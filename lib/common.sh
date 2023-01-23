#! /bin/bash

APPNAME="aznfs"
OPTDIR="/opt/microsoft/${APPNAME}"
LOGFILE="${OPTDIR}/${APPNAME}.log" 

# 
# This stores the map of local IP and share name and external blob endpoint IP. 
# 
MOUNTMAP="${OPTDIR}/mountmap"

RED="\e[2;31m"
GREEN="\e[2;32m"
YELLOW="\e[2;33m"
NORMAL="\e[0m"

_log()
{
    echoarg=""

    # We only support -n argument to echo.
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi

    color=$1
    msg=$2

    echo $echoarg -e "$(date -u) $(hostname): ${color}${msg}${NORMAL}" >> $LOGFILE
}

#
# Plain echo with file logging.
#
pecho()
{
    echoarg=""
    color=$NORMAL
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi
    _log $echoarg $color "${*}"
}

#
# Success echo.
#
secho()
{
    echoarg=""
    color=$GREEN
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi
    _log $echoarg $color "${*}"
}

#
# Warning echo.
#
wecho()
{
    echoarg=""
    color=$YELLOW
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi
    _log $echoarg $color "${*}"
}

#
# Error echo.
#
eecho()
{
    echoarg=""
    color=$RED
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi
    _log $echoarg $color "${*}"
}

#
# Verbose echo, no-op unless AZNFS_VERBOSE env variable is set.
#
vecho()
{
    if [ -z "$AZNFS_VERBOSE" -o "$AZNFS_VERBOSE" == "0" ]; then
        return
    fi

    echoarg=""
    color=$NORMAL
    if [ "$1" == "-n" ]; then
        echoarg="-n"
        shift
    fi
    _log $echoarg $color "${*}"
}

# 
# Check if the given string is a valid IPv4 address. 
# 
is_valid_ipv4_address() 
{ 
    #
    # ip route allows 10.10 as a valid address and treats it as 10.10.0.0, so 
    # we need the first coarse filter too.
    #
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && 
    ip -4 route save match $1 > /dev/null 2>&1 
}

#
# Check if the given string is a valid IPv4 prefix.
# 10, 10.10, 10.10.10, 10.10.10.10 are valid prefixes, while
# 1000, 10.256, 10. are not valid prefixes. 
#
is_valid_ipv4_prefix()
{
    ip -4 route get fibmatch $1 > /dev/null 2>&1
}

# 
# Blob fqdn to IPv4 adddress.
# Caller must make sure that it is called only for hostname and not IP address.
# 
resolve_ipv4()
{ 
    local hname="$1"

    # Resolve hostname to IPv4 address.
    host_op=$(host -4 -t A "$hname") 
    if [ $? -ne 0 ]; then
        eecho "Bad Blob FQDN: $hname" 
        return 1 
    fi 

    # 
    # TODO: For ZRS accounts, we will get 3 IP addresses, that needs to be 
    #       handled.
    # 
    local cnt_ip=$(echo "$host_op" | grep " has address " | awk '{print $4}' | wc -l) 

    if [ $cnt_ip -ne 1 ]; then 
        eecho "host returned $cnt_ip address(es) for ${hname}, expected 1!" 
        return 1 
    fi 

    local ipv4_addr=$(echo "$host_op" | grep " has address " | head -n1 | awk '{print $4}') 
    
    if ! is_valid_ipv4_address "$ipv4_addr"; then 
        eecho "[FATAL] host returned bad IPv4 address $ipv4_addr for hostname ${hname}!" 
        return 1 
    fi 

    echo $ipv4_addr 
    return 0 
}

#
# Function to check if an IP is private.
#
is_private_ip() 
{ 
    local ip=$1

    if ! is_valid_ipv4_address $ip; then
        return 1
    fi

    #
    # Check if the IP belongs to the private IP range (10.0.0.0/8,
    # 172.16.0.0/12, or 192.168.0.0/16).f
    #
    [[ $ip =~ ^10\..* ]] || 
    [[ $ip =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\..* ]] || 
    [[ $ip =~ ^192\.168\..* ]]
}

#
# MOUNTMAP is accessed by both mount.aznfs and aznfswatchdog service. Update it 
# only after taking exclusive lock.
#
# Add entry to $MOUNTMAP in case of a new mount or IP change for blob FQDN.
#
add_mountmap()
{
    grep -q $1 $MOUNTMAP
    if [ $? -ne 0 ]; then
        chattr -i $MOUNTMAP
        flock $MOUNTMAP -c "echo $1 >> $MOUNTMAP"
        chattr +i $MOUNTMAP
    else
        pecho "[$1] already exists in MOUNTMAP."
    fi
}

#
# Delete entry from $MOUNTMAP in case of unmount or IP change for blob FQDN.
#
delete_mountmap()
{
    chattr -i $MOUNTMAP
    flock $MOUNTMAP -c "sed -i '%$1%d' $MOUNTMAP"
    chattr +i $MOUNTMAP
}

#
# Reconciel the MOUNTMAP file from findmnt and iptables output.
# 
# Note: This will be added in subsequent revisions.
#
reconcile_mountmap()
{

}

#
# Check if the desired DNAT rule already exist. If not, add new DNAT rule.
#
add_iptable_entry()
{
    iptables -t nat -C OUTPUT -p tcp -d "$1" -j DNAT --to-destination "$2" 2> /dev/null
    if [ $? -ne 0 ]; then
        iptables -t nat -A OUTPUT -p tcp -d "$1" -j DNAT --to-destination "$2"
        if [ $? -ne 0 ]; then
            return 1
        fi
    else
        pecho "DNAT rule [$1 -> $2] already exists."
    fi
}

#
# Delete entry from iptables if the share is unmounted or the IP for blob FQDN
# is resolving into new IP.
#
delete_iptable_entry()
{
    iptables -t nat -C OUTPUT -p tcp -d "$1" -j DNAT --to-destination "$2" 2> /dev/null
    if [ $? -eq 0 ]; then
        iptables -t nat -D OUTPUT -p tcp -d "$1" -j DNAT --to-destination "$2"
        if [ $? -ne 0 ]; then
            return 1
        fi
    else
        pecho "DNAT rule [$1 -> $2] does not exist."
    fi
}

mkdir -p $OPTDIR
if [ $? -ne 0 ]; then
    eecho "[FATAL] Not able to create '${OPTDIR}'."
    exit 1
fi

touch $LOGFILE
if [ $? -ne 0 ]; then
    eecho "[FATAL] Not able to create '${LOGFILE}'."
    exit 1
fi

touch $MOUNTMAP
if [ $? -ne 0 ]; then
    eecho "[FATAL] Not able to create '${MOUNTMAP}'."
    exit 1
fi
chattr +i $MOUNTMAP