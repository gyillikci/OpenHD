#!/bin/bash
# Installs OpenHD with OV9281 support (camera type 49) on a Raspberry Pi 4 /
# CM4 with the OpenHD 2.6.4 image, which does not install update packages by
# itself. Run it on the Pi, from the folder with the .deb files:
#   sudo bash /boot/openhd/ov9281/install.sh air      (air unit with the OV9281)
#   sudo bash /boot/openhd/ov9281/install.sh ground   (ground station)
# The Pi reboots when it is done. Running it again is fine, on the air unit it
# resets the camera settings to the OV9281 defaults.
set -euo pipefail

role="${1:-}"
if [[ "${role}" != air && "${role}" != ground ]]; then
  echo "Usage: sudo bash $0 air|ground" >&2
  exit 2
fi
if [[ ${EUID} -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

boot=/boot
if [[ -f /boot/firmware/config.txt ]]; then
  boot=/boot/firmware
fi
# The image formats its recordings partition on the second boot and reboots
# again, which would cut off the installation.
if [[ -e "${boot}/openhd/resize.txt" ]]; then
  echo "The Pi is still doing its first-boot setup and reboots by itself." >&2
  echo "Wait for that reboot, then run this again." >&2
  exit 1
fi

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
shopt -s nullglob
openhd_debs=("${dir}"/openhd_*_armhf.deb)
sysutils_debs=("${dir}"/openhd-sys-utils_*_armhf.deb)
qopenhd_debs=("${dir}"/qopenhd_*_armhf.deb)
shopt -u nullglob
if [[ ${#openhd_debs[@]} -ne 1 || ${#sysutils_debs[@]} -ne 1 || ${#qopenhd_debs[@]} -gt 1 ]]; then
  echo "${dir} needs exactly one openhd_*_armhf.deb and one openhd-sys-utils_*_armhf.deb" >&2
  exit 1
fi

# OpenHD-SysUtils reads the role and the camera from settings.json on the FAT
# partition (openhd/settings.json is the file the OpenHD ImageWriter writes,
# a settings.json next to config.txt takes precedence) and then deletes it.
# The air.txt / ground.txt markers of older ImageWriter versions would
# override the role, so they go.
rm -f "${boot}"/openhd/{air,ground,record}.txt
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
if [[ "${role}" == air ]]; then
  # OpenHD only takes the camera type from OpenHD-SysUtils when it creates its
  # camera settings. Settings an earlier OpenHD (2.6.4 as air) left behind
  # would keep the old camera.
  rm -f /usr/local/share/openhd/video/air_camera_generic.json
fi

# On a reinstall, let OpenHD-SysUtils run its first-start tasks again, so it
# applies the camera from the settings above.
sysutils_config=/usr/local/share/OpenHD/SysUtils/config.json
if [[ -f "${sysutils_config}" ]]; then
  sed -i 's/"firstboot": false/"firstboot": true/' "${sysutils_config}"
fi
sync

dpkg_install() {
  echo "Installing ${1##*/}"
  dpkg --force-confdef --force-confold -i "$1"
}
dpkg_install "${openhd_debs[0]}"
if [[ "${role}" == ground && ${#qopenhd_debs[@]} -eq 1 ]]; then
  # QOpenHD 2.6.4 can't read this build's link statistics (RSSI, packet loss)
  # and decodes the video itself. QOpenHD 2.7 matches this build and asks
  # OpenHD-SysUtils for the video decoder.
  dpkg_install "${qopenhd_debs[0]}"
fi
# The upgrade from OpenHD-SysUtils 0.4 removes its video decode scripts, which
# QOpenHD 2.6.4 uses. Keep them, in case QOpenHD 2.6.4 stays or comes back.
keep="$(mktemp -d)"
for script in /usr/local/bin/{h264,h265,mjpeg}_decode.sh; do
  if [[ -f "${script}" ]]; then
    cp -p "${script}" "${keep}/"
  fi
done
# OpenHD-SysUtils last: its postinst starts it, and on its first start it
# writes the camera overlay to config.txt and reboots the Pi.
dpkg_install "${sysutils_debs[0]}"
for script in "${keep}"/*; do
  if [[ ! -e "/usr/local/bin/${script##*/}" ]]; then
    cp -p "${script}" /usr/local/bin/
  fi
done
rm -rf "${keep}"

echo "Waiting for OpenHD-SysUtils to finish its first start, then the Pi reboots"
for _ in $(seq 60); do
  if grep -qs '"firstboot": false' "${sysutils_config}"; then
    break
  fi
  sleep 1
done
sync
systemctl reboot
