"""
tui.py — Terminal UI wrappers around fzf: _fzf, confirm, pause, finput, _menu
"""

import os
import signal
import subprocess
import sys
import tempfile
import threading

from .constants import FZF_BASE, GRN, RED, DIM, BLD, NC, L, TMP_DIR, KB
from .utils import make_tmp, trim_s, sig_rc, strip_ansi

# Global: PID of currently blocking fzf process (for SIGUSR1 interrupt)
_active_fzf_pid = None
_active_fzf_pid_lock = threading.Lock()

_USR1_FIRED = False


def _set_active_fzf(pid):
    global _active_fzf_pid
    with _active_fzf_pid_lock:
        _active_fzf_pid = pid
    # Write to file so the shell-side watcher can also kill it
    try:
        pid_file = os.path.join(TMP_DIR, ".sd_active_fzf_pid")
        with open(pid_file, "w") as fp:
            fp.write(str(pid))
    except Exception:
        pass


def fzf(items: list[str], *extra_args, multi=False) -> tuple[int, list[str]]:
    """
    Run fzf with given items and extra args.
    Returns (returncode, [selected lines]).
    rc=0: selection made; rc=1: empty; rc=2: USR1-interrupted; rc=130: ESC/Ctrl-C
    """
    global _USR1_FIRED
    out_file = make_tmp(".sd_fzf_out_")
    try:
        args = ["fzf"] + FZF_BASE + list(extra_args)
        if multi:
            args.append("--multi")
        proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=open(out_file, "wb"),
            stderr=None,
        )
        _set_active_fzf(proc.pid)
        input_bytes = "\n".join(items).encode()
        proc.stdin.write(input_bytes)
        proc.stdin.close()
        rc = proc.wait()

        if sig_rc(rc):
            if _USR1_FIRED:
                _USR1_FIRED = False
                return 2, []
            try:
                import subprocess as sp
                sp.run(["stty", "sane"], stderr=sp.DEVNULL)
            except Exception:
                pass
            # drain stdin
            return 2, []

        with open(out_file) as fp:
            lines = [l.rstrip("\n") for l in fp.readlines() if l.strip()]
        return rc, lines
    finally:
        try:
            os.unlink(out_file)
        except Exception:
            pass


def confirm(prompt: str) -> bool:
    """Yes/No fzf picker. Returns True if user picks Yes."""
    yes_item = f"{GRN}{L['yes']}{NC}"
    no_item  = f"{RED}{L['no']}{NC}"
    header = f"{BLD}{prompt}{NC}"
    rc, sel = fzf([yes_item, no_item], f"--header={header}", "--no-multi")
    if rc != 0 or not sel:
        return False
    return L["yes"].lower() in trim_s(sel[0]).lower()


def pause(message: str = "Done."):
    """Show a message and wait for Enter/ESC."""
    item = f"{GRN}[ OK ]  {NC}{DIM}{message}{NC}"
    header = f"{DIM}{L['ok_press']}{NC}"
    fzf([item], f"--header={header}", "--no-multi")


FINPUT_RESULT = ""


def finput(prompt: str) -> bool:
    """
    Prompt user for freeform text via fzf --print-query.
    On success: sets global FINPUT_RESULT and returns True.
    On ESC: returns False.
    """
    global FINPUT_RESULT
    FINPUT_RESULT = ""
    out_file = make_tmp(".sd_finput_")
    try:
        header = f"{BLD}{prompt}{NC}\n{DIM}  {L['type_enter']}{NC}"
        args = ["fzf"] + FZF_BASE + ["--print-query", f"--header={header}", "--no-multi"]
        proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=open(out_file, "wb"),
            stderr=None,
        )
        _set_active_fzf(proc.pid)
        proc.stdin.close()
        rc = proc.wait()
        if rc in (0, 1):
            with open(out_file) as fp:
                lines = fp.readlines()
            FINPUT_RESULT = lines[0].rstrip("\n") if lines else ""
            return True
        return False
    finally:
        try:
            os.unlink(out_file)
        except Exception:
            pass


# Global for menu selection result (matches bash $REPLY)
REPLY = ""


def menu(header: str, *items: str) -> int:
    """
    Show a navigable fzf menu with a Back option.
    Sets global REPLY to the trimmed selection.
    Returns: 0=selected, 1=back/ESC, 2=USR1-interrupted
    """
    global REPLY, _USR1_FIRED
    SEP_NAV = f"{BLD}  ── Navigation ───────────────────────{NC}"
    back_item = f"{DIM} {L['back']}{NC}"
    all_items = []
    for x in items:
        if "\033" in x:
            all_items.append(x)
        else:
            all_items.append(f"{DIM} {x}{NC}")
    all_items.append(SEP_NAV)
    all_items.append(back_item)

    fzf_header = f"{BLD}── {header} ──{NC}"

    while True:
        # Drain stdin
        try:
            import termios, tty
            import select
            while select.select([sys.stdin], [], [], 0)[0]:
                sys.stdin.read(1)
        except Exception:
            pass

        rc, sel = fzf(all_items, f"--header={fzf_header}", "--no-multi")

        if rc == 2 or sig_rc(rc):
            try:
                import subprocess as sp
                sp.run(["stty", "sane"], stderr=sp.DEVNULL)
            except Exception:
                pass
            if _USR1_FIRED:
                _USR1_FIRED = False
                return 2
            continue

        if rc != 0 or not sel:
            REPLY = ""
            return 1

        chosen = trim_s(sel[0])
        if not chosen or chosen == L["back"]:
            REPLY = ""
            return 1

        REPLY = chosen
        return 0


def sep(label: str = "") -> str:
    """Return a bold separator string for use in menus."""
    if label:
        return f"{BLD}  ── {label} ──────────────────────────{NC}"
    return f"{BLD}  ──────────────────────────────────────{NC}"
