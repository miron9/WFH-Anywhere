#!/usr/bin/env bash
set -x

WG_IP=${WG_IP}
NS=phy
WG_IF_NAME=wgvpn0

function stop_network_managers() {
    # Stop network managers that could get in our way
    systemctl stop NetworkManager
    systemctl stop systemd-networkd

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
}


function dhcp() {
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

function ensure_netns_exists() {
    NS_EXIST=$(ip netns list|grep -c ${NS})
    if [[ ${NS_EXIST} == 0 ]]
    then
        ip netns add ${NS}
    fi
}

function move_ifs_to_netns() { 
    case ${1} in
        start)
            echo $BASHPID > /tmp/ensure_netns.pid

            ensure_netns_exists

            while true
            do
                IFs=$(ls -l /sys/class/net/|grep -v -e virtual -e wlan0 | awk '{print $9}')
                for IF in $IFs
                do
                    echo ${IF}
                    ip link set dev ${IF} down
                    ip link set ${IF} netns ${NS}
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
            kill $(cat /tmp/ensure_netns.pid)
            ;;
        *)
            echo "missing options for netns"
            ;;
    esac
}

function wg_vpn() {
    ensure_netns_exists
    #Wireguard setup
    ip -n ${NS} link add ${WG_IF_NAME} type wireguard
    ip -n ${NS} link set ${WG_IF_NAME} netns 1
    wg setconf ${WG_IF_NAME} /etc/wireguard/wgvpn0.conf
    sleep 1
    ip addr add ${WG_IP}/32 dev ${WG_IF_NAME}
    ip link set ${WG_IF_NAME} up
    ip route add default dev ${WG_IF_NAME}
}

function hotspot() {
	# prep the wlan0 interface for hostapd and dnsmasq by giving it an IP
	ip addr add 10.0.0.1/24 dev wlan0
	hostapd -B /etc/hostapd/simple.conf
	sleep 1
	systemctl restart dnsmasq.service

	# enable local port forward from WiFi to Wireguard
	iptables -I FORWARD 1 -i wlan0 -o ${WG_IF_NAME} -j ACCEPT
	iptables -I FORWARD 1 -i ${WG_IF_NAME} -o wlan0 -j ACCEPT
	iptables -t nat -I POSTROUTING 1 -s 10.0.0.1/24 -o ${WG_IF_NAME} -j MASQUERADE
}

function down() {
    IF=$(ip -n ${NS} link|grep enx|cut -d: -f2|tr -d ' ')

    IP_CIDR=$(ip -n ${NS} addr show ${IF}|grep -Eo "([0-9.]{7,25})/([0-9]{1,2})")
    IP=${IP_CIDR%/*}
    CIDR=${IP_CIDR#*/}

    iptables -D FORWARD -i wlan0 -o ${WG_IF_NAME} -j ACCEPT
    iptables -D FORWARD -i ${WG_IF_NAME} -o wlan0 -j ACCEPT
    iptables -t nat -D POSTROUTING -s 10.0.0.1/24 -o ${WG_IF_NAME} -j MASQUERADE

    killall hostapd

    ip addr del 10.0.0.1/24 dev wlan0
    ip route del default dev ${WG_IF_NAME}
    ip link set ${WG_IF_NAME} down
    ip addr del ${WG_IP}/32 dev ${WG_IF_NAME}

    ip link del ${WG_IF_NAME} type wireguard

    ip -n ${NS} link set dev ${IF} down
    ip -n ${NS} link set dev eth0 down
    ip -n ${NS} addr del ${IP_CIDR} dev ${IF}

    ip -n ${NS} link set ${IF} netns 1
    ip -n ${NS} link set eth0 netns 1
    ip netns del ${NS}

    # currently this is disabled is systemd
    #systemctl restart NetworkManager
}


case ${1} in
    systemd-start)
        stop_network_managers
        wg_vpn
        hotspot
        move_ifs_to_netns start
        ;;
    systemd-stop)
        down
        ;;
    systemd-restart)
        down
        wg_vpn
        hotspot
        move_ifs_to_netns start
        ;;
    *)
        echo "oh no, this options is not supported"
        ;;
esac
