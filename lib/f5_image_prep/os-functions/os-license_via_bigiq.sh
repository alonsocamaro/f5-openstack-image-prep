#!/bin/bash

shopt -s extglob
source /config/os-functions/os-functions.sh

readonly OS_BIGIQ_LICENSE_POOL_USER=admin
readonly OS_BIGIQ_LICENSE_POOL_PASSWORD=admin
readonly OS_BIGIQ_LICENSE_POOL_UUID=any
readonly OS_BIGIQ_UPDATE_FRAMEWORK=true
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

# licenese a BIG-IP using a BIG-IQ pool license. The pool license ID can be specified in the JSON file or
# any can be specified in which case loops through all the licenses until it finds a valid one.
#
# Before the actual license the BIG-IP is registered in BIG-IQ

function license_via_bigiq_license_pool() {

	local bigip_admin_password=$1
	local bigip_root_password=$2

	local bigiq_license_pool_uuid=$(get_user_data_value {bigip}{license}{bigiq_license_pool_uuid})
	local bigiq_update_framework=$(get_user_data_value {bigip}{license}{bigiq_update_framework})

	local bigiq_license_pool_host=$(get_user_data_value {bigip}{license}{bigiq_license_pool_host})
	local bigiq_license_pool_user=$(get_user_data_value {bigip}{license}{bigiq_license_pool_user})
	local bigiq_license_pool_password=$(get_user_data_value {bigip}{license}{bigiq_license_pool_password})

	local http_code
	local JSON
	local i
	declare -i i

	if [[ -z "$bigiq_license_pool_host" ]]; then
		log "BIG-IQ licensing via license pool selected but no BIG-IQ host selected, quitting..."
		return 1
	fi

	[[ $(is_false ${bigiq_license_pool_user}) ]] && bigiq_license_pool_user=${OS_BIGIQ_LICENSE_POOL_USER}
	[[ $(is_false ${bigiq_license_pool_password}) ]] && bigiq_license_pool_password=${OS_BIGIQ_LICENSE_POOL_PASSWORD}
        [[ $(is_false ${bigiq_license_pool_uuid}) ]] && bigiq_license_pool_uuid=${OS_BIGIQ_LICENSE_POOL_UUID}
	[[ $(is_false ${bigiq_update_framework}) ]] && bigiq_update_framework=${OS_BIGIQ_UPDATE_FRAMEWORK}
	

	#-------------------[ Register the BIG-IP in BIG-IQ ]-------------------

	bigip_mgmt_ip=$(get_mgmt_ip)
	JSON="{\"deviceAddress\": \"$bigip_mgmt_ip\", \"username\":\"admin\", \"password\":\"$bigip_admin_password\", \"automaticallyUpdateFramework\":\"$bigiq_update_framework\", \"rootUsername\":\"root\", \"rootPassword\":\"$bigip_root_password\"}"

	i=1
	state=""

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

		log "Trying to obtain a license from BIG-IQ's pool license $pool ..."

                JSON='{\"deviceReference\":{\"link\": \"$selflink\"}}'
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

                        log "Waiting for LICENSED status in BIG-IQ, current status: $state..."
			sleep 5

			http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$UUID -X GET)
			# cp $OS_BIGIQ_JSON_REPLY_FILE $OS_BIGIQ_JSON_REPLY_FILE.get

	        	state=$(get_bigiq_reply_value {items}[0]{state})
			
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
		
			if [ $i == $OS_BIGIQ_MAX_RETRIES ] && [ "$state" != "LICENSED" ]; then
	                        log "Aborting licensing in the BIG-IQ too many retries while waiting for LICENSED state"
				return 1
			fi

			i=$i+1
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

	return 1
}

# licenese a BIG-IP using a BIG-IQ pool license. The pool license ID can be specified in the JSON file or 
# any can be specified in which case loops through all the licenses until it finds a valid one.
#
# After the license is withadrawn the device is also unregisterd from the BIG-IQ

function unlicense_via_bigiq_license_pool() {

	local bigiq_license_pool_host=$(get_user_data_value {bigip}{license}{bigiq_license_pool_host})
	local bigiq_license_pool_user=$(get_user_data_value {bigip}{license}{bigiq_license_pool_user})
	local bigiq_license_pool_password=$(get_user_data_value {bigip}{license}{bigiq_license_pool_password})

	# Retrieve all the license Pools on BIGIQ
	http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/?\$select=uuid -X GET)
	# cp $OS_BIGIQ_JSON_REPLY_FILE $OS_BIGIQ_JSON_REPLY_FILE.pools
	pools=$(get_bigiq_reply_values_from_array {items} {uuid})

        # Try each license pool until we find us 
        for pool in $pools; do

		http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members)
		# cp $OS_BIGIQ_JSON_REPLY_FILE $OS_BIGIQ_JSON_REPLY_FILE.members
		local devices=$( get_bigiq_reply_values_from_array {items} {deviceReference}{link} )

		local -i i
		local -a uuids

		uuids=($( get_bigiq_reply_values_from_array {items} {uuid} ))
     
		i=0 
		for device in $devices; do
 
                	if [ "$device" = "$OS_THISDEVICE" ]; then

                        	uuid=${uuids[$i]}

				http_code=$(curlbigiq /mgmt/cm/shared/licensing/pools/$pool/members/$uuid -X DELETE )

				if [ "$http_code" != "200" ]; then
                                	log "Error while trying to release the license $uuid in pool $pool"
                                	return 1
				fi

				log "Could eliminate license $uuid from license pool $pool"

				http_code=$(curlbigiq /mgmt/cm/cloud/managed-devices/$OS_THISUUID -X DELETE )

				if [ "$http_code" != "200" ]; then
					log "Error while trying to delete this device with uuid $OS_THIS_UUIDi from BIG-IQ"
					return 1
				fi

				log 'Could eliminate this device from BIG-IQ'
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

function test() {

	rm -f /config/bigip.license
	reloadlic

	get_user_data

	set -x

	license_via_bigiq_license_pool admin default        
        if [[ $? = 0 ]]; then
                echo "license_via_bigiq_license_pool succeeded"
        else
                echo "license_via_bigiq_license_pool failed"
        fi

	sleep 5

	unlicense_via_bigiq_license_pool 
        if [[ $? = 0 ]]; then
                echo "unlicense_via_bigiq_license_pool succeeded"
        else
                echo "unlicense_via_bigiq_license_pool failed"
        fi

	set +x
}

if [[ $1 = "test" ]]; then
	test
elif [[ $1 = "unlicense" ]]; then

        get_user_data
        unlicense_via_bigiq_license_pool
        if [[ $? = 0 ]]; then
                echo "unlicense_via_bigiq_license_pool succeeded"
		exit 0
        else
                echo "unlicense_via_bigiq_license_pool failed"
		exit 1
        fi
fi


