# WFH-Anywhere

## What is this for?

This repo contains BASH tool that will help you configure for yourself a Wireguard VPN tunnel running via any\* number of hops.

The script will guide you via configuration stage and will produce all-in-one, stand alone installation script that you can then copy to each of your hosts and execute and voila!

## Why?

It's encapsulating my custom built solution that allows me to travel but at the same time securely route all my traffic via home ISP making me look as if I haven't even left the place.
When traveling I want to be able to connect transparently back to my home and also route all the traffic down that path and not leak single packet out of the VPN.

## How?

The key part is the Raspberry Pi route which does a couple of things:

1. Creates dedicated network namespace and moves there all interfaces except wifi (wlan0)
2. Creates in the dedicated network namespace a Wireguard interface and moves it to the default namespace
3. Runs constantly a script scanning for new interface added via USB tethering and moves it to the dedicated namespace (this allows to disconnect the phone when needed and reconnect it where it will be detected and configured each time)
4. Starts a hotspot uing Raspberry Pi wifi card

I'm using a Raspberry Pi 4 with Ubuntu 22.04 on it with a service added that runs in loop script scanning for new internet links (shared to Raspberry Pi via USB tethering from a phone). Once such device is detected it is moved to dedicated network namespace whilst at the same time there is a Wireguard interface that exists in the default namespace accepting all the traffic and passing it on to those internet links in the dedicated namespace but it's already in a VPN tunnel at that time.

\* The any has actually specific limit of 24 or 25 but I go with any as don't think anyone there is going to need that many anyway.
