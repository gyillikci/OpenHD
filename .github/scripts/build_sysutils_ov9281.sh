#!/usr/bin/env bash
# Builds the OpenHD-SysUtils .deb with a profile for camera type 49 (OV9281),
# so that selecting the OV9281 writes dtoverlay=ov9281,arducam to config.txt.
# Usage: build_sysutils_ov9281.sh <out_dir>
# SYSUTILS_REF selects the OpenHD-SysUtils commit, OPENHD_BUILD_NUMBER the
# last part of the package version.
set -euo pipefail

out_dir="$1"
ref="${SYSUTILS_REF:?SYSUTILS_REF is not set}"

src="$(mktemp -d)"
git init -q "${src}"
git -C "${src}" fetch -q --depth 1 https://github.com/OpenHD/OpenHD-SysUtils "${ref}"
git -C "${src}" checkout -q FETCH_HEAD

profiles="${src}/src/sysutil_camera.cpp"
if grep -q '{49,' "${profiles}"; then
  echo "OpenHD-SysUtils already has a profile for camera type 49" >&2
  exit 1
fi
# The "arducam" overlay parameter adds a short regulator start-up delay, which
# slow Arducam modules need. Kernels before 6.6 (OpenHD 2.6.4) don't have it,
# the firmware then ignores it and loads the overlay without it.
sed -i 's|^\( *\){47, "kms", "imx662", true, nullptr},$|&\n\1{49, "kms", "ov9281,arducam", false, nullptr},|' "${profiles}"
if ! grep -q '{49, "kms", "ov9281,arducam", false, nullptr},' "${profiles}"; then
  echo "Could not add the OV9281 profile to ${profiles}" >&2
  exit 1
fi

# The postinst of this SysUtils version starts the daemon, but doesn't enable
# its unit, which only OpenHD-ImageBuilder images do. On other images (e.g.
# OpenHD 2.6.4) SysUtils would not start after a reboot, and OpenHD would run
# as ground without a camera. Enable it and retire the pre-C++ launcher of
# SysUtils 0.4, like the dev-release branch of OpenHD-SysUtils does, before
# the daemon is started.
postinst="${src}/packaging/postinst"
export ANCHOR='        # X20 images use SysV init. Registering the script also works safely on'
export BLOCK='        # Added by the OpenHD OV9281 build: enable the native unit and retire
        # the SysUtils 0.4 launcher, as OpenHD-SysUtils dev-release does.
        if command -v systemctl >/dev/null 2>&1; then
            systemctl disable openhd_sys_utils.service >/dev/null 2>&1 || true
            systemctl enable openhd-sys-utils.service >/dev/null 2>&1 || true
        fi
        rm -f /etc/systemd/system/openhd_sys_utils.service
'
if [[ "$(grep -cxF "${ANCHOR}" "${postinst}")" != 1 ]] || grep -q 'systemctl' "${postinst}"; then
  echo "Unexpected ${postinst}, check the enable patch" >&2
  exit 1
fi
patched="$(awk '$0 == ENVIRON["ANCHOR"] { printf "%s\n", ENVIRON["BLOCK"] } { print }' "${postinst}")"
printf '%s\n' "${patched}" > "${postinst}"
sh -n "${postinst}"

cmake -S "${src}" -B "${src}/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "${src}/build" -j"$(nproc)"
(cd "${src}/build" && cpack -G DEB)

deb=("${src}"/build/openhd-sys-utils_*.deb)
if ! dpkg-deb -I "${deb[0]}" postinst | grep -q 'systemctl enable openhd-sys-utils.service'; then
  echo "The OpenHD-SysUtils package has no enable in its postinst" >&2
  exit 1
fi
mkdir -p "${out_dir}"
cp -v "${deb[@]}" "${out_dir}/"
