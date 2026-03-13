"""menu/backup_menu.py — Container backups and snapshots"""

import os
import time
from functions.constants import GRN, RED, YLW, BLD, DIM, NC, L
from functions.tui import menu, fzf, confirm, pause, finput
from functions.utils import trim_s, strip_ansi, read_json, write_json
from functions.container import (
    cname, cpath, snap_dir, rand_snap_id,
    snap_meta_get, snap_meta_set, delete_snap,
)
import functions.tui as _tui


def container_backups_menu(
    cid: str, containers_dir: str, installations_dir: str, backup_dir: str
):
    ct_name = cname(containers_dir, cid)
    bd = snap_dir(backup_dir, cid, ct_name)
    os.makedirs(bd, exist_ok=True)

    while True:
        snaps = sorted([
            d for d in os.listdir(bd)
            if os.path.isdir(os.path.join(bd, d))
        ], key=lambda s: snap_meta_get(os.path.join(bd, s), "created"), reverse=True)

        lines = []
        for s in snaps:
            sp = os.path.join(bd, s)
            label   = snap_meta_get(sp, "label") or "auto"
            created = snap_meta_get(sp, "created") or "?"
            ts = time.strftime("%Y-%m-%d", time.localtime(int(created))) if created.isdigit() else created
            lines.append(f"{DIM}◈{NC}  {s}  {DIM}[{label}]  {ts}{NC}")

        if not snaps:
            lines.append(f"{DIM}  (no snapshots){NC}")
        lines.append(f"{GRN} +  Create manual backup{NC}")

        rc, sel = fzf(lines, f"--header={BLD}── Backups: {ct_name} ──{NC}", "--no-multi")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel[0])
        if not chosen:
            return

        if "Create manual backup" in chosen:
            if not finput("Backup label (optional):"):
                continue
            label = _tui.FINPUT_RESULT.strip() or "manual"
            ip = cpath(containers_dir, installations_dir, cid)
            if not ip or not os.path.isdir(ip):
                pause("Container not installed.")
                continue
            import subprocess
            snap_id = rand_snap_id()
            snap_path = os.path.join(bd, snap_id)
            r = subprocess.run(
                ["sudo", "-n", "btrfs", "subvolume", "snapshot", "-r", ip, snap_path],
                stderr=subprocess.DEVNULL
            )
            if r.returncode == 0:
                snap_meta_set(snap_path, created=str(int(time.time())), label=label, source=ip)
                pause(f"Backup '{snap_id}' created.")
            else:
                pause("Backup failed (btrfs snapshot error).")
            continue

        # Selected a snapshot
        snap_id = None
        for s in snaps:
            if s in chosen:
                snap_id = s
                break
        if not snap_id:
            continue

        snap_path = os.path.join(bd, snap_id)
        rc2 = menu(f"Backup: {snap_id}", "Restore", "Delete")
        if rc2 != 0:
            continue
        choice = _tui.REPLY

        if "Restore" in choice:
            ip = cpath(containers_dir, installations_dir, cid)
            if not ip:
                pause("No install path.")
                continue
            if not confirm(f"Restore from backup '{snap_id}'?\n\n  Current installation will be replaced."):
                continue
            import subprocess, shutil
            r = subprocess.run(
                ["sudo", "-n", "btrfs", "subvolume", "delete", ip],
                stderr=subprocess.DEVNULL
            )
            if r.returncode != 0:
                shutil.rmtree(ip, ignore_errors=True)
            r2 = subprocess.run(
                ["sudo", "-n", "btrfs", "subvolume", "snapshot", snap_path, ip],
                stderr=subprocess.DEVNULL
            )
            if r2.returncode == 0:
                pause(f"Restored from '{snap_id}'.")
            else:
                pause("Restore failed.")

        elif "Delete" in choice:
            if confirm(f"Delete backup '{snap_id}'?"):
                delete_snap(snap_path)
                try:
                    os.unlink(snap_path + ".meta")
                except Exception:
                    pass
