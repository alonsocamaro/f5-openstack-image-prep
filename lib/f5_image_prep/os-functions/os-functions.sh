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

export PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/bin/"

OS_USER_DATA_TMP_FILE="/tmp/openstack-user-data.json"
OS_META_DATA_TMP_FILE="/tmp/openstack-meta-data.json"
OS_USER_DATA_LOCAL_FILE="/config/user_data.json"

OS_USER_DATA_RETRIES=20
OS_USER_DATA_RETRY_INTERVAL=10
OS_USER_DATA_RETRY_MAX_TIME=300

OS_USER_DATA_CLEANUP=true
OS_META_DATA_CLEANUP=true

# BIG-IP password settings
OS_CHANGE_PASSWORDS=true

# Logging settings
LOGGER_TAG="openstack-init"
LOGGER_CMD="logger -t $LOGGER_TAG"

# insert tag and log
function log() {
  echo "$1" | eval "$LOGGER_CMD"
}

# Convert to upper case
function upcase() {
  echo "$1" | tr '[a-z]' '[A-Z]'
}

function is_false() {
    val=$1

	# val is uninitialized 
    if [[ ! -n $val ]]; then
        echo 0
        return 0
    fi
	# val is set to 'NONE'
    if [[ $(upcase $val) == 'NONE' ]]; then
        echo 0
        return 0
    fi
	# val is set to 'FALSE'
    if [[ $(upcase $val) == 'FALSE' ]]; then
        echo 0
        return 0
    fi
	# val is equal to '0'
    if [[ $(upcase $val) == '0' ]]; then
        echo 0
        return 0
    fi
}

function get_json_value() {
  echo -n $(perl -MJSON -ne "\$value = decode_json(\$_)->$1; \
    \$value =~ s/([^a-zA-Z0-9])/\$1/g; print \$value" $2)
}

function get_user_data_value() {
  echo -n $(get_json_value $1 $OS_USER_DATA_TMP_FILE)
}

function get_user_data_system_cmds() {
  echo -n $(perl -MJSON -ne "print join(';;', \
  @{decode_json(\$_)->{bigip}{system_cmds}})" $OS_USER_DATA_TMP_FILE)
}

function get_user_data_firstboot_cmds() {
  echo -n $(perl -MJSON -ne "print join(';;', \
  @{decode_json(\$_)->{bigip}{firstboot_cmds}})" $OS_USER_DATA_TMP_FILE)
}

function get_user_data_network_routes() {
  echo -n $(perl -MJSON -ne "\$data = decode_json(\$_); \
  foreach \$route (@{\$data->{'bigip'}->{'network'}->{'routes'}}) { \
    print \$route->{'destination'}.\";\".\$route->{'gateway'}.\"|\"; \
  }" $OS_USER_DATA_TMP_FILE)
}

function get_dhcp_server_address() {
	echo -n $(awk '/dhcp-server-identifier/ { print $3 }' \
				  /var/lib/dhclient/dhclient.leases | tail -1 | tr -d ';')
}

# cleanup user-data, disable for debug purposes
function cleanup_user_data() {
	[[ $OS_USER_DATA_CLEANUP == true ]] && rm -f $OS_USER_DATA_TMP_FILE
	[[ $OS_META_DATA_CLEANUP == true ]] && rm -f $OS_META_DATA_TMP_FILE
}

function change_passwords() {
	local root_password=$(get_user_data_value {bigip}{root_password})
	local admin_password=$(get_user_data_value {bigip}{admin_password})
	local PW_REGEX='^\$[0-9][A-Za-z]?\$'
	
	local change_passwords=$OS_CHANGE_PASSWORDS
	[[ $change_passwords == true && \
			 $(get_user_data_value {bigip}{change_passwords}) == false ]] && \
		change_passwords=false

	if [[ $change_passwords == true ]]; then
		for creds in root:$root_password admin:$admin_password; do
			local user=$(cut -d ':' -f1 <<< $creds)
			local password=$(cut -d ':' -f2 <<< $creds)
			
			if [[ -n $password ]]; then
				if [[ $password =~ $PW_REGEX ]]; then
					password_hash=$password
					log "Found hash for salted password, successfully changed $user password..."
				else
					password_hash=$(generate_sha512_passwd_hash "$password")
					log "Found plain text password and (against my better judgment) successfully changed $user passw\
ord..."
				fi
				
				sed -e "/auth user $user/,/}/ s|\(encrypted-password \).*\$|\1\"$password_hash\"|" \
					-i /config/bigip_user.conf
			else
				log "No $user password found in user-data, skipping..."
			fi
		done
		
		tmsh load sys config user-only 2>&1 | eval $LOGGER_CMD
	else
		log "Password changed have been disabled, skipping..."
	fi
	
}

# Check if the URL is available
# arg1: url of metadata service to test
# return:
# 0 -- success
#      
function test_metadata_service() {
	curl -s $1 &>/dev/null
	return $?
}

# Get the URL of a meta data service that provides user data
# using the default EC2 datasouce:http://169.254.169.254/latest/user_data
# If that fails, try the dhcp server as a possible srouce.
# args -- none
# return:
# url of user_data -- success
# "" --failure
function get_metadata_service_url() {

	# OpenStack daatasource settings
	local OS_METADATA_SERVICE_HOST="169.254.169.254"
	local OS_METADATA_SERVICE_USER_DATA_PATH="latest/user-data"

	local metadata_url="http://$OS_METADATA_SERVICE_HOST/$OS_METADATA_SERVICE_USER_DATA_PATH"

	test_metadata_service $metadata_url
	if [[ $? != 0 ]]; then
		dhcp_server_address=$(get_dhcp_server_address)
		log "Metadata server at $metadata_url is not available, trying $dhcp_server_address instead..."
		metadata_url="http://$dhcp_server_address/${OS_METADATA_USER_DATA_PATH}"
		test_metadata_service $metadata_url
		if [[ $? != 0 ]]; then
			log "Could not locate a viable metadata server, setting default policy..."
			metadata_url=""
		fi
	fi

	echo $metadata_url
}

# Retrieve the user data from the metadata service using the passed in URL; otherwise
# try to find the the metadata service at well-known IP's
# args -- url of metadata service
# return:
# 0 -- success
# 1 -- failure
function get_metadata_service_data() {
	if [[ $1 == "" ]]; then
		metadata_url=$(get_metadata_service_url)
	else
		metadata_url=$1
	fi

	log "Retrieving user-data from $metadata_url..."
	# Use max-time 10 because it should respond within a second or two
	# and we don't want to waste all of our retry time waiting.
	curl -s -f --retry $OS_USER_DATA_RETRIES --retry-delay \
		 $OS_USER_DATA_RETRY_INTERVAL --retry-max-time $OS_USER_DATA_RETRY_MAX_TIME \
		 -m 10 \
		 -o $OS_USER_DATA_TMP_FILE $metadata_url

	if [[ $? == 0 ]]; then
		# remove newlines and repeated whitespace from JSON to appease Perl JSON \
		# module
		user_data=$(cat $OS_USER_DATA_TMP_FILE)
		echo "$user_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' \
														 > $OS_USER_DATA_TMP_FILE
		chmod 0600 $OS_USER_DATA_TMP_FILE
		log "Successfully retrieved user-data from instance metadata service..."
	else
		log "Could not retrieve user-data after $OS_USER_DATA_RETRIES attempts, trying local policy..."
		return 1
	fi

	return 0
}

# Get the user data from a local find in the config directory
# args:
# return:
# 0 -- success
# 1 -- failure
function get_local_userdata() {
	if [[ -f $OS_USER_DATA_LOCAL_FILE ]]; then
		log "Found locally installed $OS_USER_DATA_LOCAL_FILE. Using local file for user data."
		# remove newlines and repeated whitespace from JSON to appease Perl JSON \
		# module
		cat $OS_USER_DATA_LOCAL_FILE | tr -d '\n' | tr -d '\r' | tr -s ' ' \
																   > $OS_USER_DATA_TMP_FILE
		chmod 0600 $OS_USER_DATA_TMP_FILE
		return 0
	fi
	return 1
}

# Retrieve the user data from the config drive if present.  First, look for
# a block device with label "config-2".  If not available, just try the default
# "/dev/hdd".
# return:
# 0 -- success
# 1 -- failure
function get_config_drive_data() {

	local OS_CONFIG_DRIVE_MOUNT_POINT="/config/OPENSTACK_CONFIG_DRIVE"
	local OS_CONFIG_DRIVE_META_DATA_FILE="/openstack/latest/meta_data.json"
	local OS_CONFIG_DRIVE_USER_DATA_FILE="/openstack/latest/user_data"

	log "Retrieving user-data from config drive..."
	local found=0

	# Look for block device with "config-2" lable
	config_drive=$(blkid -t LABEL="config-2" -o device)
	if [[ -b $config_drive ]]; then
		mkdir -p $OS_CONFIG_DRIVE_MOUNT_POINT
		mount $config_drive $OS_CONFIG_DRIVE_MOUNT_POINT 2>&1 | $LOGGER_CMD
		if [[ $? == 0 ]]; then
			found=1
		fi
	fi

	# Look for openstack directory in the default location.
	if [[ $found != 1 ]]; then	
		# Try the default drive.
		config_drive="/dev/hdd"
		if [[ -b $config_drive ]]; then
          	mkdir -p $OS_CONFIG_DRIVE_MOUNT_POINT
          	mount $config_drive $OS_CONFIG_DRIVE_MOUNT_POINT 2>&1 | $LOGGER_CMD
			if [[ $? == 0 && -d $OS_CONFIG_DRIVE_MOUNT_POINT/openstack ]]; then
				found=1
			fi
		fi
	fi

	# If we found OpenStack config drive copy the data to temp.
	if [[ $found == 1 ]]; then
		log "Found config drive $config_drive"
	      	if [[ -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_META_DATA_FILE} ]]; then
        	      	cp ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_META_DATA_FILE} $OS_META_DATA_TMP_FILE
              		#remove newlines and repeated whitespace from JSON to appease Perl JSON \
              		# module
              		meta_data=$(cat $OS_META_DATA_TMP_FILE)
              		echo "$meta_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' \
              			> $OS_META_DATA_TMP_FILE
              		chmod 0600 $OS_META_DATA_TMP_FILE
          	fi
          	if [[ -f ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_USER_DATA_FILE} ]]; then
              		cp ${OS_CONFIG_DRIVE_MOUNT_POINT}${OS_CONFIG_DRIVE_USER_DATA_FILE} $OS_USER_DATA_TMP_FILE
              		# remove newlines and repeated whitespace from JSON to appease Perl JSON \
              		# module
              		user_data=$(cat $OS_USER_DATA_TMP_FILE)
              		echo "$user_data" | tr -d '\n' | tr -d '\r' | tr -s ' ' \
              			> $OS_USER_DATA_TMP_FILE
              		chmod 0600 $OS_USER_DATA_TMP_FILE
          	fi
          	umount $OS_CONFIG_DRIVE_MOUNT_POINT
			if [[ $? != 0 ]]; then
				log "ERROR: failed to unmount config drive on $OS_CONFIG_DRIVE_MOUNT_POINT"
			fi
          	rmdir $OS_CONFIG_DRIVE_MOUNT_POINT
          	return 0
	else
		log "Could not find config drive"
		return 1
	fi
}

# Try to find user data from all data sources.  If successful, return
# 0, else return 1.
function get_user_data() {
	# Just remove any previous files
	rm -f $OS_META_DATA_TMP_FILE
	rm -f $OS_USER_DATA_TMP_FILE

	# First, attempt to retrieve user data from config drive
	get_config_drive_data
	if [[ $? == 0 ]]; then
		return 0
	fi

	# Next, look for user data from the OpenStack metadata service
	get_metadata_service_data
	if [[ $? == 0 ]]; then
		return 0
	fi

	# If there is user data in the config directory, use that.
	get_local_userdata
	if [[ $? == 0 ]]; then
		return 0
	fi

	return 1
}

function randomize_base_passwords() {
	admin_password=`< /dev/urandom tr -dc A-Z | head -c10`
	root_password=`< /dev/urandom tr -dc A-Z | head -c10`

	/usr/bin/passwd admin $admin_password >/dev/null 2>&1
	/usr/bin/passwd root $root_password >/dev/null 2>&1

	echo "" >> /dev/kmsg
	echo "" >> /dev/kmsg
	echo "########################################################" >> /dev/kmsg
	echo "#                                                      #" >> /dev/kmsg
	echo "# random root password:           $root_password           #" >> /dev/kmsg
	echo "# random admin password:          $admin_password           #" >> /dev/kmsg
	echo "#                                                      #" >> /dev/kmsg
	echo "########################################################" >> /dev/kmsg
	echo "" >> /dev/kmsg
	echo "" >> /dev/kmsg
	echo "    r: $root_password   a: $admin_password" >> /etc/issue
	echo "" >> /etc/issue
}

function restore_issue() {
	cat /etc/issue | head -n 2 > /etc/issue
}

function get_mgmt_ip() {
	echo -n $(/sbin/ifconfig eth0 | grep 'inet addr:' | cut -d: -f2 | awk '{ print $1}')
}

# check if MCP is running
# param 1: Number of retries to perform
# param 2: Interval to wait between retries.
function wait_mcp_running() {
	local failed=0
	local retries=$1
	local interval=$2
	
	while true; do
		mcp_started=$(bigstart_wb mcpd start)

		if [[ $mcp_started == released ]]; then
			# this will log an error when mcpd is not up
			tmsh -a show sys mcp-state field-fmt | grep -q running

			if [[ $? == 0 ]]; then
				log "Successfully connected to mcpd..."
				return 0
			fi
		fi

		failed=$(($failed + 1))
		
		if [[ $failed -ge $retries ]]; then
			log "Failed to connect to mcpd after $failed attempts, quitting..."
			return 1
		fi
		
		log "Could not connect to mcpd (attempt $failed/$retries), retrying in $interval seconds..."
		sleep $interval
	done
}

# wait for tmm to start
# param 1: Number of retries to perform
# param 2: Interval to wait between retries.
function wait_tmm_started() {
	failed=0
	retries=$1
	interval=$2

	while true
	do
		tmm_started=$(bigstart_wb tmm start)
		
		if [[ $tmm_started == "released" ]]; then
			log "detected tmm started"
			return 0
		fi
		
		failed=$(($failed + 1))
		if (( $failed >= $retries )); then
			log "tmm was not started after $failed checks, quitting..."
			return 1
		fi
		
		log "tmm not started (check $failed/$retries), retrying in $interval seconds..."
		sleep $interval
	done
}

function execute_system_cmd() {
	system_cmds=$(get_user_data_system_cmds)
	[[ $ssh_key_inject == true &&
			 $(get_user_data_value {bigip}{continue_on_system_cmd_failure}) == false ]] &&
		continue_on_system_cmd_failure=false
	IFS=';;'
	running_properly=true
	for system_cmd in $system_cmds; do
		if [[ -n $system_cmd ]]; then
			if [[ $running_properly == true ]]; then
				log "Executing system command: $system_cmd..."
				if eval "$system_cmd 2>&1 | sed -e  '/^$/d' -e 's/^/  /' | $LOGGER_CMD"; then
					log "$system_cmd exited properly..."
				else
					log "$system_cmd did not exit properly..."
                if [[ $continue_on_system_cmd_failure == false ]]; then
                    running_properly=false
                fi
				fi
			else
				log "skipping the execution of $system_cmd due to command failure"
			fi      
		fi
	done
  unset IFS
}

function execute_firstboot_cmd() {
	firstboot_cmds=$(get_user_data_firstboot_cmds)
	[[ $ssh_key_inject == true &&
			 $(get_user_data_value {bigip}{continue_on_firstboot_cmd_failure}) == false ]] &&
		continue_on_firstboot_cmd_failure=false
	IFS=';;'
	running_properly=true
	for firstboot_cmd in $firstboot_cmds; do
		if [[ -n $firstboot_cmd ]]; then
			if [[ $running_properly == true ]]; then
				log "Executing system command: $firstboot_cmd..."
				if eval "$firstboot_cmd 2>&1 | sed -e  '/^$/d' -e 's/^/  /' | $LOGGER_CMD"; then
					log "$firstboot_cmd exited properly..."
				else
					log "$firstboot_cmd did not exit properly..."
					if [[ $continue_on_firstboot_cmd_failure == false ]]; then
						running_properly=false
					fi
				fi
			else
				log "skipping the execution of $firstboot_cmd due to command failure"
			fi      
		fi
	done
	unset IFS
}

function configure_base_settings() {

	log "Configuring base settings..."

        local bigip_fqdn=$(get_user_data_value {bigip}{fqdn})
        local bigip_ntp=$(get_user_data_value {bigip}{ntp})
        local bigip_syslog=$(get_user_data_value {bigip}{syslog})
	
	if [ ! -z "$bigip_fqdn" ]; then
		tmsh modify sys global-settings hostname $bigip_fqdn
	fi

        if [ ! -z "$bigip_ntp" ]; then
		tmsh modify sys ntp servers replace-all-with { $bigip_ntp }
        fi

        if [ ! -z "$bigip_syslog" ]; then
		for n in $bigip_syslog; do
			tmsh modify sys syslog remote-servers add { $n { host $n } }
		done
        fi
}

function test() {
	$(get_config_drive_data)
	if [[ $? == 0 ]]; then
		echo "Found config drive"
	fi
	
	$(get_metadata_service_data)
	if [[ $? == 0 ]]; then
		echo "Found metadata from ec2 datasource"
	fi
	
	$(get_local_userdata)
	if [[ $? == 1 ]]; then
		echo "Found local user data: $OS_USER_DATA_LOCAL_FILE"
	else
		echo "Local user data $OS_USER_DATA_LOCAL_FILE not found"
	fi
	
	get_user_data
	if [[ $? == 0 ]]; then
		echo "Successfully called get_user_data"
	else
		echo "CAll to get_user_data failed"
	fi
	
	inject_openssh_key
	if [[ $? == 0 ]]; then
		echo "inject ssh key ... success."
	fi
}

