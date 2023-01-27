#!/usr/bin/env bash

#WIREGUARD_PORT=45162
WIREGUARD_IF_NAME=wgvpn0
WIREGUARD_PORT=51820
WIREGUARD_MIDDLE_MAN_IP=178.62.29.162
WIREGUARD_START_IP=192.168.5.0/24

CIDR=$(echo ${WIREGUARD_START_IP}|cut -d/ -f2)

OUTPUT_DIR=./output
USER_ANSWERS_FILE=${OUTPUT_DIR}/configuration.ini

prerequsites(){
    mkdir -p ${OUTPUT_DIR}
    if [[ ! -f ${USER_ANSWERS_FILE} ]]; then
        touch ${USER_ANSWERS_FILE}
    fi
}

install_requirements() {
    apt update
    apt install isc-dhcp-common dnsmasq hostapd iptables iproute2 wireguard sed -y
}

hostapd() {
    # ask for password
    cp ./hostapd.conf /etc/hostapd/
}

systemd() {
    cp ./vpn-miron.service /usr/lib/systemd/system/
    systemctl enable vpn-miron.service
}

wireguard_router_config() {
    node_id=${1}
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/1/${WIREGUARD_IF_NAME}.conf
[Interface]
PrivateKey = $(cat ${OUTPUT_DIR}/1/private)
ListenPort = ${WIREGUARD_PORT}

[Peer]
PublicKey = $(cat ${OUTPUT_DIR}/${next_node_id}/public)
Endpoint = ${WIREGUARD_MIDDLE_MAN_IP}:${WIREGUARD_PORT}
AllowedIPs = 0.0.0.0/0
EOF
}

wireguard_middle_man_config() {
    node_id=${1}
    previous_node_id=$((${1}-1))
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/${node_id}/${WIREGUARD_IF_NAME}.conf
[Interface]
Address = $(cat ${OUTPUT_DIR}/${node_id}/wireguard_ip)
ListenPort = ${WIREGUARD_PORT}
PrivateKey = $(cat ${OUTPUT_DIR}/${node_id}/private)
Table = 123

PreUp = sysctl -w net.ipv4.ip_forward=1
PreUp = ip rule add iif ${WIREGUARD_IF_NAME} table 123 priority 456
PostDown = ip rule del iif ${WIREGUARD_IF_NAME} table 123 priority 456

# previous node
[Peer]
PublicKey = $(cat $OUTPUT_DIR/${previous_node_id}/public)
AllowedIPs = $(cat $OUTPUT_DIR/${previous_node_id}/wireguard_ip)/${CIDR}

# next node
[Peer]
PublicKey = $(cat $OUTPUT_DIR/${next_node_id}/public)
AllowedIPs = 0.0.0.0/0
EOF
}

wireguard_last_node_config() {
    node_id=${1}
    previous_node_id=$((${1}-1))
    next_node_id=$((${1}+1))
cat << EOF > ${OUTPUT_DIR}/${node_id}/${WIREGUARD_IF_NAME}.conf
[Interface]
Address = $(cat ${OUTPUT_DIR}/${node_id}/wireguard_ip)
ListenPort = ${WIREGUARD_PORT}
PrivateKey = $(cat ${OUTPUT_DIR}/${node_id}/private)

# IP forwarding
PreUp = sysctl -w net.ipv4.ip_forward=1
# IPv4 masquerading
PreUp = iptables -t mangle -A PREROUTING -i ${WIREGUARD_IF_NAME} -j MARK --set-mark 0x30
PreUp = iptables -t nat -A POSTROUTING ! -o ${WIREGUARD_IF_NAME} -m mark --mark 0x30 -j MASQUERADE
PostDown = iptables -t mangle -D PREROUTING -i ${WIREGUARD_IF_NAME} -j MARK --set-mark 0x30
PostDown = iptables -t nat -D POSTROUTING ! -o ${WIREGUARD_IF_NAME} -m mark --mark 0x30 -j MASQUERADE

# previous node
[Peer] 
PublicKey = $(cat $OUTPUT_DIR/${previous_node_id}/public)
Endpoint = 178.62.29.162:45162
AllowedIPs = $(cat $OUTPUT_DIR/${previous_node_id}/wireguard_ip)/${CIDR}
PersistentKeepalive = 25
EOF
}

get_input() {
    # $1 - prompt to display
    # $2 - variable to hold the response
    read -p "${1}: " ${2}
}

save_user_answer() {
    # $1 - variable name
    # $2 - variable's value

   grep -q ${1} ${USER_ANSWERS_FILE}

   if [[ ${?} == 1 ]]; then
       echo "${1}=${2}" >> ${USER_ANSWERS_FILE}
   else
       sed -i "s/${1}.*/${1}=${2}/g" ${USER_ANSWERS_FILE}
   fi
}

get_and_save_user_input() {
    # $1 - prompt to display
    # $2 - variable name
    get_input "${1}" ${2}
    save_user_answer ${2} "${!2}"
}

get_and_save_user_input_if_missing() {
    # $1 - prompt to display
    # $2 - variable name
    grep -q "${2}=.\+" ${USER_ANSWERS_FILE}

    if [[ ${?} == 1 ]]; then
        get_and_save_user_input "${1}" ${2}
    fi
}

collect_data_from_user() {
    get_and_save_user_input_if_missing "Enter node count" NODE_COUNT
}

wireguard() {
    wireguard_router_config
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

#install_requirements
prerequsites
collect_data_from_user

source ${USER_ANSWERS_FILE}

NEXT_NODE_MUST_HAVE_PUBLIC_IP=false
for ((NODE_ID=1; NODE_ID<=${NODE_COUNT}; NODE_ID++)); do
    echo "Node ${NODE_ID}"
    mkdir -p ${OUTPUT_DIR}/${NODE_ID}

    echo "nest node must have ip: ${NEXT_NODE_MUST_HAVE_PUBLIC_IP}"

    if [[ ${NEXT_NODE_MUST_HAVE_PUBLIC_IP} == false ]]; then
        get_and_save_user_input_if_missing "Does node ${NODE_ID} have public IP" NODE_${NODE_ID}_HAS_PUBLIC_IP
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
        get_and_save_user_input_if_missing "Provide public address of node ${NODE_ID}" NODE_${NODE_ID}_PUBLIC_IP

        THIS_NODE_IP=NODE_${NODE_ID}_PUBLIC_IP
        if [[ -z ${!THIS_NODE_IP} ]]; then
            echo "DUPA, zabawy nie ma"
            exit 1
        fi
    else
        NEXT_NODE_MUST_HAVE_PUBLIC_IP=true
    fi


    wireguard_generate_keys ${NODE_ID}
    get_next_ip "${WIREGUARD_START_IP}" ${NODE_ID}

    if [[ ${NODE_ID} == 1 ]]; then
        wireguard_router_config ${NODE_ID}
    elif [[ ${NODE_ID} < ${NODE_COUNT} ]]; then
        wireguard_middle_man_config ${NODE_ID}
    else
        wireguard_last_node_config ${NODE_ID}
    fi
done


#hostapd
#systemd

#wireguard
