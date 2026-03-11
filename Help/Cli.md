# simpleDocker CLI

Drive simpleDocker from scripts, cron, or the terminal without the TUI.

```
services.sh cli <img> <command> [args] [flags]
```

Every command mounts the image, runs the operation, then unmounts. All commands print a clear error with usage hint on failure.

---

## Flags

| Flag | Description |
|------|-------------|
| `--json` | Machine-readable JSON output |
| `--yes` / `-y` | Auto-confirm prompts |
| `--passkey <key>` | LUKS passphrase, skips interactive prompt |

Flags can appear anywhere in the command.

---

## Encryption & Mounting

Unlock order:
1. **Verified system** — machine is registered, silent
2. **Default keyword** — system-agnostic mode enabled, silent
3. **Interactive prompt** — terminal prompt, 3 attempts
4. **`--passkey`** — supplied directly, skips prompt

```bash
# Registered machine — just works
services.sh cli Tesla.img status

# Supply passphrase (for scripts/cron)
services.sh cli Tesla.img status --passkey "my passphrase"
```

> `--passkey` on the command line is visible in `ps` and shell history. Use a registered machine or pipe from a secrets manager for sensitive setups.

---

## Commands

### `status`
```bash
services.sh cli Tesla.img status [--json]
```
Overview of the image — ubuntu and all containers.

---

### `container` (alias: `ct`)

```bash
services.sh cli Tesla.img container list
services.sh cli Tesla.img ct list --json

services.sh cli Tesla.img container start   <name|id>
services.sh cli Tesla.img container stop    <name|id>
services.sh cli Tesla.img container restart <name|id>

services.sh cli Tesla.img container install   <blueprint-name>
services.sh cli Tesla.img container uninstall <name|id>

services.sh cli Tesla.img container logs <name|id>   # streams, Ctrl-C to exit
```

- `start` uses auto storage selection, fails if not installed
- `uninstall` removes the installation subvolume, keeps the container entry
- On name/id not found, lists available containers

---

### `blueprint` (alias: `bp`)

```bash
services.sh cli Tesla.img blueprint list
services.sh cli Tesla.img bp list --json

services.sh cli Tesla.img blueprint install <file.toml>
services.sh cli Tesla.img blueprint remove  <name>
```

---

### `storage` (alias: `stor`)

```bash
services.sh cli Tesla.img storage list
services.sh cli Tesla.img stor list --json

services.sh cli Tesla.img storage create <name> <path> [size_gb]
# size_gb defaults to 10 if omitted
```

---

### `proxy`

```bash
services.sh cli Tesla.img proxy status [--json]
services.sh cli Tesla.img proxy start
services.sh cli Tesla.img proxy stop
```

---

### `ubuntu` (alias: `ub`)

```bash
services.sh cli Tesla.img ubuntu status [--json]
services.sh cli Tesla.img ubuntu install

services.sh cli Tesla.img ubuntu pkg-add    <package>
services.sh cli Tesla.img ubuntu pkg-remove <package>
```

`pkg-add` / `pkg-remove` run directly inside the chroot (blocking, not via tmux).

---

### `unmount`

```bash
services.sh cli Tesla.img unmount
```

Force-unmount without running any other command. All other commands unmount automatically.

---

## Error Handling

Every failure prints `error: <reason>` to stderr with a usage hint:

```
error: container not found: myap

available containers:
  myapp    (a3f2c1d0)
  database (b7e9a2c1)
```

```
error: unknown container command: 'lst'
valid: list start stop restart install uninstall logs
```

Exit codes: `0` success, `1` failure.

---

## JSON Examples

```bash
services.sh cli Tesla.img status --json
```
```json
{"img":"Tesla.img","ubuntu":{"status":"ready"},"containers":[
{"id":"a3f2c1d0","name":"myapp","running":true,"installed":true},
{"id":"b7e9a2c1","name":"database","running":false,"installed":true}
]}
```

```bash
services.sh cli Tesla.img ubuntu status --json
```
```json
{"status":"ready","version":"Ubuntu 24.04.2 LTS","size":"1.3G"}
```

---

## Scripting Examples

```bash
# Start all stopped containers
services.sh cli Tesla.img ct list --json \
  | jq -r '.[] | select(.running==false) | .name' \
  | while read -r name; do
      services.sh cli Tesla.img ct start "$name" --yes
    done

# Check if a container is running
services.sh cli Tesla.img ct list --json \
  | jq -e '.[] | select(.name=="myapp" and .running==true)' > /dev/null \
  && echo "up" || echo "down"

# Cron restart at 3am (passkey from file)
# 0 3 * * * /path/to/services.sh cli ~/images/Tesla.img ct restart myapp --yes \
#   --passkey="$(cat /run/secrets/sd_pass)"
```

---

## Image Path Resolution

- Absolute: `/home/user/images/Tesla.img`
- Relative: `./Tesla.img`
- Bare name: `Tesla.img` → resolved against `~/.config/simpleDocker/images/Tesla.img`