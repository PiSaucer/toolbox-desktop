#!/bin/sh

# Build, assemble, and ad-hoc sign toolbox desktop.app.
# The script performs a clean SwiftPM build and reports each missing dependency
# explicitly instead of relying on shell-wide automatic-exit flags.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
configuration=${CONFIGURATION:-release}
output_dir="$project_dir/dist"
app_dir="$output_dir/toolbox desktop.app"
config_file="$project_dir/Sources/toolboxDesktop/ToolboxConfig.swift"
build_number=${BUILD_NUMBER:-1}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'error: %s is required (%s)\n' "$1" "$2" >&2
        exit 1
    fi
}

require_tool swift "install Xcode or the Xcode Command Line Tools"
require_tool plutil "included with macOS"
require_tool codesign "install the Xcode Command Line Tools"
require_tool ditto "included with macOS"
require_tool sed "included with macOS"
require_tool uname "included with macOS"
require_tool rm "included with macOS"
require_tool mkdir "included with macOS"
require_tool cp "included with macOS"
require_tool chmod "included with macOS"

# ToolboxConfig.swift is the human-edited version source. Copy it into the
# bundle metadata so Finder, About, DMG names, and releases all report the same
# value without maintaining a second version in Info.plist.
desktop_version=$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)"[[:space:]]*$/\1/p' "$config_file")
if [ -z "$desktop_version" ]; then
    printf 'error: ToolboxConfig.version is missing or invalid\n' >&2
    exit 1
fi
case "$build_number" in
    ''|*[!0-9]*)
        printf 'error: BUILD_NUMBER must contain only digits\n' >&2
        exit 1
        ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    printf 'error: toolbox desktop.app can only be built on macOS\n' >&2
    exit 1
fi

# Keep all generated icon catalogs and ICNS files synchronized before Swift or
# bundle assembly begins. The helper skips unchanged pipelines by timestamp.
if ! "$project_dir/tools/build-icons.sh"; then
    printf 'error: icon generation failed\n' >&2
    exit 1
fi

cd "$project_dir" || exit 1

# A clean build prevents stale Swift objects from masking package/source edits.
if ! swift package clean; then
    printf 'error: swift package clean failed\n' >&2
    exit 1
fi
if ! "$project_dir/tools/setup-toolbox.sh"; then
    printf 'error: toolbox.py staging failed\n' >&2
    exit 1
fi
if ! swift build -c "$configuration"; then
    printf 'error: Swift %s build failed\n' "$configuration" >&2
    exit 1
fi
binary_dir=$(swift build -c "$configuration" --show-bin-path)
if [ ! -x "$binary_dir/toolboxDesktop" ]; then
    printf 'error: Swift build produced no toolboxDesktop executable\n' >&2
    exit 1
fi

# Recreate the bundle only after a successful compile. All copy operations are
# checked so the script never prints a false-success message for a partial app.
rm -rf "$app_dir"
if ! mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"; then exit 1; fi
if ! cp "$project_dir/Info.plist" "$app_dir/Contents/Info.plist"; then exit 1; fi
if ! plutil -replace CFBundleShortVersionString -string "$desktop_version" "$app_dir/Contents/Info.plist"; then exit 1; fi
if ! plutil -replace CFBundleVersion -string "$build_number" "$app_dir/Contents/Info.plist"; then exit 1; fi
plutil -remove CFBundleIconName "$app_dir/Contents/Info.plist" 2>/dev/null || true
if ! plutil -replace CFBundleIconFile -string toolbox.icns "$app_dir/Contents/Info.plist"; then exit 1; fi
if ! cp "$binary_dir/toolboxDesktop" "$app_dir/Contents/MacOS/toolboxDesktop"; then exit 1; fi
if ! cp "$project_dir/tools/toolbox-cli" "$app_dir/Contents/MacOS/toolbox"; then exit 1; fi
if ! cp "$project_dir/tools/toolbox.py" "$app_dir/Contents/Resources/toolbox.py"; then exit 1; fi
if ! cp "$project_dir/../LICENSE" "$app_dir/Contents/Resources/LICENSE"; then exit 1; fi
if ! cp "$project_dir/Sources/toolboxDesktop/toolbox.icns" "$app_dir/Contents/Resources/toolbox.icns"; then exit 1; fi
if ! "$project_dir/tools/setup-python-runtime.sh" "$app_dir/Contents/Resources/python"; then exit 1; fi

if ! chmod 755 "$app_dir/Contents/MacOS/toolboxDesktop" "$app_dir/Contents/MacOS/toolbox"; then exit 1; fi
if ! codesign --force --deep --sign - "$app_dir"; then
    printf 'error: ad-hoc code signing failed\n' >&2
    exit 1
fi

printf 'Built %s\n' "$app_dir"
