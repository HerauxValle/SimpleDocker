"""
image.py — BTRFS image lifecycle: mount, unmount, create, resize, yazi picker
"""

import os
import subprocess
import sys
import time

from .constants import SD_MNT_BASE, TMP_DIR, GRN, RED, YLW, BLD, DIM, NC
from .tui import pause, confirm, finput, FINPUT_RESULT, fzf
from .utils import (
    run, run_out, sudo_run, sudo_out, make_tmp,
    current_user, is_btrfs_available,
)

# ── Dirs derived from mount point ─────────────────────────────────────────

class ImageDirs:
    def __init__(self, mnt_dir: str):
        self.mnt_dir      = mnt_dir
        self.blueprints   = os.path.join(mnt_dir, "Blueprints")
        self.containers   = os.path.join(mnt_dir, "Containers")
        self.installations = os.path.join(mnt_dir, "Installations")
        self.backup       = os.path.join(mnt_dir, "Backup")
        self.storage      = os.path.join(mnt_dir, "Storage")
        self.ubuntu       = os.path.join(mnt_dir, "Ubuntu")
        self.groups       = os.path.join(mnt_dir, "Groups")
        self.logs         = os.path.join(mnt_dir, "Logs")
        self.cache        = os.path.join(mnt_dir, ".cache")

    def makedirs(self):
        me = current_user()
        for d in [
            self.blueprints, self.containers, self.installations,
            self.backup, self.storage, self.ubuntu, self.groups,
            self.logs,
            os.path.join(self.cache, "gh_tag"),
            os.path.join(self.cache, "sd_size"),
        ]:
            os.makedirs(d, exist_ok=True)
        sudo_run([
            "chown", f"{me}:{me}",
            self.blueprints, self.containers, self.installations,
            self.backup, self.storage, self.ubuntu, self.groups,
            self.logs, self.cache,
        ])


# ── LUKS helpers ─────────────────────────────────────────────────────────

def luks_mapper(img_path: str) -> str:
    import re
    name = os.path.basename(img_path)
    if name.endswith(".img"):
        name = name[:-4]
    name = re.sub(r"[^a-zA-Z0-9_]", "", name)
    return f"sd_{name}"


def luks_dev(img_path: str) -> str:
    return f"/dev/mapper/{luks_mapper(img_path)}"


def luks_is_open(img_path: str) -> bool:
    return os.path.exists(luks_dev(img_path))


def img_is_luks(img_path: str) -> bool:
    r = sudo_run(["cryptsetup", "isLuks", img_path])
    return r.returncode == 0


def luks_open(img_path: str, cipher: str, default_keyword: str, unlock_order: list) -> bool:
    """Try to open LUKS volume. Returns True on success."""
    mapper = luks_mapper(img_path)
    if luks_is_open(img_path):
        return True

    for method in unlock_order:
        if method == "verified_system":
            r = sudo_run(
                ["cryptsetup", "open", "--key-file=-", img_path, mapper],
                input=cipher.encode()
            )
            if r.returncode == 0:
                return True
        elif method == "default_keyword":
            r = sudo_run(
                ["cryptsetup", "open", "--key-file=-", img_path, mapper],
                input=default_keyword.encode()
            )
            if r.returncode == 0:
                return True
        elif method == "prompt":
            for attempt in range(3):
                import getpass
                os.system("clear")
                print(f"\n  {BLD}── simpleDocker ──{NC}")
                print(f"  {DIM}{os.path.basename(img_path)} is encrypted. Enter passphrase.{NC}\n")
                pw = getpass.getpass("  Passphrase: ")
                r = sudo_run(
                    ["cryptsetup", "open", "--key-file=-", img_path, mapper],
                    input=pw.encode()
                )
                if r.returncode == 0:
                    os.system("clear")
                    return True
                print(f"  {RED}Wrong passphrase.{NC}")
            os.system("clear")
            return False
    os.system("clear")
    return False


def luks_close(img_path: str):
    if luks_is_open(img_path):
        sudo_run(["cryptsetup", "close", luks_mapper(img_path)])


# ── Mount / unmount ───────────────────────────────────────────────────────

def do_mount(img_path: str, cipher: str, default_keyword: str, unlock_order: list) -> str:
    """
    Mount img_path as a BTRFS loop. Returns mount dir string on success, "" on failure.
    """
    import hashlib
    img_hash = hashlib.md5(img_path.encode()).hexdigest()[:8]
    mnt_dir = os.path.join(SD_MNT_BASE, f"mnt_{img_hash}")
    os.makedirs(mnt_dir, exist_ok=True)

    # Check if already mounted
    r = run(["mountpoint", "-q", mnt_dir])
    if r.returncode == 0:
        return mnt_dir

    dev = img_path
    if img_is_luks(img_path):
        if not luks_open(img_path, cipher, default_keyword, unlock_order):
            return ""
        dev = luks_dev(img_path)
    else:
        # Setup loop device
        lo = run_out(["sudo", "-n", "losetup", "--find", "--show", img_path]).strip()
        if not lo:
            return ""
        dev = lo

    r = sudo_run(["mount", "-o", "compress=zstd,autodefrag", dev, mnt_dir])
    if r.returncode != 0:
        return ""
    return mnt_dir


def do_umount(mnt_dir: str, img_path: str):
    """Unmount and close LUKS/loop."""
    if not mnt_dir:
        return

    # Unmount submounts first (deepest first)
    r = run(["findmnt", "-n", "-o", "TARGET", "-R", mnt_dir])
    if r.returncode == 0:
        targets = r.stdout.decode().splitlines()
        targets = [t for t in targets if t != mnt_dir]
        targets.sort(key=len, reverse=True)
        for t in targets:
            sudo_run(["umount", "-lf", t])

    sudo_run(["umount", "-lf", mnt_dir])

    # Detach loop device
    src = run_out(["findmnt", "-n", "-o", "SOURCE", mnt_dir])
    if src.startswith("/dev/loop"):
        sudo_run(["losetup", "-d", src])

    # Close LUKS
    if img_path:
        luks_close(img_path)

    try:
        os.rmdir(mnt_dir)
    except Exception:
        pass


# ── Image creation ────────────────────────────────────────────────────────

def create_img(path: str, size_gb: int, encrypt: bool, passphrase: str = "") -> bool:
    """Create a new BTRFS image file. Returns True on success."""
    import shutil

    # Allocate
    r = run(["fallocate", "-l", f"{size_gb}G", path])
    if r.returncode != 0:
        r = run(["dd", "if=/dev/zero", f"of={path}", "bs=1M",
                 f"count={size_gb * 1024}", "status=none"])
        if r.returncode != 0:
            return False

    if encrypt:
        if not passphrase:
            return False
        r = sudo_run(
            ["cryptsetup", "luksFormat", "--batch-mode", "--type", "luks2",
             "--key-slot", "0", "--key-file=-", path],
            input=passphrase.encode()
        )
        if r.returncode != 0:
            return False
        mapper = luks_mapper(path)
        r = sudo_run(
            ["cryptsetup", "open", "--key-file=-", path, mapper],
            input=passphrase.encode()
        )
        if r.returncode != 0:
            return False
        r = sudo_run(["mkfs.btrfs", "-f", f"/dev/mapper/{mapper}"])
        if r.returncode != 0:
            return False
        sudo_run(["cryptsetup", "close", mapper])
    else:
        r = sudo_run(["mkfs.btrfs", "-f", path])
        if r.returncode != 0:
            return False

    return True


def resize_image(img_path: str, mnt_dir: str, new_size_gb: int) -> bool:
    """Resize a mounted BTRFS image to new_size_gb. Returns True on success."""
    # Truncate file to new size
    r = run(["truncate", "-s", f"{new_size_gb}G", img_path])
    if r.returncode != 0:
        return False
    # Resize loop device
    lo = run_out(["findmnt", "-n", "-o", "SOURCE", mnt_dir])
    if lo.startswith("/dev/loop"):
        sudo_run(["losetup", "--set-capacity", lo])
    # Resize BTRFS filesystem
    r = sudo_run(["btrfs", "filesystem", "resize", "max", mnt_dir])
    return r.returncode == 0


# ── Yazi file picker ──────────────────────────────────────────────────────

def yazi_pick(pick_dir: bool = False) -> str:
    """Launch yazi chooser. Returns picked path or ""."""
    chooser = make_tmp(".sd_yazi_")
    try:
        r = run(["yazi", f"--chooser-file={chooser}"], capture=False)
        if not os.path.exists(chooser):
            return ""
        with open(chooser) as fp:
            picked = fp.readline().rstrip()
        return picked
    except Exception:
        return ""
    finally:
        try:
            os.unlink(chooser)
        except Exception:
            pass


def pick_img() -> str:
    return yazi_pick(pick_dir=False)


def pick_dir() -> str:
    return yazi_pick(pick_dir=True)


# ── Ubuntu base ───────────────────────────────────────────────────────────

def ubuntu_cache_check(ubuntu_dir: str, default_pkgs: str, sd_mnt_base: str, pid: int):
    """Background check for Ubuntu package drift and available updates."""
    import threading

    def _check():
        os.makedirs(os.path.join(sd_mnt_base, ".tmp"), exist_ok=True)
        drift_f = os.path.join(sd_mnt_base, ".tmp", f".sd_ub_drift_{pid}")
        upd_f   = os.path.join(sd_mnt_base, ".tmp", f".sd_ub_upd_{pid}")

        if not os.path.isfile(os.path.join(ubuntu_dir, ".ubuntu_ready")):
            return

        # Package drift
        saved = os.path.join(ubuntu_dir, ".ubuntu_default_pkgs")
        cur_sorted = sorted(default_pkgs.split())
        if os.path.isfile(saved):
            with open(saved) as fp:
                saved_sorted = sorted(fp.read().split())
            drift = cur_sorted != saved_sorted
        else:
            drift = True
        with open(drift_f, "w") as fp:
            fp.write("true" if drift else "false")

        # apt updates (only if cache is stale >24h)
        last_f = os.path.join(ubuntu_dir, ".sd_last_apt_update")
        import time
        now = int(time.time())
        last = 0
        if os.path.isfile(last_f):
            try:
                last = int(open(last_f).read().strip())
            except Exception:
                pass
        if now - last > 86400:
            r = subprocess.run(
                ["chroot", ubuntu_dir, "bash", "-c",
                 "apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null | grep -c '^Inst '"],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
            )
            count = int(r.stdout.decode().strip() or "0")
            with open(upd_f, "w") as fp:
                fp.write("true" if count > 0 else "false")
            with open(last_f, "w") as fp:
                fp.write(str(now))
        else:
            with open(upd_f, "w") as fp:
                fp.write("false")

    t = threading.Thread(target=_check, daemon=True)
    t.start()
    return t


def ubuntu_cache_read(sd_mnt_base: str, pid: int, loaded: list) -> tuple:
    """Wait for background cache and return (drift: bool, has_updates: bool)."""
    if loaded[0]:
        return loaded[1], loaded[2]
    drift_f = os.path.join(sd_mnt_base, ".tmp", f".sd_ub_drift_{pid}")
    upd_f   = os.path.join(sd_mnt_base, ".tmp", f".sd_ub_upd_{pid}")
    w = 0
    while not os.path.isfile(drift_f) and w < 30:
        import time; time.sleep(0.1); w += 1
    drift = False
    if os.path.isfile(drift_f):
        drift = open(drift_f).read().strip() == "true"
        os.unlink(drift_f)
    has_updates = False
    if os.path.isfile(upd_f):
        has_updates = open(upd_f).read().strip() == "true"
        os.unlink(upd_f)
    loaded[0] = True
    loaded[1] = drift
    loaded[2] = has_updates
    return drift, has_updates


def ensure_ubuntu(ubuntu_dir: str, default_pkgs: str) -> bool:
    """Ensure Ubuntu base chroot exists. Returns True if ready."""
    return os.path.isfile(os.path.join(ubuntu_dir, ".ubuntu_ready"))
