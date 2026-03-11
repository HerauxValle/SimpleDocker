# simpleDocker

> Native container orchestrator for Linux. No Docker, no daemons — BTRFS images, Ubuntu chroots, tmux sessions.

---

## Table of Contents

- [Overview](#overview)
- [Requirements](#requirements)
- [Installation](#installation)
- [First Launch](#first-launch)
- [Core Concepts](#core-concepts)
  - [The Image](#the-image)
  - [Containers](#containers)
  - [Blueprints](#blueprints)
  - [Groups](#groups)
- [Navigation](#navigation)
  - [Main Menu](#main-menu)
  - [Keyboard Shortcuts](#keyboard-shortcuts)
- [Container Lifecycle](#container-lifecycle)
  - [Uninstalled State](#uninstalled-state)
  - [Installed / Stopped State](#installed--stopped-state)
  - [Running State](#running-state)
  - [Installing State](#installing-state)
- [Blueprint DSL Reference](#blueprint-dsl-reference)
  - [File Structure](#file-structure)
  - [[meta]](#meta)
  - [[env]](#env)
  - [[storage]](#storage)
  - [[deps]](#deps)
  - [[dirs]](#dirs)
  - [[pip]](#pip)
  - [[npm]](#npm)
  - [[git]](#git)
  - [[build]](#build)
  - [[install]](#install)
  - [[update]](#update)
  - [[start]](#start)
  - [[cron]](#cron)
  - [[actions]](#actions)
- [The Blueprints Menu](#the-blueprints-menu)
  - [File Blueprints](#file-blueprints)
  - [Persistent (Built-in) Blueprints](#persistent-built-in-blueprints)
  - [Imported Blueprints](#imported-blueprints)
  - [Blueprint Autodetect](#blueprint-autodetect)
- [Storage & Persistence](#storage--persistence)
  - [Storage Profiles](#storage-profiles)
  - [Backups](#backups)
- [Networking](#networking)
  - [Port Exposure](#port-exposure)
  - [Reverse Proxy (Caddy)](#reverse-proxy-caddy)
  - [mDNS / QR Codes](#mdns--qr-codes)
- [The Other Menu](#the-other-menu)
  - [Ubuntu Base](#ubuntu-base)
  - [Active Processes](#active-processes)
  - [Resource Limits](#resource-limits)
  - [Image Encryption (LUKS2)](#image-encryption-luks2)
  - [Resize Image](#resize-image)
- [Configuration](#configuration)
- [Example Blueprint — Full](#example-blueprint--full)
- [Troubleshooting](#troubleshooting)

---

## Overview

simpleDocker is a single bash script that orchestrates services in isolated Linux namespaces. Instead of a container daemon, it uses:

- **BTRFS images** — a `.img` file mounted as a loop device. Everything lives inside it: containers, blueprints, storage, backups.
- **BTRFS subvolumes** — each installed container gets its own subvolume under `/Installations/`, making snapshots and backups instant and space-efficient.
- **Ubuntu chroot** — a shared Ubuntu 24.04 minirootfs inside the image that all containers use as their base system. Packages you install with `[deps]` go here.
- **Linux namespaces** — `unshare` creates isolated network, PID, and mount namespaces per container.
- **tmux sessions** — every running container is a named tmux session. You can attach/detach freely.
- **fzf UI** — the entire interface is driven by `fzf` in the terminal.

---

## Requirements

| Tool | Purpose |
|------|---------|
| `fzf` | UI rendering |
| `tmux` | Session management |
| `btrfs-progs` | Image and subvolume management |
| `jq` | JSON parsing |
| `yazi` | File picker |
| `sudo` | Mount, chroot, namespace operations |
| `curl` | Downloading Ubuntu base and release assets |
| `ip` / `iproute2` | Network namespace management |

simpleDocker will detect any missing tools on first launch and offer to install them automatically.

---

## Installation

```bash
# Download the script
curl -o services.sh https://your-host/services.sh
chmod +x services.sh

# Optional: put it on your PATH
cp services.sh ~/.local/bin/services
```

> **Tip:** Set `DEFAULT_IMG` at the top of the script to a `.img` path to skip the image picker on every launch.

---

## First Launch

On first run, simpleDocker needs an **image file** to work with. It will:

1. Scan `$HOME` (up to 4 levels deep) for any BTRFS `.img` files and show them as **Detected images**.
2. Offer **Select existing image** — opens `yazi` to pick any `.img` anywhere.
3. Offer **Create new image** — creates a new blank BTRFS image at a location you choose.

After an image is selected it gets mounted and all container data lives inside it. The image path and used/total GB are shown in the main menu header.

---

## Core Concepts

### The Image

The `.img` file is a BTRFS filesystem in a file. Its internal structure:

```
/Blueprints/        — your .toml blueprint files
/Containers/        — state.json + service config per container
/Installations/     — one BTRFS subvolume per installed container
/Groups/            — group definitions
/Storage/           — persistent storage profiles (symlinked into containers)
/Backup/            — BTRFS snapshots
/.cache/            — size cache, GitHub tag cache
/.sd/               — internal config (proxy, network hosts, etc.)
```

Everything is self-contained — copy the `.img` to another machine and it works identically.

### Containers

A **container** is an isolated service instance. It has:

- A **name** and unique internal ID
- A **blueprint** — the recipe that defines how it installs and runs
- An **installation** — a BTRFS subvolume at `/Installations/<id>/` containing the actual files
- A **state** — uninstalled, installing, installed/stopped, or running

Containers run inside Linux namespaces (isolated network, PID, mounts) with a Ubuntu chroot as their filesystem root. The container's files live at `$CONTAINER_ROOT`, which is the path to its subvolume.

### Blueprints

A **blueprint** is a `.toml`-like DSL file that describes a service: what packages to install, what to download, how to start, what cron jobs to run, etc. Blueprints come in three kinds:

- **File blueprints** — `.toml` files you create inside the image via the Blueprints menu
- **Persistent blueprints** — baked directly into the `services.sh` script (Counter, N8N, Ollama, etc.)
- **Imported blueprints** — `.container` files auto-discovered on your host filesystem

### Groups

A **group** lets you start and stop multiple containers together. You can assign any containers to a group and manage them as a unit from the Groups menu.

---

## Navigation

### Main Menu

```
◈  Containers          2 running/3
▶  Groups              1 active/2
◈  Blueprints          5
─────────────────────────────────
?  Other
×  Quit
```

- **Containers** — list of all containers and their status
- **Groups** — manage container groups
- **Blueprints** — view, create, and edit blueprint files
- **Other** — system tools, plugins, settings
- **Quit** — stop all running containers and exit, or just exit

The header shows the current image filename and `[used/total GB]`.

### Keyboard Shortcuts

| Key | Action |
|-----|--------|
| `ctrl-d` | Detach from current tmux session back to simpleDocker |
| `ctrl-q` | Quit simpleDocker |
| `ctrl-\` | Detach inside a tmux session (standard tmux detach) |
| `ESC` | Go back / cancel |
| `Enter` | Select |

All shortcuts are configurable at the top of the script in the `KB` array.

---

## Container Lifecycle

Selecting a container from the Containers list opens its submenu. What you see depends on its current state.

### Uninstalled State

The container exists but has no files installed yet.

| Option | Description |
|--------|-------------|
| `↓  Install` | Run the full install process in a background tmux session |
| `◦  Edit toml` | Open the blueprint in `$EDITOR` |
| `✎  Rename` | Rename the container |
| `×  Remove` | Permanently delete the container record (not the blueprint) |

### Installed / Stopped State

The container is installed and its files exist, but it isn't running.

| Option | Description |
|--------|-------------|
| `▶  Start` | Start the container in a background tmux session |
| `⊕  Open in` | Open browser, file manager, or terminal for this container |
| `◈  Backups` | Manage BTRFS snapshots of this container |
| `◧  Profiles` | Attach/detach persistent storage profiles |
| `◦  Edit toml` | Edit the blueprint |
| `⬆  Updates` | Shows available updates (highlighted yellow if pending) |
| `○  Uninstall` | Delete the installation subvolume (keeps the container record) |

### Running State

The container's start script is active in a tmux session.

| Option | Description |
|--------|-------------|
| `■  Stop` | Send interrupt to the tmux session and stop the container |
| `↺  Restart` | Stop then immediately start again |
| `→  Attach` | Switch into the container's tmux session |
| `⊕  Open in` | Browser / File manager / Terminal |
| `≡  View log` | Tail the container's log file |
| `── Actions ──` | Custom actions defined in the blueprint's `[actions]` section |
| `── Cron ──` | Live cron jobs — click one to attach to its tmux session |

The status dot in the header changes colour:
- 🟢 Green — running and healthy (port responds)
- 🟡 Yellow — running but health check failing, or installing
- 🔴 Red — installed but stopped
- ⬜ Dim — not installed

### Installing State

When installation is in progress a background tmux session is running the install script.

| Option | Description |
|--------|-------------|
| `→  Attach to installation` | Watch the install output live |
| `✓  Finish installation` | Appears when done — confirms and cleans up |
| `×  Kill installation` | Abort a running install |

---

## Blueprint DSL Reference

### File Structure

Every blueprint is wrapped in a `[container]` block:

```toml
[container]

[meta]
name = my-service
...

[env]
PORT = 8080

[start]
exec bin/my-service --port 8080

[/container]
```

Sections are started with `[section-name]` and end when the next section begins. `# comments` work everywhere outside bash blocks. The `[/container]` closes the blueprint.

---

### [meta]

Defines service identity and runtime behaviour.

```toml
[meta]
name         = my-service          # internal name (used for directories, IDs)
version      = 1.0.0               # version string (used for update detection)
dialogue     = Short description   # shown next to the name in the container list
description  = Longer notes        # shown in detail views
port         = 8080                # primary port (used for health checks, browser open, proxy)
storage_type = my-service          # storage profile key (links persistent data)
entrypoint   = bin/my-service      # process started by the container runner
log          = logs/service.log    # log file shown by View log (default: start.log)
health       = true                # enable TCP health check on port (green/yellow dot)
gpu          = nvidia              # pass GPU into container: nvidia | amd | cuda_auto
cap_drop     = true                # drop Linux capabilities for isolation (default: true)
seccomp      = true                # apply seccomp syscall filter (default: true)
```

All fields are optional except `name`.

---

### [env]

Environment variables exported into the container at runtime.

```toml
[env]
PORT             = 8080
HOST             = 0.0.0.0
DATA_DIR         = data
API_KEY          = my-secret
N8N_ENCRYPTION_KEY = generate:hex32
LD_LIBRARY_PATH  = lib/ollama
```

**Auto-prefix:** Relative paths (not starting with `/` or `~`) are automatically prefixed with `$CONTAINER_ROOT/` at runtime. So `DATA_DIR = data` becomes `DATA_DIR = /path/to/installation/data`.

**`generate:hex32`:** A special value that generates a random 32-byte hex secret at container start. Use this for encryption keys, secrets, etc. The value is stable within a session but regenerated on reinstall unless stored in a persistent location.

**`LD_LIBRARY_PATH` / `LIBRARY_PATH` / `PKG_CONFIG_PATH`:** These are appended to any existing system value rather than overwritten.

---

### [storage]

Paths inside `$CONTAINER_ROOT` that persist across reinstalls. These directories are kept in a shared storage profile and symlinked back in after every reinstall.

```toml
[storage]
data, logs, models
```

Each path listed here will be preserved even if you uninstall and reinstall the container. Storage is managed via **Storage Profiles** (see [Storage & Persistence](#storage--persistence)).

---

### [deps]

APT packages to install into the Ubuntu chroot. These are available to all containers sharing the same Ubuntu base.

```toml
[deps]
curl, git, nodejs, python3
```

Packages are installed with `apt-get install -y` inside the Ubuntu chroot during the install process.

---

### [dirs]

Directories to create inside `$CONTAINER_ROOT`. Supports nested syntax.

```toml
[dirs]
bin, data, logs, lib(ollama), models(checkpoints, adapters)
```

- Simple: `bin, data, logs` → creates `bin/`, `data/`, `logs/`
- Nested: `lib(ollama)` → creates `lib/ollama/`
- Deep nested: `models(checkpoints, adapters)` → creates `models/checkpoints/` and `models/adapters/`

---

### [pip]

Python packages installed into `$CONTAINER_ROOT/venv` using pip.

```toml
[pip]
torch torchvision torchaudio --extra-index-url https://download.pytorch.org/whl/cu124
requests==2.31.0
flask
```

A virtualenv is created automatically at `$CONTAINER_ROOT/venv` if it doesn't exist. Full pip syntax is supported including `--extra-index-url`, version pins, etc.

---

### [npm]

Node packages installed into `$CONTAINER_ROOT/node_modules`.

```toml
[npm]
n8n
express@4.18.2
```

Requires `nodejs` in `[deps]`. The `node_modules/.bin/` directory is added to `PATH`.

---

### [git]

Download or clone GitHub repositories. Multiple lines supported.

```toml
[git]
# Auto-detect latest release binary/tarball, extract to CONTAINER_ROOT
ollama/ollama → .

# Match a specific release asset filename
owner/repo [my-asset-linux-amd64.tar.gz] → bin/

# Clone source code into src/
comfyanonymous/ComfyUI source → .

# Clone into a subdirectory
ltdrdata/ComfyUI-Manager source → custom_nodes/ComfyUI-Manager
```

**Modes:**

| Syntax | Behaviour |
|--------|-----------|
| `org/repo` | Auto-detect binary or tarball from latest release, extract to `CONTAINER_ROOT` |
| `org/repo [asset.tar.gz]` | Match exact asset filename from release |
| `org/repo → subdir/` | Extract release asset into a subdirectory |
| `org/repo source` | `git clone` the repository (not a release) into `src/` |
| `org/repo source → path/` | Clone into a specific path |

GitHub release assets are cached by tag — updates are detected when the tag changes.

---

### [build]

Bash commands run **once during install**, after git clones but before `[install]`. Use this for compilation steps.

```toml
[build]
cd src && make
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel
```

Runs inside the container's namespace with `$CONTAINER_ROOT` available.

---

### [install]

Bash commands run **once during install**, after deps, dirs, pip, npm, git, and build. Use this for any remaining setup.

```toml
[install]
venv/bin/pip install -r src/requirements.txt
mkdir -p data/db
cp src/config.example.json data/config.json
```

---

### [update]

Bash commands run when **Update** is manually triggered from the stopped container menu. Use this to pull new model files, refresh configs, etc.

```toml
[update]
bin/ollama pull llama3.2
venv/bin/pip install --upgrade my-package
```

> The `[git]` section is always re-run on update if a newer release tag is detected. `[update]` is your custom hook that runs after that.

---

### [start]

The main process script. This runs **every time the container starts**, inside its Linux namespace and chroot.

```toml
[start]
exec bin/my-service \
    --port "$PORT" \
    --data "$DATA_DIR" \
    --host "$HOST"
```

`$CONTAINER_ROOT` is always available and points to the installation directory. All `[env]` variables are exported before this runs. Use `exec` for the main process so it becomes PID 1 and receives signals correctly.

---

### [cron]

Scheduled commands that run on a timer while the container is running.

```toml
[cron]
30s [heartbeat]           | printf '[cron] alive at %s\n' "$(date '+%H:%M:%S')" >> logs/cron.log
5m  [backup]   --sudo     | rsync -a data/ /mnt/backup/
1h  [cleanup]  --unjailed | find /tmp -mtime +1 -delete
```

**Format:** `interval [name] [flags] | command`

| Part | Description |
|------|-------------|
| `interval` | `Ns`, `Nm`, or `Nh` — e.g. `30s`, `5m`, `1h` |
| `[name]` | Display name shown in the container menu |
| `--sudo` | Wrap the command with `sudo` |
| `--unjailed` | Run on the host instead of inside the container namespace |
| `command` | Any bash command |

Each cron job runs in its own tmux session. You can attach to a running cron by clicking it in the container menu. Relative paths in cron commands (e.g. `>> logs/file.log`) are automatically prefixed with the container root.

---

### [actions]

Custom one-click commands shown in the container menu when it's **running**.

```toml
[actions]
Show logs      | tail -f logs/service.log
Reset database | confirm "Really reset?" | rm -rf data/db && mkdir -p data/db
Pull model     | prompt: "Model name:" | bin/ollama pull {input}
Remove model   | select: bin/ollama list --skip-header --col 1 | bin/ollama rm {selection}
```

**Format:** `Label | [modifiers |] command`

Labels starting with a plain letter automatically get a `⊙` prefix icon. Labels starting with a symbol are used as-is.

**Modifiers:**

| Modifier | Description |
|----------|-------------|
| `prompt: "text"` | Show a text input prompt; value available as `{input}` in the command |
| `select: cmd` | Run `cmd` and show its output in an fzf picker; selected line available as `{selection}` |
| `select: cmd --skip-header` | Skip the first line of `cmd` output (e.g. column headers) |
| `select: cmd --col N` | Use column N of the selected line as `{selection}` |

---

## The Blueprints Menu

Access via **Main Menu → Blueprints**.

### File Blueprints

`.toml` files stored inside the image at `/Blueprints/`. Created and edited from this menu.

- **New blueprint** — prompts for a name, creates a pre-filled template `.toml`
- Select any blueprint to open its submenu: **Edit**, **Rename**, **Delete**, or **Create container from this blueprint**

### Persistent (Built-in) Blueprints

These are baked into the `services.sh` script itself inside a `SD_PERSISTENT_END` heredoc. They appear in the Blueprints list tagged `[Persistent]` and are read-only — edit them directly in the script source. Built-in blueprints include Counter, N8N, Ollama, OpenWebUI, ComfyUI.

### Imported Blueprints

`.container` files automatically discovered on your host filesystem. They appear tagged `[Imported]` and are read-only from within simpleDocker. To use one, create a container from it.

### Blueprint Autodetect

Configure where simpleDocker searches for `.container` files via **Other → Blueprints → Autodetect**:

| Mode | Scope |
|------|-------|
| `Home` | `$HOME`, max depth 6, skips hidden dirs (default) |
| `Root` | `/`, max depth 8 |
| `Everywhere` | Full filesystem |
| `Custom` | Paths you specify manually |
| `Disabled` | No autodetect |

---

## Storage & Persistence

### Storage Profiles

Persistent storage lives outside the container's installation subvolume. When a container is reinstalled, its storage profile is relinked automatically.

The `storage_type` field in `[meta]` is the key that links a container to a storage profile. Multiple containers sharing the same `storage_type` share the same persistent data.

**Access via:** Container menu → Profiles, or Other → Profiles & data

You can:
- Create named storage profiles manually
- Link/unlink profiles to containers
- Export a profile as a `.tar.zst` archive
- Import a previously exported archive

### Backups

Each container's installation subvolume can be snapshotted instantly using BTRFS.

**Access via:** Container menu (stopped) → Backups

- **Create backup** — prompts for a name, takes a BTRFS snapshot in seconds regardless of size
- **Restore** — roll back the container to any snapshot
- **Delete** — remove a specific snapshot
- **Clone from backup** — create a new independent container from any snapshot

---

## Networking

### Port Exposure

Each container has an **exposure level** that controls network access to its port.

| Level | Description |
|-------|-------------|
| `isolated` | Port is not accessible from outside the container namespace (default) |
| `localhost` | Port is forwarded to `localhost` on the host |
| `public` | Port is routed through the reverse proxy and accessible on the LAN |

Configure via **Container menu → Open in → exposure**, or through the **Other → Caddy** reverse proxy menu.

### Reverse Proxy (Caddy)

simpleDocker can run a Caddy instance inside the Ubuntu base to proxy containers.

**Access via:** Other → Caddy

Features:
- Automatic HTTPS with self-signed CA (trust it in your browser once)
- Routes containers to `http(s)://containername.local` via mDNS
- Per-container routes managed from the proxy menu
- Caddy config is stored inside the image at `.sd/Caddyfile`

### mDNS / QR Codes

When a container is set to `public` exposure and the Caddy proxy is running:

- The container is accessible at `http://containername.local` on your LAN
- **Open in → Show QR code** generates a terminal QR code you can scan from any device on the network

Requires `qrencode` installed (manage via **Other → QRencode**).

---

## The Other Menu

Access via **Main Menu → Other**.

### Ubuntu Base

The shared Ubuntu 24.04 minirootfs all containers use. Manage it here:

- Install / reinstall the base
- Update installed system packages
- Add or remove packages from the default set

Status shown in the header: `ready [P]` (installed and pinned) or `not installed`.

### Active Processes

Shows all currently running tmux sessions managed by simpleDocker — containers, installs, cron jobs. Select any to attach or kill it.

### Resource Limits

Set CPU and memory limits per container using `systemd-run` cgroups.

- CPU quota (percentage)
- Memory limit (MB)
- Applied on next container start

### Image Encryption (LUKS2)

Encrypt your `.img` file with LUKS2 so the data is protected at rest.

**Access via:** Other → Image encryption

- **Encrypt image** — wraps the existing image in a LUKS2 container; requires a passphrase on every mount
- **Add key** — add additional passphrases or keyfiles
- **Remove key** — revoke a passphrase slot
- **Remove encryption** — decrypt and restore a plain image

### Resize Image

Grow the `.img` file and expand the BTRFS filesystem to use the new space.

**Access via:** Other → Resize image

Enter the new size in GB. The image is unmounted, resized with `truncate`, and the BTRFS filesystem is expanded with `btrfs filesystem resize`.

---

## Configuration

At the top of `services.sh`:

```bash
# ── Basic ─────────────────────────────────────────────────────────
DEFAULT_IMG=""                # auto-mount this .img on launch (skip picker)
DEFAULT_UBUNTU_PKGS="..."     # packages always present in the Ubuntu base
ROOT_DIR="$HOME/.config/simpleDocker"  # where image list and config are stored

declare -A KB=(
    [detach]="ctrl-d"         # detach from tmux session
    [quit]="ctrl-q"           # quit simpleDocker
    [tmux_detach]="ctrl-\\"   # detach inside tmux
)

GRN='\033[0;32m'; RED='\033[0;31m'; ...  # UI colors

# ── Advanced ──────────────────────────────────────────────────────
SD_MNT_BASE="..."             # where images are mounted (default: $XDG_RUNTIME_DIR)
```

---

## Example Blueprint — Full

```toml
[container]

[meta]
name         = my-api
version      = 2.1.0
dialogue     = REST API service
description  = Example service with all features demonstrated.
port         = 8080
storage_type = my-api
entrypoint   = venv/bin/python -m uvicorn main:app --host 0.0.0.0 --port 8080
log          = logs/api.log
health       = true

[env]
PORT         = 8080
HOST         = 0.0.0.0
DATA_DIR     = data
SECRET_KEY   = generate:hex32

[storage]
data, logs

[deps]
curl, git, libpq-dev

[dirs]
bin, data, logs, data(uploads, cache)

[pip]
fastapi uvicorn[standard] psycopg2 python-dotenv

[git]
# Download latest release binary
my-org/my-cli → bin/

[build]
# Nothing to compile for Python, but you could:
# cd src && make

[install]
mkdir -p data/uploads data/cache
cp src/config.example.env data/.env
printf 'Setup complete.\n'

[update]
venv/bin/pip install --upgrade fastapi uvicorn
printf 'Updated packages.\n'

[start]
cd "$CONTAINER_ROOT"
exec venv/bin/python -m uvicorn main:app \
    --host "$HOST" \
    --port "$PORT" \
    --log-level info \
    2>&1 | tee -a logs/api.log

[cron]
5m  [health-log]  | printf '[%s] alive\n' "$(date '+%H:%M:%S')" >> logs/cron.log
1h  [cleanup]     | find data/cache -mtime +7 -delete && printf 'Cache cleaned.\n'

[actions]
Show recent logs   | tail -50 logs/api.log
Clear cache        | prompt: "Really clear cache? (yes/no):" | [[ "{input}" == "yes" ]] && rm -rf data/cache/* && printf 'Done.\n'
List uploads       | ls -lh data/uploads/
Remove upload      | select: ls data/uploads/ | rm "data/uploads/{selection}" && printf 'Removed.\n'

[/container]
```

---

## Troubleshooting

**`L: must use subscript when assigning associative array`**
There's a space between `[key]=` and `"value"` in a `declare -A` block. Bash does not allow spaces there. Remove them.

**Container won't start / blank tmux session**
Check the log: Container menu → View log, or Other → View logs. The start script likely exited immediately — check the `[start]` section for errors.

**`btrfs subvolume` errors on install**
The Ubuntu base may not be installed yet. Go to Other → Ubuntu base and install it first.

**Image won't mount**
The image may be corrupted or already mounted elsewhere. Check with `lsof | grep your-image.img` and unmount stale mounts manually if needed.

**Cron commands not writing to log files**
Relative paths in cron commands are automatically prefixed with `$CONTAINER_ROOT`. Make sure the directory exists (list it in `[dirs]`).

**Health check always yellow**
The container's port doesn't match what's in `[meta] port`. Check that your start script actually binds to that port, and that `health = true` is set.

**`generate:hex32` secret changes on restart**
`generate:hex32` is evaluated at container start time. To make it stable, generate it once and hardcode it in the blueprint, or store it in a file in `[storage]`.