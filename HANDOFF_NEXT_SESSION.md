# SimpleDocker Python Rewrite — Handoff for Next Session

## Context

You are continuing a Python rewrite of `services.sh` (7627-line bash script) as a Python TUI app called `simpledocker`. The goal is **visually and functionally identical to the bash original** — same fzf menus, same sections, same labels, same flow. Python is used only for maintainability, NOT to reduce features.

The user is **very specific**: every menu, every submenu, every item, every status indicator must match the bash 1:1.

---

## Project Location

The user's working copy is at their own path. They receive a zip. The zip must extract to a folder called `simpledocker/` (NOT `simpledocker_fixed/`).

**On the Claude container:**
- Working copy: `/home/claude/simpledocker/`
- Original bash: `/home/claude/services.sh`
- Previous plan: `/home/claude/PLAN.md`

---

## Architecture Overview

```
simpledocker/
  main.py                    # entry point — _inner_main(), tmux session launch
  cli/app.py                 # AppContext class (all dir paths), pick_or_create_image()
  functions/
    constants.py             # GRN/RED/YLW/BLU/CYN/BLD/DIM/NC, L{}, KB{}, FZF_BASE
    utils.py                 # run(), run_out(), tmux_up(), tsess(), tmux_get/set,
                             # strip_ansi(), trim_s(), make_tmp(), read_json/write_json, rand_id()
    tui.py                   # fzf(), confirm(), pause(), finput(), sep(), menu()
    image.py                 # create_img(), mount_img(), do_umount(), resize_image()
    blueprint.py             # compile_service(), list_blueprint_names(),
                             # list_persistent_names(), list_imported_names(),
                             # get_persistent_bp(), bp_cfg_set(), bp_autodetect_dirs()
    container.py             # load_containers() -> (ids, names, sjs) — ALWAYS 3-TUPLE
                             # cname(), cpath(), state_get(), is_installing(),
                             # start_container(), stop_container(), start_group(), stop_group(),
                             # list_groups(), grp_containers(), grp_seq_steps(),
                             # grp_read_field(), grp_path()
    network.py               # netns_ct_ip(), exposure_get/set/next/label/apply()
    storage.py               # stor_create_profile(), stor_link(), stor_unlink(),
                             # stor_read_name/type/active(), stor_meta_set()
    installer.py             # run_job(), guard_install(), process_install_finish(),
                             # ensure_ubuntu()
  menu/
    main_menu.py             # main_menu(), containers_submenu(), groups_menu(),
                             # blueprints_submenu(), _help_menu(), _quit_menu(), _quit_all()
    container_menu.py        # container_submenu() — ACCEPTS ctx object OR positional args
    group_menu.py            # group_submenu()
    backup_menu.py           # container_backups_menu()
    storage_menu.py          # persistent_storage_menu()
    enc_menu.py              # enc_menu()
    proxy_menu.py            # proxy_menu(), qrencode_menu()
    ubuntu_menu.py           # ubuntu_menu()
    logs_menu.py             # logs_browser()
    resources_menu.py        # resources_menu_global(), resources_menu() per-container
    port_exposure_menu.py    # port_exposure_menu()
```

**Key invariant**: `load_containers()` always returns a **3-tuple** `(ids, names, sjs)`. NEVER unpack as 2-tuple.

---

## Known Bugs That Must Be Fixed First

### CRASH — P0

1. **`_quit_all` in main_menu.py line 626** (and possibly other places):
   ```python
   # WRONG — crashes
   ids, _ = load_containers(ctx.containers_dir, show_hidden=True)
   # CORRECT
   ids, _, _ = load_containers(ctx.containers_dir, show_hidden=True)
   ```
   Search ALL files: `grep -rn "ids, _ = load_containers" menu/ functions/`

2. **`container_submenu` call in main_menu.py** — must pass ctx object:
   ```python
   # CORRECT (in containers_submenu loop)
   container_submenu(m.group(1), ctx)
   ```
   The function signature supports both ctx object and positional args.

3. **`persistent_storage_menu` call in container_menu.py** — currently passes wrong args, needs ctx object.

---

## What's Still Missing / Wrong (Full Gap List)

### menu/container_menu.py

**Missing from installed/stopped state items:**
- `ct_rename` (✎ Rename) — was in bash, may be missing from stopped section
- `ct_update` (↑ Update) — in bash as `_UPD_ITEMS`: shows update entries when a newer blueprint version exists. Should appear in the stopped-state section. The update detection logic in bash scans all blueprints for same `storage_type` and compares versions. In Python this needs `_collect_update_items(cid, containers_dir, blueprints_dir)` that returns list of update entries.
- **Port exposure** `⬤ Port exposure` toggle — needs to be in the installed/stopped section (was patched but verify it works)
- **Clone container** — was patched but uses btrfs snapshot if available, else cp. Must match bash `_clone_container()`: tries `btrfs subvolume snapshot src clone_path`, falls back to `cp -a`.

**Running state missing items**: check bash line 5546-5562:
- stop, restart, attach, open_in, log ✓
- actions ✓
- crons ✓
- **`ct_update`** also appears for running containers in some states — check bash

**`open_in_submenu` missing features**:
- "Show QR code" option (only if ubuntu ready + qrencode installed + port set + exposure=public)
- "File manager" should use `xdg-open path` not yazi
- Terminal should use `tmux switch-client` not attach, and `sdTerm_{cid}` session name

**Blueprint update flow** (`ct_update` / `⬆ Updates` section):
```python
# Needs implementation in functions/blueprint.py:
def collect_update_items(cid, containers_dir, blueprints_dir, mnt_dir):
    """Returns list of (display_str, bp_file, new_ver, bp_name) for matching blueprints."""
    # 1. Read storage_type and cur_ver from service.json
    # 2. Scan all blueprints (local + persistent + imported) for same storage_type
    # 3. Compare versions — show "Changes detected" or "v_old → v_new"
```

### menu/backup_menu.py

Current version is minimal. Must match bash `_container_backups_menu()` exactly:
- **Two sections**: `── Automatic backups ──` and `── Manual backups ──`
- Each backup shows ID + timestamp from `.meta` file
- Actions section: `+ Create manual backup`, `× Remove all backups`
- Clicking a backup → sub-menu: **Restore**, **Create clone**, **Delete**
- "Remove all" → sub-menu: "All automatic" / "All manual" / "All (automatic + manual)"
- Backup ops: check container is stopped before restore/backup/clone
- Snapshot functions needed in `functions/container.py`:
  - `create_manual_backup(cid, containers_dir, installations_dir, backup_dir)`
  - `restore_snapshot(cid, snap_path, containers_dir, installations_dir)`
  - `clone_from_snapshot(cid, snap_path, snap_id, clone_name, containers_dir, installations_dir)`
  - `delete_backup(snap_dir, snap_id)`
  - `snap_meta_get(snap_dir, snap_id, field)`

### menu/resources_menu.py

Current version is a stub. Full implementation must match bash `_resources_menu()`:
- Top-level: list all containers with cgroups status `[cgroups on]` label
- Per-container submenu shows:
  - Toggle cgroups on/off
  - CPU quota (e.g. 200% = 2 cores)
  - Memory max (e.g. 8G)
  - Memory+swap max
  - CPU weight (1-10000)
  - Info section: GPU/VRAM and Network not configurable
- Data stored in `containers_dir/{cid}/resources.json`
- Helper functions needed in `functions/container.py` or `functions/utils.py`:
  - `res_get(containers_dir, cid, key) -> str`
  - `res_set(containers_dir, cid, key, value)`
  - `res_del(containers_dir, cid, key)`

### menu/logs_menu.py

Current version looks correct — verify it matches bash `_logs_browser()`.

### menu/port_exposure_menu.py

Looks correct but uses old `fzf()` wrapper — should use `_fzf_raw()` pattern for consistency. Verify it works.

### menu/ubuntu_menu.py

Newly written this session. Needs testing. Key gaps:
- `_ensure_ubuntu()` calls `installer.ensure_ubuntu()` — verify that function exists
- Package list uses `dpkg-query` inside chroot — verify this works
- Update detection via `apt-get --simulate upgrade` may be slow — consider caching

### menu/proxy_menu.py

Should be mostly complete but verify:
- `qrencode_menu()` exists and matches bash `_qrencode_menu()`
- Caddy install/uninstall/restart flow matches bash
- Route management (add/remove/edit routes) matches bash `_proxy_menu()`

### menu/enc_menu.py

Should be complete but verify LUKS key slot management matches bash `_enc_menu()`.

### menu/group_menu.py

Newly rewritten. Verify:
- `grp_seq_steps()` is correctly reading the `start = {...}` field
- Start/stop group correctly passes all required args

### menu/storage_menu.py

Newly rewritten. Verify:
- Numbered-index selection pattern works correctly
- Export/import sessions work
- `stor_create_profile()`, `stor_link()`, `stor_unlink()` exist in `functions/storage.py`

### functions/storage.py

Check all these exist:
- `stor_path(storage_dir, scid) -> str`
- `stor_meta_path(storage_dir, scid) -> str`
- `stor_meta_set(storage_dir, scid, **kwargs)`
- `stor_read_name(storage_dir, scid) -> str`
- `stor_read_type(storage_dir, scid) -> str`
- `stor_read_active(storage_dir, scid) -> str`
- `stor_create_profile(containers_dir, cid, stype, pname, mnt_dir)`
- `stor_link(containers_dir, cid, scid, mnt_dir)`
- `stor_unlink(containers_dir, cid, scid)`
- `stor_count(containers_dir, cid) -> int`

### functions/container.py

Check these exist:
- `cleanup_stale_lock()`
- `is_installing(cid) -> bool`
- `health_check(containers_dir, cid) -> bool`
- `guard_install(containers_dir) -> bool`
- `run_job(op, cid, containers_dir, installations_dir, ubuntu_dir, logs_dir, tmp_dir, force="")`
- `process_install_finish(cid, containers_dir, installations_dir)`
- `start_group(gid, groups_dir, containers_dir, installations_dir, mnt_dir)`
- `stop_group(gid, groups_dir, containers_dir, installations_dir, mnt_dir, cache_dir)`
- `grp_seq_steps(groups_dir, gid) -> list`

### functions/blueprint.py

Missing:
- `bp_autodetect_dirs(mnt_dir) -> list` — scan Home/XDG dirs for `.container` files
- `bp_custom_paths_get/add/remove(mnt_dir)` — custom scan path management

### main_menu.py — `_install_method_menu()`

Current version is missing the **"Clone existing container"** section that bash has. Bash `_install_method_menu()` shows:
1. `── Install from blueprint ──` (blueprints list)
2. `── Clone existing container ──` (installed containers list, uses btrfs snapshot)
3. `── Navigation ──`

The clone path calls `_clone_source_submenu(src_cid)` which prompts for name then calls `_clone_container()`.

---

## Testing Checklist

After each fix, run:
```bash
cd /path/to/simpledocker
python3 -c "
import sys; sys.path.insert(0, '.')
mods = ['functions.constants','functions.utils','functions.tui','functions.blueprint',
        'functions.container','functions.image','functions.installer','functions.network',
        'functions.storage','menu.main_menu','menu.container_menu','menu.group_menu',
        'menu.backup_menu','menu.storage_menu','menu.enc_menu','menu.proxy_menu',
        'menu.ubuntu_menu','menu.logs_menu','menu.resources_menu','menu.port_exposure_menu',
        'cli.app','main']
for m in mods:
    try: __import__(m); print(f'  OK  {m}')
    except Exception as e: print(f'  ERR {m}: {e}')
"
```

Then run the app in a tmux session:
```bash
bash debug_run.sh
```

---

## Work Order (Priority)

1. **Fix all P0 crashes** — grep for 2-tuple load_containers unpacking
2. **Fix backup_menu.py** — full implementation with auto/manual sections, restore/clone/delete
3. **Fix resources_menu.py** — full per-container cgroups UI
4. **Fix container_menu.py** — ct_update flow, clone via btrfs snapshot, open_in QR code
5. **Fix _install_method_menu** — add clone-existing-container section
6. **Verify all other menus** work end-to-end
7. **Package and output zip** named `simpledocker.zip` extracting to `simpledocker/`

---

## Critical Rules

- `load_containers()` → ALWAYS 3-tuple: `ids, names, sjs = load_containers(...)`
- zip must extract to `simpledocker/` not `simpledocker_fixed/`
- After EVERY logical unit of work → save zip to `/mnt/user-data/outputs/simpledocker.zip` immediately
- The user wants **exact visual parity** with bash — same section headers, same emoji/symbols, same status indicators
- fzf pattern: use `_fzf_raw(items, *extra_args)` local helper in each menu file
- All colors via constants: `GRN RED YLW BLU CYN BLD DIM NC`
- `make_tmp(prefix, suffix="")` for temp files
