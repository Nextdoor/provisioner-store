#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Puppet - Config
# Description: >
#   Configures puppet on a system - handles the basic config, as well as
#   customized Nextdoor-specific configuration files like our facts,
#   csr_attributes and more.
#
# Inputs:
#
#   PUPPET_SERVER:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The Puppet server endpoint to hit on initial configuration.
#     Required: true
#     Advanced: false
#     Default: text:puppet.nextdoor.com
#     Possible Values:
#       - text:puppet.nextdoor.com
#       - text:puppet-test.service.cloud.nextdoor.com
#       - text:puppet.service.nextdoor.com
#       - text:puppet.service.nextdoor-test.com
#
#   PUPPET_CA_SERVER:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The Puppet Certificate Authority endpoint to hit on initial
#       configuration. This is only used for Puppet V3 configurations. Puppet
#       V5+ will just hit our main endpoint.
#     Required: true
#     Advanced: false
#     Default: text:puppetca.nextdoor.com
#     Possible Values:
#       - text:puppetca.nextdoor.com
#       - text:puppet-test.service.cloud.nextdoor.com
#
#   PUPPET_CHALLENGE_PASSWORD:
#     Input Type: single
#     Category: Nextdoor
#     Required: true
#     Advanced: true
#     Default: cred:Puppet Challenge Passphrase
#
#   PUPPET_ENVIRONMENT:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The Puppet environment to use. Note, this is only used on Puppet V3
#       installations.
#     Required: true
#     Advanced: false
#     Default: text:production
#     Possible Values:
#       - text:production
#       - text:staging
#
#   PUPPET_ROLE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The puppet node-name to use to configure the host on bootup.
#     Required: false
#     Advanced: false
#     Default: ignore
#
#   PUPPET_FACTS:
#     Input Type: array
#     Category: Nextdoor
#     Description: >
#       A comma-separated list of KEY=VALUE pairs that will be set as Puppet
#       Facts for the host. These are used to define the host type, setup
#       custom host behaviors and more.
#     Required: false
#     Advanced: false
#     Default: array:[]
#
#   PUPPET_TRUSTED_FACTS:
#     Input Type: array
#     Category: Nextdoor
#     Description: >
#       A comma-separated list of KEY=VALUE pairs that will be turned into
#       attributes added to the /etc/puppet/csr_attributes.yaml file. These
#       attributes are used by Project Zuul to deploy credentials to hosts
#       securely.
#     Required: false
#     Advanced: false
#     Default: array:[]
#
#   INSTANCE_ID:
#     Input Type: single
#     Category: Nextdoor
#     Description: The cloud-specific Instance ID for the host.
#     Required: false
#     Advanced: true
#     Default: env:INSTANCE_ID
#
#   IMAGE_NAME:
#     Input Type: single
#     Category: Nextdoor
#     Description: The cloud-specific image ID
#     Required: false
#     Advanced: true
#     Default: env:EC2_AMI_ID
#
#   DATACENTER:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The cloud-specific Datacenter/Region for this host.
#     Required: false
#     Advanced: true
#
#   ZONE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The cloud-specific zone for this host
#     Required: false
#     Advanced: true
#     Default: env:EC2_AVAILABILITY_ZONE
#
# ...

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t puppet_config) 2>&1

set -e

# Figure out what apt package we need to install to get the right repo
. /etc/profile
PUPPET_VERSION=$(puppet --version)
case ${PUPPET_VERSION:0:1} in
  3) PUPPET_DIR=/etc/puppet
     ;;
  5) PUPPET_DIR=/etc/puppetlabs/puppet
     ;;
  *) echo 'Invalid Puppet Version Supplied' && exit 1 ;;
esac

FACT_DIR=/etc/facter/facts.d
FACT_FILE=$FACT_DIR/nextdoor.txt
CSR_ATTRS=${PUPPET_DIR}/csr_attributes.yaml
PUPPET_ROLE=${PUPPET_ROLE:-None}
PUPPET_SERVER=${PUPPET_SERVER:-puppet.service.nextdoor.com}
PUPPET_ENVIRONMENT=${PUPPET_ENVIRONMENT:-production}
PUPPET_CA_SERVER=${PUPPET_CA_SERVER:-puppetca.nextdoor.com}

# Some day this will allow for outside provisioners - and this variable will be
# used for a host to tell us what kind of provisioner launched it, so that we
# can use different verification methods.
PROVISIONER=${PROVISIONER:-rightscale}
MAC=${MAC:-$(cat /sys/class/net/eth0/address)}

# These facts can be overridden in RightScale - but we default to using the
# Amazon Metadata service to get the info. This will allow us in the future to
# pass in options to this script for different clouds.. but its not necessary
# for now.
IMAGE_NAME=${IMAGE_NAME:-$(curl -s http://169.254.169.254/latest/meta-data/ami-id)}
INSTANCE_ID=${INSTANCE_ID:-$(curl -s http://169.254.169.254/latest/meta-data/instance-id)}
ZONE=${ZONE:-$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)}
DATACENTER=${DATACENTER:-$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone | sed 's/[a-z]$//g')}
OWNER_ID=${OWNER_ID:-$(curl http://169.254.169.254/latest/meta-data/network/interfaces/macs/${MAC}/owner-id)}

echo "Puppet Role: ${PUPPET_ROLE}"

# Dynamically generate a preshared key that will be put into the Puppet CSR
# file. The host will be tagged with this key as well, allowing our Puppet
# masters to verify that this host is in RightScale and in our accounts.
NEW_UUID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)

# Search for the RSC command and validate that its going to work. If it
# doesn't, we won't be able to tag the host, and thus we won't be able to get
# the Puppet SSL certificate validated.
RSC=$(which rsc)
if [[ ! -e $RSC ]]; then
  echo "Could not find the RSC command ... exiting!" && exit 1
fi

# Creates our custom puppet facts directory and files. These are used by Puppet
# to determine what node-type we are and more.
function create_facts() {
  mkdir -p $FACT_DIR
  test -e $FACT_FILE && echo "$FACT_FILE exists... skipping creation" && return

  # Set up the required and automatic facts...
  cat << EOF > $FACT_FILE
puppet_server=$PUPPET_SERVER
puppet_ca_server=$PUPPET_CA_SERVER
puppet_environment=$PUPPET_ENVIRONMENT
role=$PUPPET_ROLE
EOF

  IFS=","
  for fact in $PUPPET_FACTS; do
    echo "$fact" >> $FACT_FILE
  done

  echo "--- $FACT_FILE ---"
  cat $FACT_FILE
  echo "--- END ---"
}

# Creates the csr_attributes.yaml file if the SSL certs have not yet been built
function create_csr_attributes() {
  test -e '/var/lib/puppet/ssl' && \
          echo "SSL directory already exists..." && \
          return

  create_tag "nd:puppet_state=waiting"
  create_tag "nd:puppet_secret=${NEW_UUID}"

  cat > $CSR_ATTRS << YAML
custom_attributes:
  # challenge_password
  1.2.840.113549.1.9.7: ${PUPPET_CHALLENGE_PASSWORD}

  # pp_preshared_key
  1.3.6.1.4.1.34380.1.1.4: ${NEW_UUID}

  # pp_provisioner
  1.3.6.1.4.1.34380.1.1.17: ${PROVISIONER}

  # pp_region
  1.3.6.1.4.1.34380.1.1.18: ${DATACENTER}

  # pp_datacenter
  1.3.6.1.4.1.34380.1.1.19: ${DATACENTER}

extension_requests:
  # pp_instance_id
  1.3.6.1.4.1.34380.1.1.2: ${INSTANCE_ID}

  # pp_image_name
  1.3.6.1.4.1.34380.1.1.3: ${IMAGE_NAME}

  # pp_role
  1.3.6.1.4.1.34380.1.1.13: ${PUPPET_ROLE}

  # pp_department
  1.3.6.1.4.1.34380.1.1.15: ${OWNER_ID}

  # pp_provisioner
  1.3.6.1.4.1.34380.1.1.17: ${PROVISIONER}

  # pp_region
  1.3.6.1.4.1.34380.1.1.18: ${DATACENTER}

  # pp_datacenter
  1.3.6.1.4.1.34380.1.1.19: ${DATACENTER}

  # pp_hostname
  1.3.6.1.4.1.34380.1.1.25: $(hostname)

YAML

  IFS=","
  for fact in $PUPPET_TRUSTED_FACTS; do
    line="  $(echo $fact | sed 's/=/: /g')"
    echo "$line" >> $CSR_ATTRS
  done

}

# Simple wrapper for creating a Puppet tag...
create_tag() {
  echo "Creating tag $1 on $SELF_HREF..."
  rsc --rl10 cm15 multi_add /api/tags/multi_add resource_hrefs[]=$SELF_HREF tags[]=$1
}

# Begin our real logic now
set -e

# Verify that we can get our own HREF from the RSC command. If we can't, then
# RSC/RL10 must not be configured properly.
SELF_HREF=$(rsc --rl10 --x1 'object:has(.rel:val("self")).href' cm15 index_instance_session sessions/instance)

# Create our facts/attributes
create_facts
create_csr_attributes
