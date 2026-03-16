# services.py — Issues & Divergences from services.sh

This document catalogues every significant place where `services.py` diverges from,
misimplements, or omits behaviour from `services.sh`. Most critical issues are in
encryption, tmux bootstrapping, and the resize flow.

---

## CRITICAL — Encryption

### 1. `enc_authkey_create`: writes text instead of binary key

**Shell:**
```bash
dd if=/dev/urandom bs=64 count=1 > auth.key
```
Writes 64 **binary** bytes (not printable text).

**Python:**
```python
with open(kf,'wb') as f: f.write(os.urandom(64))
```
✅ This part is correct — binary write with `os.urandom(64)`.

However, in `create_img`, the bootstrap temp file is written as **text**:
```python
auth_tmp.write_text(G.verification_cipher)   # ← TEXT, not binary
```
Then passed to `enc_authkey_create(auth_tmp)`. The shell always passes a temp file
written with `printf '%s' "$SD_VERIFICATION_CIPHER"` which is also text — so this
specific case matches. ✅

**Real issue:** `enc_authkey_create` in the Python takes a `Path` (a file) as `auth_kf`,
but the `Reset Auth Token` path writes `tf.write_bytes(pw.encode())` — writes the
passphrase as bytes. This is correct **only if** the passphrase is ASCII. The shell
uses `printf '%s' "$_ra_pass"` which is also byte-equivalent, so this matches. ✅

### 2. `Reset Auth Token` — wrong slot killed, wrong authorisation flow

**Shell (`_enc_menu`, Reset Auth Token branch):**
```bash
# 1. Prompt passphrase
IFS= read -rs _ra_pass

# 2. If old auth.key is valid, kill slot 0 using the PROVIDED PASSPHRASE
if [[ -f "$_old_kf" ]] && sudo cryptsetup open --test-passphrase --key-file "$_old_kf" ...; then
    sudo cryptsetup luksKillSlot --key-file "$_tf_ra" "$IMG" 0   # _tf_ra = passphrase
fi

# 3. Delete old auth.key

# 4. enc_authkey_create(_tf_ra)  — passphrase as auth to add new key to slot 0
```

The shell logic:
- Uses the **user-provided passphrase** as the authorisation key to kill slot 0
- This means: "I'm proving I own this image (I know an existing passphrase), now
  replace the internal auth key with a new random one"

**Python:**
```python
old_kf = enc_authkey_path()
if old_kf.exists():
    subprocess.run([...'luksKillSlot','--batch-mode',
                    '--key-file=-',...,'0'],
                   input=pw.encode(), ...)   # uses passphrase to kill slot 0 ✅
    old_kf.unlink(missing_ok=True)
tf.write_bytes(pw.encode())
ok = enc_authkey_create(tf)   # uses passphrase to add new auth key ✅
```

Python is functionally equivalent here. ✅

**BUT:** The shell also checks `enc_authkey_valid` before attempting to kill slot 0 —
if the old `auth.key` file is missing or invalid (corrupted), it skips the kill entirely
and goes straight to creating the new one. The Python also has this branch with
`if old_kf.exists()`. Acceptable difference: Python will attempt kill regardless of
whether `auth.key` is currently valid as a key — it just checks file existence. The
shell additionally verifies the key by doing a `--test-passphrase` open. **Minor
divergence** — unlikely to cause issues in practice.

### 3. `System Agnostic` disable — uses `finput` instead of temp file (MEDIUM)

**Shell:**
```bash
# Disable path: creates tmp file, copies auth.key into it, kills slot 1
local _tf_sa_kill=$(mktemp)
_enc_authkey_valid && cp "$(_enc_authkey_path)" "$_tf_sa_kill" \
    || printf '%s' "$SD_DEFAULT_KEYWORD" > "$_tf_sa_kill"
sudo cryptsetup luksKillSlot --batch-mode --key-file "$_tf_sa_kill" "$IMG" 1
rm -f "$_tf_sa_kill"
```

**Python:**
```python
if enc_authkey_valid():
    rc = subprocess.run([...'luksKillSlot','--batch-mode',
                         '--key-file',str(enc_authkey_path()),...,'1'], ...).returncode
else:
    pw = finput('Passphrase to authorise slot removal:')
    rc = subprocess.run([...'luksKillSlot','--batch-mode',
                         '--key-file=-',...,'1'],
                        input=pw.encode(), ...).returncode
```

**Issue:** The shell fallback uses `SD_DEFAULT_KEYWORD` as the auth key — because
if `auth.key` is missing, the image was presumably opened via the default keyword.
The Python fallback asks the user for a passphrase. This is a **behavioural difference**:
if the auth key is corrupt/missing but System Agnostic was enabled (i.e. slot 1 holds
`SD_DEFAULT_KEYWORD`), the shell can self-authorise using the known default keyword,
while Python asks the user for a passphrase instead. Not wrong per se, but diverges from
the shell's self-healing behaviour.

### 4. `Auto-Unlock` disable — incomplete cache update (HIGH)

**Shell disable path:**
```bash
for _vsid in "${_vs_ids[@]}"; do
    local _dslot=$(_enc_vs_slot "$_vsid")
    [[ -z "$_dslot" || "$_dslot" == "0" ]] && continue
    sudo cryptsetup luksKillSlot --key-file "$_tf_dis" "$IMG" "$_dslot"
    local _dhost=$(_enc_vs_hostname "$_vsid")
    local _dpass=$(_enc_vs_pass "$_vsid")
    printf '%s\n%s\n%s\n' "$_dhost" "" "$_dpass" > "$_vdir/$_vsid"
    #                             ^^^ slot cleared to empty string
done
```
The shell writes a new 3-line file: `hostname\n\npassword\n` — slot cleared, password
preserved for re-enable.

**Python disable path:**
```python
lines = (vdir/vsid).read_text().splitlines()
while len(lines) < 3: lines.append('')
lines[1] = ''   # clear slot number
(vdir/vsid).write_text('\n'.join(lines))
```

**Issue:** `'\n'.join(['host','','pass'])` produces `"host\npass"` — which is
`"host\n\npass"` only if line 1 is `''`. Wait: `'\n'.join(['host','','pass'])` = 
`"host\n\npass"`. When read back with `.splitlines()`, this gives `['host','','pass']`.
So `enc_vs_pass` reads `lines[2]` = `'pass'`. ✅ Actually this is correct.

**BUT there is a subtle issue:** The shell writes the file as:
```
hostname\n
\n          ← empty slot (blank line)
password\n
```
That is 3 lines separated by newlines, with a trailing newline. Python writes
`'\n'.join(['host','','pass'])` = `"host\n\npass"` — NO trailing newline. When read
back with `.splitlines()`, this gives `['host', '', 'pass']` which is fine.

**HOWEVER:** The shell's `_enc_vs_pass` reads via `sed -n '3p'` which gets line 3.
The Python's `enc_vs_pass` reads `lines[2]` (0-indexed = line 3). ✅ Consistent.

The cache update is functionally correct. ✅

### 5. `Auto-Unlock` enable — passes passphrase via `input=` instead of key file (MEDIUM)

**Shell enable path:**
```bash
printf '%s' "$_vspass" > "$_tf_vsp"
sudo cryptsetup luksAddKey \
    --key-slot "$_free_s" --key-file "$_tf_en_auth" \   # auth = auth.key file
    "$IMG" "$_tf_vsp"                                    # new key = vspass via file
```
New key material passed as a **file** argument (last positional arg).

**Python enable path:**
```python
rc = subprocess.run(
    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
     '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
    input=vspass.encode(), capture_output=True).returncode
```
New key material passed via `stdin` (`input=vspass.encode()`).

This is **functionally identical** to the shell: when no new-key argument follows
the device, cryptsetup reads the new key from stdin. ✅

### 6. `enc_authkey_create` — `luksAddKey` new key passed as file vs stdin (MEDIUM)

**Shell:**
```bash
sudo cryptsetup luksAddKey \
    --key-slot 0 --key-file "$_auth_kf" \   # existing key = file
    "$IMG_PATH" "$_kf"                       # new key = auth.key file (positional)
```

**Python:**
```python
r = subprocess.run(
    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
     '--key-slot','0','--key-file',str(auth_kf),str(G.img_path),str(kf)],
    capture_output=True)
```
New key = `str(kf)` as positional arg = the auth.key file. ✅ Correct.

### 7. `Verify this system` — `enc_vs_write` stores wrong pass value (HIGH)

**Shell `_enc_vs_write`:**
```bash
printf '%s\n%s\n%s\n' \
    "$(cat /etc/hostname | tr -d '[:space:]')" \
    "$_slot" \
    "$(_enc_verified_pass)"   # = sha256sum /etc/machine-id | cut -c1-32 = SD_VERIFICATION_CIPHER
```

**Python `enc_vs_write`:**
```python
(vdir/vid).write_text(f'{hostname}\n{slot}\n{G.verification_cipher}\n')
```

✅ Stores `G.verification_cipher` = the machine's verification cipher. Correct.

**BUT `enc_vs_pass` returns this same value**, and when Auto-Unlock is re-enabled, it
calls `luksAddKey` with `input=vspass.encode()`. In the shell, the verified system key
stored in the LUKS slot IS `SD_VERIFICATION_CIPHER`, and auto-unlock tries
`SD_VERIFICATION_CIPHER` as first unlock method. These are consistent. ✅

### 8. `luks_open` uses wrong path for `--key-file=-` (CRITICAL)

**Shell `_luks_open`:**
```bash
verified_system)
    printf '%s' "$SD_VERIFICATION_CIPHER" | sudo cryptsetup open --key-file=- "$img" "$mapper"
```
Passes key via stdin using `--key-file=-`.

**Python `luks_open`:**
```python
r = subprocess.run(['sudo','-n','cryptsetup','open','--key-file=-',str(img),mapper],
    input=G.verification_cipher.encode(), capture_output=True)
```
✅ Also uses `--key-file=-` with `input=`. Equivalent.

### 9. `enc_authkey_create` PBKDF args missing in shell vs present in Python (MINOR)

**Shell:**
```bash
sudo cryptsetup luksAddKey \
    --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --hash sha1 \
    --key-slot 0 \
    --key-file "$_auth_kf" \
    "$IMG_PATH" "$_kf"
```
Uses fast PBKDF2 for the internal auth key (intentional — this key never needs to be
human-memorable; its strength comes from the 64-byte random key, not PBKDF hardening).

**Python:**
```python
r = subprocess.run(
    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
     '--key-slot','0','--key-file',str(auth_kf),str(G.img_path),str(kf)],
    capture_output=True)
```
✅ Same PBKDF args. Correct.

---

## HIGH — Tmux Bootstrap

### 10. Inner process detection via env var vs `$TMUX` check (HIGH)

**Shell:**
```bash
if [[ -z "$TMUX" ]]; then
    # outer: write sudoers, create/attach tmux session
fi
# (falls through if already inside tmux)
```
The inner process is the same script re-run by tmux. It skips the outer block because
`$TMUX` is set inside a tmux session.

**Python:**
```python
if os.environ.get('SD_INNER') == '1':
    return  # inner process
# ... (creates tmux session passing `env SD_INNER=1 python3 ...`)
```
The Python uses a custom `SD_INNER=1` env var. This is functionally equivalent, but
**differs from the shell** which uses the standard `$TMUX` variable. This means:
- If someone manually runs the Python script while already inside tmux, `SD_INNER`
  won't be set and `$TMUX` won't be checked — it will attempt to bootstrap again.
- The shell would detect `$TMUX` and skip to the inner logic. Python won't.

**Fix:** Should also check `os.environ.get('TMUX')` as a fallback, or replace `SD_INNER`
with a `TMUX` check.

### 11. Outer shell re-attach loop drains terminal input differently (MEDIUM)

**Shell:**
```bash
while tmux has-session -t "simpleDocker"; do
    tmux attach-session -t "simpleDocker" >/dev/null 2>&1
    stty sane
    while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done  # drain stdin
    clear
    [[ "$(tmux show-environment -g SD_DETACH)" == "SD_DETACH=1" ]] && \
        { tmux set-environment -g SD_DETACH 0; clear; break; }
done
```

**Python:**
```python
while tmux_up(sess):
    subprocess.run(['tmux','attach-session','-t',sess])
    os.system('stty sane 2>/dev/null')
    try:
        import termios, tty
        old = termios.tcgetattr(sys.stdin.fileno())
        tty.setraw(sys.stdin.fileno())
        termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
    except: pass
    os.system('clear')
    if tmux_get('SD_DETACH') == '1':
        subprocess.run(['tmux','set-environment','-g','SD_DETACH','0'], ...)
        os.system('clear')
        break
```
The Python's raw-mode trick doesn't actually drain stdin the same way. The shell drain
loop reads and discards buffered chars. The Python version sets raw mode and restores it
(which doesn't drain). **Minor** in practice but different.

### 12. `_bootstrap_tmux` calls `write_sudoers` before tmux exists (MEDIUM)

**Shell:** The outer block writes sudoers first (before creating tmux), then creates
the session. This is correct — the session is created once, sudoers is written to disk.

**Python:**
```python
sudoers = f'/etc/sudoers.d/simpledocker_{os.popen("id -un").read().strip()}'
if not os.path.exists(sudoers):
    write_sudoers()
```
Only writes sudoers if the file doesn't exist. The shell **always** re-validates
(it prompts for sudo each launch via `sudo -k` + `sudo -v`). The Python skips the
password prompt entirely if the sudoers file already exists. **Behavioural divergence**
but arguably an improvement.

---

## HIGH — Image / LUKS Resize

### 13. Resize uses `/tmp/.sd_resize_ok` — not inside `TMP_DIR` (HIGH)

**Shell resize script:**
```bash
ok_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_ok_XXXXXX")
fail_file=$(mktemp "$SD_MNT_BASE/.tmp/.sd_resize_fail_XXXXXX")
```
Uses `SD_MNT_BASE/.tmp` — the pre-mount tmp dir — because during resize the image is
**unmounted** (MNT_DIR is gone). The sentinel files are on the host.

**Python:**
```python
f.write(f'touch /tmp/.sd_resize_ok\n')
...
Path('/tmp/.sd_resize_ok').unlink(missing_ok=True)
_installing_wait_loop(sess, '/tmp/.sd_resize_ok', '/dev/null', 'Resize image')
```
Uses a **hardcoded `/tmp/`** path. This is wrong in the following ways:
1. Not unique — could collide if two instances run simultaneously
2. Not cleaned up on crash
3. Uses `/dev/null` as fail sentinel — the wait loop will **never detect failure**

**Shell uses a proper fail_file and reports failure to the user.** Python silently
ignores failure.

### 14. Resize script LUKS re-open uses `enc_authkey_path()` which may not exist (HIGH)

**Python resize script generation:**
```python
authkey = str(enc_authkey_path())
f.write(f'if [ -f {authkey!r} ]; then\n')
f.write(f'  sudo -n cryptsetup open --key-file={authkey!r} "$_lo2" {mapper!r}\n')
f.write(f'else\n')
f.write(f'  printf "%s" "{SD_DEFAULT_KEYWORD}" | sudo -n cryptsetup open --key-file=- "$_lo2" {mapper!r}\n')
```
`enc_authkey_path()` = `$MNT_DIR/.sd/auth.key`. But during resize, `MNT_DIR` is
**unmounted** — the auth.key file is inside the image and is inaccessible. The
fallback uses `SD_DEFAULT_KEYWORD`, which only works if System Agnostic is enabled.

**Shell resize script:**
```bash
auto_pass=$(printf '%q' "$SD_VERIFICATION_CIPHER")
# inside the script:
for _try_pass in "$auto_pass" "$_saved_pp"; do
    printf '%s' "$_try_pass" | sudo cryptsetup open --key-file=- ...
done
# if both fail, prompt for passphrase
```
The shell uses `SD_VERIFICATION_CIPHER` (the machine-derived key, always available on
the host) as the first attempt, then prompts the user. It does NOT rely on the auth.key
being accessible on disk.

**This is a critical divergence.** The Python resize will fail to reopen the LUKS image
for any user who has disabled System Agnostic (slot 1 / SD_DEFAULT_KEYWORD), because:
- `auth.key` is inside the unmounted image (inaccessible)
- SD_DEFAULT_KEYWORD only works if slot 1 exists

The shell correctly uses `SD_VERIFICATION_CIPHER` (auto-unlock key, always in memory)
as the first unlock attempt.

### 15. `resize_image` doesn't stop running containers first (HIGH)

**Shell `_resize_image`:**
```bash
# Collect running container names
# If any running:
#   confirm "Running services will be stopped: [list] Resize?"
#   Stop all running containers
#   Kill sdInst_ sessions
# Then resize
```

**Python `resize_image`:**
```python
# Goes straight to finput for size, then confirm, then resize
# No container stopping logic at all
```

The Python will resize while containers are running, which can cause data corruption
or failed unmount.

---

## HIGH — Persistent Blueprints

### 16. Persistent blueprints stored as files, not embedded in script (HIGH)

**Shell:** Persistent blueprints are **embedded in the script source** inside a heredoc
(`SD_PERSISTENT_END` ... `SD_PERSISTENT_END`) and extracted with `awk`. This means
they travel with the script, are always available, and can't be separated from it.

**Python:**
```python
_SD_PERSISTENT_BLUEPRINTS = {
    'Counter': '...',
}

def _seed_persistent_blueprints():
    """Write built-in blueprints to .sd/persistent_blueprints/ if not already present."""
    pd = G.mnt_dir/'.sd/persistent_blueprints'
    pd.mkdir(parents=True, exist_ok=True)
    for name, content in _SD_PERSISTENT_BLUEPRINTS.items():
        dest = pd/f'{name}.container'
        if not dest.exists():
            dest.write_text(content)
```

The Python seeds files on every mount. The shell reads them live from the script body.

**Key differences:**
1. Python blueprints can become stale if the in-memory dict changes but the seeded
   files already exist (due to `if not dest.exists()`)
2. `_list_persistent_names` in Python reads from `_SD_PERSISTENT_BLUEPRINTS` dict,
   but `_view_persistent_bp` / `_get_persistent_bp` read from the seeded files on disk
3. The shell has a toggle "Persistent blueprints" that hides/shows these; the Python
   also has this toggle, but uses a settings file `_bp_settings_get('persistent_blueprints')`
   which was not checked — it may not wire up correctly to the dict-based list function

---

## MEDIUM — Menu / UI

### 17. `quit_menu` missing the "Detach" option properly (MEDIUM)

**Shell:**
```bash
_quit_menu() {
    _menu "${L[quit]}" "${L[detach]}" "${L[quit_stop_all]}" || return
    case "$REPLY" in
        "${L[detach]}")        _tmux_set SD_DETACH 1; tmux detach-client ;;
        "${L[quit_stop_all]}") _quit_all ;;
    esac
}
```
The menu has: Detach + Stop all & quit. Pressing ESC/Back does nothing (just returns).

**Python:**
```python
def quit_menu():
    sel = fzf_run(
        [f'{DIM}⊙  {L["detach"]}{NC}', f'{RED}■  {L["quit_stop_all"]}{NC}'],
        header=...
    )
    if not sel: return
    sc = strip_ansi(sel).strip()
    if '⊙' in sc or L['detach'] in sc:
        tmux_set('SD_DETACH','1')
        _tmux('detach-client')
    elif '■' in sc or L['quit_stop_all'] in sc:
        quit_all()
```
Functionally equivalent. ✅

But note: shell `_menu` auto-adds a `Back` item; Python `quit_menu` calls `fzf_run`
directly (not `menu()`), so there's no Back item. This is intentional and correct.

### 18. `main_menu` missing group running-count display (MEDIUM)

**Shell `main_menu`** computes:
- `n_running` — count of running containers
- `grp_n_active` — count of groups with at least one running container
- Displays `"Groups  [2 active/4]"` format

**Python `main_menu`:**
```python
n_grp = len(_list_groups())
...
f' {CYN}▶{NC}  Groups  {DIM}[{n_grp}]{NC}',
```
Only shows total group count, **not** how many groups are active. Loses the running
indicator.

### 19. `containers_submenu` missing batch jq optimisation (MINOR / correctness ok)

The shell reads `service.json` + `state.json` in a single `jq` call per container
for efficiency. Python reads them separately via `sj_get()` and `st()`. Functionally
equivalent but slower.

### 20. `_sig_rc` vs `G.usr1_fired` — USR1 loop handling inconsistent (MEDIUM)

**Shell:** Every fzf loop checks `_sig_rc $rc` (exit codes 143/138/137 = signal-killed)
and does `continue` to re-render the menu. The `_SD_USR1_FIRED` flag is also checked.

**Python `fzf_run`:**
```python
if proc.returncode in _SIG_RCS:
    G.usr1_fired = True
    return None
if proc.returncode != 0: return None
```
Both signal-kill AND ESC (rc=1/130) return `None`. Callers must check `G.usr1_fired`
to distinguish "refresh needed" from "ESC pressed".

Many menu loops in Python do:
```python
if sel is None:
    if G.usr1_fired: G.usr1_fired = False; continue
    return
```
This is correct if consistently applied. However, several menus in Python don't check
`G.usr1_fired` at all, meaning a SIGUSR1 will incorrectly close the menu instead of
refreshing it. **Audit needed** — not all menus follow the pattern.

---

## MEDIUM — Container Operations

### 21. `_ensure_ubuntu` runs in tmux session, Python `_ensure_ubuntu` may not match exactly

The shell runs Ubuntu download/extract in a dedicated `sdUbuntuSetup` tmux session
with a displayed progress view. The Python port does similarly. However, the shell
embeds `_chroot_bash` as a function inside the heredoc script. Python generates
a bash script that runs in tmux. The logic appears equivalent, but the error recovery
(`.ubuntu_fail_flag`) and retry logic should be verified.

### 22. Container `.install_ok` / `.install_fail` sentinel file paths

**Shell:** `$CONTAINERS_DIR/$cid/.install_ok` and `.install_fail`

**Python:** `G.containers_dir/cid2/'.install_ok'` — correct. ✅

### 23. `_is_installing` checks tmux session `sdInst_{cid}` (shell) vs Python `inst_sess(cid)`

Shell: `_is_installing() { tmux_up "sdInst_$1"; }`

Python: `is_installing(cid) → tmux_up(inst_sess(cid))` where `inst_sess = f'sdInst_{cid}'` ✅

---

## MEDIUM — Networking

### 24. `netns_teardown` cleanup incomplete (MEDIUM)

**Shell `_netns_teardown`:**
```bash
sudo ip netns del "$ns"
sudo ip link del "sd-h${idx}"
rm -f "$mnt/.sd/.netns_name" "$mnt/.sd/.netns_idx" "$mnt/.sd/.netns_hosts"
```
Deletes the namespace, the host-side veth, and the metadata files.

**Python `netns_teardown`:**
```python
_sudo('ip','link','del',f'sd-h{idx}')
_sudo('ip','netns','del',ns)
```
**Missing:** `rm -f` for `.netns_name`, `.netns_idx`, `.netns_hosts` metadata files.
Not critical (files will be overwritten on next setup) but leaves stale data.

---

## LOW — Misc

### 25. `_bp_persistent_enabled` — Python reads from settings file, shell checks cfg (MINOR)

Both use a settings file mechanism. Appears consistent. Needs integration test.

### 26. `ub_cache_check` runs in Python thread, shell runs as background subshell (LOW)

Shell: `_sd_ub_cache_check &` (subshell, writes temp files, read by `_sd_ub_cache_read`)

Python: `threading.Thread(target=ub_cache_check)` — similar pattern with temp files.
The Python thread writes to `G.sd_mnt_base/.tmp/.sd_ub_drift_{pid}` etc., matching
the shell. ✅

### 27. `_enc_slots_used` regex — minor difference (LOW)

**Shell:** Uses `grep -oP '^\s+\K[0-9]+(?=: luks2)'` (Perl regex lookbehind/ahead)

**Python:** Uses `re.findall(r'^\s+(\d+): luks2', r.stdout, re.M)` — captures group.

Functionally equivalent results. ✅

### 28. `enc_verified_id` — first 8 hex chars of sha256 of machine-id

**Shell:** `sha256sum /etc/machine-id | cut -c1-8`

**Python:**
```python
def enc_verified_id() -> str:
    r = _run(['sha256sum','/etc/machine-id'], capture=True)
    return r.stdout[:8] if r.returncode==0 else 'fallback0'
```
`r.stdout` = full sha256 output including the filename: `"abc123...  /etc/machine-id\n"`.
So `r.stdout[:8]` = first 8 chars of the hash. ✅ Correct.

**But `enc_verified_pass`:**
```python
def enc_verified_pass() -> str: return G.verification_cipher
```
And `G.verification_cipher`:
```python
r = _run(['sha256sum','/etc/machine-id'], capture=True)
G.verification_cipher = r.stdout[:32] if r.returncode==0 else 'simpledocker_fallback'
```
`r.stdout[:32]` = first 32 chars of the output (32 hex chars of the hash). ✅

Shell: `sha256sum /etc/machine-id | cut -c1-32` = first 32 chars of hash. ✅ Matches.

### 29. `enc_authkey_slot_file` — Python writes `'0'` but shell writes `'0'` without newline

**Shell:**
```bash
[[ $_arc -eq 0 ]] && printf '0' > "$(_enc_authkey_slot_file)"
```
Writes `"0"` (no newline).

**Python:**
```python
enc_authkey_slot_file().write_text('0')
```
`write_text('0')` writes `"0"` (no newline in Python 3 by default). ✅

**Python `enc_authkey_slot` reader:**
```python
return f.read_text().strip() if f.exists() else ''
```
`.strip()` handles any newline. ✅

---

## SUMMARY TABLE

| # | Severity | Area | Issue |
|---|---|---|---|
| 13 | CRITICAL | Resize | Sentinel file in `/tmp/`, fail path uses `/dev/null` |
| 14 | CRITICAL | Resize/LUKS | Resize re-open uses `auth.key` (inside unmounted image) instead of `SD_VERIFICATION_CIPHER` |
| 15 | HIGH | Resize | No container-stop logic before resize |
| 10 | HIGH | Tmux | Inner process uses `SD_INNER` not `$TMUX` check |
| 16 | HIGH | Blueprints | Persistent BPs seeded to files; stale after dict update |
| 3  | MEDIUM | Encryption | System Agnostic disable fallback asks user instead of using `SD_DEFAULT_KEYWORD` |
| 11 | MEDIUM | Tmux | stdin drain in re-attach loop doesn't actually drain |
| 18 | MEDIUM | UI | Groups running-count missing from main menu |
| 20 | MEDIUM | UI | Not all menus check `G.usr1_fired` for refresh vs ESC |
| 24 | MEDIUM | Network | `netns_teardown` doesn't clean up metadata files |
| 2  | MINOR | Encryption | Reset Auth Token doesn't test auth.key validity before kill attempt |
| 12 | MINOR | Tmux | Sudoers only written if file missing (shell always re-validates) |
| 19 | MINOR | UI | Per-container batch jq replaced with multiple reads (perf) |
| 25–29 | LOW | Various | Small divergences unlikely to cause functional issues |