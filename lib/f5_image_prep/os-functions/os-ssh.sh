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

source /config/os-functions/os-functions.sh

# OpenStack SSH public key injection settings
readonly OS_SSH_KEY_INJECT_ENABLED=true
readonly OS_SSH_KEY_RETRIES=5
readonly OS_SSH_KEY_RETRY_INTERVAL=10
readonly OS_SSH_KEY_RETRY_MAX_TIME=300
readonly OS_SSH_KEY_PATH="/latest/meta-data/public-keys/0/openssh-key"
readonly OS_SSH_KEY_TMP_FILE="/tmp/openstack-ssh-key.pub"
readonly ROOT_AUTHORIZED_KEYS="/root/.ssh/authorized_keys"

function get_meta_data_public_key() {
	local metadata_file=$1
	echo -n $(perl -MJSON -ne "\$data = decode_json(\$_); print(values(%{\$data->{public_keys}}));" $metadata_file)
}

function inject_openssh_key() {

	local metadata_url=$1
	local metadata_file=$2
	
	local ssh_key_inject=$OS_SSH_KEY_INJECT_ENABLED
	[[ $ssh_key_inject == true &&
			 $(get_user_data_value {bigip}{ssh_key_inject}) == false ]] &&
		    ssh_key_inject=false
	
	if [[ $ssh_key_inject == true ]]; then
		rm -f $OS_SSH_KEY_TMP_FILE

		if [[ -f  ${metadata_file} ]]; then
			log "Retrieving SSH public key from ${metadata_file}..."
			ssh_key=$(get_meta_data_public_key ${metadata_file})
			if [[ ! -z $ssh_key ]]; then
				grep -q "$ssh_key" $ROOT_AUTHORIZED_KEYS
				if [[ $? != 0 ]]; then
					echo $ssh_key >> $ROOT_AUTHORIZED_KEYS
					restorecon $ROOT_AUTHORIZED_KEYS
					log "Successfully installed SSH public key..."
				else
					log "SSH public key already installed, skipping..."
				fi
			fi
		else
			log "Retrieving SSH public key from $metadata_url..."
			curl -s -f --retry $OS_SSH_KEY_RETRIES --retry-delay \
				 $OS_SSH_KEY_RETRY_INTERVAL --retry-max-time \
				 $OS_SSH_KEY_RETRY_MAX_TIME -o $OS_SSH_KEY_TMP_FILE $metadata_url
			
			if [[ $? == 0 ]]; then
				ssh_key=$(head -n1 $OS_SSH_KEY_TMP_FILE)
				grep -q "$ssh_key" $ROOT_AUTHORIZED_KEYS
				
				if [[ $? != 0 ]]; then
					echo $ssh_key >> $ROOT_AUTHORIZED_KEYS
					restorecon $ROOT_AUTHORIZED_KEYS
					rm -f $OS_SSH_KEY_TMP_FILE
					log "Successfully installed SSH public key..."
				else
					log "SSH public key already installed, skipping..."
				fi
			else
				log "Could not retrieve SSH public key after $OS_SSH_KEY_RETRIES attempts, quitting..."
				return 1
			fi
		fi
	else
		log "SSH public key injection disabled, skipping..."
	fi
}
