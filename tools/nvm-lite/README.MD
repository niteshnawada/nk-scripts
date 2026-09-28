# nvm-lite

> Lightweight Node.js version manager for **Windows Git Bash** and **MSYS2** — no admin rights required.

---

## Table of Contents

1. [Project overview](#1-project-overview)
2. [Directory layout](#2-directory-layout)
3. [Configuration](#3-configuration)
4. [Installation](#4-installation)
5. [Initialisation from .bashrc / .profile](#5-initialisation-from-bashrc--profile)
6. [Internal architecture](#6-internal-architecture)
7. [PATH management](#7-path-management)
8. [Command reference](#8-command-reference)
9. [Examples](#9-examples)
10. [Troubleshooting](#10-troubleshooting)
11. [Limitations](#11-limitations)
12. [Future enhancements](#12-future-enhancements)

---

## 1. Project overview

`nvm-lite` is a self-contained Bash script that lets you install, switch between, and uninstall multiple versions of Node.js on Windows — without administrator privileges, without PowerShell, and without any runtime beyond a standard Git Bash / MSYS2 environment.

### Why not use the official `nvm-windows`?

`nvm-windows` is an excellent tool, but it requires an installer, writes to the Windows registry, and manipulates system `PATH` entries that need elevated permissions. `nvm-lite` downloads official Node.js `.zip` archives directly from `nodejs.org`, extracts them to a directory you own, and manipulates `PATH` only inside the current Bash session.

### Key properties

| Property | Detail |
|---|---|
| **Zero admin rights** | All files live in your home directory (or any writable path you choose). |
| **No installer** | Just `source` the script. |
| **No database** | Installed versions are discovered by scanning `v-*` directories. |
| **No external tools** | Uses only `bash`, `curl`, `unzip`, `sed`, `grep`, `awk`, `sort`, `tr`, `cut`, `mktemp`. |
| **No PowerShell** | Pure Bash. |
| **Session-scoped PATH** | `PATH` changes apply only to the current shell; nothing is permanently written to the Windows system environment. |

---

## 2. Directory layout

```
~/tools/nvm-lite/          ← NVM_LITE_HOME (any writable location works)
│
├── nvm-lite.sh            ← main script (sourced from .bashrc)
├── nvm-lite.conf          ← runtime configuration (auto-generated)
│
├── cache/                 ← temporary download staging area (auto-created)
│
├── v-18.20.8/             ← extracted Node.js 18.20.8
│   ├── node.exe
│   ├── npm
│   ├── npx
│   └── …
│
├── v-20.19.2/             ← extracted Node.js 20.19.2
│   └── …
│
└── v-22.16.0/             ← extracted Node.js 22.16.0 (example)
    └── …
```

Each version directory follows the pattern `v-<MAJOR>.<MINOR>.<PATCH>` and is created directly by extracting the official Node.js Windows `.zip` archive — no renaming or restructuring of contents occurs.

The `cache/` directory is used only as a staging area during download; zips are deleted immediately after a successful extraction.

---

## 3. Configuration

The file `nvm-lite.conf` is a plain Bash script that is `source`d at startup. Every variable name begins with `NVM_LITE_`.

```bash
# nvm-lite.conf
NVM_LITE_CURRENT="22.16.0"   # version activated on shell start
NVM_LITE_DEFAULT=""           # optional override for the startup version
NVM_LITE_ARCH="win-x64"      # download architecture
```

### Variable reference

| Variable | Description | Default |
|---|---|---|
| `NVM_LITE_HOME` | Absolute path to the nvm-lite directory. Set at source time from `BASH_SOURCE[0]`. | auto |
| `NVM_LITE_CURRENT` | The version that was last activated with `nvm-lite use`. Persisted to config. | `""` |
| `NVM_LITE_DEFAULT` | An optional pinned default. If set, it takes precedence over `NVM_LITE_CURRENT` at shell start. | `""` |
| `NVM_LITE_ARCH` | Windows CPU architecture suffix for downloads. | `win-x64` |

`NVM_LITE_HOME` is `export`ed so sub-processes can locate the installation. `NVM_LITE_CURRENT` is kept as a shell variable only (not exported) because it is session state, not environment that child processes need.

---

## 4. Installation

### Step 1 — Choose a home directory

Pick any directory you own. The rest of this guide uses `~/tools/nvm-lite`:

```bash
mkdir -p ~/tools/nvm-lite
```

### Step 2 — Copy the files

Place `nvm-lite.sh` and `nvm-lite.conf` into that directory:

```
~/tools/nvm-lite/
├── nvm-lite.sh
└── nvm-lite.conf
```

Make the script executable (optional — it is sourced, not executed, but good practice):

```bash
chmod +x ~/tools/nvm-lite/nvm-lite.sh
```

### Step 3 — Source from your shell profile

See [Section 5](#5-initialisation-from-bashrc--profile).

---

## 5. Initialisation from .bashrc / .profile

Add the following line to `~/.bashrc` (for interactive shells) **or** `~/.profile` (for login shells):

```bash
# nvm-lite — Node.js version manager
source ~/tools/nvm-lite/nvm-lite.sh
```

**Order matters.** Place this line after any other tool that might modify `PATH` (e.g. `pyenv`, `rbenv`) to avoid ordering conflicts.

After saving the file, reload your shell:

```bash
source ~/.bashrc
# or open a new terminal window
```

### What happens at source time?

1. `NVM_LITE_HOME` is set to the directory containing `nvm-lite.sh`.
2. The `cache/` subdirectory is created if absent.
3. `nvm-lite.conf` is created with defaults if absent.
4. `nvm-lite.conf` is sourced to load saved state.
5. If `NVM_LITE_DEFAULT` is set, that version is activated; otherwise, if `NVM_LITE_CURRENT` is set, that version is activated.
6. The `nvm-lite` shell function is registered.

If no version is configured, the shell starts normally with no Node.js modifications.

---

## 6. Internal architecture

`nvm-lite.sh` is structured in twelve numbered sections:

| Section | Purpose |
|---|---|
| 0 — Bootstrap | Resolve `NVM_LITE_HOME` from `BASH_SOURCE[0]`. Guard against being executed instead of sourced. |
| 1 — Constants | `readonly` variables for config path, download base URL, cache dir. |
| 2 — Logging | `_nvm_lite_error`, `_nvm_lite_info`, `_nvm_lite_warn` — all output prefixed with `nvm-lite:`. |
| 3 — Config | `_nvm_lite_load_config`, `_nvm_lite_save_config`, `_nvm_lite_ensure_config`. |
| 4 — PATH helpers | `_nvm_lite_remove_path`, `_nvm_lite_path_contains` — pure string manipulation, no subshells. |
| 5 — Version discovery | `_nvm_lite_find_installed`, `_nvm_lite_semver_sort`, `_nvm_lite_resolve_installed`, `_nvm_lite_version_matches`. |
| 6 — Remote resolution | `_nvm_lite_resolve_remote` — fetches and parses `index.json` without `jq`. |
| 7 — Dependency checks | `_nvm_lite_check_curl`, `_nvm_lite_check_unzip`. |
| 8 — Activate/deactivate | `_nvm_lite_activate`, `_nvm_lite_deactivate`. |
| 9 — Download | `_nvm_lite_download` — atomic download-then-rename pattern. |
| 10 — Commands | `_nvm_lite_cmd_install`, `_nvm_lite_cmd_use`, `_nvm_lite_cmd_current`, `_nvm_lite_cmd_uninstall`, `_nvm_lite_cmd_list`, `_nvm_lite_cmd_deactivate`, `_nvm_lite_cmd_help`. |
| 11 — Dispatcher | `nvm-lite()` shell function — routes to command implementations. |
| 12 — Initialisation | Auto-activate logic that runs once at source time. |

### Helper function naming convention

All internal helpers are prefixed with `_nvm_lite_` (double underscore prefix + `nvm_lite_`) to minimise collision risk with other shell functions. The public entry point is the single `nvm-lite` function (with a hyphen).

### No install database

Installed versions are discovered entirely by directory scanning:

```bash
for dir in "${NVM_LITE_HOME}"/v-*/; do
    version="${dir%/}"
    version="${version##*/}"
    version="${version#v-}"
    …
done
```

This means you can install a version by manually extracting a Node.js zip to a `v-X.Y.Z/` directory beside `nvm-lite.sh` and it will be recognised immediately.

---

## 7. PATH management

### How it works

When you run `nvm-lite use <version>`, the script:

1. Calls `_nvm_lite_deactivate`, which removes every `PATH` entry starting with `${NVM_LITE_HOME}/v-` using a string-splitting loop (no `sed`/`grep` on `PATH`).
2. Prepends `${NVM_LITE_HOME}/v-<version>` to `PATH`.
3. Sets `NODE_HOME` to the same directory.
4. Updates `NVM_LITE_CURRENT` and writes `nvm-lite.conf`.

Because the `nvm-lite` function runs **in the current shell** (not a subshell), its `export PATH=…` affects the calling environment directly.

### No duplicates

Before prepending, `_nvm_lite_path_contains` checks whether the entry is already present. This guards against accidental double-sourcing of `.bashrc`.

### Session scope

PATH changes are **not permanent**. They affect only the current Bash session. Opening a new terminal will re-run the `.bashrc` source line, which activates `NVM_LITE_CURRENT` (or `NVM_LITE_DEFAULT`) from the saved config — that is the only "persistence".

If you want a version active in all new shells, use it and the config will be updated:

```bash
nvm-lite use 22
# Now NVM_LITE_CURRENT="22.16.0" is saved to nvm-lite.conf
# Every new shell will activate 22.16.0
```

---

## 8. Command reference

### `install`

```
nvm-lite install <version>
```

- `<version>` may be a major number (`22`), major.minor (`22.16`), or full semver (`22.16.0`).
- When only a major (or major.minor) is given, the latest matching release is fetched from `https://nodejs.org/dist/index.json`.
- If the version is already installed the command exits successfully with no action.
- The official `.zip` is downloaded to `cache/`, extracted, and the zip is removed.
- Interrupted downloads leave no corrupt state (atomic temp-file pattern).

### `use`

```
nvm-lite use <version>
```

- Activates a version in the current shell.
- `<version>` may be partial (major/major.minor); the highest installed matching version is selected.
- Updates `PATH`, sets `NODE_HOME`, and persists the selection to `nvm-lite.conf`.

### `current`

```
nvm-lite current
```

Prints the currently active version (e.g. `v22.16.0`), or a message if none is active.

### `list` / `ls`

```
nvm-lite list
nvm-lite ls
```

Lists all installed versions in ascending semantic order, marking the active version with `->`.

### `uninstall`

```
nvm-lite uninstall <version>
```

- Removes the version directory (`v-<version>/`) from `NVM_LITE_HOME`.
- If the removed version was the active one, it is deactivated and `NVM_LITE_CURRENT` is cleared.
- `<version>` may be partial.

### `deactivate`

```
nvm-lite deactivate
```

Removes any active Node.js version from `PATH` in the current shell without modifying the config file. Useful when you temporarily want a version-free environment.

### `help`

```
nvm-lite help
nvm-lite --help
nvm-lite -h
```

Prints usage information.

---

## 9. Examples

### Installing and switching versions

```bash
# Install the latest Node.js 22 (resolves to e.g. 22.16.0)
nvm-lite install 22

# Install an exact version
nvm-lite install 20.19.2

# List what is installed
nvm-lite list
#      v20.19.2
#   -> v22.16.0  (current)

# Switch to 20
nvm-lite use 20
node --version   # v20.19.2

# Switch back to 22
nvm-lite use 22
node --version   # v22.16.0
```

### Checking the active version

```bash
nvm-lite current
# v22.16.0
```

### Removing a version

```bash
nvm-lite uninstall 20
nvm-lite list
#   -> v22.16.0  (current)
```

### Temporarily removing Node from PATH

```bash
nvm-lite deactivate
which node     # not found
nvm-lite use 22
which node     # ~/tools/nvm-lite/v-22.16.0/node
```

### Using a pinned default

Edit `nvm-lite.conf`:

```bash
NVM_LITE_DEFAULT="22.16.0"
```

Now every new shell activates 22.16.0, regardless of what `nvm-lite use` last set.

### Running a script with a specific version without switching globally

```bash
# Activate in a subshell
(nvm-lite use 18 && node my-legacy-script.js)
# The outer shell is unaffected
```

---

## 10. Troubleshooting

### `nvm-lite: command not found`

You have not sourced the script. Add to `~/.bashrc`:

```bash
source ~/tools/nvm-lite/nvm-lite.sh
```

Then reload: `source ~/.bashrc`

### `nvm-lite: this script must be sourced, not executed`

You ran `bash nvm-lite.sh` or `./nvm-lite.sh` instead of sourcing it. PATH changes require the script to run **in the current shell**. Always use `source`.

### `curl: command not found`

Install curl. In Git Bash, curl is bundled with Git for Windows. In MSYS2:

```bash
pacman -S curl
```

### `unzip: command not found`

Install unzip. In MSYS2:

```bash
pacman -S unzip
```

In Git Bash (Git for Windows), unzip may not be included. Workaround: install it via the [Git for Windows SDK](https://github.com/git-for-windows/build-extra/releases) or install MSYS2 where package management is available.

### Download fails with `curl: (22) The requested URL returned error: 404`

The version you requested does not exist on nodejs.org. Check available versions at:

```
https://nodejs.org/dist/index.json
```

Or list LTS releases at `https://nodejs.org/en/about/previous-releases`.

### Download fails with SSL / certificate errors

Git for Windows bundles its own CA bundle. If you are behind a corporate proxy or firewall:

```bash
# Point curl at the system CA store
export CURL_CA_BUNDLE=/c/Windows/System32/curl-ca-bundle.crt
# or disable verification temporarily (NOT recommended for production):
export CURL_INSECURE=1
```

### `node` not found after `nvm-lite use`

Check that `NVM_LITE_HOME` is correct:

```bash
echo "$NVM_LITE_HOME"
ls "$NVM_LITE_HOME"
```

Also verify that the version directory contains `node.exe`:

```bash
ls "$NVM_LITE_HOME/v-22.16.0/"
```

### Version not detected by `nvm-lite list`

Check that the directory name exactly matches `v-MAJOR.MINOR.PATCH` with no extra characters or uppercase letters.

### Config gets corrupted

Delete `nvm-lite.conf` and let the script regenerate it:

```bash
rm ~/tools/nvm-lite/nvm-lite.conf
source ~/tools/nvm-lite/nvm-lite.sh
```

Then re-run `nvm-lite use <version>` to restore your selection.

### `nvm-lite use` activates the wrong version

`use` selects the **highest** installed version matching your spec. Use the full version string to be precise:

```bash
nvm-lite use 20.18.0   # exact
```

---

## 11. Limitations

- **Windows only.** The download URL is hard-coded to `win-x64` (or whatever `NVM_LITE_ARCH` is set to). This will not download Linux or macOS binaries.
- **No `.nvmrc` / `.node-version` support.** There is no automatic project-level version switching when you `cd` into a directory.
- **No npm/npx isolation.** Global npm packages (`npm install -g`) land in the Node installation directory. If you remove a version, those global packages are gone.
- **No shell completion.** Tab-completion is not implemented.
- **No checksum verification.** Downloaded zips are checked only for the `PK` magic bytes; SHA checksums from nodejs.org are not verified.
- **PATH changes are session-scoped.** A GUI application launched from the Windows desktop will not see the modified PATH; it uses the Windows system PATH.
- **No concurrent use across shells.** If you run `nvm-lite use 20` in terminal A and `nvm-lite use 22` in terminal B, each shell has its own PATH but both will update `nvm-lite.conf`, so the last writer wins in terms of what activates for new shells.
- **Requires Bash 4+.** Associative arrays and some parameter expansions used are not available in Bash 3 (macOS default).

---

## 12. Future enhancements

| Enhancement | Notes |
|---|---|
| `.nvmrc` / `.node-version` auto-switching | Use a `PROMPT_COMMAND` hook or `cd` override to check for version files when changing directories. |
| SHA-256 checksum verification | Download `SHASUMS256.txt` from nodejs.org and verify after download. |
| Offline mode | Cache `index.json` locally with a TTL so `install` and `resolve` work without internet. |
| npm global package migration | Before uninstalling a version, offer to `npm install -g` the same packages into the target version. |
| Shell completion | Add `_nvm_lite_complete` function registered with `complete -F`. |
| `alias` command | Persist named aliases (`lts`, `stable`, `default`) separately from version numbers. |
| Linux / macOS support | Detect OS at source time and adjust download URL and binary layout accordingly. |
| `exec` / `run` command | `nvm-lite exec 20 node script.js` — run a command with a specific version without changing the current shell. |
| Parallel downloads | Use `curl --parallel` (curl 7.66+) when installing multiple versions in sequence. |
| `update` command | Re-resolve a major version remotely and install if a newer patch is available. |

