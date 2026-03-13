# simpleDocker Python Rewrite — AI Handoff Document

> **For any AI continuing work on this project.**  
> Read this entire file before touching any code.

---

## What is this?

A complete Python rewrite of `services.sh` — a 7,627-line Bash script that implements a custom Docker-like container manager called **simpleDocker**. The original script lives at the path the user specified; the rewrite is in the `simpledocker/` directory next to this file.

**Target:** Single binary via PyInstaller `--onefile`, runs on **Arch Linux** (and Ubuntu/Debian too).

**Status:** All 22 Python modules import with 0 errors. Not yet tested end-to-end at runtime.

---

## What the original script does

simpleDocker is a full container management system built on top of:

| Mechanism | Purpose |
|---|---|
| **BTRFS image files** | Container storage (loop-mounted `.img` files) |
| **LUKS encryption** | Optional full-image encryption |
| **chroot** | Container isolation (not real namespaces — chroot + netns) |
| **Linux network namespaces** | Per-container networking with veth pairs + bridge |
| **tmux sessions** | Container "runtime" — each container runs in a named tmux session |
| **fzf** | All UI interaction — every menu is fzf |
| **Caddy** | Reverse proxy for containers with ports |
| **avahi-publish / dnsmasq** | mDNS `.local` hostname resolution |
| **iptables** | Port exposure control (isolated / localhost / public) |
| **systemd-run / cgroups** | CPU + memory resource limits |
| **BTRFS snapshots** | Backups |
| **Blueprint format** | `.container` / `.toml` files describe services |

---

## Directory structure

```
simpledocker/
├── main.py                    ← entry point (arg parse, tmux ensure, dep check, main_menu)
├── simpledocker.spec          ← PyInstaller build spec
├── build.sh                   ← one-command build: ./build.sh → dist/simpledocker
├── README.md                  ← end-user instructions
├── cli/
│   ├── __init__.py
│   └── app.py                 ← AppContext class, setup(), teardown(), pick_or_create_image()
├── functions/
│   ├── __init__.py
│   ├── constants.py           ← paths, ANSI colors, keybindings, LUKS consts, FZF_BASE
│   ├── utils.py               ← run/sudo_run wrappers, tmux helpers, state_get/set, logging
│   ├── tui.py                 ← fzf(), confirm(), pause(), finput(), menu() — ALL UI
│   ├── image.py               ← BTRFS image create/mount/umount, LUKS open/close
│   ├── blueprint.py           ← .container parser, bp_compile_to_json(), compile_service()
│   ├── network.py             ← netns_setup/teardown, veth, exposure_get/set/apply (iptables)
│   ├── container.py           ← start_container(), stop_container(), cron, groups, snapshots
│   ├── storage.py             ← persistent storage profiles (symlink management)
│   └── installer.py           ← generates bash install/update scripts, launches in tmux
└── menu/
    ├── __init__.py
    ├── main_menu.py           ← top-level fzf TUI loop
    ├── container_menu.py      ← all per-container actions (start/stop/install/etc)
    ├── backup_menu.py         ← BTRFS snapshot backups
    ├── storage_menu.py        ← persistent storage profile management
    ├── group_menu.py          ← container groups with start sequences
    ├── enc_menu.py            ← LUKS key slots, verified systems, auto-unlock, passkeys
    ├── proxy_menu.py          ← Caddy install, routes, mDNS, port exposure per container
    ├── ubuntu_menu.py         ← apt install/remove inside Ubuntu chroot
    ├── logs_menu.py           ← log file browser (fzf scrollable viewer)
    ├── resources_menu.py      ← CPU/memory cgroup limits via systemd-run
    └── port_exposure_menu.py  ← standalone iptables port exposure menu
```

---

## AppContext — the central object

`cli/app.py` defines `AppContext`. It is **passed as `ctx` to every menu function**.

```python
ctx.img_path          # str  — /path/to/image.img
ctx.mnt_dir           # str  — mount point, e.g. /run/user/1000/simpleDocker/mnt_myimage
ctx.blueprints_dir    # str  — ctx.mnt_dir/Blueprints
ctx.containers_dir    # str  — ctx.mnt_dir/Containers
ctx.installations_dir # str  — ctx.mnt_dir/Installations
ctx.backup_dir        # str  — ctx.mnt_dir/Backup
ctx.storage_dir       # str  — ctx.mnt_dir/Storage
ctx.ubuntu_dir        # str  — ctx.mnt_dir/Ubuntu  (Ubuntu 24.04 Noble chroot)
ctx.groups_dir        # str  — ctx.mnt_dir/Groups
ctx.logs_dir          # str  — ctx.mnt_dir/Logs
ctx.cache_dir         # str  — ctx.mnt_dir/.cache
ctx.tmp_dir           # str  — SD_MNT_BASE/.tmp
```

---

## Key design patterns

### fzf is the only UI
Every menu goes through `functions/tui.py`:
```python
rc, lines = fzf(items, "--header", "title")   # returns (returncode, [selected_lines])
confirm("Are you sure?")                       # → bool
pause("message shown in fzf")                 # blocks until user presses Enter/Esc
finput("Enter name:")                          # sets tui.FINPUT_RESULT global, returns bool
```

### Module-level globals in tui.py
```python
tui.REPLY          # int   — last menu() selection index
tui.FINPUT_RESULT  # str   — last finput() result
tui._FZF_PID       # int   — PID of current fzf process (for SIGUSR1 interrupt)
tui._USR1_FIRED    # bool  — set True when SIGUSR1 received
```

### SIGUSR1 pattern
The installer uses SIGUSR1 to wake the UI when an install finishes:
1. `run_job()` in `installer.py` writes a hook script that sends `kill -USR1 $PPID` on completion.
2. `main.py` sets up `signal.signal(signal.SIGUSR1, _usr1_handler)`.
3. The handler sets `tui._USR1_FIRED = True` and kills the current fzf PID.
4. Menus check `sig_rc(rc)` after fzf calls — if True, they re-enter the loop to refresh.

### Container state is JSON
Each container lives at `containers_dir/<cid>/service.json`:
```json
{
  "meta":        { "name": "myapp", "port": "8080" },
  "environment": { "MY_VAR": "value" },
  "state":       { "installed": "true" },
  "storage":     { "type": "myapp" }
}
```
Read with `utils.read_json()`, write with `utils.write_json()`.

### Install scripts are bash
`installer.py` generates a full bash script and launches it in a tmux session named `sdInst_<cid>`. Python only orchestrates; the actual install/update happens in bash inside the chroot.

### Blueprint format
`.container` files use a custom TOML-like format with sections:
```
[container]
name = myapp
port = 8080

[meta]
...

[deps]
nodejs, git

[start]
node server.js

[/container]
```
Parsed by `blueprint.py:bp_parse()` → compiled to `service.json`.

---

## Runtime dependencies (Arch Linux)

```bash
sudo pacman -S --needed \
    btrfs-progs \
    tmux \
    fzf \
    cryptsetup \
    iproute2 \
    iptables \
    openbsd-netcat \
    python \
    python-pip \
    yazi

# avahi (for mDNS, optional — only needed for Caddy proxy feature):
sudo pacman -S --needed avahi nss-mdns
sudo systemctl enable --now avahi-daemon
```

**Note:** The containers themselves run Ubuntu 24.04 Noble inside chroot. The host only needs the above. `apt-get` runs *inside* the chroot, not on the host.

---

## Building the binary (Arch Linux)

```bash
cd ~/Downloads/simpledocker/   # or wherever you extracted it

# Install PyInstaller
pip install pyinstaller --break-system-packages

# Build
python -m PyInstaller simpledocker.spec --noconfirm

# Binary is at:
./dist/simpledocker
```

Or just run from source without building:
```bash
python main.py
```

---

## Known issues / things NOT yet tested

1. **End-to-end runtime** — imports are all clean but the code has not been run against a real BTRFS image yet. Expect minor bugs on first real run.

2. **`shutil.quote` usage** — `proxy_menu.py` has a leftover stub `shutil_quote()` function that does nothing useful. Real path quoting should use `shlex.quote()`. Search for `shutil_quote` and replace if you see shell injection issues.

3. **`tsess()` import in proxy_menu.py** — `proxy_menu.py` imports `tsess` from `functions.container` but `tsess` is defined as a local function there. If you get an ImportError at runtime, either export it or inline the logic: `f"sd_{cid[:12]}"`.

4. **`update_size_cache` signature** — called in `main.py` as `update_size_cache(ctx.containers_dir)` — verify this matches the signature in `container.py`.

5. **`netns_ct_ip` vs `netns_ct_ip(cid, mnt_dir)` vs `netns_ct_ip(cid, ctx.mnt_dir)`** — double-check all call sites match the function signature in `network.py`.

6. **Arch Linux: `ncat` vs `nc`** — health checks in `container.py` use `nc`. On Arch the package is `openbsd-netcat` and the binary is `nc`. Verify the check_deps list in `utils.py` uses `nc` not `ncat`.

7. **`dnsmasq` on Arch** — `proxy_menu.py` tries to install `dnsmasq` via `apt-get`. On Arch this needs to be `pacman -S dnsmasq`. The proxy feature will fail to set up DNS on Arch unless this is fixed. The mDNS part (avahi) is fine.

8. **`/usr/sbin/update-ca-certificates`** — called in `proxy_menu._trust_ca()`. On Arch this is `update-ca-trust` (from `ca-certificates` package), not `update-ca-certificates`. Fix the call in `proxy_menu.py` for Arch.

---

## How to continue work

### Fixing a specific bug
1. Find the function using the directory structure above.
2. Check the original `services.sh` for the bash equivalent — bash functions are named similarly (e.g., `_start_container` → `start_container`, `_proxy_menu` → `proxy_menu`).
3. The bash script is in the same directory as this file (original `services.sh`).

### Running import checks
```bash
cd simpledocker/
python3 -c "
import sys; sys.path.insert(0,'.')
for m in ['functions.constants','functions.utils','functions.tui',
          'functions.image','functions.blueprint','functions.network',
          'functions.container','functions.storage','functions.installer',
          'menu.backup_menu','menu.container_menu','menu.enc_menu',
          'menu.group_menu','menu.logs_menu','menu.main_menu',
          'menu.port_exposure_menu','menu.proxy_menu','menu.resources_menu',
          'menu.storage_menu','menu.ubuntu_menu','cli.app','main']:
    try: __import__(m); print(f'OK  {m}')
    except Exception as e: print(f'FAIL {m}: {e}')
"
```

### Testing without a real image
The TUI code can be exercised in a tmux session without a mounted image by mocking AppContext:
```python
class FakeCtx:
    img_path = "/tmp/test.img"
    mnt_dir = "/tmp/fake_mnt"
    containers_dir = "/tmp/fake_mnt/Containers"
    blueprints_dir = "/tmp/fake_mnt/Blueprints"
    installations_dir = "/tmp/fake_mnt/Installations"
    backup_dir = "/tmp/fake_mnt/Backup"
    storage_dir = "/tmp/fake_mnt/Storage"
    ubuntu_dir = "/tmp/fake_mnt/Ubuntu"
    groups_dir = "/tmp/fake_mnt/Groups"
    logs_dir = "/tmp/fake_mnt/Logs"
    cache_dir = "/tmp/fake_mnt/.cache"
    tmp_dir = "/tmp"
import os; os.makedirs("/tmp/fake_mnt/Containers", exist_ok=True)
from menu.main_menu import main_menu
main_menu(FakeCtx())
```

---

## Line count summary

| File | Lines |
|---|---|
| functions/container.py | 646 |
| functions/installer.py | 626 |
| menu/main_menu.py | 708 |
| menu/container_menu.py | 529 |
| menu/proxy_menu.py | 576 |
| functions/blueprint.py | 497 |
| menu/enc_menu.py | 345 |
| functions/image.py | 354 |
| functions/utils.py | 335 |
| functions/network.py | 227 |
| functions/storage.py | 285 |
| functions/tui.py | 200 |
| functions/constants.py | 133 |
| menu/backup_menu.py | 113 |
| menu/group_menu.py | 124 |
| menu/storage_menu.py | 77 |
| menu/ubuntu_menu.py | 75 |
| menu/resources_menu.py | 104 |
| menu/port_exposure_menu.py | 44 |
| menu/logs_menu.py | 49 |
| cli/app.py | 230 |
| main.py | 90 |
| **Total** | **~6,200** |

Original bash: **7,627 lines**
