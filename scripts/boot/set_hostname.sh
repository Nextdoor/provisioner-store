#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Set Hostname
# Description: >
#   Automatically determines the hostname of the machine based on the supplied
#   server name in RightScale, Cloud Instance ID, and  the domain name. Handles
#   automatically shortening the name to the max of 63 characters, while
#   preserving the instance ID always.
#
# Inputs:
#
#   DOMAIN:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The domain name the host should live under. Almost always this is
#       the default of cloud.nextdoor.com. This is here as an option for
#       future proofing only.
#     Required: true
#     Advanced: false
#     Default: text:cloud.nextdoor.com
#
#   HOSTNAME:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The desired hostname of the machine - this can include spaces and other
#       non hostname-compatible characters, but they will all be stripped out.
#     Required: true
#     Advanced: false
#     Default: env:RS_SERVER_NAME
#
#   INSTANCE_ID:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The cloud-specific Instance ID for the host.
#     Required: true
#     Advanced: true
#     Default: env:INSTANCE_ID
# ...

set -e

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t set_hostname) 2>&1

if test "$RS_REBOOT" = "true" ; then
  echo "Skip hostname setting on REBOOT."
  logger -t RightScale "Skip hostname setting  on REBOOT."
  exit 0     # Leave with a smile ...
fi

# Figure out what our IP address is
_ipaddress=$(/sbin/ifconfig -a | grep "inet addr" | head -1 | awk '{print $2}' | awk -F: '{print $2}')

# Display data
echo "Domain Name [$DOMAIN]"
echo "IP Address [$_ipaddress]"
echo "Hostname [$HOSTNAME]"
echo "Instance ID [$INSTANCE_ID]"

# Figure out if we're a member of an array or not. If we are, write it into a file that can be..
_array_id=$(echo $HOSTNAME | perl -ne 'print $1 if s/#(\d+)/\1/')
if [ "$_array_id" != "" ]; then
  echo "Server Array ID Number: #$_array_id"
  echo "$_array_id" >> /etc/array_id
fi

# Now, if the SERVER NAME and DOMAIN were supplied, move forward..
if [ "$HOSTNAME" != "" ] && [ "$DOMAIN" != "" ]; then
  # Clean up the hostname that was passed to us.
  # 1. Set all lowercase
  HOSTNAME=$(echo $HOSTNAME | tr '[A-Z]' '[a-z]')
  echo "Sanitized: [$HOSTNAME]"

  # 2. Remove any spaces, replace with '-'
  HOSTNAME=$(echo $HOSTNAME | sed 's/\ /\-/g')
  echo "Sanitized: [$HOSTNAME]"

  # 3. Yank out any character that isn't one of the following: A-Z, a-z, 0-9, -
  HOSTNAME=$(echo $HOSTNAME | sed 's/[^a-zA-Z0-9\-]//g')
  echo "Sanitized: [$HOSTNAME]"

  # 4. Replace many dashes with a single one
  HOSTNAME=$(echo $HOSTNAME | sed 's/\-\+/\-/g')
  echo "Sanitized: [$HOSTNAME]"

  # 5. Shorten the string. Hostnames max out at 63 characters, and we want to
  # ensure that we can get a significant portion of the Instance ID in there.
  # We leave 11 characters for the instance ID, and the rest for the hostname.
  HOSTNAME=$(echo $HOSTNAME | cut -c 1-51)
  echo "Shortened: [$HOSTNAME]"
  INSTANCE_ID=$(echo $INSTANCE_ID | cut -c 1-11)

  # Is there an instance ID? ... if not ...
  if [ "$INSTANCE_ID" == "" ]; then
    # Now before we do work, put it all together
    _shortname="${HOSTNAME}"
  else
    # Strip the instance ID. In Google, the instance IDs look like:
    #   projects/nextdoor.com:nextdoor-production/instances/i-d09ffc1fc
    # in Amazon they look like:
    #    i-d09ffc1fc
    INSTANCE_ID=$(echo $INSTANCE_ID | awk -F'/' '{print $NF}')
    _shortname="${HOSTNAME}-${INSTANCE_ID}"	
  fi
else
  echo "No HOSTNAME or DOMAIN supplied, exiting script LOUDLY."
  exit 1
fi

# Set our hostname for this running instance. This is not Distro-specific.
# Now make a FQDN
_fqdn="${_shortname}.${DOMAIN}"

# Remove any name thats already in /etc/hosts for our IP
echo "Removing any existing entries for my hostname in /etc/hosts..."
sed -i /^${_ipaddress}.*/d /etc/hosts

# Re-add our name to /etc/hosts
echo "Adding our hostname [$_fqdn] to /etc/hosts..."
echo "${_ipaddress} ${_fqdn} ${_shortname}" >> /etc/hosts

# Now, with the system tools actually set our hostname
echo "Setting short hostname [$_shortname]..."
hostname ${_shortname}

echo "Setting domainname [$DOMAIN]..."
domainname $DOMAIN

# Distro-specific hostname code
echo "Adding hostname to /etc/hostname"
echo $_shortname > /etc/hostname

if [[ -e /etc/sysconfig/network ]]; then
  # Remove any hostname from /etc/sysconfig/network
  echo "Removing existing HOSTNAME entry from /etc/sysconfig..."	
  sed -i /^HOSTNAME.*/d /etc/sysconfig/network
  # Add a proper hostname to /etc/sysconfig/network
  echo "HOSTNAME=${_shortname}" >> /etc/sysconfig/network
fi
