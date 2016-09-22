#!/bin/bash
#
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
# 2015/12/15 - u.alonsocamaro@f5.com - First version released in hive
# 2016/04/29 - u.alonsocamaro@f5.com - First version released in github supporting BIG-IQ 4.5/4.6
# 2016/09/22 - u.alonsocamaro@f5.com - Support of BIG-IQ 5.0. Registration and registration are now in their own separate functions

shopt -s extglob
source /config/os-functions/os-functions.sh

# Defaults

readonly OS_BIGIQ_ADMIN_PASSWORD=admin
readonly OS_BIGIQ_ROOT_PASSWORD=default

readonly OS_BIGIQ_LICENSE_POOL_UUID=any
readonly OS_BIGIQ_UPDATE_FRAMEWORK=true

readonly OS_BIGIQ_LICENSE_POOL_HOST=127.0.0.1
readonly OS_BIGIQ_LICENSE_POOL_USER=admin
readonly OS_BIGIQ_LICENSE_POOL_PASSWORD=admin

# 
readonly OS_BIGIQ_JSON_REPLY_FILE=/tmp/bigiq_reply.json
readonly OS_BIGIQ_JSON_REPLY_TMP_FILE=/tmp/bigiq_reply.tmp
readonly OS_BIGIQ_MAX_RETRIES=20
readonly OS_THISUUID=$( cat /config/f5-rest-device-id )
readonly OS_THISDEVICE="https://localhost/mgmt/cm/cloud/managed-devices/$OS_THISUUID"

function curlbigiq() {

	rm -f ${OS_BIGIQ_JSON_REPLY_FILE} ${OS_BIGIQ_JSON_REPLY_TMP_FILE}

	local CTYPE='-H "Content-Type: application/json"'
        local CBASE="curl -sk -w %{http_code} -o ${OS_BIGIQ_JSON_REPLY_FILE} $CTYPE -u $bigiq_license_pool_user:$bigiq_license_pool_password --max-time 180"
        local -i http_code=$(eval $CBASE https://$bigiq_license_pool_host$@)

	if [[ $http_code -eq 0 ]]; then
		log "curl request to BIG-IQ failed, request was: https://$bigiq_license_pool_host$@"
	fi

	echo $http_code
}

function get_bigiq_reply_value() {

	# remove newlines and repeated whitespace from JSON to appease Perl JSON module, but only once
  	if [[ $OS_BIGIQ_JSON_REPLY_TMP_FILE -ot $OS_BIGIQ_JSON_REPLY_FILE ]]; then
		cat $OS_BIGIQ_JSON_REPLY_FILE | tr -d '\n' | tr -d '\r' | tr -s ' ' > $OS_BIGIQ_JSON_REPLY_TMP_FILE
	fi

	echo -n $(get_json_value $1 $OS_BIGIQ_JSON_REPLY_TMP_FILE)
}

function log_bigiq_message() {

        local custom_message=$1
	local code=$(get_bigiq_reply_value {code})
        local message=$(get_bigiq_reply_value {message})

	log "$custom_message. Return code is $code and error message is $message"
}

function log_bigiq_errors() {
	local custom_message=$1
	local errors=$(get_bigiq_reply_value {errors})

	log "$custom_message. Errors reported from BIG-IQ: $errors"
}

function check_licensed_unit() {

	tmsh show sys license | grep -q -i "Licensed On" && return 0
	
	return 1
}

function get_json_values_from_array () 
{ 
    echo -n $(perl -MJSON -ne "\$decoded = decode_json(\$_); @items_array= @{\$decoded->$1 }; @retvals = map { \$_->$2 } @items_array; print join(' ', @retvals);" $3 )
}

function get_bigiq_reply_values_from_array () 
{ 
    if [[ $OS_BIGIQ_JSON_REPLY_TMP_FILE -ot $OS_BIGIQ_JSON_REPLY_FILE ]]; then
        cat $OS_BIGIQ_JSON_REPLY_FILE | tr -d '\n' | tr -d '\r' | tr -s ' ' > $OS_BIGIQ_JSON_REPLY_TMP_FILE;
    fi;
    echo -n $(get_json_values_from_array $1 $2 $OS_BIGIQ_JSON_REPLY_TMP_FILE)
}

# needs_bigiq_registration checks if the BIG-IQ version is less than 5.0.0

function check_bigiq_5plus ()
{

    local http_code=$(curlbigiq "/mgmt/shared/resolver/device-groups/cm-shared-all-big-iqs/devices?\\\$select=version" -X GET )

    local -a bqVersion

    bqVersion=( $(get_bigiq_reply_values_from_array {items} {version}) )

    [[ "${bqVersion[0]}" < "5.0.0" ]] && echo 0 || echo 1;
}

function register_bigip ()
{
        local bigip_mgmt_ip=$(get_mgmt_ip)
        local JSON="{\"deviceAddress\": \"$bigip_mgmt_ip\", \"username\":\"admin\", \"password\":\"$bigip_admin_password\", \"automaticallyUpdateFramework\":\"$bigiq_update_framework\", \"rootUsername\":\"root\", \"rootPassword\":\"$bigip_root_password\"}"

        local i
	declare -i i
	i=1
        local state=""

        while [[ -z "$state" ]]; do

                http_code=$(curlbigiq /mgmt/cm/cloud/managed-devices -d "\"$JSON\"" -X POST)

                local state=$(get_bigiq_reply_value {state})

                if [ -z "$state" ] ; then
                        if [[ $OS_BIGIQ_MAX_RETRIES -lt $i ]]; then
                                log_bigiq_message "Error while registering this BIG-IP in BIG-IQ. Max retries reached ($i of $OS_BIGIQ_MAX_RETRIES). Aborting..."
                                return 1
                        else
                                log_bigiq_message "Error while registering this BIG-IP in BIG-IQ. Retrying ($i of $OS_BIGIQ_MAX_RETRIES)..."
                        fi
                else
                        log "BIG-IP registered in BIG-IQ. Waiting for ACTIVE state in BIG-IQ..."
                        break;
                fi

                i=$i+1
                sleep 10
        done

        local machineid=$(get_bigiq_reply_value {machineId})
        local selflink=$(get_bigiq_reply_value {selfLink})

        local code=""
        local errors=""
        local message=""

        # Loop until we have an 'ACTIVE' state with the BIGIQ. When updating the framework this can take some time.
        i=0

        # Go get the BIGIQ's record for this BIGIP node
        http_code=$(curlbigiq /mgmt/cm/cloud/managed-devices/$machineid -X GET)

        state=$(get_bigiq_reply_value {state})

        while [ "$state" != "ACTIVE" ];
        do

                if [ "$state" == "POST_FAILED" ]; then
                        log_bigiq_errors "Error while waiting the BIG-IP to be active in the BIG-IQ"
                        return 1
                fi

                if [ -z "$state" ]; then
                        code=$(get_bigiq_reply_value {code})

                        if [ "$code" = "404" ]; then
                                log "Error the BIG-IP is not found registered in the BIG-IQ"
                        fi
                fi

                if [ $i == $OS_BIGIQ_MAX_RETRIES ] && [ "$state" != "ACTIVE" ]; then
                        log "Aborting licensing in the BIG-IQ too many retries while waiting for ACTIVE state"
                        return 1
                fi

                i=$i+1
                log "Waiting for ACTIVE state in BIG-IQ, current status: $state..."
                sleep 5

                # Go get the BIGIQ's record for this BIGIP node
                http_code=$(curlbigiq $CBASE/mgmt/cm/cloud/managed-devices/$machineid -X GET)

                state=$(get_bigiq_reply_value {state})
        done


	echo $selflink
	return 0
}

function unregister_bigip() {

	local http_code=$(curlbigiq /mgmt/cm/cloud/managed-devices/$OS_THISUUID -X DELETE )

	if [ "$http_code" != "200" ]; then
		log "Error while trying to delete this device with uuid $OS_THIS_UUIDi from BIG-IQ"
		return 1
	fi

	log 'Could eliminate this device from BIG-IQ'
	return 0
}

# licenese a BIG-IP using a BIG-IQ pool license. The pool license ID can be specified in the JSON file or
# any can be specified in which case loops through all the licenses until it finds a valid one.
#
# Before the actual license the BIG-IP is registered in BIG-IQ

function license_via_bigiq_license_pool() {

	local http_code
	local JSON
	local i
	declare -i i

	if [[ -z "$bigiq_license_pool_host" ]]; then
		log "BIG-IQ licensing via license pool selected but no BIG-IQ host selected, quitting..."
		return 1
	fi

	is_bigiq_5plus=$( check_bigiq_5plus )

	if [[ "$is_bigiq_5plus" = 0 ]]; then
		selflink=$( register_bigip )
		if [[ $? -ne 0 ]]; then

			return 1;
		fi
	fi

        #-------------------[ License the BIG-IP from the license pools in BIG-IQ ]-------------------

	if [[ $bigiq_license_pool_uuid = "any" ]];
	then
		# Retrieve all the license Pools on BIGIQ
		http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/?\$select=uuid -X GET)
		pools=$(get_bigiq_reply_values_from_array {items} {uuid})
	else
		# Use the provided one
		pools=$bigiq_license_pool_uuid	
	fi

	# Try each license pool until we get one that works.
	for pool in $pools; do

		log "Trying to obtain a license from BIG-IP pool license $pool ..."

        	if [[ "$is_bigiq_5plus" = 0 ]]; then

                	JSON='{\"deviceReference\":{\"link\": \"$selflink\"}}'
		else

		        local bigip_mgmt_ip=$(get_mgmt_ip)

			JSON="{\"deviceAddress\": \"$bigip_mgmt_ip\", \"username\": \"admin\", \"password\": \"$bigip_admin_password\"}"
		fi

		http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members -X POST -d "\"$JSON\"")
		# cp $OS_BIGIQ_JSON_REPLY_FILE $OS_BIGIQ_JSON_REPLY_FILE.post

                uuid=$(get_bigiq_reply_value {uuid})

                if [ -z "$uuid" ]; then
			log_bigiq_message "Didn't find the pool license $pool"
			return 1
		fi

	
		i=0
		state=$(get_bigiq_reply_value {state})

		while [ "$state" != "LICENSED" ];
		do

			if [ -z "$state" ]; then

	                        code=$(get_bigiq_reply_value {items}[0]{code})

	                        if [ "$code" = "404" ]; then
        	                        log "Didn't find the pool license $pool ..."
					# We try with the next license if there is one
					continue 2
				fi

				log "Error while licensing the BIG-IP with pool license $uuid: no state has been returned"
				return 1
			fi
	
                        i=$i+1
	
			if [ $i == $OS_BIGIQ_MAX_RETRIES ] && [ "$state" != "LICENSED" ]; then
	                        log "Aborting licensing in the BIG-IQ too many retries while waiting for LICENSED state"
				return 1
			fi

                        log "Waiting for LICENSED status in BIG-IQ, current status: $state..."
                        sleep 5

                        http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$UUID -X GET)
                        # cp $OS_BIGIQ_JSON_REPLY_FILE $OS_BIGIQ_JSON_REPLY_FILE.get

                        state=$(get_bigiq_reply_value {items}[0]{state})

		done

		local expired=$(tmsh show sys license | grep "^Warning" | cut -d' ' -f4)

		if [ "$expired" = "expired" ]; then

			log "The license assigned is expired, returning the license to the BIG-IQ"
			# Delete the license key and try another pool.
			http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$uuid -X DELETE)
		
			continue
		fi

		if check_licensed_unit; then
			log "Unit has been succesfully licensed in pool license $pool with license $uuid"
			return 0	
		fi	
		
	done

	log "Licensing failure: didn't find any pool in BIG-IQ"

	return 1
}

# licenese a BIG-IP using a BIG-IQ pool license. The pool license ID can be specified in the JSON file or 
# any can be specified in which case loops through all the licenses until it finds a valid one.
#
# After the license is withadrawn the device is also unregisterd from the BIG-IQ

function unlicense_via_bigiq_license_pool() {

	local http_code
	local -a pools
	local memberIds
	local -a uuids
	local -i i

	# Retrieve all the license Pools on BIGIQ
	http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/?\$select=uuid -X GET)

	pools=( $(get_bigiq_reply_values_from_array {items} {uuid}) )

	is_bigiq_5plus=$( check_bigiq_5plus )

        # Try each license pool until we find us 
        for pool in $pools; do

		http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members)

		# Let's make version independent Ids
		if [[ "$is_bigiq_5plus" = 1 ]]; then
			memberIds=$( get_bigiq_reply_values_from_array {items} {deviceMachineId} )
			myId="$OS_THISUUID"
		else
			memberIds=$( get_bigiq_reply_values_from_array {items} {deviceReference}{link} )
			myId="$OS_THISDEVICE"
		fi

		uuids=($( get_bigiq_reply_values_from_array {items} {uuid} ))

		i=0 
		for memberId in $memberIds; do

			if [[ "$memberId" = "$myId" ]]; then

                        	uuid=${uuids[$i]}

		                if [[ "$is_bigiq_5plus" = 1 ]]; then

	                        	JSON="{\"uuid\": \"$uuid\", \"username\": \"admin\", \"password\": \"$bigip_admin_password\"}"
					http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$uuid -X DELETE -d "\"$JSON\"" )
				else
					http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$uuid -X DELETE )
				fi	

				if [ "$http_code" != "200" ]; then
                                	log "Error while trying to release the license $uuid in pool $pool"
                                	return 1
				fi

				log "Could eliminate license $uuid from license pool $pool"

			        is_bigiq_5plus=$( check_bigiq_5plus )

			        if [[ "$is_bigiq_5plus" = 0 ]]; then
					unregister_bigip
                			return $?
        			fi

				return 0
			fi

			i=$i+1	

                	sleep 1

		done

		sleep 5

	done	

	log "Could not find the license of this device in BIG-IQ"

	return 1
}

function do_license_via_bigiq() {

        license_via_bigiq_license_pool
        if [[ $? = 0 ]]; then
                echo "license_via_bigiq_license_pool succeeded"
        else
                echo "license_via_bigiq_license_pool failed"
        fi
}

function do_unlicense_via_bigiq() {

        unlicense_via_bigiq_license_pool
        if [[ $? = 0 ]]; then
                echo "unlicense_via_bigiq_license_pool succeeded"
        else
                echo "unlicense_via_bigiq_license_pool failed"
        fi
}

function test() {

	rm -f /config/bigip.license
	reloadlic

	get_user_data

	set -x

	do_license_via_bigiq

	sleep 5

	do_unlicense_via_bigiq

	set +x
}


### MAIN #########################################################

get_user_data

bigip_admin_password=$(get_user_data_value {bigip}{admin_password})
bigip_root_password=$(get_user_data_value {bigip}{root_password})

bigiq_license_pool_uuid=$(get_user_data_value {bigip}{license}{bigiq_license_pool_uuid})
bigiq_update_framework=$(get_user_data_value {bigip}{license}{bigiq_update_framework})

bigiq_license_pool_host=$(get_user_data_value {bigip}{license}{bigiq_license_pool_host})
bigiq_license_pool_user=$(get_user_data_value {bigip}{license}{bigiq_license_pool_user})
bigiq_license_pool_password=$(get_user_data_value {bigip}{license}{bigiq_license_pool_password})


[[ $(is_false ${bigiq_admin_password}) ]] && bigiq_admin_password=${OS_BIGIQ_ADMIN_PASSWORD}
[[ $(is_false ${bigiq_root_password}) ]] && bigiq_root_password=${OS_BIGIQ_ROOT_PASSWORD}

[[ $(is_false ${bigiq_license_pool_uuid}) ]] && bigiq_license_pool_uuid=${OS_BIGIQ_LICENSE_POOL_UUID}
[[ $(is_false ${bigiq_update_framework}) ]] && bigiq_update_framework=${OS_BIGIQ_UPDATE_FRAMEWORK}

[[ $(is_false ${bigiq_license_pool_host}) ]] && bigiq_license_pool_host=${OS_BIGIQ_LICENSE_POOL_HOST}
[[ $(is_false ${bigiq_license_pool_user}) ]] && bigiq_license_pool_user=${OS_BIGIQ_LICENSE_POOL_USER}
[[ $(is_false ${bigiq_license_pool_password}) ]] && bigiq_license_pool_password=${OS_BIGIQ_LICENSE_POOL_PASSWORD}

if [[ $1 = "test" ]]; then
	test
elif [[ $1 = "license" ]]; then

        do_license_via_bigiq
elif [[ $1 = "unlicense" ]]; then

	do_unlicense_via_bigiq
elif [[ $1 = "register" ]]; then

	echo Registered device with selfLink...
	register_bigip

elif [[ $1 = "unregister" ]]; then

	unregister_bigip
else
	echo "Nothing to do: check script's parameters"
fi


