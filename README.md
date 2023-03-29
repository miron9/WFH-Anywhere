# WFH-Anywhere

## What is this for?

This repo contains BASH tool that will help you configure a Wireguard VPN tunnel running via any\* number of hops/nodes.

The script will guide you via configuration stage and will produce all-in-one, stand alone installation script that you can then copy to each of your nodes, execute and voila!

## TL;DR; aka Quick start

Assumptions:

- you've got a Raspberry Pi 4, when I say Raspberry Pi I mean that specific one
- you run Ubuntu server 22.10 on the aforementioned Raspberry Pi. Ubuntu Desktop at same version should also work but no guarantees given.
- you have Android based phone. I don't know how USB tethered connection is going to be presented (as in interface name) with any other device than Android based (tested with Google Pixel 7 and OnePlus 5).

1. Install Ubuntu Server 22.10 on your Raspberry Pi 4 microSD card,
2. Run the ./run_me.sh script directly on your machine. It will install a couple of packages if these are yet not there but it will not make any changes to your system, only generate installation scripts that then you copy and run on machines these are intended for. If you prefer something even safer and you have Docker installed you can run something like this:
   `docker run -it --rm -v $(pwd):/root/WFH-Anywhere/ docker.io/library/ubuntu bash`
   and then run the `./run_me.sh` script.
3. Follow the script entering requested answers or accepting defaults if offered.
4. There will be a new directory created called `./output`. Directories inside of it with names like `1`, `2`, `3`, etc. are nodes through which you decide to relay your VPN connection. In each of these numbered directories is now a script called like `./output/1/generated_wireguard_vpn_install_script.sh`. Copy these generated scripts to each and every node you configured in the order your provided it to the script. The `1` should go on your Raspberry Pi, the `2` on the node that the Raspberry Pi is going to connect to and so on.
5. Once the scripts are distributed to its respective nodes execute them one by one.
   The Raspberry Pi will need the internet connection for the script to succeed - connect your phone to it via USB cable and tether you internet connection first.
   The `1` on your Raspberry Pi will throw some errors but don't worry about these, it will work.
6. You should now see there is a new WiFi connection available by the name you choose. Connect to it using password you defined.
7. Check your IP on any IP checking website. Your reported geolocation now should match the one of the last node.

## Why?

It's encapsulating my custom built solution that allows me to travel but at the same time securely route all my traffic via home ISP making me look as if I haven't even left the place.
When traveling I want to be able to connect transparently back to my home and also route all the traffic down that path and not leak single packet out of the VPN.

## How?

This is just normal, multi-hop VPN with Raspberry Pi based WiFi router as an entry point. This is convenient as anything that connects to the WiFi automatically and completely transparently uses the VPN.

The key part is the Raspberry Pi router which does a couple of things:

1. Creates dedicated network namespace and moves there all interfaces except WiFi (wlan0) and eth0
2. Creates in the dedicated network namespace a Wireguard interface and moves it to the default namespace
3. Runs in a loop a script scanning for new interface added via USB tethering and moves it to the dedicated namespace (this allows to disconnect the phone when needed and reconnect it where it will be detected and configured each time)
4. Starts a hotspot using Raspberry Pi WiFi card

I'm using a Raspberry Pi 4 with Ubuntu 22.04/22.10 on it with a service added that runs in loop script scanning for new internet links (shared to Raspberry Pi via USB tethering from a phone). Once such device is detected it is moved to dedicated network namespace whilst at the same time there is a Wireguard interface that exists in the default namespace accepting all the traffic and passing it on to those internet links in the dedicated namespace but it's already in a VPN tunnel at that time.

\* The any has actually specific limit of 24 or 25 but I go with any as I don't think anyone there is going to need that many hops.

This script was inspired by those two articles describing how to use Linux network namespaces with Wireguard (1) and how to configure Wireguard to pass the traffic across multiple hops (2). Both were great source of knowledge and the whole thing a good exercise.

1. https://www.wireguard.com/netns/
2. https://www.procustodibus.com/blog/2022/06/multi-hop-wireguard/

# TODO and FIXME

- in the "prerequisites" function check if dhclient command exists before running it
