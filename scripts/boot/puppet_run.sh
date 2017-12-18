#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Puppet - Run
# Description: >
#   Runs puppet on a system after its been configured.
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
#       configuration.
#     Required: true
#     Advanced: false
#     Default: text:puppetca.nextdoor.com
#     Possible Values:
#       - text:puppetca.nextdoor.com
#       - text:puppet-test.service.cloud.nextdoor.com
#
#   PUPPET_DEBUG:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       If enabled, Puppet is run in full debug mode with very loud and verbose
#       output. This should only be used when troubleshooting, and never for
#       general purpose work.
#     Required: true
#     Advanced: true
#     Default: text:false
#     Possible Values:
#       - text:true
#       - text:false
#
#   PUPPET_REPORT:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       If disabled, then Puppet will be configured to not send failure reports
#       to the admin team. This should only be used during debugging.
#     Required: true
#     Advanced: true
#     Default: text:true
#     Possible Values:
#       - text:true
#       - text:false
#
#   PUPPET_ENVIRONMENT:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The Puppet environment to use.
#       configuration.
#     Required: true
#     Advanced: false
#     Default: text:production
#     Possible Values:
#       - text:production
#       - text:staging
# ...

set -e

WAITFORCERT=15
RETRIES=5

# Boot-optimized images (pre-cached AMIs) seem to boot up with LANG=US-ASCII
# which causes Puppet to throw all kinds of errors.
#
# https://tickets.puppetlabs.com/browse/PUP-1386
export LANG=en_US.UTF-8

# Figure out what apt package we need to install to get the right repo
. /etc/profile
PUPPET_VERSION=$(puppet --version)
case ${PUPPET_VERSION:0:1} in
  3) CSR_ATTRIBUTES=/etc/puppet/csr_attributes.yaml
     AGENT_LOCK_FILE=/var/lib/puppet/state/agent_catalog_run.lock
     RUN_SUMMARY_FILE=/var/lib/puppet/state/last_run_summary.yaml
     LAST_RUN_REPORT_FILE=/var/lib/puppet/state/last_run_report.yaml
     _no_stringify_facts='--no-stringify_facts'
     _environment="--environment ${PUPPET_ENVIRONMENT}"
     ;;
  5) CSR_ATTRIBUTES=/opt/puppetlabs/puppet/csr_attributes.yaml
     AGENT_LOCK_FILE=/opt/puppetlabs/puppet/cache/state/agent_catalog_run.lock
     RUN_SUMMARY_FILE=/opt/puppetlabs/puppet/cache/state/last_run_summary.yaml
     LAST_RUN_REPORT_FILE=/opt/puppetlabs/puppet/cache/state/last_run_report.yaml
     ;;
  *) echo 'Invalid Puppet Version Supplied' && exit 1 ;;
esac

# Make absolutely sure our hostname is setup properly. This is checked
# against /etc/hostname and the `domainname` command.
hostname --file /etc/hostname
export DOMAIN=$(domainname)
export HOSTNAME=$(cat /etc/hostname)
echo "FQDN: ${HOSTNAME}.${DOMAIN}"

# Set our verbosity level
if [[ "$PUPPET_DEBUG" == "true" ]]; then
  echo "Puppet DEBUG mode enabled!"
  _puppet_debug="--debug"
fi
if [[ "$PUPPET_REPORT" == "false" ]]; then
  echo "Puppet REPORTS disabled!"
  _puppet_report="--no-report"
fi

# Put together a single variable with our entire puppet run command
CMD="puppet agent -t \
  $_puppet_debug \
  $_puppet_report \
  $_no_stringify_facts \
  $_environment \
  --ca_server ${PUPPET_CA_SERVER} \
  --pluginsync \
  --allow_duplicate_certs \
  --detailed-exitcodes \
  --color false \
  --summarize \
  --server ${PUPPET_SERVER} \
  --waitforcert ${WAITFORCERT}"

# Before we ever try to run puppet ... has Puppet run before? Is it configured?
# Then don't run again because its likely a host reboot.
test -e $LAST_RUN_REPORT_FILE && exit 0

# Ensure that START=no is NOT in the Default Ubuntu /etc/default/puppet setup
# file. This only runs if the file is in place.. and generally happens on
# Puppet 3.x hosts.
test -e /etc/default/puppet && sed -i '/^START=no/d' /etc/default/puppet

# First, begin our outer-loop that maxes out at $RETRIES.
for (( C=1; C<=$RETRIES; C++ )); do
  echo "Puppet Agent execution loop $C/$RETRIES beginning..."

  # Now, first check if puppet is already running. If it is, sleep until
  # its done running. Validate whether or not the lock file contains a PID
  # that is currently executing -- if not, purge the stale lock file.
  while [[ -e "${AGENT_LOCK_FILE}" ]]; do
    PID=$(cat $AGENT_LOCK_FILE)

    echo "$AGENT_LOCK_FILE claims $PID is running... waiting up to 5 seconds."

    if [[ ! -e "/proc/${PID}" ]]; then
      echo "Stale lock file ($AGENT_LOCK_FILE) detected. Purging."
      rm -f $AGENT_LOCK_FILE
      break
    fi

    sleep 5
  done

  # If this host has a pre-existing Puppet state file, it means that Puppet
  # has executed previously ... so we can check whether or not that file
  # indicates any changes were made. If no changes were made, we bail out
  # quickly.
  #
  # Note: This directory is purged by the nd-puppet::clean script, so on
  # a host where Puppet has been run, but then the host has been imaged, this
  # file should not exist and we should skip the check.
  if [[ -e "${RUN_SUMMARY_FILE}" ]] &&
     [[ $(grep 'changed: 0' $RUN_SUMMARY_FILE) ]]; then
     echo "$RUN_SUMMARY_FILE claims zero resources changed. We're done."
     exit 0
  fi

  # Finally, execute Puppet. If puppet exits exits with a >0 exit code,
  # we purge the state files. This is because they will actually write out
  # 'changed: 0' to a state file. The simplest solution is to purge the
  # last run summary file so that our above-check doesnt read it.
  $CMD && exit 0 || rm -f $RUN_SUMMARY_FILE $CSR_ATTRIBUTES
done

# If we get here, then the 'exit 0' above never succeeded and we must have
# a problem
echo "Puppet failed to run cleanly after $RETRIES attempts. Exiting loudly."
exit 1
