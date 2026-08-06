#!/bin/sh

# Refresh every generated macOS icon artifact from its canonical source.
#
# Pipelines:
#   Assets/AppIcon.png
#     -> Assets/AppIconPadded.png (824px artwork on a 1024px canvas)
#     -> Assets.xcassets/AppIcon.appiconset/*.png
#     -> Sources/toolboxDesktop/toolbox.icns
#
#   Assets/DMGVolumeIcon.svg
#     -> Assets/DMGVolumeIcon.png
#     -> Assets.xcassets/DMGVolumeIcon.appiconset/*.png
#     -> Assets/DMGVolumeIcon.icns
#
# Outputs are rebuilt only when missing or older than their source. This keeps
# ordinary app builds quick while ensuring an edited SVG or PNG is never stale.

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

require_tool() {
    tool_name=$1
    install_hint=$2
    if ! command -v "$tool_name" >/dev/null 2>&1; then
        printf 'error: %s is required (%s)\n' "$tool_name" "$install_hint" >&2
        exit 1
    fi
}

require_tool sips "install the Xcode Command Line Tools"
require_tool iconutil "install the Xcode Command Line Tools"
require_tool rsvg-convert "brew install librsvg"
require_tool base64 "included with macOS"
require_tool tr "included with macOS"
require_tool mktemp "included with macOS"
require_tool mkdir "included with macOS"
require_tool cp "included with macOS"
require_tool rm "included with macOS"

needs_refresh() {
    target=$1
    shift
    if [ ! -f "$target" ]; then
        return 0
    fi
    for source in "$@"; do
        if [ "$source" -nt "$target" ]; then
            return 0
        fi
    done
    return 1
}

generate_macos_app_source() {
    artwork=$1
    destination=$2
    temporary_svg=$(mktemp "${TMPDIR:-/tmp}/toolbox-app-icon.XXXXXX.svg")
    if [ ! -f "$temporary_svg" ]; then
        printf 'error: could not create temporary app icon SVG\n' >&2
        return 1
    fi

    # The 824-point safe area matches Apple's macOS icon template. It keeps the
    # artwork from looking oversized in legacy Docks without returning to the
    # much smaller 660-point padding used by the first desktop build.
    encoded_artwork=$(base64 < "$artwork" | tr -d '\n')
    if [ -z "$encoded_artwork" ]; then
        rm -f "$temporary_svg"
        printf 'error: failed to encode the canonical app icon\n' >&2
        return 1
    fi
    if ! printf '%s\n' \
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024">' \
        "  <image href=\"data:image/png;base64,$encoded_artwork\" x=\"100\" y=\"100\" width=\"824\" height=\"824\"/>" \
        '</svg>' > "$temporary_svg"; then
        rm -f "$temporary_svg"
        return 1
    fi
    if ! rsvg-convert --width 1024 --height 1024 --output "$destination" "$temporary_svg"; then
        rm -f "$temporary_svg"
        printf 'error: failed to create the macOS-safe app icon source\n' >&2
        return 1
    fi
    rm -f "$temporary_svg"
    printf 'Refreshed %s with the macOS safe area.\n' "$destination"
}

generate_appiconset() {
    source_png=$1
    destination=$2
    label=$3

    if ! mkdir -p "$destination"; then
        printf 'error: could not create %s\n' "$destination" >&2
        return 1
    fi

    for specification in \
        '16 icon_16.png' \
        '32 icon_16@2x.png' \
        '32 icon_32.png' \
        '64 icon_32@2x.png' \
        '128 icon_128.png' \
        '256 icon_128@2x.png' \
        '256 icon_256.png' \
        '512 icon_256@2x.png' \
        '512 icon_512.png' \
        '1024 icon_512@2x.png'
    do
        # Each compact entry is "pixel-size filename". Splitting it here keeps
        # the complete macOS icon matrix readable at a glance above.
        set -- $specification
        if ! sips -z "$1" "$1" "$source_png" --out "$destination/$2" >/dev/null; then
            printf 'error: failed to render %s at %sx%s\n' "$label" "$1" "$1" >&2
            return 1
        fi
    done
    printf 'Refreshed %s asset catalog.\n' "$label"
}

compile_icns() {
    appiconset=$1
    destination=$2
    label=$3
    work_root=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-icon.XXXXXX")
    if [ ! -d "$work_root" ]; then
        printf 'error: could not create temporary icon directory\n' >&2
        return 1
    fi
    iconset="$work_root/$label.iconset"
    if ! mkdir -p "$iconset"; then
        rm -rf "$work_root"
        return 1
    fi

    for mapping in \
        'icon_16.png icon_16x16.png' \
        'icon_16@2x.png icon_16x16@2x.png' \
        'icon_32.png icon_32x32.png' \
        'icon_32@2x.png icon_32x32@2x.png' \
        'icon_128.png icon_128x128.png' \
        'icon_128@2x.png icon_128x128@2x.png' \
        'icon_256.png icon_256x256.png' \
        'icon_256@2x.png icon_256x256@2x.png' \
        'icon_512.png icon_512x512.png' \
        'icon_512@2x.png icon_512x512@2x.png'
    do
        # Turn the catalog filename pair into source and iconutil destination.
        # These strings are fixed in this script, so ordinary field splitting
        # is intentional and cannot consume user-provided shell input.
        set -- $mapping
        if ! cp "$appiconset/$1" "$iconset/$2"; then
            rm -rf "$work_root"
            printf 'error: failed to stage %s for ICNS compilation\n' "$1" >&2
            return 1
        fi
    done

    if ! iconutil -c icns "$iconset" -o "$destination"; then
        rm -rf "$work_root"
        printf 'error: iconutil failed to compile %s\n' "$label" >&2
        return 1
    fi
    rm -rf "$work_root"
    printf 'Refreshed %s.\n' "$destination"
}

app_artwork="$project_dir/Assets/AppIcon.png"
app_source="$project_dir/Assets/AppIconPadded.png"
app_catalog="$project_dir/Assets.xcassets/AppIcon.appiconset"
app_icns="$project_dir/Sources/toolboxDesktop/toolbox.icns"
dmg_svg="$project_dir/Assets/DMGVolumeIcon.svg"
dmg_png="$project_dir/Assets/DMGVolumeIcon.png"
dmg_catalog="$project_dir/Assets.xcassets/DMGVolumeIcon.appiconset"
dmg_icns="$project_dir/Assets/DMGVolumeIcon.icns"

for required_source in "$app_artwork" "$dmg_svg"; do
    if [ ! -f "$required_source" ]; then
        printf 'error: canonical icon source not found: %s\n' "$required_source" >&2
        exit 1
    fi
done

if needs_refresh "$app_source" "$app_artwork"; then
    if ! generate_macos_app_source "$app_artwork" "$app_source"; then exit 1; fi
fi
if needs_refresh "$app_catalog/icon_512@2x.png" "$app_source"; then
    if ! generate_appiconset "$app_source" "$app_catalog" "AppIcon"; then exit 1; fi
fi
if needs_refresh "$app_icns" "$app_source" "$app_catalog/icon_512@2x.png"; then
    if ! compile_icns "$app_catalog" "$app_icns" "toolbox"; then exit 1; fi
fi

if needs_refresh "$dmg_png" "$dmg_svg"; then
    if ! rsvg-convert --width 1024 --height 1024 --output "$dmg_png" "$dmg_svg"; then
        printf 'error: failed to render DMGVolumeIcon.svg\n' >&2
        exit 1
    fi
    printf 'Refreshed %s from SVG.\n' "$dmg_png"
fi
if needs_refresh "$dmg_catalog/icon_512@2x.png" "$dmg_png"; then
    if ! generate_appiconset "$dmg_png" "$dmg_catalog" "DMGVolumeIcon"; then exit 1; fi
fi
if needs_refresh "$dmg_icns" "$dmg_png" "$dmg_catalog/icon_512@2x.png"; then
    if ! compile_icns "$dmg_catalog" "$dmg_icns" "DMGVolumeIcon"; then exit 1; fi
fi

printf 'Icon assets are current.\n'
