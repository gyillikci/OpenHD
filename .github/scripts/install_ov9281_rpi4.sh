#!/bin/bash
# Installs OpenHD with OV9281 support (camera type 49) on a Raspberry Pi 4 /
# CM4 with the OpenHD 2.6.4 image, which does not install update packages by
# itself. Run it on the Pi, from the folder with the two .deb files:
#   sudo bash /boot/openhd/ov9281/install.sh air      (air unit with the OV9281)
#   sudo bash /boot/openhd/ov9281/install.sh ground   (ground station)
# The Pi reboots when it is done.
set -euo pipefail

role="${1:-}"
if [[ "${role}" != air && "${role}" != ground ]]; then
  echo "Usage: sudo bash $0 air|ground" >&2
  exit 2
fi
if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
openhd_debs=("${dir}"/openhd_*_armhf.deb)
sysutils_debs=("${dir}"/openhd-sys-utils_*_armhf.deb)
shopt -u nullglob
if [[ ${#openhd_debs[@]} -ne 1 || ${#sysutils_debs[@]} -ne 1 ]]; then
  echo "${dir} needs exactly one openhd_*_armhf.deb and one openhd-sys-utils_*_armhf.deb" >&2
  exit 1
fi

# OpenHD-SysUtils reads the role and the camera from settings.json on the FAT
# partition (openhd/settings.json is the file the OpenHD ImageWriter writes,
# a settings.json next to config.txt takes precedence) and then deletes it.
boot=/boot
if [[ -f /boot/firmware/config.txt ]]; then
  boot=/boot/firmware
fi
settings="${boot}/openhd/settings.json"
if [[ -f "${boot}/settings.json" ]]; then
  settings="${boot}/settings.json"
fi
python3 - "${settings}" "${role}" <<'EOF'
import json
import os
import sys

path, role = sys.argv[1:3]
settings = {}
if os.path.exists(path):
    try:
        with open(path) as f:
            settings = json.load(f)
    except ValueError as e:
        sys.exit(f"{path} is not valid JSON ({e}), fix or delete it")
settings["role"] = role
if role == "air":
    settings["camera"] = "49"
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(settings, f, indent=4)
    f.write("\n")
print(f"{path}: role {role}" + (", camera 49 (OV9281)" if role == "air" else ""))
EOF

# On a reinstall, let OpenHD-SysUtils run its first-start tasks again, so it
# applies the camera from the settings above.
sysutils_config=/usr/local/share/OpenHD/SysUtils/config.json
if [[ -f "${sysutils_config}" ]]; then
  sed -i 's/"firstboot": false/"firstboot": true/' "${sysutils_config}"
fi
sync

echo "Installing ${openhd_debs[0]##*/}"
dpkg -i "${openhd_debs[0]}"
# OpenHD-SysUtils last: its postinst starts it, and on its first start it
# writes the camera overlay to config.txt and reboots the Pi.
echo "Installing ${sysutils_debs[0]##*/}"
dpkg -i "${sysutils_debs[0]}"

echo "Waiting for OpenHD-SysUtils to finish its first start, then the Pi reboots"
for _ in $(seq 60); do
  if grep -qs '"firstboot": false' "${sysutils_config}"; then
    break
  fi
  sleep 1
done
sync
systemctl reboot
