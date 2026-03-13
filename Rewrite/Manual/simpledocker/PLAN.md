# SimpleDocker Python Rewrite — Gap Analysis & Implementation Checklist

## Status Legend
- ✅ Implemented correctly
- ⚠️ Partial / broken
- ❌ Missing entirely

---

## 1. main_menu.py

### `main_menu()`
- ✅ Header with image label `[X.X/X.X GB]`
- ✅ Containers / Groups / Blueprints / ? Other / × Quit
- ✅ Status counts (running, active groups, bp count)
- ⚠️ `_quit_all` crashes: `ids, _ = load_containers(...)` — 3-tuple returned → **FIXED below**
- ⚠️ `SD_QUIT` ctrl-q binding via `--bind` → works but fzf opened with subprocess differently to rest

### `containers_submenu()`
- ✅ Shows containers with colored dots
- ✅ Shows dialogue, size cache, IP:port label
- ✅ `+ New container` → `_install_method_menu`
- ⚠️ `_install_method_menu` uses simple `menu()` — bash used fzf with full blueprint list shown
- ❌ Missing: install method choice as fzf list (Blueprint → pick bp; Paste JSON; Clone)

### `groups_menu()`
- ✅ Lists groups with running counts
- ⚠️ Group name read from `.toml` but `grp_read_field` not used — gid used as display name
- ❌ Header extra `[N · M active]` not showing

### `group_submenu()` (in group_menu.py)
- ⚠️ Uses generic `menu()` — bash used full fzf with sequence display inline
- ❌ Missing: sequence steps shown with colored dots (running=green, stopped=red, wait=yellow)
- ❌ Missing: "Add before" / "Edit" / "Add after" / "Remove" step sub-menu on click
- ❌ Missing: `≡ Edit name/desc` shows/edits both `name` and `desc` fields
- ❌ Missing: group header dot (green ▶ if running, dim ▶ if stopped)

### `blueprints_submenu()`
- ✅ Lists file/persistent/imported blueprints with colors
- ✅ Edit, rename, delete local blueprints
- ❌ Missing: `_blueprints_settings_menu` (autodetect mode, custom scan paths, enable/disable persistent)

### `_help_menu()` (the "Other" menu)
- ❌ COMPLETELY WRONG — bash has rich fzf list with Storage/Plugins/Tools/Caution sections:
  - `── Storage ──` section: Profiles & data, Backups, Blueprints
  - `── Plugins ──` section: Ubuntu base (status), Caddy (status), QRencode (status)
  - `── Tools ──` section: Active processes, Resource limits, Blueprint preset
  - `── Caution ──` section: View logs, Clear cache, Resize image, Manage Encryption, Delete image file
  - `── Navigation ──` section: back
- Python version just has a plain `menu()` with 7 items and no sections

### `_quit_menu()`
- ❌ Missing `⊙ Detach` option — bash has: `detach` | `quit_stop_all`

### `_quit_all()`
- ❌ `ids, _ = load_containers(...)` crashes — returns 3-tuple

### `_active_processes_menu()`
- ❌ Stripped down — bash shows tmux sessions with CPU/RAM stats, GPU header, tabbed display
- ❌ Selecting a session offers to kill it

---

## 2. container_menu.py — `container_submenu()`

### State display / header
- ✅ Colored dot in header
- ✅ dialogue label in header
- ✅ IP:port in header

### Menu items (running state)
- ✅ Stop, Restart, Attach, Open in, Log
- ✅ Actions section with custom labels from service.json
- ✅ Cron section with running/stopped status
- ❌ Missing: Exposure toggle `⬤ Exposure` cycling (isolated→localhost→public)

### Menu items (installed, stopped)
- ✅ Start, Open in, Backups, Profiles, Edit
- ✅ Updates section
- ❌ Missing: `Clone container` option
- ❌ Missing: start shows sub-fzf "Start and show live output" vs "Start in background"
- ❌ Missing: storage profile pick before start (if profiles exist)

### Menu items (not installed)
- ✅ Install, Edit, Rename
- ✅ Remove (caution section)

### Install method
- ⚠️ `_install_method_menu` doesn't match bash's `_install_method_menu` which shows:
  - Blueprint options (fzf list of all blueprints)
  - Blank canvas
  - Import JSON
  - Clone from backup
  - (already handled by containers_submenu for new)

### Actions
- ❌ `⊙ Open browser` action type missing (opens URL in browser)

---

## 3. group_menu.py

See group_submenu section above. All sequence editing is broken/missing.

---

## 4. backup_menu.py

### `container_backups_menu()`
- ✅ Lists snapshots with label + date
- ✅ Manual backup via btrfs snapshot
- ✅ Restore from snapshot
- ✅ Delete snapshot
- ❌ Missing: `_manage_backups_menu` (top-level backups view across all containers)
- ❌ Missing: `Clone from snapshot` option
- ❌ Missing: rotate_and_snapshot auto logic

---

## 5. storage_menu.py — `persistent_storage_menu()`

- ⚠️ Uses hardcoded `os.path.join(mnt_dir, "Storage")` — should use `ctx.storage_dir`
- ⚠️ Shows scid as ID only — should show name prominently
- ❌ Missing: export profile (`_stor_export_menu`)
- ❌ Missing: import profile (`_stor_import_menu`)
- ❌ Missing: link/unlink container from profile
- ❌ Missing: profile type display (shared, exclusive, etc.)

---

## 6. enc_menu.py

- ✅ Has most key management implemented (partial check only)

---

## 7. proxy_menu.py — `proxy_menu()`

- ✅ Caddy install/running/autostart status
- ✅ Routes list with mDNS names
- ✅ Port exposure section
- ⚠️ `_install_caddy()` had f-string syntax error (fixed in previous session)
- ❌ Missing: QRencode sub-menu (`_qrencode_menu`)

---

## 8. ubuntu_menu.py — `ubuntu_menu()`

- ⚠️ Uses generic dpkg-query — bash has full apt integration with update detection
- ❌ Missing: `_sd_ub_cache_read` — cached ubuntu status (PKG_DRIFT, HAS_UPDATES)
- ❌ Missing: "Install default packages" button
- ❌ Missing: update notification in header
- ❌ Missing: proper apt tmux session with output visible

---

## 9. logs_menu.py

- ✅ Basic log file browser
- ❌ Missing: tail -f live view via tmux

---

## 10. port_exposure_menu.py

- ❌ Appears to be a stub — not properly wired to main menu

---

## 11. resources_menu.py

- ⚠️ Partial — check if CPU/memory limits r/w works

---

## 12. functions/blueprint.py

- ⚠️ `list_imported_names` / `list_persistent_names` may not correctly scan filesystem
- ❌ `bp_autodetect_dirs` — must scan Home, custom paths, XDG dirs for `.container` files

---

## 13. functions/container.py

- ⚠️ `load_containers` returns 3-tuple but many callers expect 2 → **fixed but verify**
- ❌ `_update_size_cache` background job missing
- ❌ `ct_id_by_name` — verify exported correctly

---

## 14. functions/image.py — `pick_or_create_image()`

- ⚠️ Was crashing with missing args (fixed in previous session)
- ❌ Verify LUKS open flow on existing encrypted images

---

## 15. main.py — startup

- ⚠️ tmux session launch was broken (fixed but verify)
- ✅ sudoers write
- ❌ `_sweep_stale` equivalent (cleanup dead install lock files at startup)

---

## Priority Fix Order

### P0 — Crashes (won't run at all)
1. `_quit_all` 3-tuple crash
2. Any remaining import errors

### P1 — Visually wrong (looks nothing like bash)
3. `_help_menu` — rewrite as full fzf with sections
4. `_quit_menu` — add Detach option
5. `groups_menu` — fix header extra, use grp name not gid
6. `group_submenu` — full sequence display with colored dots + step edit sub-menu

### P2 — Missing functionality
7. Container submenu: Exposure toggle, Clone, start mode picker
8. `_blueprints_settings_menu` — autodetect + custom paths settings
9. `_active_processes_menu` — CPU/RAM stats, GPU header, kill option
10. `_manage_backups_menu` — top-level backups across all containers
11. `persistent_storage_menu` — export/import, link/unlink

### P3 — Polish
12. ubuntu_menu — update detection, proper apt session
13. logs_menu — live tail via tmux pane
14. blueprint autodetect scan
