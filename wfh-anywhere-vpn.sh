#!/usr/bin/env bash

WIREGUARD_IP=${WIREGUARD_IP}
WIREGUARD_INTERFACE_NAME=${WIREGUARD_INTERFACE_NAME}
NS=phy

stop_network_managers() {
    # Stop network managers that could get in our way
    systemctl stop NetworkManager.service
    systemctl stop systemd-networkd.socket
    systemctl stop systemd-networkd.service
    systemctl stop systemd-resolved.service

    systemctl is-active systemd-networkd
    if [[ ${?} != 3 ]]
    then
        echo "systemd-networkd is still running"
        exit 1
    fi
    systemctl is-active NetworkManager
    if [[ ${?} != 3 ]]
    then
        echo "Network Manager is still running"
        exit 1
    fi
    systemctl is-active systemd-resolved.service
    if [[ ${?} != 3 ]]
    then
        echo "Systemd resolver is still running"
        exit 1
    fi
}


dhcp() {
    case ${1} in
        up)
            ip netns exec phy dhclient -pf /var/run/dhclient.pid -4 -nw
            ;;
        down)
            ip netns exec phy dhclient -pf /var/run/dhclient.pid -r
            ;;
        restart)
            ip netns exec phy dhclient -pf /var/run/dhclient.pid -r
            ip netns exec phy dhclient -pf /var/run/dhclient.pid -4 -nw
            ;;
        *)
            echo "oh no, this options is not supported"
            ;;
    esac
}

ensure_netns_exists() {
    NS_EXIST=$(ip netns list|grep -c ${NS})
    if [[ ${NS_EXIST} == 0 ]]
    then
        ip netns add ${NS}
    fi
}

move_ifs_to_netns() { 
    case ${1} in
        start)

            ensure_netns_exists

            while true
            do
                IFs=$(ls -l /sys/class/net/|grep -v -e virtual -e wlan0 | awk '{print $9}')
                for IF in $IFs
                do
                    echo ${IF}
                    ip link set dev ${IF} down
                    ip link set ${IF} netns ${NS}
                    ip -n ${NS} link set dev ${IF} mtu 1500
                done
                [[ $(echo ${IFs}|wc -w) -gt 0 ]] && dhcp restart
                sleep 5
            done
            ;;
        stop)
            IFs=$(ip netns exec ${NS} ls -l /sys/class/net/|grep -v -e virtual -e wlan0 | awk '{print $9}')
            for IF in $IFs
            do
                echo ${IF}
                ip -n ${NS} link set dev ${IF} down
                ip -n ${NS} link set ${IF} netns 1
            done
            dhcp stop
            ;;
        *)
            echo "missing options for netns"
            ;;
    esac
}

wg_vpn() {
    ensure_netns_exists

    #Wireguard setup
    ip -n ${NS} link add ${WIREGUARD_INTERFACE_NAME} type wireguard
    ip -n ${NS} link set ${WIREGUARD_INTERFACE_NAME} netns 1
    wg setconf ${WIREGUARD_INTERFACE_NAME} <(wg-quick strip /etc/wireguard/${WIREGUARD_INTERFACE_NAME}.conf)

    iptables -I INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
    iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    sleep 1

    ip addr add ${WIREGUARD_IP}/32 dev ${WIREGUARD_INTERFACE_NAME}
    ip link set dev ${WIREGUARD_INTERFACE_NAME} mtu 1500
    ip link set ${WIREGUARD_INTERFACE_NAME} up
    ip route add default dev ${WIREGUARD_INTERFACE_NAME}

    sysctl -w net.ipv4.ip_forward=1
}

hotspot() {
	# prep the wlan0 interface for hostapd and dnsmasq by giving it an IP
	ip addr add 10.0.0.1/24 dev wlan0
	hostapd -B /etc/hostapd/simple.conf
	sleep 1
    echo "nameserver 127.0.0.53" > /etc/resolv.conf
	systemctl restart dnsmasq.service

	# enable local port forward from WiFi to Wireguard
    iptables -t mangle -A PREROUTING -i wlan0 -j MARK --set-mark 0x30
    iptables -t nat -A POSTROUTING ! -o wlan0 -m mark --mark 0x30 -j MASQUERADE
}

down() {
    IF=$(ip -n ${NS} link|grep enx|cut -d: -f2|tr -d ' ')

    IP_CIDR=$(ip -n ${NS} addr show ${IF}|grep -Eo "([0-9.]{7,25})/([0-9]{1,2})")
    IP=${IP_CIDR%/*}
    CIDR=${IP_CIDR#*/}

    sysctl -w net.ipv4.ip_forward=0

    iptables -t mangle -D PREROUTING -i wlan0 -j MARK --set-mark 0x30
    iptables -t nat -D POSTROUTING ! -o wlan0 -m mark --mark 0x30 -j MASQUERADE

    iptables -D INPUT -p udp --dport ${WIREGUARD_PORT} -j ACCEPT
    iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    killall hostapd

    ip addr del 10.0.0.1/24 dev wlan0
    ip route del default dev ${WIREGUARD_INTERFACE_NAME}
    ip link set ${WIREGUARD_INTERFACE_NAME} down
    ip addr del ${WIREGUARD_IP}/32 dev ${WIREGUARD_INTERFACE_NAME}

    ip link del ${WIREGUARD_INTERFACE_NAME} type wireguard

    ip -n ${NS} link set dev ${IF} down
    ip -n ${NS} link set dev eth0 down
    ip -n ${NS} addr del ${IP_CIDR} dev ${IF}

    ip -n ${NS} link set ${IF} netns 1
    ip -n ${NS} link set eth0 netns 1
    ip netns del ${NS}

    systemctl stop dnsmasq.service

    # This ought to be fine if the script is just stopped with 
    # systemctl stop ...
    # but this code also is ran when rebooting or powering down 
    # and then it messes up the process causing timout with waiting for this
    # job to stop
    #systemctl restart NetworkManager.service
    #systemctl restart systemd-networkd.socket
    #systemctl restart systemd-networkd.service
    #systemctl restart systemd-resolved.service

    dhclient -x
    dhclient

    echo "If you whish to disable the VPN then disable its service"
    echo "with systemctl and then reboot."
}


case ${1} in
    start)
        stop_network_managers
        wg_vpn
        hotspot
        move_ifs_to_netns start
        ;;
    stop)
        move_ifs_to_netns stop
        down
        ;;
    restart)
        down
        stop_network_managers
        wg_vpn
        hotspot
        move_ifs_to_netns start
        ;;
    *)
        echo "oh no, this option is not supported"
        ;;
esac
