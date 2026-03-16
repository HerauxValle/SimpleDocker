# simpleDocker — Encryption Reference

## Constants (set at startup)

| Constant | Value | Purpose |
|----------|-------|---------|
| `SD_VERIFICATION_CIPHER` | `sha256sum /etc/machine-id \| cut -c1-32` | Machine-specific 32-char unlock key. Derived at runtime, never stored. |
| `SD_DEFAULT_KEYWORD` | `"1991316125415311518"` | Fixed system-agnostic key. Works on any machine. |
| `SD_LUKS_KEY_SLOT_MIN` | `7` | Start of user-managed slot range |
| `SD_LUKS_KEY_SLOT_MAX` | `31` | End of user-managed slot range |
| `SD_UNLOCK_ORDER` | `verified_system default_keyword prompt` | Order tried when opening image |

---

## Slot Layout

```
Slot 0    auth.key — 64-byte random binary keyfile. Internal authority key.
Slot 1    SD_DEFAULT_KEYWORD — "System Agnostic". Works on any machine.
Slots 2–6 Reserved (unused).
Slots 7–31 User range:
              • Verified System slots — SD_VERIFICATION_CIPHER per machine
              • Passkeys — user-defined passphrases
```

`auth.slot` file (`$MNT_DIR/.sd/auth.slot`) stores the slot number of `auth.key` (always `"0"`).

---

## Image Creation Flow

```
truncate -s {N}G image.img
luksFormat --key-slot 31 --key-file=- <<< $SD_VERIFICATION_CIPHER   # bootstrap slot
cryptsetup open --key-file=- <<< $SD_VERIFICATION_CIPHER
mkfs.btrfs
mount
  ├── enc_authkey_create($SD_VERIFICATION_CIPHER tmpfile)
  │     dd if=/dev/urandom bs=64 count=1 > auth.key  (binary)
  │     luksAddKey --key-slot 0 --key-file=$tmpfile   (auth old=verification, new=auth.key)
  │     write "0" > auth.slot
  ├── luksKillSlot 31 --key-file=auth.key             (kill bootstrap)
  ├── luksAddKey --key-slot 1 --key-file=auth.key <<< $SD_DEFAULT_KEYWORD
  └── luksAddKey --key-slot $free --key-file=auth.key <<< $SD_VERIFICATION_CIPHER
        enc_vs_write($vid, $free)                      (cache this machine)
btrfs subvolumes: Blueprints Containers Installations Backup Storage Ubuntu Groups
```

---

## Opening an Image (unlock order)

1. **verified_system** — `printf $SD_VERIFICATION_CIPHER | cryptsetup open --key-file=-`
2. **default_keyword** — `printf $SD_DEFAULT_KEYWORD | cryptsetup open --key-file=-`
3. **prompt** — interactive passphrase, 3 attempts, masked input

Stops at first success. On failure → exits.

---

## Files on Disk (inside mounted image)

| Path | Contents |
|------|----------|
| `.sd/auth.key` | 64-byte binary random key (slot 0 material) |
| `.sd/auth.slot` | Text `"0"` — slot number of auth.key |
| `.sd/keyslot_names.json` | `{"7": "my-key", "8": "backup"}` — user-given passkey names |
| `.sd/verified/{vid}` | 3-line file: `hostname\nslot_number\nSD_VERIFICATION_CIPHER` |

`vid` = `sha256sum /etc/machine-id | cut -c1-8` (first 8 hex chars — per-machine ID)

---

## Verified System Cache File

```
line 1: hostname (from /etc/hostname)
line 2: LUKS slot number (empty if Auto-Unlock disabled for this machine)
line 3: SD_VERIFICATION_CIPHER value for this machine
```

Slot field cleared (empty line 2) when Auto-Unlock is disabled — pass retained for re-enable.

---

## State Checks

| Function | What it does |
|----------|-------------|
| `enc_auto_unlock_enabled` | `cryptsetup open --test-passphrase --key-file=- <<< $SD_VERIFICATION_CIPHER` |
| `enc_system_agnostic_enabled` | `cryptsetup open --test-passphrase --key-slot 1 --key-file=- <<< $SD_DEFAULT_KEYWORD` |
| `enc_authkey_valid` | File exists + `cryptsetup open --test-passphrase --key-slot 0 --key-file=auth.key` |
| `enc_is_verified` | Cache file `$MNT_DIR/.sd/verified/$vid` exists |

---

## Menu Operations

### System Agnostic (slot 1)

**Disable:**
- Guard: `_has_passkeys OR active_vs_count > 0` — must have another method
- Auth: `auth.key` if valid, else `SD_DEFAULT_KEYWORD` written to temp file
- `luksKillSlot --key-file=$tmpfile $IMG 1`

**Enable:**
- Auth: `auth.key` (required — error if missing)
- New key: `SD_DEFAULT_KEYWORD` written to temp file
- `luksAddKey --pbkdf pbkdf2 --iter 1000 --hash sha1 --key-slot 1 --key-file=auth.key $IMG $tmpfile`

---

### Auto-Unlock (verified system slots 7–31)

**Disable:**
- Guard: passkeys must exist first
- Auth: `auth.key` if valid, else fallback to `SD_VERIFICATION_CIPHER`
- For each verified system with an active slot: `luksKillSlot --key-file=$tf $IMG $slot`
- Cache update: clear line 2 (slot), preserve line 3 (pass)

**Enable:**
- Auth: `auth.key` (required)
- For each cached machine: find free slot, `luksAddKey --key-file=auth.key $IMG <<< $cached_pass`
- Cache update: write new slot to line 2

---

### Verify This System

- If already cached with slot → show "Already verified: {host} (slot N)"
- If cached but slot empty (disabled) → "System cached but Auto-Unlock is disabled"
- If Auto-Unlock on: find free slot → `luksAddKey --key-file=auth.key <<< $SD_VERIFICATION_CIPHER` → `enc_vs_write($vid, $slot)`
- If Auto-Unlock off: `enc_vs_write($vid, "")` — cache without adding slot

**Unauthorize a system:**
- Guard: cannot remove if it's the only unlock method
- If slot exists: `luksKillSlot --key-file=auth.key (or SD_VERIFICATION_CIPHER) $IMG $slot`
- Delete cache file `$MNT_DIR/.sd/verified/$vid`

---

### Add Passkey

Configure params (fzf param editor):
- `pbkdf`: argon2id (default) / argon2i / pbkdf2
- `ram`: KiB (default 262144 = 256 MB)
- `threads`: (default 4)
- `iter-ms`: (default 1000)
- `cipher`: aes-xts-plain64 (default) / chacha20-poly1305
- `key-bits`: 256 / 512 (default)
- `hash`: sha256 (default) / sha512 / sha1
- `sector`: 512 (default) / 1024 / 2048 / 4096

Input: masked `IFS= read -rs` × 2 (passphrase + confirm)

```
luksAddKey --pbkdf $pbkdf --pbkdf-memory $ram --pbkdf-parallel $threads --iter-time $iter
           --key-slot $free --key-file=auth.key $IMG <<< $passphrase
```
Name stored in `keyslot_names.json[slot] = name`.

---

### Remove Passkey

Safety guards (both must pass):
1. If Auto-Unlock disabled: must have `passkey_count > 1`
2. If Auto-Unlock enabled: must have `passkey_count > 1 OR active_vs_count > 0`

Auth: `auth.key` if valid, else prompt user for that key's passphrase.

```
luksKillSlot --key-file=$auth_tmpfile $IMG $slot
```
Remove name from `keyslot_names.json`.

---

### Reset Auth Token

1. Prompt passphrase (masked) — must be an existing valid passphrase
2. If `auth.key` exists and passes `--test-passphrase`:
   - `luksKillSlot --key-file=- <<< $passphrase $IMG 0`  (passphrase authorises the kill)
   - Delete `auth.key`
3. `enc_authkey_create($passphrase_tmpfile)` — generate new 64-byte random `auth.key` → slot 0

---

## Auth Key Usage Pattern

`auth.key` is the **internal authority key** used exclusively for:
- Adding new slots (`luksAddKey --key-file=auth.key`)
- Removing slots (`luksKillSlot --key-file=auth.key`)

It is **never the unlock key for normal image open** (that uses `SD_VERIFICATION_CIPHER`,
`SD_DEFAULT_KEYWORD`, or a user passphrase). It lives inside the mounted image, so it is
only accessible after the image is already open.

---

## PBKDF Notes

- `auth.key` always uses `pbkdf2 --iter 1000 --hash sha1` — fast intentionally (strength comes from 64-byte random key material, not PBKDF hardening)
- Default keyword and verified-system keys also use `pbkdf2 --iter 1000 --hash sha1`
- User passkeys default to `argon2id` with configurable params — hardened against brute force
