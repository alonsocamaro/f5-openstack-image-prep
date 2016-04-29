#!/bin/bash
# Copyright 2015-2016 F5 Networks Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

shopt -s extglob

source /config/os-functions/os-functions.sh
source /config/os-functions/os-license_via_bigiq.sh

# BIG-IP licensing settings
readonly BIGIP_LICENSE_FILE="/config/bigip.license"
readonly BIGIP_LICENSE_RETRIES=5
readonly BIGIP_LICENSE_RETRY_INTERVAL=5

# BIG-IP module provisioning
readonly BIGIP_PROVISIONING_ENABLED=true
readonly BIGIP_AUTO_PROVISIONING_ENABLED=true

readonly LEVEL_REGEX='^(dedicated|minimum|nominal|none)$'

# license and provision device if license file doesn't exist
function license_and_provision_modules() {
	if [[ $? == 0 && ! -s ${BIGIP_LICENSE_FILE} ]]; then
		license_bigip
		provision_modules
	else
		log "Skip licensing and provisioning.  "${BIGIP_LICENSE_FILE}" already exists."
	fi
}

# wait undefinetively for the operator to login and license the unit while logging
function license_via_manual() {

	log "Manual licensing selected. Waiting for the unit to be manually licensed..."
	while ! tmsh show sys license | grep -q -i "Licensed On" ; do 
		log "Waiting for the unit to be manually licensed..."
        	sleep 10
	done
}

# extract license from JSON data and license unit
function license_bigip() {
	local host=$(get_user_data_value {bigip}{license}{host})
	local basekey=$(get_user_data_value {bigip}{license}{basekey})
	local addkey=$(get_user_data_value {bigip}{license}{addkey})
	local method=$(get_user_data_value {bigip}{license}{method})

	if [[ -f /etc/init.d/mysql ]]; then
		sed -ised -e 's/sleep\ 5/sleep\ 10/' /etc/init.d/mysql
		rm -f /etc/init.d/mysqlsed
	fi
	if [[ ! -s ${BIGIP_LICENSE_FILE} ]]; then
		if [[ "$method" = "internet" ]]; then
			if [[ ! $(is_false $basekey) ]]; then
				failed=0
			
				# if a host or add-on key is provided, append to license client command
				[[ ! $(is_false $host) ]] && host_cmd="--host $host"
				[[ ! $(is_false $addkey) ]] && addkey_cmd="--addkey $addkey"
			
				while true; do
					log "Licensing BIG-IP using license key $basekey..."
					SOAPLicenseClient $host_cmd --basekey $basekey $addkey_cmd 2>&1 | eval $LOGGER_CMD

					if [[ $? == 0 && -f $BIGIP_LICENSE_FILE ]]; then
						log "Successfully licensed BIG-IP using user-data from instance metadata..."
						return 0
					else
						failed=$(($failed + 1))

						if [[ $failed -ge ${BIGIP_LICENSE_RETRIES} ]]; then
							log "Failed to license BIG-IP after $failed attempts, quitting..."
							return 1
						fi

						log "Could not license BIG-IP (attempt #$failed/$BIGIP_LICENSE_RETRIES), retrying in $BIGIP_LICENSE_RETRY_INTERVAL seconds..."
						sleep ${BIGIP_LICENSE_RETRY_INTERVAL}
					fi
				done
			else
				log "No BIG-IP license key found, skipping license activation..."
			fi
		elif [[ "$method" = "bigiq" ]]; then

        		local admin_password=$(get_user_data_value {bigip}{admin_password})
                        local root_password=$(get_user_data_value {bigip}{root_password})

			license_via_bigiq_license_pool $admin_password $root_password

		elif [[ "$method" = "manual" ]]; then
			license_via_manual
		else
			log "No BIG-IP licensing method defined, skipping license activation..."
		fi
	else
		log "BIG-IP already licensed, skipping license activation..."
	fi
}

# return list of modules supported by current platform
function get_supported_modules() {
	echo -n $(tmsh list sys provision one-line | awk '/^sys/ { print $3 }')
}

# retrieve enabled modules from BIG-IP license file
function get_licensed_modules() {
	if [[ -s $BIGIP_LICENSE_FILE ]]; then
		provisionable_modules=$(get_supported_modules)
		enabled_modules=$(awk '/^mod.*enabled/ { print $1 }' /config/bigip.license |
								 sed 's/mod_//' | tr '\n' ' ')

		for module in $enabled_modules; do
			case $module in
				wo@(c|m)) module="wom" ;;
				wa?(m)) module="wam" ;;
				af@(m|w)) module="afm" ;;
				am) module="apm" ;;
			esac
				  
			if [[ "$provisionable_modules" == *"$module"* ]]; then
				licensed_modules="$licensed_modules $module"
				log "Found license for $(upcase $module) module..."
			fi
		done
				  
		echo "$licensed_modules"
	else
		log "Could not locate valid BIG-IP license file, no licensed modules found..."
	fi
}
 
# provision BIG-IP software modules
function provision_modules() {
	# get list of licensed modules
	local licensed_modules=$(get_licensed_modules)
	local provisionable_modules=$(get_supported_modules)
	
	# if auto-provisioning enabled, obtained enabled modules list from license \
	# file
	local auto_provision=$(get_user_data_value {bigip}{modules}{auto_provision})
	[[ $BIGIP_AUTO_PROVISIONING_ENABLED == false ]] && auto_provision=false
	
	for module in $licensed_modules; do
		level=$(get_user_data_value {bigip}{modules}{$module})
		
		if [[ "$provisionable_modules" == *"$module"* ]]; then
			if [[ ! $level =~ $LEVEL_REGEX ]]; then
				if [[ $auto_provision == true ]]; then
					level=nominal
				else
					level=none
				fi
			fi
			
			tmsh modify sys provision $module level $level &> /dev/null
			
			if [[ $? == 0 ]]; then
				log "Successfully provisioned $(upcase "$module") with level $level..."
			else
				log "Failed to provision $(upcase "$module"), examine /var/log/ltm for more information..."
			fi
		fi
	done
}

function test() {
	license_bigip
	if [[ $? == 0 ]]; then
		echo "license_bigip successful"
	else
		echo "license_bigip unsuccessful"
	fi
}

#test
