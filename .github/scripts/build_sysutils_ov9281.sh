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
# The "arducam" overlay parameter only adds a short regulator start-up delay,
# which slow Arducam modules need.
sed -i 's|^\( *\){47, "kms", "imx662", true, nullptr},$|&\n\1{49, "kms", "ov9281,arducam", false, nullptr},|' "${profiles}"
if ! grep -q '{49, "kms", "ov9281,arducam", false, nullptr},' "${profiles}"; then
  echo "Could not add the OV9281 profile to ${profiles}" >&2
  exit 1
fi

cmake -S "${src}" -B "${src}/build" -DCMAKE_BUILD_TYPE=Release
cmake --build "${src}/build" -j"$(nproc)"
(cd "${src}/build" && cpack -G DEB)

mkdir -p "${out_dir}"
cp -v "${src}"/build/openhd-sys-utils_*.deb "${out_dir}/"
