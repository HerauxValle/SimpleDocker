# Fix Plan — services.py divergences from services.sh

## Context
`services.py` is a Python rewrite of `services.sh`. The goal is 1:1 functional and visual parity.
`divergences.md` is the authoritative list of all known divergences (DIV-001 through DIV-064).
Fix each DIV in severity order. Every fix must be verified against the shell source.

---

## Rules

1. **Never hallucinate shell behaviour.** Always re-read the relevant shell function before writing a fix.
2. **Schema fixes first.** DIV-013 (cron `cmd` vs `command`) affects all downstream cron code — fix before touching cron display or cron start logic.
3. **DIV-004 (build_start_script) is the hardest fix.** Read shell `_build_start_script` in full before touching it. The env must be embedded inside the heredoc with `CONTAINER_ROOT=/`.
4. **Do not break working behaviour.** Some Python divergences are improvements (DIV-005, DIV-027, DIV-046, DIV-052, DIV-061). Mark them as intentional and do not revert.
5. **One DIV per commit/edit pass.** Don't batch unrelated changes.
6. **Test after each HIGH fix** by tracing the codepath mentally or running the relevant function.

---

## Intentional Improvements — Do NOT revert

| DIV | Reason to keep Python behaviour |
|-----|-------------------------------|
| DIV-005 | `generate:hex32` persists secrets across restarts |
| DIV-027 | Cron countdown display in menu (extra feature) |
| DIV-046 | `health_check` also checks `environment.PORT` |
| DIV-052 | `active_processes_menu` shows cron sessions; sdInst_ label is more robust |
| DIV-061 | Persistent BPs seeded to disk on mount (keeps them current) |

---

## Fix Order (by severity, then dependency)

### Phase 1 — Schema fixes (must be first, other DIVs depend on these)

| DIV | What to fix |
|-----|-------------|
| DIV-013 | Change `_parse_cron_line` to emit `{'cmd': cmd, 'flags': '...'}` instead of `{'command': cmd, 'sudo': bool, 'unjailed': bool}`. Update `_cron_start_one` to read `cr.get('cmd','')` and parse flags string. |
| DIV-044 | Remove `⊙` prefix from `_parse_action_line`. Add prefix dynamically in `container_submenu` at display time. |
| DIV-053 | Change new blueprint extension from `.container` to `.toml` in `blueprints_submenu`. |

---

### Phase 2 — HIGH functional fixes

| DIV | Function | What to fix |
|-----|----------|-------------|
| DIV-001 | `validate_containers` | Add `data['installed'] = False; sf.write_text(json.dumps(data, indent=2))` after the missing-path check. |
| DIV-002 | `run_job` | Add `tmux_set('SD_INSTALLING', cid)` immediately after the install session is started. |
| DIV-003 | `_pick_storage_profile` | Rewrite to iterate `G.storage_dir` flat (not `storage_dir/cid`), filter by `storage_type`, show name/size/in-use. See divergences.md for full replacement. |
| DIV-004 | `build_start_script` | Move env setup **inside** the heredoc body. Use `CONTAINER_ROOT=/` (not absolute host path). Embed inline as shell string passed to `_chroot_bash ... -c "cd / && export ... && cmd"`. |
| DIV-007 | `_cr_prefix` | Add pure-number, colon, IPv4, and `://` passthrough conditions. |
| DIV-008 | `start_ct` | Add `if not _guard_space(): return` at top. |
| DIV-009 | `start_ct` | Add `_tmux('set-hook','-t',sess,'pane-exited',f'kill-session -t {sess}')` after `detach-on-destroy`. |
| DIV-012 | `_cron_start_one` | Add `mount -t proc`, `mount --bind /sys`, `mount --bind /dev` into ubuntu before the chroot call in jailed branch. |
| DIV-014 | `_SD_CAP_DROP_DEFAULT` | Change to `cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,cap_mknod,cap_audit_write,cap_audit_control,cap_syslog`. |
| DIV-015 | `_ensure_ubuntu` | Add sanity check at top; write `.ubuntu_default_pkgs`; remove `set -e`; add `trap '' INT`. |
| DIV-017 | `_force_quit` | Add mnt_* sweep, LUKS close loop, and loop device detach after `unmount_img()`. |
| DIV-018 | `_proxy_start` | Add `_proxy_ensure_sudoers()` call; swap `_proxy_dns_start` before `_avahi_start`. |
| DIV-019 | `run_job` | Add `if not _guard_space(): return` before script generation. |
| DIV-039 | `_stop_group` | Add shared-group check before calling `stop_ct`. |
| DIV-040 | `_open_in` Terminal | Shell opens plain bash in install dir on host. Python opens nsenter+chroot. **Decide** which is intended and document. If matching shell: remove nsenter/chroot from terminal command. |
| DIV-058 | `_gen_install_script` pip | Add apt install of `python3-full python3-pip python3-venv` inside chroot before venv creation. |

---

### Phase 3 — MEDIUM fixes

| DIV | Function | What to fix |
|-----|----------|-------------|
| DIV-010 | `stop_ct` | Add `time.sleep(0.2)` before `_stor_unlink`; add `pause(f"'{cname(cid)}' stopped.")` at end. |
| DIV-011 | cron script | Change `sleep "$_secs"` to `sleep "$_secs" &\n    wait $!` in both branches. |
| DIV-016 | `ubuntu_menu` | Add "already up to date" check; write `.ubuntu_default_pkgs` after sync. |
| DIV-021 | `exposure_apply` | Gate call with `if tmux_up(tsess(cid)):` in container_submenu exposure handler. |
| DIV-022 | `_guard_space` | Add `mountpoint -q` pre-check; fix message text. |
| DIV-023 | `ct_attach` | Add `confirm()` dialog with detach key hint before `switch-client`. |
| DIV-030 | `write_pkg_manifest` | Parse deps string into individual package tokens before storing. |
| DIV-042 | action runner | Apply `_cr_prefix` to command binary in `select:` and plain segments. |
| DIV-043 | action runner | Add pause dialogs before/after action session switch. |
| DIV-045 | `run_job` | Add Attach/Background fzf prompt after session creation. |
| DIV-047 | `_edit_container_bp` | Add running/installing guard; add `_guard_space()`; change default editor to `vi`. |
| DIV-048 | `rename_container` | Block rename for installed containers. Remove `build_start_script` call. |
| DIV-049 | `resize_image` | Replace `stop_ct()` calls with direct session kills (no per-container pause). |
| DIV-054 | update items | Add persistent blueprint scan in `_build_update_items_for`. |
| DIV-055 | `_do_blueprint_update` | Add content diff check for same-version case. |
| DIV-056 | `proxy_menu` | Fix mDNS display (use `_avahi_mdns_name`); add value to Toggle HTTPS label; fix Uninstall to call `_avahi_stop` and remove runner; add port-conflict parsing on start failure. |
| DIV-057 | install script | Add CUDA asset selection block to emitted `_sd_best_url`. |
| DIV-059 | bootstrap | Call `write_sudoers()` unconditionally, not gated on file existence. |
| DIV-062 | `_snap_submenu` | Add timestamp to header; add running-state guards before Restore and Clone. |
| DIV-063 | proxy install | Add Attach/Background prompt; add reinstall mode; improve version fallback. |

---

### Phase 4 — LOW / VISUAL fixes

| DIV | What to fix |
|-----|-------------|
| DIV-006 | Add `_sd_sp=$(python3 -c ...)` line to `_env_exports` output. |
| DIV-024 | Use `stat` file size for image total in `main_menu` instead of `df` total. |
| DIV-025 | Always count imported blueprints regardless of autodetect mode. |
| DIV-026 | Dim non-ANSI items in `_fzf_with_watcher`. |
| DIV-028 | Add days format to cron countdown (`d2, rem = divmod(rem, 86400)`). |
| DIV-029 | Move `netns_ct_del` before cron/action session kills in `stop_ct`. |
| DIV-031 | Write `.ubuntu_default_pkgs` in `_ensure_ubuntu` (covered by DIV-015 fix). |
| DIV-032 | Add `time.sleep(0.5)` at end of `start_ct`. |
| DIV-033 | Fix pkg update label to include timestamp: `f'... {DIM}— {ts}{NC} — {YLW}Update available{NC}'`. |
| DIV-034 | Fix main menu separator: `f'{BLD}  ─────────────────────────────────────{NC}'`. |
| DIV-035 | Covered by DIV-010 fix (pause after stop). |
| DIV-036 | Covered by DIV-022 fix (message text). |
| DIV-038 | Covered by DIV-006 fix. |
| DIV-041 | Remove `return` after xdg-open in `_open_in` file manager. |
| DIV-050 | Change encryption icon to `◈`; remove LUKS pre-check; move `ub_cache_read` inside loop. |
| DIV-051 | Change `logs_browser` sort to filename (lexicographic reverse) to match shell. |
| DIV-060 | Remove `-x 220 -y 50` from tmux new-session in `_bootstrap_tmux`. |
| DIV-064 | Fix QRencode Update arrow to cyan; add session wait-loop. |

---

## Key Reference Points in services.sh

| Topic | Shell line(s) |
|-------|---------------|
| `_build_start_script` env_str | 2992–3067 |
| `_cron_start_one` full body | 3145–3210 |
| `_run_job` SD_INSTALLING set | ~2895 |
| `_validate_containers` | 1891–1900 |
| `_pick_storage_profile` | 4322–4376 |
| `_stop_container` order | 3368–3400 |
| `_SD_CAP_DROP_DEFAULT` | 3311 |
| `_force_quit` extra cleanup | 337–394 |
| `_proxy_start` step order | 6347–6380 |
| action runner `_cr_prefix` | 5780–5815 |
| `_do_blueprint_update` diff | 5126–5165 |