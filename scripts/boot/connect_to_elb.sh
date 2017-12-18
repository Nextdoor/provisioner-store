#!/usr/bin/env bash
#
# ---
# RightScript Name: Nextdoor - Connect to ELB
# Description: >
#   Connects the host to an ELB on bootup.
# Inputs:
#
#   AWS_ACCESS_KEY_ID:
#     Input Type: single
#     Category: Nextdoor
#     Description: Amazon Access Key ID
#     Required: true
#     Advanced: true
#     Default: cred:AWS_ACCESS_KEY_ID
#
#   AWS_SECRET_ACCESS_KEY:
#     Input Type: single
#     Category: Nextdoor
#     Description: Amazon Secret Access Key
#     Required: true
#     Advanced: true
#     Default: cred:AWS_SECRET_ACCESS_KEY
#
#   KINGPIN_RELEASE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The pre-built release name of Kingpin to download and use. Must be a
#       release available at https://github.com/Nextdoor/kingpin/releases with
#       a properly built kingpin.zip file.
#     Required: true
#     Advanced: true
#     Default: text:pre_release
#
#   ELB_NAME:
#     Input Type: single
#     Category: Nextdoor
#     Description: The friendly name of the ELB.
#     Required: false
#     Advanced: false
#     Default: ignore
#
#   ELB_INSTANCE_ID:
#     Input Type: single
#     Category: Nextdoor
#     Description: The Instance ID of the host to add/delete from the ELB.
#     Required: false
#     Advanced: true
#     Default: env:INSTANCE_ID
#
#   ELB_REGION:
#     Input Type: single
#     Category: Nextdoor
#     Description: The region/zone that the instance and ELB resides in.
#     Required: false
#     Advanced: true
#     Default: env:EC2_AVAILABILITY_ZONE
# ...

set +x  # Don't print commands before executing them
set -e  # Exit loudly if any of the executing commands fail

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t connect_to_elb) 2>&1

# Confirming Environment Variables
if [ -z "$ELB_NAME" ]; then
    echo "ELB_NAME not set. Exiting quietly."
    exit 0
fi

if [ "$ELB_NAME" == "*" ]; then
    echo "ELB_NAME set to * -- not joining any ELBs, but the Disconnect script will work."
    exit 0
fi

ELB_ENABLE_ALL_ZONES=${ELB_ENABLE_ALL_ZONES:-False}

target_dir="$HOME/kingpin"
source="https://github.com/Nextdoor/kingpin/releases/download/${KINGPIN_RELEASE}/kingpin.zip"

# "Install" kingpin - note, this is required because the Boto package
# doesn't play well when stuck inside a zip file.
wget --no-verbose $source -O kingpin.zip
mkdir -p $target_dir
unzip -q -o -u kingpin.zip -d $target_dir

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
export SKIP_DRY=1

python $target_dir \
  --actor aws.elb.RegisterInstance \
  --option region=$ELB_REGION \
  --option elb=$ELB_NAME \
  --option enable_zones=$ELB_ENABLE_ALL_ZONES \
  --option instances=$ELB_INSTANCE_ID
