#!/usr/bin/env bash
# Prints "OPENHD_BUILD_NUMBER=<n>+ov9281" for $GITHUB_ENV. OpenHD-SysUtils
# uses it as the last part of its package version (1.0.3.<n>+ov9281).
# <n> is the build number of the newest official OpenHD-SysUtils package for
# <distribution> <architecture> (e.g. raspbian/bullseye armhf), so this build
# replaces that package, and the next official build replaces this one again.
set -euo pipefail

distribution="$1"
architecture="$2"

packages="$(curl -fsS --retry 3 --retry-all-errors -G "https://api.cloudsmith.io/v1/packages/openhd/dev-release/" \
  --data-urlencode "query=name:openhd-sys-utils AND distribution:${distribution} AND architecture:${architecture}" \
  --data-urlencode "sort=-version" \
  --data-urlencode "page_size=100")"

number="$(python3 -c 'import json, re, sys
numbers = [int(m.group(1)) for p in json.load(sys.stdin)
           if p.get("name") == "openhd-sys-utils"
           for m in [re.fullmatch(r"1\.0\.3\.(\d+)", p.get("version", ""))] if m]
print(max(numbers) if numbers else "")' <<< "${packages}")"

# No fallback: a made-up number (e.g. a date) would be newer than any official
# package, and no official package would ever replace this build.
if [[ ! "${number}" =~ ^[0-9]+$ ]]; then
  echo "::error::No official OpenHD-SysUtils package found for ${distribution} ${architecture}" >&2
  exit 1
fi
echo "OPENHD_BUILD_NUMBER=${number}+ov9281"
