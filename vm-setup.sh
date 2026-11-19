#!/bin/bash
# Prepare a fresh Ubuntu 24.04 x86_64 VM to simulate an unprivileged HPC user.
# Run as the VM's default user (with sudo), from this directory:
#
#   bash vm-setup.sh SMALLPKG
#
# SMALLPKG is the CRAN name of a package with a handful of reverse
# dependencies, used for the smoke run; pick one whose revdeps need some
# system libraries so the sudo path gets exercised. data.table is always
# included in the image.
set -euo pipefail

SMALLPKG=${1:?usage: bash vm-setup.sh SMALLPKG}
TEST_USER=${TEST_USER:-hpcuser}
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# shellcheck source=/dev/null
. /etc/os-release
if [ "$ID" != ubuntu ] || [ "$(uname -m)" != x86_64 ]; then
  echo "expected an Ubuntu x86_64 VM, found ${PRETTY_NAME:-unknown} on $(uname -m)" >&2
  exit 1
fi

echo "== Installing Docker and Apptainer"
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io software-properties-common tmux
sudo add-apt-repository -y ppa:apptainer/ppa
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y apptainer

# Ubuntu 24.04 restricts unprivileged user namespaces, which non-setuid Apptainer needs.
if [ -e /proc/sys/kernel/apparmor_restrict_unprivileged_userns ]; then
  echo 'kernel.apparmor_restrict_unprivileged_userns = 0' |
    sudo tee /etc/sysctl.d/90-apptainer-userns.conf > /dev/null
  sudo sysctl -q -p /etc/sysctl.d/90-apptainer-userns.conf
fi

echo "== Building the image (slow: data.table's revdeps need many system libraries)"
# shellcheck disable=SC2024 # the shell reads Dockerfile; docker gets it on stdin
sudo docker build --build-arg PKGS="data.table $SMALLPKG" -t revdeprun-hpc - < Dockerfile

echo "== Converting the image to revdeprun.sif"
# shellcheck disable=SC2024 # the archive should be owned by this user
sudo docker save revdeprun-hpc > revdeprun-hpc.tar
apptainer build --force revdeprun.sif docker-archive://revdeprun-hpc.tar
rm -f revdeprun-hpc.tar

echo "== Creating the unprivileged test user $TEST_USER (no sudo, no docker group)"
if ! id "$TEST_USER" > /dev/null 2>&1; then
  sudo useradd -m -s /bin/bash "$TEST_USER"
fi
sudo install -o "$TEST_USER" -g "$TEST_USER" -m 644 revdeprun.sif "/home/$TEST_USER/"
sudo install -o "$TEST_USER" -g "$TEST_USER" -m 755 \
  revdep-apptainer.sh preflight.sh vm-validate.sh "/home/$TEST_USER/"

cat << EOF

Done. Next, ideally inside tmux (tmux new -s revdep):
  sudo -iu $TEST_USER bash vm-validate.sh https://github.com/OWNER/$SMALLPKG.git
EOF
