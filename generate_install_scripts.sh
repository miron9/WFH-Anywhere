WIREGUARD_IF_NAME=wgvpn0
OUTPUT_DIR=./output
SERVICE_FILE=./vpn-miron.service

set -x
generate_router_node_install_script() {
cat << EOFX > ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
apt update
apt install wireguard -y

cat << EOF > /usr/lib/systemd/system/${WIREGUARD_IF_NAME}.service
$(cat ${SERVICE_FILE})
EOF

cat << EOF > /etc/wireguard/${WIREGUARD_IF_NAME}.service
$(cat ${OUTPUT_DIR}/${NODE_ID}/${WIREGUARD_IF_NAME}.conf)
EOF


cat << EOF1 > /usr/local/bin/wfh-anywhere-vpn.sh
$(cat ./wfh-anywhere-vpn.sh)
EOF1
chmod u+x /usr/local/bin/wfh-anywhere-vpn.sh

systemctl enable wfh-anywhere-vpn
systemctl start wfh-anywhere-vpn
systemctl status wfh-anywhere-vpn

systemctl enable wg-quick@${WIREGUARD_IF_NAME}
systemctl start wg-quick@${WIREGUARD_IF_NAME}
systemctl status wg-quick@${WIREGUARD_IF_NAME}
EOFX
}


generate_every_next_node_install_script() {
cat << EOFX > ./${OUTPUT_DIR}/${NODE_ID}/generated_wireguard_vpn_install_script.sh
apt update
apt install wireguard -y

cat << EOF > /etc/wireguard/${WIREGUARD_IF_NAME}.service
$(cat ${OUTPUT_DIR}/${NODE_ID}/${WIREGUARD_IF_NAME}.conf)
EOF

systemctl enable wg-quick@${WIREGUARD_IF_NAME}
systemctl start wg-quick@${WIREGUARD_IF_NAME}
systemctl status wg-quick@${WIREGUARD_IF_NAME}
EOFX
}

NODE_ID=1
generate_router_node_install_script
NODE_ID=2
generate_every_next_node_install_script
