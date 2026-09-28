#!/usr/bin/env bash
# =============================================================================
# nvm-lite.sh — Lightweight Node.js version manager for Windows Git Bash/MSYS2
# =============================================================================
# Source this file from .bashrc or .profile:
#   source ~/tools/nvm-lite/nvm-lite.sh
#
# All public state lives in nvm-lite.conf (shell-sourceable key=value pairs).
# Installed versions are detected by scanning v-* directories beside this file.
# =============================================================================

# Guard against being executed rather than sourced, but only when not in a
# sub-shell invoked by the command dispatcher (see _nvm_lite_dispatch_cmd).
# We allow direct execution for unit-testing individual functions.
if [[ "${BASH_SOURCE[0]}" == "${0}" && "${NVM_LITE_ALLOW_EXEC:-}" != "1" ]]; then
    echo "nvm-lite: this script must be sourced, not executed." >&2
    echo "  Add to .bashrc:  source /path/to/nvm-lite/nvm-lite.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# 0. Bootstrap — determine home directory
# ---------------------------------------------------------------------------

# NVM_LITE_HOME is the directory that contains nvm-lite.sh, version dirs, and
# the config file.  We resolve it once at source time so every function can
# rely on it without re-deriving it.
if [[ -z "${NVM_LITE_HOME:-}" ]]; then
    # BASH_SOURCE[0] is set even when sourced.
    NVM_LITE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    NVM_LITE_HOME="$(cygpath -u "${NVM_LITE_HOME}")"
fi
export NVM_LITE_HOME

# ---------------------------------------------------------------------------
# 1. Constants
# ---------------------------------------------------------------------------

readonly _NVM_LITE_CONF="${NVM_LITE_HOME}/nvm-lite.conf"
readonly _NVM_LITE_NODE_DIST="https://nodejs.org/dist"
readonly _NVM_LITE_INDEX_URL="${_NVM_LITE_NODE_DIST}/index.json"
readonly _NVM_LITE_CACHE_DIR="${NVM_LITE_HOME}/cache"

# ---------------------------------------------------------------------------
# 2. Logging helpers
# ---------------------------------------------------------------------------

# _nvm_lite_error MESSAGE
#   Print a prefixed error message to stderr.
_nvm_lite_error() {
    echo "nvm-lite [error]: $*" >&2
}

# _nvm_lite_info MESSAGE
#   Print a prefixed informational message to stdout.
_nvm_lite_info() {
    echo "nvm-lite: $*"
}

# _nvm_lite_warn MESSAGE
#   Print a prefixed warning to stderr.
_nvm_lite_warn() {
    echo "nvm-lite [warn]: $*" >&2
}

# ---------------------------------------------------------------------------
# 3. Config management
# ---------------------------------------------------------------------------

# _nvm_lite_load_config
#   Source the config file if it exists, initialising defaults for any
#   variables that are not already set.
_nvm_lite_load_config() {
    if [[ -f "${_NVM_LITE_CONF}" ]]; then
        # shellcheck source=/dev/null
        source "${_NVM_LITE_CONF}"
    fi
    # Apply defaults for variables not present in config
    NVM_LITE_CURRENT="${NVM_LITE_CURRENT:-}"
    NVM_LITE_DEFAULT="${NVM_LITE_DEFAULT:-}"
    NVM_LITE_ARCH="${NVM_LITE_ARCH:-win-x64}"
}

# _nvm_lite_save_config
#   Persist all NVM_LITE_* runtime variables to the config file.
#   The file is a plain shell script so it can be sourced directly.
_nvm_lite_save_config() {
    cat > "${_NVM_LITE_CONF}" <<EOF
# nvm-lite configuration — auto-generated, do not edit manually while
# nvm-lite is active; changes will be overwritten.
NVM_LITE_CURRENT="${NVM_LITE_CURRENT:-}"
NVM_LITE_DEFAULT="${NVM_LITE_DEFAULT:-}"
NVM_LITE_ARCH="${NVM_LITE_ARCH:-win-x64}"
EOF
}

# _nvm_lite_ensure_config
#   Create a default config file if none exists.
_nvm_lite_ensure_config() {
    if [[ ! -f "${_NVM_LITE_CONF}" ]]; then
        NVM_LITE_CURRENT=""
        NVM_LITE_DEFAULT=""
        NVM_LITE_ARCH="win-x64"
        _nvm_lite_save_config
    fi
}

# ---------------------------------------------------------------------------
# 4. PATH helpers
# ---------------------------------------------------------------------------

# _nvm_lite_remove_path PREFIX
#   Remove every PATH component whose value starts with PREFIX.
#   This is used to remove any previously active v-* bin directory.
_nvm_lite_remove_path() {
    local prefix="$1"
    local new_path=""
    local segment

    # Split PATH on ':' and rebuild without matching entries.
    while IFS= read -r -d ':' segment; do
        if [[ "${segment}" != "${prefix}"* ]]; then
            new_path="${new_path:+${new_path}:}${segment}"
        fi
    done < <(printf '%s:' "${PATH}")
    # Handle the last segment (no trailing colon)
    # The loop above handles it because we append ':' in the process substitution.

    export PATH="${new_path}"
}

# _nvm_lite_path_contains ENTRY
#   Return 0 (true) if PATH already contains ENTRY, 1 otherwise.
_nvm_lite_path_contains() {
    local entry="$1"
    local segment
    while IFS= read -r -d ':' segment; do
        if [[ "${segment}" == "${entry}" ]]; then
            return 0
        fi
    done < <(printf '%s:' "${PATH}")
    return 1
}

# ---------------------------------------------------------------------------
# 5. Version directory helpers
# ---------------------------------------------------------------------------

# _nvm_lite_version_dir VERSION
#   Echo the absolute path to the installation directory for VERSION.
#   Does NOT check whether the directory exists.
_nvm_lite_version_dir() {
    local version="$1"
    echo "${NVM_LITE_HOME}/v-${version}"
}

# _nvm_lite_bin_dir VERSION
#   Echo the absolute path to the bin directory inside a Node installation.
#   On Windows zip distributions the executables sit at the root of the
#   extracted folder (no separate bin/ subdirectory).
_nvm_lite_bin_dir() {
    local version="$1"
    echo "${NVM_LITE_HOME}/v-${version}"
}

# _nvm_lite_find_installed
#   Echo a newline-separated list of ALL installed versions, one per line,
#   in ascending semantic version order.
#   Versions are determined purely by scanning v-* directories.
_nvm_lite_find_installed() {
    local dir version versions=()

    for dir in "${NVM_LITE_HOME}"/v-*/; do
        [[ -d "${dir}" ]] || continue
        # Strip the leading path and the "v-" prefix
        version="${dir%/}"          # remove trailing slash
        version="${version##*/}"    # keep basename
        version="${version#v-}"     # strip "v-" prefix
        versions+=("${version}")
    done

    if [[ ${#versions[@]} -eq 0 ]]; then
        return 0
    fi

    # Sort semantically using _nvm_lite_semver_sort
    _nvm_lite_semver_sort "${versions[@]}"
}

# _nvm_lite_semver_sort VERSION [VERSION ...]
#   Print versions on stdout, one per line, in ascending semantic order.
_nvm_lite_semver_sort() {
    local v
    for v in "$@"; do
        printf '%s\n' "${v}"
    done | awk -F. '{printf "%05d.%05d.%05d %s\n", $1, $2, $3, $0}' \
         | sort \
         | awk '{print $2}'
}

# _nvm_lite_resolve_installed SPEC
#   Resolve SPEC (which may be a major like "20" or full "20.19.2") to the
#   highest installed version that matches.
#   Prints the resolved full version string, or nothing if none found.
_nvm_lite_resolve_installed() {
    local spec="$1"
    local installed best=""

    while IFS= read -r installed; do
        [[ -z "${installed}" ]] && continue
        if _nvm_lite_version_matches "${installed}" "${spec}"; then
            best="${installed}"   # semver_sort gives ascending; last wins
        fi
    done < <(_nvm_lite_find_installed)

    echo "${best}"
}

# _nvm_lite_version_matches FULL_VERSION SPEC
#   Return 0 if FULL_VERSION satisfies SPEC.
#   SPEC may be:
#     22          → major only
#     22.16       → major.minor
#     22.16.0     → exact
_nvm_lite_version_matches() {
    local full="$1"
    local spec="$2"

    # Count dots in spec to determine precision
    local dots
    dots=$(printf '%s' "${spec}" | tr -cd '.' | wc -c)

    case "${dots}" in
        0)  # major only
            [[ "${full%%.*}" == "${spec}" ]]
            ;;
        1)  # major.minor
            local major_minor="${full%.*}"
            [[ "${major_minor}" == "${spec}" ]]
            ;;
        2)  # exact match
            [[ "${full}" == "${spec}" ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 6. Remote version resolution
# ---------------------------------------------------------------------------

# _nvm_lite_resolve_remote SPEC
#   Query nodejs.org/dist/index.json and return the highest available version
#   matching SPEC (major, major.minor, or exact).
#   Requires curl.
_nvm_lite_resolve_remote() {
    local spec="$1"
    local json best="" line version

    _nvm_lite_check_curl || return 1

    _nvm_lite_info "Fetching Node.js release index…"
    json="$(curl --silent --show-error --fail --location \
                 --connect-timeout 15 --max-time 60 \
                 "${_NVM_LITE_INDEX_URL}" 2>&1)"
    local curl_exit=$?
    if [[ ${curl_exit} -ne 0 ]]; then
        _nvm_lite_error "Failed to fetch release index: ${json}"
        return 1
    fi

    # Parse the JSON without jq.
    # index.json is a JSON array; each element contains "version":"vX.Y.Z".
    # We extract version strings using grep + sed, then resolve.
    #
    # Format: one JSON object per line (nodejs.org always formats it this way).
    while IFS= read -r line; do
        # Extract the version value e.g. "v22.16.0"
        version="$(printf '%s' "${line}" | grep -o '"version":"v[^"]*"' \
                   | sed 's/"version":"v\([^"]*\)"/\1/')"
        [[ -z "${version}" ]] && continue

        if _nvm_lite_version_matches "${version}" "${spec}"; then
            best="${version}"   # ascending iteration; last match wins
        fi
    done < <(printf '%s' "${json}" | grep '"version"')

    if [[ -z "${best}" ]]; then
        _nvm_lite_error "No release found matching '${spec}' on nodejs.org"
        return 1
    fi

    echo "${best}"
}

# ---------------------------------------------------------------------------
# 7. Dependency checks
# ---------------------------------------------------------------------------

# _nvm_lite_check_curl
#   Return 0 if curl is available, 1 otherwise.
_nvm_lite_check_curl() {
    if ! command -v curl &>/dev/null; then
        _nvm_lite_error "curl is required but was not found in PATH"
        return 1
    fi
}

# _nvm_lite_check_unzip
#   Return 0 if unzip is available, 1 otherwise.
_nvm_lite_check_unzip() {
    if ! command -v unzip &>/dev/null; then
        _nvm_lite_error "unzip is required but was not found in PATH"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 8. Activate / deactivate
# ---------------------------------------------------------------------------

# _nvm_lite_deactivate
#   Remove any currently active v-* entry from PATH and clear NODE_HOME.
_nvm_lite_deactivate() {
    _nvm_lite_remove_path "${NVM_LITE_HOME}/v-"
    unset NODE_HOME
}

# _nvm_lite_activate VERSION
#   Prepend the bin directory for VERSION to PATH and set NODE_HOME.
#   Removes any previously active nvm-lite version from PATH first.
_nvm_lite_activate() {
    local version="$1"
    local bin_dir
    bin_dir="$(_nvm_lite_bin_dir "${version}")"
    bin_dir="$(cygpath -u "${bin_dir}")"

    if [[ ! -d "${bin_dir}" ]]; then
        _nvm_lite_error "Version ${version} is not installed (directory missing: ${bin_dir})"
        return 1
    fi

    # Remove previous nvm-lite entries
    _nvm_lite_deactivate

    # Prepend only if not already present (belt-and-suspenders)
    if ! _nvm_lite_path_contains "${bin_dir}"; then
        export PATH="${bin_dir}:${PATH}"
    fi

    export NODE_HOME="${bin_dir}"
    NVM_LITE_CURRENT="${version}"
}

# ---------------------------------------------------------------------------
# 9. Download
# ---------------------------------------------------------------------------

# _nvm_lite_download VERSION ARCH
#   Download the official Node.js zip for VERSION and ARCH into the cache
#   directory, then extract it into v-VERSION.
#   ARCH defaults to win-x64.
_nvm_lite_download() {
    local version="$1"
    local arch="${2:-win-x64}"
    local zip_name="node-v${version}-${arch}.zip"
    local url="${_NVM_LITE_NODE_DIST}/v${version}/${zip_name}"
    local dest_dir
    dest_dir="$(_nvm_lite_version_dir "${version}")"
    local tmp_zip

    _nvm_lite_check_curl  || return 1
    _nvm_lite_check_unzip || return 1

    # Ensure cache directory exists
    mkdir -p "${_NVM_LITE_CACHE_DIR}"

    local cached_zip="${_NVM_LITE_CACHE_DIR}/${zip_name}"

    # Use a temp file so an interrupted download never leaves a corrupt zip
    tmp_zip="$(mktemp "${_NVM_LITE_CACHE_DIR}/nvm-lite-dl-XXXXXX.zip")"

    _nvm_lite_info "Downloading ${url} …"
    if ! curl --silent --show-error --fail --location \
              --connect-timeout 15 --max-time 600 \
              --output "${tmp_zip}" \
              "${url}"; then
        _nvm_lite_error "Download failed for ${url}"
        rm -f "${tmp_zip}"
        return 1
    fi

    # Basic sanity check — a valid zip starts with PK (0x504B)
    local magic
    magic="$(head -c 2 "${tmp_zip}" 2>/dev/null || true)"
    if [[ "${magic}" != "PK" ]]; then
        _nvm_lite_error "Downloaded file does not appear to be a valid zip archive"
        rm -f "${tmp_zip}"
        return 1
    fi

    mv "${tmp_zip}" "${cached_zip}"

    # Extract into a staging dir first, then rename to final location
    local staging_dir
    staging_dir="$(mktemp -d "${NVM_LITE_HOME}/nvm-lite-stage-XXXXXX")"

    _nvm_lite_info "Extracting ${zip_name} …"
    if ! unzip -q "${cached_zip}" -d "${staging_dir}"; then
        _nvm_lite_error "Extraction failed"
        rm -f "${cached_zip}"
        rm -rf "${staging_dir}"
        return 1
    fi

    # The zip contains a single top-level directory: node-vVERSION-ARCH/
    local extracted_root
    extracted_root="$(find "${staging_dir}" -mindepth 1 -maxdepth 1 -type d | head -1)"

    if [[ -z "${extracted_root}" ]]; then
        _nvm_lite_error "Could not find extracted directory in ${staging_dir}"
        rm -f "${cached_zip}"
        rm -rf "${staging_dir}"
        return 1
    fi

    # Move to final location
    if ! mv "${extracted_root}" "${dest_dir}"; then
        _nvm_lite_error "Failed to move extracted directory to ${dest_dir}"
        rm -f "${cached_zip}"
        rm -rf "${staging_dir}"
        return 1
    fi

    rm -rf "${staging_dir}"

    # Remove zip after successful extraction
    rm -f "${cached_zip}"

    _nvm_lite_info "Node.js v${version} installed to ${dest_dir}"
}

# ---------------------------------------------------------------------------
# 10. Command implementations
# ---------------------------------------------------------------------------

# _nvm_lite_cmd_install SPEC
#   Install a Node.js version.  SPEC may be a major number or full version.
_nvm_lite_cmd_install() {
    local spec="${1:-}"

    if [[ -z "${spec}" ]]; then
        _nvm_lite_error "Usage: nvm-lite install <version>"
        return 1
    fi

    local version

    # Determine whether we need to resolve remotely
    local dots
    dots=$(printf '%s' "${spec}" | tr -cd '.' | wc -c)

    if [[ "${dots}" -lt 2 ]]; then
        # Partial spec — resolve from nodejs.org
        version="$(_nvm_lite_resolve_remote "${spec}")" || return 1
    else
        version="${spec}"
    fi

    # Validate version format (must be X.Y.Z with digits)
    if ! printf '%s' "${version}" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
        _nvm_lite_error "Invalid version format: '${version}'"
        return 1
    fi

    local dest_dir
    dest_dir="$(_nvm_lite_version_dir "${version}")"

    if [[ -d "${dest_dir}" ]]; then
        _nvm_lite_info "Node.js v${version} is already installed at ${dest_dir}"
        return 0
    fi

    local arch="${NVM_LITE_ARCH:-win-x64}"
    _nvm_lite_download "${version}" "${arch}" || return 1
}

# _nvm_lite_cmd_use SPEC
#   Switch to a Node.js version in the current shell.
_nvm_lite_cmd_use() {
    local spec="${1:-}"

    if [[ -z "${spec}" ]]; then
        _nvm_lite_error "Usage: nvm-lite use <version>"
        return 1
    fi

    local version
    version="$(_nvm_lite_resolve_installed "${spec}")"

    if [[ -z "${version}" ]]; then
        _nvm_lite_error "No installed version matches '${spec}'. Run: nvm-lite install ${spec}"
        return 1
    fi

    _nvm_lite_activate "${version}" || return 1
    _nvm_lite_save_config
    _nvm_lite_info "Now using Node.js v${version}"
}

# _nvm_lite_cmd_current
#   Print the currently active version.
_nvm_lite_cmd_current() {
    if [[ -z "${NVM_LITE_CURRENT:-}" ]]; then
        _nvm_lite_info "No version currently active"
    else
        echo "v${NVM_LITE_CURRENT}"
    fi
}

# _nvm_lite_cmd_uninstall SPEC
#   Remove an installed Node.js version.
_nvm_lite_cmd_uninstall() {
    local spec="${1:-}"

    if [[ -z "${spec}" ]]; then
        _nvm_lite_error "Usage: nvm-lite uninstall <version>"
        return 1
    fi

    local version
    version="$(_nvm_lite_resolve_installed "${spec}")"

    if [[ -z "${version}" ]]; then
        _nvm_lite_error "No installed version matches '${spec}'"
        return 1
    fi

    local dest_dir
    dest_dir="$(_nvm_lite_version_dir "${version}")"

    _nvm_lite_info "Uninstalling Node.js v${version} from ${dest_dir} …"
    rm -rf "${dest_dir}"

    # If we just removed the active version, deactivate and clear config
    if [[ "${NVM_LITE_CURRENT:-}" == "${version}" ]]; then
        _nvm_lite_deactivate
        NVM_LITE_CURRENT=""
        _nvm_lite_save_config
        _nvm_lite_warn "Active version removed; no version is currently selected"
    fi

    _nvm_lite_info "Node.js v${version} uninstalled"
}

# _nvm_lite_cmd_list
#   List all installed versions, marking the currently active one.
_nvm_lite_cmd_list() {
    local installed
    local found=0

    while IFS= read -r installed; do
        [[ -z "${installed}" ]] && continue
        found=1
        if [[ "${installed}" == "${NVM_LITE_CURRENT:-}" ]]; then
            printf '  -> v%s  (current)\n' "${installed}"
        else
            printf '     v%s\n' "${installed}"
        fi
    done < <(_nvm_lite_find_installed)

    if [[ ${found} -eq 0 ]]; then
        _nvm_lite_info "No versions installed. Run: nvm-lite install <version>"
    fi
}

# _nvm_lite_cmd_deactivate
#   Deactivate the currently active version in the current shell, without
#   modifying the persisted config.
_nvm_lite_cmd_deactivate() {
    _nvm_lite_deactivate
    NVM_LITE_CURRENT=""
    _nvm_lite_info "Deactivated. No Node.js version is now active in this shell."
}

# _nvm_lite_cmd_help
#   Print usage information.
_nvm_lite_cmd_help() {
    cat <<'HELP'
nvm-lite — Lightweight Node.js version manager for Windows Git Bash / MSYS2

USAGE
  nvm-lite <command> [args]

COMMANDS
  install <version>     Install a Node.js version.
                        <version> may be a major (e.g. 22) or full semver (22.16.0).

  use <version>         Activate an installed version in the current shell.
                        <version> may be a major or full semver.

  current               Print the currently active Node.js version.

  list                  List all installed versions.

  uninstall <version>   Remove an installed version.

  deactivate            Remove any active Node.js version from PATH.

  help                  Show this help message.

EXAMPLES
  nvm-lite install 22           # install latest 22.x.x
  nvm-lite install 20.19.2      # install exact version
  nvm-lite use 22               # activate highest installed 22.x
  nvm-lite use 20.19.2          # activate exact version
  nvm-lite current              # print active version
  nvm-lite list                 # list all installed versions
  nvm-lite uninstall 20         # remove highest installed 20.x
  nvm-lite deactivate           # remove Node from PATH in this shell

ENVIRONMENT
  NVM_LITE_HOME     Directory containing nvm-lite.sh and version folders.
  NVM_LITE_CURRENT  Currently active version (persisted to config).
  NVM_LITE_DEFAULT  Default version to activate on shell start (optional).
  NVM_LITE_ARCH     Windows architecture (default: win-x64).

HELP
}

# ---------------------------------------------------------------------------
# 11. Main dispatcher — the public nvm-lite function
# ---------------------------------------------------------------------------

# nvm-lite COMMAND [ARGS...]
#   Main entry point registered as a shell function so it runs in the current
#   shell and can modify PATH, NODE_HOME, and NVM_LITE_CURRENT.
nvm-lite() {
    local cmd="${1:-help}"
    shift || true

    case "${cmd}" in
        install)    _nvm_lite_cmd_install "$@" ;;
        use)        _nvm_lite_cmd_use     "$@" ;;
        current)    _nvm_lite_cmd_current      ;;
        list|ls)    _nvm_lite_cmd_list         ;;
        uninstall)  _nvm_lite_cmd_uninstall "$@" ;;
        deactivate) _nvm_lite_cmd_deactivate   ;;
        help|--help|-h) _nvm_lite_cmd_help     ;;
        *)
            _nvm_lite_error "Unknown command: '${cmd}'. Run 'nvm-lite help' for usage."
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# 12. Initialisation (runs at source time)
# ---------------------------------------------------------------------------

# Ensure the cache directory exists
mkdir -p "${_NVM_LITE_CACHE_DIR}"

# Create config if it does not exist yet
_nvm_lite_ensure_config

# Load config
_nvm_lite_load_config

# Auto-activate default or current version
_nvm_lite_auto_activate() {
    local target=""

    # Prefer NVM_LITE_DEFAULT if set, else fall back to NVM_LITE_CURRENT
    if [[ -n "${NVM_LITE_DEFAULT:-}" ]]; then
        target="${NVM_LITE_DEFAULT}"
    elif [[ -n "${NVM_LITE_CURRENT:-}" ]]; then
        target="${NVM_LITE_CURRENT}"
    fi

    if [[ -z "${target}" ]]; then
        return 0
    fi

    # Only activate if the directory is present; avoid error spam on first use
    local resolved
    resolved="$(_nvm_lite_resolve_installed "${target}")"
    if [[ -n "${resolved}" ]]; then
        _nvm_lite_activate "${resolved}" 2>/dev/null || true
    fi
}

_nvm_lite_auto_activate
