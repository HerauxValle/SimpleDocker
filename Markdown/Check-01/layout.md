# simpleDocker — Divergence Scan Rules (layout.md)

> This file defines the exact rules an AI must follow to produce `divergences.md`.  
> Follow every rule precisely. Do not invent, assume, or hallucinate.

---

## Purpose

`divergences.md` documents every place where `services.py` behaves differently from `services.sh`. It is produced by reading both files in full, comparing them function by function, and recording only what is actually observed in the code — never what was previously documented, never what "should" be there.

---

## Rule 1 — Read both files completely before writing anything

Read `services.sh` and `services.py` in their entirety before producing any output. Do not rely on memory of prior sessions, prior patchlogs, or prior divergence reports. The files may have changed. The only source of truth is the current content of both files.

Use `sed -n 'N,Mp'` in chunks of ~500 lines to read the full Python file (5000+ lines). Read the shell file in full. If a tool call hits a limit, continue from where you left off.

---

## Rule 2 — Compare function by function, not feature by feature

For every logical function in `services.sh`, locate the corresponding function in `services.py` and compare them line by line. Proceed in the order the shell defines them:

1. Boot / tmux bootstrap (`_sd_outer_sudo`, outer loop, inner init)
2. Sweep / cleanup (`_sweep_stale`, `_force_quit`)
3. Image mount/unmount/create (`_mount_img`, `_unmount_img`, `_create_img`)
4. LUKS / encryption (`_luks_open`, `_enc_*`, `_enc_menu`)
5. Network namespace (`_netns_*`, `_exposure_*`)
6. Blueprint (`_bp_parse`, `_bp_validate`, `_bp_compile_to_json`, `_compile_service`)
7. Env exports (`_env_exports`, `_cr_prefix`)
8. Install script generation (`_run_job`, `_gen_install_script`, `_emit_runner_steps`)
9. Start script generation (`_build_start_script`)
10. Container lifecycle (`_start_container`, `_stop_container`)
11. Cron (`_cron_start_one`, `_cron_start_all`, `_cron_stop_all`)
12. Storage (`_stor_link`, `_stor_unlink`, `_auto_pick_storage_profile`, `_pick_storage_profile`, `_stor_create_profile`)
13. Backups (`_container_backups_menu`, `_rotate_and_snapshot`, `_do_restore_snap`, `_clone_from_snap`)
14. Groups (`_start_group`, `_stop_group`, `_group_submenu`, `_groups_menu`)
15. Persistent storage menu (`_persistent_storage_menu`)
16. Ubuntu base (`_ensure_ubuntu`, `_ubuntu_menu`, `_ubuntu_pkg_*`)
17. Proxy / Caddy (`_proxy_menu`, `_proxy_start`, `_proxy_write`, `_proxy_install_caddy`)
18. Resources (`_resources_menu`)
19. Active processes (`_active_processes_menu`)
20. Container submenu (`_container_submenu`)
21. Containers submenu (`_containers_submenu`)
22. Install method menu (`_install_method_menu`)
23. Blueprint menus (`_blueprints_submenu`, `_blueprints_settings_menu`, `_blueprint_submenu`)
24. Help menu (`_help_menu`)
25. Main menu (`main_menu`)
26. Resize (`_resize_image`)
27. Quit (`_quit_menu`, `_quit_all`)
28. Setup image (`_setup_image`)
29. Signal handling

---

## Rule 3 — Only record observable differences

A divergence must be something you can point to in the actual code of both files. Do not record:

- Things that "should" be different based on documentation
- Differences that only existed in old versions of the files
- Theoretical issues not traceable to specific lines
- Differences that are already fixed (verify by reading the code, not the patchlog)

If the Python code matches the shell, do not record it as a divergence — even if a prior document said it was one.

---

## Rule 4 — Format of divergences.md

The file must have exactly this structure:

```
# simpleDocker — Divergences (services.py vs services.sh)

> Generated: {date}  
> Source of truth: services.sh  
> Compared against: services.py

---

## Summary Table

| ID | Severity | Area | Shell function | Python function |
|---|---|---|---|---|
| DIV-001 | CRITICAL | ... | ... | ... |
...

---

## Detailed Entries

### DIV-001 — {short title}

**Severity:** CRITICAL | HIGH | MEDIUM | LOW  
**Shell:** `{function name}` (line ~N)  
**Python:** `{function name}` (line ~N)  

**Shell behaviour:**  
{exact description of what the shell does, with specific variable names, command names, flags}

**Python behaviour:**  
{exact description of what the Python does, with specific variable names, function names}

**Impact:**  
{what breaks or differs at runtime}

---
```

Every entry must have all six fields. Do not omit any.

---

## Rule 5 — Severity definitions

Use exactly these four levels:

| Level | Meaning |
|---|---|
| **CRITICAL** | Data loss, broken core feature, runtime crash, security issue |
| **HIGH** | Feature incomplete or silently wrong, user-visible malfunction |
| **MEDIUM** | Behavioural difference, wrong UX text, missing guard or fallback |
| **LOW** | Minor parity gap, cosmetic, performance difference, missing optimisation |

---

## Rule 6 — What counts as a divergence

Record a divergence when any of the following are true:

- A function or code block present in the shell is entirely absent in Python
- A function exists in Python but does something materially different
- An argument, flag, or parameter differs between the two (e.g. missing `--batch-mode`, different pbkdf args)
- A guard, safety check, or error path present in the shell is missing in Python
- A file is written, read, or deleted in the shell but not in Python (or vice versa)
- A tmux session is created or killed in the shell but not in Python
- A signal is sent in the shell but not in Python
- UI text (header, pause message, confirm text, finput prompt) differs materially
- A menu item, section separator, or menu option is present in shell but absent in Python (or vice versa)
- The order of operations differs in a way that affects correctness

Do **not** record as a divergence:

- Minor wording differences that do not change meaning or user experience
- Python-specific implementation details (threading vs subshell, Path vs string) that produce identical behaviour
- Differences in code style, variable naming, or organisation with identical effect
- Items already confirmed fixed by reading the current code (not by trusting prior docs)

---

## Rule 7 — ID numbering

IDs must be `DIV-NNN` with zero-padded three digits starting at `DIV-001`. Assign IDs in the order divergences are discovered (function by function, as per Rule 2). Do not reuse IDs from prior documents.

---

## Rule 8 — Shell line references

When citing shell code, use approximate line numbers. Use `grep -n` or `sed -n` to find the line numbers before writing. Do not invent line numbers.

---

## Rule 9 — Do not reference prior fix history

`divergences.md` describes the current state of the code only. Do not mention TODO numbers, patchlog rounds, or prior fix sessions. Each entry must be self-contained and understandable without reference to any other document.

---

## Rule 10 — Verify before asserting

Before recording that something is missing from Python, search for it:

```bash
grep -n "function_name\|keyword" /path/to/services.py
```

Only record it as missing if the search confirms absence. If it is present but different, record the difference — not absence.

---

## Checklist before finalising divergences.md

- [ ] Both files read in full (not just sampled)
- [ ] Every shell function has been checked against its Python equivalent
- [ ] Every entry is traceable to specific lines in both files
- [ ] No entry references prior patchlogs or TODO history
- [ ] All six fields filled in for every entry
- [ ] Summary table matches detailed entries (same IDs, same severities)
- [ ] No divergences recorded that are already fixed in the current code
- [ ] No divergences omitted because they were "previously fixed" without verifying current code