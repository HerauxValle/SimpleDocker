"""
utils.py — Utility helpers: sudo keepalive, ANSI stripping, logging, random IDs, etc.
"""

import hashlib
import json
import os
import random
import re
import signal
import string
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

from .constants import TMP_DIR, SD_MNT_BASE


# ── Shell / subprocess helpers ────────────────────────────────────────────

def run(cmd, *, check=False, capture=True, input=None, env=None, timeout=None):
    """Run a shell command (list or string). Returns CompletedProcess."""
    if isinstance(cmd, str):
        cmd = ["bash", "-c", cmd]
    kw = dict(check=check, env=env)
    if capture:
        kw["stdout"] = subprocess.PIPE
        kw["stderr"] = subprocess.PIPE
    if input is not None:
        kw["input"] = input.encode() if isinstance(input, str) else input
    if timeout is not None:
        kw["timeout"] = timeout
    return subprocess.run(cmd, **kw)


def run_out(cmd, *, default="", **kw) -> str:
    """Run cmd and return stdout as stripped string."""
    try:
        r = run(cmd, capture=True, **kw)
        return r.stdout.decode(errors="replace").strip()
    except Exception:
        return default


def sudo_run(cmd, *, capture=True, input=None, **kw):
    """Prepend sudo -n to cmd."""
    if isinstance(cmd, list):
        return run(["sudo", "-n"] + cmd, capture=capture, input=input, **kw)
    return run(f"sudo -n {cmd}", capture=capture, input=input, **kw)


def sudo_out(cmd, *, default="", **kw) -> str:
    try:
        r = sudo_run(cmd, capture=True, **kw)
        return r.stdout.decode(errors="replace").strip()
    except Exception:
        return default


# ── sudo keepalive ────────────────────────────────────────────────────────

_keepalive_thread = None
_keepalive_stop = threading.Event()


def sudo_keepalive():
    """Launch background thread that refreshes sudo every 55s."""
    global _keepalive_thread
    if _keepalive_thread and _keepalive_thread.is_alive():
        return

    def _loop():
        while not _keepalive_stop.wait(55):
            subprocess.run(["sudo", "-n", "true"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    _keepalive_thread = threading.Thread(target=_loop, daemon=True)
    _keepalive_thread.start()


def sudo_keepalive_stop():
    _keepalive_stop.set()


# ── ANSI helpers ─────────────────────────────────────────────────────────

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(s: str) -> str:
    return _ANSI_RE.sub("", s)


def trim_s(s: str) -> str:
    return strip_ansi(s).strip()


# ── tmux helpers ─────────────────────────────────────────────────────────

def tmux_get(key: str) -> str:
    return run_out(["tmux", "show-environment", "-g", key]).split("=", 1)[-1].split("=", 1)[-1]


def tmux_set(key: str, value: str):
    subprocess.run(["tmux", "set-environment", "-g", key, value],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def tmux_up(session: str) -> bool:
    r = subprocess.run(["tmux", "has-session", "-t", session],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


def tsess(cid: str) -> str:
    return f"sd_{cid}"


def inst_sess(cid: str) -> str:
    return f"sdInst_{cid}"


def cron_sess(cid: str, idx) -> str:
    return f"sdCron_{cid}_{idx}"


# ── state / JSON helpers ──────────────────────────────────────────────────

def state_get(containers_dir: str, cid: str, key: str, default=None):
    f = os.path.join(containers_dir, cid, "state.json")
    try:
        with open(f) as fp:
            return json.load(fp).get(key, default)
    except Exception:
        return default


def state_set(containers_dir: str, cid: str, key: str, value):
    f = os.path.join(containers_dir, cid, "state.json")
    try:
        with open(f) as fp:
            data = json.load(fp)
    except Exception:
        data = {}
    data[key] = value
    tmp = f + ".tmp"
    with open(tmp, "w") as fp:
        json.dump(data, fp, indent=2)
    os.replace(tmp, f)


def svc_get(containers_dir: str, cid: str, *keys, default=None):
    """Read nested key from service.json. keys is dotted path as args."""
    f = os.path.join(containers_dir, cid, "service.json")
    try:
        with open(f) as fp:
            d = json.load(fp)
        for k in keys:
            d = d[k]
        return d
    except Exception:
        return default


def read_json(path: str, default=None):
    try:
        with open(path) as fp:
            return json.load(fp)
    except Exception:
        return default if default is not None else {}


def write_json(path: str, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w") as fp:
        json.dump(data, fp, indent=2)
    os.replace(tmp, path)


# ── Logging ───────────────────────────────────────────────────────────────

_LOG_MAX = 10 * 1024 * 1024   # 10 MB
_LOG_KEEP = int(_LOG_MAX * 0.8)


def log_write(path: str, *lines):
    try:
        with open(path, "a") as fp:
            for l in lines:
                fp.write(l + "\n")
        sz = os.path.getsize(path)
        if sz > _LOG_MAX:
            with open(path, "rb") as fp:
                fp.seek(-_LOG_KEEP, 2)
                tail = fp.read()
            with open(path, "wb") as fp:
                fp.write(tail)
    except Exception:
        pass


def log_path(logs_dir: str, cid: str, cname: str, kind: str) -> str:
    return os.path.join(logs_dir, f"{cname}-{cid}-{kind}.log")


# ── Random ID ─────────────────────────────────────────────────────────────

def rand_id(containers_dir: str) -> str:
    chars = string.ascii_lowercase + string.digits
    while True:
        rid = "".join(random.choices(chars, k=8))
        if not os.path.isdir(os.path.join(containers_dir, rid)):
            return rid


# ── Guard: disk space ─────────────────────────────────────────────────────

def guard_space(mnt_dir: str) -> bool:
    """Return True if enough space available (> 100 MB)."""
    try:
        st = os.statvfs(mnt_dir)
        free_mb = (st.f_bavail * st.f_frsize) // (1024 * 1024)
        return free_mb > 100
    except Exception:
        return True


# ── Signal helpers ────────────────────────────────────────────────────────

def sig_rc(rc: int) -> bool:
    """Return True if rc indicates process was killed by signal."""
    return rc in (143, 138, 137)


# ── Machine-id / cipher ───────────────────────────────────────────────────

def machine_cipher() -> str:
    try:
        r = subprocess.run(["sha256sum", "/etc/machine-id"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return r.stdout.decode().split()[0][:32]
    except Exception:
        return "simpledocker_fallback"


def machine_id_short() -> str:
    try:
        r = subprocess.run(["sha256sum", "/etc/machine-id"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return r.stdout.decode().split()[0][:8]
    except Exception:
        return "unknown"


# ── Misc ──────────────────────────────────────────────────────────────────

def make_tmp(prefix=".sd_tmp_", suffix="", dir=None) -> str:
    d = dir or TMP_DIR
    os.makedirs(d, exist_ok=True)
    fd, path = tempfile.mkstemp(prefix=prefix, suffix=suffix, dir=d)
    os.close(fd)
    return path


def sha256_file(path: str) -> str:
    try:
        h = hashlib.sha256()
        with open(path, "rb") as fp:
            for chunk in iter(lambda: fp.read(65536), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""


def current_user() -> str:
    return run_out(["id", "-un"])


def hostname() -> str:
    try:
        with open("/etc/hostname") as fp:
            return fp.read().strip()
    except Exception:
        return "unknown"


def is_btrfs_available() -> bool:
    try:
        with open("/proc/filesystems") as fp:
            return "btrfs" in fp.read()
    except Exception:
        return False


def check_deps() -> list:
    """Return list of missing required tools."""
    import shutil
    return [t for t in ["tmux", "fzf", "btrfs", "sudo", "curl", "ip"]
            if shutil.which(t) is None]


def install_deps(missing: list):
    """Install missing deps using available package manager."""
    pm = None
    for cmd, pkg_cmd in [
        ("pacman",  "pacman -S --noconfirm"),
        ("apt-get", "apt-get install -y"),
        ("dnf",     "dnf install -y"),
        ("zypper",  "zypper install -y"),
    ]:
        if subprocess.run(["which", cmd], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0:
            pm = pkg_cmd
            break
    if not pm:
        print("No known package manager found")
        sys.exit(1)
    for t in missing:
        pkg = t
        if t == "btrfs": pkg = "btrfs-progs"
        if t == "ip":    pkg = "iproute2"
        subprocess.run(f"sudo {pm} {pkg}", shell=True)
