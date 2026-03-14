# services.py — Fix & Divergence Status

Source of truth: `pyissues.md`, `shoverview.md`, `services.sh`

---

## ✅ PREVIOUSLY FIXED (pyissues.md)

| # | Sev | Description |
|---|-----|-------------|
| 13 | CRIT | `resize_image`: sentinel files in `G.tmp_dir` with unique suffix; proper fail sentinel |
| 14 | CRIT | `resize_image`: LUKS re-open uses `verification_cipher` → `SD_DEFAULT_KEYWORD` → prompt |
| 15 | HIGH | `resize_image`: stops running containers (with confirm) before resize |
| 10 | HIGH | `_bootstrap_tmux`: inner detection checks `$TMUX` in addition to `SD_INNER=1` |
| 16 | HIGH | `_seed_persistent_blueprints`: always overwrites — dict changes propagate to disk |
| 3  | MED  | `enc_menu` System Agnostic disable: uses `SD_DEFAULT_KEYWORD` temp file (not `finput`) |
| 11 | MED  | Outer re-attach stdin drain: `tcflush` + select/read-discard loop |
| 18 | MED  | `main_menu` Groups: shows `[N active/M]` active group count |
| 20 | MED  | `setup_image` loop: checks `G.usr1_fired` before `_force_quit` |
| 24 | MED  | `netns_teardown`: deletes `.netns_name`, `.netns_idx`, `.netns_hosts` |
| 2  | MIN  | `Reset Auth Token`: `--test-passphrase` validates auth.key before kill attempt |
| 12 | MIN  | `_bootstrap_tmux`: always `sudo -k` + `sudo -v` re-validates on every launch |
| 19 | MIN  | `containers_submenu`: batches `service.json`+`state.json` into one read per container |

---

## 🔴 NEW — VISUAL DIVERGENCES (from services.sh comparison)

| # | Location | Shell | Python |
|---|----------|-------|--------|
| V1 | `main_menu` Containers line | `"%-28s %b"` — padded name + coloured status (e.g. `3 running/5`) | `[{n_ct} · {n_running} ▶]` — different layout, no padding, `▶` icon inside brackets |
| V2 | `main_menu` Containers: when no running | Shows `DIM N DIM` (just grey count) | Always shows `· N_running ▶` even when 0 |
| V3 | `main_menu` Groups status | `GRN N active DIM/M NC` or `DIM M NC` (conditional colour) | `DIM[grp_n_active active/n_grp]` — always same format, no conditional green |
| V4 | `main_menu` Blueprints line | `"%-28s DIM N NC"` with 28-char padded label | `DIM[{n_bp}]NC` — no padding |
| V5 | `container_submenu` installed state | Order: Start, Open in, `── Storage ──`, Backups, Profiles, Edit toml, `── Caution ──`, Updates, Uninstall | Order: Start, Open in, `── Management ──`, Edit toml, Rename, Exposure, `── Storage ──`, Backups, Profiles, `── Caution ──`, Updates, Uninstall |
| V6 | `container_submenu` installed state | `ct_rename` and `ct_exposure` NOT shown when installed+stopped | Python shows Rename and Exposure under `── Management ──` when installed+stopped |
| V7 | `container_submenu` running state | No `ct_exposure` in running items list (separate `⬤  Exposure` handler via `*"⬤  Exposure"*`) | Shows `ct_exposure` as a named item in running items list |
| V8 | `container_submenu` uninstalled state | Order: Install, Edit, Rename, `── Caution ──`, Remove | Python same — ✅ correct |
| V9 | `_help_menu` header | `── Other ──  DIM Ubuntu: NC{status}  DIM Proxy: NC{status}` with `ubuntu_upd_tag` appended to ubuntu_status inside | Python: Ubuntu status + Update tag inline in header — close but `ubuntu_upd_tag` variable shown differently |
| V10 | `blueprints_submenu` new blueprint | Creates file with `_blueprint_template`, shows `pause "Blueprint created. Select it to edit."` — does NOT open editor | Python opens `$EDITOR` immediately after creation |
| V11 | `blueprints_submenu` header | `── Blueprints ──  DIM[N file · N built-in · N imported]` with section header `── Blueprints ──` inside list | Python: same header format ✅, but list starts directly without inner section separator |
| V12 | `resize_image` prompt location | Prompt (`finput`) is in `_help_menu` (caller), result passed to `_resize_image $size` | Python prompts inside `resize_image()` itself |
| V13 | `resize_image` minimum size formula | `int(used_bytes/GiB)+1+10` (integer GB: used rounded down + 1 + 10 headroom) | `round(used_gb * 1.1, 2)` (10% headroom) — different formula, different values |
| V14 | `resize_image` confirm message | `Resize image from X GB → Y GB?` or `Running services will be stopped:\n  • name\n\nResize image from X GB → Y GB?` (bullet list with `•`) | Python: `Running services will be stopped:\n  name\n\n  Resize?` — no `•` bullets, different wording |
| V15 | `mount_img` mount point path | `mnt_$(basename "${img%.img}")` — name-based (e.g. `mnt_simpleDocker`) | `mnt_{md5[:8]}` — hash-based |
| V16 | `_autodetect_mode` default | `${m:-Home}` — defaults to **Home** if unset | Python: `_bp_settings_get('autodetect_blueprints','Disabled')` — defaults to **Disabled** |

---

## 🟠 NEW — FUNCTIONAL DIVERGENCES (from services.sh comparison)

| # | Location | Shell | Python |
|---|----------|-------|--------|
| F1 | `_bp_validate` | Validates: name required, entrypoint/start required, port must be number, storage requires storage_type, git line format, dirs parens balanced, actions {input}/{selection} consistency, pip requires python3 in deps | Python only validates: name required — missing 7 other validation checks |
| F2 | `_env_exports` | Exports: `CONTAINER_ROOT`, HOME, XDG_*, PATH (includes `python/bin`, `.local/bin`), PYTHONNOUSERSITE, PIP_USER, `VIRTUAL_ENV`, PYTHONPATH (computed), auto-creates dirs, GPU auto-detect block for `cuda_auto` | Python missing: `VIRTUAL_ENV`, `PYTHONPATH`, dir auto-creation in exports, GPU auto-detect block |
| F3 | `_env_exports` PATH | `venv/bin:python/bin:.local/bin:bin:$PATH` | Python: `venv/bin:bin:$PATH` — missing `python/bin` and `.local/bin` |
| F4 | `_env_exports` env values | `generate:hex32` → substituted with `$(openssl rand -hex 32 ...)` at runtime | Python: passes `generate:hex32` literal string |
| F5 | `_env_exports` LD_LIBRARY_PATH etc | `LD_LIBRARY_PATH`, `LIBRARY_PATH`, `PKG_CONFIG_PATH` appended with `:${existing:-}` | Python: all env vars exported with `=` overwrite |
| F6 | `_compile_service` / `_bootstrap_src` | If `service.src` is already valid JSON (previously compiled), copies it directly to `service.json` without re-parsing; also computes and stores `sha256` hash of src | Python: always re-parses toml; no hash tracking |
| F7 | `_ensure_src` | If `service.src` missing but `service.json` exists, bootstraps src from json | Python: creates empty template instead |
| F8 | `resize_image` after success | On success: kills all container sessions, unmounts image, then `exec bash "$0"` (restarts itself) — full fresh restart | Python: calls `set_img_dirs()` and shows pause — does NOT restart; image stays mounted |
| F9 | `resize_image` script | Uses `_do_mount` / `_do_umount` helper functions, mounts to temp dir (`/tmp/.sd_mnt_XXXXXX`), then remounts to original `mnt_dir` — robust two-step | Python: single-pass unmount/truncate/remount inline |
| F10 | `_netns_setup` | Writes `ns` to `${mnt}/.sd/.netns_name` and `idx` to `${mnt}/.sd/.netns_idx` after setup | Python: does not write these metadata files during setup |
| F11 | `_enc_menu` Auto-Unlock disable | Requires at least one passkey to exist before disabling (`[[ "$_has_passkeys" == false ]]` → `pause`) | Python: no passkey-exists guard before disabling auto-unlock |
| F12 | `_enc_menu` "Add Key" passphrase entry | Uses raw terminal `IFS= read -rs _np1; read -rs _np2` (masked input) with `clear` before/after | Python: uses `finput()` (fzf text input, not masked) — passphrase visible while typing |
| F13 | `_enc_menu` "Reset Auth Token" passphrase | Uses raw `IFS= read -rs _ra_pass` (masked) | Python: uses `finput()` — passphrase visible |
| F14 | `_enc_menu` "Add Key" PBKDF params (pbkdf2 branch) | Uses user-configured `_cipher`, `_keybits`, `_sector` even for pbkdf2 | Python: ignores cipher/keybits/sector for pbkdf2 branch |
| F15 | `_enc_is_verified` / "Verify this system" | Checks `_enc_is_verified` (slot exists AND is non-empty) and shows different message for "cached but Auto-Unlock disabled" vs "already verified with slot" | Python: similar logic but messages differ slightly |
| F16 | `_list_persistent_names` | Reads directly from script heredoc via `awk` on `$_SELF_PATH` — always up to date from source | Python: reads from seeded disk files (fixed by issue #16 overwrite, but mechanism differs) |
| F17 | `_bp_autodetect_dirs` | Prunes `.*`, `node_modules`, `__pycache__`, `.git`, `vendor` from search; uses `grep -E '/[^./]+\.container$'` to skip dotfiles | Python: `rglob('*.container')` with depth check — does not prune hidden dirs or vendor |
| F18 | `_container_submenu` `ct_log` | Shows `tail -100` of log file inside `pause()` (scrollable text) | Python: loads full file into `fzf_run` with `--tac` — different viewer |
| F19 | `_container_submenu` `ct_exposure` (running) | Cycles to next mode immediately on click (no submenu), shows brief pause | Python: opens `_exposure_toggle_menu()` submenu with explicit mode selection |
| F20 | `_open_in_submenu` Terminal | Detects bash path via inline bash (`[[ ! -e …/bin/bash ]]`) | Python: uses inline bash detect string — ✅ equivalent |
| F21 | `_mount_img` | Deletes `Logs/*.log` on mount (`rm -f "$MNT_DIR/Logs/"*.log`) | Python: does not clear log files on mount |
| F22 | `_create_img` / `_mount_img` | Does not run `_seed_persistent_blueprints` — persistent BPs extracted live from script body | Python: calls `_seed_persistent_blueprints()` on `set_img_dirs` |
| F23 | `_process_install_finish` / `_run_job` | Uses `_tmux_launch` which shows a wait loop with "Attach" option during install, auto-advances when done; separate `_installing_menu` in container_submenu that blocks with watcher | Python: `_fzf_with_watcher` in container_submenu + `_installing_wait_loop` for separate jobs — functionally similar but `_installing_menu` has slightly different items |
| F24 | `_guard_ubuntu_pkg` | If `sdUbuntuPkg` already running, shows menu: Attach / Kill before allowing another operation | Python: no guard — starts new operation over existing one |
| F25 | `main_menu` empty sel (ESC/no-match) | If `SD_QUIT` not set AND sel is empty → calls `_quit_all` directly (no confirm) | Python: calls `quit_menu()` (which has Detach + Stop all options) |
| F26 | `_validate_containers` | Python version exists and is called ✅ — but Python also calls `_seed_persistent_blueprints` which shell does not |

---

## ✅ LOW — CONFIRMED EQUIVALENT (no change needed)
- #25–29 from pyissues.md: `_bp_persistent_enabled` wiring, `ub_cache` thread vs subshell, `enc_slots_used` regex, `enc_verified_id` sha256 slice, `enc_authkey_slot_file` no-newline
- Signal handling (SIGUSR1/INT/TERM/HUP): equivalent via Python signal module
- `sweep_stale`, `require_sudo` keepalive, tmux session naming: equivalent
- Blueprint parsing (`bp_parse`): functionally equivalent for all supported fields
- Network namespace, iptables exposure: equivalent

---

## SUMMARY

**Visual:** 16 divergences (V1–V16)
**Functional:** 26 divergences (F1–F26)

Most impactful to fix for 1:1 parity:
- **F1** `bp_validate` missing 7 checks
- **F2–F5** `_env_exports` missing vars/PATH entries/generate:hex32/LD_LIBRARY_PATH appending
- **F8** `resize_image` should `exec` restart itself on success
- **F11–F13** Passphrase entry should use masked terminal input, not fzf
- **F19** `ct_exposure` when running should cycle directly (no submenu)
- **V1–V4** `main_menu` display format (column alignment, conditional colour)
- **V5–V7** `container_submenu` installed/running item order and visibility
- **V16** `_autodetect_mode` default should be `Home` not `Disabled`
- **V10** New blueprint should NOT open editor immediately