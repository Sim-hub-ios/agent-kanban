#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_variant=baseline
task_variant_set=0
task_should_build=1

task_usage() {
  print -u2 'Usage: build-diagnostics-app.sh [baseline|no-selection|eager-stack|no-autoscroll] [--no-build]'
}

for task_argument in "$@"; do
  case "$task_argument" in
    baseline|no-selection|eager-stack|no-autoscroll)
      if (( task_variant_set )); then
        task_usage
        exit 2
      fi
      task_variant="$task_argument"
      task_variant_set=1
      ;;
    --no-build) task_should_build=0 ;;
    -h|--help) task_usage; exit 0 ;;
    *) task_usage; exit 2 ;;
  esac
done

if (( task_should_build )); then
  swift build --package-path "$task_root" -c debug
  task_binary_dir="$(swift build --package-path "$task_root" -c debug --show-bin-path)"
else
  # SwiftPM maintains this symlink. Do not invoke SwiftPM again while another build owns its lock.
  task_binary_dir="$task_root/.build/debug"
fi

if [[ ! -x "$task_binary_dir/AgentKanban" ]]; then
  print -u2 "Missing debug executable: $task_binary_dir/AgentKanban"
  print -u2 'Build once without --no-build before packaging another variant.'
  exit 1
fi

task_variant_root="$task_root/build/diagnostics/$task_variant"
task_app="$task_variant_root/Agent Kanban Debug.app"
task_data="$task_variant_root/data"
task_database="$task_data/workspace.sqlite"
task_source_directory="${AGENT_KANBAN_SOURCE_DATA_DIR:-$HOME/Library/Application Support/AgentKanban}"
task_source_directory="${task_source_directory:A}"
task_source_database="$task_source_directory/workspace.sqlite"

if [[ "${task_database:A}" == "${task_source_database:A}" ]]; then
  print -u2 'The diagnostics data directory must differ from the source workspace directory.'
  exit 1
fi
if [[ -f "$task_app/Contents/MacOS/AgentKanban" ]] && \
   [[ -n "$(/usr/sbin/lsof -t "$task_app/Contents/MacOS/AgentKanban" 2>/dev/null || true)" ]]; then
  print -u2 "Quit this diagnostic variant before rebuilding it: $task_app"
  exit 1
fi

mkdir -p "$task_data/Diagnostics"
chmod 700 "$task_data" "$task_data/Diagnostics"
if [[ ! -f "$task_database" ]]; then
  if [[ ! -f "$task_source_database" ]]; then
    print -u2 "No source workspace database: $task_source_database"
    print -u2 'AGENT_KANBAN_SOURCE_DATA_DIR can point to another existing workspace directory.'
    exit 1
  fi
  # A per-variant lock prevents two first-time packagers from replacing each other's snapshot.
  task_initialization_lock="$task_data/.initializing"
  if ! mkdir "$task_initialization_lock" 2>/dev/null; then
    print -u2 "A workspace snapshot is already initializing: $task_data"
    exit 1
  fi
  task_temporary_database="$task_initialization_lock/workspace.sqlite"
  trap 'rm -f "$task_temporary_database"; rmdir "$task_initialization_lock" 2>/dev/null || true' EXIT
  # Changing directory keeps the dot-command filename literal; source paths remain shell-quoted.
  # .backup reads a consistent SQLite snapshot, including the live WAL, via a read-only connection.
  (
    cd "$task_initialization_lock"
    /usr/bin/sqlite3 -readonly "$task_source_database" '.timeout 5000' '.backup workspace.sqlite'
  )
  if [[ ! -f "$task_database" ]]; then
    mv "$task_temporary_database" "$task_database"
  fi
  rm -f "$task_temporary_database"
  rmdir "$task_initialization_lock"
  trap - EXIT
  print "Initialized independent workspace snapshot: $task_database"
else
  print "Preserving existing diagnostic workspace: $task_database"
fi
chmod 600 "$task_database"

mkdir -p "$task_app/Contents/MacOS" "$task_app/Contents/Resources"
cp "$task_binary_dir/AgentKanban" "$task_app/Contents/MacOS/AgentKanban"
for task_bundle in "$task_binary_dir"/*.bundle(N); do
  ditto "$task_bundle" "$task_app/Contents/Resources/${task_bundle:t}"
done

task_plist="$task_app/Contents/Info.plist"
cat > "$task_plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentKanban</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>LSEnvironment</key><dict/></dict></plist>
PLIST
task_bundle_variant="${task_variant//-/}"
/usr/bin/plutil -insert CFBundleIdentifier -string "com.agentkanban.diagnostics.$task_bundle_variant" "$task_plist"
/usr/bin/plutil -insert CFBundleName -string 'Agent Kanban Debug' "$task_plist"
/usr/bin/plutil -insert CFBundleDisplayName -string "Agent Kanban Debug · $task_variant" "$task_plist"
/usr/bin/plutil -insert LSEnvironment.AGENT_KANBAN_DIAGNOSTICS -string '1' "$task_plist"
/usr/bin/plutil -insert LSEnvironment.AGENT_KANBAN_SCROLL_VARIANT -string "$task_variant" "$task_plist"
/usr/bin/plutil -insert LSEnvironment.AGENT_KANBAN_DATA_DIR -string "$task_data" "$task_plist"
/usr/bin/plutil -lint "$task_plist"
codesign --force --deep --sign - "$task_app"
codesign --verify --deep --strict "$task_app"

print "Diagnostic app: $task_app"
print "Diagnostics folder: $task_data/Diagnostics"
print "Variant: $task_variant"
print 'Use this app only to reproduce message scrolling; do not execute real project tasks.'
print 'The production app has not been replaced or opened.'
