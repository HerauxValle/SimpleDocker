"""menu/logs_menu.py — Log file browser. Matches bash _logs_browser 1:1."""
import os, subprocess
from functions.constants import FZF_BASE, L, BLD, DIM, NC
from functions.tui import pause
from functions.utils import trim_s, strip_ansi, make_tmp


def _fzf_raw(items, *extra_args):
    out_f = make_tmp(".sd_logs_fzf_")
    try:
        proc = subprocess.Popen(["fzf"] + list(FZF_BASE) + list(extra_args),
                                stdin=subprocess.PIPE, stdout=open(out_f, "wb"))
        proc.stdin.write("\n".join(items).encode())
        proc.stdin.close()
        rc = proc.wait()
        try: sel = open(out_f).read().strip()
        except: sel = ""
        return rc, sel
    finally:
        try: os.unlink(out_f)
        except: pass


def logs_browser(ctx):
    while True:
        logs_dir = ctx.logs_dir
        if not logs_dir or not os.path.isdir(logs_dir):
            pause("No Logs folder found.")
            return

        r = subprocess.run(["find", logs_dir, "-type", "f", "-name", "*.log"],
                           capture_output=True, text=True)
        files = sorted(r.stdout.splitlines(), reverse=True)
        if not files:
            pause("No log files yet.")
            return

        items = [f"{DIM}{f[len(logs_dir):].lstrip('/')}{NC}" for f in files]
        items.append(f"{DIM}{L['back']}{NC}")

        rc, sel = _fzf_raw(items, f"--header={BLD}── Logs ──{NC}")
        if rc != 0 or not sel:
            return
        clean = strip_ansi(trim_s(sel)).strip()
        if clean == L["back"] or not clean:
            return

        path = os.path.join(logs_dir, clean)
        if not os.path.isfile(path):
            continue

        try:
            with open(path, errors="replace") as fp:
                content_lines = fp.read().splitlines()
        except OSError:
            continue

        _fzf_raw(
            content_lines,
            f"--header={BLD}── {clean}  {DIM}(read only){NC} ──{NC}",
            "--no-multi", "--disabled",
        )
