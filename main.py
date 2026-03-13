"""simpleDocker — entry point."""
from __future__ import annotations
import os
import sys
import signal
import subprocess
import argparse
import shlex
import traceback


_SUDOERS_CMDS = (
    "/bin/mount", "/bin/umount", "/usr/bin/mount", "/usr/bin/umount",
    "/usr/bin/btrfs", "/usr/sbin/btrfs", "/bin/btrfs", "/sbin/btrfs",
    "/usr/bin/mkfs.btrfs", "/sbin/mkfs.btrfs",
    "/usr/bin/chown", "/bin/chown",
    "/bin/mkdir", "/usr/bin/mkdir",
    "/usr/bin/rm", "/bin/rm",
    "/usr/bin/chmod", "/bin/chmod",
    "/usr/bin/tee", "/usr/bin/nsenter", "/usr/sbin/nsenter",
    "/usr/bin/unshare",
    "/usr/bin/chroot", "/usr/sbin/chroot",
    "/bin/bash", "/usr/bin/bash",
    "/usr/bin/ip", "/bin/ip", "/sbin/ip", "/usr/sbin/ip",
    "/usr/sbin/iptables", "/usr/bin/iptables", "/sbin/iptables",
    "/usr/sbin/sysctl", "/usr/bin/sysctl",
    "/bin/cp", "/usr/bin/cp",
    "/usr/bin/apt-get", "/usr/bin/apt",
    "/usr/sbin/cryptsetup", "/usr/bin/cryptsetup", "/sbin/cryptsetup",
    "/sbin/losetup", "/usr/sbin/losetup", "/bin/losetup",
    "/sbin/blockdev", "/usr/sbin/blockdev",
    "/usr/bin/dmsetup", "/usr/sbin/dmsetup",
    "/usr/bin/rsync",
)


def _outer_sudo() -> None:
    me = subprocess.run(["id", "-un"], capture_output=True, text=True).stdout.strip()
    sudoers_path = f"/etc/sudoers.d/simpledocker_{me}"
    subprocess.run(["sudo", "-k"], capture_output=True)
    print("\n  \033[1m── simpleDocker ──\033[0m")
    print("  \033[2msimpleDocker requires sudo access.\033[0m\n")
    while subprocess.run(["sudo", "-v"]).returncode != 0:
        print("  \033[0;31mIncorrect password.\033[0m  Try again.\n")
    rule = f"{me} ALL=(ALL) NOPASSWD: {', '.join(_SUDOERS_CMDS)}\n"
    subprocess.run(["sudo", "mkdir", "-p", "/etc/sudoers.d"], capture_output=True)
    subprocess.run(["sudo", "tee", sudoers_path],
                   input=rule.encode(), capture_output=True)


def _outer_launch(self_path: str, extra_args: list) -> None:
    sess = "simpleDocker"
    # Kill stale session that isn't marked ready
    r = subprocess.run(["tmux", "has-session", "-t", sess], capture_output=True)
    if r.returncode == 0:
        ready = subprocess.run(
            ["tmux", "show-environment", "-t", sess, "SD_READY"],
            capture_output=True, text=True).stdout.strip()
        if ready != "SD_READY=1":
            subprocess.run(["tmux", "kill-session", "-t", sess], capture_output=True)

    # Create detached session if not already running
    if subprocess.run(["tmux", "has-session", "-t", sess], capture_output=True).returncode != 0:
        inner_cmd = " ".join(
            [shlex.quote(sys.executable), shlex.quote(self_path), "--inner"]
            + [shlex.quote(a) for a in extra_args]
        )
        subprocess.run(["tmux", "new-session", "-d", "-s", sess, inner_cmd])
        subprocess.run(["tmux", "set-option", "-t", sess, "status", "off"],
                       capture_output=True)

    # Attach loop — re-attaches on detach, exits when session ends or SD_DETACH=1
    while subprocess.run(["tmux", "has-session", "-t", sess],
                         capture_output=True).returncode == 0:
        subprocess.run(["tmux", "attach-session", "-t", sess])
        subprocess.run(["stty", "sane"], capture_output=True)
        os.system("clear")
        r2 = subprocess.run(["tmux", "show-environment", "-g", "SD_DETACH"],
                             capture_output=True, text=True)
        if r2.stdout.strip() == "SD_DETACH=1":
            subprocess.run(["tmux", "set-environment", "-g", "SD_DETACH", "0"],
                           capture_output=True)
            os.system("clear")
            break

    os.system("clear")
    sys.exit(0)


def _check_system() -> None:
    import shutil
    required = ["tmux", "fzf", "btrfs"]
    missing = [t for t in required if shutil.which(t) is None]
    if missing:
        print(f"\n  \033[0;31mMissing: {', '.join(missing)}\033[0m")
        print(f"  sudo pacman -S --needed {' '.join(missing)}\n")
        input("  Press Enter to exit...")
        sys.exit(1)


def _setup_signals() -> None:
    import functions.tui as _tui
    def _usr1(sig, frame):
        _tui._USR1_FIRED = True
        if _tui._FZF_PID:
            try:
                os.kill(_tui._FZF_PID, signal.SIGTERM)
            except ProcessLookupError:
                pass
    signal.signal(signal.SIGUSR1, _usr1)


def _inner_main(img_arg) -> None:
    subprocess.run(["tmux", "set-environment", "SD_READY", "1"], capture_output=True)
    _setup_signals()
    _check_system()

    from cli.app import setup, teardown, pick_or_create_image

    if img_arg:
        img_path = os.path.abspath(img_arg)
        if not os.path.isfile(img_path):
            print(f"\n  Image not found: {img_path}\n")
            input("  Press Enter to exit...")
            sys.exit(1)
    else:
        img_path = pick_or_create_image()

    ctx = setup(img_path)

    try:
        from functions.container import validate_containers
        validate_containers(ctx.containers_dir, ctx.installations_dir)
    except Exception:
        pass

    try:
        from functions.container import update_size_cache
        import threading
        threading.Thread(target=update_size_cache,
                         args=(ctx.containers_dir,), daemon=True).start()
    except Exception:
        pass

    try:
        from menu.main_menu import main_menu
        main_menu(ctx)
    except KeyboardInterrupt:
        pass
    except Exception:
        # Show crash inside tmux so user can read it
        traceback.print_exc()
        input("\n  [crashed — press Enter to exit]")
    finally:
        teardown(ctx)


def main() -> None:
    p = argparse.ArgumentParser(prog="simpledocker")
    p.add_argument("image", nargs="?")
    p.add_argument("--inner", action="store_true", help=argparse.SUPPRESS)
    p.add_argument("--version", action="version", version="simpleDocker 1.0")
    args = p.parse_args()

    if args.inner or os.environ.get("TMUX"):
        _inner_main(args.image)
    else:
        try:
            _outer_sudo()
        except Exception as e:
            print(f"\n  sudo setup failed: {e}\n")
            sys.exit(1)
        self_path = os.path.abspath(__file__)
        extra = [args.image] if args.image else []
        _outer_launch(self_path, extra)


if __name__ == "__main__":
    main()
# This line intentionally left blank — file complete
