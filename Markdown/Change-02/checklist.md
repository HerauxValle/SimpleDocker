# services.py Fix Checklist

---

## SYSTEM PROMPT — paste at the start of every fix session

```
You are fixing services.py based on divs.md.
Rules:
- Budget per message: read(2) → fix(N) → py_compile(1) → output(1). Never exceed 20 tool calls.
- Before ANY fix: read the exact shell lines cited in the DIV. Never hallucinate shell behaviour.
- Output format per DIV: {"div":"DIV-XXX","type":"str_replace","old":"...","new":"..."}
- One JSON block per change. Multiple blocks if a DIV has multiple hunks.
- After all fixes: run `python3 -m py_compile services.py` and show result.
- If compile fails: fix error, recheck, show final region.
- Fixes must be minimal — change only what the DIV specifies. No refactoring.
- SKIP (no fix needed): DIV-003 DIV-005 DIV-008 DIV-016 DIV-019 DIV-020 DIV-021 DIV-022
  DIV-023 DIV-024 DIV-025 DIV-026 DIV-027 DIV-030 DIV-032 DIV-033 DIV-034 DIV-035
  DIV-036 DIV-039 DIV-040 DIV-041 DIV-047(covered by DIV-048) DIV-050 DIV-052 DIV-053
  DIV-056 DIV-057 DIV-059 DIV-060
```

---

## Session 1 — Data integrity (snap_dir, load_containers, cron parse)
**Scope:** `snap_dir`, `load_containers`, `_parse_cron_line`, `container_submenu` (update calls)

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-001 | [ ] | `load_containers`: skip containers where `data.get('hidden')` is truthy |
| DIV-002 | [ ] | `snap_dir`: `return G.backup_dir/cname(cid)` instead of `G.backup_dir/cid` |
| DIV-004 | [ ] | `_parse_cron_line`: rewrite `>> relpath` → `>> $CONTAINER_ROOT/relpath` in `cmd` |
| DIV-054 | [ ] | `container_submenu` update block: call `_build_ubuntu_update_item_for` + `_build_pkg_manifest_item_for` after `_build_update_items_for` when `installed` |
| DIV-055 | [ ] | `_do_blueprint_update`: cast `idx` to `int` before `bps[idx]` |

**Shell refs needed:** `_load_containers` (line 1877), `_snap_dir` (line 3795), `_bp_flush_section` cron (line 2016), `_container_submenu` update block (lines 5533–5536)

---

## Session 2 — Stop/start lifecycle
**Scope:** `stop_ct`, `_cron_start_one`, `_do_ubuntu_update`, `_do_pkg_update`

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-010 | [ ] | `stop_ct`: add `os.system('clear')` before final `pause(...)` |
| DIV-011 | [ ] | `_cron_start_one`: handle `--sudo` flag — wrap cmd with `sudo -n bash -c` after `$CONTAINER_ROOT` substitution |
| DIV-012 | [ ] | `_cron_start_one`: wrap `_cb` call args in `shlex.quote()` to handle paths with spaces |
| DIV-007 | [ ] | `_do_ubuntu_update`: change `dist-upgrade`→`upgrade`; add base-version confirm; add backup prompt; write stamp after op |
| DIV-031 | [ ] | `_do_pkg_update`: generate full inline apt/pip/npm/git update script instead of `run_job(cid,'update')` |
| DIV-061 | [ ] | `_do_ubuntu_update` (per-container): use `f'sdUbuntuCtUpd_{cid}'` session name |

**Shell refs needed:** `_stop_container` (line 3390), `_cron_start_one` (lines 3145–3201), `_do_ubuntu_update` (lines 5067–5094), `_do_pkg_update` (lines 4894–5035)

---

## Session 3 — Proxy + CA trust
**Scope:** `_proxy_trust_ca`, `_proxy_ensure_sudoers`, `_proxy_dns_start`, `_proxy_install_caddy_menu`

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-045 | [ ] | `_proxy_trust_ca`: poll up to 5s for CA cert file before returning |
| DIV-046 | [ ] | `_proxy_trust_ca`: rename `caddy-local.crt` → `simpleDocker-caddy.crt` |
| DIV-047 | [ ] | `_proxy_trust_ca`: copy CA cert to `G.mnt_dir/'.sd/caddy/ca.crt'` |
| DIV-048 | [ ] | `_proxy_ensure_sudoers`: add `update-ca-certificates`, `dnsmasq`, `pkill`, `systemctl avahi` to NOPASSWD rule |
| DIV-018 | [ ] | `_proxy_dns_start`: call `_proxy_dns_stop()` at top before starting new instance |
| DIV-063 | [ ] | `_proxy_install_caddy_menu`: use unique session `f'sdCaddyMdnsInst_{os.getpid()}'`; add to active-processes regex |

**Shell refs needed:** `_proxy_trust_ca` (lines 6379–6393), `_proxy_ensure_sudoers` (lines 6321–6345), `_proxy_dns_start` (lines 6200–6208), `_proxy_install_caddy` (lines 6457–6524), `_active_processes_menu` filter regex (line 5857)

---

## Session 4 — Update labels + ubuntu items
**Scope:** `_build_update_items_for`, `_build_ubuntu_update_item_for`, `_do_blueprint_update` confirm text, `_do_pkg_update` confirm text

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-013 | [ ] | `_build_update_items_for`: add source label and version suffix to entry strings |
| DIV-014 | [ ] | `_build_ubuntu_update_item_for`: compare per-container `.sd_ubuntu_stamp` to base stamp; show "Not installed" if ubuntu absent |
| DIV-028 | [ ] | cron countdown in `container_submenu`: add seconds-only branch `elif not m2: countdown = f'next: {s2}s'` |

**Shell refs needed:** `_build_update_items` (lines 5096–5123), `_build_ubuntu_update_item` (lines 5044–5065), `_cron_countdown` (lines 3131–3142)

---

## Session 5 — UI fixes + misc
**Scope:** `load_containers` hidden, `_force_quit` block_device, `_qrencode_menu` loop, `logs_browser` sort, `persistent_storage_menu` export, `_proxy_dns_write`

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-017 | [ ] | `_force_quit`: use `stat.S_ISBLK(os.stat(str(mp)).st_mode)` instead of `mp.is_block_device()` |
| DIV-037 | [ ] | `logs_browser`: change `key=lambda f: f.name` → `key=lambda f: str(f)` |
| DIV-038 | [ ] | `_qrencode_menu`: wrap body in `while True:` with `continue` after each op; add return for outer while-true loop |
| DIV-042 | [ ] | `_run_action`: add `label` parameter; use label in "already running" pause instead of `dsl[:30]` |
| DIV-044 | [ ] | `__main__`: remove redundant `ub_thread.start()` call (thread starts in `set_img_dirs` already) |
| DIV-064 | [ ] | `persistent_storage_menu`: `__export__` with no cid context → show full profile picker instead of pause |
| DIV-006 | [ ] | `_env_exports`: document that `_sd_sp`/PYTHONPATH lines are Python additions — add comment noting divergence |

**Shell refs needed:** `_force_quit` (lines 376–394), `_logs_browser` (lines 7092–7115), `_qrencode_menu` (lines 6404–6455), `_container_submenu` action dispatch (lines 5748–5819), `_stor_export_menu` (lines 4600–4660)

---

## Session 6 — Run job confirm + action label pass-through (finish)
**Scope:** `run_job`, `container_submenu` action dispatch, `_run_action` signature

| DIV | Done | Fix summary |
|-----|------|-------------|
| DIV-015 | [ ] | `_ensure_ubuntu`: fix `.ubuntu_default_pkgs` write: one package per line |
| DIV-043 | [ ] | `run_job`: consider moving fzf prompt before `_tmux('new-session'...)` so cancelling ESC doesn't silently start install |

**Shell refs needed:** `_ensure_ubuntu` (lines 1472–1550), `_tmux_launch` (lines 5244–5301)