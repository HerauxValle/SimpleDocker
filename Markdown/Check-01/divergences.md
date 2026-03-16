# services.py Divergences from services.sh
**Self-contained. No shell script needed. Every fix described in full.**
Ordered by severity: HIGH → MEDIUM → LOW → VISUAL.

---

## HIGH — Breaks core functionality

---

### DIV-001 · `validate_containers` — body is a stub, never writes `installed: false`

**Shell (`_validate_containers`, line 1891):**
Iterates `$CONTAINERS_DIR/*/`, reads each `state.json`. If `installed == true` but the `install_path` directory does not exist on disk, calls `_set_st "$cid" installed false` — writes the corrected value back to `state.json`.

**Python (`validate_containers`, line 605):**
Performs the same read-and-check, detects the missing directory, but the `# Installation path missing — clear installed flag` comment is followed by a bare `pass` (no-op). The flag is **never written back**. Every subsequent menu render still shows the container as installed.

**Fix:**
```python
# replace the pass at the end of validate_containers with:
data['installed'] = False
sf.write_text(json.dumps(data, indent=2))
```

---

### DIV-002 · `run_job` — never sets `SD_INSTALLING = cid`

**Shell (`_run_job`, line ~2895):**
Before launching the tmux install session:
```bash
_tmux_set SD_INSTALLING "$cid"
```
This is what `_installing_id()` reads everywhere to know which container is currently installing, and what `_cleanup_stale_lock` clears on startup.

**Python (`run_job`, line 1977):**
The function is never called with `tmux_set('SD_INSTALLING', cid)`. It only ever **clears** `SD_INSTALLING` (in `process_install_finish` at line 2022, and in `quit_all` at line 5716). The result: the yellow installing-dot never appears, `_cleanup_stale_installing()` has nothing to clean, and the "already installing" guard in the container submenu always evaluates false.

**Fix:**
```python
# In run_job(), immediately after the inst session is started with _tmux():
tmux_set('SD_INSTALLING', cid)
```

---

### DIV-003 · `_pick_storage_profile` — traverses wrong path, always returns `None`

**Shell (`_pick_storage_profile`, line 4322):**
Iterates `$STORAGE_DIR/*/` and filters profiles where `_stor_read_type(scid) == stype`. Shows a fzf picker with name/size/in-use status. Returns the chosen `scid`.

**Python (`_pick_storage_profile`, line 2807):**
```python
d = G.storage_dir / cid          # WRONG: e.g. Storage/abc12345/
if not d.is_dir(): return None   # this path never exists
```
Storage profiles live at `Storage/<scid>/`, not `Storage/<cid>/`. The `cid` subdirectory never exists, so the function always returns `None` immediately. Any container start that requires a storage profile selection silently aborts.

The function also ignores storage_type filtering and shows a completely different (minimal) UI compared to the shell.

**Fix:** Replace the function body to mirror shell logic:
```python
def _pick_storage_profile(cid: str) -> Optional[str]:
    stype = _stor_type_from_sj(cid)
    if _stor_count(cid) == 0: return ''
    if not G.storage_dir or not G.storage_dir.is_dir():
        v = finput('New storage profile name:\n  (leave blank for Default)')
        if v is None: return None
        return _stor_create_profile(cid, stype, v or 'Default')
    options = []; scid_map = []
    new_label = f'{GRN}+  New profile…{NC}'
    for sdir in sorted(G.storage_dir.iterdir()):
        if not sdir.is_dir(): continue
        scid = sdir.name
        if _stor_read_type(scid) != stype: continue
        pname = _stor_read_name(scid) or '(unnamed)'
        try: sz = _run(['du','-sh',str(sdir)], capture=True).stdout.split()[0]
        except: sz = '?'
        active_cid = _stor_read_active(scid)
        if active_cid and active_cid != cid and tmux_up(tsess(active_cid)):
            options.append(f'{DIM}○  {pname}  [{scid}]  {sz}  — in use by {cname(active_cid)}{NC}')
            scid_map.append('__inuse__'); continue
        elif active_cid and active_cid != cid:
            _stor_clear_active(scid)
        options.append(f'●  {pname}  [{scid}]  {sz}'); scid_map.append(scid)
    options.append(new_label); scid_map.append('__new__')
    sel = fzf_run(options, header=f'{BLD}── Storage profile ──{NC}')
    if not sel: return None
    sc = clean(sel)
    for i, opt in enumerate(options):
        if clean(opt) == sc:
            mapped = scid_map[i]
            if mapped == '__inuse__': pause('That profile is in use.'); return None
            if mapped == '__new__':
                v = finput('New storage profile name:\n  (leave blank for Default)')
                if v is None: return None
                return _stor_create_profile(cid, stype, v or 'Default')
            return mapped
    return None
```

---

### DIV-004 · `build_start_script` — env vars written outside heredoc; `CONTAINER_ROOT` wrong value inside chroot

**Shell (`_build_start_script`, line 2971):**
Inside the `start.sh` generator, the shell builds a compact `env_str` with `CONTAINER_ROOT=/` (absolute path **from inside the chroot**) and bakes it directly into the chroot `-c` argument:
```bash
_chroot_inner_cmd=$(printf '%q' "cd / && $env_str$_nv_ld && $chroot_cmd")
_exec_inner=$(printf '_chroot_bash %q -c %s' "$install_path" "$_chroot_inner_cmd")
```
The environment is thus part of the shell string passed to `chroot`, not a separate block that `sudo` could strip.

**Python (`build_start_script`, line 1675):**
Calls `_env_exports(cid, ip)` which produces `export CONTAINER_ROOT='/full/host/path'` (the absolute host path) and writes it **before** the `sudo nsenter` heredoc. `sudo` with `env_reset` (no `SETENV` in sudoers) strips these exports before the inner bash process runs. Inside the chroot, `$CONTAINER_ROOT` is empty. Any `[start]` block that references `$CONTAINER_ROOT/…` silently becomes `/…`, which may or may not work accidentally. The `PATH`, `VIRTUAL_ENV`, `PYTHONPATH`, and XDG variables are also lost.

**Fix:** The non-cuda path inside the heredoc body must embed the env inline (as shell does), with `CONTAINER_ROOT=/`:
```python
# inside the heredoc body (after _chroot_bash definition), before the _chroot_bash call:
env_str = ("export CONTAINER_ROOT=/ HOME=/ VIRTUAL_ENV=/venv PYTHONNOUSERSITE=1 PIP_USER=false "
           "PATH=\"/venv/bin:/python/bin:/.local/bin:/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:$PATH\"")
for k, v in d.get('environment', {}).items():
    sv = str(v)
    if sv == 'generate:hex32': sv = '...'   # same secret-file logic
    sv_inner = sv.replace('$CONTAINER_ROOT', '')  # strip prefix, chroot root is /
    if k in ('LD_LIBRARY_PATH', 'LIBRARY_PATH', 'PKG_CONFIG_PATH'):
        env_str += f' {k}="{sv_inner}:${{{k}:-}}"'
    else:
        env_str += f' {k}="{sv_inner}"'
exec_cmd_for_chroot = exec_cmd.replace('$CONTAINER_ROOT/', '/').replace('$CONTAINER_ROOT', '/')
f.write(f'_chroot_bash {str(ip)!r} -c "cd / && {env_str}{nv_ld} && {exec_cmd_for_chroot}"\n')
```

---

### DIV-005 · `_env_exports` — `generate:hex32` not persisted; regenerated every start

**Shell (`_env_exports`, line 2554):**
For `generate:hex32` env values, produces a literal shell expression:
```bash
$(openssl rand -hex 32 2>/dev/null || ...)
```
This executes at container-start time and generates a **new** random value every time. The generated value is not persisted.

**Python (`_env_exports`, line 1629):**
Checks for a secret file (`$storage_dir/scid/.sd_secret_KEY` or `$containers_dir/cid/.sd_secret_KEY`), reuses it if present, otherwise generates and **saves** it:
```python
pv = (f'$(if [[ -f {sf_q!r} ]]; then cat {sf_q!r}; '
      f'else v=$(openssl rand -hex 32 ...); printf "%s" "$v" > {sf_q!r} ...; printf "%s" "$v"; fi)')
```

**Verdict:** Python has **better** behaviour (secrets survive restarts). The shell should adopt the Python approach. Document this as intentional improvement — but note the divergence so it is not accidentally reverted.

---

### DIV-006 · `_env_exports` (install-script context) — `_sd_sp` line missing in Python

**Shell (`_env_exports`, line 2563):**
```bash
_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if 'site-packages' in p and '/usr' not in p), ''))" 2>/dev/null)
```
Sets `_sd_sp` (user site-packages path) used by downstream PATH/PYTHONPATH logic.

**Python (`_env_exports`, line 1629):**
This line is absent. The `_sd_vsp` logic (venv glob) is present, but `_sd_sp` is not.

**Fix:** Add to `_env_exports` output lines:
```python
lines.append('_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if \'site-packages\' in p and \'/usr\' not in p), \'\'))" 2>/dev/null)')
```

---

### DIV-007 · `_cr_prefix` — missing passthrough conditions

**Shell (`_cr_prefix`, line 2179):** Passes value through unchanged if it:
- starts with `/`, `~`, or `$`
- contains `$`
- contains `://`
- is a pure integer (`[[ "$v" =~ ^[0-9]+$ ]]`)
- contains `:` (port numbers, key=value pairs)
- matches IPv4 (`[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]`)

**Python (`_cr_prefix`, line 1621):** Only checks startswith `('/', '$', '~', '"', "'")`.

**Missing in Python:** pure-number passthrough, colon passthrough, IPv4 passthrough, `://` passthrough.

**Effect:** A value like `8080` (port), `127.0.0.1` (host), `redis://…` (URL), or `data:logs` (colon-pair) gets incorrectly prefixed with `$CONTAINER_ROOT/`.

**Fix:**
```python
def _cr_prefix(val: str) -> str:
    if not val: return val
    if val.startswith(('/', '$', '~', '"', "'")): return val
    if re.match(r'^\d+$', val): return val          # pure integer
    if ':' in val: return val                        # port pair / URL / key:val
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', val): return val  # IPv4
    if '://' in val: return val
    return f'$CONTAINER_ROOT/{val}'
```

---

### DIV-008 · `start_ct` — missing `_guard_space` call

**Shell (`_start_container`, line 3235):**
```bash
_guard_space || return 1
```
Called at the very top, before any storage or network setup. Aborts if < 2 GiB free.

**Python (`start_ct`, line 1455):**
No `_guard_space()` call. A container can be started on a full image, resulting in silent write failures or corrupted state.

**Fix:** Add as the first check in `start_ct`:
```python
def start_ct(cid: str, mode='background', profile_cid: str=''):
    if not _guard_space(): return
    if tmux_up(tsess(cid)): return
    ...
```

---

### DIV-009 · `start_ct` — missing `pane-exited` → `kill-session` hook

**Shell (`_start_container`, line ~3296):**
```bash
tmux set-hook -t "$sess" pane-exited "kill-session -t $sess"
```
When the container process exits (crash, normal exit), the tmux session is automatically destroyed. The background watcher thread then fires SIGUSR1 to refresh the UI.

**Python (`start_ct`, line 1509):**
`set-hook pane-exited` is never set for the container session (only for install sessions in `run_job`). After the container exits, the session becomes a zombie (empty, lingering). The watcher thread (`_ct_watcher`) still fires because it polls `tmux_up(sess)` — but that loop **never terminates** because the dead session persists. The UI dot never goes red.

**Fix:**
```python
_tmux('set-hook', '-t', sess, 'pane-exited', f'kill-session -t {sess}')
```
Add immediately after `_tmux('set-option','-t',sess,'detach-on-destroy','off')`.

---

### DIV-010 · `stop_ct` — missing `sleep 0.2` before storage unlink; missing `pause` and `update_size_cache`

**Shell (`_stop_container`, line 3368):**
```
kill main session → kill sdTerm_ → netns_ct_del → kill sdAction_ → cron_stop_all → sleep 0.2 → stor_unlink → clear; pause "'name' stopped." → update_size_cache
```

**Python (`stop_ct`, line 1535):**
```
kill main session → kill sdTerm_ → kill sdCron_+sdAction_ → remove cron next-files → netns_ct_del → exposure_flush → stor_unlink → update_size_cache
```

Three concrete differences:
1. **No `sleep 0.2`** between cron/action session kill and `_stor_unlink`. The cron runner may still have the storage path open; unlink races against it.
2. **No `pause("'name' stopped.")`** — user gets no feedback after stopping.
3. **`exposure_flush` called redundantly** — shell already calls it from inside `netns_ct_del` (line 592). Python calls `netns_ct_del` (which does NOT call exposure_flush — correctly), then calls `exposure_flush` separately. Net effect is the same, but it's an ordering divergence.

**Fix:**
```python
# after killing all cron/action sessions and before stor_unlink:
time.sleep(0.2)
# ... stor_unlink ...
update_size_cache(cid)
# add at end of stop_ct:
pause(f"'{cname(cid)}' stopped.")
```

---

### DIV-011 · `_cron_start_one` — cron sleep not interruptible; `sleep` vs `sleep & wait $!`

**Shell (`_cron_start_one`, line 3172):**
```bash
sleep "$_cron_secs" &
wait $!
```
Using `wait` on a backgrounded sleep means the wait is interruptible by signals. When the cron session is killed, `wait` returns immediately and the loop exits cleanly via the `[[ -f "$_cron_next_file" ]] || exit 0` guard.

**Python (`_cron_start_one`, line 1590/1603):**
```bash
sleep "$_secs"
```
Plain foreground `sleep`. A `kill-session` sends SIGHUP to the shell, which kills `sleep` too — so functionally it works. But the shell pattern is safer on hosts where SIGHUP is blocked or ignored.

**Fix:** Change both occurrences in the generated script from `sleep "$_secs"` to `sleep "$_secs" &\n    wait $!`.

---

### DIV-012 · `_cron_start_one` — jailed cron missing `proc/sys/dev` mounts

**Shell (`_cron_start_one`, line 3183):**
Inside the jailed (non-`--unjailed`) cron heredoc, mounts proc/sys/dev into ubuntu_dir before the chroot:
```bash
mount -t proc proc "$_ub/proc"
mount --bind /sys "$_ub/sys"
mount --bind /dev "$_ub/dev"
```

**Python (`_cron_start_one`, line 1607):**
```python
f.write(f'mount --bind {ip} {ub}/mnt 2>/dev/null||true\n')
f.write(f'_cb {ub} -c "cd /mnt && {inner}"\n')
```
`proc`, `sys`, and `dev` are never mounted. Any cron command that needs `/proc`, `/sys`, or device access inside the chroot fails silently.

**Fix:** Add before the `_cb` call in the non-unjailed branch:
```python
f.write(f'mount -t proc proc {ub}/proc 2>/dev/null||true\n')
f.write(f'mount --bind /sys {ub}/sys 2>/dev/null||true\n')
f.write(f'mount --bind /dev {ub}/dev 2>/dev/null||true\n')
```

---

### DIV-013 · `service.json` schema — cron key `cmd` vs `command`

**Shell (`_bp_compile_to_json`, line 2150):**
Compiled `service.json` stores cron entries with key `"cmd"`:
```json
{"name":"ping","interval":"10s","cmd":"echo hi","flags":""}
```
Shell `_cron_start_all` reads `.crons[$i].cmd`.

**Python (`_parse_cron_line`, line 1186):**
Returns dict with key `"command"`:
```python
return {'interval':interval,'name':name,'command':cmd,'sudo':sudo,'unjailed':unjailed}
```
Python `_cron_start_one` reads `cr.get('command','')`.

**Effect:** If a `service.json` was compiled by the shell and then read by Python (or vice-versa), all cron commands are empty strings — crons start but run nothing. Additionally Python compiled JSON uses `"sudo"/"unjailed"` booleans while shell uses a `"flags"` string. This is a **cross-compatibility schema break**.

**Fix:** Standardise on one schema. Easiest: update `_parse_cron_line` to emit `'cmd'` and `'flags'` (matching shell), then update `_cron_start_one` to read `cr.get('cmd','')` and parse flags string:
```python
return {'interval':interval,'name':name,'cmd':cmd,
        'flags': ('--sudo ' if sudo else '') + ('--unjailed' if unjailed else '')}
```
And in `_cron_start_one`:
```python
cmd = cr.get('cmd', cr.get('command',''))
flags = cr.get('flags','')
use_sudo = '--sudo' in flags
unjailed = '--unjailed' in flags
```

---

### DIV-014 · `_SD_CAP_DROP_DEFAULT` — wrong capabilities

**Shell (line 3311):**
```
cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_mknod,cap_audit_write,cap_audit_control,cap_syslog
```

**Python (line 1398):**
```
cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_sys_admin,cap_net_admin,cap_syslog
```

Python **adds** `cap_sys_admin` and `cap_net_admin` (breaks containers that need mounts or networking), and **removes** `cap_mknod`, `cap_audit_write`, `cap_audit_control`.

**Fix:**
```python
_SD_CAP_DROP_DEFAULT = ('cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,'
                        'cap_mknod,cap_audit_write,cap_audit_control,cap_syslog')
```

---

### DIV-015 · `_ensure_ubuntu` — missing sanity check; wrong sentinel files; missing `.ubuntu_default_pkgs` write; `set -e` difference

**Shell (`_ensure_ubuntu`, line 1472):**
- Opens with sanity check: if `.ubuntu_ready` exists but `usr/bin/apt-get` does not → removes `.ubuntu_ready` before proceeding.
- Sentinel files: `.ubuntu_ok_flag` / `.ubuntu_fail_flag`.
- After successful install, writes `DEFAULT_UBUNTU_PKGS` to `.ubuntu_default_pkgs` (used by drift detection).
- Install script traps INT; does **not** use `set -e`.
- Kills `sdUbuntuSetup` session from **inside** the script body at end.

**Python (`_ensure_ubuntu`, line 4653):**
- No sanity check.
- Sentinel files: `.ub_ok` / `.ub_fail` — different names. The shell's `ubuntu_menu` references `.ubuntu_ok_flag`/`.ubuntu_fail_flag`; if this Python function is called from a context expecting those names, the wait loop never terminates.
- Does **not** write `.ubuntu_default_pkgs`.
- Script uses `set -e` — any minor command failure (e.g. `mount --bind` fallback) aborts install.
- Does not kill session from within script.

**Fix:**
1. Add sanity check at top of `_ensure_ubuntu`:
```python
ready_f = G.ubuntu_dir/'.ubuntu_ready'
if ready_f.exists() and not (G.ubuntu_dir/'usr/bin/apt-get').exists():
    ready_f.unlink(missing_ok=True)
if ready_f.exists(): return
```
2. Use consistent sentinel names or update all call sites to match.
3. After `touch .ubuntu_ready`, write default pkgs:
```python
f.write(f'printf "%s\\n" {DEFAULT_UBUNTU_PKGS} > {ub!r}/.ubuntu_default_pkgs 2>/dev/null||true\n')
```
4. Remove `set -e`; add `trap '' INT`.

---

### DIV-016 · `ubuntu_menu` — "Sync default pkgs" missing "already up to date" check and missing `.ubuntu_default_pkgs` update

**Shell (`_ubuntu_menu`, line ~7010):**
Before running sync:
```bash
[[ ${#_cur_missing[@]} -eq 0 && "$_SD_UB_PKG_DRIFT" == false ]] && pause "Already up to date." && continue
```
After successful sync:
```bash
printf '%s\n' "${cur_default_pkgs[@]}" > "$(_ubuntu_default_pkgs_file)"
_SD_UB_PKG_DRIFT=false
```

**Python (`ubuntu_menu`, line ~4601):**
Neither check is present. "Already up to date" is never shown. `.ubuntu_default_pkgs` is never updated after sync, so `ub_cache_check` always reports drift.

**Fix:**
```python
if 'Sync default pkgs' in sc2:
    installed_names = {p for p,v,s in pkgs}
    missing = [p for p in DEFAULT_UBUNTU_PKGS.split() if p not in installed_names]
    if not missing and not G.ub_pkg_drift:
        pause('Already up to date.'); continue
    sync_pkgs = ' '.join(missing) if missing else DEFAULT_UBUNTU_PKGS
    cmd = f'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {sync_pkgs} 2>&1'
    if not _guard_ubuntu_pkg(): continue
    _ubuntu_pkg_op('sdUbuntuPkg','Sync default pkgs',cmd)
    # after op completes:
    try:
        (G.ubuntu_dir/'.ubuntu_default_pkgs').write_text('\n'.join(DEFAULT_UBUNTU_PKGS.split()))
    except: pass
    G.ub_pkg_drift = False; G.ub_cache_loaded = False
```

---

### DIV-017 · `_force_quit` — missing `mnt_*/` sweep, LUKS close, loop detach

**Shell (`_force_quit`, line 337):**
After killing container sessions and calling `_unmount_img`, additionally:
1. Sweeps `$SD_MNT_BASE/mnt_*/` — umount + losetup -d + rmdir each.
2. Closes all `/dev/mapper/sd_*` LUKS mappers and detaches their loop devices.
3. Detaches any remaining loop devices backing simpleDocker images.

**Python (`_force_quit`, line 5864):**
Steps 1–3 are absent. Only calls `unmount_img()` then `shutil.rmtree(sd_mnt_base)`.

**Fix:** After `unmount_img()`:
```python
# sweep mnt_* dirs
for mnt in G.sd_mnt_base.glob('mnt_*/'):
    _sudo('umount','-lf',str(mnt))
    lo_r = _run(['findmnt','-n','-o','SOURCE',str(mnt)], capture=True)
    if lo_r.stdout.strip().startswith('/dev/loop'):
        _sudo('losetup','-d',lo_r.stdout.strip())
    try: mnt.rmdir()
    except: pass
# close LUKS mappers
for mp in Path('/dev/mapper').glob('sd_*'):
    if mp.is_block_device():
        nm = mp.name
        r2 = _sudo('cryptsetup','status',nm, capture=True)
        lo = next((l.split()[-1] for l in r2.stdout.splitlines() if 'device:' in l), '')
        _sudo('cryptsetup','close',nm)
        if lo.startswith('/dev/loop'): _sudo('losetup','-d',lo)
# detach remaining simpleDocker loop devices
r3 = _run(['sudo','-n','losetup','-a'], capture=True)
for line in r3.stdout.splitlines():
    if 'simpleDocker' in line:
        _sudo('losetup','-d',line.split(':')[0])
```

---

### DIV-018 · `_proxy_start` — missing `_proxy_ensure_sudoers`; wrong step order; different caddy launch method

**Shell (`_proxy_start`, line 6347):**
Order: `_proxy_write` → `_proxy_update_hosts add` → **`_proxy_ensure_sudoers`** → `_proxy_dns_start` → `avahi-daemon` → `_avahi_start` → launch caddy via `setsid sudo -n "$(_proxy_caddy_runner)"…`.

`_proxy_caddy_runner` is a wrapper script `run.sh` that sets `CADDY_STORAGE_DIR` and execs caddy. `_proxy_ensure_sudoers` also **creates** this wrapper script. If this step is skipped, `run.sh` does not exist and caddy cannot start.

**Python (`_proxy_start`, line 4842):**
Order: `_proxy_write` → `_proxy_update_hosts` → `avahi-daemon` → **`_avahi_start`** → **`_proxy_dns_start`** → launch caddy via `subprocess.Popen(['sudo','-n',caddy,'run','--config',cf,'--pidfile',pf])`.

Three divergences:
1. `_proxy_ensure_sudoers` is never called → `run.sh` never created → shell-side caddy can't start (relevant if both codepaths share the image).
2. `_proxy_dns_start` and `_avahi_start` swapped versus shell order.
3. Python passes `--pidfile` directly to caddy CLI; shell captures PID from `$!` and writes it manually. Both work but produce different caddy behaviour (caddy's own pidfile vs shell pidfile).

**Fix:**
```python
def _proxy_start(background=False) -> bool:
    ...
    _proxy_write()
    _proxy_update_hosts('add')
    _proxy_ensure_sudoers()   # add this
    _proxy_dns_start()        # swap order: dns before avahi
    if _run(['systemctl','is-active','--quiet','avahi-daemon']).returncode != 0:
        _sudo('systemctl','start','avahi-daemon')
    _avahi_start()
    ...
```
And implement `_proxy_ensure_sudoers` to create `run.sh`.

---

### DIV-019 · `run_job` — missing `_guard_space` call

**Shell (`_run_job`, line ~2751):**
```bash
_guard_space || return 1
```
Called before generating the install script.

**Python (`run_job`, line 1977):**
No `_guard_space()` call. An install can begin on a full image.

**Fix:**
```python
def run_job(cid: str, mode='install', force=False):
    compile_service(cid)
    if not _guard_space(): return
    ...
```

---

## MEDIUM — Incorrect behaviour, not immediately fatal

---

### DIV-020 · `_pkg_manifest` — cache key scheme diverges; update label missing timestamp

**Shell (`_build_pkg_update_item`, line 4862):**
- Single cache file: `CACHE_DIR/gh_tag/$cid` (all repos combined into one file).
- Installed-tag file: `CACHE_DIR/gh_tag/$cid.inst`.
- Update label: `"[P] Packages — {ts} — Update available"` (includes timestamp).
- No-update label: `"[P] Packages — ✓ {ts}"`.

**Python (`_build_pkg_manifest_item_for`, line 3594):**
- Per-repo cache files: `gh_tag/{cid}_{repo_sanitized}` and `.inst`.
- Update label: `"[P] Packages Update available"` — **timestamp missing**.
- `.inst` files are never written by any Python code path, so `has_update` can only be true when `latest` exists and `installed` is empty — meaning after the first check it always shows "Update available" until the user manually updates.

**Fix:** Write `.inst` file after a successful update in `_do_pkg_update`. Fix update label to include `ts`:
```python
items.append(f'{DIM}[P]{NC} Packages {DIM}— {ts}{NC} — {YLW}Update available{NC}')
```

---

### DIV-021 · `exposure_apply` — Python applies iptables even when container is not running

**Shell (`_container_submenu` exposure handler, line 5705):**
```bash
tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
```
Only applies iptables rules if the container session is alive.

**Python (`container_submenu` exposure handler, line ~3406):**
```python
exposure_apply(cid)
```
Always calls regardless of running state. Adding DROP rules for a stopped container pollutes iptables with rules that never get flushed (since `stop_ct` only flushes for running containers).

**Fix:**
```python
if tmux_up(tsess(cid)): exposure_apply(cid)
```

---

### DIV-022 · `_guard_space` — message text differs; missing `mountpoint -q` pre-check

**Shell (line 1559):**
Pre-check: `mountpoint -q "$MNT_DIR" 2>/dev/null || return 0` — if not a real mountpoint (e.g. direct-dir mode), skip check.
Message: `'⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.'`

**Python (line 3117):**
No mountpoint pre-check.
Message: `'⚠  Less than 2 GiB free. Use Other → Resize image first.'`

**Fix:**
```python
def _guard_space() -> bool:
    if not G.mnt_dir: return True
    if _run(['mountpoint','-q',str(G.mnt_dir)]).returncode != 0: return True
    r = _run(['df','-k',str(G.mnt_dir)], capture=True)
    avail = int(r.stdout.splitlines()[-1].split()[3]) if r.returncode==0 else 9999999
    if avail < 2097152:
        pause('⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.')
        return False
    return True
```

---

### DIV-023 · `ct_attach` — Python skips confirm dialog with detach hint

**Shell:** Uses `_tmux_attach_hint` which shows:
```
Attach to 'name'
  Press ctrl-\ to detach without stopping.
[Yes, confirm] [No]
```

**Python:** Directly calls `_tmux('switch-client','-t',sess)` with no confirm. Users don't know the detach key and may accidentally close the container with Ctrl-C.

**Fix:**
```python
elif sc == L['ct_attach']:
    if confirm(f"Attach to '{n}'\n\n  Press {KB['tmux_detach']} to detach without stopping."):
        _tmux('switch-client','-t',tsess(cid))
```

---

### DIV-024 · `main_menu` — image size uses `df` total instead of `stat` file size

**Shell (line ~7268):**
```bash
total_bytes=$(stat -c%s "$IMG_PATH")
total_gb=$(awk "BEGIN{printf \"%.1f\",${total_bytes}/1073741824}")
```
`stat -c%s` returns the `.img` file size = the pre-allocated image capacity.

**Python (line ~5749):**
```python
total_gb = int(parts[1])/1048576  # from df -k, col 1 = filesystem blocks
```
`df` column 1 is the filesystem's 1K-block count, which is slightly smaller than the image file size due to LUKS/btrfs overhead. Minor discrepancy in displayed GB.

**Fix:**
```python
if G.img_path and G.img_path.exists():
    total_bytes = G.img_path.stat().st_size
    total_gb = total_bytes / 1073741824
```

---

### DIV-025 · `main_menu` — imported blueprints always counted; shell only when autodetect active

**Shell (line ~7239):**
Always counts `bp_names + pbp_names + ibp_names` for `n_bps`.

**Python (line ~5742):**
```python
if _bp_autodetect_mode() != 'Disabled':
    n_bp += len(_list_imported_names())
```
Only adds imported when autodetect is not Disabled. The number shown in the main menu will differ from shell.

**Fix:** Always include imported count (match shell):
```python
n_bp = len(_list_blueprint_names()) + len(_list_persistent_names()) + len(_list_imported_names())
```

---

### DIV-026 · `_installing_menu` — Python does not dim non-action items

**Shell (`_installing_menu`, line 5162):**
Items that do not already contain ANSI escape codes are wrapped in `${DIM}…${NC}` before display — visually greying out navigation/status items during an install.

**Python (`_fzf_with_watcher`, line 3462):**
Items are passed to `fzf_run` as-is with no dimming transformation.

**Fix:** In `_fzf_with_watcher` or at call site, dim items lacking ANSI:
```python
dimmed = [x if '\033[' in x else f'{DIM} {x}{NC}' for x in items]
```

---

## LOW — Minor behavioural gaps

---

### DIV-027 · Cron countdown display — Python shows countdown; shell does not

**Shell container_submenu cron label (line 5555):**
```
" ⏱  name  [interval]"
```
No countdown.

**Python container_submenu cron label (line 3329):**
```
" ⏱  name  [interval]  next: Xm Xs"
```
Adds countdown from next-timestamp file.

**Verdict:** Python has extra functionality. Not a regression. Shell should adopt this.

---

### DIV-028 · Cron countdown — Python missing days format

**Shell `_cron_countdown` (line 3131):** Formats `Xd Xh Xm Xs` for intervals ≥ 1 day.

**Python countdown (line 3329):** Only handles hours/minutes — no days. A 24h+ cron shows `24h 00m 00s` instead of `1d 00h 00m 00s`.

**Fix:**
```python
d2, rem3 = divmod(rem, 86400)
h, rem2 = divmod(rem3, 3600); m2, s2 = divmod(rem2, 60)
if d2: countdown = f'  {DIM}next: {d2}d {h:02d}h {m2:02d}m{NC}'
elif h: countdown = f'  {DIM}next: {h}h {m2:02d}m {s2:02d}s{NC}'
else: countdown = f'  {DIM}next: {m2}m {s2:02d}s{NC}'
```

---

### DIV-029 · `stop_ct` — cron sessions killed before `netns_ct_del`; shell kills them after

**Shell order:** main session → sdTerm_ → **`netns_ct_del`** → sdAction_ → cron_stop_all → sleep 0.2 → stor_unlink

**Python order:** main session → sdTerm_ → sdCron_ + sdAction_ → cron next-files → **`netns_ct_del`** → exposure_flush → stor_unlink

Shell kills network namespace **before** killing cron sessions. This ensures cron jobs that are mid-execution lose network access immediately (consistent with the container being stopped). Python preserves network for cron jobs slightly longer.

**Fix:** Move `netns_ct_del` call before the cron/action session kill loop in `stop_ct`.

---

### DIV-030 · `write_pkg_manifest` — stores raw lists vs parsed package names

**Shell (`_write_pkg_manifest`, line 4835):** Parses `.deps` string through `_deps_parse_split`, producing a flat list of apt package tokens. Parses `.pip` and `.npm` strings similarly. Stores resolved package names.

**Python (`write_pkg_manifest`, line 1971):** Reads already-compiled `service.json` arrays directly and stores them verbatim. The `.deps` array contains the raw deps string (a single element), not individual package names.

The `_build_pkg_manifest_item_for` function counts `len(m.get('deps',[]))` — this will always be 1 (the whole string) rather than the number of packages, making the package count display wrong.

**Fix:** Parse deps string in `write_pkg_manifest`:
```python
import shlex
deps_str = d.get('deps','')
dep_list = shlex.split(deps_str.replace(',',' ')) if isinstance(deps_str,str) else deps_str
```

---

### DIV-031 · `_ensure_ubuntu` — Python does not write `.ubuntu_default_pkgs` for drift detection

(Partially covered in DIV-015. Explicit call-out for drift only.)

`ub_cache_check` reads `.ubuntu_default_pkgs` to compare against `DEFAULT_UBUNTU_PKGS`. If this file is never created, drift is always reported as `true` regardless of what is installed. The yellow `[changes detected]` tag appears permanently.

**Fix:** In `_ensure_ubuntu` script, after `touch .ubuntu_ready`:
```bash
printf '%s\n' curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential > /path/to/ubuntu_dir/.ubuntu_default_pkgs
```
Or write the DEFAULT_UBUNTU_PKGS from Python before launching the tmux session.

---

### DIV-032 · `start_ct` — missing `sleep 0.5` before return in background mode

**Shell (`_start_container`, line ~3300):**
After cron startup and security apply:
```bash
sleep 0.5
```
Gives the tmux session a moment to initialise before the menu re-renders (prevents flash of "not running" state).

**Python (`start_ct`, line 1528):**
No sleep. UI may briefly show the container as stopped before the session registers.

**Fix:** Add `time.sleep(0.5)` at the end of `start_ct` before returning.

---

## VISUAL — Label / display divergences

---

### DIV-033 · `_pkg_update_item` label — update label includes timestamp in shell, not in Python

**Shell:** `[P] Packages — {ts} — Update available`
**Python:** `[P] Packages Update available` (no `ts`, no `—` separators)

**Fix:** See DIV-020.

---

### DIV-034 · Main menu separator style

**Shell (line 7226):** `"${BLD}  ─────────────────────────────────────${NC}"` — bold, leading spaces.
**Python (line ~5762):** `f'{DIM}─────────────────────────────────────────{NC}'` — dim, no leading spaces, two extra dashes.

**Fix:**
```python
f'{BLD}  ─────────────────────────────────────{NC}'
```

---

### DIV-035 · `stop_ct` — no `clear` + `pause "stopped"` feedback

**Shell:** Ends with `clear; pause "'name' stopped."`.
**Python:** Silent. User returns to the menu with no confirmation the stop completed.

**Fix:** See DIV-010.

---

### DIV-036 · `_guard_space` pause message text differs

**Shell:** `'⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.'`
**Python:** `'⚠  Less than 2 GiB free. Use Other → Resize image first.'`

**Fix:** See DIV-022.

---

### DIV-037 · `exposure_label` — Python identical; shell `_exposure_label` identical (no divergence)

Confirmed match. Listed for completeness — no action needed.

---

### DIV-038 · `_env_exports` install-script context — `_sd_sp` Python line absent

See DIV-006. The missing `_sd_sp=$(python3 -c …)` line is a functional gap (incorrect PYTHONPATH in some configs) as well as a visual/output divergence in the generated install script.

---

## Summary table

| ID | Area | Severity | One-line description |
|----|------|----------|----------------------|
| DIV-001 | `validate_containers` | HIGH | Never writes `installed:false` back to disk |
| DIV-002 | `run_job` | HIGH | Never sets `SD_INSTALLING=cid` |
| DIV-003 | `_pick_storage_profile` | HIGH | Traverses `Storage/<cid>/` (doesn't exist); always returns None |
| DIV-004 | `build_start_script` | HIGH | Env written outside heredoc; sudo strips it; CONTAINER_ROOT wrong |
| DIV-005 | `_env_exports` | HIGH* | `generate:hex32` persisted in Python (improvement), not in shell |
| DIV-006 | `_env_exports` | HIGH | `_sd_sp` python3 line missing |
| DIV-007 | `_cr_prefix` | HIGH | Missing number/colon/IPv4/URL passthrough conditions |
| DIV-008 | `start_ct` | HIGH | Missing `_guard_space` check |
| DIV-009 | `start_ct` | HIGH | Missing `pane-exited → kill-session` hook → zombie sessions |
| DIV-010 | `stop_ct` | HIGH | Missing sleep 0.2, missing pause, update_size_cache placement |
| DIV-011 | cron script | MEDIUM | `sleep` not interruptible (should be `sleep & wait $!`) |
| DIV-012 | cron script | HIGH | Jailed cron missing proc/sys/dev mounts |
| DIV-013 | service.json | HIGH | Cron key `cmd` (shell) vs `command` (Python); flags string vs booleans |
| DIV-014 | cap_drop | HIGH | Wrong capabilities: adds cap_sys_admin/cap_net_admin, drops cap_mknod/cap_audit_* |
| DIV-015 | `_ensure_ubuntu` | HIGH | Missing sanity check; wrong sentinels; missing default_pkgs; set -e wrong |
| DIV-016 | `ubuntu_menu` | MEDIUM | Missing "already up to date" check; missing .ubuntu_default_pkgs update |
| DIV-017 | `_force_quit` | HIGH | Missing mnt_* sweep, LUKS close, loop detach |
| DIV-018 | `_proxy_start` | HIGH | Missing ensure_sudoers; wrong step order; caddy launch method differs |
| DIV-019 | `run_job` | HIGH | Missing `_guard_space` |
| DIV-020 | pkg manifest | MEDIUM | Cache key scheme wrong; update label missing timestamp; .inst never written |
| DIV-021 | exposure | MEDIUM | Always applies iptables regardless of running state |
| DIV-022 | `_guard_space` | MEDIUM | Missing mountpoint check; wrong message text |
| DIV-023 | attach | MEDIUM | Missing confirm dialog with detach key hint |
| DIV-024 | main_menu | LOW | Image size uses df total instead of stat file size |
| DIV-025 | main_menu | LOW | Imported bp count conditional on autodetect mode |
| DIV-026 | installing_menu | LOW | Items not dimmed during install |
| DIV-027 | cron display | LOW | Python adds countdown (extra feature vs shell) |
| DIV-028 | cron countdown | LOW | Missing days format for ≥24h intervals |
| DIV-029 | `stop_ct` | LOW | netns_ct_del order swapped vs shell |
| DIV-030 | pkg manifest | MEDIUM | Stores raw string not parsed package list; count always 1 |
| DIV-031 | ubuntu drift | LOW | `.ubuntu_default_pkgs` never written → permanent drift warning |
| DIV-032 | `start_ct` | LOW | Missing sleep 0.5 before return |
| DIV-033 | pkg label | VISUAL | Update label missing timestamp |
| DIV-034 | main separator | VISUAL | Style/weight/length differs |
| DIV-035 | stop feedback | VISUAL | No clear + pause after stop |
| DIV-036 | guard message | VISUAL | Different wording |
| DIV-037 | exposure_label | — | Confirmed identical; no action |
| DIV-038 | env exports | HIGH | `_sd_sp` line absent (see DIV-006) |

---

## Additional Divergences (DIV-039 through DIV-052)

---

### DIV-039 · `_stop_group` — missing shared-group check; stops containers used by other running groups

**Shell (`_stop_group`, line 3490):**
Before stopping each container, iterates all other `.toml` group files. If the container appears in another group AND at least one other container in that group is running, sets `in_other=true` and skips stopping it.

**Python (`_stop_group`, line 3092):**
```python
for step in reversed(steps):
    if step.lower().startswith('wait'): continue
    cid = _ct_id_by_name(step)
    if not cid or not tmux_up(tsess(cid)): continue
    stop_ct(cid)
```
No shared-group check. Stops the container unconditionally even if another running group depends on it.

**Fix:** Before `stop_ct(cid)`, add:
```python
in_other = False
for gf in (G.groups_dir or Path('.')).glob('*.toml'):
    ogid = gf.stem
    if ogid == gid: continue
    members = _grp_containers(ogid)
    if step not in members: continue
    if any(_ct_id_by_name(oc) and tmux_up(tsess(_ct_id_by_name(oc)))
           for oc in members if oc != step):
        in_other = True; break
if in_other: continue
stop_ct(cid)
```

---

### DIV-040 · `_open_in` Terminal — shell opens host bash; Python opens nsenter+chroot inside container

**Shell (`_open_in_submenu`, line 5358):**
```bash
tmux new-session -d -s "$tsess_term" "cd $(printf '%q' "$tip") && exec bash"
```
Opens a plain bash shell in the install directory **on the host**. No namespacing or chroot.

**Python (`_open_in_submenu`, line 3232):**
```python
_tmux('new-session','-d','-s',sess,
      f'sudo -n nsenter --net=/run/netns/{ns} -- '
      f'unshare --mount --pid --uts --ipc --fork bash -c '
      f'"{bash_detect}sudo -n chroot {tip!r} \\"$_b\\""; '
      f'tmux kill-session -t {sess} 2>/dev/null||true')
```
Opens a shell **inside the container namespace and chroot**. Completely different environment — container's filesystem, network, PID space.

**Verdict:** The behaviours are opposite. Shell gives host access; Python gives container access. Decide on intended behaviour and make consistent. Python's approach is arguably more correct for container management.

---

### DIV-041 · `_open_in` File manager — shell stays in menu; Python exits submenu

**Shell:** After `xdg-open "$open_path" & disown`, execution falls through to the next loop iteration — stays in the Open In menu.

**Python:** After `subprocess.Popen(['xdg-open', open_path], ...)`, calls `return` — exits the submenu entirely.

**Fix:** Remove `return` after xdg-open in Python to match shell behaviour:
```python
elif 'File manager' in sc:
    open_path = str(install_path) if install_path else ''
    if not open_path: pause('No install path found.'); continue
    subprocess.Popen(['xdg-open', open_path], stderr=subprocess.DEVNULL, start_new_session=True)
    # no return — stay in menu like shell
```

---

### DIV-042 · Action runner — missing `_cr_prefix` on command binary in `select:` and plain segments

**Shell (action runner, line ~5780):**
For each non-`prompt:`/non-`select:` segment, applies `_cr_prefix` to the first token (command binary):
```bash
local cmd_bin_p; cmd_bin_p=$(_cr_prefix "$cmd_bin")
```
For `select:` segments, also applies `_cr_prefix` to the command binary:
```bash
local scmd_bin_p; scmd_bin_p=$(_cr_prefix "$scmd_bin")
```

**Python (`_run_action`, line 3504):**
Neither `select:` commands nor plain commands have `_cr_prefix` applied. A relative binary like `bin/list-items` in a `select:` segment runs as `bin/list-items` (not found on PATH) instead of `$CONTAINER_ROOT/bin/list-items`.

**Fix:** In the `select:` branch:
```python
scmd_parts = scmd.split(None, 1)
scmd_bin = _cr_prefix(scmd_parts[0]) if scmd_parts else scmd
scmd_rest = scmd_parts[1] if len(scmd_parts) > 1 else ''
full_scmd = f'{scmd_bin} {scmd_rest}'.strip()
f.write(f'_sd_list=$({full_scmd} 2>/dev/null)\n')
```
In the plain command branch:
```python
parts = seg.split(None, 1)
cmd_bin = _cr_prefix(parts[0]) if parts else seg
cmd_rest = parts[1] if len(parts) > 1 else ''
cmd_out = f'{cmd_bin} {cmd_rest}'.strip()
cmd_out = cmd_out.replace('{input}','$_sd_input').replace('{selection}','$_sd_selection')
f.write(cmd_out + '\n')
```

---

### DIV-043 · Action runner — no confirm/pause dialogs before/during action session

**Shell (action runner dispatch, line ~5806):**
- If action session already running: `pause("Action 'X' is still running.\n\n  Press ctrl-\ to detach.")` then switches.
- If action session is new: `pause("Starting 'X'...\n\n  Press ctrl-\ to detach.")` then switches.

**Python (`_run_action`, line 3539):**
- Already running: switches directly with no pause.
- New session: switches directly with no pause.

User has no visual feedback that anything happened, and no reminder of the detach key.

**Fix:**
```python
if tmux_up(sess):
    pause(f"Action '{dsl[:30]}' is still running.\n\n  Press {KB['tmux_detach']} to detach.")
    _tmux('switch-client','-t',sess)
else:
    _tmux('new-session',...)
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    pause(f"Starting action...\n\n  Press {KB['tmux_detach']} to detach.")
    _tmux('switch-client','-t',sess)
```

---

### DIV-044 · `service.json` action label schema — `⊙` baked in by Python at compile time; shell adds at render time

**Shell (`_bp_flush_section` [actions], line ~2004):**
Stores the raw label from the blueprint without modification:
```bash
BP_ACTIONS_NAMES+=("$albl")
```
In `container_submenu`, when building the display list, the `⊙` prefix is added dynamically:
```bash
if [[ "$_first_char" =~ ^[a-zA-Z0-9]$ ]]; then lbl="⊙  $lbl"; fi
```
`service.json` contains: `{"label": "Show logs", "dsl": "..."}`

**Python (`_parse_action_line`, line 1203):**
```python
if re.match(r'^[a-zA-Z0-9]', label): label = '⊙  ' + label
```
Applied at parse/compile time. `service.json` contains: `{"label": "⊙  Show logs", "dsl": "..."}`

**Effect:**
- Shell reads Python-compiled JSON → container_submenu adds another `⊙` → `"⊙  ⊙  Show logs"`.
- Python reads shell-compiled JSON → no `⊙` prefix → `"Show logs"` (plain, no icon).

**Fix:** Remove the auto-prefix from `_parse_action_line`, store label raw. Apply `⊙` at display time in `container_submenu`:
```python
# In _parse_action_line:
return {'label': label, 'dsl': dsl}  # no ⊙ prefix

# In container_submenu when building items:
for a in d.get('actions', []):
    lbl = a['label']
    if re.match(r'^[a-zA-Z0-9]', lbl): lbl = '⊙  ' + lbl
    action_labels.append(lbl)
    action_dsls.append(a['dsl'])
```

---

### DIV-045 · `run_job` / install launch — shell prompts "Attach or Background?"; Python always runs silently in background

**Shell (`_run_job` → `_tmux_launch`, line 5244):**
`_tmux_launch` shows an fzf picker:
```
▶  Attach — follow live output
   Background — run silently
```
with header showing the detach key hint. User chooses whether to watch the install live.

**Python (`run_job`, line 1977):**
Always launches in background. No prompt. User must manually navigate to the install session.

**Fix:** After creating the install session, offer attach/background:
```python
sel = fzf_run([f'{GRN}▶  Attach — follow live output{NC}',
               f'{DIM}   Background — run silently{NC}'],
              header=f'{BLD}── {mode.capitalize()}: {cname(cid)} ──{NC}\n'
                     f'{DIM}  Press {KB["tmux_detach"]} to detach at any time.{NC}')
if sel and 'Attach' in strip_ansi(sel):
    if os.environ.get('TMUX'):
        _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess}')
    else:
        _tmux('switch-client','-t',sess)
```

---

### DIV-046 · `health_check` — Python checks `environment.PORT` fallback; shell does not

**Shell (`_health_check`, line 427):**
```bash
port=$(jq -r '.meta.port // empty' "$sj" 2>/dev/null)
```
Only reads `meta.port`.

**Python (`health_check`, line 1390):**
```python
port = d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT')
```
Falls back to `environment.PORT` if `meta.port` is absent.

**Verdict:** Python has slightly better coverage. Not a regression. Document as intentional improvement.

---

### DIV-047 · `_edit_container_bp` — missing running/installing guard; different default editor; missing `_guard_space`

**Shell (`_edit_container_bp`, line 5436):**
```bash
tmux_up "$(tsess "$cid")" && _erun=true
_is_installing "$cid" && _einst=true
[[ "$_erun" == "true" || "$_einst" == "true" ]] && { pause "⚠  Stop the container before editing."; return 1; }
_guard_space || return 1
```
Default editor: `${EDITOR:-vi}`.

**Python (`_edit_container_bp`, line 3479):**
No running/installing check. No `_guard_space` call.
Default editor: `os.environ.get('EDITOR', 'nano')`.

**Fix:**
```python
def _edit_container_bp(cid: str):
    if tmux_up(tsess(cid)) or is_installing(cid):
        pause('⚠  Stop the container before editing.'); return
    if not _guard_space(): return
    editor = os.environ.get('EDITOR', 'vi')
    ...
```

---

### DIV-048 · `rename_container` — shell blocks rename for installed containers; Python allows it

**Shell (`_rename_container`, line 5459):**
```bash
[[ "$(_st "$cid" installed)" == "true" ]] && { pause "Rename is only available for uninstalled containers."; return 1; }
```

**Python (`_rename_container`, line 3492):**
No such check. Allows renaming installed containers and additionally rebuilds `start_script` (which the shell never does on rename).

**Fix:** Add guard:
```python
def _rename_container(cid: str, new_name: str) -> bool:
    if st(cid, 'installed', False):
        pause('Rename is only available for uninstalled containers.'); return False
    ...
    # remove the build_start_script call at end
```

---

### DIV-049 · `resize_image` — shell kills sessions directly; Python calls `stop_ct()` per container causing multiple pauses

**Shell (`_resize_image`, line ~1696):**
```bash
tmux send-keys -t "$_sess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$_sess" 2>/dev/null || true
```
Quick kill with no per-container pause messages.

**Python (`resize_image`, line ~5392):**
```python
for c in running_cts:
    stop_ct(c)
```
`stop_ct` calls `pause(f"'{cname(cid)}' stopped.")` for each container. If 3 containers are running, user sees 3 consecutive "stopped" pause screens before resize begins.

**Fix:** Inline the kill logic without calling `stop_ct`:
```python
for c in running_cts:
    sess2 = tsess(c)
    _tmux('send-keys','-t',sess2,'C-c','')
    time.sleep(0.3)
    _tmux('kill-session','-t',sess2)
tmux_set('SD_INSTALLING','')
time.sleep(0.5)
```

---

### DIV-050 · `help_menu` — encryption menu icon differs; LUKS check added in Python; `ub_cache_read` placement differs

Three sub-divergences:

1. **Icon:** Shell: `◈  Manage Encryption`. Python: `⚷  Manage Encryption`.

2. **LUKS pre-check:** Shell always opens `_enc_menu` regardless of whether image is LUKS.
   Python:
   ```python
   if G.img_path and img_is_luks(G.img_path): enc_menu()
   else: pause('Image is not encrypted.')
   ```
   If a user opens a non-LUKS image, shell opens the enc menu (which handles unencrypted gracefully); Python blocks with a pause.

3. **`ub_cache_read` placement:** Shell calls `_sd_ub_cache_read` inside the `while true` loop — refreshes ubuntu status on every menu render. Python calls `ub_cache_read()` once before the loop.

**Fix:**
```python
# 1. Change icon:
f'{DIM} ◈  Manage Encryption{NC}',
# 2. Remove LUKS guard:
elif 'Manage Encryption' in sc:
    enc_menu()
# 3. Move ub_cache_read inside loop:
while True:
    ub_cache_read()
    ...
```

---

### DIV-051 · `logs_browser` — shell sorts by filename; Python sorts by mtime

**Shell:** `find "$LOGS_DIR" -type f -name "*.log" | sort -r` — lexicographic reverse sort (newest by name convention since names include timestamps).

**Python:** `sorted(..., key=lambda f: f.stat().st_mtime, reverse=True)` — sorts by file modification time.

These produce different orderings when log files have been modified after creation (e.g. appended to). Usually equivalent, but not guaranteed.

**Fix:** Align to mtime sort (Python is more correct) or filename sort (shell). Pick one and document.

---

### DIV-052 · `active_processes_menu` — Python shows `sdCron_` sessions; shell does not; sdInst_ label source differs

**Shell session filter (line ~5856):** `grep -E "^sd_[a-z0-9]{8}$|^sdInst_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$"` — no `sdCron_`.

**Python session filter (line ~5273):** `re.match(r'^sd_[a-z0-9]{8}$|^sdInst_|^sdCron_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$', s)` — includes `sdCron_`.

Python also labels cron sessions with their cron name and container — shell never shows cron sessions at all.

**sdInst_ label:**
- Shell: `icid=$(_installing_id)` → reads `SD_INSTALLING` tmux env var → gets the cid that is currently installing → looks up container name.
- Python: `icid = sess[len('sdInst_'):]` → extracts cid directly from session name.

Since Python never sets `SD_INSTALLING` (DIV-002), the shell approach would return empty in Python context anyway — Python's direct extraction is more robust here.

**Verdict:** Python showing cron sessions is an improvement. sdInst_ label fix is correct in Python. Document as intentional improvements.

---

## Updated Summary Table (additions only)

| ID | Area | Severity | One-line description |
|----|------|----------|----------------------|
| DIV-039 | `_stop_group` | HIGH | Stops container shared with another running group |
| DIV-040 | `_open_in` Terminal | HIGH | Shell: host bash; Python: nsenter+chroot inside container |
| DIV-041 | `_open_in` File manager | LOW | Shell stays in menu; Python exits with return |
| DIV-042 | Action runner | MEDIUM | Missing `_cr_prefix` on select/plain command binaries |
| DIV-043 | Action runner | MEDIUM | No pause dialogs before/after action session start |
| DIV-044 | service.json actions | HIGH | `⊙` baked in at compile time vs render time → double/missing on cross-read |
| DIV-045 | `run_job` | MEDIUM | Shell prompts Attach/Background; Python always silently backgrounds |
| DIV-046 | `health_check` | LOW | Python also checks environment.PORT (improvement) |
| DIV-047 | `_edit_container_bp` | MEDIUM | Missing running guard, guard_space; wrong default editor (nano vs vi) |
| DIV-048 | `rename_container` | MEDIUM | Shell blocks rename for installed containers; Python allows it |
| DIV-049 | `resize_image` | MEDIUM | Python calls stop_ct() per container → multiple pause screens |
| DIV-050 | `help_menu` | LOW | Wrong encryption icon; LUKS pre-check blocks enc_menu; ub_cache_read outside loop |
| DIV-051 | `logs_browser` | LOW | Shell sorts by filename; Python sorts by mtime |
| DIV-052 | `active_processes_menu` | LOW | Python shows sdCron_ sessions; shell does not; sdInst_ label source differs |

---

## Additional Divergences (DIV-053 through DIV-058)

---

### DIV-053 · `blueprints_submenu` — new blueprint file extension `.toml` vs `.container`

**Shell (`_blueprints_submenu`, line 7557):**
```bash
bfile="$BLUEPRINTS_DIR/$bname.toml"
```

**Python (`blueprints_submenu`, line ~4452):**
```python
bfile = G.blueprints_dir / f'{bname}.container'
```

New blueprints created by shell are `.toml`; new blueprints created by Python are `.container`. Both scan for both extensions when listing, so existing files work. But the created extension diverges.

**Fix:** Use `.toml` to match shell:
```python
bfile = G.blueprints_dir / f'{bname}.toml'
```

---

### DIV-054 · `_build_update_items` — Python omits persistent blueprint update checks

**Shell (`_collect_bps_by_type`, line 4807):**
Scans both `BLUEPRINTS_DIR/*.toml|*.json` AND all persistent blueprints (via `_list_persistent_names`). Persistent matches shown with `[P]` tag; file matches with `[B]` tag.

**Python (`_build_update_items_for`, line 3559):**
Only scans `G.blueprints_dir`. No persistent blueprint lookup. A container whose blueprint only exists as a persistent (built-in) blueprint never shows an update entry.

**Fix:** After scanning blueprints_dir, also iterate persistent blueprints:
```python
for pname in _list_persistent_names():
    raw = _get_persistent_bp(pname)  # or however persistent BPs are read
    if not raw: continue
    bp = bp_parse(raw)
    if bp.get('meta',{}).get('storage_type') != stype: continue
    new_ver = str(bp.get('meta',{}).get('version',''))
    # ... build entry with [P] tag
    items.append(entry); idx.append(str(len(idx)))
```

---

### DIV-055 · `_do_blueprint_update` — Python skips same-version content diff check

**Shell (`_do_blueprint_update`, line 5126):**
If `cur_ver == new_ver`, runs `diff -q "$cur_src" "$bp_file"`. If files differ, prompts `"Changes detected (version X unchanged). Apply configuration changes?"`. If files are identical, shows `"Nothing to do — already up to date"` and returns.

**Python (`_do_blueprint_update`, line 3651):**
No `diff` check. If versions match, still shows the version-update confirm dialog. User sees a confusing prompt even when nothing has changed.

**Fix:**
```python
if cur_ver == new_ver:
    src = G.containers_dir/cid/'service.src'
    same = src.exists() and bf.exists() and src.read_text() == bf.read_text()
    if same:
        pause(f"Nothing to do — '{cname(cid)}' is already up to date\n  (version {cur_ver or '?'}, configuration unchanged).")
        return
    if not confirm(f"Changes detected in '{cname(cid)}' (version {cur_ver or '?'} unchanged).\n\n  Blueprint: {bf.stem}\n  Apply configuration changes?"): return
    shutil.copy(str(bf), str(src))
    if bp_compile(src, cid):
        if st(cid,'installed'): build_start_script(cid)
        pause(f"Configuration updated for '{cname(cid)}' (version {cur_ver or '?'}).")
    else: pause('⚠  Update applied but compile had errors.')
    return
```

---

### DIV-056 · `proxy_menu` — four sub-divergences

**A. Route mDNS display:**
Shell uses `_avahi_mdns_name "$rurl"` which strips `.local` and returns the proper mDNS hostname.
Python hardcodes `f'{rurl}.local'` — if the URL already ends in `.local`, the display shows `name.local.local`.

**B. "Toggle HTTPS" label:**
Shell: `"Toggle HTTPS (currently: $rh2)"` — shows current value.
Python: `"Toggle HTTPS"` — no current value shown.

**C. Uninstall path:**
Shell: calls `_avahi_stop`, removes both `_proxy_caddy_bin()` and `_proxy_caddy_runner()`, removes sudoers, then launches avahi-utils removal.
Python: only removes caddy binary, removes sudoers, launches avahi-utils removal. Does not call `_avahi_stop()` or remove the runner script.

**D. Start failure diagnostics:**
Shell: parses caddy log for port-conflict patterns, looks up conflicting container names, shows detailed `"Port conflict on :PORT — containers sharing this port: ..."` message.
Python: only shows raw log tail with no conflict analysis.

**Fix A:**
```python
from services import _avahi_mdns_name
mdns = _avahi_mdns_name(rurl)
route_lines.append(f' {CYN}◈{NC}  {CYN}{rurl}{NC}  →  {rname}  {DIM}({proto}  mDNS: {mdns}){NC}')
```
**Fix B:** Change label to `f'Toggle HTTPS (currently: {str(rhttps).lower()})'`
**Fix C:** Add `_avahi_stop()` call and `Path(_proxy_caddy_runner()).unlink(missing_ok=True)` in uninstall.
**Fix D:** Add port-conflict parsing after failed start.

---

### DIV-057 · `_sd_best_url` in install script — missing CUDA asset selection

**Shell (`_sd_best_url`, line 2424):**
Before generic arch matching, checks if `_SD_GPU == cuda` and tries to find a CUDA-specific asset:
```bash
if [[ -n "$url" && "${_SD_GPU:-cpu}" == "cuda" ]]; then
    url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1)
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "$arch" | head -1)
fi
```

**Python (`_gen_install_script`, line ~1820):**
The `_sd_best_url` helper emitted in the install script skips the CUDA block entirely. GPU containers that need a CUDA-specific release asset fall through to the generic arch matcher and may download the wrong asset.

**Fix:** Add to the emitted `_sd_best_url` function in `_gen_install_script`:
```python
'  if [[ "${_SD_GPU:-cpu}" == "cuda" ]]; then',
'    [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true',
'    [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE "cuda" | grep -iE "$arch" | head -1) || true',
'  fi',
```
(Insert after the `atype` case block and before the generic arch lines.)

---

### DIV-058 · `_gen_install_script` pip — Python skips `python3-full`/`python3-pip` apt install

**Shell (`_run_job` pip block, line ~2856):**
Inside the chroot, first runs:
```bash
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-full python3-pip
```
then creates `/venv` and runs pip. Ensures pip is available inside the container.

**Python (`_gen_install_script`, line ~1904):**
```python
f'python3 -m venv {ip!r}/venv 2>/dev/null||true',
'_mnt',
f'sudo -n mount --bind {ip!r} {ub!r}/mnt',
f'_chroot_bash {ub!r} -c "/mnt/venv/bin/pip install {pkg_str} 2>&1"',
```
Creates the venv on the **host** using the host Python (`python3 -m venv`), then bind-mounts the install path into ubuntu and runs pip from the venv binary. Does not apt-install `python3-full`/`python3-pip` first. If ubuntu base lacks pip, the `pip install` call fails silently.

**Fix:** Before the venv creation, add an apt install step inside the chroot:
```python
lines += [
    '_mnt',
    f'_chroot_bash {ub!r} -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-full python3-pip python3-venv 2>&1 || apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-full python3-pip python3-venv 2>&1"',
    '_umnt',
    f'_chroot_bash {ub!r} -c "python3 -m venv /mnt/venv" 2>/dev/null || python3 -m venv {ip!r}/venv 2>/dev/null || true',
]
```

---

## Updated Summary Table (DIV-053 to DIV-058)

| ID | Area | Severity | One-line description |
|----|------|----------|----------------------|
| DIV-053 | `blueprints_submenu` | LOW | New blueprints saved as `.container` (Python) vs `.toml` (shell) |
| DIV-054 | update items | MEDIUM | Persistent blueprint updates never shown; only blueprints_dir scanned |
| DIV-055 | `_do_blueprint_update` | MEDIUM | Missing same-version content diff check; no "nothing to do" path |
| DIV-056 | `proxy_menu` | MEDIUM | mDNS display wrong; Toggle HTTPS missing current value; Uninstall incomplete; no port-conflict diagnostics |
| DIV-057 | install script | MEDIUM | `_sd_best_url` missing CUDA asset selection block |
| DIV-058 | install script pip | HIGH | Missing `python3-full`/`python3-pip` apt install before pip; venv created on host not in chroot |

---

## Additional Divergences (DIV-059 through DIV-063)

---

### DIV-059 · `_bootstrap_tmux` — sudoers not rewritten on subsequent launches

**Shell (`_sd_outer_sudo`, line 302):**
Always runs `sudo -k`, prompts for password, and re-tees the full NOPASSWD sudoers rule on every launch, even if the file already exists.

**Python (`_bootstrap_tmux`, line 5788):**
```python
if not os.path.exists(sudoers):
    write_sudoers()   # only on first run
else:
    subprocess.run(['sudo','-k'], ...); sudo -v loop
```
If the sudoers file is deleted, corrupted, or becomes outdated (e.g. new tools added to the rule), Python never repairs it. Also means new `sudo -n` commands added to the rule in a future update won't take effect until the user manually deletes the sudoers file.

**Fix:** Always call `write_sudoers()` unconditionally, not gated on file existence.

---

### DIV-060 · `_bootstrap_tmux` — Python forces fixed terminal dimensions

**Shell:** `tmux new-session -d -s "simpleDocker" "bash ..."` — no `-x`/`-y`, inherits caller's terminal dimensions.

**Python:** `['tmux','new-session','-d','-s',sess,'-x','220','-y','50',cmd]` — forces 220×50.

On wide/tall terminals the Python session feels cramped; on narrow terminals the shell session may wrap. Neither is strictly wrong, but they diverge.

**Fix:** Remove `-x` and `-y` to match shell, or read `$COLUMNS`/`$LINES` from environment.

---

### DIV-061 · `set_img_dirs` — Python seeds persistent blueprints on every mount; shell never does

**Python (`set_img_dirs`, line 648):**
Calls `_seed_persistent_blueprints()` which writes every entry in `_SD_PERSISTENT_BLUEPRINTS` dict to `.sd/persistent_blueprints/*.container` on every mount/remount.

**Shell (`_set_img_dirs`):**
No equivalent. Persistent blueprints are embedded in the running script and accessed directly from memory — nothing is written to disk automatically.

**Effect:** On Python, `.sd/persistent_blueprints/` is always kept in sync with the embedded dict. On shell, if the dict changes, disk copies are stale until manually updated. Python behaviour is arguably better, but it's an undocumented divergence and the written `.container` extension diverges from the shell's `.toml` convention (see DIV-053).

**Fix:** Accept Python behaviour as an improvement, or align extensions with DIV-053 fix.

---

### DIV-062 · `_snap_submenu` — missing timestamp in header; missing running-state guards

**Shell (`_container_backups_menu`, line ~4147):**
Snapshot submenu header: `"Backup: {id}  ({ts})"` — includes timestamp.
Before Restore: `tmux_up "$(tsess "$cid")" && { pause "Stop the container before restoring."; continue; }`
Before Clone: same running check.

**Python (`_snap_submenu`, line 3763):**
Header is just `label` (the snap id, no timestamp).
No running-state check before Restore or Clone.

**Fix:**
```python
def _snap_submenu(cid: str, snap_path: Path, label: str):
    sdir = snap_dir(cid)
    ts = snap_meta_get(sdir, label, 'ts') or '?'
    sel = menu(f'Backup: {label}  ({ts})', 'Restore', 'Create clone', L['stor_delete'])
    if not sel: return
    if 'Restore' in sel:
        if tmux_up(tsess(cid)): pause('Stop the container before restoring.'); return
        restore_snap(cid, snap_path, label)
    elif 'Clone' in sel:
        if tmux_up(tsess(cid)): pause('Stop the container before cloning.'); return
        v = finput('Name for the clone:')
        if v: clone_from_snap(cid, snap_path, label, v)
    elif sel == L['stor_delete']:
        if confirm(f"Delete backup '{label}'?"):
            btrfs_delete(snap_path)
            (sdir/f'{label}.meta').unlink(missing_ok=True)
            pause(f"Backup '{label}' deleted.")
```

---

### DIV-063 · `_proxy_install_caddy` — no Attach/Background prompt; no reinstall mode; weaker version fallback

**Shell (`_proxy_install_caddy`, line 6457):**
- Uses `_tmux_launch` which prompts "Attach — follow live output" / "Background — run silently".
- Accepts `reinstall` argument → uses `apt-get install --reinstall`.
- Version fallback: tries GitHub API, then redirect URL, then `2.9.1`.

**Python (`_proxy_install_caddy_menu`, line 4956):**
- Always runs silently via `_installing_wait_loop` — no attach/background choice.
- No reinstall mode — always plain `apt-get install`.
- Version fallback: GitHub API then hardcoded `2.9.1` (skips redirect URL fallback).

**Fix:**
```python
# After creating session, offer attach option (matching run_job pattern):
sel = fzf_run([f'{GRN}▶  Attach — follow live output{NC}',
               f'{DIM}   Background — run silently{NC}'],
              header=f'{BLD}── Install Caddy + mDNS ──{NC}')
if sel and 'Attach' in strip_ansi(sel):
    _tmux('switch-client','-t',sess)
# Add reinstall support in the install script:
apt_cmd = 'apt-get install --reinstall' if reinstall else 'apt-get install'
```

---

## Updated Summary Table (DIV-059 to DIV-063)

| ID | Area | Severity | One-line description |
|----|------|----------|----------------------|
| DIV-059 | bootstrap | MEDIUM | Sudoers not rewritten on repeat launches; stale rules never repaired |
| DIV-060 | bootstrap | LOW | Python forces 220×50 tmux dimensions; shell inherits terminal |
| DIV-061 | `set_img_dirs` | LOW | Python seeds persistent BPs to disk on every mount; shell never does |
| DIV-062 | backups | MEDIUM | Snap submenu missing timestamp in header; no running check before restore/clone |
| DIV-063 | proxy install | MEDIUM | No attach prompt; no reinstall mode; weaker version fallback |

---

### DIV-064 · `_qrencode_menu` — Update icon color differs; missing session wait-loop

**Shell:** Update label uses `${CYN}↑${NC}` (cyan). On entering the menu, checks if `sdQrInst`/`sdQrUninst` is running and calls `_pkg_op_wait` to block until it finishes before re-rendering.

**Python:** Update label uses `${YLW}↑{NC}` (yellow). No session-wait check on entry.

**Fix:** Change arrow color to `{CYN}` and add running-session check matching the ubuntu_menu pattern.

| DIV-064 | `_qrencode_menu` | VISUAL | Update arrow is yellow (Python) vs cyan (shell); missing session wait-loop |