#!/bin/zsh
set -euo pipefail
task_root="${0:A:h:h}"
task_configuration="${1:-debug}"
if [[ "$task_configuration" != debug && "$task_configuration" != release ]]; then
  print -u2 'Usage: build-app.sh [debug|release]'
  exit 2
fi
"$task_root/scripts/build-icon.sh"
task_icon_assets="$task_root/build/icon-assets"
swift build --package-path "$task_root" -c "$task_configuration"
task_binary_dir="$(swift build --package-path "$task_root" -c "$task_configuration" --show-bin-path)"
task_app="$task_root/build/Agent Kanban.app"
mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_binary_dir/AgentKanban" "$task_app/Contents/MacOS/AgentKanban"
cp "$task_icon_assets/AppIcon.icns" "$task_app/Contents/Resources/AppIcon.icns"
cp "$task_icon_assets/Assets.car" "$task_app/Contents/Resources/Assets.car"
for task_bundle in "$task_binary_dir"/*.bundle(N); do
  ditto "$task_bundle" "$task_app/Contents/Resources/${task_bundle:t}"
done
cat > "$task_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.agentkanban.desktop</string>
<key>CFBundleName</key><string>Agent Kanban</string>
<key>CFBundleDisplayName</key><string>Agent Kanban</string>
<key>CFBundleExecutable</key><string>AgentKanban</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge \"$task_icon_assets/icon.plist\"" "$task_app/Contents/Info.plist"
plutil -lint "$task_app/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$task_app"
print "$task_app"
