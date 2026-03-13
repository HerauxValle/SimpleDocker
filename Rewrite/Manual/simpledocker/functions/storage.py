"""
storage.py — Persistent storage profiles: create, link, unlink, pick, menu
"""

import os
import random
import re
import shutil
import string
import time

from .constants import GRN, RED, YLW, BLD, DIM, NC
from .utils import (
    read_json, write_json, rand_id, tmux_up, tsess,
    run_out, sudo_run, make_tmp,
)
from .tui import fzf, confirm, pause, finput, FINPUT_RESULT, sep, menu, REPLY


# ── Storage path helpers ──────────────────────────────────────────────────

def stor_path(storage_dir: str, scid: str) -> str:
    return os.path.join(storage_dir, scid)


def stor_meta_path(storage_dir: str, scid: str) -> str:
    return os.path.join(stor_path(storage_dir, scid), ".sd_meta.json")


def stor_meta_set(storage_dir: str, scid: str, **kv):
    mp = stor_meta_path(storage_dir, scid)
    os.makedirs(os.path.dirname(mp), exist_ok=True)
    data = read_json(mp) or {}
    data.update(kv)
    write_json(mp, data)


def stor_read_field(storage_dir: str, scid: str, key: str, default="") -> str:
    data = read_json(stor_meta_path(storage_dir, scid)) or {}
    return str(data.get(key, default))


def stor_read_name(storage_dir: str, scid: str)   -> str: return stor_read_field(storage_dir, scid, "name")
def stor_read_type(storage_dir: str, scid: str)   -> str: return stor_read_field(storage_dir, scid, "storage_type")
def stor_read_active(storage_dir: str, scid: str) -> str: return stor_read_field(storage_dir, scid, "active_container")
def stor_set_active(storage_dir: str, scid: str, cid: str):  stor_meta_set(storage_dir, scid, active_container=cid)
def stor_clear_active(containers_dir: str, mnt_dir: str, scid: str):
    # We need storage_dir from mnt_dir
    storage_dir = os.path.join(mnt_dir, "Storage")
    stor_meta_set(storage_dir, scid, active_container="")


def stor_type_from_sj(containers_dir: str, cid: str) -> str:
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj) or {}
    return data.get("meta", {}).get("storage_type", "")


def stor_count(containers_dir: str, cid: str) -> int:
    st = stor_type_from_sj(containers_dir, cid)
    if not st:
        return 0
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj) or {}
    return len(data.get("storage", []))


def stor_paths(containers_dir: str, cid: str) -> list:
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj) or {}
    return data.get("storage", [])


def stor_unlink(containers_dir: str, cid: str, install_path: str):
    for rel in stor_paths(containers_dir, cid):
        if not rel:
            continue
        link_path = os.path.join(install_path, rel)
        if os.path.islink(link_path):
            os.unlink(link_path)
            os.makedirs(link_path, exist_ok=True)


def stor_link(containers_dir: str, cid: str, install_path: str, scid: str, mnt_dir: str):
    storage_dir = os.path.join(mnt_dir, "Storage")
    sdir = stor_path(storage_dir, scid)
    os.makedirs(sdir, exist_ok=True)

    active_paths = set(stor_paths(containers_dir, cid))
    state_data = read_json(os.path.join(containers_dir, cid, "state.json")) or {}
    prev_paths = state_data.get("storage_paths", [])

    # Migrate paths no longer active -> copy back and delete real dir
    for prev in prev_paths:
        if not prev or prev in active_paths:
            continue
        real_path = os.path.join(sdir, prev)
        link_path = os.path.join(install_path, prev)
        if not os.path.isdir(real_path):
            continue
        if os.path.islink(link_path):
            os.unlink(link_path)
        os.makedirs(link_path, exist_ok=True)
        contents = os.listdir(real_path)
        if contents:
            for item in contents:
                src = os.path.join(real_path, item)
                dst = os.path.join(link_path, item)
                try:
                    shutil.copytree(src, dst) if os.path.isdir(src) else shutil.copy2(src, dst)
                except Exception:
                    pass
        shutil.rmtree(real_path, ignore_errors=True)

    # Link active paths
    for rel in active_paths:
        if not rel:
            continue
        real_path = os.path.join(sdir, rel)
        link_path = os.path.join(install_path, rel)
        os.makedirs(real_path, exist_ok=True)
        os.makedirs(os.path.dirname(link_path), exist_ok=True)

        if os.path.islink(link_path):
            os.unlink(link_path)

        if os.path.isdir(link_path):
            # Move existing contents to real_path
            for item in os.listdir(link_path):
                src = os.path.join(link_path, item)
                dst = os.path.join(real_path, item)
                try:
                    shutil.move(src, dst)
                except Exception:
                    pass
            shutil.rmtree(link_path, ignore_errors=True)

        os.symlink(real_path, link_path)

    # Update state
    state_data["storage_paths"] = list(active_paths)
    state_data["storage_id"] = scid
    write_json(os.path.join(containers_dir, cid, "state.json"), state_data)
    stor_set_active(storage_dir, scid, cid)


# ── Auto-pick and create ──────────────────────────────────────────────────

def _rand_scid(storage_dir: str) -> str:
    chars = string.ascii_lowercase + string.digits
    while True:
        scid = "".join(random.choices(chars, k=8))
        if not os.path.isdir(stor_path(storage_dir, scid)):
            return scid


def stor_create_profile_silent(containers_dir: str, cid: str, stype: str, mnt_dir: str) -> str:
    storage_dir = os.path.join(mnt_dir, "Storage")
    scid = _rand_scid(storage_dir)
    os.makedirs(stor_path(storage_dir, scid), exist_ok=True)
    stor_meta_set(storage_dir, scid,
                  storage_type=stype,
                  name="Default",
                  created=time.strftime("%Y-%m-%d"),
                  active_container="")
    state_data = read_json(os.path.join(containers_dir, cid, "state.json")) or {}
    state_data["default_storage_id"] = scid
    write_json(os.path.join(containers_dir, cid, "state.json"), state_data)
    return scid


def auto_pick_storage_profile(cid: str, containers_dir: str, mnt_dir: str) -> str:
    storage_dir = os.path.join(mnt_dir, "Storage")
    stype = stor_type_from_sj(containers_dir, cid)
    if stor_count(containers_dir, cid) == 0:
        return ""
    if not os.path.isdir(storage_dir):
        return stor_create_profile_silent(containers_dir, cid, stype, mnt_dir)

    state_data = read_json(os.path.join(containers_dir, cid, "state.json")) or {}
    def _try_scid(scid: str) -> bool:
        if not scid or not os.path.isdir(stor_path(storage_dir, scid)):
            return False
        ac = stor_read_active(storage_dir, scid)
        if not ac or ac == cid:
            return True
        if not tmux_up(tsess(ac)):
            stor_meta_set(storage_dir, scid, active_container="")
            return True
        return False

    for key in ("default_storage_id", "storage_id"):
        scid = state_data.get(key, "")
        if scid and _try_scid(scid):
            return scid

    for entry in sorted(os.listdir(storage_dir)):
        if not os.path.isdir(os.path.join(storage_dir, entry)):
            continue
        if stor_read_type(storage_dir, entry) != stype:
            continue
        if _try_scid(entry):
            return entry

    return stor_create_profile_silent(containers_dir, cid, stype, mnt_dir)


def stor_create_profile(containers_dir: str, cid: str, stype: str, pname: str, mnt_dir: str) -> str:
    storage_dir = os.path.join(mnt_dir, "Storage")
    pname = re.sub(r'[^a-zA-Z0-9_ -]', '', pname) or "Default"

    # Check for duplicate name
    for entry in os.listdir(storage_dir) if os.path.isdir(storage_dir) else []:
        if (stor_read_type(storage_dir, entry) == stype and
                stor_read_name(storage_dir, entry) == pname):
            pause(f"A profile named '{pname}' already exists for this type.")
            return ""

    scid = _rand_scid(storage_dir)
    os.makedirs(stor_path(storage_dir, scid), exist_ok=True)
    stor_meta_set(storage_dir, scid,
                  storage_type=stype,
                  name=pname,
                  created=time.strftime("%Y-%m-%d"),
                  active_container="")
    return scid


def pick_storage_profile(cid: str, containers_dir: str, mnt_dir: str) -> str:
    storage_dir = os.path.join(mnt_dir, "Storage")
    stype = stor_type_from_sj(containers_dir, cid)
    if stor_count(containers_dir, cid) == 0:
        return ""

    if not os.path.isdir(storage_dir):
        if not finput("New storage profile name:\n  (leave blank for Default)"):
            return ""
        import functions.tui as _tui
        pname = _tui.FINPUT_RESULT or "Default"
        return stor_create_profile(containers_dir, cid, stype, pname, mnt_dir)

    options = []
    scid_map = []
    for entry in sorted(os.listdir(storage_dir)):
        if not os.path.isdir(os.path.join(storage_dir, entry)):
            continue
        if stor_read_type(storage_dir, entry) != stype:
            continue
        pname = stor_read_name(storage_dir, entry) or "(unnamed)"
        try:
            sz = run_out(["du", "-sh", stor_path(storage_dir, entry)]).split()[0]
        except Exception:
            sz = "?"
        ac = stor_read_active(storage_dir, entry)
        if ac and ac != cid and tmux_up(tsess(ac)):
            from .container import cname as ct_cname
            options.append(f"{DIM}○  {pname}  [{entry}]  {sz}  — in use by {ct_cname(containers_dir, ac)}{NC}")
            scid_map.append("__inuse__")
            continue
        elif ac and ac != cid:
            stor_meta_set(storage_dir, entry, active_container="")
        options.append(f"●  {pname}  [{entry}]  {sz}")
        scid_map.append(entry)

    options.append(f"{GRN}+  New profile…{NC}")
    scid_map.append("__new__")

    rc, sel = fzf(options, f"--header={BLD}── Storage profile ──{NC}", "--no-multi")
    if rc != 0 or not sel:
        return ""
    chosen = sel[0].strip()
    for i, opt in enumerate(options):
        if opt.strip() == chosen:
            mapped = scid_map[i]
            if mapped == "__inuse__":
                pause("That profile is in use by another running container.")
                return ""
            if mapped == "__new__":
                if not finput("New storage profile name:\n  (leave blank for Default)"):
                    return ""
                import functions.tui as _tui
                pname = _tui.FINPUT_RESULT or "Default"
                return stor_create_profile(containers_dir, cid, stype, pname, mnt_dir)
            return mapped
    return ""
