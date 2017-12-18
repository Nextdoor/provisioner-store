#!/usr/bin/sudo /bin/bash
# ---
# RightScript Name: Nextdoor - Patch System and Reboot
# Description: >
#   Optionally patches a system and then reboots it during the setup process.
#   This is typically used for doing things like upgrading a kernel, which is
#   an operation that should always happen long before we ever install software
#   or services on the host.
#
# Inputs:
#
#   UPGRADE_KERNEL:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       Name of the kernel package we should upgrade. Example,
#       linux-image-virtual just upgrades the default image thats there to the
#       latest patch release. linux-image-virtual-lts-xenial updates to the
#       latest 4.4.0 backported kernel from the Ubuntu team.
#     Required: false
#     Advanced: true
#     Default: ignore
#
#   UPGRADE_IXGBEVF:
#     Input Type: single
#     Category: Nextdoor
#     Description: >
#       Installs a specific version of the IXGBEVF driver. Just enter the version number, ie: 2.16.4.
#     Required: false
#     Advanced: true
#     Default: ignore
#     Possible Values:
#       - text:2.16.4
# ...

set -e
set -x

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t patch_system_and_reboot) 2>&1

APT=$(which apt-fast || which apt-get)
TOUCH_FILE=/etc/.updates_done
export DEBIAN_FRONTEND=noninteractive
IXGBEVF_URL="https://downloadmirror.intel.com/25723/eng/ixgbevf-${UPGRADE_IXGBEVF}.tar.gz"

# If we've been run before, bail!
test -e $TOUCH_FILE && exit 0

# Make sure that if we do any upgrades at all, that the
# various system components are updated appropriately
cat << EOF > /etc/kernel-img.conf
do_symlinks = yes
relative_links = yes
do_bootloader = no
do_bootfloppy = no
do_initrd = yes
link_in_boot = no
postinst_hook = update-grub
postrm_hook = update-grub
EOF

if [[ "$UPGRADE_KERNEL" ]]; then
  echo "NOTICE: UPGRADE_KERNEL set to \"$UPGRADE_KERNEL\" ... will reboot after kernel upgrade."
  $APT install -y -f --install-recommends $UPGRADE_KERNEL
  rm /boot/grub/menu.lst
  update-grub-legacy-ec2 -y
  cat /boot/grub/menu.lst
  REBOOT=1
fi

# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/sriov-networking.html
if [[ "$UPGRADE_IXGBEVF" ]]; then
  echo "NOTICE: UPGRADE_IXGBEVF set to \"$UPGRADE_IXGBEVF\" ... will reboot."
  test -e /usr/sbin/dkms || $APT install -y -f dkms

  if [[ ! -e /usr/src/ixgbevf-${UPGRADE_IXGBEVF} ]]; then
    curl --verbose --location --retry 3 -O "$IXGBEVF_URL"
    tar -xzf ixgbevf-${UPGRADE_IXGBEVF}.tar.gz
    mv --force ixgbevf-${UPGRADE_IXGBEVF} /usr/src/
  fi

  cat << EOF > /usr/src/ixgbevf-${UPGRADE_IXGBEVF}/dkms.conf
PACKAGE_NAME="ixgbevf"
PACKAGE_VERSION="${UPGRADE_IXGBEVF}"
CLEAN="make -C src/ clean"
MAKE="make -C src/ KERNELDIR=/lib/modules/\${kernelver}/build BUILD_KERNEL=\${kernelver}"
BUILT_MODULE_LOCATION[0]="src/"
BUILT_MODULE_NAME[0]="ixgbevf"
DEST_MODULE_LOCATION[0]="/updates"
DEST_MODULE_NAME[0]="ixgbevf"
AUTOINSTALL="yes"
EOF

  test -e /var/lib/dkms/ixgbevf/${UPGRADE_IXGBEVF} || dkms add -m ixgbevf -v ${UPGRADE_IXGBEVF}
  dkms build -m ixgbevf -v ${UPGRADE_IXGBEVF}
  dkms install -m ixgbevf -v ${UPGRADE_IXGBEVF}
  ls /var/lib/initramfs-tools | xargs -n1 /usr/lib/dkms/dkms_autoinstaller start
  update-initramfs -c -k all
  REBOOT=1
fi

# If any reboot-worthy changes were made, do it.
if [[ "$REBOOT" -eq 1 ]]; then

  # If touching the file fails for any reason, we don't do a reboot
  # because doing so would put us into a reboot loop.
  touch $TOUCH_FILE

  if [[ -e /usr/bin/rs_shutdown ]]; then
    # Rightlink 6 support
    rs_shutdown --reboot --immediately
  else
    # Rightlink 10 doesn't have the rs_shutdown command, so it doesn't
    # know when we start the reboot that we want to cancel all other
    # scripts that are queued up. To combat this (and prevent a script
    # from starting, but then dying mid-run), we wait indefinitely after
    # the reboot command has been called. This prevents any other scripts
    # from running. Unfortunately this has the side effect of looking
    # like a failed script run when linux finally issues the sigterm to
    # us..
    reboot

    echo "Waiting for script to be auto-terminated by the reboot command..."
    sleep 90
  fi
fi
