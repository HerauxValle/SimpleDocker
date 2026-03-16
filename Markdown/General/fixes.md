# services.py — Fix & Divergence Status (Deep Review Round 2)

Source of truth: `services.sh`
Last updated: after applying all V1–V16, F1–F26, NV1–NV9, NF1–NF9.

---

## ✅ FULLY APPLIED

| Group | Status |
|-------|--------|
| V1–V16 (visual) | ✅ all applied |
| F1–F26 (functional) | ✅ all applied |
| NV1–NV9 (new visual from round 1) | ✅ all applied |
| NF1–NF9 (new functional from round 1) | ✅ all applied |

---

## 🔴 ROUND 2 — VISUAL DIVERGENCES

### R2V1 — `container_backups_menu`: no auto/manual split, no Remove all, no Clone (HIGH)
**Shell:** Two sections: `── Automatic backups ──` and `── Manual backups ──`.
Each backup entry shows `DIM ◈  {id}  ({ts})NC`.
Actions section has `GRN+NC  Create manual backup` and `REDXNC  Remove all backups`.
"Remove all backups" → submenu: "All automatic" / "All manual" / "All (automatic + manual)".
Backup submenu: `Restore` / `Create clone` / `Delete`.
Before creating a backup, shell does `confirm "Create manual backup of '{name}'?"`.
**Python:** Single flat `── Snapshots ──` section, no type split, no Remove all action,
no Create clone option. No confirm before creating backup.

### R2V2 — `proxy_menu` Add URL prompt text (LOW)
**Shell:** `finput "Enter URL  (e.g. comfyui.local, myapp.local)\n\n  Use .local for zero-config LAN access on all devices (mDNS).\n  Other TLDs (e.g. .sd) only work on this machine unless you configure DNS."`
**Python:** Shorter prompt, missing "Other TLDs" explanation.

### R2V3 — `proxy_menu` Add URL success pause (LOW)
**Shell:** `pause "✓ Added: {url} → {name} (port {port})\n\n  Visit: http(s)://{url}"`
**Python:** `pause(f"✓ Added: {nurl} → {sel_ct} (port {nport})")` — missing the "Visit:" line.

---

## 🟠 ROUND 2 — FUNCTIONAL DIVERGENCES

### R2F1 — `start_ct`: missing `_compile_service` call before start (HIGH)
**Shell `_start_container`:** Calls `_compile_service "$cid"` before anything else —
ensures `service.json` is up-to-date from `service.src` hash check.
**Python `start_ct`:** Does not call `compile_service(cid)` before starting.
The start script may use a stale `service.json`.

### R2F2 — `start_ct`: missing `rotate_and_snapshot` auto-backup before start (HIGH)
**Shell:** Calls `_rotate_and_snapshot "$cid"` immediately before starting — creates an
automatic snapshot (keeps max 2, rotates oldest). Ensures a rollback point exists.
**Python:** `rotate_and_snapshot` function exists but is **not called** from `start_ct`.

### R2F3 — `start_ct`: missing storage link/unlink on start (HIGH)
**Shell:** Before starting, calls `_stor_unlink` (clears previous symlinks) then
`_stor_link` (creates new symlinks from install_path into the selected storage profile dir,
copies data back and forth, sets active container on the profile).
Also calls `_auto_pick_storage_profile` to select the profile when not provided.
**Python:** `start_ct` receives a `profile_cid` arg but **does not call `_stor_link`
or `_stor_unlink`**. Storage symlinks are never set up on container start.

### R2F4 — `start_ct`: missing default exposure detection from HOST env var (MEDIUM)
**Shell:** On first start (no exposure file), checks `environment.HOST` in service.json:
`0.0.0.0` → sets exposure to `public`; `127.0.0.1`/`localhost` → sets to `localhost`.
**Python:** Never checks `HOST` env var; exposure file is not set on first start.

### R2F5 — `start_ct`: missing cgroups/systemd-run support (MEDIUM)
**Shell:** Reads `resources.json`; if `enabled=true`, wraps tmux launch with
`systemd-run --user --scope --unit=sd-{cid} -p CPUQuota=X -p MemoryMax=X ...`
**Python:** No `systemd-run` support. Always uses plain `tmux new-session`.

### R2F6 — `build_start_script`: missing log redirect and log rotation trap (HIGH)
**Shell `_build_start_script`:** Start script does:
```
exec > >(tee -a "$logfile") 2>&1
_sd_scap() { rotate if >10MB }; trap _sd_scap EXIT
```
Every container stdout/stderr is tee'd to `LOGS_DIR/{name}-{cid}-start.log`
with a 10 MB rotation trap.
**Python `build_start_script`:** No `exec > >(tee ...)` in the generated `start.sh`.
`start_ct` does `2>&1 | tee -a $logfile` in the tmux command, but this only captures
stdout from the outer `nsenter` wrapper, not from within the chroot.
Also missing the size-cap rotation trap.

### R2F7 — `build_start_script`: missing NVIDIA cuda_auto lib-copy block (MEDIUM)
**Shell:** For `meta.gpu = cuda_auto`, the start script includes a large block that:
1. Detects the host NVIDIA driver major version from `/sys/module/nvidia/version`
2. Clears stale cached `.so` files if driver version changed
3. Copies `libcuda.so*` and `libnvidia*.so*` from host into
   `$install_path/usr/local/lib/sd_nvidia/` inside the chroot
4. Sets `_SD_EXTRA=--cpu` if no NVIDIA module found
**Python:** Only exports `NVIDIA_GPU=1` and `CUDA_VISIBLE_DEVICES` env vars.
No `.so` file copying. GPU-dependent containers won't have CUDA libs.

### R2F8 — `_env_exports` / `generate:hex32`: secret not persisted (HIGH)
**Shell `_build_start_script`:** For `generate:hex32` values, checks for a persistent
secret file at `$STORAGE_DIR/$scid/.sd_secret_{KEY}` (or `$CONTAINERS_DIR/$cid/.sd_secret_{KEY}`
if no storage). If it exists, reuses the same value. If not, generates with
`openssl rand -hex 32` and **saves it to the file** for future restarts.
**Python `_env_exports`:** Always emits `$(openssl rand -hex 32 ...)` — a new random
secret is generated on every container start. Any value that was `generate:hex32` changes
on each restart (e.g. API keys, JWT secrets).

### R2F9 — `set_img_dirs`: does not trigger `ub_cache_check` on remount (MEDIUM)
**Shell `_set_img_dirs`:** Always ends with `_sd_ub_cache_check &` — spawns a background
subshell to check Ubuntu package updates. Runs on every mount and remount.
**Python `set_img_dirs`:** No `ub_cache_check` call. It is only called at startup
(`ub_thread` in `__main__`). After a resize+remount or re-exec, the cache is never refreshed.

### R2F10 — `sweep_stale`: does not `rm -rf SD_MNT_BASE` (LOW)
**Shell `_sweep_stale`:** After unmounting and closing LUKS, does `rm -rf "$SD_MNT_BASE"`
then `mkdir -p "$SD_MNT_BASE" "$TMP_DIR"` — full clean slate.
**Python `sweep_stale`:** Only recreates `sd_mnt_base` and `tmp_dir` dirs; does not
`shutil.rmtree(sd_mnt_base)` first. Stale files/dirs can persist.

### R2F11 — `container_backups_menu`: no "Create clone" from snapshot (MEDIUM)
**Shell:** Backup submenu has `Create clone` option → calls `_clone_from_snap` which
prompts for a clone name then creates a new container from the snapshot.
**Python `_snap_submenu`:** Has `Clone as new container` → calls `clone_from_snap`.
Actually equivalent — py has this. ✅ (previously thought missing; confirmed present)

### R2F12 — `_profile_submenu` rename: no duplicate-name check within same type (LOW)
**Shell:** Rename loop checks if another profile with the same name AND same
`storage_type` already exists across all storage dirs. Rejects with pause if duplicate.
**Python `_profile_submenu`:** Renames via `profile.rename(nd)` with no duplicate check
(only checks if the destination path exists on disk, not by stored name/type).

### R2F13 — `proxy_menu` Add URL: missing `caddy trust` CA call on https (LOW)
**Shell:** After adding an https route, if caddy is installed, calls
`CADDY_STORAGE_DIR=... caddy trust &` in the background to trust the internal CA.
**Python:** Does not call `caddy trust` after adding https route.

### R2F14 — `_stor_link` / `_stor_unlink` not implemented in py (HIGH — same as R2F3)
See R2F3. `_stor_link` creates symlinks from install path into storage profile dir
and copies data bidirectionally. `_stor_unlink` removes those symlinks before stop.
Neither is called in `start_ct` or `stop_ct` in py. Storage bind-mount architecture
is broken for persistent storage containers.

### R2F15 — `mount_img`: does not `rm -rf TMP_DIR` before recreating (LOW)
**Shell `_mount_img`:** Does `rm -rf "$TMP_DIR"` twice — before and after `_set_img_dirs` —
to ensure a clean tmp dir.
**Python:** Only calls `G.tmp_dir.mkdir(parents=True, exist_ok=True)`. Stale tmp files
can persist between mounts.

### R2F16 — `create_img`: calls `save_known_img` but shell does not (LOW)
**Shell `_create_img`:** Does not save the image path to any list file.
**Python `create_img`:** Calls `save_known_img(img)` after creation. Minor divergence —
py adds the new image to the known-images list, shell does not.
(This is arguably an improvement, not a bug.)

---

## PRIORITY ORDER FOR REMAINING FIXES

1. **R2F3/R2F14** — `_stor_link`/`_stor_unlink` in `start_ct`/`stop_ct` (HIGH — breaks persistent storage)
2. **R2F8** — `generate:hex32` persistent secret (HIGH — secret rotates on every restart)
3. **R2F6** — `build_start_script` log redirect + rotation trap (HIGH — logs broken)
4. **R2F1** — `start_ct` calls `compile_service` (HIGH)
5. **R2F2** — `start_ct` calls `rotate_and_snapshot` (HIGH)
6. **R2F7** — NVIDIA cuda_auto lib-copy block (MEDIUM)
7. **R2F5** — systemd-run cgroups support (MEDIUM)
8. **R2F4** — default exposure from HOST env var (MEDIUM)
9. **R2F9** — `set_img_dirs` triggers `ub_cache_check` (MEDIUM)
10. **R2V1** — `container_backups_menu` auto/manual split + Remove all (HIGH visual)
11. **R2F12**, **R2F13**, **R2F15**, **R2V2**, **R2V3** — low-impact divergences

---

## ✅ CONFIRMED EQUIVALENT (no change needed)

- quit_all, _force_quit: equivalent ✅
- sweep_stale session killing + LUKS/loop cleanup: equivalent ✅
- create_img full key hierarchy + btrfs subvolumes: equivalent ✅
- check_deps missing-tool display: equivalent ✅
- enc_menu all slot operations: equivalent ✅
- proxy_menu route add/edit/remove/toggle: equivalent ✅
- container_backups_menu "Create clone": equivalent ✅ (py has _snap_submenu with clone)
- groups_menu / group_submenu: equivalent ✅
- install_method_menu: equivalent ✅
- blueprints_submenu: equivalent ✅ (after NV fixes)
- active_processes_menu: equivalent ✅
- resources_menu: equivalent ✅
- logs_browser: equivalent ✅

# FIXES BEFORE THE ABOVE

# services.py — Fix & Divergence Status (Updated after deep review)

Source of truth: `services.sh`, `shoverview.md`
Last updated: after applying all V1–V16, F1–F26 from original pyissues.md/fixes.md.

---

## ✅ FULLY APPLIED — Original pyissues.md + fixes.md (V1–V16, F1–F26)

All previously documented issues have been applied and the file is syntax-clean at 4900+ lines.

| Area | Status |
|------|--------|
| main_menu display (V1–V4) | ✅ padded %-28s, conditional GRN/DIM colours |
| container_submenu order/visibility (V5–V7) | ✅ correct item order, exposure cycles directly |
| help_menu ubuntu_upd_tag (V9) | ✅ separate var, not appended to ubuntu_status |
| blueprints_submenu separator + no-editor (V10–V11) | ✅ inner separator, pause only on new |
| resize_image prompt in caller (V12) | ✅ finput in help_menu, size passed to resize_image() |
| resize min-size formula (V13) | ✅ int(used_bytes/GiB)+1+10 |
| resize confirm bullet list (V14) | ✅ • bullets, "X GB → Y GB" wording |
| mount point name-based (V15) | ✅ mnt_{img.stem} |
| autodetect default 'Home' (V16) | ✅ |
| bp_validate 7 missing checks (F1) | ✅ entrypoint, port number, storage_type, git format, dirs parens, actions {input}/{selection}, pip python3 |
| _env_exports full parity (F2–F5) | ✅ PATH python/bin+.local/bin, VIRTUAL_ENV, PYTHONPATH, dir creation, generate:hex32, LD_LIBRARY_PATH append, GPU block |
| bp_compile JSON shortcut + sha256 hash (F6) | ✅ |
| _ensure_src bootstrap from json (F7) | ✅ wired into _edit_container_bp |
| resize_image exec restart on success (F8) | ✅ os.execv after unmount |
| resize two-step mount (F9) | ✅ _do_mount/_do_umount helpers, temp dir → final remount |
| netns_setup writes .netns_name/.netns_idx (F10) | ✅ |
| enc auto-unlock disable passkey guard (F11) | ✅ |
| Add Key masked passphrase (F12) | ✅ getpass + clear |
| Reset Auth Token masked passphrase (F13) | ✅ getpass + clear |
| Add Key pbkdf2 uses cipher/keybits/sector (F14) | ✅ |
| enc verify messages (F15) | ✅ hostname, slot, cached-vs-active distinction |
| autodetect default 'Home' (F16) | ✅ |
| _list_imported_names prune hidden+vendor (F17) | ✅ also applied to _get_imported_bp_path |
| ct_log uses tail -100 in pause (F18) | ✅ |
| ct_exposure cycles directly, no submenu (F19) | ✅ |
| usr1_fired in all menu loops (F20) | ✅ audited — all loops correct |
| mount_img clears Logs/*.log (F21) | ✅ |
| _seed_persistent_blueprints always overwrites (F22/16) | ✅ |
| process_install_finish stale guard 600s (F23) | ✅ |
| _guard_ubuntu_pkg wired to all ubuntu op sites (F24) | ✅ incl. _do_ubuntu_update |
| main_menu ESC → quit_all directly (F25) | ✅ |

---

## ✅ NEW VISUAL — ALL APPLIED (NV1–NV9)

### ✅ NV1 — `_open_in_submenu`: QR code option missing (HIGH)
**Shell:** Shows `⊞  Show QR code` when qrencode is installed AND container has
a port. Checks exposure is `public` first. Renders QR in fzf, URL = `http://{cid}.local`.
**Python:** No QR code option in `_open_in_submenu` at all.

### ✅ NV2 — `_open_in_submenu`: "File manager" is xdg-open in shell, yazi in py (MEDIUM)
**Shell:** `*"File manager"*` → `xdg-open "$open_path" & disown` — opens system native file manager detached.
**Python:** `subprocess.run(['yazi', str(ip)])` — opens yazi inline.
Shell opens the native desktop file manager in the background. Different UX.

### ✅ NV3 — `_open_in_submenu`: browser URL ignores proxy routes (MEDIUM)
**Shell:** `_open_in_best_url` checks proxy config for a registered route for this
cid; if found uses `http(s)://route_url`, else falls back to `http://localhost:{port}`.
**Python:** Always opens `http://{netns_ct_ip}:{port}` — never checks proxy routes.

### ✅ NV4 — `_open_in_submenu`: terminal missing pause hint before switch (LOW)
**Shell:** Before `tmux switch-client`, shows `pause "Opening terminal for '{name}'
  {path}
  Press ctrl-\ to detach."`.
**Python:** Switches directly with no message.

### ✅ NV5 — `_blueprint_submenu`: edit missing `_guard_space` check (LOW)
**Shell:** Calls `_guard_space || continue` before opening `$EDITOR`.
**Python:** Opens editor directly, no space check.

### ✅ NV6 — `_blueprint_submenu`: delete confirm message differs (LOW)
**Shell:** `"Delete blueprint '$bname'?\nThis cannot be undone."`
**Python:** `"Delete blueprint '{name}'?\n\n  This does not affect containers."`

### ✅ NV7 — `_blueprint_submenu`: rename does not loop on name conflict (LOW)
**Shell:** Inner `while true` loop — on existing-name conflict, shows pause then
re-prompts for a new name. Exits only on cancel or success.
**Python:** Single attempt — on conflict shows pause then `continue`s outer loop
(back to edit/rename/delete menu), not back to the name prompt.

### ✅ NV8 — `_blueprint_submenu`: editor fallback is `vi` in shell, `nano` in py (LOW)
**Shell:** `${EDITOR:-vi}`  **Python:** `os.environ.get('EDITOR','nano')`

### ✅ NV9 — `_blueprint_submenu`: post-edit validation added in py but absent in shell (LOW)
**Shell:** Opens editor, no validation after — file is accepted as-is.
**Python:** After editor closes calls `bp_parse` + `bp_validate` and shows
errors if found. Improvement but a divergence.

---

## 🟠 NEW — FUNCTIONAL DIVERGENCES

### NF1 — `persistent_storage_menu`: py has split view; shell has unified view (HIGH)
**Shell `_persistent_storage_menu`:** Single unified list of ALL profiles across
ALL containers. Each entry shows coloured status dot:
- `GRN●` running, `YLW○` stale (clears active on display), `DIM○` free
- `★` suffix if this profile is the default for some container
Shows: `def_for` (which container it's set as default for), size, scid, type.
Inline export/import running status (`YLW↑ Export running` / `DIM↑ Export`).
Header: `── Profiles: {name} ──` (per-container ctx) or `── Persistent storage ──` (global).
**Python `persistent_storage_menu`:** Global mode shows a list of containers
with storage, then navigates to per-container view. Per-container view shows
profiles with running/stale/free status but:
- No ★ default indicator
- No `def_for` (which container is this the default for)
- No inline export/import running status lines
- No `active_cid` stale-clear on display
- Status logic is per-container running state, not per-profile active_cid

### NF2 — `_manage_backups_menu` (global): shell shows all containers; py filters to only those with backups (MEDIUM)
**Shell:** Lists ALL containers regardless of whether they have backups.
**Python `_global_backups_menu`:** Only lists containers that have `.meta` files
in their snap dir. A container with no backups yet is invisible.

### NF3 — `_ensure_ubuntu`: no guard if `sdUbuntuSetup` is already running (MEDIUM)
**Shell `_ubuntu_menu`:** If `tmux_up sdUbuntuSetup OR sdUbuntuPkg`, shows
Attach/Kill menu before proceeding.
**Python:** `_ensure_ubuntu()` launches `sdUbuntuSetup` session without checking
if one is already running, potentially creating a duplicate.

### NF4 — `containers_submenu`: background size cache refresh not implemented (LOW)
**Shell:** In the container list render loop, if `_sz_age > 60` spawns a
background `du` subshell to update `CACHE_DIR/sd_size/$cid` asynchronously
(non-blocking — list renders with stale value, updates silently).
**Python:** Reads cache file if present but never spawns background update —
size cache never refreshes during a session.

### NF5 — `containers_submenu`: health check called unconditionally in py (LOW)
**Shell:** `nc -z -w1 127.0.0.1 "$_list_port"` only if `health=true AND port set AND non-zero` — avoids `nc` call otherwise.
**Python:** `health_check(cid)` called for every running container, regardless of
whether the blueprint sets `health=true`.

### NF6 — `_global_backups_menu` header/container matching divergence (LOW)
**Shell `_manage_backups_menu`:** Header is `"Manage backups"`. Uses `_menu` helper
(adds Back automatically). Matches by `*"${CT_NAMES[$i]}"*`.
**Python:** Header is `── Backups ──`. Matches by `cname(cid2) in sc`. Functionally
close but header and match style differ.

### NF7 — `stop_ct` missing `exposure_flush` call (LOW)
**Shell `_stop_container`:** After killing the tmux session calls `_exposure_flush "$cid"`
to purge iptables rules for that container.
**Python `stop_ct`:** Calls `netns_ct_del` which removes the veth pair and
flushes iptables via `netns_ct_del`, but `_exposure_flush` (which calls
`_exposure_apply isolated`) is not explicitly called on stop. Check if
`netns_ct_del` subsumes this.

### NF8 — `_cleanup_stale_lock` equivalent not called per-render (LOW)
**Shell:** `_cleanup_stale_lock` called at top of `containers_submenu`,
`container_submenu`, and `main_menu` render loops. It clears `SD_INSTALLING`
if the `sdInst_` session has died.
**Python:** `validate_containers` runs at mount-time via `set_img_dirs` but
equivalent stale-lock cleanup is not run on each menu render.

---

## ✅ CONFIRMED EQUIVALENT

- Signal handling (SIGUSR1/INT/TERM/HUP) ✅
- sweep_stale, require_sudo keepalive, tmux session naming ✅
- enc_menu System Agnostic disable: SD_DEFAULT_KEYWORD temp file fallback ✅
- _env_exports: all env vars, PATH, GPU block ✅
- netns_setup/teardown metadata files ✅
- resize_image: two-step mount, exec restart, LUKS re-open order ✅
- install_method_menu: blueprint/clone/imported, tab-delimited fzf ✅
- containers_submenu: batch json read, cid tag extraction from `[cid]` ✅
- groups_menu/group_submenu: structure, start/stop/edit/delete/sequence ✅
- proxy_menu: routes, exposure section, mDNS display (rurl.local equivalent) ✅
- resources_menu: full parity ✅
- active_processes_menu: full parity ✅
- logs_browser: full parity ✅
- setup_image: detect/select/create flow, yazi picker with .img filter ✅
- blueprints_settings_menu: persistent/autodetect toggles, custom paths ✅
- enc_menu: all slot operations, passkeys, verified systems ✅
- _guard_ubuntu_pkg: wired to all 4 ubuntu op sites ✅
- process_install_finish: stale guard, backup offer ✅