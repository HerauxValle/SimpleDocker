"""
menu/storage_menu.py — Persistent storage management
Matches services.sh _persistent_storage_menu 1:1.
"""

import os
import re
import subprocess
import time

from functions.constants import GRN, RED, YLW, BLU, BLD, DIM, NC, L, FZF_BASE, TMP_DIR
from functions.tui import confirm, pause, finput
from functions.utils import (
    trim_s, strip_ansi, tmux_up, tsess, make_tmp, read_json, write_json,
)
from functions.storage import (
    stor_path, stor_meta_path, stor_meta_set, stor_read_field,
    stor_read_name, stor_read_type, stor_read_active,
    stor_count, stor_create_profile, stor_unlink, stor_link,
)
import functions.tui as _tui


def _fzf_raw(items, *extra_args):
    out_f = make_tmp(".sd_stor_fzf_")
    try:
        proc = subprocess.Popen(
            ["fzf"] + list(FZF_BASE) + list(extra_args),
            stdin=subprocess.PIPE,
            stdout=open(out_f, "wb"),
        )
        proc.stdin.write("\n".join(items).encode())
        proc.stdin.close()
        rc = proc.wait()
        try:
            sel = open(out_f).read().strip()
        except Exception:
            sel = ""
        return rc, sel
    finally:
        try:
            os.unlink(out_f)
        except Exception:
            pass


def persistent_storage_menu(cid_ctx, ctx):
    """
    cid_ctx: container ID if opened from container submenu, else None.
    ctx: AppContext
    """
    storage_dir = ctx.storage_dir
    while True:
        if not os.path.isdir(storage_dir):
            pause("No storage directory found.")
            return

        entries  = []
        scids    = []
        all_cids = []
        if os.path.isdir(ctx.containers_dir):
            all_cids = [d for d in os.listdir(ctx.containers_dir)
                        if os.path.isfile(os.path.join(ctx.containers_dir, d, "state.json"))]

        for sdir_entry in sorted(os.listdir(storage_dir)):
            sdir = os.path.join(storage_dir, sdir_entry)
            if not os.path.isdir(sdir):
                continue
            scid = sdir_entry

            # Size
            r = subprocess.run(["du", "-sh", sdir], capture_output=True, text=True)
            ssize = r.stdout.split("\t")[0].strip() if r.returncode == 0 else "?"

            pname      = stor_read_name(storage_dir, scid) or "(unnamed)"
            stype      = stor_read_type(storage_dir, scid) or ""
            active_cid = stor_read_active(storage_dir, scid) or ""

            # Find which container has this as default
            def_for = ""
            for c in all_cids:
                stj = os.path.join(ctx.containers_dir, c, "state.json")
                data = read_json(stj) or {}
                if data.get("default_storage_id") == scid:
                    def_for = read_json(os.path.join(ctx.containers_dir, c, "state.json"),).get("name", c) or c
                    break

            base_info = f"{BLD}{pname}{NC}  {DIM}[{scid}]{NC}"
            if stype:
                base_info += f"  {DIM}({stype}){NC}"

            # Check if active container is still running
            if active_cid and tmux_up(tsess(active_cid)):
                dot   = f"{GRN}★{NC}" if def_for else f"{GRN}●{NC}"
                cname = _cname_from_ctx(ctx, active_cid)
                label = f"{dot}  {base_info}  {DIM}{ssize}  — running in {cname}{NC}"
            elif active_cid:
                # stale — clear it
                stor_meta_set(storage_dir, scid, active_container="")
                dot   = f"{YLW}★{NC}" if def_for else f"{YLW}○{NC}"
                label = f"{dot}  {base_info}  {DIM}{ssize}  [stale]{NC}"
            else:
                dot   = f"{DIM}★{NC}" if def_for else f"{DIM}○{NC}"
                label = f"{dot}  {base_info}  {DIM}{ssize}{NC}"

            entries.append(label)
            scids.append(scid)

        # Backup/export/import section
        SEP_BACKUP = f"{BLD}  ── Backup data ──────────────────────{NC}"
        entries.append(SEP_BACKUP)
        scids.append("")

        export_running = tmux_up("sdStorExport")
        import_running = tmux_up("sdStorImport")

        if export_running:
            entries.append(f"{YLW}↑{NC}{DIM}  Export running — click to manage{NC}")
            scids.append("__export_running__")
        else:
            entries.append(f"{DIM}↑  Export{NC}")
            scids.append("__export__")

        if import_running:
            entries.append(f"{YLW}↓{NC}{DIM}  Import running — click to manage{NC}")
            scids.append("__import_running__")
        else:
            entries.append(f"{DIM}↓  Import{NC}")
            scids.append("__import__")

        # New profile
        SEP_NEW = f"{BLD}  ── New ──────────────────────────────{NC}"
        entries.append(SEP_NEW)
        scids.append("")
        entries.append(f"{GRN} +  New storage profile{NC}")
        scids.append("__new__")

        # Nav
        entries.append(f"{BLD}  ── Navigation ───────────────────────{NC}")
        scids.append("")
        entries.append(f"{DIM} {L['back']}{NC}")
        scids.append("__back__")

        # Build numbered list for index-based selection
        numbered = [f"{i:04d}\t{e}" for i, e in enumerate(entries)]

        if cid_ctx:
            cname_ctx = _cname_from_ctx(ctx, cid_ctx)
            hdr = (f"{BLD}── Profiles: {cname_ctx} ──{NC}\n"
                   f"{DIM}  {GRN}●{NC}{DIM} running  {YLW}○{NC}{DIM} stale  ○ free  {YLW}★{NC}{DIM} default{NC}")
        else:
            hdr = (f"{BLD}── Persistent storage ──{NC}\n"
                   f"{DIM}  {GRN}●{NC}{DIM} running  {YLW}○{NC}{DIM} stale  ○ free  {YLW}★{NC}{DIM} default{NC}")

        rc, sel = _fzf_raw(
            numbered,
            f"--header={hdr}",
            "--delimiter=\t", "--with-nth=2..",
        )
        if rc != 0 or not sel:
            return

        # Extract index
        raw_idx = sel.split("\t")[0].strip() if "\t" in sel else ""
        if not raw_idx.isdigit():
            continue
        idx = int(raw_idx)
        if idx >= len(scids):
            continue
        sel_scid = scids[idx]

        if not sel_scid:
            continue
        if sel_scid == "__back__":
            return
        if sel_scid == "__new__":
            _create_storage_profile(ctx, cid_ctx)
            continue
        if sel_scid == "__export__":
            _stor_export_menu(ctx)
            continue
        if sel_scid == "__import__":
            _stor_import_menu(ctx)
            continue
        if sel_scid == "__export_running__":
            _running_session_menu("sdStorExport", "export")
            continue
        if sel_scid == "__import_running__":
            _running_session_menu("sdStorImport", "import")
            continue

        # Profile selected
        _storage_profile_submenu(sel_scid, ctx, cid_ctx)


def _cname_from_ctx(ctx, cid):
    stj = os.path.join(ctx.containers_dir, cid, "state.json")
    data = read_json(stj) or {}
    return data.get("name") or cid


def _create_storage_profile(ctx, cid_ctx):
    if not finput("Profile type (storage_type, e.g. 'myapp-data'):"):
        return
    stype = _tui.FINPUT_RESULT.strip()
    if not finput("Profile name (e.g. Default):"):
        return
    pname = _tui.FINPUT_RESULT.strip() or "Default"
    stor_create_profile(ctx.containers_dir, cid_ctx or "", stype, pname, ctx.mnt_dir)
    pause(f"Profile '{pname}' created.")


def _storage_profile_submenu(scid, ctx, cid_ctx):
    storage_dir = ctx.storage_dir
    pname = stor_read_name(storage_dir, scid) or scid

    lines = [
        f"{DIM}✎  Rename{NC}",
        f"{DIM}◧  Link to container{NC}",
        f"{DIM}◧  Unlink from container{NC}",
        f"{RED}×  Delete{NC}",
        f"{BLD}  ── Navigation ───────────────────────{NC}",
        f"{DIM} {L['back']}{NC}",
    ]
    rc, sel = _fzf_raw(lines, f"--header={BLD}── Profile: {pname} ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = strip_ansi(trim_s(sel)).strip()

    if "Rename" in chosen:
        if not finput(f"New name for '{pname}':"):
            return
        stor_meta_set(storage_dir, scid, name=_tui.FINPUT_RESULT.strip())

    elif "Link to container" in chosen:
        ids, names, _ = _load_ct(ctx)
        if not names:
            pause("No containers.")
            return
        rc2, sel2 = _fzf_raw(names, f"--header={BLD}── Link to ──{NC}")
        if rc2 != 0 or not sel2:
            return
        target_cid = _ct_id_by_name(ctx, strip_ansi(trim_s(sel2)), ids, names)
        if target_cid:
            stor_link(ctx.containers_dir, target_cid, scid, ctx.mnt_dir)
            pause(f"Profile linked to container.")

    elif "Unlink from container" in chosen:
        ids, names, _ = _load_ct(ctx)
        rc2, sel2 = _fzf_raw(names, f"--header={BLD}── Unlink from ──{NC}")
        if rc2 != 0 or not sel2:
            return
        target_cid = _ct_id_by_name(ctx, strip_ansi(trim_s(sel2)), ids, names)
        if target_cid:
            stor_unlink(ctx.containers_dir, target_cid, scid)
            pause("Profile unlinked.")

    elif "Delete" in chosen:
        if confirm(f"Delete storage profile '{pname}'?\n\n  All data inside will be lost."):
            import shutil
            shutil.rmtree(stor_path(storage_dir, scid), ignore_errors=True)
            pause(f"Profile '{pname}' deleted.")


def _load_ct(ctx):
    from functions.container import load_containers
    return load_containers(ctx.containers_dir)


def _ct_id_by_name(ctx, name, ids, names):
    for cid, n in zip(ids, names):
        if n == name:
            return cid
    return ""


def _running_session_menu(sess_name, label):
    lines = [
        f"→  Attach to {label}",
        f"{RED}×  Kill {label}{NC}",
        f"{DIM} {L['back']}{NC}",
    ]
    from menu.main_menu import _fzf_raw
    rc, sel = _fzf_raw(lines, f"--header={BLD}── {label.title()} running ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = strip_ansi(trim_s(sel)).strip()
    if "Attach" in chosen:
        subprocess.run(["tmux", "attach-session", "-t", sess_name],
                       stderr=subprocess.DEVNULL)
    elif "Kill" in chosen:
        if confirm(f"Kill the running {label}?"):
            subprocess.run(["tmux", "kill-session", "-t", sess_name],
                           stderr=subprocess.DEVNULL)
            pause(f"{label.title()} killed.")


def _stor_export_menu(ctx):
    storage_dir = ctx.storage_dir
    entries = [d for d in os.listdir(storage_dir)
               if os.path.isdir(os.path.join(storage_dir, d))]
    if not entries:
        pause("No storage profiles to export.")
        return

    lines = []
    for scid in sorted(entries):
        pname = stor_read_name(storage_dir, scid) or scid
        lines.append(f"{DIM}◈{NC}  {pname}  {DIM}[{scid}]{NC}")

    from menu.main_menu import _fzf_raw
    rc, sel = _fzf_raw(lines, f"--header={BLD}── Export: select profile ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = trim_s(sel)
    m = re.search(r'\[([a-z0-9]{8,})\]', chosen)
    if not m:
        return
    scid = m.group(1)
    sdir = stor_path(storage_dir, scid)

    if not finput("Export destination path (e.g. /mnt/usb/backup.tar.zst):"):
        return
    dest = _tui.FINPUT_RESULT.strip()
    if not dest:
        return

    script = make_tmp(".sd_stor_export_", ".sh")
    with open(script, "w") as fp:
        fp.write(f"#!/usr/bin/env bash\n"
                 f"echo 'Exporting {scid} to {dest}...'\n"
                 f"btrfs send '{sdir}' | zstd -T0 -o '{dest}' 2>&1 && echo '✓ Export done.' || echo '✗ Export failed.'\n"
                 f"rm -f '{script}'\n"
                 f"read -p 'Press Enter to close...'\n")
    os.chmod(script, 0o755)
    subprocess.run(["tmux", "new-session", "-d", "-s", "sdStorExport",
                    f"bash '{script}'"], stderr=subprocess.DEVNULL)
    pause(f"Export started in background session 'sdStorExport'.")


def _stor_import_menu(ctx):
    if not finput("Import source path (e.g. /mnt/usb/backup.tar.zst):"):
        return
    src = _tui.FINPUT_RESULT.strip()
    if not src or not os.path.isfile(src):
        pause("File not found.")
        return

    import secrets
    scid = secrets.token_hex(4)
    sdir = os.path.join(ctx.storage_dir, scid)
    os.makedirs(sdir, exist_ok=True)

    script = make_tmp(".sd_stor_import_", ".sh")
    with open(script, "w") as fp:
        fp.write(f"#!/usr/bin/env bash\n"
                 f"echo 'Importing {src} to {scid}...'\n"
                 f"zstd -d '{src}' --stdout 2>/dev/null | btrfs receive '{ctx.storage_dir}' 2>&1 && echo '✓ Import done.' || echo '✗ Import failed.'\n"
                 f"rm -f '{script}'\n"
                 f"read -p 'Press Enter to close...'\n")
    os.chmod(script, 0o755)
    subprocess.run(["tmux", "new-session", "-d", "-s", "sdStorImport",
                    f"bash '{script}'"], stderr=subprocess.DEVNULL)
    pause(f"Import started in background session 'sdStorImport'.")
