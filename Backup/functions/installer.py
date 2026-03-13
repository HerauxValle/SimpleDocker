"""
installer.py — run_job: generate and launch install/update bash scripts in tmux
"""

import os
import re
import shlex
import subprocess
import tempfile
import time

from .constants import TMP_DIR, DEFAULT_UBUNTU_PKGS, GRN, RED, BLD, DIM, NC
from .utils import (
    run, run_out, sudo_run, make_tmp, current_user,
    tmux_get, tmux_set, tmux_up, inst_sess,
    state_get, state_set, read_json, write_json, log_path,
)
from .blueprint import compile_service, cr_prefix
from .container import cname, cpath, is_installing, env_exports
from .utils import guard_space


# ── Helpers ───────────────────────────────────────────────────────────────

def _shq(s: str) -> str:
    return shlex.quote(s)


def _deps_parse(deps_block: str) -> str:
    """Parse deps block and return space-separated apt package list."""
    pkgs = []
    for line in deps_block.splitlines():
        line = re.sub(r'#.*', '', line).strip()
        if not line:
            continue
        for tok in line.split(','):
            tok = tok.strip().lstrip('@')
            if not tok:
                continue
            if ':' in tok:
                pkg, _, ver = tok.partition(':')
                if ver == 'latest':
                    pkgs.append(pkg)
                else:
                    ver = ver.replace('.x', '.*')
                    pkgs.append(f"{pkg}={ver}")
            else:
                pkgs.append(tok)
    return " ".join(pkgs)


def _deps_pkg_version(deps_block: str, name: str) -> str:
    for line in deps_block.splitlines():
        line = re.sub(r'#.*', '', line).strip()
        for tok in line.split(','):
            tok = tok.strip().lstrip('@')
            pkg = tok.split(':')[0]
            if pkg != name:
                continue
            if ':' in tok:
                ver = tok.split(':', 1)[1]
                if ver == 'latest':
                    return name
                return f"{name}={ver.replace('.x', '.*')}"
            return name
    return name


def _expand_dirs(dirs_block: str) -> list:
    """Expand 'lib(a, b)' -> ['lib/a', 'lib/b']. Returns flat list."""
    result = []
    for part in [p.strip() for p in dirs_block.replace('\n', ',').split(',')]:
        m = re.match(r'^([^(]+)\(([^)]+)\)$', part)
        if m:
            base = m.group(1).strip()
            for sub in m.group(2).split(','):
                result.append(f"{base}/{sub.strip()}")
        elif part:
            result.append(part)
    return result


# ── Ubuntu bootstrap inline ───────────────────────────────────────────────

def _emit_ubuntu_bootstrap(ubuntu_dir: str, default_pkgs: str, me: str) -> str:
    ud = _shq(ubuntu_dir)
    lines = []
    lines.append(f'# ── Ubuntu base (auto-install if missing) ──')
    lines.append(f'if [[ ! -f {ud}/.ubuntu_ready ]]; then')
    lines.append(f"    printf '\\033[1m[ubuntu] Base not found — installing...\\033[0m\\n'")
    lines.append(f'    _sd_ub_arch=$(uname -m)')
    lines.append(f'    case "$_sd_ub_arch" in')
    lines.append(f'        x86_64)  _sd_ub_arch=amd64 ;;')
    lines.append(f'        aarch64) _sd_ub_arch=arm64  ;;')
    lines.append(f'        armv7l)  _sd_ub_arch=armhf  ;;')
    lines.append(f'        *)       _sd_ub_arch=amd64  ;;')
    lines.append(f'    esac')
    lines.append(f'    _sd_ub_index="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"')
    lines.append(f'    _sd_ub_ver=$(curl -fsSL "$_sd_ub_index" 2>/dev/null | grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${{_sd_ub_arch}}" | head -1)')
    lines.append(f'    [[ -z "$_sd_ub_ver" ]] && _sd_ub_ver="24.04.3-base-${{_sd_ub_arch}}"')
    lines.append(f'    _sd_ub_url="${{_sd_ub_index}}ubuntu-base-${{_sd_ub_ver}}.tar.gz"')
    lines.append(f'    _sd_ub_tmp=$(mktemp {ud}/../.sd_ubuntu_dl_XXXXXX.tar.gz 2>/dev/null || mktemp /tmp/.sd_ubuntu_dl_XXXXXX.tar.gz)')
    lines.append(f'    mkdir -p {ud}')
    lines.append(f"    printf '[ubuntu] Downloading Ubuntu 24.04 LTS Noble (%s)...\\n' \"$_sd_ub_arch\"")
    lines.append(f'    if curl -fsSL --progress-bar "$_sd_ub_url" -o "$_sd_ub_tmp"; then')
    lines.append(f"        printf '[ubuntu] Extracting...\\n'")
    lines.append(f'        tar -xzf "$_sd_ub_tmp" -C {ud} 2>&1 || true')
    lines.append(f'        rm -f "$_sd_ub_tmp"')
    lines.append(f'        [[ ! -e {ud}/bin   ]] && ln -sf usr/bin   {ud}/bin   2>/dev/null || true')
    lines.append(f'        [[ ! -e {ud}/lib   ]] && ln -sf usr/lib   {ud}/lib   2>/dev/null || true')
    lines.append(f'        [[ ! -e {ud}/lib64 ]] && ln -sf usr/lib64 {ud}/lib64 2>/dev/null || true')
    lines.append(f"        printf 'nameserver 8.8.8.8\\n' > {ud}/etc/resolv.conf 2>/dev/null || true")
    lines.append(f'        mkdir -p {ud}/etc/apt/apt.conf.d 2>/dev/null || true')
    lines.append(f"        printf 'APT::Sandbox::User \"root\";\\n' > {ud}/etc/apt/apt.conf.d/99sandbox 2>/dev/null || true")
    lines.append(f"        printf '[ubuntu] Installing base packages...\\n'")
    sudoers = _shq(f"/etc/sudoers.d/simpledocker_ubsetup_$$")
    lines.append(f"        printf '%s ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/chroot, /usr/sbin/chroot\\n' {_shq(me)} | sudo -n tee {sudoers} >/dev/null 2>&1 || true")
    lines.append(f'        mkdir -p {ud}/tmp {ud}/proc {ud}/sys {ud}/dev 2>/dev/null || true')
    lines.append(f'        sudo -n mount --bind /proc {ud}/proc 2>/dev/null || true')
    lines.append(f'        sudo -n mount --bind /sys  {ud}/sys  2>/dev/null || true')
    lines.append(f'        sudo -n mount --bind /dev  {ud}/dev  2>/dev/null || true')
    lines.append(f'        _sd_ub_apt=$(mktemp {ud}/../.sd_ubinit_XXXXXX.sh 2>/dev/null || echo /tmp/.sd_ubinit_$$.sh)')
    lines.append(f"        printf '#!/bin/sh\\nset -e\\napt-get update -qq\\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {default_pkgs} 2>&1\\n' > \"$_sd_ub_apt\"")
    lines.append(f'        chmod +x "$_sd_ub_apt"')
    lines.append(f'        sudo -n mount --bind "$_sd_ub_apt" {ud}/tmp/.sd_ubinit.sh 2>/dev/null || cp "$_sd_ub_apt" {ud}/tmp/.sd_ubinit.sh 2>/dev/null || true')
    lines.append(f'        sudo -n chroot {ud} /bin/bash /tmp/.sd_ubinit.sh || true')
    lines.append(f'        sudo -n umount -lf {ud}/tmp/.sd_ubinit.sh 2>/dev/null || true')
    lines.append(f'        sudo -n umount -lf {ud}/dev {ud}/sys {ud}/proc 2>/dev/null || true')
    lines.append(f'        rm -f "$_sd_ub_apt" {ud}/tmp/.sd_ubinit.sh 2>/dev/null || true')
    lines.append(f'        sudo -n rm -f {sudoers} 2>/dev/null || true')
    lines.append(f'        touch {ud}/.ubuntu_ready')
    lines.append(f"        date '+%Y-%m-%d' > {ud}/.sd_ubuntu_stamp")
    lines.append(f"        printf '\\033[0;32m[ubuntu] Ubuntu base ready.\\033[0m\\n\\n'")
    lines.append(f'    else')
    lines.append(f'        rm -f "$_sd_ub_tmp"')
    lines.append(f"        printf '\\033[0;31m[ubuntu] ERROR: Download failed — cannot proceed.\\033[0m\\n'")
    lines.append(f'        exit 1')
    lines.append(f'    fi')
    lines.append(f'fi')
    lines.append('')
    return "\n".join(lines)


# ── GitHub download helpers (emitted into install script) ─────────────────

_SD_HELPER_SCRIPT = r"""
_sd_extract_auto() {
    local url="$1" dest="$2"; mkdir -p "$dest"
    local _tmp; _tmp=$(mktemp "$dest/.sd_dl_XXXXXX")
    curl -fL --progress-bar --retry 5 --retry-delay 3 --retry-all-errors -C - "$url" -o "$_tmp" || { rm -f "$_tmp"; printf "[!] Download failed: %s\n" "$url"; return 1; }
    local strip=1
    local _extracted=false
    if [[ "$url" =~ \.tar\.zst$ ]]; then
        local _tops; _tops=$(tar --use-compress-program=unzstd -t -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar --use-compress-program=unzstd -x -C "$dest" --strip-components="$strip" -f "$_tmp" 2>/dev/null && _extracted=true || true
    elif [[ "$url" =~ \.(tar\.(gz|bz2|xz)|tgz)$ ]]; then
        local _tops; _tops=$(tar -ta -f "$_tmp" 2>/dev/null | sed 's|/.*||' | sort -u | grep -v '^\.$' | wc -l) || true
        [[ "${_tops:-1}" -gt 1 ]] && strip=0
        tar -xa -C "$dest" --strip-components="$strip" -f "$_tmp" 2>/dev/null && _extracted=true || true
    elif [[ "$url" =~ \.zip$ ]]; then
        unzip -o -d "$dest" "$_tmp" 2>/dev/null && _extracted=true || true
    fi
    if [[ "$_extracted" == false ]]; then
        local _bn; _bn=$(basename "$url" | sed 's/[?#].*//' \
            | sed 's/\.\(tar\.\(gz\|bz2\|xz\|zst\)\|tgz\|zip\)$//' \
            | sed 's/[-_]linux[-_][^-]*$//' \
            | sed 's/[-_]linux$//' \
            | sed 's/[-_]\(amd64\|arm64\|x86_64\|aarch64\|v[0-9][0-9.]*\)$//')
        [[ -z "$_bn" ]] && _bn=$(basename "$url" | sed 's/[?#].*//')
        mkdir -p "$dest"
        mv "$_tmp" "$dest/$_bn"; chmod +x "$dest/$_bn"; return
    fi
    rm -f "$_tmp"
}
_sd_latest_tag() {
    local repo="$1"
    curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null \
        | grep -o '"tag_name": *"[^"]*"' | head -1 | grep -o '"[^"]*"$' | tr -d '"'
}
_sd_best_url() {
    local repo="$1" arch="$2" hint="${3:-}" atype="${4:-}"
    local rel; rel=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || true
    local urls; urls=$(printf '%s' "$rel" | grep -o '"browser_download_url": *"[^"]*"' \
        | grep -ivE 'sha256|\.sig|\.txt|\.json|rocm|jetpack' | grep -o 'https://[^"]*') || true
    local type_urls="$urls"
    case "${atype^^}" in
        BIN)  type_urls=$(printf '%s' "$urls" | grep -ivE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$') ;;
        ZIP)  type_urls=$(printf '%s' "$urls" | grep -iE '\.zip$') ;;
        TAR)  type_urls=$(printf '%s' "$urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz)$') ;;
    esac
    local url=""
    [[ -n "$hint" ]] && url=$(printf '%s' "$type_urls" | grep -iF "$hint" | head -1) || true
    [[ -z "$url" && "${_SD_GPU:-cpu}" == "cuda" ]] && url=$(printf '%s' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | grep -iE "$arch" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE "$arch" | head -1) || true
    [[ -z "$url" && -n "$hint" ]] && url=$(printf '%s' "$urls" | grep -i "$hint" | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$type_urls" | grep -iE '\.(tar\.(gz|zst|xz|bz2)|tgz|zip)$' | head -1) || true
    [[ -z "$url" ]] && url=$(printf '%s' "$rel" | grep -o '"tarball_url": *"[^"]*"' | grep -o 'https://[^"]*' | head -1) || true
    printf '%s' "$url"
}
"""


def _emit_github_block(github_block: str, install_path: str) -> str:
    lines = ["# ── GitHub downloads ──"]
    arch = "arm64" if run_out(["uname", "-m"]) == "aarch64" else "amd64"
    lines.append(f"_SD_ARCH={_shq(arch)}")
    lines.append(f"_SD_INSTALL={_shq(install_path)}")
    lines.append("")
    lines.append(_SD_HELPER_SCRIPT)
    lines.append("")

    for raw_line in github_block.splitlines():
        ghline = re.sub(r'#.*', '', raw_line).strip()
        if not ghline:
            continue
        # Handle "varname = org/repo" format
        m = re.match(r'^[a-zA-Z_]\w*\s*=\s*(.*)', ghline)
        if m:
            ghline = m.group(1).strip()

        repo = ghline.split()[0] if ghline.split() else ""
        rest = ghline[len(repo):].strip()

        # Extract [HINT], [BIN|ZIP|TAR] tokens
        asset_hint = ""
        asset_type = ""
        for token_m in re.finditer(r'\[([^\]]+)\]', rest):
            bval = token_m.group(1)
            if bval.upper() in ("BIN", "ZIP", "TAR"):
                asset_type = bval.upper()
            elif not asset_hint:
                asset_hint = bval
        rest_clean = re.sub(r'\[[^\]]*\]', '', rest).strip()

        # Destination subdir after →
        dest_sub = ""
        m = re.search(r'→\s*(\S+)', rest_clean)
        if m:
            dest_sub = m.group(1).rstrip("/")
        if dest_sub and dest_sub != ".":
            dest_expr = f"$_SD_INSTALL/{dest_sub}"
        else:
            dest_expr = "$_SD_INSTALL"

        if re.match(r'^source', rest_clean):
            lines.append(f"printf 'Cloning {repo}...\\n'")
            lines.append(f'_sd_tag=$(_sd_latest_tag "{repo}")')
            lines.append(f'_sd_cdest="{dest_expr}"')
            lines.append(f'if [[ -n "$_sd_tag" ]]; then')
            lines.append(f'    git clone --depth=1 --branch "$_sd_tag" "https://github.com/{repo}.git" "$_sd_cdest" 2>&1')
            lines.append(f'else')
            lines.append(f'    git clone --depth=1 "https://github.com/{repo}.git" "$_sd_cdest" 2>&1')
            lines.append(f'fi')
            lines.append('')
        else:
            lines.append(f"printf 'Fetching {repo} (%s)...\\n' \"$_SD_ARCH\"")
            lines.append(f'_sd_url=$(_sd_best_url "{repo}" "$_SD_ARCH" "{asset_hint}" "{asset_type}")')
            lines.append(f'[[ -z "$_sd_url" ]] && {{ printf "[!] No asset found for {repo}\\n"; exit 1; }}')
            lines.append(f'_sd_extract_auto "$_sd_url" "{dest_expr}"')
            lines.append(f"printf '\\033[0;32m✓ {repo} → {dest_expr}\\033[0m\\n'")
            lines.append('')

    return "\n".join(lines)


# ── Chroot mount helpers (emitted into scripts) ───────────────────────────

def _chroot_mount_block(ip_q: str, me: str, sudoers_q: str) -> str:
    return f"""printf '{me} ALL=(ALL) NOPASSWD: /bin/mount, /bin/umount, /usr/bin/bash, /usr/bin/chroot, /usr/sbin/chroot, /usr/bin/unshare\\n' | sudo -n tee {sudoers_q} >/dev/null 2>&1 || true
mkdir -p {ip_q}/tmp {ip_q}/proc {ip_q}/sys {ip_q}/dev 2>/dev/null || true
sudo -n mount --bind /proc {ip_q}/proc 2>/dev/null || true
sudo -n mount --bind /sys  {ip_q}/sys  2>/dev/null || true
sudo -n mount --bind /dev  {ip_q}/dev  2>/dev/null || true"""


def _chroot_umount_block(ip_q: str, sudoers_q: str) -> str:
    return f"""sudo -n umount -lf {ip_q}/dev {ip_q}/sys {ip_q}/proc 2>/dev/null || true
sudo -n rm -f {sudoers_q} 2>/dev/null || true"""


# ── Main run_job function ─────────────────────────────────────────────────

def run_job(
    mode: str,
    cid: str,
    containers_dir: str,
    installations_dir: str,
    ubuntu_dir: str,
    logs_dir: str,
    tmp_dir: str,
    force: str = "ask"
) -> bool:
    """
    Generate and launch install/update script in a tmux session.
    mode: "install" | "update"
    Returns True if launched successfully.
    """
    from .tui import pause

    ip      = cpath(containers_dir, installations_dir, cid)
    ok_file = os.path.join(containers_dir, cid, ".install_ok")
    fail_file = os.path.join(containers_dir, cid, ".install_fail")

    if mode == "install" and is_installing(cid):
        if force != "yes":
            return False
        subprocess.run(["tmux", "kill-session", "-t", inst_sess(cid)],
                       stderr=subprocess.DEVNULL)

    compile_service(cid, containers_dir)

    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj) or {}

    if mode == "install":
        if not ip:
            pause("No install path set.")
            return False
        has_install = any([
            data.get("install", "").strip(),
            data.get("git", "").strip(),
            data.get("dirs", "").strip(),
            data.get("pip", "").strip(),
            data.get("npm", "").strip(),
        ])
        if not has_install:
            pause("⚠  No install, git, dirs, pip, or npm block in service.json.")
            return False

        # Remove old installation
        if os.path.isdir(ip):
            r = sudo_run(["btrfs", "subvolume", "delete", ip])
            if r.returncode != 0:
                subprocess.run(["rm", "-rf", ip], stderr=subprocess.DEVNULL)

        # Snapshot or create from Ubuntu base
        if os.path.isfile(os.path.join(ubuntu_dir, ".ubuntu_ready")):
            r = subprocess.run(
                ["btrfs", "subvolume", "snapshot", ubuntu_dir, ip],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if r.returncode != 0:
                subprocess.run(["btrfs", "subvolume", "create", ip],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) or \
                os.makedirs(ip, exist_ok=True)
            me = current_user()
            sudo_run(["chown", f"{me}:{me}", ip])
            stamp = os.path.join(ubuntu_dir, ".sd_ubuntu_stamp")
            if os.path.isfile(stamp):
                import shutil
                shutil.copy2(stamp, os.path.join(ip, ".sd_ubuntu_stamp"))
        else:
            r = subprocess.run(
                ["btrfs", "subvolume", "create", ip],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if r.returncode != 0:
                os.makedirs(ip, exist_ok=True)

        for f in [ok_file, fail_file]:
            try:
                os.unlink(f)
            except Exception:
                pass

    else:
        if not ip or not os.path.isdir(ip):
            pause("Not installed.")
            return False

    if not guard_space(ip):
        pause("⚠  Low disk space — aborting.")
        return False

    os.makedirs(logs_dir, exist_ok=True)
    ct_name = cname(containers_dir, cid)
    logfile = log_path(logs_dir, cid, ct_name, mode)
    me = current_user()

    # ── Build the full install/update script ──────────────────────────────
    script_lines = []
    script_lines.append("#!/usr/bin/env bash")
    script_lines.append("set -e")

    # Log to file
    script_lines.append(f"exec > >(tee -a {_shq(logfile)}) 2>&1")

    # Finish trap
    ok_q   = _shq(ok_file)
    fail_q = _shq(fail_file)
    script_lines.append(f"""
_finish() {{
    local code=$?
    if [[ $code -eq 0 ]]; then
        touch {ok_q}
        printf '\\n\\033[0;32m══ {mode.title()} complete ══\\033[0m\\n'
    else
        touch {fail_q}
        printf '\\n\\033[0;31m══ {mode.title()} failed (exit %d) ══\\033[0m\\n' "$code"
    fi
}}
trap _finish EXIT
trap 'touch {fail_q}; exit 130' INT TERM
""")

    # Environment block
    env_block = env_exports(containers_dir, cid, ip)
    script_lines.append(env_block)
    script_lines.append('cd "$CONTAINER_ROOT"')
    script_lines.append("")

    # chroot_bash helper
    script_lines.append(r"""_chroot_bash() {
    local r=$1; shift; local b=/bin/bash
    [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash
    [[ ! -e "$r$b" ]] && b=/bin/sh
    sudo -n chroot "$r" "$b" "$@"
}""")

    # Ubuntu bootstrap
    script_lines.append(_emit_ubuntu_bootstrap(ubuntu_dir, DEFAULT_UBUNTU_PKGS, me))

    # Populate container from Ubuntu base if missing
    ud_q = _shq(ubuntu_dir)
    me_q = _shq(me)
    script_lines.append(f"""if [[ ! -e bin/bash && -f {ud_q}/.ubuntu_ready ]]; then
    printf '[sd] Populating container with Ubuntu base...\\n'
    if command -v rsync >/dev/null 2>&1; then
        sudo -n rsync -a --ignore-existing {ud_q}/ . 2>/dev/null || true
    else
        sudo -n cp -an {ud_q}/. . 2>/dev/null || true
    fi
    sudo -n chown -R {me_q} . 2>/dev/null || true
fi
""")

    if mode == "install":
        ip_q = _shq(ip)

        # ── apt deps ──
        deps_raw = data.get("deps", "").strip()
        if deps_raw:
            pkgs = _deps_parse(deps_raw)
            if pkgs:
                sudoers_q = _shq(f"/etc/sudoers.d/simpledocker_deps_$$")
                script_lines.append(f"# ── System deps (apt) ──")
                script_lines.append(f"printf '\\033[1m[deps] Installing: {pkgs}\\033[0m\\n'")
                script_lines.append(_chroot_mount_block(ip_q, me, sudoers_q))
                script_lines.append(f"""_sd_deps_cmd=$(mktemp {ip_q}/tmp/.sd_deps_XXXXXX.sh 2>/dev/null || echo {ip_q}/tmp/.sd_deps_$$.sh)
printf '#!/bin/sh\\nset -e\\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {pkgs} 2>&1 || {{ apt-get update -qq 2>&1 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {pkgs} 2>&1; }}\\n' > "$_sd_deps_cmd"
chmod +x "$_sd_deps_cmd"
sudo -n chroot {ip_q} /bin/bash /tmp/$(basename "$_sd_deps_cmd")""")
                script_lines.append(_chroot_umount_block(ip_q, sudoers_q))
                script_lines.append(f'rm -f "$_sd_deps_cmd" 2>/dev/null || true\n')

        # ── dirs ──
        dirs_raw = data.get("dirs", "").strip()
        if dirs_raw:
            expanded = _expand_dirs(dirs_raw)
            script_lines.append("# ── Create dirs ──")
            script_lines.append("printf '\\033[1m[dirs] Creating directory structure\\033[0m\\n'")
            for d in expanded:
                if d:
                    script_lines.append(f"mkdir -p {_shq(os.path.join(ip, d))} 2>/dev/null || true")
            script_lines.append("")

        # ── pip ──
        pip_raw = data.get("pip", "").strip()
        if pip_raw:
            pip_pkgs = " ".join(
                t.strip() for t in re.split(r'[,\n]', re.sub(r'#.*', '', pip_raw)) if t.strip()
            )
            py_tok = _deps_pkg_version(deps_raw, "python3")
            sudoers_q = _shq(f"/etc/sudoers.d/simpledocker_pip_$$")
            script_lines.append("# ── pip install ──")
            script_lines.append(f"printf '\\033[1m[pip] Installing: {pip_pkgs}\\033[0m\\n'")
            script_lines.append(_chroot_mount_block(ip_q, me, sudoers_q))
            script_lines.append(f"""_sd_pip_cmd=$(mktemp {ip_q}/tmp/.sd_pip_XXXXXX.sh 2>/dev/null || echo {ip_q}/tmp/.sd_pip_$$.sh)
cat > "$_sd_pip_cmd" << '_SD_PIP_EOF'
#!/bin/sh
set -e
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {py_tok} python3-full python3-pip 2>&1 || {{
    apt-get update -qq 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {py_tok} python3-full python3-pip 2>&1
}}
python3 -m venv --clear /venv
/venv/bin/pip install --upgrade pip
/venv/bin/pip install --upgrade {pip_pkgs}
_SD_PIP_EOF
chmod +x "$_sd_pip_cmd"
sudo -n chroot {ip_q} /bin/bash /tmp/$(basename "$_sd_pip_cmd")
_sd_pip_rc=$?""")
            script_lines.append(_chroot_umount_block(ip_q, sudoers_q))
            venv_q = _shq(os.path.join(ip, "venv"))
            script_lines.append(f'rm -f "$_sd_pip_cmd" 2>/dev/null || true')
            script_lines.append(f'sudo -n chown -R {_shq(me)} {venv_q} 2>/dev/null || true')
            script_lines.append(f'if [[ $_sd_pip_rc -ne 0 ]]; then exit "$_sd_pip_rc"; fi\n')

        # ── npm ──
        npm_raw = data.get("npm", "").strip()
        if npm_raw:
            npm_pkgs = " ".join(
                t.strip() for t in re.split(r'[,\n]', re.sub(r'#.*', '', npm_raw)) if t.strip()
            )
            sudoers_q = _shq(f"/etc/sudoers.d/simpledocker_npm_$$")
            script_lines.append("# ── npm install ──")
            script_lines.append(f"printf '\\033[1m[npm] Installing: {npm_pkgs}\\033[0m\\n'")
            script_lines.append(_chroot_mount_block(ip_q, me, sudoers_q))
            script_lines.append(f"""_sd_npm_cmd=$(mktemp {ip_q}/tmp/.sd_npm_XXXXXX.sh 2>/dev/null || echo {ip_q}/tmp/.sd_npm_$$.sh)
cat > "$_sd_npm_cmd" << '_SD_NPM_EOF'
#!/bin/sh
set -e
node_ok=0
if command -v node >/dev/null 2>&1; then
    _nv=$(node -e "process.exit(parseInt(process.version.slice(1)) >= 22 ? 0 : 1)" 2>/dev/null && echo 1 || echo 0)
    [ "$_nv" = "1" ] && node_ok=1
fi
if [ "$node_ok" = "0" ]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1 || {{ apt-get update -qq 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates 2>&1; }}
    curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs 2>&1
fi
npm install {npm_pkgs} 2>&1
_SD_NPM_EOF
chmod +x "$_sd_npm_cmd"
sudo -n chroot {ip_q} /bin/bash /tmp/$(basename "$_sd_npm_cmd")
_sd_npm_rc=$?""")
            script_lines.append(_chroot_umount_block(ip_q, sudoers_q))
            script_lines.append(f'rm -f "$_sd_npm_cmd" 2>/dev/null || true')
            script_lines.append(f'sudo -n chown -R {_shq(me)} {ip_q}/node_modules 2>/dev/null || true')
            script_lines.append(f'if [[ $_sd_npm_rc -ne 0 ]]; then exit "$_sd_npm_rc"; fi\n')

    # ── git downloads (install only) ──
    github_block = data.get("git", "").strip()
    if github_block and mode == "install":
        script_lines.append(_emit_github_block(github_block, ip))

    # ── build (install only) ──
    build_block = data.get("build", "").strip()
    if build_block and mode == "install":
        script_lines.append("# ── Build ──")
        script_lines.append(build_block)
        script_lines.append("")

    # ── install/update script block ──
    script_block = data.get(mode, "").strip()
    if script_block:
        ip_q2 = _shq(ip)
        sudoers_q2 = _shq(f"/etc/sudoers.d/simpledocker_script_$$")
        label = "Installation" if mode == "install" else "Update"
        script_lines.append(f"# ── {label} script ──")
        script_lines.append(_chroot_mount_block(ip_q2, me, sudoers_q2))
        script_lines.append(f"""_sd_run_cmd=$(mktemp {ip_q2}/tmp/.sd_run_XXXXXX.sh 2>/dev/null || echo {ip_q2}/tmp/.sd_run_fallback.sh)
cat > "$_sd_run_cmd" << '_SD_RUN_EOF'
#!/bin/bash
set -e
cd /
{script_block}
_SD_RUN_EOF
chmod +x "$_sd_run_cmd"
sudo -n chroot {ip_q2} /bin/bash /tmp/$(basename "$_sd_run_cmd")
_sd_run_rc=$?""")
        script_lines.append(_chroot_umount_block(ip_q2, sudoers_q2))
        script_lines.append(f'rm -f "$_sd_run_cmd" 2>/dev/null || true')
        script_lines.append(f'if [[ $_sd_run_rc -ne 0 ]]; then exit "$_sd_run_rc"; fi\n')

    # Write script
    full_script = make_tmp(".sd_install_", ".sh", dir=tmp_dir)
    with open(full_script, "w") as fp:
        fp.write("\n".join(script_lines) + "\n")
    os.chmod(full_script, 0o755)

    # Launch in tmux
    tmux_set("SD_INSTALLING", cid)
    inst_s = inst_sess(cid)
    subprocess.run(["tmux", "kill-session", "-t", inst_s], stderr=subprocess.DEVNULL)

    title = f"{mode.title()}: {ct_name}"
    r = subprocess.run(
        ["tmux", "new-session", "-d", "-s", inst_s, f"bash {_shq(full_script)}"],
        stderr=subprocess.DEVNULL
    )
    if r.returncode != 0:
        try:
            os.unlink(full_script)
        except Exception:
            pass
        tmux_set("SD_INSTALLING", "")
        return False

    subprocess.run(
        ["tmux", "rename-window", "-t", f"{inst_s}:0", title],
        stderr=subprocess.DEVNULL
    )

    # Hook: write fail_file if session ends abnormally
    hook_script = make_tmp(".sd_inst_hook_", ".sh", dir=tmp_dir)
    with open(hook_script, "w") as fp:
        fp.write(f"#!/usr/bin/env bash\n[[ -f {_shq(ok_file)} || -f {_shq(fail_file)} ]] || touch {_shq(fail_file)}\n")
    os.chmod(hook_script, 0o755)
    subprocess.run(
        ["tmux", "set-hook", "-t", inst_s, "pane-exited",
         f"run-shell {_shq(hook_script)}"],
        stderr=subprocess.DEVNULL
    )

    return True


def guard_install(containers_dir: str) -> bool:
    """Return True if OK to start a new install (no others running, or user confirmed)."""
    from .tui import confirm
    running = []
    for d in os.listdir(containers_dir) if os.path.isdir(containers_dir) else []:
        cid = d
        if is_installing(cid):
            running.append(cname(containers_dir, cid))
    if not running:
        return True
    return confirm(
        f"⚠  Installation already running: {', '.join(running)}\n\n"
        "  Running another simultaneously may slow both down.\n  Continue anyway?"
    )
