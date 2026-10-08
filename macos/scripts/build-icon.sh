#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_assets="$task_root/Assets"
task_source="$task_assets/AppIcon-source.png"
task_document="$task_assets/AppIcon.icon"
task_output="$task_root/build/icon-assets"
if [[ ! -f "$task_source" || ! -f "$task_document/icon.json" ]]; then
  print -u2 'Missing AppIcon-source.png or AppIcon.icon/icon.json.'
  exit 1
fi
task_actool="$(xcrun --find actool)"
task_developer="$(xcode-select -p)"
task_ictool="${task_developer:h}/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$task_ictool" ]]; then
  print -u2 'Xcode 26 or later with Icon Composer is required to build the macOS app icon.'
  exit 1
fi
mkdir -p "$task_root/build"
task_temporary="$(mktemp -d "$task_root/build/.icon-assets.XXXXXX")"
trap 'rm -rf "$task_temporary"' EXIT
task_iconset="$task_temporary/AppIcon.iconset"
mkdir -p "$task_iconset" "$task_document/Assets" "$task_temporary/compiled"

sips -z 1024 1024 "$task_source" --out "$task_temporary/AppIcon.png" >/dev/null
cp "$task_temporary/AppIcon.png" "$task_document/Assets/Kanban.png"
for task_size in 16 32 128 256 512; do
  sips -z "$task_size" "$task_size" "$task_temporary/AppIcon.png" \
    --out "$task_iconset/icon_${task_size}x${task_size}.png" >/dev/null
  task_retina=$((task_size * 2))
  sips -z "$task_retina" "$task_retina" "$task_temporary/AppIcon.png" \
    --out "$task_iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_iconset" -o "$task_temporary/AppIcon.icns"

# Compile the Icon Composer document. A legacy ICNS alone is inset by macOS 26;
# Assets.car and CFBundleIconName are required for the system-shaped icon.
"$task_actool" "$task_document" \
  --compile "$task_temporary/compiled" \
  --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon \
  --output-partial-info-plist "$task_temporary/compiled/icon.plist" \
  --output-format human-readable-text --errors --warnings --notices
for task_file in Assets.car AppIcon.icns icon.plist; do
  if [[ ! -s "$task_temporary/compiled/$task_file" ]]; then
    print -u2 "Icon compilation did not produce $task_file."
    exit 1
  fi
done
plutil -lint "$task_temporary/compiled/icon.plist" >/dev/null
if [[ "$(plutil -extract CFBundleIconName raw "$task_temporary/compiled/icon.plist")" != AppIcon ]]; then
  print -u2 'Compiled icon metadata is missing CFBundleIconName=AppIcon.'
  exit 1
fi
"$task_ictool" "$task_document" --export-image \
  --output-file "$task_temporary/compiled/preview.png" \
  --platform macOS --rendition Default --width 1024 --height 1024 --scale 1
if [[ ! -s "$task_temporary/compiled/preview.png" ]]; then
  print -u2 'Icon Composer did not produce the macOS preview.'
  exit 1
fi
cp "$task_temporary/AppIcon.png" "$task_assets/AppIcon.png"
cp "$task_temporary/AppIcon.icns" "$task_assets/AppIcon.icns"
rm -rf "$task_output"
mv "$task_temporary/compiled" "$task_output"
print "$task_output"
