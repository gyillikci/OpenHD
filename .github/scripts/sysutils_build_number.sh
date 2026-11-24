#!/usr/bin/env bash
# Prints "OPENHD_BUILD_NUMBER=<n>+ov9281" for $GITHUB_ENV. OpenHD-SysUtils
# uses it as the last part of its package version (1.0.3.<n>+ov9281).
# <n> is the build number of the newest official OpenHD-SysUtils package for
# <distribution> <architecture> (e.g. raspbian/bullseye armhf), so this build
# replaces that package, and the next official build replaces this one again.
set -euo pipefail

distribution="$1"
architecture="$2"

number="$(curl -fsS -G "https://api.cloudsmith.io/v1/packages/openhd/dev-release/" \
    --data-urlencode "query=name:openhd-sys-utils AND distribution:${distribution} AND architecture:${architecture}" \
    --data-urlencode "sort=-version" \
    --data-urlencode "page_size=1" |
  python3 -c 'import json, sys
packages = json.load(sys.stdin)
print(packages[0]["version"].split(".")[3] if packages else "")' || true)"

if [[ ! "${number}" =~ ^[0-9]+$ ]]; then
  echo "::warning::No official OpenHD-SysUtils package found for ${distribution} ${architecture}, using a timestamp" >&2
  number="$(date -u +%Y%m%d%H%M%S)"
fi
echo "OPENHD_BUILD_NUMBER=${number}+ov9281"
