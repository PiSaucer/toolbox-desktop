#!/bin/sh
# Stage the repository's canonical toolbox.py for the macOS app build.
#
# This file deliberately lives in the project rather than at the repository
# root so Xcode can run it as a pre-build phase without knowing the caller's
# current working directory. The staged Python file is ignored by Git.

for required_tool in cmp mktemp cp chmod mv grep rm; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf 'error: required staging tool is missing: %s\n' "$required_tool" >&2
        exit 1
    fi
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
desktop_repository=$(CDPATH= cd -- "${script_dir}/../.." && pwd)
workspace_root=$(CDPATH= cd -- "${desktop_repository}/.." && pwd)
source_file="${workspace_root}/toolbox/toolbox.py"
staged_file="${script_dir}/toolbox.py"
source_description="the neighboring toolbox repository"

# Source precedence is deliberate: a neighboring toolbox checkout is best for
# coordinated development, the staged copy makes this repository standalone,
# and GitHub is only a last-resort bootstrap for a checkout missing both.
if [ ! -f "$source_file" ]; then
    if [ -f "$staged_file" ]; then
        printf 'Using the previously staged toolbox.py at %s.\n' "$staged_file"
        exit 0
    fi

    # A standalone toolbox-desktop checkout has no sibling toolbox repository.
    # In that case, bootstrap the same canonical launcher published by the main
    # project instead of requiring someone to copy it into tools by hand.
    if ! command -v curl >/dev/null 2>&1; then
        printf 'error: curl is required to download toolbox.py from GitHub\n' >&2
        exit 1
    fi
    source_file=$(mktemp "${TMPDIR:-/tmp}/toolbox-download.XXXXXX.py")
    if [ ! -f "$source_file" ]; then
        printf 'error: could not create a temporary download file\n' >&2
        exit 1
    fi
    trap 'rm -f "$source_file"' EXIT HUP INT TERM
    source_url="https://raw.githubusercontent.com/PiSaucer/toolbox/main/toolbox.py"
    if ! curl --fail --location --retry 3 --output "$source_file" "$source_url"; then
        printf 'error: could not download toolbox.py from %s\n' "$source_url" >&2
        exit 1
    fi
    if ! grep -Eq '^__version__[[:space:]]*=[[:space:]]*"[^"]+"[[:space:]]*$' "$source_file"; then
        printf 'error: downloaded toolbox.py has no recognizable version\n' >&2
        exit 1
    fi
    source_description="$source_url"
fi

# Avoid changing the staged file's timestamp when the canonical launcher has
# not changed. This prevents needless Xcode resource-copy and signing work.
if [ -f "$staged_file" ] && cmp -s "$source_file" "$staged_file"; then
    printf 'toolbox.py is already staged and current.\n'
    exit 0
fi

temporary_file=$(mktemp "${script_dir}/.toolbox.XXXXXX")
if [ ! -f "$temporary_file" ]; then
    printf 'error: could not create a temporary toolbox.py\n' >&2
    exit 1
fi
# Include a downloaded source in cleanup when this is a standalone checkout.
trap 'rm -f "$temporary_file"; case "${source_file:-}" in "${TMPDIR:-/tmp}"/toolbox-download.*.py) rm -f "$source_file" ;; esac' EXIT HUP INT TERM
if ! cp "$source_file" "$temporary_file"; then exit 1; fi
if ! chmod 0644 "$temporary_file"; then exit 1; fi
if ! mv "$temporary_file" "$staged_file"; then exit 1; fi
trap - EXIT HUP INT TERM
printf 'Staged %s from %s.\n' "$staged_file" "$source_description"
