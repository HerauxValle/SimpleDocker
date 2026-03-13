# SimpleDocker Menu Structure Analysis

---

## BASH (`services.sh`) — Menu Tree

```
main_menu()
├── Containers  →  _containers_submenu()
│   ├── ── Containers ──
│   │   └── [cid_entry...]  ← dot: dim/yellow/green/red ◈, name, dialogue, size, ip:port
│   ├── + New container  →  _install_method_menu()
│   │   ├── ── Install from blueprint ──
│   │   │   ├── [local bp...]       tag: bp:NAME
│   │   │   ├── [persistent bp...]  tag: pbp:NAME
│   │   │   └── [imported bp...]    tag: ibp:NAME
│   │   ├── ── Clone existing container ──
│   │   │   └── [installed ct...]   tag: clone:CID  →  _clone_source_submenu(cid)
│   │   │       ├── ── Main ──
│   │   │       │   ├── Current state           tag: current
│   │   │       │   └── Post-Installation (ts)  tag: post  [if exists]
│   │   │       └── ── Other ──
│   │   │           └── [other backups...]      tag: snap_id
│   │   └── ── Navigation ──
│   │       └── Back
│   └── ── Navigation ──
│       └── Back
│
│   _container_submenu(cid)  [entered from _containers_submenu]
│   ├── STATE: installing / install_done
│   │   ├── ── General ──
│   │   ├── Attach to installation   (if installing, not done)
│   │   │   OR  ✓ Finish installation / ✓ Finish update  (if done)
│   │   └── ── Navigation ──
│   │       └── Back
│   │
│   ├── STATE: running
│   │   ├── ── General ──
│   │   ├── Stop
│   │   ├── Restart
│   │   ├── Attach
│   │   ├── Open in  →  _open_in_submenu(cid)
│   │   │   ├── ⊕  Browser         [if port set]
│   │   │   ├── ⊞  Show QR code    [if port set + qrencode installed]
│   │   │   ├── ◧  File manager
│   │   │   └── ◉  Terminal
│   │   ├── Log
│   │   ├── ── Actions ──           [if actions exist]
│   │   │   └── [action_labels...]
│   │   └── ── Cron ──              [if crons exist]
│   │       └── [⏱ cron_name [interval|stopped]...]
│   │
│   ├── STATE: installed (stopped)
│   │   ├── ── General ──
│   │   ├── Start  →  start submenu (Attach live / Background)
│   │   ├── Open in  →  _open_in_submenu(cid)
│   │   ├── ── Storage ──
│   │   ├── Backups  →  _container_backups_menu(cid)
│   │   │   ├── ── Automatic backups ──
│   │   │   │   └── [auto_id (ts)...]
│   │   │   ├── ── Manual backups ──
│   │   │   │   └── [man_id (ts)...]
│   │   │   ├── ── Actions ──
│   │   │   │   ├── + Create manual backup
│   │   │   │   └── × Remove all backups  →  submenu
│   │   │   │       ├── All automatic
│   │   │   │       ├── All manual
│   │   │   │       └── All (automatic + manual)
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   │   [per-backup click]  →  submenu
│   │   │       ├── Restore
│   │   │       ├── Create clone
│   │   │       └── Delete
│   │   ├── Profiles  →  _persistent_storage_menu(cid)   [see below]
│   │   ├── Edit blueprint
│   │   ├── ── Caution ──
│   │   ├── ⬆ Updates  [yellow if pending]   →  _build_update_items submenu
│   │   │   └── [update entries...]
│   │   └── Uninstall
│   │
│   └── STATE: not installed
│       ├── ── General ──
│       ├── Install
│       ├── Edit blueprint
│       ├── Rename
│       ├── ── Caution ──
│       └── Remove
│
├── Groups  →  _groups_menu()
│   ├── ── Groups ──
│   │   └── [▶/dim▶  group_name  N/M running...]
│   ├── + New group
│   └── ── Navigation ──
│       └── Back
│
│   _group_submenu(gid)  [entered from _groups_menu]
│   ├── ── General ──
│   ├── STATE: running
│   │   └── ■  Stop group
│   ├── STATE: stopped
│   │   ├── ▶  Start group
│   │   ├── ≡  Edit name/desc
│   │   └── ×  Delete group
│   ├── ── Sequence ──
│   │   └── [step entries... (container/wait steps)]
│   │       [per-step click]  →  submenu
│   │           ├── Add before
│   │           ├── Edit
│   │           ├── Add after
│   │           └── Remove
│   └── +  Add step
│
├── Blueprints  →  _blueprints_submenu()
│   ├── ── Blueprints ──
│   │   ├── [local bps...]
│   │   ├── [persistent bps...  [Persistent]]
│   │   └── [imported bps...    [Imported]]
│   ├── + New blueprint
│   └── ── Navigation ──
│       └── Back
│
│   [per-blueprint click]  →  _blueprint_submenu(bname)
│       ├── Edit
│       ├── Rename
│       └── Delete
│
│   _blueprints_settings_menu()  [accessible from blueprints_submenu "Settings"]
│       ├── ── General ──
│       ├── Persistent blueprints  [Enabled/Disabled]
│       ├── Autodetect blueprints  [Home/Root/Everywhere/Custom/Disabled]
│       ├── ── Scanned paths ──    [only if mode=Custom]
│       │   └── [custom_path...]   (click to remove)
│       │   └── + Add path
│       └── ── Navigation ──
│           └── Back
│
├── ── separator ──
├── ?  Help  →  _help_menu()
│   ├── ── Storage ──
│   │   ├── Profiles & data  →  _persistent_storage_menu()
│   │   │   ├── [storage profiles...]  ●/○/★ name [scid]  (type)  size  status
│   │   │   ├── ── Backup data ──
│   │   │   │   ├── ↑ Export  →  _stor_export_menu()
│   │   │   │   │   └── [multi-select profiles]  →  pick dest dir  →  filename input
│   │   │   │   └── ↓ Import  →  _stor_import_menu()
│   │   │   │       └── file picker  →  confirm
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   │   [per-profile click]  →  submenu
│   │   │       ├── ★ Set as default / ☆ Unset default
│   │   │       ├── Rename
│   │   │       └── Delete
│   │   ├── Backups  →  _manage_backups_menu()
│   │   │   └── container picker  →  _container_backups_menu(cid)   [see above]
│   │   └── Blueprints  →  _blueprints_settings_menu()   [see above]
│   ├── ── Plugins ──
│   │   ├── Ubuntu base  [ready/not installed + update tag]  →  _ubuntu_menu()
│   │   │   ├── ── Actions ──
│   │   │   │   ├── Updates  →  submenu
│   │   │   │   │   ├── Sync default pkgs  [up to date / changes detected]
│   │   │   │   │   ├── Update all pkgs    [up to date / updates available]
│   │   │   │   │   └── ── Navigation ──
│   │   │   │   └── Uninstall Ubuntu base
│   │   │   ├── ── Default packages ──
│   │   │   │   └── [def pkg ◈  name  version...]
│   │   │   ├── ── System packages ──
│   │   │   │   └── [sys pkg ◈  name  version...]
│   │   │   ├── ── Packages ──
│   │   │   │   └── [user pkg ◈  name  version...]  (click → confirm remove)
│   │   │   └── + Add package
│   │   ├── Caddy  [running/stopped]  →  _proxy_menu()
│   │   │   ├── ── Installation ──
│   │   │   │   └── Caddy + mDNS  [installed/not installed]
│   │   │   │       [if installed]  →  submenu
│   │   │   │           ├── Reinstall / update
│   │   │   │           ├── Uninstall
│   │   │   │           ├── View log
│   │   │   │           ├── View Caddyfile
│   │   │   │           └── Reset proxy config
│   │   │   ├── ── Startup ──
│   │   │   │   ├── Running  [running/stopped]      (click → start/stop)
│   │   │   │   └── Autostart  [on/off]             (click → toggle)
│   │   │   ├── ── Rerouting ──
│   │   │   │   ├── [route entries...  url → container  (proto  mDNS)]
│   │   │   │   │   [per-route click]  →  submenu
│   │   │   │   │       ├── Change URL
│   │   │   │   │       ├── Change container
│   │   │   │   │       ├── Toggle HTTPS (currently: X)
│   │   │   │   │       └── Remove
│   │   │   │   └── + Add URL  →  container picker  →  URL input  →  http/https picker
│   │   │   ├── ── Port exposure ──
│   │   │   │   └── [installed cts with ports...  exposure_label  name  ip:port]
│   │   │   │       (click → cycle: isolated → localhost → public)
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   └── QRencode  [installed/not installed]  →  _qrencode_menu()
│   │       ├── [if installed]   Update / Uninstall
│   │       └── [if not]         Install
│   ├── ── Tools ──
│   │   ├── Active processes  →  _active_processes_menu()
│   │   │   ├── ── Processes ──
│   │   │   │   └── [session entries  label  CPU  RAM  PID]
│   │   │   │       (click → confirm kill)
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   ├── Resource limits  →  _resources_menu()
│   │   │   ├── ── Containers ──
│   │   │   │   └── [ct entries  name  [cgroups on]]
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   │   [per-ct click]  →  per-container submenu
│   │   │       ├── ── Configuration ──
│   │   │       │   ├── ● Enabled / ○ Disabled   (toggle)
│   │   │       │   ├── CPU quota    value
│   │   │       │   ├── Memory max   value
│   │   │       │   ├── Memory+swap  value
│   │   │       │   └── CPU weight   value
│   │   │       ├── ── Info ──
│   │   │       │   ├── GPU/VRAM     not configurable
│   │   │       │   └── Network      not configurable
│   │   │       └── ── Navigation ──
│   │   │           └── Back
│   │   └── Blueprint preset  (read-only viewer)
│   ├── ── Caution ──
│   │   ├── View logs  →  _logs_browser()
│   │   │   └── [log files list]  →  file viewer (read-only)
│   │   ├── Clear cache
│   │   ├── Resize image  (input: new GB)
│   │   ├── Manage Encryption  →  _enc_menu()
│   │   │   ├── ── General ──
│   │   │   │   ├── System Agnostic  [Enabled/Disabled]
│   │   │   │   ├── Auto-Unlock      [Enabled/Disabled]
│   │   │   │   └── Reset Auth Token
│   │   │   ├── ── Verified Systems ──
│   │   │   │   └── [vs entries  hostname  [vs:id]]
│   │   │   │       (click → Unauthorize)
│   │   │   │   └── + Verify this system
│   │   │   ├── ── Passkeys ──
│   │   │   │   └── [key entries  name  [s:slot]]
│   │   │   │       [per-key click]  →  submenu
│   │   │   │           ├── Rename
│   │   │   │           ├── Remove
│   │   │   │           └── Cancel
│   │   │   │   └── + Add Key  →  param editor  →  pbkdf/ram/threads/name/passphrase
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   └── × Delete image file
│   ├── ── Navigation ──
│   └── Back
│
└── × Quit  →  _quit_menu()
    ├── Detach
    └── Stop all & quit
```

---

---

## PYTHON (`simpledocker/`) — Menu Tree

```
main_menu()  [main_menu.py]
├── Containers  →  containers_submenu()  [main_menu.py]
│   ├── ── Containers ──
│   │   └── [cid_entry...]  ← dot, name, dialogue, size, ip:port  [same as bash]
│   ├── + New container  →  _install_method_menu()  [main_menu.py]
│   │   ├── ── Install from blueprint ──
│   │   │   ├── [local bp...]       tag: bp:NAME
│   │   │   ├── [persistent bp...]  tag: pbp:NAME
│   │   │   └── [imported bp...]    tag: ibp:NAME
│   │   ├── ── Clone existing container ──
│   │   │   └── [installed ct...]   tag: clone:CID  →  _clone_source_submenu()  [main_menu.py]
│   │   │       ├── ── Main ──
│   │   │       │   ├── Current state
│   │   │       │   └── Post-Installation (ts)  [if exists]
│   │   │       └── ── Other ──
│   │   │           └── [other backups...]
│   │   └── ── Navigation ──
│   │       └── Back
│   └── ── Navigation ──
│       └── Back
│
│   container_submenu(cid)  [container_menu.py]
│   ├── STATE: installing / install_done
│   │   ├── Attach to installation   (if installing, not done)
│   │   │   OR  ✓ Finish installation / ✓ Finish update  (if done)
│   │   └── [no explicit Navigation section visible in items list]
│   │
│   ├── STATE: running
│   │   ├── Stop
│   │   ├── Restart
│   │   ├── Attach
│   │   ├── Open in  →  open_in_submenu()  [container_menu.py]
│   │   │   ├── ⊕  Browser         [if port set]
│   │   │   ├── ⊞  Show QR code    [if port set + qrencode]  ← MISSING in Python
│   │   │   ├── ◧  File manager
│   │   │   └── ◉  Terminal
│   │   ├── Log
│   │   ├── ── Actions ──           [if actions exist]
│   │   │   └── [action_labels...]
│   │   └── ── Cron ──              [if crons exist]
│   │       └── [⏱ cron entries...]
│   │
│   ├── STATE: installed (stopped)
│   │   ├── Start  →  start submenu (Attach live / Background)
│   │   ├── Open in  →  open_in_submenu()
│   │   ├── ── Storage ──
│   │   ├── Backups  →  container_backups_menu()  [backup_menu.py]
│   │   │   ├── ── Automatic backups ──
│   │   │   │   └── [auto_id (ts)...]
│   │   │   ├── ── Manual backups ──
│   │   │   │   └── [man_id (ts)...]
│   │   │   ├── ── Actions ──
│   │   │   │   ├── + Create manual backup
│   │   │   │   └── × Remove all backups  →  submenu
│   │   │   │       ├── All automatic
│   │   │   │       ├── All manual
│   │   │   │       └── All (automatic + manual)
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   │   [per-backup click]  →  submenu
│   │   │       ├── Restore
│   │   │       ├── Create clone
│   │   │       └── Delete
│   │   ├── Profiles  →  persistent_storage_menu()  [storage_menu.py]
│   │   ├── Edit blueprint
│   │   ├── Rename                  ← EXTRA in Python (bash: installed state has no Rename)
│   │   ├── ◦  Clone container      ← EXTRA in Python (bash: no clone in installed state)
│   │   ├── ── Management ──        ← EXTRA section header in Python
│   │   │   └── [exposure_label]  Port exposure  (click → cycle)
│   │   ├── ── Caution ──
│   │   └── Uninstall
│   │   NOTE: ⬆ Updates section is ABSENT in Python (bash builds it here)
│   │
│   └── STATE: not installed
│       ├── Install
│       ├── Edit blueprint
│       ├── Rename
│       ├── ── Caution ──
│       └── Remove
│
├── Groups  →  groups_menu()  [main_menu.py]
│   ├── ── Groups ──
│   │   └── [▶/dim▶  group_name  N/M running...]
│   ├── + New group
│   └── ── Navigation ──
│       └── Back
│
│   group_submenu(gid)  [group_menu.py]
│   ├── ── General ──
│   ├── STATE: running
│   │   └── ■  Stop group
│   ├── STATE: stopped
│   │   ├── ▶  Start group
│   │   ├── ≡  Edit name/desc
│   │   └── ×  Delete group
│   ├── ── Sequence ──
│   │   └── [step entries...]
│   │       [per-step click]  →  submenu
│   │           ├── Add before
│   │           ├── Edit
│   │           ├── Add after
│   │           └── Remove
│   └── +  Add step
│
├── Blueprints  →  blueprints_submenu()  [main_menu.py]
│   ├── ── Blueprints ──
│   │   ├── [local bps...]
│   │   ├── [persistent bps...]
│   │   └── [imported bps...]
│   ├── + New blueprint             ← EXTRA in Python (bash has no inline create here)
│   ├── ── Settings ──              ← EXTRA section in Python
│   │   └── Settings  →  _blueprints_settings_menu()  [main_menu.py]
│   │       ├── ── General ──
│   │       ├── Persistent blueprints  [Enabled/Disabled]
│   │       ├── Autodetect blueprints  [Home/Root/Everywhere/Custom/Disabled]
│   │       ├── ── Scanned paths ──    [if Custom]
│   │       │   └── [custom_path...]
│   │       │   └── + Add path         ← Python uses text input, not yazi picker
│   │       └── ── Navigation ──
│   │           └── Back
│   └── ── Navigation ──
│       └── Back
│
│   [per-blueprint click]  →  _blueprint_submenu()  [main_menu.py]
│       ├── Edit
│       ├── Rename
│       └── Delete
│
├── ── separator ──
├── ?  Help  →  _help_menu()  [main_menu.py]
│   ├── ── Storage ──
│   │   ├── Profiles & data  →  persistent_storage_menu()  [storage_menu.py]
│   │   │   ├── [storage profiles...]  ●/○/★ name  size  status
│   │   │   ├── ── Backup data ──
│   │   │   │   ├── ↑ Export  →  _stor_export_menu()  [storage_menu.py]
│   │   │   │   │   NOTE: Python uses text path input (no yazi file picker)
│   │   │   │   └── ↓ Import  →  _stor_import_menu()  [storage_menu.py]
│   │   │   │       NOTE: Python uses text path input (no yazi file picker)
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   │   [per-profile click]  →  _storage_profile_submenu()  [storage_menu.py]
│   │   │       ├── Link to container   ← DIFFERENT: Python uses Link/Unlink
│   │   │       ├── Unlink              ← bash uses Set as default / Unset default
│   │   │       ├── Rename
│   │   │       └── Delete
│   │   ├── Backups  →  _manage_backups_menu()  [main_menu.py]
│   │   │   NOTE: ABSENT in Python — _manage_backups_menu not implemented in main_menu.py
│   │   └── Blueprints  →  _blueprints_settings_menu()
│   │
│   ├── ── Plugins ──
│   │   ├── Ubuntu base  →  ubuntu_menu()  [ubuntu_menu.py]
│   │   │   ├── ── Actions ──
│   │   │   │   ├── Updates  →  submenu
│   │   │   │   │   ├── Sync default pkgs
│   │   │   │   │   ├── Update all pkgs
│   │   │   │   │   └── ── Navigation ──
│   │   │   │   └── Uninstall Ubuntu base
│   │   │   ├── ── Default packages ──
│   │   │   │   └── [def pkg entries...]
│   │   │   ├── ── System packages ──
│   │   │   │   └── [sys pkg entries...]
│   │   │   ├── ── Packages ──
│   │   │   │   └── [user pkg entries...]
│   │   │   └── + Add package
│   │   │   NOTE: Python ubuntu_menu has simplified package list (no per-pkg click handler
│   │   │         for system/default pkg protection messaging - confirm remove only)
│   │   ├── Caddy  →  proxy_menu()  [proxy_menu.py]
│   │   │   ├── ── Installation ──
│   │   │   │   └── Caddy + mDNS  [installed/not installed]
│   │   │   │       [if installed]  →  submenu
│   │   │   │           ├── Reinstall / update
│   │   │   │           ├── Uninstall
│   │   │   │           ├── View log
│   │   │   │           ├── View Caddyfile
│   │   │   │           └── Reset proxy config
│   │   │   ├── ── Startup ──
│   │   │   │   ├── Running  [running/stopped]
│   │   │   │   └── Autostart  [on/off]
│   │   │   ├── ── Rerouting ──
│   │   │   │   ├── [route entries...]
│   │   │   │   │   [per-route click]  →  submenu
│   │   │   │   │       ├── Change URL
│   │   │   │   │       ├── Change container
│   │   │   │   │       ├── Toggle HTTPS (currently: X)
│   │   │   │   │       └── Remove
│   │   │   │   └── + Add URL
│   │   │   ├── ── Port exposure ──
│   │   │   │   └── [installed cts with ports...]
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   └── QRencode  →  qrencode_menu()  [proxy_menu.py]
│   │       ├── [if installed]   Update / Uninstall
│   │       └── [if not]         Install
│   │
│   ├── ── Tools ──
│   │   ├── Active processes  →  ABSENT in Python (_active_processes_menu not implemented)
│   │   │   NOTE: bash has full session list with CPU/RAM/PID and kill action
│   │   ├── Resource limits  →  resources_menu()  [resources_menu.py]
│   │   │   ├── ── Containers ──
│   │   │   │   └── [ct entries  name  [cgroups on]]
│   │   │   └── [per-ct click]  →  per-container submenu
│   │   │       ├── ── Configuration ──
│   │   │       │   ├── ● Enabled / ○ Disabled   (toggle)
│   │   │       │   ├── CPU quota    value
│   │   │       │   ├── Memory max   value
│   │   │       │   ├── Memory+swap  value
│   │   │       │   └── CPU weight   value
│   │   │       ├── ── Info ──
│   │   │       │   ├── GPU/VRAM     not configurable
│   │   │       │   └── Network      not configurable
│   │   │       └── ── Navigation ──
│   │   │           └── Back
│   │   └── Blueprint preset  (read-only viewer)
│   │
│   ├── ── Caution ──
│   │   ├── View logs  →  logs_browser()  [logs_menu.py]
│   │   │   └── [log files list]  →  file viewer (read-only)
│   │   ├── Clear cache
│   │   ├── Resize image
│   │   ├── Manage Encryption  →  enc_menu()  [enc_menu.py]
│   │   │   ├── ── General ──
│   │   │   │   ├── System Agnostic  [Enabled/Disabled]
│   │   │   │   ├── Auto-Unlock      [Enabled/Disabled]
│   │   │   │   └── Reset Auth Token
│   │   │   ├── ── Verified Systems ──
│   │   │   │   └── [vs entries  hostname  [vs:id]]
│   │   │   │   └── + Verify this system
│   │   │   ├── ── Passkeys ──
│   │   │   │   └── [key entries  name  [s:slot]]
│   │   │   │       [per-key click]  →  submenu
│   │   │   │           ├── Rename
│   │   │   │           ├── Remove
│   │   │   │           └── Cancel
│   │   │   │   └── + Add Key
│   │   │   └── ── Navigation ──
│   │   │       └── Back
│   │   └── × Delete image file
│   │
│   └── ── Navigation ──
│       └── Back
│
└── × Quit  →  _quit_menu()  [main_menu.py]
    ├── Detach
    └── Stop all & quit
```

---

---

## Discrepancies: Bash vs Python

### MISSING in Python (present in bash)

1. **`_active_processes_menu`** — Entire menu absent. Bash shows all tmux sessions
   (containers, install, resize, term, action) with CPU/RAM/PID stats; click kills.
   Python `_help_menu` references it in the items list but there is no implementation.

2. **`_manage_backups_menu`** — Referenced from `_help_menu` "Backups" item but not
   implemented in `main_menu.py`. Bash shows a container picker then delegates to
   `_container_backups_menu`. Python `_help_menu` has the "Backups" item but it goes
   nowhere.

3. **`⬆ Updates` section in `container_submenu` (installed/stopped state)** — Bash
   builds `_UPD_ITEMS` via `_build_update_items`, `_build_ubuntu_update_item`,
   `_build_pkg_update_item`, shows yellow `⬆ Updates` label if pending, opens a
   submenu listing blueprint/ubuntu/pkg update options. Python has no update detection,
   no update items, and no `⬆ Updates` entry in the installed-stopped state branch.

4. **QR code in `open_in_submenu`** — Bash shows `⊞ Show QR code` option if port is
   set and qrencode is available. Python `open_in_submenu` builds items but the QR
   code branch is not present.

5. **Storage profile actions differ** — Bash per-profile submenu: `★ Set as default` /
   `☆ Unset default`, Rename, Delete. Python (`_storage_profile_submenu`) shows:
   Link to container, Unlink, Rename, Delete — a different action model.

6. **Export/Import via file picker** — Bash uses `_yazi_pick` / `_pick_dir` for
   interactive file/directory selection. Python replaces this with plain `finput` text
   input for path entry (no interactive picker).

### EXTRA in Python (not in bash)

1. **`Rename` in installed-stopped state** — Python adds Rename to the
   installed-stopped branch. Bash only allows Rename in the not-installed state.

2. **`◦ Clone container` in installed-stopped state** — Python adds this inline to the
   installed-stopped branch. Bash places cloning exclusively through the
   `_install_method_menu` "Clone existing container" section.

3. **`── Management ──` section with Port exposure in installed-stopped state** —
   Python adds a Management section with the exposure toggle inline in the container
   submenu. Bash exposes this only via the proxy menu or port exposure menu; the
   installed-stopped branch in bash has no inline exposure toggle.

4. **`+ New blueprint` in `blueprints_submenu`** — Python adds an inline "New
   blueprint" entry with a text input. Bash does not have inline blueprint creation
   inside the blueprints list; creation is in settings.

5. **`── Settings ──` section in `blueprints_submenu`** — Python adds an explicit
   "Settings" entry leading to `_blueprints_settings_menu`. Bash reaches settings
   differently (through `_help_menu → Blueprints`).

### STRUCTURAL DIFFERENCES

- **`container_submenu` installed-stopped branch** — Bash does not include `Rename`
  (only in not-installed). Python includes it in both states.

- **`_blueprints_settings_menu` Add path** — Bash uses `yazi --chooser-file` for
  interactive directory selection. Python uses plain `finput` text input.

- **`_help_menu` "Active processes" item** — Present in both item lists but Python
  has no target function. Selecting it silently does nothing (no implementation).

- **`container_submenu` General section header** — Bash always adds `── General ──`
  as the first item in all state branches. Python omits this section header entirely
  (items list starts directly with the first action).
```
