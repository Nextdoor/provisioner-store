#! /usr/bin/sudo /bin/bash
# ---
# Updates package repositories and installs installer tools (e.g. apt-fast)
#
# OS Support:
#   - Debian
#
# Required environment variables:
#   (None)
#
# Optional environment variables:
#   PACKAGE_REGION_OVERRIDE: String with the region to use for the AWS-based OS
#     package mirrors.
#   Example: "apt:tree apt:git"
#

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t refresh_repos) 2>&1

if which apt-get > /dev/null 2>&1; then
  pkgman=apt
elif which yum > /dev/null 2>&1; then
  pkgman=yum
fi

export DEBIAN_FRONTEND=noninteractive

if [ -z "$pkgman" ]; then
  echo "ERROR: Unrecognized package manager, but we have packages to install"
  exit 1
else
  echo "Detected package manager: $pkgman"
fi

function refresh_repos() {
  if [[ "$pkgman" == "apt" ]]; then
    # Setup repos
    add-apt-repository -y ppa:saiarcot895/myppa

    if [ ! -z "$PACKAGE_REGION_OVERRIDE" ]; then
      sed -E -i "s/(http\:\/\/)([a-z0-9\-]+)(\.ec2\.archive\.ubuntu\.com)/\1$PACKAGE_REGION_OVERRIDE\3/g" /etc/apt/sources.list
    fi

    # Determine which packages are suitable for install on this system.
    apt-get clean
    rm -rf /var/lib/apt/lists/*
    rm -rf /var/lib/apt/lists/partial/*
    apt-get clean
    apt-get update || echo "apt-get update failed .. proceeding anyways"

    # Install and configure apt-fast
    DEBIAN_FRONTEND=noninteractive apt-get install -y apt-fast
    sed -i 's/^_MAXNUM=.*$/_MAXNUM=10/g' /etc/apt-fast.conf
    echo "MIRRORS=( 'us-west-1.ec2.archive.ubuntu.com/ubuntu,us-east-1.ec2.archive.ubuntu.com/ubuntu,us-east-2.ec2.archive.ubuntu.com/ubuntu,eu-west-1.ec2.archive.ubuntu.com/ubuntu,eu-west-2.ec2.archive.ubuntu.com/ubuntu' )" >> /etc/apt-fast.conf

    # Force clean apt-fast cache. `|| true` is added because this command throws an
    # error code `1` if the cache is already empty.
    apt-fast clean || true
  fi
}

# If this is a Nextdoor baked AMI, apt-fast would already be installed and apt
# cache would already be updated as needed by Puppet runs or the Install
# Packages script.
test -e /etc/.nd-baked || refresh_repos
