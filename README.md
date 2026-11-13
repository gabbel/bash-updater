# YDNS Bash Updater Script

This repository contains the bash updater script which can be used on *NIX-like environments to update dynamic hosts. It is recommended to use this script with cronjob to run periodically (preferrably every 15 minutes).

The script uses the YDNS API v1 (dyn-compatible).

## Installation

First, ensure that your host has [curl](http://curl.haxx.se) installed.

1. Check out the source code (updater.sh)
2. Place it into desired place and make it executable (`chmod +x updater.sh`)
3. Edit the script and update the user and host information to fit your configuration
4. Run the script (either by single call or set up a cronjob to run it periodically)

## Crontab Setup

To run this script every 15 minutes using `crontab`, add the following line to your crontab list:

```bash
*/15 * * * * /path/to/script/updater.sh > /dev/null
```

Although this works on most all implementations of `crontab`, for more portability use this instead:

```bash
0,15,30,45 * * * * /path/to/script/updater.sh > /dev/null
````

**NOTE:** To gain access to the crontab list to edit and add entries, execute `crontab -e` at the terminal

## Further notes

The code is licensed under the GNU Public License, version 3.

## Contribution

If you like to contribute useful changes to the script, simply fork the project, apply your changes and make a pull request.

## Changes on this fork

- Support for IPv6 AAAA Records
- Support for IPv4 A Records
- Shortens IPv6 Address by default
- Discovers IPv6 Address of a Target host.
- Does not require dhcpv6, can also detect the SLAAC configured IPv6 Address of a Target host.
- Filter for the default route interface if none has been specified.
- Filter for API return messages.
- Is gready with API calls, tracks changes of IP addresses over per host defined '/tmp/ydns_last_ip6_<host>' or '/tmp/ydns_last_ip4_<host>' file.
- Works with BusyBox ash / POSIX sh. No Bash-specific features.

## Requirements:

- curl, awk, sort, sed, tr, grep, head, tail;
- ip (for IPv6 and for -i); nslookup for -t

```bash
# Within openwrt normally only curl is an addtional required package.
# Install from CLI using.
apk add curl
```

## Usage Examples:

```bash
updater.sh -4 mylocalservice.domain.com         # WAN IPv4
updater.sh -i tun0 -4 mylocalservice.domain.com # IPv4 of the VPN interface
updater.sh -6 myrouter.domain.com               # IPv6 of the WAN interface
updater.sh -I tun0 -6 myrouter.domain.com       # IPv6 of the VPN interface
updater.sh -V                                   # Verbose mode.
```
- Recommended usage:

Create a helper Script if you got Serval entries to keep track, trigger that one over your crontab.
```bash
#!/bin/ash

# sound.mydomain.net
/etc/updater.sh -4 sound.mydomain.net -6 sound.mydomain.net -t s2.lan
# nextcloud.mydomain.net
/etc/updater.sh -4 nextcloud.mydomain.net -6 nextcloud.mydomain.net -t s3.lan

exit 0
```

## Complex Example:
```bash
updater.sh -i wan.10 \                          # IPv4 of interface wan.10 (wan on vlan10)
           -4 mylocalservice.domain.com \       # Use to update this IPv4 entry within ydns.
           -6 mylocalservice.domain.com \       # Update this IPv6 entry within ydns,
           -t localserver02.lan                 # by discovering and using the Public IPv6 Address of this local host.
```
