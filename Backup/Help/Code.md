# simpleDocker — Codebase Reference

> For AI assistants. Describes architecture, key functions, data flows, and patterns. Designed to stay useful as the codebase evolves — focuses on shape and intent rather than exact line numbers.

---

## Table of Contents

- [Architecture summary](#architecture-summary)
- [Entry point and startup](#entry-point-and-startup)
- [Global state](#global-state)
- [Image and directory layout](#image-and-directory-layout)
- [Container state machine](#container-state-machine)
- [Blueprint pipeline](#blueprint-pipeline)
- [Install pipeline](#install-pipeline)
- [Start pipeline](#start-pipeline)
- [Cron engine](#cron-engine)
- [UI system](#ui-system)
- [Networking](#networking)
- [Storage system](#storage-system)
- [Backup system](#backup-system)
- [Update system](#update-system)
- [Other menu subsystems](#other-menu-subsystems)
- [Key helpers quick-reference](#key-helpers-quick-reference)
- [Naming conventions](#naming-conventions)
- [Patterns and idioms](#patterns-and-idioms)
- [What not to change without reading first](#what-not-to-change-without-reading-first)

---

## Architecture summary

simpleDocker is a single bash script (~7600 lines). No daemons, no external services at rest. Everything is driven by:

- **fzf** for the interactive UI (every menu is a `fzf` call)
- **tmux** for session management (every running container/install/cron is a named tmux session)
- **BTRFS** for storage (images, subvolumes, snapshots)
- **Linux namespaces** (`unshare`, `nsenter`) for container isolation
- **Ubuntu chroot** as a shared base filesystem for all containers
- **jq** for all JSON reads/writes

The script is structured in roughly this order:

```
1. Config / globals / color vars / L[] labels / KB[] keybindings
2. SD_PERSISTENT_END heredoc — built-in blueprints baked into the script
3. SD_BLUEPRINT_PRESET — template shown to users
4. declare -A L — UI label strings
5. Runtime globals (dirs, state vars)
6. Helper functions (ordered roughly by dependency)
7. Blueprint parser and compiler
8. Install/update/start script generators
9. Cron engine
10. Menu functions (container, groups, blueprints, other, main)
11. Entry point: _require_sudo → _setup_image → main_menu
```

---

## Entry point and startup

```bash
_require_sudo         # writes sudoers file for passwordless mount/chroot/unshare ops
_setup_image          # prompts user to select or create a .img file, mounts it
main_menu             # infinite loop driving the top-level fzf UI
```

`_setup_image` sets all global dir vars (`MNT_DIR`, `CONTAINERS_DIR`, etc.) and calls `_set_img_dirs`. If `DEFAULT_IMG` is set and the file exists, it skips the picker entirely.

---

## Global state

### Configuration globals (top of file, user-editable)

| Variable | Purpose |
|----------|---------|
| `DEFAULT_IMG` | Path to auto-mount on launch; skips image picker if set and valid |
| `DEFAULT_UBUNTU_PKGS` | Space-separated apt packages always present in Ubuntu base |
| `ROOT_DIR` | Config directory on host (`~/.config/simpleDocker`) |
| `KB[]` | Associative array of fzf keybindings (`detach`, `quit`, `tmux_detach`) |
| Color vars | `GRN RED YLW BLU CYN BLD DIM NC` — ANSI escape codes |

### Runtime globals (set after image is mounted)

| Variable | Purpose |
|----------|---------|
| `MNT_DIR` | Host path where the .img is mounted |
| `IMG_PATH` | Path to the .img file itself |
| `BLUEPRINTS_DIR` | `$MNT_DIR/Blueprints` |
| `CONTAINERS_DIR` | `$MNT_DIR/Containers` |
| `INSTALLATIONS_DIR` | `$MNT_DIR/Installations` |
| `BACKUP_DIR` | `$MNT_DIR/Backup` |
| `STORAGE_DIR` | `$MNT_DIR/Storage` |
| `UBUNTU_DIR` | `$MNT_DIR/Ubuntu` — the Ubuntu chroot |
| `GROUPS_DIR` | `$MNT_DIR/Groups` |
| `LOGS_DIR` | Inside-image log directory |
| `CACHE_DIR` | `$MNT_DIR/.cache` — size cache, GitHub tag cache |
| `TMP_DIR` | Initially `$SD_MNT_BASE/.tmp`; wiped and recreated on every mount |
| `SD_SHELL_PID` | PID of the main shell — receives SIGUSR1 to force fzf refresh |
| `SD_ACTIVE_FZF_PID` | PID of the currently blocking fzf subprocess |

### `declare -A L` — UI labels

All user-visible strings are in `L[key]`. To change button text, edit the value here. Keys map to logical actions (e.g. `L[ct_start]`, `L[ct_stop]`, `L[back]`). This array is used throughout all menu functions for case matching — `"${L[ct_start]}"` is both the display label and the match target.

---

## Image and directory layout

```
$MNT_DIR/
├── Blueprints/           *.toml files (user-created blueprints)
├── Containers/
│   └── <cid>/
│       ├── service.json  compiled blueprint (source of truth at runtime)
│       ├── service.src   raw DSL text (edited by user, compiled on demand)
│       ├── state.json    installed, name, storage_id, etc.
│       ├── .install_ok   sentinel: install succeeded
│       ├── .install_fail sentinel: install failed
│       └── cron_N_next   timestamp file per cron job (used by loop to check exit)
├── Installations/
│   └── <cid>/            BTRFS subvolume = $CONTAINER_ROOT at runtime
├── Groups/
│   └── <gid>.json        group definition
├── Storage/
│   └── <sid>/            persistent storage profile directory
├── Backup/
│   └── <cid>/            BTRFS snapshots + .meta files
├── Ubuntu/               Ubuntu 24.04 minirootfs (shared base for all containers)
├── .cache/
│   ├── sd_size/<cid>     cached disk usage in GB (written after stop/install)
│   └── gh_tag/<cid>      cached GitHub release tag per container
└── .sd/
    ├── bp_settings.json  blueprint autodetect config
    ├── Caddyfile         reverse proxy config
    ├── caddy/            Caddy data/storage
    └── netns_hosts       /etc/hosts for container network namespace
```

**Container ID (`cid`):** a short random hex string generated at container creation. Used as directory name, tmux session suffix, and storage key. Never changes for the lifetime of a container.

---

## Container state machine

A container's state is determined at runtime by inspecting files and tmux sessions — there is no explicit state enum stored.

```
Uninstalled
    ↓  Install triggered
Installing  (sdInst_<cid> tmux session running)
    ↓  .install_ok written
    ↓  user clicks "Finish installation"
Installed/Stopped  (.install_ok present, no active tmux session)
    ↓  Start
Running  (sd_<cid> tmux session active)
    ↓  Stop / session dies
Installed/Stopped
    ↓  Uninstall
Uninstalled
```

**Detecting state in code:**

```bash
_st "$cid" installed        # returns "true" if installed
tmux_up "$(tsess "$cid")"   # returns 0 if container session running
_is_installing "$cid"       # returns 0 if install session running
```

**Key state accessors:**

| Function | Returns |
|----------|---------|
| `_cname "$cid"` | Container name string |
| `_cpath "$cid"` | Installation path (`$INSTALLATIONS_DIR/<cid>`) |
| `_st "$cid" key` | Value from `state.json` for the given key |
| `tsess "$cid"` | tmux session name for the container (`sd_<cid>`) |
| `_inst_sess "$cid"` | tmux session name for install (`sdInst_<cid>`) |

---

## Blueprint pipeline

**Three blueprint sources:**

1. **File blueprints** — `.toml` files in `$BLUEPRINTS_DIR`. The user edits these. Stored as `service.src` per container.
2. **Persistent blueprints** — baked into the script inside the `SD_PERSISTENT_END` heredoc block. Read with `_get_persistent_bp name`. Listed with `_list_persistent_names`.
3. **Imported blueprints** — `.container` files found on the host filesystem via `_bp_autodetect_dirs`. Autodetect mode configured in `$MNT_DIR/.sd/bp_settings.json`.

**Compile path:**

```
service.src (DSL text)
    → _bp_parse        reads sections into global BP_* variables
    → _bp_validate     checks required fields
    → _bp_compile_to_json   writes service.json
```

`_compile_service "$cid"` is the public entry point. It's called before every install, start, and update — so edits to `service.src` are automatically picked up.

**Key parser globals** (populated by `_bp_parse`):

```
BP_META[]         associative array of [meta] key=value pairs
BP_ENV[]          associative array of [env] key=value pairs
BP_STORAGE        raw string from [storage]
BP_DEPS           raw string from [deps]
BP_DIRS           raw string from [dirs]
BP_PIP            raw string from [pip]
BP_NPM            raw string from [npm]
BP_GITHUB         raw string from [git]
BP_BUILD          raw string from [build]
BP_INSTALL        raw string from [install]
BP_UPDATE         raw string from [update]
BP_START          raw string from [start]
BP_ACTIONS_NAMES[]   action labels (parallel arrays)
BP_ACTIONS_SCRIPTS[] action DSL strings
BP_CRON_NAMES[]      cron job names (parallel arrays)
BP_CRON_INTERVALS[]  cron intervals
BP_CRON_CMDS[]       cron commands
BP_CRON_FLAGS[]      cron flags (--sudo, --unjailed)
```

---

## Install pipeline

Entry point: `_run_job "install" "$cid"`

Generates a full bash script in a temp file, then launches it in a tmux session via `_tmux_launch`. The generated script runs these steps in order:

```
1. Ubuntu base auto-bootstrap (if not yet installed — _emit_ubuntu_bootstrap_inline)
2. [deps]   → apt-get install into $UBUNTU_DIR
3. [dirs]   → mkdir -p inside the installation subvolume
4. [pip]    → pip install into $CONTAINER_ROOT/venv (inside Ubuntu chroot)
5. [npm]    → npm install into $CONTAINER_ROOT/node_modules (inside Ubuntu chroot)
6. [git]    → download releases or clone repos (_emit_runner_steps)
7. [build]  → run inside Ubuntu chroot with /mnt = $CONTAINER_ROOT
8. [install]→ run inside Ubuntu chroot with /mnt = $CONTAINER_ROOT
```

On success, `.install_ok` is written. On failure, `.install_fail` is written. The user then clicks "Finish installation" which calls `_process_install_finish "$cid"`.

**The installation subvolume** is created as a BTRFS snapshot of `$UBUNTU_DIR` — so it inherits the Ubuntu base files at zero extra disk cost (copy-on-write). Deps installed into `$UBUNTU_DIR` are therefore available inside every container without reinstalling.

**Script execution context** for `[build]`, `[install]`, `[update]`:
- Ubuntu chroot at `$UBUNTU_DIR`
- Container subvolume bind-mounted at `$UBUNTU_DIR/mnt`
- Inside the script: `cd /mnt` is the first command (i.e. `$CONTAINER_ROOT`)
- `set -e` is active

---

## Start pipeline

Entry point: `_start_container "$cid"`

1. Compiles `service.src` → `service.json` (picks up any blueprint edits).
2. Links storage profile symlinks into the installation subvolume.
3. Calls `_build_start_script "$cid"` which generates `$CONTAINER_ROOT/start.sh`.
4. Launches `start.sh` in tmux session `sd_<cid>`.
5. Calls `_cron_start_all "$cid"` to launch cron sessions.

**`start.sh` structure:**

```bash
# env exports (from _env_exports)
export CONTAINER_ROOT=/path/to/installation
export PORT=8080
export SECRET_KEY=$(openssl rand -hex 32)  # or read from file if generate:hex32
# ... all [env] vars

# NVIDIA lib copy (if gpu = cuda_auto)

# sudo nsenter --net=/run/netns/<nsname> -- unshare --mount --pid --uts --ipc --fork bash -s << '_SDNS_WRAP'
#   (namespace wrapper inline heredoc)
#   mount -t proc proc $UBUNTU_DIR/proc
#   mount --bind /sys  $UBUNTU_DIR/sys
#   mount --bind /dev  $UBUNTU_DIR/dev
#   mount --bind $install_path $UBUNTU_DIR/mnt
#   _chroot_bash $UBUNTU_DIR -c "cd /mnt && $env_str && $start_cmd"
# _SDNS_WRAP
```

The `start.sh` is inlined as a heredoc fed to `bash -s` to avoid executing a file from inside a potentially MNT_LOCKED namespace.

**PATH inside containers:**
```
$CONTAINER_ROOT/venv/bin
$CONTAINER_ROOT/python/bin
$CONTAINER_ROOT/.local/bin
$CONTAINER_ROOT/bin
(system PATH)
```

**Auto-set HOME and XDG dirs:** `HOME`, `XDG_CACHE_HOME`, `XDG_CONFIG_HOME`, etc. are all set to subdirectories of `$CONTAINER_ROOT` so container processes don't pollute the host home.

---

## Cron engine

Entry point: `_cron_start_all "$cid"` (called from `_start_container`)

Each cron job defined in `service.json .crons[]` gets its own tmux session named `sdCron_<cid>_<idx>`.

**Session lifecycle:**
- Created by `_cron_start_one`: generates a temp bash script that loops indefinitely with `sleep $interval`.
- Stopped by `_cron_stop_all`: deletes the `cron_<idx>_next` timestamp file (the loop checks for this file each iteration and exits if missing), then kills the session.
- The timestamp file at `$CONTAINERS_DIR/<cid>/cron_<idx>_next` stores the Unix timestamp of the next scheduled run.

**Execution context:**
- Default (jailed): runs inside `nsenter + unshare + chroot` identical to the container's start environment. `$CONTAINER_ROOT` inside the chroot is `/mnt`.
- `--unjailed`: runs directly on the host. `CONTAINER_ROOT` is exported as the real installation path.
- `--sudo`: command is wrapped in `sudo -n bash -c '...'`.

**`>>` redirection rewriting:** inside cron commands, `>> logfile` is converted to `| tee -a logfile` so output appears both in the tmux session and in the file.

---

## UI system

All menus are built with `fzf`. The pattern is:

```bash
_menu "Header text" "${items[@]}"
# sets REPLY to the stripped/cleaned selected line
# returns 0 on selection, 1 on ESC/back, 2 on SIGUSR1 (refresh)
```

`_fzf` is a thin wrapper around `fzf` that writes the pid to `$TMP_DIR/.sd_active_fzf_pid` so SIGUSR1 can kill it to force a menu refresh.

**SIGUSR1 refresh mechanism:**
Background processes (install watcher, etc.) send `kill -USR1 $SD_SHELL_PID` to force a UI refresh. The trap handler kills the active fzf pid, `_SD_USR1_FIRED` is set to 1, and the menu loop sees return code 138/143 and continues (re-rendering).

**`FZF_BASE` array:** shared base fzf options applied to all menus. Modifying this changes the look of the entire UI.

**ANSI helpers:**
- `_strip_ansi` — strips color codes from a string (used to clean fzf output for case matching)
- `_trim_s` — strips + strips ANSI
- `DIM`, `BLD`, `CYN`, `GRN`, `RED`, `NC` — standard ANSI codes used inline in menu strings

---

## Networking

**Network namespace:** each container runs inside a dedicated network namespace created with `ip netns add sd_<hash>`. The namespace is created when the image is mounted and torn down on unmount. Containers get a virtual ethernet pair (`veth`) bridged through the host.

**Container IPs:** assigned sequentially from `10.88.x.2+`. The mapping is stored in `$MNT_DIR/.sd/netns_hosts` which is bind-mounted over `/etc/hosts` inside each container namespace — so containers can reach each other by name.

**Port exposure levels** (stored in `$CONTAINERS_DIR/<cid>/exposure`):

| Level | Effect |
|-------|--------|
| `isolated` | Container port not accessible from host or LAN (default) |
| `localhost` | Port forwarded to `127.0.0.1` on host via Caddy stanza |
| `public` | Routed through Caddy reverse proxy, accessible on LAN via mDNS |

**Caddy:** optional reverse proxy running inside `$UBUNTU_DIR`. Manages per-container routes. Config at `$MNT_DIR/.sd/Caddyfile`. Started/stopped via `_proxy_start` / `_proxy_stop`.

**mDNS:** Avahi advertises `<containername>.local` for public containers. Managed by `_avahi_start` / `_avahi_stop`.

---

## Storage system

**Storage profiles** live at `$STORAGE_DIR/<sid>/`. Each profile is a directory of actual data. Containers reference a profile via `storage_id` in `state.json`.

**Linking** (`_stor_link "$cid" "$install_path"`): creates symlinks from `$install_path/<storagepath>` → `$STORAGE_DIR/<sid>/<storagepath>` for each path in the `[storage]` section.

**Unlinking** (`_stor_unlink "$cid" "$install_path"`): removes those symlinks.

**Auto-pick** (`_auto_pick_storage_profile "$cid"`): if a profile with matching `storage_type` exists and is unattached, uses it automatically on start. Otherwise prompts.

**`storage_type`** in `[meta]` is the matching key. Multiple containers can share one profile if they have the same `storage_type` — useful for multi-instance setups.

**`generate:hex32` stability:** secrets generated at start time are written to `$STORAGE_DIR/<sid>/.sd_secret_<VARNAME>`. On subsequent starts the file is read instead of regenerating, giving a stable secret across restarts. If no storage profile is linked, the secret file goes to `$CONTAINERS_DIR/<cid>/.sd_secret_<VARNAME>`.

---

## Backup system

BTRFS snapshots of `$INSTALLATIONS_DIR/<cid>` stored in `$BACKUP_DIR/<cid>/`.

**Create:** `btrfs subvolume snapshot` — instant regardless of data size (CoW). Named snapshots include a `.meta` sidecar with timestamp and description.

**Restore:** `_do_restore_snap "$cid" "$snap_path"` — deletes current subvolume, creates a new snapshot from the backup snapshot.

**Clone:** `_clone_from_snap "$cid" "$snap_path"` — creates a new independent container from a snapshot. Changes to the clone don't affect the original.

**Rotation:** `_rotate_and_snapshot` enforces a max backup count per container.

---

## Update system

Entry point: `_build_update_items "$cid"` — scans for available updates and populates `_UPD_ITEMS[]`. Displayed in the stopped container menu; highlighted yellow if any updates are pending.

**Three update types checked:**

1. **Blueprint updates** (`_do_blueprint_update`): compares `version` in `service.json` against the latest GitHub tag for each `[git]` repo. If the tag changed, marks as available.
2. **Ubuntu base updates** (`_do_ubuntu_update`): checks if any `DEFAULT_UBUNTU_PKGS` are missing or outdated in `$UBUNTU_DIR`.
3. **Package updates** (`_do_pkg_update`): checks pip/npm packages for newer versions.

Triggering update calls `_run_job "update" "$cid"` which re-runs `[git]` (if tag changed) and then `[update]`.

---

## Other menu subsystems

**Ubuntu base (`_ubuntu_menu`):** manages `$UBUNTU_DIR` — install, update packages, add/remove default packages. All apt ops use `_chroot_bash "$UBUNTU_DIR" ...`.

**Resource limits (`_resources_menu`):** reads/writes `$CONTAINERS_DIR/<cid>/resources.json`. Applied at container start via `systemd-run --user --scope` wrapping the start script.

**LUKS2 encryption (`_luks_menu`):** encrypts/decrypts the `.img` file in place. Uses `cryptsetup luksFormat` / `luksOpen`. Managed keyslots. The mapper device is used as the loop device when the image is encrypted.

**Active processes (`_active_processes_menu`):** lists all tmux sessions matching `sd_*`, `sdInst_*`, `sdCron_*` patterns. Select to attach or kill.

**Logs browser (`_logs_browser`):** fzf picker over log files in `$LOGS_DIR`. Select to tail.

**Image resize (`_resize_image`):** unmounts image, `truncate` to new size, remounts, `btrfs filesystem resize max`.

---

## Key helpers quick-reference

| Function | What it does |
|----------|-------------|
| `_cname "$cid"` | Container name from state.json |
| `_cpath "$cid"` | Installation subvolume path |
| `_st "$cid" key` | Read a key from state.json |
| `_state_set "$cid" key val` | Write a key to state.json |
| `tsess "$cid"` | tmux session name for container |
| `_inst_sess "$cid"` | tmux session name for install |
| `_cron_sess "$cid" "$idx"` | tmux session name for cron job |
| `tmux_up "session"` | Returns 0 if session exists and is alive |
| `_is_installing "$cid"` | Returns 0 if install session running |
| `_start_container "$cid"` | Start a container (link storage, generate start.sh, launch tmux) |
| `_stop_container "$cid"` | Stop a container (kill tmux session, stop crons, unlink storage) |
| `_run_job mode "$cid"` | Generate and launch install/update script |
| `_compile_service "$cid"` | Recompile service.src → service.json |
| `_build_start_script "$cid"` | Generate $CONTAINER_ROOT/start.sh |
| `_env_exports "$cid" path` | Emit bash `export` lines for [env] section |
| `_cr_prefix "$value"` | Auto-prefix relative paths with $CONTAINER_ROOT |
| `_emit_runner_steps mode cid path` | Emit [git]+[build]+[install/update] script fragment |
| `_mount_img "$path"` | Mount a .img file, set all dir globals |
| `_unmount_img` | Unmount and clean up |
| `_chroot_bash "$root" args` | Run bash inside a chroot (resolves /bin vs /usr/bin/bash) |
| `_set_img_dirs` | Set BLUEPRINTS_DIR, CONTAINERS_DIR, etc. from MNT_DIR |
| `_yazi_pick [ext]` | Open yazi file picker, return selected path |
| `_strip_ansi` | Pipe filter: remove ANSI color codes |
| `_menu "header" items...` | Show fzf menu, set REPLY, return 0/1/2 |
| `pause "msg"` | Show a message, wait for Enter/ESC |
| `confirm "msg"` | Yes/No prompt, returns 0 for yes |
| `finput "prompt"` | Text input prompt, result in $FINPUT_RESULT |
| `_load_containers` | Populate CT_IDS[] array of all container IDs |
| `_log_path "$cid" mode` | Path to log file for install/start/update |
| `_update_size_cache "$cid"` | Write disk usage to .cache/sd_size/<cid> |
| `_stor_link "$cid" path` | Link storage profile into container |
| `_stor_unlink "$cid" path` | Unlink storage profile |
| `_auto_pick_storage_profile "$cid"` | Find matching unattached profile or prompt |
| `_bp_compile_to_json file cid` | Parse DSL file → service.json |
| `_proxy_running` | Returns 0 if Caddy is running |
| `_exposure_get "$cid"` | Returns exposure level: isolated/localhost/public |

---

## Naming conventions

| Prefix/Pattern | Meaning |
|----------------|---------|
| `_func` | Internal helper (not meant to be called from menus directly) |
| `_menu` | Opens an fzf menu |
| `_*_menu` | Top-level menu function for a subsystem |
| `_*_submenu` | Sub-level menu (called from a parent menu) |
| `_emit_*` | Writes generated bash code to stdout (used in script generation) |
| `_build_*` | Constructs something (a script, a JSON, etc.) |
| `_run_job` | Launches a background install/update tmux session |
| `_guard_*` | Pre-condition check; returns 1 and shows a message if the condition fails |
| `sdInst_<cid>` | tmux session: installation |
| `sd_<cid>` | tmux session: running container |
| `sdCron_<cid>_<idx>` | tmux session: cron job |
| `sdTerm_<cid>` | tmux session: user terminal inside container dir |
| `sdLuksEnc` / `sdLuksDec` | tmux sessions: LUKS operations |
| `<cid>` | Short hex container ID — directory and session key |
| `<sid>` | Storage profile ID |
| `<gid>` | Group ID |
| `sj` | Local var name for path to `service.json` |
| `ip` / `install_path` | Local var name for `$INSTALLATIONS_DIR/<cid>` |

---

## Patterns and idioms

**All fzf menus use REPLY for result:**
```bash
_menu "Header" "Option A" "Option B"
case "$REPLY" in
    "Option A") ... ;;
    "Option B") ... ;;
esac
```

**ANSI stripping before case matching:**
Menu items are built with ANSI color codes for display, but `REPLY` is cleaned by `_strip_ansi` + `sed` trim before case matching. Always match against the plain text string, not the colored one.

**tmux session checks:**
```bash
tmux_up "sd_$cid"    # preferred — handles error codes
tmux has-session -t "sd_$cid" 2>/dev/null  # raw tmux call
```

**Script generation pattern:**
Large generated bash scripts are built with `printf` into temp files (`mktemp "$TMP_DIR/.sd_*_XXXXXX.sh"`). These files are `chmod +x` then launched via tmux. On tmux session exit, the hook script cleans them up.

**`set -e` in generated scripts:**
All install/update/build scripts have `set -e` active. A failing command aborts and writes `.install_fail`.

**`jq` is the only JSON interface:**
No bash JSON parsing — all reads and writes go through `jq`. `jq -r` for string output. `jq -n` for building new JSON. `jq --arg k v` for safe string injection.

**Parallel arrays for ordered data:**
Where ordered arrays with multiple properties are needed (cron jobs, actions), parallel bash arrays are used: `BP_CRON_NAMES[]`, `BP_CRON_INTERVALS[]`, `BP_CRON_CMDS[]`, `BP_CRON_FLAGS[]` all indexed the same way.

**SIGUSR1 refresh loop:**
Any background process that wants to refresh the UI calls `kill -USR1 $SD_SHELL_PID`. The trap kills the active fzf, sets `_SD_USR1_FIRED=1`, and the menu loop `continue`s (re-renders). Check `_sig_rc $?` after a `wait` to detect this case.

---

## What not to change without reading first

**`declare -A L` syntax:** no spaces between `[key]=` and `"value"`. Bash does not allow this in associative array declarations. `bash -n` will not catch this — it only fails at runtime.

**`SD_PERSISTENT_END` heredoc:** the built-in blueprints are inside a `: << 'SD_PERSISTENT_END' ... SD_PERSISTENT_END` null command. The closing delimiter must be on a line by itself with no leading whitespace. `_list_persistent_names` and `_get_persistent_bp` parse this block using `awk` — the `# [Name]` comment format before each blueprint is mandatory.

**`start.sh` is generated, not static:** never edit `$CONTAINER_ROOT/start.sh` manually — it is regenerated on every start from the blueprint + env. Changes are lost.

**`service.json` is compiled, not authoritative:** the user edits `service.src`. `_compile_service` rewrites `service.json` from it. Direct edits to `service.json` are overwritten.

**Namespace wrapper is inlined, not a file:** `start.sh` uses a heredoc `<< '_SDNS_WRAP'` to pass the namespace wrapper code to `bash -s` instead of writing a file. This is intentional — files inside BTRFS loop mounts are MNT_LOCKED and cannot be executed from inside a user namespace.

**TMP_DIR is wiped on mount:** `$TMP_DIR` (inside the image) is `rm -rf` and recreated every time the image is mounted. Do not store anything important there.

**`generate:hex32` has two phases:** during install (in the install script), it generates inline using `openssl rand -hex 32` as a shell substitution. During start, it checks for a saved secret file in storage first and only generates if the file is missing. These are two separate code paths.

**CACHE_DIR is set after mount:** `CACHE_DIR=""` at script load time. It is only set to `$MNT_DIR/.cache` inside `_mount_img`. Any function that uses `$CACHE_DIR` must be called after image mount.