# services.py Fix Checklist

---

## SYSTEM PROMPT — paste this at the start of every fix session

```
You are fixing services.py based on divergences.md and plan.md.
Rules:
- You have 20 tool calls per message. Budget: read(2) → fix(N) → syntax-check(1) → output(1). Never exceed 20.
- Before ANY fix: read the exact shell lines referenced in the DIV. Do not hallucinate shell behaviour.
- Output format per DIV: {"div":"DIV-XXX","file":"services.py","type":"str_replace","old":"...","new":"..."}
- If a DIV has multiple changes, output one JSON block per change.
- After all fixes in session: run `python3 -m py_compile services.py` and show result.
- If compile fails: fix the error, recheck, then output final file region.
- Fixes must be minimal — change only what the DIV specifies. No refactoring.
- KEEP items: DIV-005, DIV-027, DIV-046, DIV-052, DIV-061 — do not touch these.
- N/A item: DIV-037 — skip.
- DIV-031, DIV-035, DIV-036, DIV-038 are covered by their parent DIV — skip as standalone.
```

---

## Session 1 — Schema (do first, everything depends on these)
**Files needed:** services.py lines ~1186-1210 (bp_parse), ~3300-3340 (container_submenu cron display), ~4450 (blueprints_submenu new file)
**Shell refs:** line 2150 (cron JSON), line 5505 (⊙ prefix), line 7557 (blueprint extension)

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 1** | [ ] | |
| DIV-013 | [ ] | `_parse_cron_line` → emit `{'cmd':cmd,'flags':'--sudo'/'--unjailed'/...}` not `{'command':cmd,'sudo':bool}`. Update `_cron_start_one` to read `cr.get('cmd','')` and parse flags string. |
| DIV-044 | [ ] | Remove `⊙` from `_parse_action_line`. Add `if re.match(r'^[a-zA-Z0-9]',lbl): lbl='⊙  '+lbl` in `container_submenu` at display time. |
| DIV-053 | [ ] | `blueprints_submenu` new blueprint: change `.container` → `.toml` |

---

## Session 2 — Install flow (highest user-visible breakage)
**Files needed:** services.py `validate_containers`, `run_job`, `_guard_space`, `_gen_install_script` pip block
**Shell refs:** lines 1891-1900, 2895, 2751, 2856

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 2** | [ ] | |
| DIV-001 | [ ] | `validate_containers`: add `data['installed']=False; sf.write_text(json.dumps(data,indent=2))` — currently a stub with no write |
| DIV-002 | [ ] | `run_job`: add `tmux_set('SD_INSTALLING',cid)` after `_tmux('new-session'...)` call |
| DIV-019 | [ ] | `run_job`: add `if not _guard_space(): return` before script generation |
| DIV-022 | [ ] | `_guard_space`: add `mountpoint -q` pre-check; fix message text to match shell exactly |
| DIV-058 | [ ] | `_gen_install_script` pip: add apt install of `python3-full python3-pip python3-venv` inside chroot before venv creation |

---

## Session 3 — Container lifecycle (start/stop/cron)
**Files needed:** services.py `start_ct`, `stop_ct`, `_cron_start_one`
**Shell refs:** lines 3235-3313, 3368-3400, 3145-3210

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 3** | [ ] | |
| DIV-008 | [ ] | `start_ct`: add `if not _guard_space(): return` at top |
| DIV-009 | [ ] | `start_ct`: add `_tmux('set-hook','-t',sess,'pane-exited',f'kill-session -t {sess}')` after `detach-on-destroy` |
| DIV-010 | [ ] | `stop_ct`: add `time.sleep(0.2)` before `_stor_unlink`; add `pause(f"'{cname(cid)}' stopped.")` at end |
| DIV-011 | [ ] | `_cron_start_one`: change `sleep "$_secs"` → `sleep "$_secs" &\n    wait $!` in both branches |
| DIV-012 | [ ] | `_cron_start_one`: add `mount -t proc/sys/dev` into ubuntu before chroot in jailed branch |
| DIV-029 | [ ] | `stop_ct`: move `netns_ct_del` call before cron/action session kills |
| DIV-032 | [ ] | `start_ct`: add `time.sleep(0.5)` at end |

---

## Session 4 — build_start_script + env + cr_prefix (hardest, read shell carefully)
**Files needed:** services.py `build_start_script`, `_env_exports`, `_cr_prefix`
**Shell refs:** lines 2992-3110 (env_str inside heredoc, CONTAINER_ROOT=/), 2554-2605, 2179-2193

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 4** | [ ] | |
| DIV-004 | [ ] | `build_start_script`: env must be **inside** heredoc body as inline `export CONTAINER_ROOT=/ ...` baked into `-c "cd / && export ... && cmd"`. Currently written outside heredoc → sudo strips it. |
| DIV-006 | [ ] | `_env_exports`: add `_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if 'site-packages' in p and '/usr' not in p),''))" 2>/dev/null)` line |
| DIV-007 | [ ] | `_cr_prefix`: add passthrough for pure integers, values containing `:`, IPv4 pattern, values containing `://` |

---

## Session 5 — Storage + cap_drop + pkg manifest
**Files needed:** services.py `_pick_storage_profile`, `_SD_CAP_DROP_DEFAULT`, `write_pkg_manifest`, `_build_pkg_manifest_item_for`
**Shell refs:** lines 4322-4376, 3311, 4835-4865, 4862-4895

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 5** | [ ] | |
| DIV-003 | [ ] | `_pick_storage_profile`: rewrite — currently traverses `storage_dir/cid` (wrong). Must iterate `storage_dir/*`, filter by `storage_type`. See divergences.md for full replacement. |
| DIV-014 | [ ] | `_SD_CAP_DROP_DEFAULT`: change to `cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_mknod,cap_audit_write,cap_audit_control,cap_syslog` |
| DIV-020 | [ ] | `_build_pkg_manifest_item_for`: fix cache key to `gh_tag/{cid}` (not per-repo); fix update label to include timestamp; write `.inst` file after update |
| DIV-030 | [ ] | `write_pkg_manifest`: parse deps string into individual package tokens before storing |

---

## Session 6 — Ubuntu + _ensure_ubuntu
**Files needed:** services.py `_ensure_ubuntu`, `ubuntu_menu`
**Shell refs:** lines 1472-1550, 7000-7035

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 6** | [ ] | |
| DIV-015 | [ ] | `_ensure_ubuntu`: add sanity check (`.ubuntu_ready` exists but `usr/bin/apt-get` missing → remove flag); align sentinel filenames; write `.ubuntu_default_pkgs`; remove `set -e`; add `trap '' INT` |
| DIV-016 | [ ] | `ubuntu_menu` Sync: add "already up to date" early-exit check; write `.ubuntu_default_pkgs` after sync completes |

---

## Session 7 — Force quit + proxy start + bootstrap
**Files needed:** services.py `_force_quit`, `_proxy_start`, `_bootstrap_tmux`
**Shell refs:** lines 337-394, 6347-6380, 300-335

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 7** | [ ] | |
| DIV-017 | [ ] | `_force_quit`: add mnt_* sweep + LUKS mapper close loop + loop device detach after `unmount_img()` |
| DIV-018 | [ ] | `_proxy_start`: add `_proxy_ensure_sudoers()` call; move `_proxy_dns_start` before `_avahi_start` |
| DIV-059 | [ ] | `_bootstrap_tmux`: call `write_sudoers()` unconditionally (not gated on file existence) |
| DIV-060 | [ ] | `_bootstrap_tmux`: remove `-x 220 -y 50` from `tmux new-session` call |

---

## Session 8 — Container submenu + action runner + menus
**Files needed:** services.py `container_submenu`, `_run_action`, `_edit_container_bp`, `_rename_container`, `_open_in_submenu`
**Shell refs:** lines 5478-5825, 5748-5815, 5436-5460, 5459-5480, 5311-5378

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 8** | [ ] | |
| DIV-021 | [ ] | `container_submenu` exposure handler: gate `exposure_apply` with `if tmux_up(tsess(cid)):` |
| DIV-023 | [ ] | `ct_attach`: add `confirm()` dialog with `KB['tmux_detach']` hint before `switch-client` |
| DIV-040 | [ ] | `_open_in` Terminal: **decide** host-bash vs container-bash, document in Notes, implement chosen |
| DIV-041 | [ ] | `_open_in` file manager: remove `return` after xdg-open |
| DIV-042 | [ ] | `_run_action`: apply `_cr_prefix` to command binary in `select:` and plain cmd segments |
| DIV-043 | [ ] | `_run_action`: add pause dialogs ("Starting…" / "already running") before `switch-client` |
| DIV-045 | [ ] | `run_job`: add Attach/Background fzf prompt after session creation |
| DIV-047 | [ ] | `_edit_container_bp`: add running/installing guard; add `_guard_space()`; default editor → `vi` |
| DIV-048 | [ ] | `_rename_container`: block rename if `installed=True`; remove `build_start_script` call |

---

## Session 9 — Proxy menu + blueprint updates + backups
**Files needed:** services.py `proxy_menu`, `_build_update_items_for`, `_do_blueprint_update`, `_snap_submenu`, `resize_image`
**Shell refs:** lines 6526-6770, 5096-5130, 5126-5165, 4147-4165, 1656-1720

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 9** | [ ] | |
| DIV-039 | [ ] | `_stop_group`: add shared-group check before `stop_ct` |
| DIV-049 | [ ] | `resize_image`: replace `stop_ct()` per-container with direct `send-keys C-c + kill-session` (no pause per container) |
| DIV-054 | [ ] | `_build_update_items_for`: add persistent blueprint scan with `[P]` tag |
| DIV-055 | [ ] | `_do_blueprint_update`: add content diff check for same-version case; add "nothing to do" path |
| DIV-056 | [ ] | `proxy_menu`: fix mDNS display; add value to Toggle HTTPS label; fix Uninstall (`_avahi_stop` + remove runner); add port-conflict parsing on start failure |
| DIV-057 | [ ] | `_gen_install_script`: add CUDA block to emitted `_sd_best_url` |
| DIV-062 | [ ] | `_snap_submenu`: add timestamp to header; add running-state guards before Restore and Clone |
| DIV-063 | [ ] | `_proxy_install_caddy_menu`: add Attach/Background prompt; add reinstall mode; improve version fallback |

---

## Session 10 — Visual / low priority
**Files needed:** services.py `main_menu`, `logs_browser`, `help_menu`, `_qrencode_menu`, `container_submenu` (cron countdown)
**Shell refs:** lines 7228-7320, 7092-7115, 7115-7230, 6404-6460

| DIV | Done | Notes |
|-----|------|-------|
| **SESSION 10** | [ ] | |
| DIV-024 | [ ] | `main_menu`: use `stat` file size for image total GB, not `df` total |
| DIV-025 | [ ] | `main_menu`: always count imported BPs regardless of autodetect mode |
| DIV-026 | [ ] | `_fzf_with_watcher`: dim non-ANSI items |
| DIV-028 | [ ] | cron countdown: add days format `d2,rem=divmod(rem,86400)` |
| DIV-033 | [ ] | pkg update label: add timestamp — `f'... {DIM}— {ts}{NC} — {YLW}Update available{NC}'` |
| DIV-034 | [ ] | main menu separator: `f'{BLD}  ─────────────────────────────────────{NC}'` |
| DIV-050 | [ ] | `help_menu`: change encryption icon `⚷`→`◈`; remove LUKS pre-check; move `ub_cache_read` inside loop |
| DIV-051 | [ ] | `logs_browser`: change sort to filename lexicographic reverse (match shell) |
| DIV-064 | [ ] | `_qrencode_menu`: Update arrow → cyan; add session wait-loop |