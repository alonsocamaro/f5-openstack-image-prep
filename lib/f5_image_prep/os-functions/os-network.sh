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

# TMM interfaces network settings
readonly OS_MGMT_LEASE_FILE="/var/lib/dhclient/dhclient.leases"
readonly OS_MGMT_MTU=1400
readonly OS_DHCP_ENABLED=true
readonly OS_DHCP_LEASE_FILE="/tmp/openstack-dhcp.leases"
readonly OS_DHCP_REQ_TIMEOUT=30
readonly OS_VLAN_PREFIX="openstack-network-"
readonly OS_VLAN_DESCRIPTION="auto-added by openstack-init"
readonly OS_VLAN_MTU=1500
readonly OS_SELFIP_PREFIX="openstack-dhcp-"
readonly OS_SELFIP_ALLOW_SERVICE="none"
readonly OS_SELFIP_DESCRIPTION="auto-added by openstack-init"
readonly OS_DEVICE_SYNC="false"
readonly OS_DEVICE_FAILOVER="false"
readonly OS_DEVICE_MIRROR_PRIMARY="false"
readonly OS_DEVICE_MIRROR_SECONDARY="false"

# Regular expressions
readonly TMM_IF_REGEX='^1\.[0-9]$'
readonly IP_REGEX='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
readonly SELFIP_ALLOW_SERVICE_REGEX='^(all|default|none)$'

function set_tmm_if_selfip() {
	local tmm_if=$1
	local address=$2
	local netmask=$3
	local mtu=$4
  
	unset dhcp_enabled selfip_prefix selfip_name selfip_description selfip_allow_service vlan_prefix vlan_name selfip_floatingip 
	
	if [[ ${address} =~ $IP_REGEX && ${netmask} =~ $IP_REGEX ]]; then
	  
		local dhcp_enabled=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{dhcp})
		local vlan_prefix=$(get_user_data_value {bigip}{network}{vlan_prefix})
		local vlan_name=$(normalize_name "$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{vlan_name})")
		local selfip_prefix=$(get_user_data_value {bigip}{network}{selfip_prefix})
		local selfip_name=$(normalize_name "$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{selfip_name})")
		local selfip_floatingip=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{selfip_floatingip})
                local floatingip_owner=$(get_user_data_value {bigip}{network}{floatingip_owner})
		local selfip_description=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{selfip_description})
		local selfip_allow_service=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{selfip_allow_service})
		local device_is_sync=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{is_sync})
		local device_is_failover=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{is_failover})
		local device_is_mirror_primary=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{is_mirror_primary})
		local device_is_mirror_secondary=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{is_mirror_secondary})
    
		[[ $(is_false ${vlan_prefix}) ]] && vlan_prefix=${OS_VLAN_PREFIX}
		[[ $(is_false ${vlan_name}) ]] && vlan_name="${vlan_prefix}${tmm_if}"
		
		[[ $(is_false ${selfip_prefix}) ]] && selfip_prefix=${OS_SELFIP_PREFIX}
		[[ $(is_false ${selfip_name}) ]] && selfip_name="${selfip_prefix}${tmm_if}"
		[[ $(is_false ${selfip_description}) ]] && selfip_description=${OS_SELFIP_DESCRIPTION}
		[[ $(is_false ${selfip_allow_service}) ]] && selfip_allow_service=${OS_SELFIP_ALLOW_SERVICE}
		[[ $(is_false ${device_is_sync}) ]] && device_is_sync=${OS_DEVICE_SYNC}
		[[ $(is_false ${device_is_failover}) ]] && device_is_failover=${OS_DEVICE_FAILOVER}
		[[ $(is_false ${device_is_mirror_primary}) ]] && device_is_mirror_primary=${OS_DEVICE_MIRROR_PRIMARY}
		[[ $(is_false ${device_is_mirror_secondary}) ]] && device_is_mirror_secondary=${OS_DEVICE_MIRROR_SECONDARY}
		
		if [[ ${dhcp_enabled} == false ]]; then
			log "Configuring self IP $selfip_name on VLAN $vlan_name with static address $address/$netmask..."
		else
			log "Configuring self IP $selfip_name on VLAN $vlan_name with DHCP address $address/$netmask..."
		fi
		
		if [ -n "$mtu" ]; then
			vlan_mtu_cmd="tmsh modify net vlan $vlan_name { mtu $mtu }"
			log "  $vlan_mtu_cmd"
			eval "$vlan_mtu_cmd 2>&1 | $LOGGER_CMD"
		fi
		
		selfip_cmd="tmsh create net self $selfip_name address $address/$netmask allow-service $selfip_allow_service vlan $vlan_name description \"$selfip_description\""
		log "  $selfip_cmd"
		eval "$selfip_cmd 2>&1 | $LOGGER_CMD"

		if [[ "$(upcase ${floatingip_owner})" = "TRUE" ]] && [[ "$(upcase ${selfip_floatingip})" != "NONE" ]]; then
			selfip_cmd="tmsh create net self $selfip_name-floating address $selfip_floatingip/$netmask traffic-group traffic-group-1 allow-service $selfip_allow_service vlan $vlan_name description \"floating-ip $selfip_description\""
			log "  $selfip_cmd"
			eval "$selfip_cmd 2>&1 | $LOGGER_CMD"
		fi

		if [[ $device_is_sync == true ]]; then
			log "Configuring self IP $selfip_name as the device config sync interface"
			if [[ $(is_false  ${local_device_name}) ]]; then
				local_device_name=`tmsh show /cm device all field-fmt|grep "cm device"|awk 'NR<2{print $3}'`
			fi
			tmsh modify /cm device ${local_device_name} { configsync-ip ${address} }
		fi
		
		if [[ ${device_is_failover} == true ]]; then
			log "Configuring self IP $selfip_name as a device unicast failover interface"
			if [[ $(is_false ${local_device_name}) ]]; then
				local_device_name=`tmsh show /cm device all field-fmt|grep "cm device"|awk 'NR<2{print $3}'`
			fi
			if [[ $(is_false ${unicast_failover_addresses}) ]]; then
				unicast_failover_address=($address)
				tmsh modify /cm device ${local_device_name} unicast-address \
					 { { effective-ip ${address} effective-port 1026 ip ${address} } }
			else
				unicast_failover_addresses+=($address)
				ua_list="{"
				for i in ${unicast_failover_addresses[@]}; do
					ua_list="$ua_list { effective-ip ${i} effective-port 1026 ip ${i} }";
				done
				ua_list="${ua_list} }"
				tmsh modify /cm device ${local_device_name} unicast-address ${ua_list}               
			fi
		fi
		
		if [[ ${device_is_mirror_primary} == true ]]; then
			log "Configuring self IP $selfip_name as the device primary mirroring interface"
			if [[ $(is_false ${local_device_name}) ]]; then
				local_device_name=`tmsh show /cm device all field-fmt|grep "cm device"|awk 'NR<2{print $3}'`
			fi
			tmsh modify /cm device ${local_device_name} mirror-ip ${address}
		fi
		
		if [[ ${device_is_mirror_secondary} == true ]]; then
			log "Configuring self IP $selfip_name as the device secondary mirroring interface"
			if [[ $(is_false ${local_device_name}) ]]; then
				local_device_name=`tmsh show /cm device all field-fmt|grep "cm device"|awk 'NR<2{print $3}'`
			fi
			tmsh modify /cm device ${local_device_name} mirror-secondary-ip ${address}
		fi    
		
	fi
}

function set_tmm_if_vlan() {
	local tmm_if=$1

	unset vlan_prefix vlan_name vlan_description vlan_tag tagged vlan_tag_cmd tagged_cmd

	if [[ $tmm_if =~ $TMM_IF_REGEX ]]; then
		local vlan_prefix=$(get_user_data_value {bigip}{network}{vlan_prefix})
		local vlan_name=$(normalize_name "$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{vlan_name})")
		local vlan_description=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{vlan_description})
		local vlan_tag=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{vlan_tag})
		local tagged=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{tagged})
		local mtu=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{mtu})
		
		
		[[ $(is_false ${vlan_prefix}) ]] && vlan_prefix=$OS_VLAN_PREFIX
		[[ $(is_false ${vlan_name}) ]] && vlan_name="${vlan_prefix}${tmm_if}"
		[[ $(is_false ${vlan_description}) ]] && vlan_description=$OS_VLAN_DESCRIPTION
		[[ $(is_false ${mtu}) ]] && mtu=$OS_VLAN_MTU
		
		if [[ ${tagged} == true && tagged_cmd="{ tagged } " ]]; then
			if [[ ${vlan_tag} -ge 1 && ${vlan_tag} -le 4096 ]]; then
				vlan_tag_cmd=" tag $vlan_tag "
				log "Configuring VLAN $vlan_name with tag $vlan_tag on interface $tmm_if..."
			fi
		else
			log "Configuring VLAN $vlan_name on interface $tmm_if..."
		fi
		
		vlan_cmd="tmsh create net vlan $vlan_name interfaces add { $tmm_if $tagged_cmd}$vlan_tag_cmd description \"$vlan_description\" mtu $mtu"
		
		log "  $vlan_cmd"
		eval "$vlan_cmd 2>&1 | $LOGGER_CMD"
	fi
}

function dhcp_tmm_if() {
	[[ -f $OS_DHCP_LEASE_FILE ]] && rm -f $OS_DHCP_LEASE_FILE
	
	log "Issuing DHCP request on interface 1.${1:3}..."
	to_arg="-T"
	is_el6_dhclient=`rpm -q dhclient | grep el6 | wc -l`
	if [ $is_el6_dhclient == 1 ]
	then
		to_arg="-timeout"
	fi  
	dhclient_cmd="dhclient -lf $OS_DHCP_LEASE_FILE -cf /dev/null -1 $to_arg \
    $OS_DHCP_REQ_TIMEOUT -sf /bin/echo -R \
    subnet-mask,broadcast-address,interface-mtu,routers $1"
	eval "$dhclient_cmd 2>&1 | sed -e '/^$/d' -e 's/^/  /' | $LOGGER_CMD"
	pkill dhclient
	
	if [[ -f $OS_DHCP_LEASE_FILE ]]; then 
		dhcp_offer=`awk 'BEGIN {
      FS="\n"
      RS="}"
    }
    /lease/ {
      interface_mtu=""
      for (i=1;i<=NF;i++) {
        if ($i ~ /interface-mtu/) {
          sub(/;/,"",$i)
          split($i,INTMTU," ")
          interface_mtu=INTMTU[3]
        }
        else if ($i ~ /interface/) {
          gsub(/[";]/,"",$i)
          sub(/eth/, "1.", $i)
          split($i,INT," ")
          interface=INT[2]
        }
        else if ($i ~ /fixed/) {
          sub(/;/,"",$i)
          split($i,ADDRESS," ")
          address=ADDRESS[2]
        }
        else if ($i ~ /mask/) {
          sub(/;/,"",$i)
          split($i,NETMASK, " ")
          netmask=NETMASK[3]
        }
      }

      print interface " " address " " netmask " " interface_mtu
    }' $OS_DHCP_LEASE_FILE`
    
    rm -f $OS_DHCP_LEASE_FILE
    
    echo $dhcp_offer
  fi
}

function configure_tmm_ifs() {
	local tmm_ifs=$(ip link show | egrep '^[0-9]+: eth[1-9]' | cut -d ' ' -f2 |
						   tr -d  ':')
	
	local dhcp_enabled_global=$OS_DHCP_ENABLED
	local vlan_prefix=$(get_user_data_value {bigip}{network}{vlan_prefix})
	[[ $(is_false $vlan_prefix) ]] && vlan_prefix=$OS_VLAN_PREFIX
	
	[[ ${dhcp_enabled_global} == true && \
			 $(get_user_data_value {bigip}{network}{dhcp}) == false ]] && \
		dhcp_enabled_global=false
	
	# stop DHCP for management interface because only one dhclient process can run at a time
	log "Stopping DHCP client for management interface..."
	service dhclient stop  &> /dev/null
	sleep 1

	[[ ${dhcp_enabled_global} == false ]] &&
		log "DHCP disabled globally, will not auto-configure any interfaces..."

	for interface in ${tmm_ifs}; do
		local tmm_if="1.${interface:3}"
		local dhcp_enabled=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{dhcp})
		
		# setup VLAN
		tmsh list net vlan one-line | grep -q "interfaces { .*$1\.${interface:3}.* }"

		if [[ $? != 0 ]]; then
			log "Setup VLAN on interface $tmm_if..."
			set_tmm_if_vlan $tmm_if
		else
			log "VLAN already configured on interface $tmm_if, skipping..."
		fi

		# setup self-IP
		vlan_name=$(normalize_name "$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{vlan_name})")
		[[ $(is_false $vlan_name) ]] && vlan_name="${vlan_prefix}${tmm_if}"
		tmsh list net self one-line | grep -q "vlan $vlan_name"

		if [[ $? != 0 ]]; then

			log "Configuring self IP for interface $tmm_if..."

			if [[ $dhcp_enabled_global == false || $dhcp_enabled == false ]]; then
				# DHCP is disabled, look for static address and configure it
				address=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{address})
				netmask=$(get_user_data_value {bigip}{network}{interfaces}{$tmm_if}{netmask})

				if [[ -n $address && -n $netmask ]]; then
					set_tmm_if_selfip $tmm_if $address $netmask
				else
					log "DHCP is disabled and no static address could be located for $tmm_if, skipping..."
				fi
			else
				set_tmm_if_selfip $(dhcp_tmm_if $interface)
				sleep 2
			fi
		else
			log "Self IP already configured for interface $tmm_if, skipping..."
		fi
	done

	# restart DHCP for management interface
	#log "Restarting DHCP client for management interface..."
	#service dhclient restart &> /dev/null
	tmsh modify sys db dhclient.mgmt { value disable }
	log "Saving after configuring interfaces"
	tmsh save sys config | eval $LOGGER_CMD
}


# Change the management MTU.
function force_mgmt_mtu() {

	# Search for interface_mtu within the lease declaration
	    mgmt_mtu=`awk 'BEGIN {
      FS="\n"
      RS="}"
    }
    /lease/ {
      interface_mtu=""
      for (i=1;i<=NF;i++) {
        if ($i ~ /interface-mtu/) {
          sub(/;/,"",$i)
          split($i,INTMTU," ")
          interface_mtu=INTMTU[3]
        }
      }

      print interface_mtu
    }' $OS_MGMT_LEASE_FILE`

		# Is the management interface mtu is set by DHCP?
		if [[ $mgmt_mtu =~ ^[0-9]+$ ]]; then
			# Yes, honor it.
			log "Setting Management interface MTU per DHCP to $mgmt_mtu"
			ip link set eth0 mtu $mgmt_mtu
		else
			# No, use a smaller sized MTU
			log "Setting Management interface MTU to default $mgmt_mtu"
			ip link set eth0 mtu $OS_MGMT_MTU
		fi
}

function configure_global_routes() {
	local routes=$(get_user_data_network_routes)
	for route in $(echo $routes | tr "|" "\n"); do
		re=($(echo $route | tr ";" "\n"));
		if [[ ! $(is_false ${re[1]}) ]]; then
			log "Adding global route destination ${re[0]} gateway ${re[1]}..."
			tmsh create /net route ${re[0]} gw ${re[1]}
		fi
	done
}

function test() {
	configure_tmm_ifs
	if [[ $? == 0 ]]; then
		echo "configure-tmm-ifs succeeded"
	else
		echo "configure-tmm-ifs failed"
	fi
}

# test
