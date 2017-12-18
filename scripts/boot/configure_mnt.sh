#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Configure Mount Volume
# Description: >
#   Configures the /mnt volume on the host based on the supplied inputs.
#
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
#   STORAGE_SCRIPT_BRANCH:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       The Github Branch of code to pull down for the storage scripts.
#     Required: true
#     Advanced: true
#     Default: text:master
#
#   STORAGE_NO_PARTITIONS_EXIT_CODE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       Set the exit code to throw if no disk volumes can be found to create a
#       /mnt volume. By default this is 1 so that an error is raised. Can be
#       set to 0 if you know what you're doing.
#     Required: true
#     Advanced: true
#     Default: text:1
#     Possible Values:
#       - text:1
#       - text:0
#
#   STORAGE_EBS_TYPE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       gp2 for General Purpose (SSD) volumes, io1 for Provisioned IOPS (SSD)
#       volumes, or standard for Magnetic volumes. If you choose io1, you'll
#       get 4000 IOPS.
#     Required: true
#     Advanced: false
#     Default: text:gp2
#     Possible Values:
#       - text:gp2
#       - text:standard
#       - text:io1
#
#   STORAGE_SIZE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       IF STORAGE_TYPE == EBS: This is the total size of the array to create.
#       (in GB)
#     Required: false
#     Advanced: false
#
#   STORAGE_TYPE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       If storage type is 'instance', local normal storage is used. If type is
#       'ebs', a whole new set of EBS volumes will be created. If
#       'remount_ebs', we will re-mount EBS volumes supplied in the
#       STORAGE_VOLIDLIST
#     Required: true
#     Advanced: false
#     Default: text:instance
#     Possible Values:
#       - text:instance
#       - text:ebs
#
#   STORAGE_VOLCOUNT:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       IF STORAGE_TYPE == EBS: The number of volumes to create within EC2 and join to the RAID array.
#     Required: true
#     Advanced: false
#     Default: text:1
#     Possible Values:
#       - text:1
#       - text:2
#       - text:4
#
#   STORAGE_ENABLE_BCACHE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       Whether or not to enable the Block Caching of EBS storage to the local
#       SSDs. This is generally determined automatically -- only explicitly set
#       this if you know for sure that you need it, and that the scripts won't
#       do it automatically.
#     Required: true
#     Advanced: true
#     Default: text:0
#     Possible Values:
#       - text:0
#       - text:1
#
#   STORAGE_FSTYPE:
#     Input Type: single
#     Category: Nextdoor
#     Description: What filesystem type to format /mnt with.
#     Required: true
#     Advanced: true
#     Default: text:ext4
#     Possible Values:
#       - text:xfs
#       - text:ext4
#
#   STORAGE_MOUNT_OPTS:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       What filesystem options are applid at mount-time for the
#       volume.
#     Required: false
#     Advanced: true
#     Default: text:defaults,nobootwait,discard
#     Possible Values:
#       - text:defaults,nobootwait,discard
#
#   STORAGE_BLOCK_SIZE:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       Set the storage RAID Block Size. Without a setting, the storage scripts
#       automatically determine the correct block size.
#     Required: false
#     Advanced: true
#     Possible Values:
#       - text:256
#       - text:512
#       - text:2048
#
#   STORAGE_RAID_LEVEL:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       RAID level to use (0, 1, 5 or 10)
#     Required: false
#     Advanced: true
#     Default: text:0
#     Possible Values:
#       - text:0
#       - text:1
#       - text:5
#       - text:10
# ...

set -e

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t configure_mnt) 2>&1

# If we ran this before, bail
test -e /etc/.volumeized && exit 0

export DEBIAN_FRONTEND=noninteractive

# Make absolutely sure that /mnt isn't mounted before we begin working. Back in
# RL6 days, this was automatic ... but in RL10 days its not.
umount -f /mnt || echo "/mnt was already unmounted"

# Rename a few variables that were supplied so they work with the scripts we
# downloaded. Export the rest of the variables to make sure they're absolutely
# set properly for all the subsequent scripts.
export STORAGE_SCRIPT_BRANCH STORAGE_RAID_LEVEL STORAGE_FSTYPE
export STORAGE_BLOCK_SIZE STORAGE_NO_PARTITIONS_EXIT_CODE
export MOUNT_OPTS=${STORAGE_MOUNT_OPTS}
export ENABLE_BCACHE=${STORAGE_ENABLE_BCACHE}
export EBS_TYPE=${STORAGE_EBS_TYPE}

echo "Downloading Storage-Scripts to $RS_ATTACH_DIR"

URL=https://github.com/diranged/storage-scripts/tarball/${STORAGE_SCRIPT_BRANCH}

mkdir -p $RS_ATTACH_DIR && pushd $RS_ATTACH_DIR
curl --location --silent $URL | sudo tar zx --strip-components 1

DRY=0 VERBOSE=1 FORCE=1 ./setup.sh

# Create /mnt/tmp dir
mkdir -p /mnt/tmp
chmod 1777 /mnt/tmp

# Ensure we never run this again
touch /etc/.volumeized
