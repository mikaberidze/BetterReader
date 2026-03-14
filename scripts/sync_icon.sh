#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_icon="${repo_root}/icon.png"
appicon_dir="${repo_root}/src/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "${source_icon}" ]]; then
  echo "Missing source icon: ${source_icon}" >&2
  echo "Put a square 1024x1024 PNG there, then run scripts/sync_icon.sh." >&2
  exit 1
fi

declare -a outputs=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

for spec in "${outputs[@]}"; do
  size="${spec%%:*}"
  filename="${spec#*:}"
  sips -s format png -z "${size}" "${size}" "${source_icon}" \
    --out "${appicon_dir}/${filename}" >/dev/null
done

echo "Updated app icon assets from ${source_icon}."
