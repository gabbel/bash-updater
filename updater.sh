#!/usr/bin/env bash
#
# YDNS updater script
# Copyright (C) 2013-2017 TFMT UG (haftungsbeschränkt) <support@ydns.io>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


##
# Define your YDNS account details and host you'd like to update.
# In case you'd like to update multiple hosts at once, provide the hosts
# separated by space.
##

# Your API Username string
YDNS_USER="exampleuser"
# Your API Secret string
YDNS_PASSWD="APISECRET"
# One or serval hosts, separated by space
YDNS_HOSTS="hostrecord.ydns.eu"

##
# Don't change anything below.
##
YDNS_UPD_VERSION="20250516.1"

if ! hash curl 2>/dev/null; then
	echo "ERROR: cURL command is missing."
	exit 1
fi

if ! hash ip 2>/dev/null; then
	echo "ERROR: ip command is missing."
	exit 1
fi

if ! hash sed 2>/dev/null; then
	echo "ERROR: sed command is missing."
	exit 1
fi

usage () {
	echo "YDNS Updater"
	echo ""
	echo "Usage: $0 [options]"
	echo ""
	echo "Available options are:"
	echo "  -h             Display usage"
	echo "  -H HOST        YDNS host to update"
	echo "  -u USERNAME    YDNS username for authentication"
	echo "  -p PASSWORD    YDNS password for authentication"
	echo "  -i INTERFACE   Use the local IP address for the given interface"
	echo "  -v             Display version"
	echo "  -V             Enable verbose output"
	exit 0
}

## Shorthand function to update the IP address
update_ip_address () {
	# if this fails with error 60 your certificate store does not contain the certificate,
	# either add it or use -k (disable certificate check
	ret=
	
	ret=`curl --basic \
		-u "$YDNS_USER:$YDNS_PASSWD" \
		--silent \
		https://ydns.io/api/v1/update/?host=${host}\&ip=${current_ip}`
	echo ${ret//[[:space:]]/}
}


## Shorthand function to display version
show_version () {
	echo "YDNS Updater version $YDNS_UPD_VERSION"
	exit 0
}

## Shorthand function to write a message
write_msg () {
	if [ $verbose -ne 1 ]; then
		return
	fi

	outfile=1

	if [ -n "$2" ]; then
		outfile=$2
	fi

	echo "[`date +%Y/%m/%dT%H:%M:%S`] $1" >&$outfile
}

exit_code=0
verbose=0
local_interface_addr=

while getopts "hH:i:p:u:vV" opt; do
	case $opt in
		h)
			usage
			;;
		H)
			custom_host="$custom_host $OPTARG"
			;;
		i)
			local_interface_addr=$OPTARG
			;;
		p)
			YDNS_PASSWD=$OPTARG
			;;
		u)
			YDNS_USER=$OPTARG
			;;
		v)
			show_version
			;;
		V)
			verbose=1
			;;
	esac
done

if [ "$custom_host" != "" ]; then
	YDNS_HOSTS=$custom_host
fi

# get device name of default interface
if [ "$local_interface_addr" = "" ]; then
	local_interface_addr=$(ip route | awk '/default/ {print $5}')
fi

# Convert to array
read -ra ydns_hostslist <<< "$YDNS_HOSTS"


for host in "${ydns_hostslist[@]}"; do

	write_msg "Processing host: $host using interface $local_interface_addr"
	YDNS_LASTIP_FILE="/tmp/ydns_last_ip_$host"

	if ! [ -f $YDNS_LASTIP_FILE ]; then
		# Ensure file exists with exactly two lines (first line for ipv4 and second line for ipv6)
		echo -e "\n" > "$YDNS_LASTIP_FILE"
	fi

	# Try to read read previous IPs from temp file (first line for ipv4 and second line for ipv6)
	last_ipv4=$(head -n 1 "$YDNS_LASTIP_FILE")
	last_ipv6=$(head -n 2 "$YDNS_LASTIP_FILE" | tail -n 1)
	# Retrieve current local IP address for a given interface
	current_ipv4=$(ip -o -4 addr show dev "${local_interface_addr}" | awk '{split($4,a,"/"); print a[1]}')
	current_ipv6=$(ip -o -6 addr show dev "${local_interface_addr}" scope global | awk '{split($4,a,"/"); print a[1]; exit}')

	
	# Check and update if needed for ipv4	
	if [ "$current_ipv4" != "" ] && [ "$current_ipv4" != "$last_ipv4" ]; then
		write_msg  "IPv4 has changed: $last_ipv4 → $current_ipv4"
		# update_ydns_record "ipv4" "$current_ipv4"
		current_ip="$current_ipv4"
		ret=$(update_ip_address)
	
		case "$ret" in
			badauth*)
				write_msg "YDNS host ipv4 update failed: $YDNS_HOST (authentication failed)" 2
				exit_code=90
				;;
			nohost*)
				write_msg "YDNS hostrecord $host does not exist." 2
				exit_code=91
				;;
			good*)
				write_msg "YDNS host ipv4 updated successfully: $YDNS_HOST ($current_ipv4)"
				sed -i "1s/.*/$current_ipv4/" $YDNS_LASTIP_FILE
				;;
			nochg*)
				write_msg "YDNS ipv4 entry unchanged."
				sed -i "1s/.*/$current_ipv4/" $YDNS_LASTIP_FILE
				;;
			*)
				write_msg "YDNS host ipv4 update failed: $YDNS_HOST ($ret)" 2
				exit_code=91
				;;
		esac
	else
		if [ "$current_ipv4" = "" ]; then
			write_msg "This interface has no ipv4 address" 2
		else
			write_msg "Not updating YDNS ipv4 host $YDNS_HOST: IP address unchanged" 2
		fi
	fi
	
	# Check and update if needed for ipv6	
	if [ "$current_ipv6" != "" ] && [ "$current_ipv6" != "$last_ipv6" ]; then
		write_msg  "IPv6 has changed: $last_ipv6 → $current_ipv6"
		# update_ydns_record "ipv6" "$current_ipv6"
		current_ip="$current_ipv6"
		ret=$(update_ip_address)
	
		case "$ret" in
			badauth*)
				write_msg "YDNS host ipv6 update failed: $YDNS_HOST (authentication failed)" 2
				exit_code=90
				;;
			nohost*)
				write_msg "YDNS hostrecord $host does not exist." 2
				exit_code=91
				;;
			good*)
				write_msg "YDNS host ipv6 updated successfully: $YDNS_HOST ($current_ipv6)"
				sed -i "2s/.*/$current_ipv6/" $YDNS_LASTIP_FILE
				;;
			nochg*)
				write_msg "YDNS ipv6 entry unchanged."
				sed -i "2s/.*/$current_ipv6/" $YDNS_LASTIP_FILE
				;;
			*)
				write_msg "YDNS host ipv6 update failed: $YDNS_HOST ($ret)" 2
				exit_code=91
				;;
		esac	
	else
		if [ "$current_ipv6" = "" ]; then
			write_msg "This interface has no ipv6 address" 2
		else
			write_msg "Not updating YDNS ipv6 host $YDNS_HOST: IP address unchanged" 2
		fi
	fi

done

exit $exit_code
