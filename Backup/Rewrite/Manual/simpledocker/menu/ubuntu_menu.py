"""menu/ubuntu_menu.py — Ubuntu base package management. Matches bash _ubuntu_menu 1:1."""
import os, re, subprocess, time
from functions.constants import GRN, RED, YLW, CYN, BLD, DIM, NC, L, FZF_BASE, TMP_DIR
from functions.tui import confirm, pause, finput
from functions.utils import trim_s, strip_ansi, tmux_up, make_tmp
import functions.tui as _tui


def _fzf_raw(items, *extra_args):
    out_f = make_tmp(".sd_ub_fzf_")
    try:
        proc = subprocess.Popen(["fzf"] + list(FZF_BASE) + list(extra_args),
                                stdin=subprocess.PIPE, stdout=open(out_f, "wb"))
        proc.stdin.write("\n".join(items).encode())
        proc.stdin.close()
        rc = proc.wait()
        sel = ""
        try: sel = open(out_f).read().strip()
        except: pass
        return rc, sel
    finally:
        try: os.unlink(out_f)
        except: pass


def ubuntu_menu(ctx):
    while True:
        ub_ok   = os.path.join(ctx.ubuntu_dir, ".ubuntu_ok_flag")
        ub_fail = os.path.join(ctx.ubuntu_dir, ".ubuntu_fail_flag")

        # If setup/pkg session running, wait for it
        for sess in ("sdUbuntuSetup", "sdUbuntuPkg"):
            if tmux_up(sess):
                pause(f"Ubuntu operation in progress. Attach to session '{sess}' to monitor.")
                return

        if not os.path.isfile(os.path.join(ctx.ubuntu_dir, ".ubuntu_ready")):
            if not confirm("Ubuntu base not installed. Download and install now?"):
                return
            _ensure_ubuntu(ctx)
            continue

        # Get version and size
        ub_ver = ""
        try:
            r = subprocess.run(["chroot", ctx.ubuntu_dir, "grep", "PRETTY_NAME", "/etc/os-release"],
                               capture_output=True, text=True)
            for line in r.stdout.splitlines():
                if "PRETTY_NAME" in line:
                    ub_ver = line.split("=", 1)[-1].strip().strip('"')
        except: pass

        ub_size = ""
        try:
            r = subprocess.run(["du", "-sh", ctx.ubuntu_dir], capture_output=True, text=True)
            ub_size = r.stdout.split("\t")[0].strip() if r.returncode == 0 else "?"
        except: pass

        # Get package list partitioned into default/system/extra
        default_pkgs = set(os.environ.get("SD_DEFAULT_UBUNTU_PKGS", "").split() or
                           "curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential".split())

        def_lines, sys_lines, pkg_lines = [], [], []
        def_keys,  sys_keys,  pkg_keys  = [], [], []

        try:
            r = subprocess.run(
                ["chroot", ctx.ubuntu_dir, "dpkg-query", "-W",
                 "-f=${Package}\t${Version}\t${Priority}\t${Status}\n"],
                capture_output=True, text=True
            )
            for line in sorted(r.stdout.splitlines()):
                parts = line.split("\t")
                if len(parts) < 4 or "installed" not in parts[3]:
                    continue
                pkg, ver, priority = parts[0], parts[1], parts[2]
                display = f" {CYN}◈{NC}  {pkg:<28} {DIM}{ver}{NC}"
                key = f"{pkg}|{ver}"
                if pkg in default_pkgs:
                    def_lines.append(display); def_keys.append(key)
                elif priority in ("required", "important", "standard"):
                    sys_lines.append(display); sys_keys.append(key)
                else:
                    pkg_lines.append(display); pkg_keys.append(key)
        except: pass

        # Check for updates (cached)
        upd_tag = ""
        try:
            r = subprocess.run(
                ["chroot", ctx.ubuntu_dir, "apt-get", "--simulate", "-qq", "upgrade"],
                capture_output=True, text=True, timeout=5
            )
            if r.stdout.strip():
                upd_tag = f"  {YLW}[updates available]{NC}"
        except: pass

        lines = []
        lines.append(f"{BLD} ── Actions ─────────────────────────────{NC}")
        lines.append(f" {CYN}◈{NC}  Updates{upd_tag}")
        lines.append(f" {CYN}◈{NC}  Uninstall Ubuntu base")
        lines.append(f"{BLD} ── Default packages ────────────────────{NC}")
        lines.extend(def_lines) or lines.append(f" {DIM}(none installed yet){NC}")
        if not def_lines: lines.append(f" {DIM}(none installed yet){NC}")
        lines.append(f"{BLD} ── System packages ─────────────────────{NC}")
        lines.extend(sys_lines) if sys_lines else lines.append(f" {DIM}(none){NC}")
        lines.append(f"{BLD} ── Packages ────────────────────────────{NC}")
        lines.extend(pkg_lines) if pkg_lines else lines.append(f" {DIM}(no extra packages){NC}")
        lines.append(f" {GRN}+{NC}  Add package")
        lines.append(f"{BLD} ── Navigation ──────────────────────────{NC}")
        lines.append(f"{DIM} {L['back']}{NC}")

        hdr = (f"{BLD}── Ubuntu base ──{NC}  {DIM}{ub_ver or 'Ubuntu 24.04'}{NC}  "
               f"{DIM}Size:{NC} {ub_size or '?'}  {CYN}[P]{NC}")

        rc, sel = _fzf_raw(lines, f"--header={hdr}")
        if rc != 0 or not sel:
            return
        clean = strip_ansi(trim_s(sel)).strip()
        if clean == L["back"] or not clean:
            return

        if "Updates" in clean:
            _ubuntu_run_updates(ctx)
        elif "Uninstall Ubuntu base" in clean:
            if confirm("Uninstall Ubuntu base?\n\n  All containers using Ubuntu packages will break."):
                import shutil
                shutil.rmtree(ctx.ubuntu_dir, ignore_errors=True)
                os.makedirs(ctx.ubuntu_dir, exist_ok=True)
                pause("Ubuntu base removed.")
            return
        elif "Add package" in clean:
            if not finput("Package name to install:"):
                continue
            pkg = _tui.FINPUT_RESULT.strip()
            if pkg:
                _apt_op(ctx, "install", pkg)
        else:
            # Package selected — install/remove
            pkg = clean.replace("◈", "").strip().split()[0] if clean else ""
            if not pkg:
                continue
            lines2 = [f"{GRN}↑  Install / update{NC}", f"{RED}×  Remove{NC}",
                      f"{DIM} {L['back']}{NC}"]
            rc2, sel2 = _fzf_raw(lines2, f"--header={BLD}── {pkg} ──{NC}")
            if rc2 != 0 or not sel2:
                continue
            act = strip_ansi(trim_s(sel2)).strip()
            if "Install" in act or "update" in act:
                _apt_op(ctx, "install", pkg)
            elif "Remove" in act:
                if confirm(f"Remove package '{pkg}'?"):
                    _apt_op(ctx, "remove", pkg)


def _ensure_ubuntu(ctx):
    """Start Ubuntu bootstrap install session."""
    from functions.installer import ensure_ubuntu
    ensure_ubuntu(ctx.ubuntu_dir, ctx.tmp_dir)


def _apt_op(ctx, op, pkg):
    sess = "sdUbuntuPkg"
    script = make_tmp(".sd_apt_", ".sh")
    with open(script, "w") as fp:
        fp.write(f"#!/usr/bin/env bash\n"
                 f"echo '── apt-get {op} {pkg} ──'\n"
                 f"chroot '{ctx.ubuntu_dir}' apt-get {op} -y '{pkg}' 2>&1\n"
                 f"echo ''\n"
                 f"[[ $? -eq 0 ]] && touch '{ctx.ubuntu_dir}/.upkg_ok' || touch '{ctx.ubuntu_dir}/.upkg_fail'\n"
                 f"rm -f '{script}'\n"
                 f"read -p 'Done — press Enter to close...'\n")
    os.chmod(script, 0o755)
    subprocess.run(["tmux", "new-session", "-d", "-s", sess, f"bash '{script}'"],
                   stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "attach-session", "-t", sess], stderr=subprocess.DEVNULL)


def _ubuntu_run_updates(ctx):
    sess = "sdUbuntuPkg"
    script = make_tmp(".sd_ub_upd_", ".sh")
    with open(script, "w") as fp:
        fp.write(f"#!/usr/bin/env bash\n"
                 f"echo '── apt-get update && upgrade ──'\n"
                 f"chroot '{ctx.ubuntu_dir}' apt-get update 2>&1\n"
                 f"chroot '{ctx.ubuntu_dir}' apt-get upgrade -y 2>&1\n"
                 f"rm -f '{script}'\n"
                 f"read -p 'Done — press Enter to close...'\n")
    os.chmod(script, 0o755)
    subprocess.run(["tmux", "new-session", "-d", "-s", sess, f"bash '{script}'"],
                   stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "attach-session", "-t", sess], stderr=subprocess.DEVNULL)
