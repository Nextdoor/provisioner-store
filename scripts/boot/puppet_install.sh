#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Puppet - Install
# Description: >
#   Installs Puppet on a system. Does not handle configuration or execution.
#
# Inputs:
#
#   PUPPET_VERSION:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       String with the version of Puppet to install
#     Required: false
#     Advanced: true
#     Default: text:3.8.7-1puppetlabs1
#     Possible Values:
#       - text:3.8.7-1puppetlabs1
#       - text:5.3.2-1
# ...

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t puppet_install) 2>&1

LSB_RELEASE=$(which lsb_release)
YUM=$(which yum)
APT=$(which apt-fast || which apt-get)
CURL=$(which curl)
CURL_OPTS="--silent --fail --retry 3 --retry-delay 10 --connect-timeout 10 --speed-limit 10240"

export DEBIAN_FRONTEND=noninteractive

# First, figure out what kind of OS we're on. If the lsb_release tools aren't
# in place, we're in big trouble. They should be required by the 'package'
# parameter in Kingpin when this script is pushed to RightScale.
if [[ -z "$LSB_RELEASE" ]]; then
  echo "Missing the lsb_release toolset. Exiting!" && exit 1
fi
if [[ -z "$CURL" ]]; then
  echo "Missing curl. Exiting!" && exit 1
fi

# Next, are we using APT or YUM? Neither? Really fail then!
if [[ ! -z "$APT" ]]; then
  PACKAGE_MGR=apt
elif [[ -z "$YUM" ]]; then
  PACKAGE_MGR=yum
else
  echo "Could not find APT or YUM package managers. Exiting!"
  exit 1
fi

# Ok, get some version information dynamically
CODENAME=$(lsb_release -s -c)

function install_yum() {
  echo "Not Supported Yet"
  exit 1
}

function install_apt() {
  echo "Checking if puppet is already installed or not..."
  dpkg -s puppet && echo "Puppet already installed, exiting cleanly!" && exit 0

  # Figure out what apt package we need to install to get the right repo
  case ${PUPPET_VERSION:0:1} in
    "") REPO_PACKAGE=puppet5-release-${CODENAME}.deb
        PACKAGE_NAME=puppet-agent
        PACKAGE_FQDN=${PACKAGE_NAME}
        ;;
    3) REPO_PACKAGE=puppetlabs-release-${CODENAME}.deb
       PACKAGE_NAME=puppet
       PACKAGE_FQDN=${PACKAGE_NAME}=${PUPPET_VERSION}
       ;;
    5) REPO_PACKAGE=puppet5-release-${CODENAME}.deb
       PACKAGE_NAME=puppet-agent
       PACKAGE_FQDN=${PACKAGE_NAME}=${PUPPET_VERSION}${CODENAME}
       ;;
    *) echo 'Invalid Puppet Version Supplied' && exit 1 ;;
  esac

  echo "Installing Puppet on an Apt-based system..."
  ${CURL} ${CURL_OPTS} -O https://apt.puppetlabs.com/${REPO_PACKAGE} && dpkg -i ${REPO_PACKAGE}
  ${APT} update -qq

  # Now, install puppet if its missing.
  $APT install -y --upgrade --reinstall -qq ethtool ${PACKAGE_FQDN}

  . /etc/profile
  echo "Installed Puppet: $(puppet --version)"
}

# Ok, do our main logic here
set -e

# First, before we do _anything_ .. is puppet already installed? If so, bail
# quietly and happily!
case $PACKAGE_MGR in
  apt)
    install_apt
    ;;
  yum)
    install_yum
    ;;
  *)
    echo "Unsupported OS detected."
    exit 1
    ;;
esac

