# services.sh — Authoritative Overview

**Purpose:** `services.sh` is a single-file Bash TUI ("simpleDocker") for managing
containerised services inside an encrypted BTRFS-on-LUKS `.img` file. It uses `fzf` for
all menus, `tmux` for background processes, and `sudo -n` for all privileged ops.

---

## 1. Boot Sequence

```
(outer shell, no TMUX)
  → _sd_outer_sudo()          # write NOPASSWD sudoers once, prompt password with retry
  → create/attach tmux "simpleDocker" session
  → re-attach loop: breaks only when SD_DETACH=1 env var is set by Ctrl-D

(inner process, inside TMUX session)
  → _check_deps ask/yes       # jq tmux yazi fzf btrfs sudo curl ip
  → btrfs kernel check
  → _require_sudo → _sudo_keepalive (background, refreshes ticket every 55s)
  → trap _force_quit INT TERM HUP
  → trap USR1 → _sd_usr1_handler  (kills active fzf pid for menu refresh)
  → tmux set-environment SD_READY 1
  → _sweep_stale
  → _setup_image              # prompt for/auto-select .img
  → main_menu
```

The key distinction: the **outer shell** manages sudo credentials and the tmux
session lifecycle. The **inner** shell (re-executed via `bash "$_self"` inside tmux)
runs the actual TUI.

---

## 2. tmux Session Architecture

| Session name pattern  | Purpose |
|---|---|
| `simpleDocker`        | Main UI / root session |
| `sd_{8hex}`           | Running container (`cid` = 8 hex chars) |
| `sdInst_{cid}`        | Installation job for container `cid` |
| `sdCron_{cid}_{idx}`  | Cron job `idx` for container `cid` |
| `sdResize`            | Image resize operation |
| `sdTerm_{cid}`        | Interactive terminal for container |
| `sdAction_{cid}_{idx}`| Action runner |
| `sdUbuntuSetup`       | Ubuntu base download/install |
| `sdUbuntuPkg`         | Ubuntu apt operations |
| `sdCaddyMdnsInst_{pid}`| Caddy+mDNS installation |

**Key tmux env vars (global):**
- `SD_READY=1` — set by inner process once init is done
- `SD_DETACH=1` — set when user presses Ctrl-D (outer shell detects and breaks re-attach loop)
- `SD_QUIT=1` — set by fzf Ctrl-Q binding, triggers quit menu
- `SD_INSTALLING=<cid>` — tracks current installation cid

**SIGUSR1 flow:** main shell PID stored as `SD_SHELL_PID`. Any code can send `SIGUSR1` to
`SD_SHELL_PID` to force-refresh the active fzf menu (e.g. cron watcher when container
stops). `_SD_USR1_FIRED` flag is checked in all fzf loops.

**Keybindings:**
- `ctrl-d` — detach from tmux (sets SD_DETACH)
- `ctrl-q` — quit (sets SD_QUIT)
- `ctrl-\` — detach *inside* tmux (standard tmux)

---

## 3. Menu Tree

```
main_menu
├── Containers  → _containers_submenu
│   ├── [container]  → _container_submenu(cid)
│   │   ├── ▶  Start        → _start_ct
│   │   ├── ■  Stop         → _stop_ct
│   │   ├── ↺  Restart
│   │   ├── →  Attach       → tmux switch-client
│   │   ├── ↓  Install      → _install_method_menu / run in sdInst_
│   │   ├── →  Attach to installation
│   │   ├── ×  Kill installation
│   │   ├── ✓  Finish installation
│   │   ├── ◉  Terminal     → sdTerm_ tmux session
│   │   ├── ↑  Update
│   │   ├── ◦  Edit toml    → $EDITOR
│   │   ├── ≡  View log
│   │   ├── ×  Remove
│   │   ○  Uninstall
│   │   ✎  Rename
│   │   ◈  Backups
│   │   ◧  Profiles
│   │   ⊕  Open in (browser)
│   │   ⬤  Port exposure
│   └── +  New container → _install_method_menu
│
├── Groups → _groups_menu
│   └── [group] → start/stop all members
│
├── Blueprints → _blueprints_submenu
│   ├── [file bp] → _blueprint_submenu → edit/delete/rename
│   ├── [Persistent] → _view_persistent_bp (read-only)
│   ├── [Imported] → view only (from autodetect)
│   └── + New blueprint
│
├── ? Other → _help_menu
│   ├── Storage section
│   │   ├── Profiles & data → _persistent_storage_menu
│   │   ├── Backups         → _manage_backups_menu
│   │   └── Blueprints      → _blueprints_settings_menu
│   ├── Plugins section
│   │   ├── Ubuntu base     → _ubuntu_menu
│   │   ├── Caddy           → _proxy_menu
│   │   └── QRencode        → _qrencode_menu
│   ├── Tools section
│   │   ├── Active processes → _active_processes_menu
│   │   ├── Resource limits  → _resources_menu
│   │   └── Blueprint preset (read-only view)
│   └── Caution section
│       ├── View logs        → _logs_browser
│       ├── Clear cache
│       ├── Resize image     → _resize_image
│       ├── Manage Encryption → _enc_menu
│       └── × Delete image file
│
└── × Quit → _quit_menu
    ├── ⊙ Detach (keeps running, sets SD_DETACH=1)
    └── ■ Stop all & quit → _quit_all
```

---

## 4. Global State Variables

| Variable | Meaning |
|---|---|
| `IMG_PATH` | Path to the mounted `.img` file |
| `MNT_DIR` | Mount point (`$SD_MNT_BASE/mnt_*`) |
| `BLUEPRINTS_DIR` | `$MNT_DIR/Blueprints` |
| `CONTAINERS_DIR` | `$MNT_DIR/Containers` |
| `INSTALLATIONS_DIR` | `$MNT_DIR/Installations` |
| `BACKUP_DIR` | `$MNT_DIR/Backup` |
| `STORAGE_DIR` | `$MNT_DIR/Storage` |
| `UBUNTU_DIR` | `$MNT_DIR/Ubuntu` |
| `GROUPS_DIR` | `$MNT_DIR/Groups` |
| `LOGS_DIR` | `$MNT_DIR/Logs` |
| `CACHE_DIR` | `$MNT_DIR/.cache` |
| `TMP_DIR` | Pre-mount: `$SD_MNT_BASE/.tmp`, post-mount: `$MNT_DIR/.tmp` |
| `ROOT_DIR` | `~/.config/simpleDocker` (image list, config) |
| `CT_IDS[]` / `CT_NAMES[]` | Loaded container arrays |
| `SD_SHELL_PID` | Main shell PID for USR1 signals |
| `SD_ACTIVE_FZF_PID` | PID written to `.sd_active_fzf_pid` temp file |

---

## 5. LUKS / Encryption Architecture

### Slot Layout

```
Slot 0   — auth.key (64-byte random keyfile, stored at $MNT_DIR/.sd/auth.key)
Slot 1   — SD_DEFAULT_KEYWORD ("1991316125415311518") — "System Agnostic"
Slot 2–6 — reserved (not used)
Slot 7–31— user range:
             • Verified system keys (auto-unlock, keyed by SD_VERIFICATION_CIPHER)
             • Passkeys (user-defined passphrases)
```

`SD_LUKS_KEY_SLOT_MIN=7`, `SD_LUKS_KEY_SLOT_MAX=31`

### Key Material

| Name | Value | Purpose |
|---|---|---|
| `SD_VERIFICATION_CIPHER` | `sha256sum /etc/machine-id \| cut -c1-32` | Machine-specific auto-unlock key |
| `SD_DEFAULT_KEYWORD` | `"1991316125415311518"` | System-agnostic open (any machine) |
| `auth.key` | 64 bytes from `/dev/urandom` | Internal auth key used to add/remove other slots |

### Unlock Order (`SD_UNLOCK_ORDER`)

1. `verified_system` — try `SD_VERIFICATION_CIPHER` (auto-unlock)
2. `default_keyword` — try `SD_DEFAULT_KEYWORD` (system-agnostic)
3. `prompt` — ask user for passphrase (3 retries)

### Verified System Cache

Per-system unlock info stored in `$MNT_DIR/.sd/verified/{vid}`:
```
line 1: hostname
line 2: LUKS slot number (empty if auto-unlock disabled for this system)
line 3: SD_VERIFICATION_CIPHER (the machine's unlock passphrase)
```
`vid` = `sha256sum /etc/machine-id | cut -c1-8`

### Auth Key File Tracking

- `$MNT_DIR/.sd/auth.slot` — contains the slot number of `auth.key` (always `"0"`)
- `$MNT_DIR/.sd/keyslot_names.json` — maps `"<slot>": "name"` for user passkeys

### Image Creation (`_create_img`)

1. `truncate -s ${size}G` (sparse file)
2. `luksFormat --key-slot 31` with `SD_VERIFICATION_CIPHER` as bootstrap key
3. `luks open` with bootstrap key
4. `mkfs.btrfs`
5. `mount`
6. `_enc_authkey_create` → generates `auth.key`, adds to slot 0, kills bootstrap slot 31
7. Add `SD_DEFAULT_KEYWORD` to slot 1 (System Agnostic)
8. Add `SD_VERIFICATION_CIPHER` to free slot (Verified System / Auto-Unlock)
9. Create BTRFS subvolumes: Blueprints, Containers, Installations, Backup, Storage, Ubuntu, Groups, Logs

### `_enc_authkey_create(auth_kf)`

```bash
dd if=/dev/urandom bs=64 count=1 > auth.key
chmod 600 auth.key
cryptsetup luksAddKey --key-slot 0 --key-file $auth_kf $IMG auth.key
echo '0' > auth.slot
```
**Existing key** `$auth_kf` is used to *authorise* adding the new random key to slot 0.

### Disable/Enable System Agnostic

- **Enable:** Use `auth.key` to add `SD_DEFAULT_KEYWORD` to slot 1
- **Disable:** Use `auth.key` (or prompt) to `luksKillSlot 1`
- Safety: Cannot disable if no other unlock method exists

### Disable/Enable Auto-Unlock

- **Disable:** For each verified system with an active slot, `luksKillSlot` that slot (using `auth.key`). Cache files updated: slot field cleared but hostname and pass retained.
- **Enable:** For each verified system with a saved pass, find a free slot and `luksAddKey` using `auth.key`, then update cache file with new slot number.

### Reset Auth Token

1. User enters any existing passphrase (for authorisation)
2. If old `auth.key` exists and is valid, `luksKillSlot 0`
3. Delete old `auth.key`
4. Call `_enc_authkey_create(tmp_file_with_passphrase)` to create new auth.key at slot 0

### Add Passkey

1. User configures: name, PBKDF params (argon2id default; pbkdf2 option), cipher, key bits, hash, sector size
2. User enters passphrase + confirm
3. `cryptsetup luksAddKey --key-slot <free> --key-file auth.key $IMG` with passphrase piped to stdin
4. Name stored in `keyslot_names.json`

### Remove Passkey

- Auth: prefer `auth.key`; fallback to asking user for that key's passphrase
- Safety: Cannot remove if it would leave no unlock method

---

## 6. fzf / UI Primitives

All menus use `fzf` with `FZF_BASE` args. Key pattern:

```bash
fzf "${FZF_BASE[@]}" --header="..." > $tmpfile &
pid=$!
echo $pid > $TMP_DIR/.sd_active_fzf_pid
wait $pid; rc=$?
sel=$(cat $tmpfile | _trim_s)
rm -f $tmpfile
_sig_rc $rc && { stty sane; continue; }   # USR1/signal → refresh loop
[[ $rc -ne 0 || -z "$sel" ]] && return    # ESC → back
```

`_sig_rc` returns true for exit codes 143/138/137 (killed by signal). These indicate the
fzf was interrupted by SIGUSR1 (auto-refresh) — the loop should `continue`, not `return`.

Key helpers:
- `pause(msg)` — show message, wait for Enter/ESC
- `confirm(msg)` — Yes/No fzf prompt
- `finput(prompt)` — fzf `--print-query` free-text input
- `_menu(header, items...)` — generic menu with auto-Back button
- `_strip_ansi` / `_trim_s` — clean fzf output for matching

---

## 7. Container Lifecycle

### State Files

- `$CONTAINERS_DIR/{cid}/state.json` — `{name, installed, install_path, ...}`
- `$CONTAINERS_DIR/{cid}/service.json` — parsed blueprint (meta, env, start script, crons, actions, etc.)
- `$CONTAINERS_DIR/{cid}/.install_ok` / `.install_fail` — sentinel files
- `$CONTAINERS_DIR/{cid}/exposure` — `isolated|localhost|public`

### Session name: `sd_{cid}`, Install session: `sdInst_{cid}`

### Start flow:
1. `netns_ct_add` — add veth pair to container network namespace
2. `exposure_apply` — apply iptables rules
3. `tmux new-session -d -s sd_{cid}` running the container start script inside `nsenter`/`chroot`
4. Start cron jobs in `sdCron_{cid}_{idx}` sessions

### Stop flow:
1. Send `C-c` to session
2. `tmux kill-session`
3. `netns_ct_del` — remove veth, flush iptables
4. Kill cron sessions

---

## 8. Network Namespace

Per-image (not per-container) veth bridge setup:
- NS name: `sd_{md5(MNT_DIR)[:8]}`
- Bridge index `idx`: `0x{md5(MNT_DIR)[:2]} % 254`
- Subnet: `10.88.{idx}.0/24`
- Host IP: `10.88.{idx}.254`
- Container IPs: `10.88.{idx}.{2-253}` (deterministic from `cid`)

Port exposure modes:
- `isolated` — iptables DROP
- `localhost` — iptables ACCEPT (FORWARD only, localhost accessible)
- `public` — DNAT + MASQUERADE (LAN accessible)

---

## 9. Blueprint Format (`.toml` / `.container`)

Sections: `[container]`, `[meta]`, `[env]`, `[storage]`, `[deps]`, `[dirs]`, `[pip]`,
`[npm]`, `[git]`, `[build]`, `[install]`, `[update]`, `[start]`, `[cron]`, `[actions]`,
`[/container]`

Code sections (`install`, `update`, `start`, `build`) are raw bash. All others are
key=value or comma-separated lists.

Parsed into `service.json` by `bp_compile`. CONTAINER_ROOT env var always set to install path.

---

## 10. Ubuntu Base

- Stored in `$MNT_DIR/Ubuntu` (chroot-able Ubuntu 24.04 LTS Noble)
- Download runs in `sdUbuntuSetup` tmux session
- Used as chroot for container apt deps
- `_chroot_bash($dir, ...)` = `sudo chroot $dir /bin/bash ...`
- Package drift detection: compares `DEFAULT_UBUNTU_PKGS` to `.ubuntu_default_pkgs`

---

## 11. Persistent Blueprints

Stored inside the script file itself, between `SD_PERSISTENT_END` heredoc markers.
Parsed with `awk`. Read-only from the UI. Prefixed with `# ` in the file.

---

## 12. Sweep / Cleanup (`_sweep_stale`)

On startup, kills all `sd_*`/`sdInst_*`/`sdCron_*`/`sdResize` tmux sessions, unmounts
everything under `SD_MNT_BASE`, closes all `/dev/mapper/sd_*` LUKS mappers, detaches
loop devices that backed simpleDocker images, then recreates clean tmp dir.

---

## 13. Image Resize (`_resize_image`)

Runs in `sdResize` tmux session as a shell script. The shell script:
1. Stops all running containers
2. Unmounts image, closes LUKS, detaches loop device
3. Extends/shrinks image file with `truncate`
4. Re-attaches loop device, reopens LUKS (tries `SD_VERIFICATION_CIPHER` first, then prompts)
5. `cryptsetup resize`
6. Remounts; `btrfs filesystem resize max`
7. Success/fail sentinel files written back to the calling shell

**Critical detail:** LUKS re-open in the resize script uses `SD_VERIFICATION_CIPHER`
(the auto_pass variable) first, then the user's passphrase if needed. This is done inside
a bash heredoc embedded in the calling shell, not a Python subprocess.