#!/bin/sh

# Build a distributable drag-to-Applications DMG.
#
# Usage:
#   ./scripts/build-dmg.sh [path/to/toolbox desktop.app] [output.dmg]
#
# With no arguments, this first builds dist/toolbox desktop.app and writes a versioned
# DMG beside it. Packaging is delegated to the create-dmg utility. This script
# intentionally performs no Developer ID signing or notarization.
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_was_provided=false
if [ "$#" -ge 1 ]; then app_was_provided=true; fi
app_path=${1:-"$project_dir/dist/toolbox desktop.app"}
config_file="$project_dir/Sources/toolboxDesktop/ToolboxConfig.swift"

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'error: %s is required (%s)\n' "$1" "$2" >&2
        exit 1
    fi
}

require_tool create-dmg "brew install create-dmg"
require_tool plutil "included with macOS"
require_tool ditto "included with macOS"
require_tool textutil "included with macOS"
require_tool awk "included with macOS"
require_tool sed "included with macOS"
require_tool uname "included with macOS"
require_tool mktemp "included with macOS"
require_tool mkdir "included with macOS"
require_tool rm "included with macOS"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: DMG packaging is only supported on macOS" >&2
    exit 1
fi

# With no custom app path, rebuild even when dist already contains an app. This
# prevents an old bundle version from silently determining a new DMG filename.
# build-app also refreshes both app and DMG icons, so do not repeat that work.
if [ "$app_was_provided" = false ]; then
    if ! "$project_dir/scripts/build-app.sh"; then
        echo "error: application build failed" >&2
        exit 1
    fi
else
    # A caller supplying a prebuilt app bypasses build-app, but the separate
    # DMG volume icon may still have changed since the previous package.
    if ! "$project_dir/tools/build-icons.sh"; then
        echo "error: icon generation failed" >&2
        exit 1
    fi
fi

if [ ! -d "$app_path" ]; then
    echo "toolbox desktop.app was not found at: $app_path" >&2
    exit 1
fi

version=$(sed -n 's/^[[:space:]]*static let version = "\([^"]*\)"[[:space:]]*$/\1/p' "$config_file")
if [ -z "$version" ]; then
    echo "error: ToolboxConfig.version is missing or invalid" >&2
    exit 1
fi
bundle_version=$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist" 2>/dev/null)
if [ "$bundle_version" != "$version" ]; then
    printf 'error: app version %s does not match ToolboxConfig.version %s\n' \
        "${bundle_version:-unknown}" "$version" >&2
    printf 'error: rebuild the app before packaging it\n' >&2
    exit 1
fi
output_path=${2:-"$project_dir/dist/toolbox-installer-$version.dmg"}
staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-dmg.XXXXXX")
eula_file=$(mktemp "${TMPDIR:-/tmp}/toolbox-license.XXXXXX.rtf")
license_text=$(mktemp "${TMPDIR:-/tmp}/toolbox-license.XXXXXX.txt")

cleanup() {
    rm -rf "$staging_dir"
    rm -f "$eula_file"
    rm -f "$license_text"
}
trap cleanup EXIT HUP INT TERM

# `ditto` preserves the application bundle's resource forks, permissions, and
# signatures. create-dmg adds the Applications link and Finder presentation.
if ! ditto "$app_path" "$staging_dir/toolbox desktop.app"; then
    echo "error: failed to stage toolbox desktop.app" >&2
    exit 1
fi

# Join hard-wrapped source lines within each paragraph before conversion so
# DiskImageMounter controls wrapping for the actual license-window width.
if ! awk 'BEGIN { RS=""; ORS="\n\n" } { gsub(/[[:space:]]+/, " "); print }' \
    "$project_dir/../LICENSE" > "$license_text"; then
    echo "error: failed to reflow the license text" >&2
    exit 1
fi

if ! textutil -convert rtf -font "Menlo" -fontsize 11 \
    -output "$eula_file" "$license_text"; then
    echo "error: failed to format the license EULA" >&2
    exit 1
fi

mkdir -p "$(dirname "$output_path")"

# Build one argument list so the optional background can be appended without
# duplicating the create-dmg command or losing paths that contain spaces.
set -- \
    --volname "toolbox installer" \
    --volicon "$project_dir/Assets/DMGVolumeIcon.icns" \
    --window-pos 100 100 \
    --window-size 720 460 \
    --text-size 13 \
    --icon-size 104 \
    --icon "toolbox desktop.app" 120 236 \
    --hide-extension "toolbox desktop.app" \
    --app-drop-link 595 236 \
    --add-file "License.txt" "$project_dir/../LICENSE" 360 300 \
    --hide-extension "License.txt" \
    --eula "$eula_file" \
    --filesystem HFS+ \
    --format UDZO \
    --no-internet-enable \
    --overwrite

# A custom background is optional; create-dmg otherwise uses Finder's native
# background while retaining the same icon layout.
if [ -f "$project_dir/Assets/DMGBackground.png" ]; then
    # Positional parameters preserve every argument boundary as the optional
    # Finder background is added to the list assembled above.
    set -- "$@" --background "$project_dir/Assets/DMGBackground.png"
fi

if ! create-dmg "$@" "$output_path" "$staging_dir"; then
    echo "error: create-dmg failed" >&2
    exit 1
fi

echo "Created $output_path"
