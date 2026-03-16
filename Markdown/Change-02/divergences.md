# simpleDocker — Shell → Python Divergences (Complete)

> **Self-contained.** Every entry describes the shell behaviour, the Python behaviour,
> and the exact fix. No need to open `services.sh` — the shell lines are quoted inline.
> **Shell functions needed** are listed at the end of each entry.

---

### DIV-001 · `load_containers` — does not respect `hidden=true` flag

**Shell (`_load_containers`, line 1877):**
```bash
{ read -r hidden; IFS= read -r n; } < <(jq -r '.hidden // false, .name // empty' ...)
[[ "$show_hidden" == "false" && "$hidden" == "true" ]] && continue
```
Hidden containers are suppressed from all menus when `show_hidden=false` (the default).

**Python (`load_containers`, line 374):**
No check for `.hidden`; every container directory is unconditionally appended.

**Fix:** Add hidden-flag check:
```python
try: data = json.loads((d/'state.json').read_text())
except: data = {}
if data.get('hidden'): continue
```

**Shell functions needed:** `_load_containers`

---

### DIV-002 · `snap_dir` — uses `cid` not `cname(cid)` as the backup subdirectory

**Shell (`_snap_dir`, line 3795):**
```bash
_snap_dir() { printf '%s/%s' "$BACKUP_DIR" "$(_cname "$1")"; }
```
Snapshots live under `Backup/<container-name>/`.

**Python (`snap_dir`, line 406):**
```python
def snap_dir(cid: str) -> Path:
    return G.backup_dir/cid
```
Uses the raw 8-character `cid` instead of the human name. If a container is renamed the
old backup directory is unreachable; fresh installs store backups under a different path
than the shell would.

**Fix:** `return G.backup_dir/cname(cid)`

**Shell functions needed:** `_snap_dir`

---

### DIV-003 · `_stor_create_profile` — does not set `default_storage_id` on the container

**Shell (`_stor_create_profile_silent`, line 4309):**
```bash
_set_st "$cid" default_storage_id "\"$new_scid\""
```

**Python (`_stor_create_profile`, line 2864):**
```python
def _stor_create_profile(cid: str, stype: str, pname: str = 'Default') -> Optional[str]:
    ...
    return _stor_create_profile_silent(cid, stype)
```
`_stor_create_profile_silent` does set `default_storage_id`; however `_stor_create_profile`
(the named-profile variant called from `_pick_storage_profile`) calls `_stor_create_profile_silent`
correctly — so this is actually fine. **No real divergence.** Noted for completeness.

**Shell functions needed:** N/A

---

### DIV-004 · `_parse_cron_line` — `>>` redirect rewrite is missing from Python's cron parser

**Shell (`_bp_flush_section` cron section, line 2016):**
```bash
local ccmd_prefixed; ccmd_prefixed=$(printf '%s' "$ccmd" | \
    sed 's#>>[[:space:]]*\([[:alpha:]_][^[:space:]]*\)#>> $CONTAINER_ROOT/\1#g')
BP_CRON_CMDS+=("$ccmd_prefixed")
```
Rewrites bare `>> logs/foo.log` → `>> $CONTAINER_ROOT/logs/foo.log` inside the parsed
cron command.

**Python (`_parse_cron_line`, line 1188):**
```python
return {'interval':interval,'name':name,'cmd':cmd,'flags':flags}
```
`cmd` is stored as-is. Relative redirect targets are never rewritten.

**Fix:** Add to `_parse_cron_line` after `cmd=cmd.strip()`:
```python
cmd = re.sub(r'>>\s*([a-zA-Z_][^\s]*)', r'>> $CONTAINER_ROOT/\1', cmd)
```

**Shell functions needed:** `_bp_flush_section` (cron case)

---

### DIV-005 · `_parse_action_line` — `⊙` prefix NOT added at parse time (shell also defers it)

**Shell (`_container_submenu`, line 5505):**
```bash
local _first_char; _first_char=$(printf '%s' "$lbl" | cut -c1)
if [[ "$_first_char" =~ ^[a-zA-Z0-9]$ ]]; then lbl="⊙  $lbl"; fi
```
The `⊙` is prepended at *display time* in `_container_submenu`, not at parse time.
`service.json` stores the raw label without `⊙`.

**Python (`container_submenu`, line 3396):**
```python
for a in d.get('actions',[]):
    lbl=a['label']
    if re.match(r'^[a-zA-Z0-9]',lbl): lbl='⊙  '+lbl
```
Also adds `⊙` at display time — consistent with the shell. No divergence.

**Shell functions needed:** N/A

---

### DIV-006 · `_env_exports` — `_sd_sp` site-packages line not in shell; shell has a different PYTHONPATH pattern

**Shell (`_env_exports`, line ~2554 area — not found):**
The shell's `_env_exports` does NOT emit `_sd_sp` / `PYTHONPATH` lines. It only emits:
```bash
export CONTAINER_ROOT=... HOME=... XDG_* ... PATH=... PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV=...
mkdir -p ...
[[ ! -e "$CONTAINER_ROOT/bin" ]] && mkdir -p ...
```

**Python (`_env_exports`, lines 1651–1654):**
```python
'_sd_sp=$(python3 -c "import sys; ..." 2>/dev/null)',
'_sd_vsp=$(compgen -G "$CONTAINER_ROOT/venv/lib/python*/site-packages" 2>/dev/null | head -1) || true',
'[[ -n "$_sd_vsp" ]] && export PYTHONPATH="$_sd_vsp${PYTHONPATH:+:$PYTHONPATH}"',
```
Python adds extra lines that the shell does not have. These are improvements (better
Python environment setup inside the chroot) that don't break anything — but they are
divergences from the shell's exact output.

**Shell functions needed:** `_env_exports`

---

### DIV-007 · `_do_ubuntu_update` — Python uses `apt dist-upgrade`; shell uses `apt upgrade`; no backup prompt; no stamp update

**Shell (`_do_ubuntu_update`, line 5067):**
1. Confirms: `"Update Ubuntu base for '%s'?\n\n  Base : %s"`
2. Offers backup first with named snapshot.
3. Runs `apt-get upgrade -y` (not `dist-upgrade`).
4. Writes `date '+%Y-%m-%d' > "$UBUNTU_DIR/.sd_ubuntu_stamp"`.
5. Copies stamp into container path.

**Python (`_do_ubuntu_update`, line 3772):**
```python
cmd='apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1'
```
Uses `dist-upgrade`, no confirm with version info, no backup offer, no stamp update.

**Fix:**
- Change `dist-upgrade` → `upgrade`.
- Add pre-confirm with base version.
- Add "Create backup first?" prompt (matching shell).
- After `_ubuntu_pkg_op` call, write `(G.ubuntu_dir/'.sd_ubuntu_stamp').write_text(time.strftime('%Y-%m-%d'))` and copy it into `cpath(cid)`.

**Shell functions needed:** `_do_ubuntu_update`, `_ct_ubuntu_ver`, `_snap_dir`

---

### DIV-008 · `start_ct` — missing `compile_service` result check; missing `tmux_up` early-return guard

**Shell (`_start_container`, line 3235):**
```bash
_guard_space || return 1
_compile_service "$cid" 2>/dev/null || true
if tmux_up "$(tsess "$cid")"; then return 0; fi
```
Exits immediately if the container is already running, after guard_space.

**Python (`start_ct`, line 1455):**
```python
def start_ct(cid: str, mode='background', profile_cid: str=''):
    if not _guard_space(): return
    if tmux_up(tsess(cid)): return
```
The `tmux_up` check is present. `compile_service` is called but its return value is
ignored. This is minor — consistent with shell which also uses `|| true`.

**Shell functions needed:** `_start_container`, `_guard_space`

---

### DIV-009 · `stop_ct` — `netns_ct_del` called AFTER session kill; shell calls it in the same order

**Shell (`_stop_container`, line 3368):**
```bash
tmux send-keys -t "$sess" C-c "" ...
tmux kill-session -t "$sess" ...
tmux kill-session -t "sdTerm_${cid}" ...
_netns_ct_del "$cid" "$(_cname "$cid")" "$MNT_DIR"
while IFS= ... tmux kill-session -t "^sdAction_${cid}_"
_cron_stop_all "$cid"
sleep 0.2
storage unlink
```

**Python (`stop_ct`, line 1538):**
```python
_tmux('kill-session','-t',sess)
_tmux('kill-session','-t',f'sdTerm_{cid}', capture=True)
netns_ct_del(cid, cname(cid))   # ← after session kill ✓
r=_tmux('list-sessions',...)
for s in ...: _tmux('kill-session',...)  # kills cron+action ✓
```
Order is correct. The only divergence: Python's `stop_ct` calls
`exposure_flush(cid, port, netns_ct_ip(cid))` directly (not via `_netns_ct_del`), while
the shell relies on `_netns_ct_del` to call `_exposure_flush`. Both flush iptables.
No functional divergence.

**Shell functions needed:** N/A

---

### DIV-010 · `stop_ct` — no `clear` before `pause`; shell calls `clear` first

**Shell (`_stop_container`, line 3390):**
```bash
clear; pause "'$(_cname "$cid")' stopped."
```

**Python (`stop_ct`, line 1569):**
```python
pause(f"'{cname(cid)}' stopped.")
```
No `clear` before the pause. The container's tmux pane output lingers on screen.

**Fix:** Add `os.system('clear')` before the `pause(...)` call.

**Shell functions needed:** `_stop_container`

---

### DIV-011 · `_cron_start_one` — `--sudo` flag: shell resolves `$CONTAINER_ROOT` in cmd before wrapping; Python does not

**Shell (`_cron_start_one`, line 3156):**
```bash
if [[ "$_use_sudo" == "true" ]]; then
    local _cmd_resolved; _cmd_resolved="${cmd//\$CONTAINER_ROOT/$ip}"
    cmd="sudo -n bash -c $(printf '%q' "$_cmd_resolved")"
fi
```
Replaces `$CONTAINER_ROOT` with the real path and wraps in `sudo -n bash -c`.

**Python (`_cron_start_one`, line 1577):**
The `flags` field is read and `--unjailed` / `--sudo` are checked, but the `--sudo` case
is never handled. The command runs without `sudo -n` wrapping when `--sudo` is specified.

**Fix:** After reading flags, add:
```python
if use_sudo:
    cmd_resolved = cmd.replace('$CONTAINER_ROOT', str(ip))
    import shlex as _sx
    cmd = f'sudo -n bash -c {_sx.quote(cmd_resolved)}'
```

**Shell functions needed:** `_cron_start_one`

---

### DIV-012 · `_cron_start_one` — jailed branch mounts `/dev` as `--bind` not `-t devtmpfs`

**Shell (`_cron_start_one`, line 3182):**
```bash
printf 'mount -t proc proc %q 2>/dev/null || true\n' "$_ub/proc"
printf 'mount --bind /sys %q 2>/dev/null || true\n' "$_ub/sys"
printf 'mount --bind /dev %q 2>/dev/null || true\n' "$_ub/dev"
printf 'mount --bind %q %q 2>/dev/null || true\n' "$ip" "$_ub/mnt"
printf '_cb %q -c %q\n' "$_ub" "cd /mnt && $_cmd_inner"
```

**Python (`_cron_start_one`, line 1614):**
```python
f.write(f'    sudo -n nsenter --net=/run/netns/{ns} -- unshare --mount --pid --uts --ipc --fork bash -s << \'_SDCRON\'\n')
f.write(f'_cb(){{ ... }}\n')
f.write(f'mount -t proc proc {ub}/proc 2>/dev/null||true\n')
f.write(f'mount --bind /sys {ub}/sys 2>/dev/null||true\n')
f.write(f'mount --bind /dev {ub}/dev 2>/dev/null||true\n')
f.write(f'mount --bind {ip} {ub}/mnt 2>/dev/null||true\n')
f.write(f'_cb {ub} -c "cd /mnt && {inner}"\n')
```
This looks correct. **However**, the shell escapes the `_cb` chroot command with `%q`
(printf quoting), while Python uses a raw f-string interpolation — if `inner` or `ub`
contain spaces or special shell characters the Python version will break.

**Fix:** Wrap arguments in `shlex.quote()` when writing the `_cb` call.

**Shell functions needed:** `_cron_start_one`

---

### DIV-013 · `_build_update_items_for` — update items include source label `[B]`/`[P]` with source name; Python omits source name

**Shell (`_build_update_items`, line 5112):**
```bash
entry="$(printf "%b %s ${DIM}%s${NC} — ${YLW}Changes detected${NC}%b" "$stag" "$bn" "$src" "$_vs")"
# e.g.: [B] myapp  Blueprints — Changes detected  v1.0
```
The source label (`Blueprints` or `Persistent`) appears after the blueprint name.

**Python (`_build_update_items_for`, line 3691):**
```python
entry=f'{DIM}[B] {bname} —{NC} {YLW}Changes detected{NC}'
```
Source name (`Blueprints`/`Persistent`) is omitted. The version suffix (e.g. `v1.0`) is
also omitted for same-version same-content case.

**Fix:**
```python
src_name = 'Blueprints'
entry = f'{DIM}[B]{NC} {bname} {DIM}{src_name}{NC} — {YLW}Changes detected{NC}{DIM}  v{cur_ver}{NC}'
```

**Shell functions needed:** `_build_update_items`, `_collect_bps_by_type`

---

### DIV-014 · `_build_ubuntu_update_item_for` — uses global cache drift/updates; shell uses per-container stamp comparison

**Shell (`_build_ubuntu_update_item`, line 5044):**
Reads `_ct_ubuntu_stamp` from the container's install path and compares to the base stamp:
```bash
local ct_stamp;   ct_stamp=$(_ct_ubuntu_stamp "$install_path")
local base_stamp; base_stamp=$(_ct_ubuntu_stamp "$UBUNTU_DIR")
if [[ -z "$base_stamp" || ( -n "$ct_stamp" && "$ct_stamp" == "$base_stamp" ) ]]; then
    entry="...✓ $ct_ver..."
else
    entry="...Update available..."
fi
```
Shows "Not installed" if Ubuntu base is absent.

**Python (`_build_ubuntu_update_item_for`, line 3720):**
```python
ub_cache_read()
if G.ub_pkg_drift or G.ub_has_updates:
    items.append(f'...Updates available...')
```
Uses global `ub_has_updates` flag (system-wide apt upgrade check) instead of comparing
per-container stamps. A container whose Ubuntu base is already up-to-date will show
"Updates available" if any other apt packages have pending upgrades.

**Fix:** Check `(ip/'.sd_ubuntu_stamp').read_text()` vs `(ubuntu_dir/'.sd_ubuntu_stamp').read_text()`,
plus show "Not installed" when Ubuntu base absent, matching shell exactly.

**Shell functions needed:** `_build_ubuntu_update_item`, `_ct_ubuntu_stamp`, `_ct_ubuntu_ver`

---

### DIV-015 · `_ensure_ubuntu` — `.ubuntu_default_pkgs` written one-per-line in shell; Python writes space-separated single line

**Shell (`_ensure_ubuntu` via ubuntu script, line 1530):**
```bash
printf '%s\n' $DEFAULT_UBUNTU_PKGS > "$UBUNTU_DIR/.ubuntu_default_pkgs"
```
Produces one package per line.

**Python (`_ensure_ubuntu`, line 4882):**
```python
f.write(f'printf "%s\\n" {DEFAULT_UBUNTU_PKGS} > {ub!r}/.ubuntu_default_pkgs 2>/dev/null||true\n')
```
`printf "%s\n" curl git wget ...` with space-separated args — emits all on one line.
`ub_cache_check` reads the file with `.splitlines()`, sorts, and compares; a one-line
file always mismatches the sorted individual-word list → `ub_pkg_drift` is always `true`.

**Fix:**
```python
pkgs_lines = '\\n'.join(DEFAULT_UBUNTU_PKGS.split())
f.write(f'printf "{pkgs_lines}\\n" > {ub!r}/.ubuntu_default_pkgs 2>/dev/null||true\n')
```

**Shell functions needed:** `_ensure_ubuntu`, `_sd_ub_cache_check`

---

### DIV-016 · `ubuntu_menu` — Sync default pkgs: Python installs missing only; shell uses full `$DEFAULT_UBUNTU_PKGS` as fallback

**Shell (`_ubuntu_menu` Sync branch, line 7011):**
```bash
local _sync_pkgs="${_cur_missing[*]:-$DEFAULT_UBUNTU_PKGS}"
```
If all packages are present but `PKG_DRIFT=true`, falls back to installing all
`DEFAULT_UBUNTU_PKGS` to ensure consistency.

**Python (`ubuntu_menu` Sync branch, line 4784):**
```python
sync_pkgs = ' '.join(missing) if missing else DEFAULT_UBUNTU_PKGS
```
Same logic — uses all packages when nothing is missing. Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-017 · `_force_quit` — Python does not sweep remaining `mnt_*/` directories or additional LUKS mappers

**Shell (`_force_quit`, line 337):**
After unmount, sweeps any leftover `mnt_*/` dirs:
```bash
for _mnt in "$SD_MNT_BASE"/mnt_*/; do
    sudo -n umount -lf "$_mnt"
    local _mlo; _mlo=$(findmnt -n -o SOURCE "$_mnt" | grep '^/dev/loop')
    [[ -n "$_mlo" ]] && sudo -n losetup -d "$_mlo"
    rmdir "$_mnt"
done
```
Then closes LUKS mappers with `sd_*` pattern and detaches loop devices with `simpleDocker`
in the path, then `rm -rf "$SD_MNT_BASE"`.

**Python (`_force_quit`, line 6101):**
Has a `mnt_*` sweep and LUKS loop, but the order differs slightly and the intermediate
`rm -rf G.sd_mnt_base` is called via `shutil.rmtree`. Functionally equivalent but the
Python code checks `mp.is_block_device()` via Path — on some systems LUKS mappers appear
as character devices, not block devices, and `is_block_device()` returns False.

**Fix:** Use `stat.S_ISBLK(os.stat(str(mp)).st_mode)` instead of `mp.is_block_device()`.

**Shell functions needed:** `_force_quit`

---

### DIV-018 · `_proxy_start` — Python does not call `_proxy_ensure_sudoers()` before starting; no `_proxy_dns_stop` before `_proxy_dns_start`

**Shell (`_proxy_start`, line 6347):**
```bash
_proxy_write
_proxy_update_hosts add
_proxy_ensure_sudoers
_proxy_dns_start
```
`_proxy_ensure_sudoers` is explicitly called every time Caddy starts so the runner script
and sudoers rule are always fresh.

**Python (`_proxy_start`, line 5050):**
```python
def _proxy_start(background=False) -> bool:
    ...
    _proxy_write()
    _proxy_update_hosts('add')
    _proxy_ensure_sudoers()   # ← present ✓
    _proxy_dns_start()
```
This is actually present. The divergence is that `_proxy_dns_start` in Python doesn't
call `_proxy_dns_stop()` first (shell `_proxy_dns_start` does). If dnsmasq is already
running, a second instance starts on the same port and both fail.

**Fix:** Add `_proxy_dns_stop()` call at the start of `_proxy_dns_start`.

**Shell functions needed:** `_proxy_start`, `_proxy_dns_start`, `_proxy_dns_stop`

---

### DIV-019 · `run_job` — `_guard_space` is NOT called in the shell's `_run_job`; Python calls it

**Shell (`_run_job`, line 2751):**
The shell does call `_guard_space || return 1` near the top.

**Python (`run_job`, line 2028):**
```python
if not _guard_space(): return
```
Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-020 · `_pick_storage_profile` — Python `_stor_create_profile` does not pass the profile name back to caller; only the silent variant is returned

**Shell (`_pick_storage_profile` "new" branch, line 4368):**
```bash
_stor_create_profile "$cid" "$stype" "$_sp_name"
```
`_stor_create_profile` returns the new scid via `printf '%s' "$new_scid"`.

**Python (`_pick_storage_profile` "new" branch, line 2908):**
```python
return _stor_create_profile(cid, stype, v or 'Default')
```
`_stor_create_profile` calls `_stor_create_profile_silent` which returns the scid.
Correct. No divergence.

**Shell functions needed:** N/A

---

### DIV-021 · `container_submenu` — exposure toggle does NOT apply `exposure_apply` when container is not running

**Shell (`_container_submenu`, line 5705):**
```bash
"${L[ct_exposure]}"*)
    local _new_exp; _new_exp=$(_exposure_next "$cid")
    _exposure_set "$cid" "$_new_exp"
    tmux_up "$(tsess "$cid")" && _exposure_apply "$cid"
```
`_exposure_apply` only called when running.

**Python (`container_submenu`, line 3501):**
```python
elif sc==L['ct_exposure'] or '⬤  Exposure' in sc:
    new_mode=_exposure_next(cid)
    _exposure_set(cid,new_mode)
    if tmux_up(tsess(cid)): _exposure_apply(cid)
```
Consistent with shell — only applies when running. No divergence.

**Shell functions needed:** N/A

---

### DIV-022 · `container_submenu` — `ct_attach` does not show confirm dialog with detach hint

**Shell (`_container_submenu`, line 5645):**
```bash
"${L[ct_attach]}") _tmux_attach_hint "$name" "$(tsess "$cid")" ;;
```
`_tmux_attach_hint` shows a `confirm()` dialog:
```bash
confirm "Attach to '%s'\n\n  Press %s to detach without stopping." "$label" "${KB[tmux_detach]}"
```

**Python (`container_submenu`, line 3485):**
```python
elif sc==L['ct_attach']:
    sess_ct = tsess(cid)
    if tmux_up(sess_ct):
        if confirm(f"Attach to '{n}'\n\n  Press {KB['tmux_detach']} to detach without stopping."):
            ...switch-client...
```
Consistent — confirms before attaching. No divergence.

**Shell functions needed:** N/A

---

### DIV-023 · `container_submenu` — `ct_log` shows `tail -100`; shell shows `tail -100` but only reads up to 100 lines

**Shell (`_container_submenu`, line 5676):**
```bash
if [[ -f "$_lf" ]]; then
    pause "$(tail -100 "$_lf" 2>/dev/null | cat)"
```
`tail -100` on the log file.

**Python (`container_submenu`, line 3497):**
```python
r_tail=_run(['tail','-100',str(lf)], capture=True)
pause(r_tail.stdout if r_tail.returncode==0 else '')
```
Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-024 · `main_menu` — image total-GB uses `stat -c%s` in shell; Python uses `stat().st_size` — identical, no divergence

Both use the file's actual byte size from `stat`. Consistent. **No divergence.**

---

### DIV-025 · `main_menu` — blueprint count in header: Python counts imported BPs regardless of autodetect mode

**Shell (`main_menu`, line 7239):**
Calls `_list_imported_names()` which internally calls `_bp_autodetect_dirs` which
respects the autodetect mode. If mode is `Disabled`, `ibps` is empty.

**Python (`main_menu`, line 5986):**
```python
n_bp = len(_list_blueprint_names()) + len(_list_persistent_names()) + len(_list_imported_names())
```
`_list_imported_names()` returns `[]` when `mode == 'Disabled'` (line 4514):
```python
if mode == 'Disabled': return []
```
Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-026 · `_fzf_with_watcher` — dimmed items: Python correctly dims non-ANSI items to match shell `_installing_menu`

**Shell (`_installing_menu`, line 5162):**
```bash
printf '%s' "$x" | grep -q $'\033' && lines+=("$x") || lines+=("$(printf "${DIM} %s${NC}" "$x")")
```

**Python (`_fzf_with_watcher`, line 3567):**
```python
dimmed=[x if '\033[' in x else f'{DIM} {x}{NC}' for x in items]
```
Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-027 · `resize_image` — Python uses `os.execv` to self-restart; shell calls `exec bash "$_SELF_PATH"` — different but equivalent

Both restart the process after a successful resize. Python's `os.execv` re-runs the
Python interpreter; shell's `exec bash` restarts the script. Functionally equivalent.
No divergence.

**Shell functions needed:** N/A

---

### DIV-028 · cron countdown — Python does not apply the full `_cron_countdown` format in menu display

**Shell (`_cron_countdown`, line 3131):**
```bash
if   (( d > 0 )); then printf '%dd %02dh %02dm %02ds' ...
elif (( h > 0 )); then printf '%dh %02dm %02ds' ...
elif (( m > 0 )); then printf '%dm %02ds' ...
else printf '%ds' ...
```
Separate display format for day/hour/minute/second cases.

**Python (`container_submenu`, line 3421):**
```python
d2,rem3=divmod(rem,86400); h,rem2=divmod(rem3,3600); m2,s2=divmod(rem2,60)
if d2: countdown = f'  {DIM}next: {d2}d {h:02d}h {m2:02d}m{NC}'
elif h: countdown = f'  {DIM}next: {h}h {m2:02d}m {s2:02d}s{NC}'
else: countdown = f'  {DIM}next: {m2}m {s2:02d}s{NC}'
```
Missing seconds-only branch. Shell formats `%ds` for sub-60-second waits; Python falls
into `m2=0, s2=N` and displays `0m 05s` instead of `5s`.

**Fix:** Add:
```python
elif not m2: countdown = f'  {DIM}next: {s2}s{NC}'
```
before the bare `else` clause.

**Shell functions needed:** `_cron_countdown`

---

### DIV-029 · `stop_ct` — missing `clear` before `pause`; also missing `_cron_stop_all` equivalent that cleans next-files

**Shell (`_stop_container`, lines 3219–3225):**
```bash
_cron_stop_all() {
    local cid="$1"
    rm -f "$CONTAINERS_DIR/$cid"/cron_*_next 2>/dev/null
    while IFS= read -r sess; do
        tmux kill-session -t "$sess"
    done < <(tmux list-sessions -F "#{session_name}" | grep "^sdCron_${cid}_")
}
```
`rm -f cron_*_next` is the first step.

**Python (`stop_ct`, line 1558):**
```python
# Clean cron next-timestamp files (matches shell _cron_stop_all)
if G.containers_dir:
    for nf in (G.containers_dir/cid).glob('cron_*_next'):
        nf.unlink(missing_ok=True)
```
Cleans next-files. Consistent. Also kills `sdCron_` sessions:
```python
for s in (r.stdout.splitlines() if r.returncode==0 else []):
    if s.startswith(f'sdCron_{cid}_') or s.startswith(f'sdAction_{cid}_'):
        _tmux('kill-session','-t',s)
```
Consistent. The only real gap is the missing `clear` before `pause` (see DIV-010).

**Shell functions needed:** `_cron_stop_all`, `_stop_container`

---

### DIV-030 · `validate_containers` — Python writes the patched state.json; shell uses `_set_st`

**Shell (`_validate_containers`, line 1891):**
```bash
[[ -n "$ip" && -d "$ip" ]] || _set_st "$cid" installed false
```
Uses `_set_st` which does a jq-inplace update (preserves other fields).

**Python (`validate_containers`, line 605):**
```python
data['installed'] = False
sf.write_text(json.dumps(data, indent=2))
```
Writes the full file — equivalent and safe since `data` was loaded from the same file.
No actual divergence.

**Shell functions needed:** N/A

---

### DIV-031 · `_do_pkg_update` — Python runs `run_job(cid,'update')`; shell generates a full inline update script with git/pip/npm/apt

**Shell (`_do_pkg_update`, line 4894):**
Generates a bespoke inline script that:
1. Upgrades apt packages via `apt-get install --only-upgrade`.
2. Upgrades pip packages via `/mnt/venv/bin/pip install --upgrade`.
3. Upgrades npm packages via `npm update`.
4. Checks and updates git releases via `_sd_burl`/`_sd_xauto`.
5. Updates `pkg_manifest.json` `updated` timestamp.
6. Writes new tag hashes to `.inst` file.

**Python (`_do_pkg_update`, line 3780):**
```python
if confirm(f"Update packages for '{cname(cid)}'?"): run_job(cid,'update')
```
Delegates entirely to `run_job` which runs the `[update]` block from `service.json`.
The `[update]` block is user-defined (usually blank); it does not handle git/pip/npm
package upgrades automatically.

**Fix:** Generate an inline update script analogous to the shell's `_do_pkg_update`,
or at minimum emit the apt/pip/npm/git upgrade steps before invoking the user `[update]`
block in `_gen_install_script`.

**Shell functions needed:** `_do_pkg_update`

---

### DIV-032 · `mount_img` — Python correctly clears log files; correctly autostarts proxy — matches shell. No divergence.

**Shell (`_mount_img`, lines 1273–1277):**
```bash
rm -f "$MNT_DIR/Logs/"*.log 2>/dev/null || true
if [[ -f "$MNT_DIR/.sd/proxy.json" ]] && \
   [[ "$(jq -r '.autostart // false' ...)" == "true" ]]; then
    _proxy_start --background
fi
```

**Python (`mount_img`, lines 745–756):**
```python
if G.logs_dir and G.logs_dir.is_dir():
    for lf in G.logs_dir.glob('*.log'):
        try: lf.unlink()
        ...
netns_setup(mnt)
proxy_cfg = mnt/'.sd/proxy.json'
if proxy_cfg.exists():
    try:
        if json.loads(proxy_cfg.read_text()).get('autostart'):
            proxy_start(background=True)
```
Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-033 · `_build_pkg_manifest_item_for` — pkg update label format differs from shell

**Shell (`_build_pkg_update_item`, line 4885):**
```bash
entry="$(printf "${DIM}[P]${NC} Packages ${DIM}— %s${NC} — ${YLW}Update available${NC}" "${ts:-never}")"
```
Format: `[P] Packages — <ts> — Update available`

**Python (`_build_pkg_manifest_item_for`, line 3767):**
```python
items.append(f'{DIM}[P]{NC} Packages {DIM}— {ts}{NC} — {YLW}Update available{NC}')
```
Consistent — same format. No divergence.

**Shell functions needed:** N/A

---

### DIV-034 · `main_menu` — separator line differs slightly

**Shell (`main_menu`, line 7226):**
```bash
_SEP="$(printf "${BLD}  ─────────────────────────────────────${NC}")"
```
37 em-dashes with 2-space indent.

**Python (`main_menu`, line 6008):**
```python
f'{BLD}  ─────────────────────────────────────{NC}',
```
Same string. No divergence.

**Shell functions needed:** N/A

---

### DIV-035 · `help_menu` — `ub_cache_read()` called once outside loop; shell calls `_sd_ub_cache_read` inside the loop

**Shell (`_help_menu`, line 7125):**
```bash
while true; do
    ...
    _sd_ub_cache_read
```
Called every iteration so updates propagate to the header.

**Python (`help_menu`, line 5782):**
```python
def help_menu():
    while True:
        ub_cache_read()
```
Called every iteration. Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-036 · `help_menu` — Manage Encryption icon: shell uses `◈`; Python uses `◈` — consistent, no divergence

Both use `◈`. No divergence.

---

### DIV-037 · `logs_browser` — Python sorts by full path `reverse=True`; shell uses `find … | sort -r` which is filename-only lexicographic

**Shell (`_logs_browser`, line 7092):**
```bash
while IFS= read -r f; do
    _files+=("$(printf "${DIM}%s${NC}" "${f#$LOGS_DIR/}")")
done < <(find "$LOGS_DIR" -type f -name "*.log" | sort -r)
```
`find | sort -r` does reverse lexicographic sort on **full paths**.

**Python (`logs_browser`, line 3196):**
```python
files=sorted(G.logs_dir.rglob('*.log'), key=lambda f: f.name, reverse=True)
```
Sorts by **filename only** (`f.name`), not full path. If there are nested subdirectories,
relative ordering between files in different subdirs differs from the shell.

**Fix:** Change sort key: `key=lambda f: str(f)` to match full-path sort.

**Shell functions needed:** `_logs_browser`

---

### DIV-038 · `_qrencode_menu` — Python doesn't loop for multiple operations; shell loops for Update+Uninstall

**Shell (`_qrencode_menu`, line 6404):**
```bash
while true; do
    ...
    case "$REPLY" in
        *"Update"*)   _ubuntu_pkg_tmux ...; continue ;;
        *"Uninstall"*)
            confirm ...
            _ubuntu_pkg_tmux ...; continue ;;
    esac
done
```
Loop allows returning to the menu after each action.

**Python (`_qrencode_menu`, line 5899):**
```python
if qr_ok:
    sel = menu('QRencode',...)
    if not sel: return
    if 'Update' in sel:
        ..._ubuntu_pkg_op(...)
    elif 'Uninstall' in sel:
        if confirm(...): _ubuntu_pkg_op(...)
else:
    sel = menu('QRencode',...)
    if sel and 'Install' in sel:
        _ubuntu_pkg_op(...)
```
No loop. After an operation the function returns. Also, the session wait-loop for
`sdQrInst`/`sdQrUninst` wraps in `_installing_wait_loop` which handles Attach, but the
outer while-true that keeps showing the menu after the op finishes is absent.

**Fix:** Wrap in `while True:` loop with `continue` after each operation, matching shell.

**Shell functions needed:** `_qrencode_menu`

---

### DIV-039 · `_stop_group` — Python version misses the "in_other running group" shared check inside the inner loop

**Shell (`_stop_group`, line 3490):**
```bash
in_other=false
for gf in "$GROUPS_DIR"/*.toml; do
    ...
    _grp_containers "$ogid" | grep -q "^${step}$" || continue
    while IFS= read -r oc; do
        [[ "$oc" == "$step" ]] && continue
        ocid=$(_ct_id_by_name "$oc")
        [[ -n "$ocid" ]] && tmux_up "$(tsess "$ocid")" && in_other=true && break
    done < <(_grp_containers "$ogid")
    [[ "$in_other" == true ]] && break
done
if [[ "$in_other" == false ]]; then _stop_container "$cid"; fi
```

**Python (`_stop_group`, line 4252):**
```python
for oc in other_members:
    if oc == step: continue
    ocid = _ct_id_by_name(oc)
    if ocid and tmux_up(tsess(ocid)):
        in_other = True
        break
if in_other: break
```
Logic is consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-040 · `_open_in_submenu` — `File manager` branch: Python does NOT `return` after `xdg-open` but shell does

**Shell (`_open_in_submenu`, line 5360):**
```bash
*"File manager"*)
    xdg-open "$open_path" 2>/dev/null & disown 2>/dev/null || true ;;
```
Falls through inside the `case` then the `while true` loop continues (no explicit
`return`). Next iteration re-renders the menu.

**Python (`_open_in_submenu`, line 3323):**
```python
elif 'File manager' in sc:
    ...
    subprocess.Popen(['xdg-open', open_path], ...)
```
No `return`. Continues the `while True` loop. Consistent — menu stays open. No divergence.

**Shell functions needed:** N/A

---

### DIV-041 · `_open_in_submenu` — `Terminal` branch: Python uses `new-window`; shell uses `pause` then `switch-client`

**Shell (`_open_in_submenu`, line 5363):**
```bash
*"Terminal"*)
    ...
    pause "$(printf "Opening terminal...\n  %s\n  Press %s to detach." "$name" "$tip" "${KB[tmux_detach]}")"
    tmux switch-client -t "$tsess_term"
```
Shows a `pause` dialog first, then switches.

**Python (`_open_in_submenu`, line 3328):**
```python
elif 'Terminal' in sc:
    ...
    pause(f"Opening terminal for '{n}'\n\n  {tip}\n  Press {KB['tmux_detach']} to detach.")
    _tmux('switch-client','-t',sess)
```
Shows pause then switches. Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-042 · `_run_action` — action DSL label used in "already running" message; shell uses the action label, Python uses `dsl[:30]`

**Shell (`_container_submenu` action dispatch, line 5809):**
```bash
pause "$(printf "Action '%s' is still running.\n\n  Press %s to detach." "${action_labels[$ai]}" "${KB[tmux_detach]}")"
```
Uses the human-readable label.

**Python (`_run_action`, line 3648):**
```python
pause(f"Action '{dsl[:30]}' is still running.\n\n  Press {KB['tmux_detach']} to detach.")
```
Uses truncated DSL string instead of label. Caller passes `dsl` not `label`.

**Fix:** Pass the action label to `_run_action`:
```python
def _run_action(cid: str, ai: int, label: str, dsl: str):
```
and update the pause: `pause(f"Action '{label}' is still running...")`

**Shell functions needed:** `_container_submenu` (action dispatch)

---

### DIV-043 · `run_job` — Python shows Attach/Background BEFORE session exists; shell creates session first then shows prompt

**Shell (`_run_job` → `_tmux_launch`, line 5270):**
The fzf prompt is shown first. If the user picks "Attach", THEN `tmux new-session` +
`switch-client` happens. If user picks "Background", session is created and background
watcher disowns.

**Python (`run_job`, line 2054):**
```python
_tmux('new-session','-d','-s',sess, ...)
...
sel2 = fzf_run([...attach/background...])
if sel2 and 'Attach' in ...:
    ...switch-client...
```
Session is created FIRST, then prompt shown. If user presses ESC on the prompt, the
session runs silently in the background (which is fine). Shell's `_tmux_launch` creates
session only after the user picks "Attach" or "Background"; a cancelled prompt means
no session is created. This means Python always starts the install even if the user
cancels the mode-selection prompt.

**Fix:** Create session after the prompt, or accept the "always runs" behaviour as an
intentional improvement (background install even on ESC).

**Shell functions needed:** `_run_job`, `_tmux_launch`

---

### DIV-044 · `ub_cache_check` — Python starts background check in `set_img_dirs`; original `__main__` still starts it too

**Shell:** `_sd_ub_cache_check &` is called from `_set_img_dirs` only.

**Python:** `threading.Thread(target=ub_cache_check, daemon=True).start()` is called
from **both** `set_img_dirs` (line 652) AND `__main__` (line 6220). The `__main__` call
starts before `setup_image()` → `G.ubuntu_dir` is not yet set → thread returns
immediately from `if not G.ubuntu_dir`. The second call in `set_img_dirs` is the
effective one. The first call is harmless but wasteful.

**Fix:** Remove the `ub_thread.start()` call in `__main__` — it's redundant.

**Shell functions needed:** `_set_img_dirs`, `_sd_ub_cache_check`

---

### DIV-045 · `_proxy_trust_ca` — Python doesn't poll for CA cert; shell waits up to 5 seconds

**Shell (`_proxy_trust_ca`, line 6379):**
```bash
local _waited=0
while [[ ! -f "$ca_crt" && $_waited -lt 10 ]]; do sleep 0.5; (( _waited++ )); done
```
Waits up to 5 seconds for the cert to appear.

**Python (`_proxy_trust_ca`, line 5026):**
```python
if not ca_root.exists(): return
```
Returns immediately if missing. On slow systems Caddy hasn't written the cert yet.

**Fix:**
```python
waited = 0
while not ca_root.exists() and waited < 10:
    time.sleep(0.5); waited += 1
if not ca_root.exists(): return
```

**Shell functions needed:** `_proxy_trust_ca`

---

### DIV-046 · `_proxy_trust_ca` — CA cert filename: Python uses `caddy-local.crt`; shell uses `simpleDocker-caddy.crt`

**Shell (`_proxy_trust_ca`, line 6387):**
```bash
sudo -n cp "$ca_crt" /usr/local/share/ca-certificates/simpleDocker-caddy.crt
```

**Python (`_proxy_trust_ca`, line 5030):**
```python
_sudo('cp',str(ca_root),'/usr/local/share/ca-certificates/caddy-local.crt')
```
Different filename → two certs accumulate if both versions are used on the same system.

**Fix:** Change to `simpleDocker-caddy.crt`.

**Shell functions needed:** `_proxy_trust_ca`

---

### DIV-047 · `_proxy_trust_ca` — Python does not copy CA cert to `$MNT_DIR/.sd/caddy/ca.crt`

**Shell (`_proxy_trust_ca`, line 6392):**
```bash
cp "$ca_crt" "$MNT_DIR/.sd/caddy/ca.crt" 2>/dev/null || true
```

**Python:** No such copy. Containers cannot find the CA at the image-internal path.

**Fix:**
```python
try: shutil.copy(str(ca_root), str(G.mnt_dir/'.sd/caddy/ca.crt'))
except: pass
```

**Shell functions needed:** `_proxy_trust_ca`

---

### DIV-048 · `_proxy_caddy_runner` — Python's `_proxy_ensure_sudoers` does NOT include `dnsmasq`, `pkill`, `systemctl avahi` in the rule

**Shell (`_proxy_ensure_sudoers`, line 6321):**
```bash
nopasswd_line="$runner, /usr/sbin/update-ca-certificates, /usr/bin/update-ca-certificates"
if [[ -n "$dnsmasq_bin" ]]; then nopasswd_line+="${dnsmasq_bin}, ${pkill_bin}"; fi
if [[ -n "$systemctl_bin" ]]; then nopasswd_line+="${systemctl_bin} start avahi-daemon, ..."; fi
```

**Python (`_proxy_ensure_sudoers`, line 5033):**
```python
rule = f'{me} ALL=(ALL) NOPASSWD: {runner}\n'
```
Only the runner. `sudo update-ca-certificates`, `sudo dnsmasq`, `sudo systemctl avahi`
all fail silently.

**Fix:**
```python
parts = [str(runner),'/usr/sbin/update-ca-certificates','/usr/bin/update-ca-certificates']
if shutil.which('dnsmasq'): parts += [shutil.which('dnsmasq'), shutil.which('pkill') or '/usr/bin/pkill']
if shutil.which('systemctl'):
    sc = shutil.which('systemctl')
    parts += [f'{sc} start avahi-daemon', f'{sc} enable avahi-daemon']
rule = f'{me} ALL=(ALL) NOPASSWD: {", ".join(p for p in parts if p)}\n'
```

**Shell functions needed:** `_proxy_ensure_sudoers`

---

### DIV-049 · `resize_image` — Python `stop_ct()` per container during resize shows pause dialogs; shell just kills sessions directly

**Shell (`_resize_image` stop block, line 1688):**
```bash
for dcid in "${CT_IDS[@]}"; do
    dsess="$(tsess "$dcid")"
    tmux_up "$dsess" && { tmux send-keys -t "$dsess" C-c "" 2>/dev/null; sleep 0.3; tmux kill-session -t "$dsess"; }
done
tmux list-sessions -F "#{session_name}" | grep "^sdInst_" | xargs -I{} tmux kill-session -t {}
_tmux_set SD_INSTALLING ""
```
No `pause`, no `clear`.

**Python (`resize_image`, line 5623):**
```python
for c in running_cts:
    sess2 = tsess(c)
    _tmux('send-keys', '-t', sess2, 'C-c', '')
    time.sleep(0.3)
    _tmux('kill-session', '-t', sess2)
```
No pause — consistent with shell. Correct.

**Shell functions needed:** N/A

---

### DIV-050 · `help_menu` — "QRencode" shown as installed only based on `chroot command -v`; Python does the same but with a separate call

**Shell (`_help_menu`, line 7143):**
```bash
"$(printf " ${CYN}◈${NC}${DIM}  QRencode — %b${NC}" "$([[ -f "$UBUNTU_DIR/.ubuntu_ready" ]] && _chroot_bash "$UBUNTU_DIR" -c 'command -v qrencode' >/dev/null 2>&1 && printf "${GRN}installed${NC}" || printf "${DIM}not installed${NC}")")"
```

**Python (`help_menu`, line 5793):**
```python
qr_installed = bool(G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists()
                    and _run(['sudo','-n','chroot',str(G.ubuntu_dir),'sh','-c',
                              'command -v qrencode'], capture=True).returncode==0)
```
Both check `ubuntu_ready` first and then `command -v qrencode` inside chroot. Consistent.
No divergence.

**Shell functions needed:** N/A

---

### DIV-051 · `blueprints_submenu` — new blueprint creates `.toml`; shell creates `.toml` ✓. But `_blueprint_template` output differs slightly in comment whitespace

**Shell (`_blueprint_template` output excerpt):**
```
# log        = logs/service.log        # log file shown in View log (default: start.log)
```
Extra alignment spaces.

**Python (`bp_template()`, line 1302):**
```python
# log = logs/service.log # log file shown in View log (default: start.log)
```
No alignment. Minor cosmetic difference — both are comments; no functional impact.

**Shell functions needed:** N/A

---

### DIV-052 · `_snap_submenu` — Python shows static header; shell shows timestamp in header

**Shell (`_container_backups_menu` snap action, line 4158):**
```bash
_menu "$(printf "Backup: %s  (%s)" "$sel_id" "${bts:-?}")" "Restore" "Create clone" "Delete"
```
Header includes the backup timestamp.

**Python (`_snap_submenu`, line 3921):**
```python
sel=menu(f'Backup: {label}  ({ts})','Restore this snapshot','Clone as new container',L['stor_delete'])
```
Consistent — includes timestamp. No divergence.

**Shell functions needed:** N/A

---

### DIV-053 · `blueprints_submenu` → new blueprint: shell checks for `.container` first, then `.toml`; Python creates `.toml` directly

**Shell (`_blueprints_submenu`, line 7554 area):**
```bash
local bfile; bfile="$BLUEPRINTS_DIR/$bname.toml"
[[ -f "$bfile" ]] && { pause "Blueprint '$bname' already exists."; continue; }
_blueprint_template > "$bfile"
```
Creates `.toml`.

**Python (`blueprints_submenu`, line 4629):**
```python
bfile = G.blueprints_dir/f'{bname}.toml'
if bfile.exists(): pause(...); continue
bfile.write_text(bp_template())
```
Also creates `.toml`. Consistent. No divergence.

**Shell functions needed:** N/A

---

### DIV-054 · `_build_update_items_for` — does not call `_build_ubuntu_update_item` or `_build_pkg_manifest_item`; these are separate calls in `container_submenu`

**Shell (`_container_submenu`, lines 5533–5536):**
```bash
_build_update_items "$cid"
[[ "$installed" == "true" ]] && _build_ubuntu_update_item "$cid"
[[ "$installed" == "true" ]] && _build_pkg_update_item "$cid"
```
Three separate functions update `_UPD_ITEMS`.

**Python (`container_submenu`, line 3401):**
```python
_UPD_ITEMS=[]; _UPD_IDX=[]
if not installing and not running:
    _build_update_items_for(cid,_UPD_ITEMS,_UPD_IDX)
```
Only calls `_build_update_items_for`. `_build_ubuntu_update_item_for` and
`_build_pkg_manifest_item_for` are defined but NEVER called from `container_submenu`.

**Fix:** Add after `_build_update_items_for(...)`:
```python
if installed:
    _build_ubuntu_update_item_for(cid, _UPD_ITEMS, _UPD_IDX)
    _build_pkg_manifest_item_for(cid, _UPD_ITEMS, _UPD_IDX)
```

**Shell functions needed:** `_container_submenu`, `_build_ubuntu_update_item`, `_build_pkg_update_item`

---

### DIV-055 · `_do_blueprint_update` — `idx` parameter is `str` from `_build_update_items_for`; code tries `bps[int(idx)]` — type mismatch

**Python (`_build_update_items_for`, line 3695):**
```python
idx.append(str(len(idx)))
```
Appends string index.

**Python (`_do_blueprint_update`, line 3801):**
```python
try: bf=bps[idx] if idx<len(bps) else None
```
`idx` is a string (e.g. `'2'`); `idx<len(bps)` does a string-int comparison → `TypeError`
in Python 3, or wrong result.

**Fix:** Cast: `try: bf=bps[int(idx)] if int(idx)<len(bps) else None`

**Shell functions needed:** N/A (Python-only bug)

---

### DIV-056 · `proxy_menu` — route mDNS display: Python correctly uses `_avahi_mdns_name`; shell does same — no divergence

Both call `_avahi_mdns_name(rurl)` / `_avahi_mdns_name(rurl)`. Consistent. No divergence.

---

### DIV-057 · `_gen_install_script` (emitted `_sd_best_url`) — CUDA block is present in Python

**Python (`_gen_install_script`, lines 1843–1845):**
```python
'  if [[ -z "$url" && "${_SD_GPU:-cpu}" == "cuda" ]]; then',
'    url=$(printf \'%s\' "$type_urls" | grep -iE "cuda" ...) || true',
'  fi',
```
Present. No divergence with the divergences.md entry.

**Shell functions needed:** N/A

---

### DIV-058 · `_gen_install_script` — pip block: Python installs `python3-full python3-pip python3-venv` inside the Ubuntu chroot; shell installs them inside the *install* chroot

**Shell (`_run_job` pip block, line 2869):**
The shell installs `python3-full python3-pip` inside the container's install path chroot,
then creates venv there:
```bash
_sd_pip_cmd=$(mktemp "$install_path/tmp/.sd_pip_XXXXXX.sh")
cat > "$_sd_pip_cmd" <<'...'
DEBIAN_FRONTEND=noninteractive apt-get install -y python3-full python3-pip ...
python3 -m venv --clear /venv
/venv/bin/pip install ...
```
Runs inside `chroot "$install_path"`.

**Python (`_gen_install_script` pip block, line 1937):**
```python
f'_chroot_bash {ub!r} -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-full python3-pip python3-venv ..."',
'_umnt',
f'python3 -m venv {ip!r}/venv 2>/dev/null||true',
'_mnt',
f'sudo -n mount --bind {ip!r} {ub!r}/mnt',
f'_chroot_bash {ub!r} -c "/mnt/venv/bin/pip install {pkg_str} 2>&1"',
```
Installs python3 into the **Ubuntu** chroot, then creates venv in the install path,
then mounts install path into Ubuntu chroot for pip. Different approach from the shell
but produces the same result (pip installed inside container's venv). The venv is created
outside both chrots via host `python3 -m venv` — this means the venv uses the host
Python version, not the Ubuntu chroot's Python version.

**Shell functions needed:** `_run_job` (pip block)

---

### DIV-059 · `_bootstrap_tmux` — `write_sudoers()` always called on every launch; shell's `_sd_outer_sudo` does same; consistent

Both always run the sudo-write/prompt loop on each outer launch. No divergence.

**Shell functions needed:** N/A

---

### DIV-060 · `_bootstrap_tmux` — no `-x 220 -y 50` size flags in Python; shell doesn't use them either — no divergence

Shell `tmux new-session -d -s "simpleDocker" "bash..."` — no explicit size.
Python: same. No divergence.

**Shell functions needed:** N/A

---

### DIV-061 · `_do_ubuntu_update` (per-container) — Python calls `_ubuntu_pkg_op` but the shell calls `_ubuntu_pkg_tmux`; these differ

**Shell (`_do_ubuntu_update`, line 5089):**
```bash
_ubuntu_pkg_tmux "sdUbuntuCtUpd" "Ubuntu update — $name" "$apt_cmd"
```
Uses a separate session name `sdUbuntuCtUpd` (container-specific), not `sdUbuntuPkg`.

**Python (`_do_ubuntu_update`, line 3775):**
```python
_ubuntu_pkg_op('sdUbuntuPkg','Ubuntu update',cmd)
```
Uses `sdUbuntuPkg`. If the Ubuntu system-wide pkg menu is open simultaneously, the same
session name conflicts. Should use a container-specific session.

**Fix:** Change to `_ubuntu_pkg_op(f'sdUbuntuCtUpd_{cid}', f'Ubuntu update — {cname(cid)}', cmd)`.

**Shell functions needed:** `_do_ubuntu_update`, `_ubuntu_pkg_tmux`

---

### DIV-062 · `_snap_submenu` — "Restore" label differs: Python says "Restore this snapshot"; shell says "Restore"

**Shell (`_container_backups_menu`, line 4158):**
```bash
_menu "..." "Restore" "Create clone" "Delete"
```

**Python (`_snap_submenu`, line 3921):**
```python
sel=menu(f'...','Restore this snapshot','Clone as new container',L['stor_delete'])
```
Shell uses `"Restore"` / `"Create clone"` / `"Delete"`.
Python uses `"Restore this snapshot"` / `"Clone as new container"` / `L['stor_delete']`.

The Python labels are clearer but differ from the shell. The dispatch matches on `'Restore'
in sel` so both work. Visual difference only.

**Shell functions needed:** N/A

---

### DIV-063 · `_proxy_install_caddy_menu` — Python uses single session `sdCaddyInst`; shell uses `sdCaddyMdnsInst_$$` (unique per launch)

**Shell (`_proxy_install_caddy`, line 6518):**
```bash
local sess="sdCaddyMdnsInst_$$"
_tmux_launch "$sess" "Install Caddy + mDNS" "$script"
```

**Python (`_proxy_install_caddy_menu`, line 5199):**
```python
sess = 'sdCaddyInst'
```
Fixed name. If user triggers Caddy install twice quickly, the second kills the first.
Also the session name `sdCaddyMdnsInst_$$` appears in `_active_processes_menu`'s session
filter regex — Python's `sdCaddyInst` is not matched by the filter
`r'^sd_[a-z0-9]{8}$|^sdInst_|^sdCron_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$'`,
so Caddy install won't appear in active processes.

**Fix:** Either match the session pattern or add `sdCaddyInst` to the processes filter.

**Shell functions needed:** `_proxy_install_caddy`, `_active_processes_menu`

---

### DIV-064 · `persistent_storage_menu` — `__export__` opens `_stor_export` with full profile picker; Python shows "Select a container first"

**Shell (`_persistent_storage_menu`, line 4487):**
```bash
"__export__")   _stor_export_menu ;;
```
`_stor_export_menu` shows a picker of **all** storage profiles across all containers.

**Python (`persistent_storage_menu`, line 2996):**
```python
if sel_scid == '__export__':
    if cid:
        ...profile picker within that cid's storage...
    else:
        pause('Select a container first to export.')
```
When called from "Profiles & data" (no `cid` context), export is blocked with a pause.
Shell always shows the full multi-profile export picker.

**Fix:** When `cid == ''`, show the full-profile export picker instead of pausing.

**Shell functions needed:** `_stor_export_menu`