#!/bin/sh
# Build a relocatable, app-private Python environment containing Rich.
#
# A conventional `python -m venv` is intentionally not used here: macOS venvs
# normally retain an absolute reference to their Homebrew/framework Python and
# therefore break after the app moves to another Mac. python-build-standalone
# supplies the relocatable interpreter; installing packages into its own
# site-packages gives the app the venv-like isolation we need.

for required_tool in uname curl shasum awk tar mktemp ditto sed mkdir rm mv; do
    if ! command -v "$required_tool" >/dev/null 2>&1; then
        printf 'error: required Python-runtime tool is missing: %s\n' "$required_tool" >&2
        exit 1
    fi
done

PYTHON_VERSION=3.13.14
RUNTIME_RELEASE=20260728
RICH_REQUIREMENT='rich>=13.9,<15'

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
machine_arch=$(uname -m)
case "$machine_arch" in
    arm64)
        runtime_arch=aarch64
        expected_sha256=aa2a054f5e04bde63ae199e3bb6bbb634e457423efd294842deeb1299e7e5932
        ;;
    x86_64)
        runtime_arch=x86_64
        expected_sha256=aa73c37aebebe3b7264dce1e49923719ab0ac0fc590353adf393eee3e2041c18
        ;;
    *)
        printf 'error: unsupported Mac architecture: %s\n' "$machine_arch" >&2
        exit 1
        ;;
esac

archive_name="cpython-${PYTHON_VERSION}+${RUNTIME_RELEASE}-${runtime_arch}-apple-darwin-install_only_stripped.tar.gz"
archive_url="https://github.com/astral-sh/python-build-standalone/releases/download/${RUNTIME_RELEASE}/${archive_name}"
cache_dir="${script_dir}/.cache"
archive_path="${cache_dir}/${archive_name}"
runtime_cache="${script_dir}/python-${machine_arch}"
destination=${1:-"${runtime_cache}"}
runtime_marker="${PYTHON_VERSION}-${RUNTIME_RELEASE}-rich13"

# The downloaded archive is immutable and checksum-pinned. The extracted cache
# avoids reinstalling Rich on every app build; the marker controls when that
# prepared runtime must be recopied into a destination bundle.

if ! mkdir -p "$cache_dir"; then
    printf 'error: could not create runtime cache: %s\n' "$cache_dir" >&2
    exit 1
fi
if [ ! -f "$archive_path" ]; then
    if ! curl --fail --location --retry 3 "$archive_url" --output "$archive_path"; then
        printf 'error: failed to download the Python runtime\n' >&2
        exit 1
    fi
fi

actual_sha256=$(shasum -a 256 "$archive_path" | awk '{print $1}')
if [ -z "$actual_sha256" ]; then
    printf 'error: could not calculate the Python runtime checksum\n' >&2
    exit 1
fi
if [ "$actual_sha256" != "$expected_sha256" ]; then
    printf 'error: Python runtime checksum mismatch\n' >&2
    exit 1
fi

cached_runtime_marker=$(sed -n '1p' "${runtime_cache}/.toolbox-runtime-version" 2>/dev/null || true)
if [ ! -x "${runtime_cache}/bin/python3" ] || [ "$cached_runtime_marker" != "$runtime_marker" ]; then
    # A constant change must invalidate the prepared cache as well as bundle
    # copies. Otherwise an older interpreter could survive indefinitely simply
    # because its executable is still present.
    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/toolbox-python.XXXXXX")
    if [ ! -d "$work_dir" ]; then
        printf 'error: could not create a temporary runtime directory\n' >&2
        exit 1
    fi
    trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
    if ! tar -xzf "$archive_path" -C "$work_dir"; then
        printf 'error: failed to extract the Python runtime\n' >&2
        exit 1
    fi

    # Install into the runtime's own site-packages. This keeps every Python
    # dependency inside the app and avoids modifying the user's Python setup.
    if ! "$work_dir/python/bin/python3" -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        "$RICH_REQUIREMENT"; then
        printf 'error: failed to install Rich in the private runtime\n' >&2
        exit 1
    fi
    if ! "$work_dir/python/bin/python3" -c 'import rich'; then exit 1; fi

    rm -rf "$runtime_cache"
    if ! mv "$work_dir/python" "$runtime_cache"; then exit 1; fi
    if ! printf '%s\n' "$runtime_marker" > "${runtime_cache}/.toolbox-runtime-version"; then exit 1; fi
    trap - EXIT HUP INT TERM
fi

if [ "$destination" != "$runtime_cache" ]; then
    installed_marker=$(sed -n '1p' "${destination}/.toolbox-runtime-version" 2>/dev/null || true)
    if [ "$installed_marker" != "$runtime_marker" ]; then
        rm -rf "$destination"
        if ! mkdir -p "$(dirname -- "$destination")"; then exit 1; fi
        if ! ditto "$runtime_cache" "$destination"; then
            printf 'error: failed to copy the private Python runtime\n' >&2
            exit 1
        fi
    fi
fi

if ! "${destination}/bin/python3" -c 'import rich, sys; print(f"Bundled Python {sys.version.split()[0]} with Rich is ready.")'; then
    printf 'error: bundled Python runtime validation failed\n' >&2
    exit 1
fi
