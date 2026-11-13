#!/bin/ash
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
#
# Works with BusyBox ash / POSIX sh. No Bash-specific features.
# updater.sh - YDNS updater with separate IPv4 (A) and IPv6 (AAAA) handling#
#
# Designed to run on the router itself.
#
# Rules (interfaces are optional):
#   - IPv4 (A records):
#       * default: the public IPv4 address of the WAN interface (the one
#         holding the IPv4 default route). Only if that address is not public
#         (router behind another NAT) ydns.io/api/v1/ip is asked instead.
#       * -i IFACE: the IPv4 address of that interface instead
#         (e.g. a VPN interface that carries a public address)
#   - IPv6 (AAAA records):
#       * default: the public IPv6 address of the interface that holds the
#         IPv6 default route (the WAN interface)
#       * -I IFACE: the public IPv6 address of that interface instead
#       * -t TARGET: discover the public IPv6 address of the host TARGET
#         (DNS AAAA + DHCP lease/ethers MAC + IPv6 neighbor table, limited
#         to -I IFACE if given) and publish that address.
#
# Note: the YDNS API only UPDATES existing records ("best suitable" record
# of the host). It cannot create hosts or A/AAAA records: create them once in
# the YDNS web interface, the script then keeps them current.
#
# The last published address is stored per host and family in
# /tmp/ydns_last_ip4_<host> and /tmp/ydns_last_ip6_<host>. The API is only
# contacted when the current address differs from the stored one.
#
# Requirements: curl, awk, sort, sed, tr, grep, head, tail;
#               ip (for IPv6 and for -i); nslookup for -t
#
# Examples:
#   updater.sh -4 mylocalservice.domain.com         # WAN IPv4
#   updater.sh -i tun0 -4 mylocalservice.domain.com # IPv4 of the VPN interface
#   updater.sh -6 myrouter.domain.com               # IPv6 of the WAN interface
#   updater.sh -I tun0 -6 myrouter.domain.com       # IPv6 of the VPN interface
#   updater.sh -V                                   # Verbose mode.
# Complex Example:
#   updater.sh -i wan.10 \                          # IPv4 of interface wan.10 (wan on vlan10)
#              -4 mylocalservice.domain.com \       # Use to update this IPv4 entry within ydns.
#              -6 mylocalservice.domain.com \       # Update this IPv6 entry within ydns,
#              -t localserver02.lan                 # by discovering and using the Public IPv6 Address of this local host.
##
# Account details (can be overridden with -u / -p).
##
# Your API Username string
YDNS_USER="exampleuser"
# Your API Secret string
YDNS_PASSWD="APISECRET"

# Hosts to update (space separated). Can be extended with -4 / -6.
YDNS_HOSTS4=""      # hosts that get an A record (IPv4)
YDNS_HOSTS6=""      # hosts that get an AAAA record (IPv6)

# Optional default for the IPv6 discovery target (-t).
TARGET=""

# Data sources for the IPv6 discovery.
LEASES="/tmp/dhcp.leases"
ETHERS="/etc/ethers"

# Where the last published addresses are stored.
LASTIP_DIR="${YDNS_LASTIP_DIR:-/tmp}"

##
# Don't change anything below.
##
YDNS_UPD_VERSION="20261111.1"

verbose=0
IFACE4=""       # optional: interface to take the IPv4 address from
IFACE6=""       # optional: interface to take / search the IPv6 address on


# ==================================================
# Helpers
# ==================================================

usage()
{
    cat <<EOF
YDNS Updater (IPv4 + IPv6)

Usage: $0 [-4 HOST]... [-6 HOST]... [options]

Hosts (at least one of -4 / -6, both repeatable):
  -4 HOST        YDNS host to update with the IPv4 address (A record)
  -6 HOST        YDNS host to update with the IPv6 address (AAAA record)

Address selection (all optional):
  -i INTERFACE   IPv4: use the IPv4 address of this interface (e.g. a VPN
                 interface with a public address).
                 Default: the public IPv4 address of the WAN interface
                 (the one holding the IPv4 default route)
  -I INTERFACE   IPv6: use the public IPv6 address of this interface.
                 Default: the interface holding the IPv6 default route
  -t TARGET      IPv6: discover the address of TARGET (e.g. s2.lan) via DNS,
                 DHCP leases/ethers and the neighbor table (limited to
                 -I INTERFACE if given) instead of using a local address

Other options:
  -u USERNAME    YDNS username for authentication
  -p PASSWORD    YDNS password for authentication
  -h             Display usage
  -v             Display version
  -V             Enable verbose output
EOF
}

# write_msg MESSAGE [err]
# Messages marked "err" are always printed (stderr), others only with -V.
write_msg()
{
    if [ "$2" = "err" ]; then
        echo "[$(date +%Y/%m/%dT%H:%M:%S)] $1" >&2
        return 0
    fi

    [ "$verbose" -eq 1 ] || return 0
    echo "[$(date +%Y/%m/%dT%H:%M:%S)] $1"
}

have()
{
    command -v "$1" >/dev/null 2>&1
}


# ==================================================
# IPv6 address normalization (RFC 5952)
# ==================================================
# Prints the shortest canonical form of a hexadecimal IPv6 address.
# Prints nothing (and exits 1) for invalid input.
# IPv4-embedded notation is not supported.

ipv6_shorten()
{
    printf '%s\n' "$1" | awk '

    function parse_part(s, A,    n,i)
    {
        if (s == "")
            return 0

        n = split(s, A, ":")

        for (i=1; i<=n; i++) {
            if (A[i] !~ /^[0-9a-f]+$/ || length(A[i]) > 4)
                return -1
        }

        return n
    }

    {
        addr = tolower($0)

        if (addr ~ /\./)
            exit 1

        pos = index(addr, "::")

        if (pos) {

            left  = substr(addr, 1, pos-1)
            right = substr(addr, pos+2)

            if (index(right, "::"))
                exit 1

            nl = parse_part(left, L)
            nr = parse_part(right, R)

            if (nl < 0 || nr < 0)
                exit 1

            missing = 8 - nl - nr

            if (missing < 1)
                exit 1

            n = 0

            for (i=1; i<=nl; i++)
                G[++n] = L[i]

            for (i=1; i<=missing; i++)
                G[++n] = "0"

            for (i=1; i<=nr; i++)
                G[++n] = R[i]

        } else {

            n = parse_part(addr, G)

            if (n != 8)
                exit 1
        }

        if (n != 8)
            exit 1

        for (i=1; i<=8; i++) {

            sub(/^0+/, "", G[i])

            if (G[i] == "")
                G[i] = "0"
        }

        # Longest run of zero hextets (first one wins on a tie).
        best  = 0
        start = 0
        i     = 1

        while (i <= 8) {

            if (G[i] == "0") {

                s = i

                while (i <= 8 && G[i] == "0")
                    i++

                len = i - s

                if (len > best) {
                    best  = len
                    start = s
                }

            } else {
                i++
            }
        }

        # RFC 5952: no :: for a single zero hextet.
        if (best < 2) {

            for (i=1; i<=8; i++) {

                if (i > 1)
                    printf ":"

                printf "%s", G[i]
            }

            print ""
            exit
        }

        left = ""
        right = ""

        for (i=1; i<start; i++) {

            if (left != "")
                left = left ":"

            left = left G[i]
        }

        for (i=start+best; i<=8; i++) {

            if (right != "")
                right = right ":"

            right = right G[i]
        }

        if (left == "" && right == "")
            result = "::"
        else if (left == "")
            result = "::" right
        else if (right == "")
            result = left "::"
        else
            result = left "::" right

        print result
    }'
}


# ==================================================
# Public IPv6 address filter
# ==================================================
# Accepts global unicast (2000::/3) and drops documentation and a few
# special-purpose ranges. Practical filter, not the full IANA registry.

ipv6_is_public()
{
    addr="$(ipv6_shorten "$1" 2>/dev/null)"

    [ -n "$addr" ] || return 1

    case "$addr" in
        2*|3*)
            ;;
        *)
            return 1
            ;;
    esac

    case "$addr" in
        2001:0:*|2001:1:*|2001:2[0-9a-f]:*|2001:db8:*)
            return 1
            ;;
    esac

    return 0
}

# Reads candidate addresses from stdin, prints unique, normalized,
# public IPv6 addresses.
filter_public_ipv6()
{
    while IFS= read -r cand; do

        [ -n "$cand" ] || continue

        if ipv6_is_public "$cand"; then
            ipv6_shorten "$cand"
        fi

    done |
    sort -u
}


# ==================================================
# Interface addresses
# ==================================================

# Public IPv4 address as seen from the internet. Only used as a fallback when
# the WAN interface itself has no public address (e.g. router behind CGNAT),
# because this contacts the YDNS API on every run.
get_public_ipv4()
{
    curl --silent --max-time 15 --ipv4 https://ydns.io/api/v1/ip 2>/dev/null |
    tr -d ' \t\r\n'
}

# Succeeds if $1 is a public IPv4 address (not private, CGNAT, loopback,
# link-local or otherwise unusable).
ipv4_is_public()
{
    case "$1" in
        ""|0.*|10.*|127.*|169.254.*|192.168.*|22[4-9].*|2[3-5][0-9].*)
            return 1
            ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*)
            return 1
            ;;
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*)
            return 1
            ;;
    esac

    return 0
}

# Interface that holds the IPv4 default route (the WAN interface).
get_default_iface4()
{
    have ip || return 0

    ip -4 route show default 2>/dev/null |
    awk '
        {
            for (i=1; i<NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

# Interface that holds the IPv6 default route (the WAN interface).
get_default_iface6()
{
    ip -6 route show default 2>/dev/null |
    awk '
        {
            for (i=1; i<NF; i++) {
                if ($i == "dev") {
                    print $(i+1)
                    exit
                }
            }
        }
    '
}

# First usable IPv4 address of interface $1 (no link-local 169.254/16).
get_iface_ipv4()
{
    ip -4 addr show dev "$1" 2>/dev/null |
    awk '
        $1 == "inet" {
            a = $2
            sub(/\/.*/, "", a)

            if (a !~ /^169\.254\./) {
                print a
                exit
            }
        }
    '
}

# First public, stable IPv6 address of interface $1. Temporary (privacy),
# deprecated and tentative addresses are skipped.
get_iface_ipv6()
{
    ip -6 addr show dev "$1" 2>/dev/null |
    awk '
        $1 == "inet6" && $0 !~ /temporary|deprecated|tentative/ {
            a = $2
            sub(/\/.*/, "", a)
            print a
        }
    ' |
    filter_public_ipv6 |
    head -n 1
}


# ==================================================
# IPv6 discovery of a target host (-t)
# ==================================================

# DNS AAAA lookup. Only addresses after the "Name:" section are used, so the
# resolver's own address is never mistaken for an answer.
dns_lookup()
{
    nslookup -type=AAAA "$1" 2>/dev/null |
    awk '
        /^Name:/ {
            found = 1
            next
        }

        found && $1 ~ /^Address/ {
            addr = $NF
            sub(/#.*/, "", addr)

            if (addr ~ /:/)
                print addr
        }
    '
}

# Sets MAC from the DHCP leases (expiry MAC IP hostname ...) or /etc/ethers.
find_mac()
{
    MAC=""

    if [ -f "$LEASES" ]; then
        MAC="$(awk -v h="$HOST" -v s="$SHORT" '
            tolower($4) == h || tolower($4) == s {
                print $2
                exit
            }
        ' "$LEASES")"
    fi

    if [ -z "$MAC" ] && [ -f "$ETHERS" ]; then
        MAC="$(awk -v h="$HOST" -v s="$SHORT" '
            tolower($2) == h || tolower($2) == s {
                print $1
                exit
            }
        ' "$ETHERS")"
    fi

    MAC="$(printf '%s' "$MAC" | tr 'A-F' 'a-f')"
}

# IPv6 neighbors with the given MAC, restricted to $IFACE6 if one was given
# (otherwise all interfaces are searched).
find_neighbors()
{
    [ -n "$MAC" ] || return 0

    set -- ip -6 neigh show

    if [ -n "$IFACE6" ]; then
        set -- "$@" dev "$IFACE6"
    fi

    "$@" nud all 2>/dev/null |
    awk -v mac="$MAC" '
        {
            for (i=1; i<=NF; i++) {
                if (tolower($i) == mac && $1 ~ /^[0-9a-fA-F:]+$/)
                    print $1
            }
        }
    '
}

# Prints ONE public IPv6 address of $TARGET, or returns 1.
# Preference: address present in both DNS and neighbor table, then the
# neighbor table, then DNS.
discover_ipv6_target()
{
    HOST="$(printf '%s' "$TARGET" | tr 'A-Z' 'a-z')"
    SHORT="${HOST%%.*}"

    dns6="$(
        {
            have nslookup && dns_lookup "$HOST"
            if have nslookup && [ "$SHORT" != "$HOST" ]; then
                dns_lookup "$SHORT"
            fi
        } | filter_public_ipv6
    )"

    find_mac

    neigh6="$(find_neighbors | filter_public_ipv6)"

    write_msg "Target $HOST: MAC=${MAC:-none}" >&2
    write_msg "Target $HOST: DNS AAAA: $(echo $dns6)" >&2
    write_msg "Target $HOST: neighbor table: $(echo $neigh6)" >&2

    if [ -n "$dns6" ] && [ -n "$neigh6" ]; then
        for cand in $neigh6; do
            if printf '%s\n' "$dns6" | grep -Fxq "$cand"; then
                echo "$cand"
                return 0
            fi
        done
    fi

    if [ -n "$neigh6" ]; then
        printf '%s\n' "$neigh6" | head -n 1
        return 0
    fi

    if [ -n "$dns6" ]; then
        printf '%s\n' "$dns6" | head -n 1
        return 0
    fi

    return 1
}


# ==================================================
# YDNS update
# ==================================================

# update_host HOST IP FAMILY(4|6)
# Skips the update if the IP equals the last one published for this host
# and family. Returns 0 on success/unchanged, 90 on auth error, 91 otherwise.
update_host()
{
    uh_host="$1"
    uh_ip="$2"
    uh_fam="$3"
    uh_file="$LASTIP_DIR/ydns_last_ip${uh_fam}_${uh_host}"
    uh_last=""

    if [ -f "$uh_file" ]; then
        uh_last="$(head -n 1 "$uh_file")"
    fi

    if [ "$uh_ip" = "$uh_last" ]; then
        write_msg "Not updating YDNS host $uh_host (IPv$uh_fam): IP address unchanged ($uh_ip)"
        return 0
    fi

    # If this fails with curl error 60 the certificate store lacks the
    # certificate; add it or (not recommended) use -k.
    #
    # The HTTP status code is appended on its own last line (-w).
    uh_out="$(curl --basic \
        -u "$YDNS_USER:$YDNS_PASSWD" \
        --silent \
        --max-time 30 \
        -w '\n%{http_code}' \
        "https://ydns.io/api/v1/update/?host=${uh_host}&ip=${uh_ip}")"

    uh_code="$(printf '%s\n' "$uh_out" | tail -n 1 | tr -d '\r')"
    uh_body="$(printf '%s\n' "$uh_out" | sed '$d' | head -n 1 | tr -d '\r')"
    uh_word="${uh_body%% *}"

    # YDNS answers HTTP 200 with a body starting with "good" (it may be
    # followed by the IP, e.g. "good 2001:db8::1"). "ok" and "nochg" are
    # accepted as well for the legacy behavior.
    if [ "$uh_code" = "200" ]; then
        case "$uh_word" in
            good|ok|nochg)
                write_msg "YDNS host updated successfully: $uh_host ($uh_ip)"
                echo "$uh_ip" > "$uh_file"
                return 0
                ;;
        esac
    fi

    case "$uh_code:$uh_word" in
        401:*|*:badauth)
            write_msg "YDNS host update failed: $uh_host (authentication failed)" err
            return 90
            ;;

        404:*)
            write_msg "YDNS host update failed: $uh_host (host not found in YDNS)" err
            return 91
            ;;

        400:*)
            write_msg "YDNS host update failed: $uh_host (invalid parameters, ip=$uh_ip)" err
            return 91
            ;;

        *)
            write_msg "YDNS host update failed: $uh_host (IPv$uh_fam, HTTP ${uh_code:-none}, ${uh_body:-no response})" err
            return 91
            ;;
    esac
}


# ==================================================
# Argument handling
# ==================================================

while getopts "hi:I:4:6:t:u:p:vV" opt; do
    case "$opt" in
        h)
            usage
            exit 0
            ;;

        i)
            IFACE4="$OPTARG"
            ;;

        I)
            IFACE6="$OPTARG"
            ;;

        4)
            YDNS_HOSTS4="$YDNS_HOSTS4 $OPTARG"
            ;;

        6)
            YDNS_HOSTS6="$YDNS_HOSTS6 $OPTARG"
            ;;

        t)
            TARGET="$OPTARG"
            ;;

        u)
            YDNS_USER="$OPTARG"
            ;;

        p)
            YDNS_PASSWD="$OPTARG"
            ;;

        v)
            echo "YDNS Updater version $YDNS_UPD_VERSION"
            exit 0
            ;;

        V)
            verbose=1
            ;;

        *)
            usage >&2
            exit 1
            ;;
    esac
done

if [ -z "$YDNS_HOSTS4" ] && [ -z "$YDNS_HOSTS6" ]; then
    echo "Error: no host given (use -4 HOST and/or -6 HOST)." >&2
    echo >&2
    usage >&2
    exit 1
fi

if [ -n "$TARGET" ] && [ -z "$YDNS_HOSTS6" ]; then
    echo "Error: -t only makes sense together with -6 HOST." >&2
    exit 1
fi

if ! have curl; then
    echo "ERROR: cURL is missing." >&2
    exit 1
fi

if [ -n "$IFACE4" ] && [ -z "$YDNS_HOSTS4" ]; then
    echo "Error: -i only makes sense together with -4 HOST." >&2
    exit 1
fi

if [ -n "$IFACE6" ] && [ -z "$YDNS_HOSTS6" ]; then
    echo "Error: -I only makes sense together with -6 HOST." >&2
    exit 1
fi

# ip is needed for IPv6 and whenever an interface is given.
if { [ -n "$YDNS_HOSTS6" ] || [ -n "$IFACE4" ]; } && ! have ip; then
    echo "ERROR: the ip command is missing." >&2
    exit 1
fi

for chk in $IFACE4 $IFACE6; do
    if ! ip link show dev "$chk" >/dev/null 2>&1; then
        echo "Error: interface '$chk' does not exist." >&2
        exit 1
    fi
done


# ==================================================
# Main
# ==================================================

rc=0

# ---- IPv4 / A records: WAN public address, or the given interface --------

if [ -n "$YDNS_HOSTS4" ]; then

    if [ -n "$IFACE4" ]; then
        ip4="$(get_iface_ipv4 "$IFACE4")"
        src4="interface $IFACE4"
    else
        # Read the address from the WAN interface (no API contact needed).
        ip4=""
        src4="WAN interface"
        wan4="$(get_default_iface4)"

        if [ -n "$wan4" ]; then
            ip4="$(get_iface_ipv4 "$wan4")"
            src4="WAN interface $wan4"

            if ! ipv4_is_public "$ip4"; then
                write_msg "WAN interface $wan4 has no public IPv4 address (${ip4:-none}), asking ydns.io"
                ip4=""
            fi
        fi

        # Fallback: router is behind another NAT or has no default route.
        if [ -z "$ip4" ]; then
            ip4="$(get_public_ipv4)"
            src4="public address reported by ydns.io"
        fi
    fi

    if [ -z "$ip4" ]; then
        write_msg "Error: no IPv4 address found ($src4)." err
        rc=92
    else
        write_msg "Current IPv4 ($src4): $ip4"

        for h in $YDNS_HOSTS4; do
            update_host "$h" "$ip4" 4 || rc=$?
        done
    fi
fi

# ---- IPv6 / AAAA records: WAN/given interface or discovered target -------

if [ -n "$YDNS_HOSTS6" ]; then

    if [ -n "$TARGET" ]; then
        ip6="$(discover_ipv6_target)"
        src="target $TARGET${IFACE6:+ via $IFACE6}"
    else
        iface6="$IFACE6"

        if [ -z "$iface6" ]; then
            iface6="$(get_default_iface6)"
        fi

        if [ -z "$iface6" ]; then
            write_msg "Error: no IPv6 default route found; specify -I INTERFACE." err
            iface6=""
        fi

        ip6=""

        if [ -n "$iface6" ]; then
            ip6="$(get_iface_ipv6 "$iface6")"
        fi

        src="interface $iface6"
    fi

    if [ -z "$ip6" ]; then
        write_msg "Error: no public IPv6 address found ($src)." err
        rc=92
    else
        write_msg "Current IPv6 ($src): $ip6"

        for h in $YDNS_HOSTS6; do
            update_host "$h" "$ip6" 6 || rc=$?
        done
    fi
fi

exit $rc
