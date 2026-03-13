"""AppContext — carries all runtime directory paths and startup logic."""
from __future__ import annotations
import os
import sys
import time
import signal
import subprocess
import threading
from pathlib import Path

from functions.constants import ROOT_DIR, SD_MNT_BASE, TMP_DIR


# ── AppContext ────────────────────────────────────────────────────────────────

class AppContext:
    """Single object passed through all menu functions carrying directory state."""

    def __init__(self, img_path: str, mnt_dir: str):
        self.img_path = img_path
        self.mnt_dir  = mnt_dir

        # All dirs live inside the mounted BTRFS image
        self.blueprints_dir    = os.path.join(mnt_dir, "Blueprints")
        self.containers_dir    = os.path.join(mnt_dir, "Containers")
        self.installations_dir = os.path.join(mnt_dir, "Installations")
        self.backup_dir        = os.path.join(mnt_dir, "Backup")
        self.storage_dir       = os.path.join(mnt_dir, "Storage")
        self.ubuntu_dir        = os.path.join(mnt_dir, "Ubuntu")
        self.groups_dir        = os.path.join(mnt_dir, "Groups")
        self.logs_dir          = os.path.join(mnt_dir, "Logs")
        self.cache_dir         = os.path.join(mnt_dir, ".cache")
        self.tmp_dir           = TMP_DIR

        # ubuntu cache state — [loaded, ready, pkg_drift]
        self._ub_cache: list = [False, False, False]
        self._ub_pkgs:  list = []

    # ── directory setup ───────────────────────────────────────────────────────

    def makedirs(self) -> None:
        """Create all expected directories inside the mounted image."""
        for d in (
            self.blueprints_dir,
            self.containers_dir,
            self.installations_dir,
            self.backup_dir,
            self.storage_dir,
            self.ubuntu_dir,
            self.groups_dir,
            self.logs_dir,
            self.cache_dir,
        ):
            os.makedirs(d, exist_ok=True)

    def set_img_dirs(self) -> None:
        """Re-compute all dirs after img_path changes (e.g. after delete+recreate)."""
        self.blueprints_dir    = os.path.join(self.mnt_dir, "Blueprints")
        self.containers_dir    = os.path.join(self.mnt_dir, "Containers")
        self.installations_dir = os.path.join(self.mnt_dir, "Installations")
        self.backup_dir        = os.path.join(self.mnt_dir, "Backup")
        self.storage_dir       = os.path.join(self.mnt_dir, "Storage")
        self.ubuntu_dir        = os.path.join(self.mnt_dir, "Ubuntu")
        self.groups_dir        = os.path.join(self.mnt_dir, "Groups")
        self.logs_dir          = os.path.join(self.mnt_dir, "Logs")
        self.cache_dir         = os.path.join(self.mnt_dir, ".cache")

    # ── ubuntu cache ──────────────────────────────────────────────────────────

    def ub_cache_start(self) -> None:
        """Start background ubuntu-cache check (sets _ub_cache flags)."""
        ready_flag = os.path.join(self.ubuntu_dir, ".ubuntu_ready")
        if not os.path.isfile(ready_flag):
            return

        def _check():
            saved_file = os.path.join(self.ubuntu_dir, ".ubuntu_default_pkgs")
            try:
                # read installed packages via dpkg-query inside ubuntu chroot
                r = subprocess.run(
                    ["sudo", "-n", "chroot", self.ubuntu_dir,
                     "dpkg-query", "-f", "${Package}\\n", "-W"],
                    capture_output=True, text=True
                )
                pkgs = [p.strip() for p in r.stdout.splitlines() if p.strip()]
                self._ub_pkgs = pkgs
                self._ub_cache[1] = True  # ready

                if os.path.isfile(saved_file):
                    saved = set(Path(saved_file).read_text().splitlines())
                    current = set(pkgs)
                    self._ub_cache[2] = saved != current  # pkg drift
            except Exception:
                pass
            finally:
                self._ub_cache[0] = True  # loaded

        threading.Thread(target=_check, daemon=True).start()


# ── image selection / config ─────────────────────────────────────────────────

def _config_file() -> str:
    return os.path.join(ROOT_DIR, "config.json")


def _read_config() -> dict:
    import json
    f = _config_file()
    if os.path.isfile(f):
        try:
            return json.loads(Path(f).read_text())
        except Exception:
            pass
    return {}


def _write_config(d: dict) -> None:
    import json
    os.makedirs(ROOT_DIR, exist_ok=True)
    Path(_config_file()).write_text(json.dumps(d, indent=2))


def _list_images() -> list[str]:
    """Return list of .img files known to config + any found in ROOT_DIR."""
    cfg = _read_config()
    known: list[str] = cfg.get("images", [])
    # also scan ROOT_DIR
    for f in Path(ROOT_DIR).glob("*.img"):
        fp = str(f)
        if fp not in known:
            known.append(fp)
    return [f for f in known if os.path.isfile(f)]


def _mnt_dir_for(img_path: str) -> str:
    base = os.path.basename(img_path)
    stem = base[:-4] if base.endswith(".img") else base
    return os.path.join(SD_MNT_BASE, f"mnt_{stem}")


# ── stale lock cleanup ────────────────────────────────────────────────────────

def sweep_stale_locks(ctx: AppContext) -> None:
    """Remove stale .installing lock files whose tmux session no longer exists."""
    ct_dir = ctx.containers_dir
    if not os.path.isdir(ct_dir):
        return
    for lock in Path(ct_dir).glob("*/.installing"):
        cid = lock.parent.name
        sess = f"sdInst_{cid}"
        r = subprocess.run(
            ["tmux", "has-session", "-t", sess],
            capture_output=True
        )
        if r.returncode != 0:
            try:
                lock.unlink()
            except OSError:
                pass


# ── sudoers keepalive ─────────────────────────────────────────────────────────

def sudo_setup() -> bool:
    """Prompt for sudo password once and set up NOPASSWD sudoers if possible."""
    # First try if sudo -n already works
    r = subprocess.run(["sudo", "-n", "true"], capture_output=True)
    if r.returncode == 0:
        return True
    # Prompt once
    print("\n  simpleDocker needs sudo for BTRFS, LUKS and network operations.")
    r2 = subprocess.run(["sudo", "true"])
    return r2.returncode == 0


# ── proxy autostart ───────────────────────────────────────────────────────────

def _proxy_autostart(ctx: AppContext) -> None:
    """Start Caddy proxy in background if autostart is configured."""
    cfg_f = Path(ctx.mnt_dir) / ".sd" / "proxy.json"
    if not cfg_f.is_file():
        return
    try:
        import json
        cfg = json.loads(cfg_f.read_text())
        if not cfg.get("autostart"):
            return
    except Exception:
        return

    caddy_bin = str(Path(ctx.mnt_dir) / ".sd" / "caddy" / "caddy")
    if not os.path.isfile(caddy_bin):
        return

    def _start():
        from menu.proxy_menu import proxy_start, _get_containers
        try:
            containers = _get_containers(ctx)
            proxy_start(ctx, containers, background=True)
        except Exception:
            pass

    threading.Thread(target=_start, daemon=True).start()


# ── main setup / teardown ─────────────────────────────────────────────────────

def setup(img_path: str) -> AppContext:
    """Mount image (if needed), build AppContext, run startup tasks."""
    from functions.image import do_mount, luks_is_open, luks_open, img_is_luks
    from functions.utils import guard_space, sudo_keepalive

    mnt_dir = _mnt_dir_for(img_path)
    os.makedirs(mnt_dir, exist_ok=True)
    os.makedirs(TMP_DIR, exist_ok=True)

    # Mount if not already mounted
    if not _is_mounted(mnt_dir):
        encrypted = img_is_luks(img_path)
        if encrypted and not luks_is_open(img_path):
            if not luks_open(img_path, mnt_dir):
                print(f"\n  \033[0;31mFailed to open LUKS image.\033[0m\n")
                sys.exit(1)
        do_mount(img_path, mnt_dir)

    ctx = AppContext(img_path, mnt_dir)
    ctx.makedirs()

    # Persist image in config
    cfg = _read_config()
    imgs = cfg.get("images", [])
    if img_path not in imgs:
        imgs.append(img_path)
        cfg["images"] = imgs
        _write_config(cfg)

    # Background tasks
    sudo_keepalive()
    sweep_stale_locks(ctx)
    ctx.ub_cache_start()
    _proxy_autostart(ctx)

    return ctx


def teardown(ctx: AppContext) -> None:
    """Stop proxy, stop containers if needed (best-effort)."""
    # Stop caddy if running
    try:
        from menu.proxy_menu import proxy_stop, _proxy_running
        if _proxy_running(ctx):
            proxy_stop(ctx)
    except Exception:
        pass


def _is_mounted(mnt_dir: str) -> bool:
    r = subprocess.run(["mountpoint", "-q", mnt_dir], capture_output=True)
    return r.returncode == 0


# ── image creator interactive flow ───────────────────────────────────────────

def _create_image_interactive() -> str:
    """
    Full interactive image creation flow matching the original services.sh.
    Prompts for name, size, directory, then creates LUKS+BTRFS image.
    Returns the new img_path, or empty string on cancel.
    """
    import re, shlex, subprocess, tempfile, shutil
    from pathlib import Path
    from functions.tui import finput, pause, fzf
    import functions.tui as _tui
    from functions.constants import GRN, RED, DIM, NC, BLD, CYN
    from functions.image import (
        luks_mapper, luks_open, luks_close,
        do_mount,
    )
    from functions.utils import sudo_run
    from functions.constants import SD_VERIFICATION_CIPHER, SD_DEFAULT_KEYWORD

    # ── name ──
    if not finput(
        f"Image name (e.g. simpleDocker):\n\n"
        f"  {RED}⚠  WARNING:{NC}  The name cannot be changed after creation."
    ):
        return ""
    name = re.sub(r"[^a-zA-Z0-9_\-]", "", (_tui.FINPUT_RESULT or "").strip())
    if not name:
        pause("No name given.")
        return ""

    # ── size ──
    if not finput("Max size in GB (sparse — only uses actual disk space, leave blank for 50 GB):"):
        return ""
    size_str = (_tui.FINPUT_RESULT or "").strip() or "50"
    if not size_str.isdigit() or int(size_str) < 1:
        pause("Invalid size.")
        return ""
    size_gb = int(size_str)

    # ── directory picker ──
    from functions.image import pick_dir
    chosen_dir = pick_dir()
    if not chosen_dir:
        pause("No directory selected.")
        return ""

    imgfile = os.path.join(chosen_dir, f"{name}.img")
    if os.path.exists(imgfile):
        pause(f"Already exists: {imgfile}")
        return ""

    # ── allocate sparse file ──
    r = subprocess.run(["truncate", "-s", f"{size_gb}G", imgfile], capture_output=True)
    if r.returncode != 0:
        pause("Failed to allocate image file.")
        return ""

    # ── LUKS format with SD_VERIFICATION_CIPHER ──
    r = subprocess.run(
        ["sudo", "-n", "cryptsetup", "luksFormat",
         "--type", "luks2", "--batch-mode",
         "--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000",
         "--hash", "sha1", "--key-slot", "31", "--key-file=-", imgfile],
        input=SD_VERIFICATION_CIPHER.encode(), capture_output=True
    )
    if r.returncode != 0:
        os.unlink(imgfile)
        pause("luksFormat failed.")
        return ""

    # ── LUKS open ──
    mapper = luks_mapper(imgfile)
    r = subprocess.run(
        ["sudo", "-n", "cryptsetup", "open", "--key-file=-", imgfile, mapper],
        input=SD_VERIFICATION_CIPHER.encode(), capture_output=True
    )
    if r.returncode != 0:
        os.unlink(imgfile)
        pause("LUKS open failed.")
        return ""

    # ── mkfs.btrfs ──
    r = subprocess.run(
        ["sudo", "-n", "mkfs.btrfs", "-q", "-f", f"/dev/mapper/{mapper}"],
        capture_output=True
    )
    if r.returncode != 0:
        subprocess.run(["sudo", "-n", "cryptsetup", "close", mapper], capture_output=True)
        os.unlink(imgfile)
        pause("mkfs.btrfs failed.")
        return ""

    # ── mount ──
    mnt_dir = _mnt_dir_for(imgfile)
    os.makedirs(mnt_dir, exist_ok=True)
    r = subprocess.run(
        ["sudo", "-n", "mount", "-o", "compress=zstd", f"/dev/mapper/{mapper}", mnt_dir],
        capture_output=True
    )
    if r.returncode != 0:
        subprocess.run(["sudo", "-n", "cryptsetup", "close", mapper], capture_output=True)
        os.unlink(imgfile)
        try: os.rmdir(mnt_dir)
        except: pass
        pause("Mount failed.")
        return ""

    subprocess.run(
        ["sudo", "-n", "chown", f"{os.getuid()}:{os.getgid()}", mnt_dir],
        capture_output=True
    )
    os.makedirs(os.path.join(mnt_dir, ".tmp"), exist_ok=True)
    os.makedirs(os.path.join(mnt_dir, ".sd"), exist_ok=True)

    # ── auth keyfile — 64 random bytes, added as LUKS key ──
    authkey_path = os.path.join(mnt_dir, ".sd", "authkey")
    import secrets as _sec
    authkey_bytes = _sec.token_bytes(64)
    Path(authkey_path).write_bytes(authkey_bytes)
    os.chmod(authkey_path, 0o600)
    tf_boot = tempfile.NamedTemporaryFile(delete=False)
    tf_boot.write(SD_VERIFICATION_CIPHER.encode()); tf_boot.close()
    subprocess.run(
        ["sudo", "-n", "cryptsetup", "luksAddKey", "--batch-mode",
         "--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000",
         "--hash", "sha1", "--key-slot", "0",
         "--key-file", tf_boot.name, imgfile, authkey_path],
        capture_output=True
    )
    try: os.unlink(tf_boot.name)
    except: pass

    # Kill bootstrap slot 31, add default-keyword slot 1
    if os.path.isfile(authkey_path):
        subprocess.run(
            ["sudo", "-n", "cryptsetup", "luksKillSlot", "--batch-mode",
             "--key-file", authkey_path, imgfile, "31"],
            capture_output=True
        )
        tf2 = tempfile.NamedTemporaryFile(delete=False)
        tf2.write(SD_DEFAULT_KEYWORD.encode()); tf2.close()
        subprocess.run(
            ["sudo", "-n", "cryptsetup", "luksAddKey", "--batch-mode",
             "--pbkdf", "pbkdf2", "--pbkdf-force-iterations", "1000",
             "--hash", "sha1", "--key-slot", "1",
             "--key-file", authkey_path, imgfile, tf2.name],
            capture_output=True
        )
        try: os.unlink(tf2.name)
        except: pass

    # ── btrfs subvolumes ──
    for sv in ["Blueprints", "Containers", "Installations",
               "Backup", "Storage", "Ubuntu", "Groups", "Logs"]:
        subprocess.run(
            ["sudo", "-n", "btrfs", "subvolume", "create",
             os.path.join(mnt_dir, sv)],
            capture_output=True
        )

    # ── netns setup ──
    try:
        from functions.network import netns_setup
        netns_setup(mnt_dir)
    except Exception:
        pass

    # ── persist in config ──
    cfg = _read_config()
    imgs = cfg.get("images", [])
    if imgfile not in imgs:
        imgs.append(imgfile)
        cfg["images"] = imgs
        _write_config(cfg)

    pause(f"Image created: {imgfile}")
    return imgfile


# ── image picker (first run or multi-image) ───────────────────────────────────

def pick_or_create_image() -> str:
    """
    Interactive image picker / creator matching original _setup_image().
    Returns the chosen img_path, exits on cancel.
    """
    import glob, subprocess
    from functions.tui import fzf
    from functions.image import img_is_luks
    from functions.constants import GRN, CYN, DIM, NC, BLD

    while True:
        images = _list_images()

        # Auto-mount single known image
        if len(images) == 1:
            return images[0]

        # Scan $HOME for .img files (BTRFS or LUKS)
        detected = []
        for f in glob.glob(os.path.expanduser("~/**/*.img"), recursive=False):
            if f in images:
                continue
            try:
                r = subprocess.run(["file", f], capture_output=True, text=True)
                if "BTRFS" in r.stdout or img_is_luks(f):
                    detected.append(f)
            except Exception:
                pass
        # Also shallow scan
        for f in glob.glob(os.path.expanduser("~/*.img")):
            if f not in detected and f not in images:
                detected.append(f)

        lines = [
            f" {CYN}◈{NC}  Select existing image",
            f" {CYN}◈{NC}  Create new image",
        ]
        if images:
            lines.append(f"{DIM}  ── Known images ─────────────────────{NC}")
            for p in images:
                lines.append(f" {CYN}◈{NC}  {os.path.basename(p)}  {DIM}({os.path.dirname(p)}){NC}")
        if detected:
            lines.append(f"{DIM}  ── Detected images ──────────────────{NC}")
            for p in detected:
                lines.append(f" {CYN}◈{NC}  {os.path.basename(p)}  {DIM}({os.path.dirname(p)}){NC}")

        rc, sel = fzf(lines, "--header", f"{BLD}── simpleDocker ──{NC}", "--no-multi")
        if rc != 0 or not sel:
            import sys; sys.exit(0)

        sc = sel[0].strip()
        from functions.utils import strip_ansi
        sc = strip_ansi(sc).strip()

        if "Create new image" in sc:
            result = _create_image_interactive()
            if result:
                return result
            continue

        if "Select existing image" in sc:
            from functions.image import pick_img
            picked = pick_img()
            if picked:
                return picked
            continue

        # Clicked a detected or known image
        all_imgs = images + detected
        for p in all_imgs:
            if os.path.basename(p) in sc:
                return p
