#!/usr/bin/env bash
# Packs the OpenHD update.zip for <rpi4|rpi5> from the build output in
# <out_dir> into <dist_dir>, next to the single packages and a README.
# On the SD card it goes to openhd/update/update.zip, the OpenHD updater
# installs it on the next boot.
set -euo pipefail

board="$1"
out_dir="$2"
mkdir -p "$3"
dist_dir="$(realpath "$3")"

cd "${out_dir}"
case "${board}" in
  rpi4)
    # The updaters of all OpenHD releases install the .deb files of the zip.
    zip -j "${dist_dir}/update.zip" openhd_*_armhf.deb openhd-sys-utils_*_armhf.deb
    ;;
  rpi5)
    # binaries/openhd replaces /usr/local/bin/openhd, whatever version the
    # installed openhd package has. OpenHD-SysUtils stays a .deb, it cannot
    # overwrite its own running binary.
    zip "${dist_dir}/update.zip" binaries/openhd openhd-sys-utils_*_arm64.deb
    ;;
  *)
    echo "Unknown board ${board}" >&2
    exit 1
    ;;
esac
cp -v ./*.deb "${dist_dir}/"

{
  echo "OpenHD with OV9281 support (camera type 49) for the ${board}"
  echo "Built from ${GITHUB_REF_NAME:-?} ${GITHUB_SHA:-?}"
  echo
  echo "update.zip:"
  unzip -Z1 "${dist_dir}/update.zip" | sed 's/^/  /'
  echo
  if [[ "${board}" == "rpi4" ]]; then
    cat <<'EOF'
1. Write the "OpenHD-2.6.4-evo Raspberry" image (Air) with the OpenHD
   ImageWriter.
2. On the OPENHD (FAT) partition of the SD card:
   - copy update.zip to openhd/update/update.zip
   - set "camera": "49" in openhd/settings.json
3. Boot the Pi. It installs the update and reboots. OpenHD-SysUtils then adds
   dtoverlay=ov9281,arducam to config.txt and reboots once more.
EOF
  else
    cat <<'EOF'
There is no public OpenHD image for the RPi 5 yet. On an OpenHD RPi 5 image
(OpenHD-ImageBuilder target pi5-bookworm):
1. On the FAT partition of the SD card:
   - copy update.zip to openhd/update/update.zip
   - set "camera": "49" in openhd/settings.json
   - add these lines at the end of config.txt, after
     #OPENHD_DYNAMIC_CONTENT_BEGIN# (append ",cam0" to the dtoverlay line if
     the camera is on CAM0):
       camera_auto_detect=0
       dtoverlay=ov9281,arducam
2. Boot the Pi. It installs the update and reboots.
EOF
  fi
  echo
  echo "The ground station has to run the same OpenHD build."
} > "${dist_dir}/README.txt"
cat "${dist_dir}/README.txt"
