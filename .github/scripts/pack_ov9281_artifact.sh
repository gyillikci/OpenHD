#!/usr/bin/env bash
# Packs the build output in <out_dir> for <rpi4|rpi5> into <dist_dir>, with a
# README.txt. For the rpi4, the .deb files in the optional <extra_dir> (the
# QOpenHD package for the ground station) go along.
# Usage: pack_ov9281_artifact.sh <rpi4|rpi5> <out_dir> <dist_dir> [<extra_dir>]
set -euo pipefail

board="$1"
out_dir="$(realpath "$2")"
mkdir -p "$3"
dist_dir="$(realpath "$3")"
extra_dir="${4:-}"
scripts_dir="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
sysutils_ref="${SYSUTILS_REF:-unknown}"

case "${board}" in
  rpi4)
    # The OpenHD 2.6.4 image doesn't install update packages by itself (its
    # updater script is never run), the packages are installed with install.sh.
    mkdir -p "${dist_dir}/ov9281"
    cp -v "${out_dir}"/openhd_*_armhf.deb "${out_dir}"/openhd-sys-utils_*_armhf.deb "${dist_dir}/ov9281/"
    if [[ -n "${extra_dir}" ]]; then
      cp -v "${extra_dir}"/*.deb "${dist_dir}/ov9281/"
    fi
    cp -v "${scripts_dir}/install_ov9281_rpi4.sh" "${dist_dir}/ov9281/install.sh"
    ;;
  rpi5)
    cp -v "${out_dir}/binaries/openhd" "${out_dir}"/openhd-sys-utils_*_arm64.deb "${dist_dir}/"
    ;;
  *)
    echo "Unknown board ${board}" >&2
    exit 1
    ;;
esac

{
  echo "OpenHD with OV9281 support (camera type 49), built from"
  echo "${GITHUB_REF_NAME:-?} ${GITHUB_SHA:-?}"
  echo
  (cd "${dist_dir}" && find . -type f ! -name README.txt | sed 's|^\./|  |' | sort)
  echo
  echo "openhd-sys-utils is OpenHD-SysUtils main ${sysutils_ref:0:8} with a profile for"
  echo "camera type 49 (dtoverlay=ov9281,arducam) and a postinst that enables its"
  echo "service."
  echo
  if [[ "${board}" == "rpi4" ]]; then
    cat <<'EOF'
Raspberry Pi 4 / CM4, OpenHD 2.6.4 image. The image doesn't install update
packages by itself, so they are installed once with install.sh, on the air
unit and on the ground station: the link of this build doesn't work with
OpenHD 2.6.4.

1. Write "OpenHD-2.6.4-evo Raspberry" with the OpenHD ImageWriter (Air for the
   air unit, Ground for the ground station).
2. Re-insert the SD card and open the drive named OPENHD. Cancel any offer to
   format or initialize another drive of the card. Copy the ov9281 folder
   into the openhd folder of the OPENHD drive.
3. Boot the Pi and wait a few minutes: on its first start the image reboots
   by itself.
4. Open a shell on the Pi:
   - SSH: ssh openhd@openhd.local (or the IP address your router shows),
     password openhd. Both Pis are called openhd, connect one at a time.
   - Screen and keyboard: Ctrl+Alt+F2 opens a root shell. If QOpenHD is on
     the screen, press Ctrl+F12 first to close it.
5. Run
     sudo bash /boot/openhd/ov9281/install.sh air      (air unit, OV9281)
     sudo bash /boot/openhd/ov9281/install.sh ground   (ground station)
   It writes the role (and camera 49) to openhd/settings.json, installs the
   packages and reboots the Pi. On the air unit, OpenHD-SysUtils first writes
   camera_auto_detect=0 and dtoverlay=ov9281,arducam to config.txt.
   If the Pi reboots before "Waiting for OpenHD-SysUtils" is printed, run it
   again.

On the ground station, install.sh also installs QOpenHD 2.7.1 (an official
OpenHD build), which reads this build's link statistics; QOpenHD 2.6.4 would
show no RSSI or packet loss. The video decoder then runs in OpenHD-SysUtils.
QOpenHD doesn't list camera type 49, the camera is set by install.sh; running
install.sh air again resets the camera settings.
CM4 with the camera on CAM0: after the install, change the last line of
config.txt to dtoverlay=ov9281,arducam,cam0.
EOF
  else
    cat <<'EOF'
Raspberry Pi 5, for development only:
- There is no public OpenHD image for the RPi 5.
- This OpenHD version only drives Wi-Fi cards with OpenHD's own Realtek
  kernel drivers (rtl88xxau_ohd, rtl88x2bu_ohd, rtl88x2eu_ohd), which no RPi 5
  kernel has. OpenHD 3.0 uses a user space driver instead, so don't replace
  the openhd of an OpenHD 3.0 image with this one.
- The camera part needs Raspberry Pi OS Bookworm (64 bit) with
  gstreamer1.0-libcamera, gstreamer1.0-plugins-ugly (x264enc) and the
  libraries ldd reports for openhd (Poco from libpoco-dev), and in config.txt:
    camera_auto_detect=0
    dtoverlay=ov9281,arducam      (append ",cam0" for the CAM0 connector)
- openhd goes to /usr/local/bin/openhd (sudo install -m 0755 openhd
  /usr/local/bin/openhd), install openhd-sys-utils with sudo dpkg -i from a
  shell, not through an update.zip.
EOF
  fi
  echo
  echo "Not tested on hardware."
} > "${dist_dir}/README.txt"
cat "${dist_dir}/README.txt"
