# simpleDocker — services.sh Authoritative Overview

> Source of truth: `services.sh` (~7600 lines, single-file Bash TUI)  
> Last updated: 2026-03-14

---

## What it is

`services.sh` is a single-file Bash TUI called **simpleDocker**. It manages containerised services stored inside a LUKS-encrypted BTRFS `.img` sparse file. All menus use `fzf`, background jobs run in `tmux` sessions, and all privileged operations go through `sudo -n` (passwordless, configured at startup via a NOPASSWD sudoers rule). The same script file serves as both the outer launcher and the inner TUI.

---

## Boot Sequence

### Outer process (no `$TMUX`)

1. `_sd_outer_sudo` — writes NOPASSWD sudoers rule for current user covering mount, umount, btrfs, cryptsetup, losetup, iptables, nsenter, chroot, ip, and more. Prompts for password with retry loop.
2. Checks if `simpleDocker` tmux session exists and has `SD_READY=1`. If stale, kills it.
3. Creates tmux session running `bash <self>` with `status off`.
4. Re-attach loop: attaches, drains stdin on each detach, breaks only when `SD_DETACH=1` is set.

### Inner process (inside `$TMUX`)

1. Check BTRFS kernel module available, exit if missing.
2. `_require_sudo` → `_sudo_keepalive` background subshell, refreshes ticket every 55s.
3. `trap '_force_quit' INT TERM HUP`.
4. `SIGUSR1` trap → `_sd_usr1_handler` — kills active fzf PID, sets `_SD_USR1_FIRED=1` for menu refresh.
5. Sets `SD_READY=1` in tmux environment.
6. `_sweep_stale` — kills stale `sd_*`/`sdInst_*`/`sdCron_*`/`sdResize` sessions, unmounts everything under `SD_MNT_BASE`, closes all `/dev/mapper/sd_*` LUKS mappers, detaches loop devices, `rm -rf $SD_MNT_BASE`, recreates clean dirs.
7. `_setup_image` — select or create `.img` file.
8. `main_menu` — enters the main fzf loop.

---

## Directory Layout

| Variable | Path |
|---|---|
| `MNT_DIR` | `$SD_MNT_BASE/mnt_{imgname}` |
| `BLUEPRINTS_DIR` | `$MNT_DIR/Blueprints` |
| `CONTAINERS_DIR` | `$MNT_DIR/Containers` |
| `INSTALLATIONS_DIR` | `$MNT_DIR/Installations` |
| `BACKUP_DIR` | `$MNT_DIR/Backup` |
| `STORAGE_DIR` | `$MNT_DIR/Storage` |
| `UBUNTU_DIR` | `$MNT_DIR/Ubuntu` |
| `GROUPS_DIR` | `$MNT_DIR/Groups` |
| `LOGS_DIR` | `$MNT_DIR/Logs` |
| `CACHE_DIR` | `$MNT_DIR/.cache` |
| `TMP_DIR` | pre-mount: `$SD_MNT_BASE/.tmp` / post-mount: `$MNT_DIR/.tmp` |
| `ROOT_DIR` | `~/.config/simpleDocker` |

All subdirs are BTRFS subvolumes. The `.sd/` directory inside the image holds private state (auth.key, proxy.json, verified/, etc).

---

## tmux Session Naming

| Pattern | Purpose |
|---|---|
| `simpleDocker` | Main UI |
| `sd_{8hex}` | Running container |
| `sdInst_{cid}` | Installation job |
| `sdCron_{cid}_{idx}` | Cron job |
| `sdResize` | Image resize |
| `sdTerm_{cid}` | Interactive terminal |
| `sdAction_{cid}_{idx}` | Action runner |
| `sdUbuntuSetup` | Ubuntu base download |
| `sdUbuntuPkg` | Ubuntu apt ops |
| `sdCaddyMdnsInst_{pid}` | Caddy+mDNS install |
| `sdStorExport` / `sdStorImport` | Storage export/import |

**Key tmux env vars:** `SD_READY=1`, `SD_DETACH=1`, `SD_QUIT=1`, `SD_INSTALLING=<cid>`, `SD_SHELL_PID`.

---

## Menu Tree

```
main_menu
├── Containers  → _containers_submenu
│   └── [cid]   → _container_submenu
│       ├── ▶ Start / ■ Stop / ↺ Restart / → Attach
│       ├── ↓ Install / → Attach inst / × Kill inst / ✓ Finish
│       ├── ◉ Terminal / ≡ View log / ⊕ Open in
│       ├── ↑ Update (blueprint / ubuntu / packages)
│       ├── ◦ Edit toml / ✎ Rename / × Remove / ○ Uninstall
│       ├── ◈ Backups / ◧ Profiles / ⬤ Port exposure
│       └── [actions] / [cron entries]
├── Groups  → _groups_menu
│   └── [group] → _group_submenu (Start/Stop/Edit/Delete, Sequence editor)
├── Blueprints  → _blueprints_submenu
│   ├── [file] → _blueprint_submenu (Edit/Rename/Delete)
│   ├── [Persistent] → _view_persistent_bp (read-only)
│   └── [Imported] → fzf viewer
└── Other  → _help_menu
    ├── Profiles & data  → _persistent_storage_menu
    ├── Backups          → _manage_backups_menu
    ├── Blueprints       → _blueprints_settings_menu
    ├── Ubuntu base      → _ubuntu_menu
    ├── Caddy            → _proxy_menu
    ├── QRencode         → _qrencode_menu
    ├── Active processes → _active_processes_menu
    ├── Resource limits  → _resources_menu
    ├── Blueprint preset (read-only)
    ├── View logs        → _logs_browser
    ├── Clear cache
    ├── Resize image     → _resize_image
    ├── Manage Encryption → _enc_menu
    └── × Delete image file
```

Quit menu: `Detach` (sets `SD_DETACH=1`) or `Stop all & quit` (`_quit_all`). ESC from main menu → `_quit_all` directly.

---

## fzf / UI Primitives

`FZF_BASE`: `--ansi --no-sort --header-first --prompt="  ❯ " --pointer=▶ --height=80% --min-height=18 --reverse --border=rounded --margin=1,2 --no-info --bind=esc:abort` + ctrl-d binding that sets `SD_DETACH=1`.

Every fzf call: start as background process → write PID to `.sd_active_fzf_pid` → `wait $pid` → `_sig_rc $rc` (143/138/137 = signal-killed → `continue`) → `rc != 0 || -z sel` → `return`.

Helpers: `confirm`, `pause`, `finput` (`--print-query`), `_menu` (auto Back button), `_strip_ansi`, `_trim_s`, `_sig_rc`.

---

## LUKS / Encryption Architecture

### Slot Layout
```
Slot 0     auth.key — 64-byte random binary (internal authority key)
Slot 1     SD_DEFAULT_KEYWORD ("1991316125415311518") — system-agnostic
Slots 2–6  Reserved
Slots 7–31 User range: verified-system keys + user passkeys
```

### Key Constants
| Name | Value | Purpose |
|---|---|---|
| `SD_VERIFICATION_CIPHER` | `sha256sum /etc/machine-id \| cut -c1-32` | Machine-specific auto-unlock, 32 hex chars, derived at runtime |
| `SD_DEFAULT_KEYWORD` | `"1991316125415311518"` | Works on any machine |
| `auth.key` | 64 bytes urandom | Only used to add/remove slots, never to open image |

### Unlock Order
1. `verified_system` — `SD_VERIFICATION_CIPHER` via `--key-file=-`
2. `default_keyword` — `SD_DEFAULT_KEYWORD` via `--key-file=-`
3. `prompt` — interactive passphrase, 3 retries

### Image Creation
1. `truncate -s {N}G` sparse file
2. `luksFormat --key-slot 31` with `SD_VERIFICATION_CIPHER` (bootstrap)
3. Open, `mkfs.btrfs`, mount
4. `_enc_authkey_create`: `dd if=/dev/urandom bs=64 count=1 > auth.key` → `luksAddKey --key-slot 0 --key-file=$bootstrap_tmp $img auth.key` → write `"0"` to `auth.slot`
5. `luksKillSlot 31` (kill bootstrap)
6. Add `SD_DEFAULT_KEYWORD` → slot 1 (pbkdf2/sha1/iter=1000)
7. Add `SD_VERIFICATION_CIPHER` → free slot (same PBKDF)
8. `_enc_vs_write($vid, $slot)` — cache this machine
9. Create BTRFS subvolumes

### Verified System Cache
File at `$MNT_DIR/.sd/verified/{vid}` (`vid = sha256sum /etc/machine-id | cut -c1-8`):
```
line 1: hostname
line 2: LUKS slot number (empty when Auto-Unlock disabled)
line 3: SD_VERIFICATION_CIPHER for this machine
```

### PBKDF
- `auth.key`, default keyword, verified-system: `pbkdf2 --pbkdf-force-iterations 1000 --hash sha1` (fast — strength from entropy)
- User passkeys: `argon2id` default, fully configurable (RAM, threads, iter-ms, cipher, key-bits, hash, sector)

### Enc Menu Operations
- **System Agnostic disable:** auth with `auth.key` (or `SD_DEFAULT_KEYWORD` if missing) → `luksKillSlot 1`
- **System Agnostic enable:** auth with `auth.key` → `luksAddKey --key-slot 1` with `SD_DEFAULT_KEYWORD`
- **Auto-Unlock disable:** `luksKillSlot` all verified-system slots; preserve cache with empty slot field
- **Auto-Unlock enable:** for each cached machine, find free slot, `luksAddKey --key-file=auth.key` with cached pass
- **Reset Auth Token:** user passphrase → `luksKillSlot 0` → new `auth.key` at slot 0
- **Add Passkey:** configurable params, masked double-entry, `luksAddKey --key-slot $free --key-file=auth.key`
- **Remove Passkey:** safety guards, auth via `auth.key` or key's passphrase, `luksKillSlot`

---

## Container Lifecycle

### State Files (`$CONTAINERS_DIR/{cid}/`)
- `state.json` — name, install_path, installed, hidden, storage_id, default_storage_id
- `service.json` — compiled blueprint JSON
- `service.src` — raw blueprint source (editable)
- `service.src.hash` — sha256, used to detect changes
- `.install_ok` / `.install_fail` — install sentinels
- `exposure` — `isolated | localhost | public`
- `resources.json` — cgroup limits
- `pkg_manifest.json` — recorded packages

### Start Flow (`_start_container`)
1. `_guard_space` (≥ 2 GiB free)
2. `_compile_service` (recompile if hash changed)
3. Storage: `_stor_unlink` → `_auto_pick_storage_profile` → `_stor_link`
4. `_rotate_and_snapshot` (auto-backup, max 2)
5. `_build_start_script`
6. `_netns_ct_add` (veth pair into namespace)
7. Set default exposure from `HOST` env var on first start
8. `_exposure_apply` (iptables rules)
9. `tmux new-session` (optionally with `systemd-run` for cgroups)
10. Background watcher → sends SIGUSR1 on container exit
11. `_cron_start_all`
12. Background: `_cap_drop_apply` + `_seccomp_apply` after 2s

### Stop Flow (`_stop_container`)
1. `tmux send-keys C-c`, wait up to 8s, `kill-session`
2. Kill `sdTerm_{cid}`, `sdAction_{cid}_*`
3. `_netns_ct_del` → calls `_exposure_flush`
4. `_cron_stop_all`
5. Storage: `_stor_unlink`, `_stor_clear_active`
6. `_update_size_cache`

---

## Blueprint Format

Sections: `[container]` `[meta]` `[env]` `[storage]` `[deps]` `[dirs]` `[pip]` `[npm]` `[git]` `[build]` `[install]` `[update]` `[start]` `[cron]` `[actions]` `[/container]`

Code sections (`build`, `install`, `update`, `start`) — raw Bash. Others — `key = value` or comma-separated lists. Comments `#`.

Parsed by `_bp_parse` → validated by `_bp_validate` → compiled to `service.json` by `_bp_compile_to_json`. Hash tracked in `service.src.hash`.

**git syntax:** `org/repo [hint] [TYPE] [→ subdir/]` / `org/repo source`  
**cron syntax:** `interval [name] [--sudo] [--unjailed] | command`  
**actions syntax:** `Label | [prompt: "x" |] [select: cmd |] cmd [{input}|{selection}]`

---

## Network Namespace

One veth bridge per image (not per container).
- NS: `sd_{md5(MNT_DIR)[:8]}`
- Subnet: `10.88.{idx}.0/24` where `idx = 0x{md5[:2]} % 254`
- Host IP: `10.88.{idx}.254`; container IPs: `10.88.{idx}.{2–253}` (deterministic from cid md5)
- Interfaces: bridge `sd-br{idx}`, host veth `sd-h{idx}`, per-ct veths `sd-c{idx}-{cid[:6]}`
- `.netns_hosts` bind-mounted over container `/etc/hosts`

Exposure: `isolated` = DROP, `localhost` = FORWARD ACCEPT, `public` = DNAT + MASQUERADE.

---

## Install Script Generation (`_run_job`)

Generated temp bash script in `sdInst_{cid}`:
1. `exec > >(tee -a $logfile) 2>&1` + `_sd_icap` rotation trap (10 MB)
2. `_finish` trap → `.install_ok` / `.install_fail`; INT/TERM → `.install_fail` + exit 130
3. Env exports (`CONTAINER_ROOT`, `HOME`, `XDG_*`, `PATH`, GPU block, `[env]` vars)
4. Ubuntu base inline bootstrap (auto-downloads if missing)
5. BTRFS snapshot of Ubuntu base as container root
6. `[deps]` apt via chroot
7. `[dirs]` mkdir with `lib(a,b)` expansion
8. `[pip]` venv creation + pip install via chroot
9. `[npm]` Node.js 22 via NodeSource + npm install via chroot
10. `[git]` `_sd_best_url` (arch/GPU-aware) + `_sd_extract_auto` (tar/zip/binary)
11. `[build]` raw bash in chroot
12. `[install]` raw bash in chroot

---

## Start Script Generation (`_build_start_script`)

Generates `$install_path/start.sh`:
1. `exec > >(tee -a $logfile) 2>&1` + `_sd_scap` rotation trap (10 MB)
2. Env exports block
3. NVIDIA cuda_auto block (if `meta.gpu=cuda_auto`): detect driver version from `/sys/module/nvidia/version`, cache-invalidate on change, copy `libcuda.so*`/`libnvidia*.so*` into `usr/local/lib/sd_nvidia/`, inject `LD_LIBRARY_PATH`, pass `$_SD_EXTRA` to heredoc
4. `sudo nsenter --net=/run/netns/{ns} -- unshare --mount --pid --uts --ipc --fork bash -s`
5. Inside heredoc: set hostname, mount proc/sys/dev, bind-mount `MNT_DIR`, bind-mount `.netns_hosts` → `/etc/hosts`, `chroot $install_path /bin/bash -c "$env_vars && $cmd"`

---

## generate:hex32 (persistent secrets)

When env var is `generate:hex32`, `_build_start_script` generates a bash subshell in start.sh that: checks for persistent secret file at `$STORAGE_DIR/$scid/.sd_secret_{KEY}` (or `$CONTAINERS_DIR/$cid/.sd_secret_{KEY}`), reuses if found, otherwise `openssl rand -hex 32` and saves. Secrets survive restarts.

---

## Cron Jobs

Each cron runs in `sdCron_{cid}_{idx}` tmux. Generated runner loops: sleep interval → execute. Normal: `nsenter` + `unshare` + chroot into Ubuntu base with container bind-mounted to `/mnt`. `--unjailed`: runs on host with `CONTAINER_ROOT` exported. Next-execution timestamps in `$CONTAINERS_DIR/{cid}/cron_{idx}_next`. Countdown displayed in container submenu.

---

## Persistent Storage

Profiles in `$STORAGE_DIR/{scid}/` with `.sd_meta.json` (name, storage_type, active_container).

`_stor_link(cid, install_path, scid)`: for each `[storage]` path — copy existing dir data into `$STORAGE_DIR/$scid/$rel`, replace with symlink. Handles paths removed from `[storage]` by copying back.

`_stor_unlink`: removes symlinks, recreates empty dirs.

`_auto_pick_storage_profile`: default profile → last used → any free → create new silently.

---

## Backups (BTRFS Snapshots)

`$BACKUP_DIR/{cname}/{snap_id}/` + `.meta` sidecar (type=auto|manual, ts).

- Auto: `_rotate_and_snapshot` before every container start, max 2 kept
- Manual: user-created, unlimited
- Menu: two sections (Automatic / Manual), Remove all submenu, Create clone, Restore
- Clone: new container via `btrfs subvolume snapshot` (copy-on-write)

---

## Proxy / Caddy

Binary at `$MNT_DIR/.sd/caddy/caddy`. Config: `proxy.json` (routes: url→cid→https) + `Caddyfile`. Start: write Caddyfile → update `/etc/hosts` → start dnsmasq (LAN DNS) → start avahi (mDNS) → `setsid sudo caddy run` → `_proxy_trust_ca` (copy CA cert to system store). Add URL: https routes → `caddy trust &` in background.

---

## Resource Limits (cgroups)

`resources.json` with `enabled:true` → `systemd-run --user --scope --unit=sd-{cid} -p CPUQuota=X -p MemoryMax=X ...`. Post-start: `_seccomp_apply` (SystemCallFilter on systemd unit blocking kexec/mount/unshare/ptrace etc), `_cap_drop_apply` (capsh --drop on child pids).

---

## Ubuntu Base

Ubuntu 24.04 LTS Noble chroot at `$MNT_DIR/Ubuntu`. Downloaded from `cdimage.ubuntu.com/ubuntu-base/releases/noble/`. Pre-installs `DEFAULT_UBUNTU_PKGS`. Used as base for all container installs (BTRFS snapshot). Background cache check at every mount: detects `DEFAULT_UBUNTU_PKGS` drift and apt update availability (checked every 24h).

---

## Image Resize (`_resize_image`)

`sdResize` tmux session. Script: stop containers → unmount/close LUKS/detach loop → truncate (grow) or btrfs-resize-then-truncate (shrink) → re-open LUKS with `SD_VERIFICATION_CIPHER` first then passphrase prompt → remount → write sentinel. Sentinels use mktemp under `SD_MNT_BASE/.tmp`. On success: `exec bash <self>` to restart.

---

## Persistent Blueprints

Embedded in script between `SD_PERSISTENT_END` heredoc markers. Extracted with `awk`. Read-only in UI. Each blueprint prefixed with `# ` inside the heredoc.

---

## Sweep / Cleanup

`_sweep_stale`: kill all `sd_*`/`sdInst_*`/`sdCron_*`/`sdResize` sessions → unmount all under `SD_MNT_BASE` → close all `/dev/mapper/sd_*` LUKS mappers → detach loop devices → `rm -rf $SD_MNT_BASE` → recreate clean dirs.

`_force_quit` (INT/TERM/HUP): same + kill `simpleDocker` session.