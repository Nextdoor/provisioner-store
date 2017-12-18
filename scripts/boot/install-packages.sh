#! /bin/bash
# ---
# RightScript Name: SYS packages install
# Description: |
#   Installs packages required by RightScripts, or extra packages.
#   To handle naming variations, prefix package names with "yum:" or "apt:".
# Inputs:
#   PACKAGES:
#     Input Type: single
#     Category: RightScale
#     Description: Space-separated list of additional packages.
#     Default: blank
#     Required: false
#     Advanced: true
# ...

# http://urbanautomaton.com/blog/2014/09/09/redirecting-bash-script-output-to-syslog/
exec 1> >(logger -s -t install_packages) 2>&1

shopt -s expand_aliases

APT=$(which apt-fast || which apt-get)

if [ -z "$RS_PACKAGES" -a -z "$PACKAGES" ]; then
  echo "No packages to install"
  exit 0
fi

if [ -n "$PACKAGES" -a -n "$RS_PACKAGES" ]; then
  packages="$RS_PACKAGES $PACKAGES"
elif [ -n "$PACKAGES" ]; then
  packages=$PACKAGES
else
  packages=$RS_PACKAGES
fi

if which apt-get > /dev/null 2>&1; then
  pkgman=apt
  alias repo_update='sudo apt-get clean && sudo rm -rf /var/lib/apt/lists/* && sudo apt-get update'
  INSTALLED_PACKAGES=$(sudo dpkg --get-selections | grep -v deinstall | awk '{print $1}')
elif which yum > /dev/null 2>&1; then
  pkgman=yum
  alias repo_update='sudo yum update'
  INSTALLED_PACKAGES=$(sudo yum list -q installed | tail -n +2 | awk '{print $1}')
fi

if [ -z "$pkgman" ]; then
  echo "ERROR: Unrecognized package manager, but we have packages to install"
  exit 1
else
  echo "Detected package manager: $pkgman"
fi

# Run passed-in command with retries if errors occur. This was pulled from
# Rightscale's stock RightScripts.
function retry_command() {
  # Setting config variables for this function
  retries=3
  wait_time=5

  while [ $retries -gt 0 ]; do
    # Reset this variable before every iteration to be checked if changed
    issue_running_command=false
    $@ || { issue_running_command=true; }
    if [ "$issue_running_command" = true ]; then
      (( retries-- ))
      echo "Error occurred - will retry shortly..."
      if [[ "$REPO_UPDATE_RAN" != "1" ]]; then
        echo "Trying a repo update because of run failure..."
        REPO_UPDATE_RAN=1
        repo_update
      fi
      sleep $wait_time
    else
      # Break out of loop since command was successful.
      break
    fi
  done

  # Check if issue running command still existed after all retries
  if [ "$issue_running_command" = true ]; then
    echo "ERROR: Unable to run: '$@'"
    return 1
  fi
}

# We use this to prevent the apt cache from being updated unless it's needed
# to install a new package.
function sudo_apt_package_install() {
  set +e
  sudo apt-get install --dry-run $@ |grep -E -q '0 newly installed'
  set -e
  REQUIRE_APT_UPDATE=$?
  if [[ "$REQUIRE_APT_UPDATE" != "0" ]] && [[ "$REPO_UPDATE_RAN" != "1" ]]; then
    REPO_UPDATE_RAN=1
    retry_command repo_update
  fi

  DEBIAN_FRONTEND=noninteractive retry_command sudo $APT install -y $@
}

# Determine which packages are suitable for install on this system.
declare -a list
sz=0
for pkg in $packages; do
  echo $pkg | grep --extended-regexp --quiet '^[a-z0-9_]+:'
  selective=$?
  echo $pkg | grep --extended-regexp --quiet "^$pkgman:"
  matching=$?
  pkg=`echo $pkg | sed -e s/^$pkgman://`

  # Package is selective (begins with pkgman:) AND the pkgman matches ours;
  # it is a candidate for install, or
  # Package is not selective (it has the same name for every pkgman). It is
  # a candidate for install.
  if [ $selective == 0 -a $matching == 0 ] || [ $selective != 0 ]; then
    # Do not install any packages that are already installed.
    INSTALLED=$(echo "${INSTALLED_PACKAGES}" | grep -x $pkg)

    if [[ ! -n "$INSTALLED" ]]; then
      list[$sz]=$pkg
      let sz=$sz+1
    fi
  fi
done

if [ -n "$list" ]; then
  echo "Packages required on this system: ${list[*]}"
else
  echo "No required packages on this system. Already installed: $packages"
  exit 0
fi

set -e
case $pkgman in
  yum)
    sudo yum install -y ${list[*]}
    ;;
  apt)
    sudo_apt_package_install ${list[*]}
    ;;
  *)
    echo "INTERNAL ERROR in RightScript (unrecognized pkgman $pkgman)"
    exit 2
    ;;
esac
set +e
