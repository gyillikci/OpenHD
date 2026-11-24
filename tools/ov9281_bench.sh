#!/bin/bash
# Bench test of the OV9281 build without Wi-Fi cards: the air Pi and the ground
# Pi run OpenHD on Raspberry Pi OS (Bookworm or newer) and talk over an
# Ethernet cable between them (OpenHD's Ethernet link). OpenHD-SysUtils is not
# used, Wi-Fi stays as it is (so Raspberry Pi Connect keeps working).
#
# On each Pi, from a clone of this branch:
#   git clone --recursive -b claude/upbeat-planck-c52i6b https://github.com/gyillikci/OpenHD.git
#   cd OpenHD
#   bash tools/ov9281_bench.sh setup          # packages and build (both Pis)
#   bash tools/ov9281_bench.sh config air     # air Pi, with the OV9281
#   bash tools/ov9281_bench.sh config ground  # ground Pi
#   bash tools/ov9281_bench.sh check          # what to send when asking for help
#   bash tools/ov9281_bench.sh run air        # air Pi, Ctrl+C stops OpenHD
#   bash tools/ov9281_bench.sh run ground     # ground Pi
#   bash tools/ov9281_bench.sh view           # ground Pi, second shell: the video
#   bash tools/ov9281_bench.sh reset          # undo config
set -euo pipefail

AIR_IP=192.168.2.18
GROUND_IP=192.168.2.1
VIDEO_PORT=5910
TELEMETRY_PORT=5920
NM_PROFILE=openhd-bench
ETH_IF="${ETH_IF:-eth0}"

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
build_dir="${repo_dir}/build-bench"
boot_config=/boot/firmware/config.txt
if [[ ! -f "${boot_config}" ]]; then
  boot_config=/boot/config.txt
fi

usage() {
  sed -n '10,17p' "${BASH_SOURCE[0]}" | sed 's/^# *//' >&2
  exit 2
}

die() {
  echo "$*" >&2
  exit 1
}

setup() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${VERSION_CODENAME:-}" in
    bookworm | trixie) ;;
    *) echo "Note: made for Raspberry Pi OS Bookworm or newer, this is ${PRETTY_NAME:-unknown}" >&2 ;;
  esac
  sudo apt-get update
  sudo apt-get install -y --no-install-recommends \
    git cmake g++ make pkg-config libpoco-dev libusb-1.0-0-dev libpcap-dev \
    libsodium-dev libnl-3-dev libnl-genl-3-dev libnl-route-3-dev libsdl2-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libv4l-dev \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav \
    gstreamer1.0-libcamera
  git -C "${repo_dir}" submodule update --init --recursive
  # About 1 GB of RAM per compile job
  local mem_gb jobs
  mem_gb="$(awk '/MemTotal/ {print int($2 / 1000000)}' /proc/meminfo)"
  jobs="$(nproc)"
  if ((mem_gb < jobs)); then jobs="${mem_gb}"; fi
  if ((jobs < 1)); then jobs=1; fi
  cmake -S "${repo_dir}/OpenHD" -B "${build_dir}" -DCMAKE_BUILD_TYPE=Release
  cmake --build "${build_dir}" -j"${jobs}"
  sudo install -m 0755 "${build_dir}/openhd" /usr/local/bin/openhd
  echo "Installed /usr/local/bin/openhd"
}

config() {
  local role="$1" my_ip
  case "${role}" in
    air) my_ip="${AIR_IP}" ;;
    ground) my_ip="${GROUND_IP}" ;;
    *) usage ;;
  esac
  command -v nmcli > /dev/null ||
    die "nmcli (NetworkManager) not found, set ${my_ip}/24 on ${ETH_IF} by hand"
  # The cable to the other Pi replaces whatever network eth0 has now.
  if ip route show default | grep -q " dev ${ETH_IF} "; then
    die "${ETH_IF} carries this Pi's internet connection now. Connect the Pi to Wi-Fi first (Raspberry Pi Connect keeps working over Wi-Fi), then run this again."
  fi
  if nmcli -t -f NAME connection show | grep -qx "${NM_PROFILE}"; then
    sudo nmcli connection modify "${NM_PROFILE}" ipv4.addresses "${my_ip}/24"
  else
    sudo nmcli connection add type ethernet ifname "${ETH_IF}" con-name "${NM_PROFILE}" \
      ipv4.method manual ipv4.addresses "${my_ip}/24" ipv4.never-default yes \
      ipv6.method disabled connection.autoconnect yes \
      connection.autoconnect-priority 100 > /dev/null
  fi
  if ! sudo nmcli connection up "${NM_PROFILE}" > /dev/null 2>&1; then
    echo "${ETH_IF} gets ${my_ip} as soon as the cable to the other Pi is plugged in."
  fi
  sudo mkdir -p /Config
  printf 'GROUND_UNIT_IP=%s\nAIR_UNIT_IP=%s\nVIDEO_PORT=%s\nTELEMETRY_PORT=%s\n' \
    "${GROUND_IP}" "${AIR_IP}" "${VIDEO_PORT}" "${TELEMETRY_PORT}" |
    sudo tee /Config/ethernet.txt > /dev/null
  if [[ "${role}" == air ]]; then
    # Without OpenHD-SysUtils, OpenHD takes the camera from its own settings.
    # enable_audio 1 means off (OPENHD_AUDIO_DISABLE), there is no microphone.
    sudo mkdir -p /usr/local/share/openhd/video
    printf '{\n    "dualcam_primary_video_allocated_bandwidth_perc": 60,\n    "enable_audio": 1,\n    "primary_camera_type": 49,\n    "secondary_camera_type": 255,\n    "switch_primary_and_secondary": false\n}\n' |
      sudo tee /usr/local/share/openhd/video/air_camera_generic.json > /dev/null
    if ! grep -q '^dtoverlay=ov9281' "${boot_config}"; then
      echo "Note: ${boot_config} has no dtoverlay=ov9281 line yet. Add camera_auto_detect=0 and dtoverlay=ov9281 (,cam0 for CAM0 on a Pi 5) and reboot." >&2
    fi
  fi
  echo "Configured as ${role}: ${ETH_IF} ${my_ip}/24, /Config/ethernet.txt"
}

check() {
  tr -d '\0' < /proc/device-tree/model
  echo
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "${PRETTY_NAME:-?}, $(uname -m), kernel $(uname -r)"
  ip -br addr show "${ETH_IF}" || true
  grep -nE '^camera_auto_detect|^dtoverlay=ov9281' "${boot_config}" || echo "no ov9281 overlay in ${boot_config}"
  if [[ -f /Config/ethernet.txt ]]; then
    cat /Config/ethernet.txt
  fi
  if pgrep -x openhd > /dev/null; then
    echo "openhd is running, the camera list below may be empty because of that"
  fi
  (rpicam-hello --list-cameras 2>&1 || libcamera-hello --list-cameras 2>&1) | head -12 || true
  local other="${GROUND_IP}"
  if ip -br addr show "${ETH_IF}" | grep -q "${GROUND_IP}/"; then
    other="${AIR_IP}"
  fi
  ping -c 2 -W 1 "${other}" | tail -2 || echo "${other} does not answer"
  if [[ -x /usr/local/bin/openhd ]]; then
    echo "openhd installed"
  else
    echo "openhd not installed yet (run setup)"
  fi
}

run() {
  local role="$1"
  [[ "${role}" == air || "${role}" == ground ]] || usage
  [[ -x /usr/local/bin/openhd ]] || die "Run setup first"
  [[ -f /Config/ethernet.txt ]] || die "Run config ${role} first"
  echo "Starting OpenHD as ${role}. It first waits 30 s for OpenHD-SysUtils, which isn't used here. Ctrl+C stops it."
  exec sudo /usr/local/bin/openhd --"${role}"
}

view() {
  local caps="application/x-rtp,media=video,clock-rate=90000,encoding-name=H264"
  if [[ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ]]; then
    exec gst-launch-1.0 udpsrc port=5600 caps="${caps}" ! rtph264depay ! h264parse ! \
      avdec_h264 ! videoconvert ! autovideosink sync=false
  fi
  echo "No screen in this shell, showing the frame rate of the video the ground receives (Ctrl+C stops)."
  echo "For the picture, run this in a terminal on the ground Pi's desktop (screen sharing in Raspberry Pi Connect)."
  gst-launch-1.0 -v udpsrc port=5600 caps="${caps}" ! rtph264depay ! h264parse ! avdec_h264 ! \
    fpsdisplaysink video-sink=fakesink text-overlay=false sync=false 2>&1 |
    grep --line-buffered -o 'rendered: [0-9]*, dropped: [0-9]*, current: [0-9.]*'
}

reset() {
  sudo nmcli connection delete "${NM_PROFILE}" > /dev/null 2>&1 || true
  sudo rm -f /Config/ethernet.txt
  echo "Removed the ${NM_PROFILE} network profile and /Config/ethernet.txt"
}

case "${1:-}" in
  setup) setup ;;
  config) config "${2:-}" ;;
  check) check ;;
  run) run "${2:-}" ;;
  view) view ;;
  reset) reset ;;
  *) usage ;;
esac
