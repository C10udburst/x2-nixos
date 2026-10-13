#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

# Visual styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

REPO_URL="https://gitea.home.praworzadnyzly.pl/miecz/x2-nixos.git"
TARGET_DISK="/dev/nvme0n1"

cleanup() {
  echo -e "\n${YELLOW}[!] Script interrupted or finished.${NC}"
}
trap cleanup EXIT

# 0. Check network
echo -e "${BLUE}==>${NC} Checking internet connectivity..."
if ! ping -c 1 -W 5 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 5 8.8.8.8 >/dev/null 2>&1; then
  whiptail --title "ERROR: Network Offline" \
           --msgbox "No internet connection detected!\n\nPlease configure ethernet or Wi-Fi before running the installer.\nYou can use 'nmtui' to connect." 12 60
  exit 1
fi

# 1. Ask for 'miecz' user password
PASS_1=""
PASS_2=""
while true; do
  PASS_1=$(whiptail --title "User Setup: miecz" \
                    --passwordbox "Enter password for user 'miecz':" 10 50 \
                    3>&1 1>&2 2>&3) || {
    echo -e "${RED}[X] Installation aborted by user.${NC}"
    exit 1
  }

  if [ -z "$PASS_1" ]; then
    whiptail --title "Error" --msgbox "Password cannot be empty. Please try again." 8 45
    continue
  fi

  PASS_2=$(whiptail --title "User Setup: miecz" \
                    --passwordbox "Confirm password for user 'miecz':" 10 50 \
                    3>&1 1>&2 2>&3) || {
    echo -e "${RED}[X] Installation aborted by user.${NC}"
    exit 1
  }

  if [ "$PASS_1" = "$PASS_2" ]; then
    break
  else
    whiptail --title "Mismatch" --msgbox "Passwords do not match. Please try again." 8 45
  fi
done

# 2. Warning dialog
whiptail --title "WARNING: DATA DESTRUCTION" \
         --yesno "WARNING: Everything on ${TARGET_DISK} will be permanently erased!\n\nThis will partition ${TARGET_DISK} with Btrfs (@, @nix, @home, @srv) and install NixOS for GMKtec EVO-X2.\n\nAre you sure you want to proceed?" 14 65 || {
  echo -e "${YELLOW}[!] Aborted by user. No disks were modified.${NC}"
  exit 0
}

# 3. Clone repo to temp directory & test eval
WORK_DIR=$(mktemp -d /tmp/x2-nixos-install.XXXXXX)
echo -e "${BLUE}==>${NC} Cloning repository from ${REPO_URL} into ${WORK_DIR}..."
git clone "${REPO_URL}" "${WORK_DIR}"

echo -e "${BLUE}==>${NC} Testing evaluation of nixosConfigurations.evo-x2..."
nix eval --extra-experimental-features "nix-command flakes" \
  "${WORK_DIR}#nixosConfigurations.evo-x2.config.system.build.toplevel.drvPath"

# 4. Partition and format disk using disko
echo -e "${BLUE}==>${NC} Running Disko partitioning and filesystem creation..."
nix --extra-experimental-features "nix-command flakes" \
  run github:nix-community/disko -- --mode zap_create_mount "${WORK_DIR}/disko.nix"

# 5. Install NixOS to /mnt
echo -e "${BLUE}==>${NC} Installing NixOS onto target system (/mnt)..."
nixos-install --no-root-passwd --flake "${WORK_DIR}#evo-x2"

# 6. Set password for user 'miecz' in /mnt
echo -e "${BLUE}==>${NC} Setting password for user 'miecz'..."
# Set user password inside target system
nixos-enter -- root -c "echo 'miecz:${PASS_1}' | chpasswd"

# 7. Clone repo to /etc/nixos/configuration and configure nixconfig permissions
echo -e "${BLUE}==>${NC} Setting up /etc/nixos/configuration editable by 'nixconfig' group..."
TARGET_CONF="/mnt/etc/nixos/configuration"
mkdir -p "$(dirname "${TARGET_CONF}")"
git clone "${REPO_URL}" "${TARGET_CONF}"

# Ensure nixconfig group has full write permissions
# Look up GID of nixconfig in target system /mnt/etc/group
NIXCONFIG_GID=$(grep '^nixconfig:' /mnt/etc/group | cut -d: -f3 || true)
if [ -n "${NIXCONFIG_GID}" ]; then
  chown -R "root:${NIXCONFIG_GID}" "${TARGET_CONF}"
else
  # Fallback to group name inside nixos-enter
  nixos-enter -- root -c "chown -R root:nixconfig /etc/nixos/configuration" || true
fi
chmod -R g+rwX "${TARGET_CONF}"
chmod g+s "${TARGET_CONF}"

# Sync filesystems
sync

echo -e "${GREEN}${BOLD}==> Installation successfully completed!${NC}"
echo -e "${GREEN}You can now reboot into your new NixOS system.${NC}"
whiptail --title "Success" --msgbox "NixOS has been successfully installed!\n\nYou may now remove the installer USB drive and reboot." 10 50
