# Blueprint Reference

A blueprint is a plain-text DSL file that fully describes a service: how to install it, how to start it, what environment variables it needs, what to persist, and what scheduled jobs or custom actions to expose. simpleDocker compiles a blueprint into a `service.json` at install/start time. You never edit the JSON directly.

Blueprint files use the extension `.toml` (stored inside the image at `/Blueprints/`) or `.container` (on the host filesystem, auto-discovered). The format is identical regardless of extension.

---

## Table of Contents

- [Blueprint Reference](#blueprint-reference)
  - [Table of Contents](#table-of-contents)
  - [File structure](#file-structure)
  - [Comments](#comments)
  - [Sections overview](#sections-overview)
  - [\[meta\]](#meta)
  - [\[env\]](#env)
    - [Auto-prefix rules](#auto-prefix-rules)
    - [Special values](#special-values)
  - [\[storage\]](#storage)
  - [\[deps\]](#deps)
  - [\[dirs\]](#dirs)
  - [\[pip\]](#pip)
  - [\[npm\]](#npm)
  - [\[git\]](#git)
    - [Release download mode](#release-download-mode)
    - [Source clone mode](#source-clone-mode)
  - [\[build\]](#build)
  - [\[install\]](#install)
  - [\[update\]](#update)
  - [\[start\]](#start)
  - [\[cron\]](#cron)
    - [Interval syntax](#interval-syntax)
    - [Flags](#flags)
  - [\[actions\]](#actions)
    - [Modifiers](#modifiers)
  - [Install execution order](#install-execution-order)
  - [Full example](#full-example)

---

## File structure

Every blueprint is wrapped in a `[container]` / `[/container]` pair:

```
[container]

[meta]
...

[env]
...

[start]
...

[/container]
```

- Each `[section]` begins at its header line and ends when the next `[section]` begins.
- `[/container]` closes the blueprint.
- Sections may appear in any order, though the conventional order matches this document.
- All sections are optional. A blueprint with only `[meta]` and `[start]` is valid.

---

## Comments

`#` anywhere on a line starts a comment. Everything after it on that line is ignored. This works in every section, including bash blocks (`[start]`, `[install]`, etc.) — however, inside bash blocks the `#` is part of the generated script, so it behaves as a shell comment, not a DSL comment.

```
[meta]
name = my-service    # this comment is stripped by the parser
port = 8080

[start]
# this is a shell comment — it passes through to the generated script
exec bin/my-service
```

---

## Sections overview

| Section | Type | When it runs |
|---------|------|-------------|
| `[meta]` | Key = value | Parsed at compile time |
| `[env]` | Key = value | Exported before every start and install |
| `[storage]` | Paths list | Linked before every start |
| `[deps]` | Package list | `apt-get install` — install only |
| `[dirs]` | Directory spec | Created — install only |
| `[pip]` | Package list | `pip install` into venv — install only |
| `[npm]` | Package list | `npm install` into node_modules — install only |
| `[git]` | Repo spec | Downloaded/cloned — install only (update re-runs if tag changed) |
| `[build]` | Bash script | Runs once after `[git]` — install only |
| `[install]` | Bash script | Runs once after `[build]` — install only |
| `[update]` | Bash script | Runs when Update is triggered from the menu |
| `[start]` | Bash script | Runs every time the container starts |
| `[cron]` | Cron spec | One tmux session per job, runs while container is up |
| `[actions]` | Action spec | One-click commands shown in the running container menu |

---

## [meta]

Defines the identity and runtime behaviour of the container. All fields are `key = value`. All are optional except `name`.

```
[meta]
name         = my-service
version      = 1.0.0
dialogue     = Short label shown next to the name in the list
description  = Longer description for detail views
port         = 8080
storage_type = my-service
entrypoint   = bin/my-service --port 8080
log          = logs/service.log
health       = true
gpu          = cuda_auto
cap_drop     = true
seccomp      = true
```

| Field | Description |
|-------|-------------|
| `name` | Internal service name. Used for directory names and IDs. Alphanumeric, hyphens, underscores. |
| `version` | Version string. Compared against the latest GitHub release tag to detect updates. |
| `dialogue` | One-line label shown next to the container name in the UI. |
| `description` | Longer text for detail/info views. |
| `port` | Primary port number. Used for health checks, browser open, and reverse proxy routing. |
| `storage_type` | Key that links this container to a storage profile. Containers sharing the same key share persistent data. |
| `entrypoint` | Fallback start command if `[start]` is empty. Relative binary path is auto-prefixed with `$CONTAINER_ROOT`. |
| `log` | Log file path shown by "View log". Relative paths are auto-prefixed. Defaults to `start.log` in the logs directory. |
| `health` | `true` to enable TCP health check on `port`. Turns the status dot green (healthy) or yellow (unhealthy). |
| `gpu` | GPU passthrough mode. `cuda_auto` auto-detects NVIDIA at start time and copies driver libs into the chroot. `nvidia` and `amd` are accepted aliases. |
| `cap_drop` | `true` (default) drops Linux capabilities for isolation. Set `false` only if the service genuinely needs elevated privileges. |
| `seccomp` | `true` (default) applies a seccomp syscall filter. Set `false` if the service fails due to blocked syscalls. |

---

## [env]

Environment variables exported into the container namespace before every start and during install.

```
[env]
PORT             = 8080
HOST             = 0.0.0.0
DATA_DIR         = data
SECRET_KEY       = generate:hex32
LD_LIBRARY_PATH  = lib/mylib
DB_URL           = postgres://localhost:5432/mydb
```

Format: `KEY = VALUE`. One per line. Blank lines and comments are ignored.

### Auto-prefix rules

The parser checks each value and decides whether to prepend `$CONTAINER_ROOT/`:

| Value | Treated as | Example result |
|-------|-----------|----------------|
| Starts with `/` | Absolute path — no prefix | `/etc/ssl` → `/etc/ssl` |
| Starts with `~` | Home path — no prefix | `~/data` → `~/data` |
| Contains `$` | Shell expression — no prefix | `$HOME/db` → `$HOME/db` |
| Contains `://` | URL — no prefix | `http://localhost:5432` → unchanged |
| Contains `:` | Special directive or host:port — no prefix | `generate:hex32`, `localhost:5432` |
| Pure number | Port/integer — no prefix | `8080` → `8080` |
| IP address | Left alone | `0.0.0.0` → `0.0.0.0` |
| Relative path (contains `/`) | Prefixed | `data/uploads` → `$CONTAINER_ROOT/data/uploads` |
| Bare word (no `/`) | Prefixed | `data` → `$CONTAINER_ROOT/data` |

The intent: anything that looks like a path inside the container gets the full path automatically. You never need to write `$CONTAINER_ROOT/` manually in `[env]`.

### Special values

**`generate:hex32`**
Generates a random 32-byte hex secret at start time using `openssl rand -hex 32`.

- On first start: generates and **saves** the secret to a file in the storage profile (`.sd_secret_VARNAME`).
- On subsequent starts: reads the same file — the secret is **stable** across restarts.
- On reinstall without storage: generates a new secret.
- Use this for encryption keys, JWT secrets, API tokens, etc.

**`LD_LIBRARY_PATH` / `LIBRARY_PATH` / `PKG_CONFIG_PATH`**
These three variables are **appended** to any existing system value rather than overwritten:

```bash
export LD_LIBRARY_PATH="lib/mylib:${LD_LIBRARY_PATH:-}"
```

All other variables overwrite.

---

## [storage]

Comma-separated or newline-separated list of paths inside `$CONTAINER_ROOT` that persist across reinstalls.

```
[storage]
data, logs, models
```

or multiline:

```
[storage]
data
logs
models
```

These directories are symlinked into the installation subvolume from a dedicated storage profile. When you uninstall and reinstall a container, these paths survive. The `storage_type` field in `[meta]` determines which storage profile is linked. Multiple containers with the same `storage_type` share the same persistent directories.

---

## [deps]

APT packages installed into the shared Ubuntu chroot. These are available to all containers.

```
[deps]
curl, git, libpq-dev, nodejs
```

- Comma-separated or one per line.
- Version pinning: `package:1.2.3` installs `package=1.2.3` via apt. `package:latest` installs the latest available.
- `package:X.x` wildcard: `nodejs:22.x` installs `nodejs=22.*`.
- Packages are installed with `apt-get install -y --no-install-recommends`.
- Only runs during install, not on every start.

---

## [dirs]

Directories to create inside `$CONTAINER_ROOT`. Supports nested syntax.

```
[dirs]
bin, data, logs
```

```
[dirs]
lib(ollama)
models(checkpoints, adapters)
data(uploads, cache(thumbnails))
```

| Syntax | Creates |
|--------|---------|
| `bin` | `$CONTAINER_ROOT/bin/` |
| `lib(ollama)` | `$CONTAINER_ROOT/lib/ollama/` |
| `models(a, b)` | `$CONTAINER_ROOT/models/a/` and `$CONTAINER_ROOT/models/b/` |
| `data(cache(thumbs))` | `$CONTAINER_ROOT/data/cache/thumbs/` (arbitrary depth) |

Nested parens can go arbitrarily deep. Commas separate siblings at the same level.

---

## [pip]

Python packages installed into `$CONTAINER_ROOT/venv` using pip inside the Ubuntu chroot.

```
[pip]
fastapi uvicorn[standard]
requests==2.31.0
torch torchvision --extra-index-url https://download.pytorch.org/whl/cu124
```

- Full pip syntax: version pins (`==`, `>=`), extras (`[standard]`), flags (`--extra-index-url`, `--no-deps`, etc.).
- The virtualenv is created at `$CONTAINER_ROOT/venv` automatically if it doesn't exist.
- `venv/bin/` is on `PATH` inside the container at runtime.
- Only runs during install.

---

## [npm]

Node packages installed into `$CONTAINER_ROOT/node_modules`.

```
[npm]
n8n
express@4.18.2
```

- Node.js 22 is installed automatically via NodeSource if not present or too old.
- `node_modules/.bin/` is added to `PATH` inside the container.
- The `nodejs` package in `[deps]` is NOT required — npm handles its own Node installation.
- Only runs during install.

---

## [git]

Download GitHub release assets or clone source code. One entry per line. Multiple entries supported.

```
[git]
owner/repo
owner/repo → subdir/
owner/repo [specific-asset.tar.gz]
owner/repo [specific-asset][TYPE]
owner/repo source
owner/repo source → src/myrepo
```

### Release download mode

Any line without the `source` keyword downloads from GitHub Releases.

```
[git]
ollama/ollama → .
```

**Asset selection logic** (in priority order):

1. If `[asset-name]` is specified, match that filename exactly from the release assets, filtered by `[TYPE]` if provided.
2. If `gpu = cuda_auto` and CUDA is detected, prefer assets containing `cuda` in the name.
3. Prefer archives (`.tar.gz`, `.tar.zst`, `.tar.xz`, `.zip`) matching the host architecture (`amd64`/`arm64`) and `linux` in the filename.
4. Fall back to any archive for the architecture, then any archive, then the tarball URL.
5. Archives are auto-extracted; single binaries are placed in `bin/` and made executable.

**Explicit asset name:**

```
[git]
owner/repo [my-app-linux-amd64.tar.gz] → bin/
```

The `[asset-name]` token is matched case-insensitively against the release asset filenames. If the hint matches nothing, the auto-selection fallback runs.

**Asset type (`[TYPE]`):**

An optional type token controls which *kind* of asset is selected. It can appear alone or after an asset name hint. When no type is given, auto-detection defaults to preferring archives (ZIP/TAR).

| Token | Selects |
|-------|---------|
| `[ZIP]` | `.zip` files only |
| `[TAR]` | `.tar.gz`, `.tar.zst`, `.tar.xz`, `.tgz`, `.tar.bz2` files only |
| `[BIN]` | Raw binaries only — excludes all archive extensions |

```
[git]
# Only match the raw binary, not the zip of the same name
stashapp/stash [stash-linux-amd64][BIN] → bin/

# Only match the zip asset
owner/repo [my-app][ZIP] → .

# Type alone, no name hint — picks any raw binary for the arch
owner/repo [BIN] → bin/
```

If the type filter produces no match, the selector falls back to the unfiltered hint match, then standard auto-detection. This means `[TYPE]` never causes a hard failure — it only narrows the preference.

**Destination (`→`):**

```
[git]
owner/repo → .          # extract to $CONTAINER_ROOT
owner/repo → bin/       # extract to $CONTAINER_ROOT/bin/
owner/repo → tools/cli  # extract to $CONTAINER_ROOT/tools/cli/
```

`→ .` means extract to the container root. Any other path is relative to `$CONTAINER_ROOT`.

**Archive extraction:**

- `.tar.gz`, `.tar.xz`, `.tgz`, `.tar.bz2`, `.tar.zst` — extracted with `--strip-components=1` if the archive has a single top-level directory, or extracted as-is if it has multiple.
- `.zip` — extracted with `unzip`.
- Raw binary — moved to `bin/<name>` and `chmod +x`.

**Update detection:**

The latest release tag is cached. On every Update check, the cached tag is compared to the live GitHub API. If the tag has changed, the asset is re-downloaded.

### Source clone mode

Adding `source` after the repo path does a `git clone` instead of a release download.

```
[git]
comfyanonymous/ComfyUI source → .
ltdrdata/ComfyUI-Manager source → custom_nodes/ComfyUI-Manager
```

- Clones with `--depth=1` to the latest tag (or main branch if no tags exist).
- If the destination already has files, the clone goes to a temp directory and files are merged in with `cp -rn` (no overwrite).
- Source clones are NOT re-downloaded on update. Use `[update]` to pull new commits if needed.
- Destination is relative to `$CONTAINER_ROOT`. `→ .` clones into the container root.

---

## [build]

Bash commands run **once during install**, after `[git]` completes and before `[install]`. Use for compilation.

```
[build]
cd src
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --parallel $(nproc)
cp build/myapp bin/myapp
```

- Runs inside a chroot of the Ubuntu base with `$CONTAINER_ROOT` mounted at `/mnt`.
- `cd "$CONTAINER_ROOT"` is called before the block runs, so relative paths work.
- `set -e` is active — any command that fails aborts the install.
- Only runs during install, not during updates.

---

## [install]

Bash commands run **once during install**, after `[build]`.

```
[install]
venv/bin/pip install -r src/requirements.txt
mkdir -p data/uploads data/cache
cp src/config.example.json data/config.json
printf 'Setup complete.\n'
```

- Same execution environment as `[build]`: Ubuntu chroot, `$CONTAINER_ROOT` = `/mnt`, `set -e`.
- Runs after deps, dirs, pip, npm, git, and build — so all files are already in place.
- Intended for final wiring: copying configs, initializing databases, etc.

---

## [update]

Bash commands run when **Update** is manually triggered from the stopped container menu.

```
[update]
venv/bin/pip install --upgrade mypackage
bin/myapp migrate
printf 'Updated.\n'
```

- Same execution environment as `[install]`.
- The `[git]` block is also re-evaluated on update: if the release tag has changed, the new asset is downloaded before `[update]` runs.
- `[deps]`, `[pip]`, `[npm]` are NOT re-run on update (only on install).
- Use this for pulling new model weights, running database migrations, refreshing configs, etc.

---

## [start]

The main process script. Runs every time the container starts, inside its Linux namespace and chroot.

```
[start]
exec bin/my-service \
    --port "$PORT" \
    --data "$DATA_DIR" \
    --host "$HOST"
```

- All `[env]` variables are exported before this runs.
- `$CONTAINER_ROOT` is available and points to the installation path.
- The working directory is `$CONTAINER_ROOT` (i.e. `cd "$CONTAINER_ROOT"` is done automatically).
- Use `exec` for the main process so it receives signals correctly and the session ends cleanly when it exits.
- If `[start]` is empty and `entrypoint` is set in `[meta]`, the entrypoint is used as a fallback. The relative binary path in `entrypoint` is auto-prefixed with `$CONTAINER_ROOT`.
- Stdout and stderr are tee'd to the log file and visible when attached to the tmux session.

---

## [cron]

Scheduled commands that run while the container is running. Each job gets its own tmux session.

```
[cron]
30s [heartbeat]            | printf '[%s] alive\n' "$(date '+%H:%M:%S')" >> logs/cron.log
5m  [backup]    --sudo     | rsync -a data/ /mnt/backup/data/
1h  [cleanup]   --unjailed | find /tmp -mtime +1 -delete
1d  [report]               | bin/my-service --generate-report >> logs/report.log
```

Format: `interval [name] [flags] | command`

### Interval syntax

| Suffix | Unit | Example | Period |
|--------|------|---------|--------|
| `s` | seconds | `30s` | every 30 seconds |
| `m` | minutes | `5m` | every 5 minutes |
| `h` | hours | `2h` | every 2 hours |
| `d` | days | `1d` | every 1 day |
| `w` | weeks | `1w` | every 7 days |
| `mo` | months | `1mo` | every 30 days |

The timer fires **after** the interval, not at a fixed clock time. After each execution, the UI shows "Done. Next execution: HH:MM:SS [YYYY-MM-DD]".

### Flags

| Flag | Effect |
|------|--------|
| `--sudo` | Wraps the command in `sudo -n bash -c '...'`. |
| `--unjailed` | Runs on the **host** instead of inside the container namespace. `$CONTAINER_ROOT` is exported and points to the installation path. |

Flags can be combined: `5m [backup] --sudo --unjailed | rsync ...`

**Output redirection in cron:**
`>>` redirections are transparently converted to `| tee -a` so output appears both in the log file and in the tmux session when you attach to it.

```
[cron]
1m [log] | printf 'tick\n' >> logs/cron.log
# becomes: printf 'tick\n' | tee -a logs/cron.log
```

**Relative paths in cron commands** are automatically prefixed with `$CONTAINER_ROOT`:

```
[cron]
5m [backup] | cp -a data /backup/data   # data → $CONTAINER_ROOT/data
```

Absolute paths (starting with `/`) are left alone.

**Clicking a cron entry** in the running container menu attaches you to that job's tmux session so you can watch live output.

---

## [actions]

Custom one-click commands shown in the container menu when running. One action per line.

```
[actions]
Show logs         | tail -50 logs/service.log
Restart workers   | bin/my-service --restart-workers
Pull model        | prompt: "Model name:" | bin/my-service pull {input}
Remove model      | select: bin/my-service list --skip-header --col 1 | bin/my-service rm {selection}
⚡ Force reset    | rm -rf data/state && printf 'Reset done.\n'
```

Format: `Label | [modifier |] command`

- Labels starting with a plain ASCII letter or digit get a `⊙` prefix icon automatically.
- Labels starting with any other character (e.g. `⚡`, `→`, `×`) are used as-is.
- `Open browser` (case-insensitive) is a reserved label — it is hidden since the browser is opened via "Open in → Browser".

### Modifiers

Modifiers are optional pipe-separated segments before the final command. They change how the action collects input.

**`prompt: "text"`** — shows a text input prompt. The value the user types is available as `{input}` in the command.

```
[actions]
Set API key | prompt: "Paste your API key:" | printf '%s' "{input}" > data/api.key
```

**`select: command`** — runs a shell command, presents its output as an fzf picker, and makes the selected line available as `{selection}` in the final command.

```
[actions]
Delete backup | select: ls data/backups/ | rm "data/backups/{selection}"
```

**`select: command --skip-header`** — skips the first line of the command output (useful when the command prints a column header row).

```
[actions]
Remove model | select: bin/ollama list --skip-header | bin/ollama rm "{selection}"
```

**`select: command --col N`** — uses only column N (1-indexed, whitespace-split) of the selected line as `{selection}`. Useful when the list command outputs multiple columns.

```
[actions]
Remove model | select: bin/ollama list --skip-header --col 1 | bin/ollama rm "{selection}"
```

Modifiers can be combined:

```
[actions]
Move file | prompt: "Destination:" | select: ls data/ | mv "data/{selection}" "{input}/{selection}"
```

---

## Install execution order

When Install is triggered, steps run in this exact order:

```
1. [deps]     — apt-get install into Ubuntu chroot
2. [dirs]     — mkdir -p inside $CONTAINER_ROOT
3. [pip]      — pip install into $CONTAINER_ROOT/venv
4. [npm]      — npm install into $CONTAINER_ROOT/node_modules
5. [git]      — download releases / clone repos
6. [build]    — custom compile steps
7. [install]  — custom setup steps
```

When Update is triggered:

```
1. [git]      — re-download if release tag changed
2. [update]   — custom update steps
```

When Start is triggered:

```
1. Storage profile linked (symlinks created)
2. [env] variables exported
3. [start] script executed inside namespace+chroot
4. [cron] jobs launched in parallel tmux sessions
```

---

## Full example

A realistic blueprint using most features:

```
[container]

[meta]
name         = data-pipeline
version      = 3.2.1
dialogue     = ETL pipeline service
description  = Pulls data from external APIs, transforms it, stores results.
port         = 9000
storage_type = data-pipeline
entrypoint   = venv/bin/python -m pipeline.server
log          = logs/pipeline.log
health       = true

[env]
PORT          = 9000
HOST          = 0.0.0.0
DATA_DIR      = data
LOGS_DIR      = logs
SECRET_KEY    = generate:hex32
DATABASE_URL  = sqlite:///data/pipeline.db
API_TIMEOUT   = 30

[storage]
data, logs

[deps]
libsqlite3-dev, curl

[dirs]
bin, data, logs, data(raw, processed, archive)

[pip]
fastapi uvicorn[standard]
httpx sqlalchemy
pandas pyarrow

[git]
myorg/pipeline-cli → bin/

[build]
# nothing to compile — pure Python

[install]
venv/bin/python -m pipeline.migrate
cp src/pipeline.example.toml data/pipeline.toml
printf 'Database initialised.\n'

[update]
venv/bin/pip install --upgrade fastapi httpx
venv/bin/python -m pipeline.migrate
printf 'Migration complete.\n'

[start]
exec venv/bin/python -m pipeline.server \
    --host "$HOST" \
    --port "$PORT" \
    --db "$DATABASE_URL"

[cron]
15m [fetch]    | venv/bin/python -m pipeline.fetch >> logs/fetch.log
1h  [process]  | venv/bin/python -m pipeline.process >> logs/process.log
1d  [archive]  | mv data/processed/* data/archive/ && printf 'Archived.\n'
1w  [cleanup]  --sudo | find data/archive -mtime +30 -delete

[actions]
Show fetch log     | tail -100 logs/fetch.log
Run fetch now      | venv/bin/python -m pipeline.fetch
Inspect record     | prompt: "Record ID:" | venv/bin/python -m pipeline.inspect {input}
Delete dataset     | select: ls data/processed/ | rm -rf "data/processed/{selection}"
Force full refresh | bin/pipeline-cli refresh --all

[/container]
```