#!/usr/bin/env bash


# Functions START
prerequisites(){ 

    mkdir -p ${OUTPUT_DIR}
    if [[ ! -f ${USER_ANSWERS_FILE} ]]; then
        touch ${USER_ANSWERS_FILE}
    fi
}

install_requirements() {
    echo "*** Installing required tools"
    # iproute2 provide the "ip" tool 
    # gettext-base provides the "envsubst" tool
    apt update
    apt install -y \
        wireguard \
        iptables \
        sed \
        iproute2 \
        gettext-base
}

hostapd_configuration() {
    node_id=${1}
    export HOTSPOT_NAME HOTSPOT_PASSWORD
    cat ./hostapd.conf | envsubst > ${OUTPUT_DIR}/${node_id}/hostapd.conf
}

wireguard_router_config() {
    node_id=${1}
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/${node_id}/${WIREGUARD_INTERFACE_NAME}.conf
[Interface]
PrivateKey = $(cat ${OUTPUT_DIR}/${node_id}/private)
ListenPort = ${WIREGUARD_PORT}

# IP forwarding
PreUp = sysctl -w net.ipv4.ip_forward=1

# IPv4 masquerading
PreUp = iptables -t mangle -A PREROUTING -i wlan0 -j MARK --set-mark 0x30
PreUp = iptables -t nat -A POSTROUTING ! -o wlan0 -m mark --mark 0x30 -j MASQUERADE
PostDown = iptables -t mangle -D PREROUTING -i wlan0 -j MARK --set-mark 0x30
PostDown = iptables -t nat -D POSTROUTING ! -o wlan0 -m mark --mark 0x30 -j MASQUERADE

PreUp = iptables -I INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PreUp = iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PostDown = iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

[Peer]
$( [[ -f $OUTPUT_DIR/${next_node_id}/public_ip ]] && echo "Endpoint = $(cat $OUTPUT_DIR/${next_node_id}/public_ip):${WIREGUARD_PORT}" )
$( [[ ! -f $OUTPUT_DIR/${node_id}/public_ip ]] && echo "PersistentKeepalive = 25" )
PublicKey = $(cat ${OUTPUT_DIR}/${next_node_id}/public)
AllowedIPs = 0.0.0.0/0
EOF
}

wireguard_middle_man_config() {
    node_id=${1}
    previous_node_id=$((${1}-1))
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/${node_id}/${WIREGUARD_INTERFACE_NAME}.conf
[Interface]
Address = $(cat ${OUTPUT_DIR}/${node_id}/wireguard_ip)
ListenPort = ${WIREGUARD_PORT}
PrivateKey = $(cat ${OUTPUT_DIR}/${node_id}/private)
Table = \${RANDOM_TABLE_ID}
MTU = 1500

# IP forwarding
PreUp = sysctl -w net.ipv4.ip_forward=1

PreUp = ip rule add iif ${WIREGUARD_INTERFACE_NAME} table \${RANDOM_TABLE_ID} priority 10
PreUp = iptables -I INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PreUp = iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = ip rule del iif ${WIREGUARD_INTERFACE_NAME} table \${RANDOM_TABLE_ID} priority 10
PostDown = iptables -D INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PostDown = iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# previous node
[Peer]
PublicKey = $(cat $OUTPUT_DIR/${previous_node_id}/public)
AllowedIPs = $(cat $OUTPUT_DIR/${previous_node_id}/wireguard_ip)/${WIREGUARD_NETMASK}
$( [[ -f $OUTPUT_DIR/${previous_node_id}/public_ip ]] && echo "Endpoint = $(cat $OUTPUT_DIR/${previous_node_id}/public_ip):${WIREGUARD_PORT}" )
$( [[ ! -f $OUTPUT_DIR/${node_id}/public_ip ]] && echo "PersistentKeepalive = 25" )
# next node
[Peer]
PublicKey = $(cat $OUTPUT_DIR/${next_node_id}/public)
AllowedIPs = 0.0.0.0/0
$( [[ -f $OUTPUT_DIR/${next_node_id}/public_ip ]] && echo "Endpoint = $(cat $OUTPUT_DIR/${next_node_id}/public_ip):${WIREGUARD_PORT}" )
$( [[ ! -f $OUTPUT_DIR/${node_id}/public_ip ]] && echo "PersistentKeepalive = 25" )
EOF
}

wireguard_last_node_config() {
    node_id=${1}
    previous_node_id=$((${1}-1))
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/${node_id}/${WIREGUARD_INTERFACE_NAME}.conf
[Interface]
Address = $(cat ${OUTPUT_DIR}/${node_id}/wireguard_ip)
ListenPort = ${WIREGUARD_PORT}
PrivateKey = $(cat ${OUTPUT_DIR}/${node_id}/private)
MTU = 1500

# IP forwarding
PreUp = sysctl -w net.ipv4.ip_forward=1

# IPv4 masquerading
PreUp = iptables -t mangle -A PREROUTING -i ${WIREGUARD_INTERFACE_NAME} -j MARK --set-mark 0x30
PreUp = iptables -t nat -A POSTROUTING ! -o ${WIREGUARD_INTERFACE_NAME} -m mark --mark 0x30 -j MASQUERADE
PostDown = iptables -t mangle -D PREROUTING -i ${WIREGUARD_INTERFACE_NAME} -j MARK --set-mark 0x30
PostDown = iptables -t nat -D POSTROUTING ! -o ${WIREGUARD_INTERFACE_NAME} -m mark --mark 0x30 -j MASQUERADE

PreUp = iptables -I INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PreUp = iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
PostDown = iptables -D INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
PostDown = iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# previous node
[Peer]
PublicKey = $(cat $OUTPUT_DIR/${previous_node_id}/public)
AllowedIPs = $(cat $OUTPUT_DIR/${previous_node_id}/wireguard_ip)/${WIREGUARD_NETMASK}
$( [[ -f $OUTPUT_DIR/${previous_node_id}/public_ip ]] && echo "Endpoint = $(cat $OUTPUT_DIR/${previous_node_id}/public_ip):${WIREGUARD_PORT}" )
$( [[ ! -f $OUTPUT_DIR/${node_id}/public_ip ]] && echo "PersistentKeepalive = 25" )
EOF
}

dnsmasq_configuration() {
    node_id=${1}
cat << EOF > ${OUTPUT_DIR}/${node_id}/dnsmasq.conf
dhcp-leasefile=/var/lib/misc/dnsmasq.wlan0.leases
#interface=wlan0
#bind-interfaces
listen-address=10.0.0.1,127.0.0.53,127.0.0.1
dhcp-range=10.0.0.10,10.0.0.128,24h
dhcp-option=6,10.0.0.1

port=53
domain-needed
bogus-priv
expand-hosts
cache-size=1000
server=8.8.4.4
server=1.1.1.1
server=8.8.8.8
EOF
}

generate_router_node_install_script() {
export WIREGUARD_IP=$(cat ${OUTPUT_DIR}/${NODE_ID}/wireguard_ip)
export WIREGUARD_INTERFACE_NAME
export WIREGUARD_PORT

cat << EOFX > ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
#!/usr/bin/env bash

set -e

# On Ubuntu server when a phone tethers USB connection the newly added interface
# is not being automatically configured and so we need to run dhclient 
[[ -x \$(which dhclient) ]] && echo "Running dhclient to configure interfaces" && dhclient

echo "Checking internet connection. If this stops here then there was a problem sending ping to 8.8.8.8"
ping -c 2 -W 2 -q 8.8.8.8

apt update
# psmisc provides the "killall" tool
# coreutils provides the "shuf" tool
apt install -y \
    wireguard \
    iptables \
    hostapd \
    dnsmasq \
    psmisc \
    coreutils  

cat << EOF > /usr/lib/systemd/system/wfh-anywhere-vpn-${WIREGUARD_INTERFACE_NAME}.service
$(cat ${SERVICE_FILE})
EOF

cat << EOF > /etc/wireguard/${WIREGUARD_INTERFACE_NAME}.conf
$(cat ${OUTPUT_DIR}/${NODE_ID}/${WIREGUARD_INTERFACE_NAME}.conf)
EOF


cat << EOF > /usr/local/bin/wfh-anywhere-vpn.sh
$(cat ./wfh-anywhere-vpn.sh | envsubst '${WIREGUARD_INTERFACE_NAME},${WIREGUARD_IP},${WIREGUARD_PORT}' | sed 's/\$/\\$/g')
EOF
chmod u+x /usr/local/bin/wfh-anywhere-vpn.sh

cat << EOF > /etc/hostapd/hostapd.conf
$(cat ${OUTPUT_DIR}/${NODE_ID}/hostapd.conf)
EOF

cat << EOF > /etc/dnsmasq.d/10-dhcp_and_dns_cache.conf
$(cat ${OUTPUT_DIR}/${NODE_ID}/dnsmasq.conf)
EOF

systemctl enable wfh-anywhere-vpn-${WIREGUARD_INTERFACE_NAME}
systemctl start wfh-anywhere-vpn-${WIREGUARD_INTERFACE_NAME}
systemctl status wfh-anywhere-vpn-${WIREGUARD_INTERFACE_NAME}

systemctl unmask hostapd
systemctl enable hostapd
systemctl start hostapd
EOFX
chmod u+x ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
}

generate_every_next_node_install_script() {
cat << EOFX > ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
#!/usr/bin/env bash

set -e

apt update
# coreutils provides the "shuf" tool
apt install -y \
    wireguard \
    iptables \
    coreutils

set +e

get_unique_route_table_id() {
    continue=0
    while [[ \${continue} == 0 ]]; do
        export RANDOM_TABLE_ID=\$(shuf -i 10-240 -n 1)
        ip route show table all | grep -q "table \${RANDOM_TABLE_ID}"
        continue=\${?}
    done
}

get_unique_route_table_id

cat << EOF > /etc/wireguard/${WIREGUARD_INTERFACE_NAME}.conf

$(cat ${OUTPUT_DIR}/${NODE_ID}/${WIREGUARD_INTERFACE_NAME}.conf)
EOF

systemctl enable wg-quick@${WIREGUARD_INTERFACE_NAME}
systemctl start wg-quick@${WIREGUARD_INTERFACE_NAME}
systemctl status wg-quick@${WIREGUARD_INTERFACE_NAME}
EOFX
chmod u+x ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
}

get_input() {
    # $1 - prompt to display
    # $2 - variable to hold the response
    read -p "${1}: " ${2}
}

save_user_answer_to_shared_file() {
    # $1 - variable name
    # $2 - variable's value

   grep -q ${1} ${USER_ANSWERS_FILE}

   if [[ ${?} == 1 ]]; then
       echo "${1}=${2}" >> ${USER_ANSWERS_FILE}
   else
       sed -i "s/${1}.*/${1}=${2}/g" ${USER_ANSWERS_FILE}
   fi
}

save_user_answer_to_separate_file() {
	# $1 - node id
	# $2 - file name
	# $3 - file value
	echo "${3}" > ${OUTPUT_DIR}/${1}/${2}
}

get_and_save_user_input() {
    # $1 - prompt to display
    # $2 - variable or file name (see next option)
    # $3 - 'shared' to save to shared configuration file or "new" to save to new file in specific node's directory
    # $4 - default value
    # $5 - if parameter $3 was set to "new" then this should be containing the node_id

    default_value=${4}
    get_input "${1} (default: ${default_value})" ${2}

    user_input=${!2}
    final_value=${user_input:-${default_value}}

    export ${2}=${final_value}

    if [[ ${3} == 'shared' ]]; then
        save_user_answer_to_shared_file ${2} "${final_value}"
    elif [[ ${3} == 'new' ]]; then
        save_user_answer_to_separate_file ${5} ${2} "${final_value}"
    fi
}

get_and_save_user_input_if_missing() {
    # $1 - prompt to display
    # $2 - variable or file name (see next option)
    # $3 - 'shared' to save to shared configuration file or "new" to save to new file in specific node's directory
    # $4 - default value
    # $5 - if parameter $3 was set to "new" then this should be containing the node_id
    #
    # return 0 if new value saved (default) or 2 if  existing value was found
    if [[ ${3} == 'shared' ]]; then
        grep -q "${2}=.\+" ${USER_ANSWERS_FILE}
    elif [[ ${3} == 'new' ]]; then
        ls ${OUTPUT_DIR}/${5}/${2} > /dev/null 2>&1
    fi

    if [[ ${?} != 0 ]]; then
        get_and_save_user_input "${1}" ${2} ${3} ${4} ${5}
    else
        return 2
    fi
}

collect_data_from_user() {
    get_and_save_user_input_if_missing "Enter node count" NODE_COUNT shared 3
    echo "Warning! Make sure the interface name is unique across all nodes you will deploy this VPN. If there is a conflict your existing configuration may be overwritten!"
    get_and_save_user_input_if_missing "Wireguard interface name" WIREGUARD_INTERFACE_NAME shared "wfhavpn0"
    get_and_save_user_input_if_missing "Wireguard network CIDR" WIREGUARD_CIDR shared "192.168.200.0/24"
    get_and_save_user_input_if_missing "Wireguard port" WIREGUARD_PORT shared "51820"
    get_and_save_user_input_if_missing "WiFi hotspot name/SSID" HOTSPOT_NAME shared "WFH-Anywhere"
    random_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)
    get_and_save_user_input_if_missing "WiFi hotspot password" HOTSPOT_PASSWORD shared "${random_password}"
}

wireguard_generate_keys() {
    # $1 - node id
    echo "Generating keys for node ${1}"
    wg genkey > ${OUTPUT_DIR}/${1}/private 2>/dev/null
    cat ${OUTPUT_DIR}/${1}/private | wg pubkey > ${OUTPUT_DIR}/${1}/public
}

get_next_ip() {
    # $1 - first IP
    # $2 - node id
    o1=$(echo ${1}|cut -d. -f1)
    o2=$(echo ${1}|cut -d. -f2)
    o3=$(echo ${1}|cut -d. -f3)
    o4=$(echo ${1}|cut -d. -f4)

    echo "${o1}.${o2}.${o3}.$((o4+${2}*10))" > ${OUTPUT_DIR}/${2}/wireguard_ip
}
# Functions END



#=============================================================================



# Prepare and collect data START
SERVICE_FILE=./wfh-anywhere-vpn-router.service
OUTPUT_DIR=./output
USER_ANSWERS_FILE=${OUTPUT_DIR}/configuration.ini

prerequisites
install_requirements
collect_data_from_user
# Prepare and collect data END


# Generate configs and scripts START
source ${USER_ANSWERS_FILE}

WIREGUARD_NETMASK=$(echo ${WIREGUARD_CIDR}|cut -d/ -f2)

# Generate keys and IPs that will be required for template generation
NEXT_NODE_MUST_HAVE_PUBLIC_IP=false
for ((NODE_ID=1; NODE_ID<=${NODE_COUNT}; NODE_ID++)); do
    mkdir -p ${OUTPUT_DIR}/${NODE_ID}
    wireguard_generate_keys ${NODE_ID}
    get_next_ip "${WIREGUARD_CIDR}" ${NODE_ID}

    echo "Node ${NODE_ID}"

    if [[ ${NEXT_NODE_MUST_HAVE_PUBLIC_IP} == false ]]; then
        get_and_save_user_input_if_missing "Does node ${NODE_ID} have public IP (y/n)?" NODE_${NODE_ID}_HAS_PUBLIC_IP shared y
    else
        export NODE_${NODE_ID}_HAS_PUBLIC_IP='y'
    fi

    THIS_NODE_HAS_PUBLIC_IP=NODE_${NODE_ID}_HAS_PUBLIC_IP

    if [[ ${!THIS_NODE_HAS_PUBLIC_IP} == 'n' && ${NEXT_NODE_MUST_HAVE_PUBLIC_IP} == true ]]; then
        echo "Error. This node must have public IP."
        exit 1
    fi

    if [[ ${!THIS_NODE_HAS_PUBLIC_IP} == 'y' || ${NEXT_NODE_MUST_HAVE_PUBLIC_IP} == true ]]; then
        NEXT_NODE_MUST_HAVE_PUBLIC_IP=false
        get_and_save_user_input_if_missing "Provide public address of node ${NODE_ID}" public_ip new "-" ${NODE_ID} 

        # RC=2 from the command above will return true if value already existed
        # hence no need to verify again here which would cause problems
        if [[ ${?} != 2 ]]; then
            echo ${public_ip} | grep -qsEo "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$"
            [[ ${?} != 0 ]] && echo "This is not a valid IP address. Edit or remove ./output/configuration.ini to continue or start fresh." && exit 1
        fi
    else
        NEXT_NODE_MUST_HAVE_PUBLIC_IP=true
    fi
done


# Render templates
for ((NODE_ID=1; NODE_ID<=${NODE_COUNT}; NODE_ID++)); do
    if [[ ${NODE_ID} == 1 ]]; then
        hostapd_configuration 1
        dnsmasq_configuration 1
        wireguard_router_config ${NODE_ID}
        generate_router_node_install_script
    elif [[ ${NODE_ID} < ${NODE_COUNT} ]]; then
        wireguard_middle_man_config ${NODE_ID}
        generate_every_next_node_install_script
    else
        wireguard_last_node_config ${NODE_ID}
        generate_every_next_node_install_script
    fi
done
# Generate configs and scripts END
