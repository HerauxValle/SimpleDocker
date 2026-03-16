#!/usr/bin/env python3
"""simpleDocker.py — single-file Python port of services.sh
Visually and functionally identical to the original bash script.
Each section tagged with its future split destination.
"""
# ── FUTURE DIRECTORY LAYOUT ──────────────────────────────────────────────────
# simpledocker/
# ├── main.py                  ← __main__ block (bottom of this file)
# ├── core/
# │   ├── config.py            ← G, L, KB, GRN/RED/…, FZF_BASE, DEFAULT_*
# │   ├── state.py             ← load_containers, st/set_st, cname, cpath, etc.
# │   └── deps.py              ← check_deps, require_sudo, sweep_stale
# ├── ui/
# │   └── fzf.py               ← fzf_run, confirm, pause, finput, menu
# ├── image/
# │   ├── mount.py             ← setup_image, mount_img, unmount_img, create_img
# │   ├── luks.py              ← luks_open/close, enc_menu
# │   └── btrfs.py             ← resize_image, snap helpers
# ├── container/
# │   ├── lifecycle.py         ← start_ct, stop_ct, run_job, process_finish
# │   ├── blueprint.py         ← bp_parse, bp_compile, bp_validate, gen_install_script
# │   ├── network.py           ← netns_setup/teardown/ct_add/ct_del, exposure_*
# │   └── backup.py            ← create_backup, restore_snap, clone_snap
# ├── services/
# │   ├── ubuntu.py            ← ensure_ubuntu, ubuntu_menu
# │   └── caddy.py             ← proxy_menu, proxy_running
# └── menus/
#     ├── main_menu.py
#     ├── containers.py        ← containers_submenu, install_method_menu
#     ├── container.py         ← container_submenu
#     ├── groups.py
#     ├── blueprints.py        ← blueprints_submenu, blueprints_settings_menu
#     ├── help.py
#     ├── storage.py           ← persistent_storage_menu
#     ├── encryption.py
#     ├── processes.py
#     ├── resources.py
#     └── logs.py
# ─────────────────────────────────────────────────────────────────────────────
from __future__ import annotations
import os, sys, re, json, time, shutil, signal, hashlib, subprocess, tempfile, threading, stat
from pathlib import Path
from typing import Optional, List

# ══════════════════════════════════════════════════════════════════════════════
# core/config.py — constants, global state, labels
# ══════════════════════════════════════════════════════════════════════════════

GRN='\033[0;32m'; RED='\033[0;31m'; YLW='\033[0;33m'; BLU='\033[0;34m'
CYN='\033[0;36m'; BLD='\033[1m';    DIM='\033[2m';     NC='\033[0m'

L = {
    'title':'simpleDocker','detach':'⊙  Detach','quit':'Quit',
    'quit_stop_all':'■  Stop all & quit','new_container':'New container',
    'help':'Other','ct_start':'▶  Start','ct_stop':'■  Stop',
    'ct_restart':'↺  Restart','ct_attach':'→  Attach','ct_install':'↓  Install',
    'ct_edit':'◦  Edit toml','ct_terminal':'◉  Terminal','ct_update':'↑  Update',
    'ct_uninstall':'○  Uninstall','ct_remove':'×  Remove','ct_rename':'✎  Rename',
    'ct_backups':'◈  Backups','ct_profiles':'◧  Profiles','ct_open_in':'⊕  Open in',
    'ct_exposure':'⬤  Port exposure','ct_attach_inst':'→  Attach to installation',
    'ct_kill_inst':'×  Kill installation','ct_finish_inst':'✓  Finish installation',
    'ct_log':'≡  View log','bp_new':'New blueprint','bp_edit':'◦  Edit',
    'bp_delete':'×  Delete','bp_rename':'✎  Rename','grp_new':'New group',
    'stor_rename':'✎  Rename','stor_delete':'×  Delete','back':'← Back',
    'yes':'Yes, confirm','no':'No','ok_press':'Press Enter or ESC to continue',
    'type_enter':'Type and press Enter  (ESC to cancel)',
    'msg_install_running':'An installation is already running',
    'msg_install_ok':'installed successfully.',
    'msg_install_fail':'Installation failed — attach to check output.',
    'img_select':'Select existing image','img_create':'Create new image',
}
KB = {'detach':'ctrl-d','quit':'ctrl-q','tmux_detach':'ctrl-\\'}

DEFAULT_IMG = ''
DEFAULT_UBUNTU_PKGS = 'bash curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential'
SD_DEFAULT_KEYWORD  = '1991316125415311518'
SD_LUKS_SLOT_MIN, SD_LUKS_SLOT_MAX = 7, 31
SD_BP_EXT = '.sdc'  # blueprint file extension

SD_AUTH_SLOT_A, SD_AUTH_SLOT_B = 2, 3   # auth key rotates between these; never touches passkey range
SD_UNLOCK_ORDER = ['verified_system','default_keyword','prompt']

class G:
    """Mutable global state — future: core/config.py"""
    img_path:         Optional[Path] = None
    mnt_dir:          Optional[Path] = None
    root_dir:         Path = Path.home()/'.config/simpleDocker'
    sd_mnt_base:      Path = Path(os.environ.get('XDG_RUNTIME_DIR',
                            str(Path.home()/'.local/share')))/'simpleDocker'
    tmp_dir:          Optional[Path] = None
    blueprints_dir:   Optional[Path] = None
    containers_dir:   Optional[Path] = None
    installations_dir:Optional[Path] = None
    backup_dir:       Optional[Path] = None
    storage_dir:      Optional[Path] = None
    ubuntu_dir:       Optional[Path] = None
    groups_dir:       Optional[Path] = None
    logs_dir:         Optional[Path] = None
    cache_dir:        Optional[Path] = None
    active_fzf_pid:   Optional[int]  = None
    usr1_fired:       bool = False
    running:          bool = True
    ub_pkg_drift:     bool = False
    ub_has_updates:   bool = False
    ub_cache_loaded:  bool = False
    CT_IDS:           list = []
    CT_NAMES:         list = []
    stor_ctx_cid:     str  = ''
    verification_cipher: str = ''

def _init_g():
    G.sd_mnt_base.mkdir(parents=True, exist_ok=True)
    G.tmp_dir = G.sd_mnt_base/'.tmp'
    G.tmp_dir.mkdir(parents=True, exist_ok=True)
    G.root_dir.mkdir(parents=True, exist_ok=True)
    # Derive verification_cipher from stable machine identity — never a shared fallback
    _vc = ''
    for _src in ['/etc/machine-id', '/var/lib/dbus/machine-id']:
        try:
            _d = Path(_src).read_text().strip()
            if _d: _vc = hashlib.sha256(_d.encode()).hexdigest()[:32]; break
        except: pass
    if not _vc:
        try:
            _hn = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
            if _hn: _vc = hashlib.sha256(_hn.encode()).hexdigest()[:32]
        except: pass
    G.verification_cipher = _vc or 'simpledocker_fallback'

FZF_BASE = [
    '--ansi','--no-sort','--header-first',
    '--prompt=  ❯ ','--pointer=▶',
    '--height=80%','--min-height=18',
    '--reverse','--border=rounded','--margin=1,2',
    '--no-info','--bind=esc:abort',
    f'--bind={KB["detach"]}:execute-silent(tmux set-environment -g SD_DETACH 1'
     ' && tmux detach-client >/dev/null 2>&1)+abort',
]

# ══════════════════════════════════════════════════════════════════════════════
# core/deps.py — subprocess helpers, dep check, sudo, sweep
# ══════════════════════════════════════════════════════════════════════════════

def _run(cmd, capture=False, input=None, check=False, **kw):
    """Thin wrapper — always silences stderr unless caller overrides."""
    kw.setdefault('stderr', subprocess.DEVNULL)
    if capture: kw['stdout'] = subprocess.PIPE; kw['text'] = True
    return subprocess.run(cmd, input=input, check=check, **kw)

def _sudo(*args, capture=False):
    return _run(['sudo','-n',*args], capture=capture)

def _tmux(*args, capture=False):
    return _run(['tmux',*args], capture=capture)

def tmux_up(session: str) -> bool:
    return _tmux('has-session','-t',session).returncode == 0

def tmux_get(key: str) -> str:
    r = _tmux('show-environment','-g',key, capture=True)
    return r.stdout.strip().split('=',1)[-1] if r.returncode==0 else ''

def tmux_set(key: str, val: str):
    _tmux('set-environment','-g',key,val)

def tmux_launch(sess: str, cmd: str, *, detach_on_destroy: bool = True):
    """Generalized tmux session launcher. Always logs to <img>/Logs/<sess>.log if img is mounted."""
    import sys as _sys
    _dbg = '--debug' in _sys.argv
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    if _dbg:
        full = f'bash -c \'set -x; exec "$@"\' -- bash -c {cmd!r}'
    else:
        full = cmd
    _tmux('new-session','-d','-s',sess, full)
    if detach_on_destroy:
        _tmux('set-option','-t',sess,'detach-on-destroy','off')
    if G.logs_dir:
        G.logs_dir.mkdir(parents=True, exist_ok=True)
        lf = str(G.logs_dir/f'{sess}.log')
        _tmux('pipe-pane','-t',sess, f'cat >> {lf!r}')

def tsess(cid: str) -> str: return f'sd_{cid}'
def inst_sess(cid: str) -> str: return f'sdInst_{cid}'
def cron_sess(cid: str, idx) -> str: return f'sdCron_{cid}_{idx}'

REQUIRED_TOOLS = ['jq','tmux','fzf','btrfs','sudo','curl','ip','cryptsetup','losetup']
# Optional host tools — features degrade gracefully if absent (no silent installs)
OPTIONAL_HOST_TOOLS = {
    'avahi-publish': 'avahi-utils',  # mDNS for Caddy .local domains
    'capsh':         'libcap2-bin',  # capability dropping (security)
    'dnsmasq':       'dnsmasq',      # container DNS resolution
}

def check_deps(mode='ask') -> bool:
    """Return True if all deps present. mode: 'ask'|'yes'|'no'"""
    missing = [t for t in REQUIRED_TOOLS if not shutil.which(t)]
    if not missing: return True
    if mode == 'no':
        print(f"Missing: {' '.join(missing)}"); sys.exit(1)
    if mode == 'ask': return False
    # mode == 'yes': install
    pkg_map = {'btrfs':'btrfs-progs','ip':'iproute2'}
    if shutil.which('pacman'):    pm = ['sudo','pacman','-S','--noconfirm']
    elif shutil.which('apt-get'): pm = ['sudo','apt-get','install','-y']
    elif shutil.which('dnf'):     pm = ['sudo','dnf','install','-y']
    elif shutil.which('zypper'):  pm = ['sudo','zypper','install','-y']
    else: print("No known package manager found"); sys.exit(1)
    for t in missing:
        subprocess.run(pm+[pkg_map.get(t,t)], capture_output=True)
    return True

def require_sudo():
    """Background keepalive — refreshes sudo ticket every 55s."""
    def _keep():
        while True: _sudo('true'); time.sleep(55)
    pass  # NOPASSWD sudoers - no keepalive needed

def sweep_stale():
    """Kill stale tmux sessions, unmount, close LUKS — future: core/deps.py"""
    # Kill stale container/install/cron sessions (not the main simpleDocker session)
    r = _tmux('list-sessions','-F','#{session_name}', capture=True)
    for s in (r.stdout.splitlines() if r.returncode==0 else []):
        if re.match(r'^(sd_|sdInst_|sdCron_|sdResize)',s):
            _tmux('kill-session','-t',s)
    # Unmount any leftover mnt_* mount points under sd_mnt_base
    if G.sd_mnt_base.is_dir():
        r = _run(['findmnt','-n','-o','TARGET','-R',str(G.sd_mnt_base)],capture=True)
        mounts = sorted([l for l in r.stdout.splitlines()
                         if l.strip() and l.strip() != str(G.sd_mnt_base)],
                        key=len, reverse=True)
        for m in mounts:
            _sudo('umount','-lf',m)
            try: Path(m).rmdir()
            except: pass
    # Close any leftover LUKS mappers (only if any exist)
    _sd_mappers = [mp for mp in Path('/dev/mapper').glob('sd_*')
                   if stat.S_ISBLK(os.stat(str(mp)).st_mode)]
    for mp in _sd_mappers:
        nm = mp.name
        r2 = _sudo('cryptsetup','status',nm, capture=True)
        lo = next((l.split()[-1] for l in r2.stdout.splitlines() if 'device:' in l), '')
        _sudo('cryptsetup','close',nm, capture=True)
        if lo.startswith('/dev/loop'): _sudo('losetup','-d',lo, capture=True)
    # Detach loop devices for .img files with no active mount (single losetup -a call)
    r = _run(['sudo','-n','losetup','-a'], capture=True)
    for line in r.stdout.splitlines():
        if '.img' not in line: continue
        lo = line.split(':')[0].strip()
        if not lo: continue
        # Fast check: does this loop have any mount? Use losetup -j on backing file
        backing = line.split('(')[-1].rstrip(')') if '(' in line else ''
        already_mounted = bool(backing and _run(
            ['findmnt','--source',f'/dev/mapper/sd_{backing.split("/")[-1].replace(".img","")}'],
            capture=True).stdout.strip()) if backing else False
        if not already_mounted:
            _sudo('losetup','-d',lo)
    # Clean tmp dir only (not the whole sd_mnt_base which may have active mounts)
    try: shutil.rmtree(str(G.tmp_dir), ignore_errors=True)
    except: pass
    G.sd_mnt_base.mkdir(parents=True, exist_ok=True)
    G.tmp_dir.mkdir(parents=True, exist_ok=True)

def write_sudoers():
    """Prompt for sudo password (with retry loop like the shell), then write NOPASSWD rule."""
    import pwd as _pwd; me = _pwd.getpwuid(os.getuid()).pw_name
    cmds = ('/bin/mount,/bin/umount,/usr/bin/mount,/usr/bin/umount,'            '/usr/bin/btrfs,/usr/sbin/btrfs,/bin/btrfs,/sbin/btrfs,'            '/usr/bin/mkfs.btrfs,/sbin/mkfs.btrfs,/usr/bin/chown,/bin/chown,'            '/bin/mkdir,/usr/bin/mkdir,/usr/bin/rm,/bin/rm,/usr/bin/chmod,'            '/bin/chmod,/usr/bin/tee,/usr/bin/nsenter,/usr/sbin/nsenter,'            '/usr/bin/unshare,/usr/bin/chroot,/usr/sbin/chroot,/bin/bash,'            '/usr/bin/bash,/usr/bin/ip,/bin/ip,/sbin/ip,/usr/sbin/ip,'            '/usr/sbin/iptables,/usr/bin/iptables,/sbin/iptables,'            '/usr/sbin/sysctl,/usr/bin/sysctl,/bin/cp,/usr/bin/cp,'            '/usr/bin/apt-get,/usr/bin/apt,/usr/sbin/cryptsetup,'            '/usr/bin/cryptsetup,/sbin/cryptsetup,/sbin/losetup,'            '/usr/sbin/losetup,/bin/losetup,/sbin/blockdev,/usr/sbin/blockdev,'            '/usr/bin/dmsetup,/usr/sbin/dmsetup,/usr/bin/rsync,'            '/usr/bin/mktemp,/bin/mktemp,/usr/bin/touch,/bin/touch,'            '/usr/bin/date,/bin/date,/usr/bin/truncate,/bin/truncate,'            '/usr/bin/dd,/bin/dd,/usr/bin/find,/bin/find')
    rule = f'{me} ALL=(ALL) NOPASSWD: {cmds}\n'
    # Invalidate cached credentials, then prompt until success — mirrors shell _sd_outer_sudo
    subprocess.run(['sudo','-k'], capture_output=True)
    print(f'\n  {BLD}── simpleDocker ──{NC}')
    print(f'  {DIM}simpleDocker requires sudo access.{NC}\n')
    try:
        while subprocess.run(['sudo','-v']).returncode != 0:
            print(f'  {RED}Incorrect password.{NC} Try again.\n')
    except KeyboardInterrupt:
        print(f'\n\n  {DIM}Bye.{NC}\n'); sys.exit(0)
    subprocess.run(['sudo','mkdir','-p','/etc/sudoers.d'])
    p = subprocess.run(['sudo','tee',f'/etc/sudoers.d/simpledocker_{me}'],
                       input=rule.encode(), capture_output=True)
    return p.returncode == 0

# ══════════════════════════════════════════════════════════════════════════════
# ui/fzf.py — all interactive prompts
# ══════════════════════════════════════════════════════════════════════════════

def strip_ansi(s: str) -> str:
    return re.sub(r'\x1b\[[0-9;]*m','',s)

def clean(s: str) -> str:
    return strip_ansi(s).strip()

def _sep(title: str, width: int=38) -> str:
    return f'{BLD}  ── {title} {"─"*(width-len(title)-5)}{NC}'

def _nav_sep() -> str: return _sep('Navigation',38)
def _back_item() -> str: return f'{DIM} {L["back"]}{NC}'

_SIG_RCS = {137, 138, 143}   # signal-killed fzf (SIGKILL/SIGTERM/SIGUSR1) → refresh
_ABORT_RCS = {1, 130}        # fzf quit/ESC → go back (return None without setting usr1_fired)

def fzf_run(items: List[str], header: str='', extra: list=None,
            with_nth: str=None, delimiter: str=None) -> Optional[str]:
    """Core fzf wrapper — returns stripped selection or None.
    Sets G.usr1_fired=True only when fzf was signal-killed (not on ESC/abort)."""
    args = ['fzf'] + FZF_BASE + [f'--header={header}']
    if extra: args += extra
    if with_nth: args += [f'--with-nth={with_nth}', f'--delimiter={delimiter or chr(9)}']
    inp = '\n'.join(items).encode()
    proc = subprocess.Popen(args, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    G.active_fzf_pid = proc.pid
    try:
        out, _ = proc.communicate(inp)
    except: out = b''
    finally: G.active_fzf_pid = None
    if proc.returncode in _SIG_RCS:
        G.usr1_fired = True
        return None
    if proc.returncode != 0: return None   # includes ESC (130) and no-match (1) — just go back
    return out.decode().strip()

def confirm(msg: str) -> bool:
    sel = fzf_run(
        [f'{GRN}{L["yes"]}{NC}', f'{RED}{L["no"]}{NC}'],
        header=f'{BLD}{msg}{NC}')
    return sel is not None and L['yes'] in strip_ansi(sel)

def pause(msg: str='Done.'):
    fzf_run([f'{GRN}[ OK ]{NC}  {DIM}{msg}{NC}'],
            header=f'{DIM}{L["ok_press"]}{NC}')

def finput(prompt: str) -> Optional[str]:
    """Returns typed text or None on ESC/signal-kill."""
    proc = subprocess.Popen(
        ['fzf'] + FZF_BASE + [
            f'--header={BLD}{prompt}{NC}\n{DIM}  {L["type_enter"]}{NC}',
            '--print-query',
        ],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    G.active_fzf_pid = proc.pid
    out, _ = proc.communicate(b'')
    G.active_fzf_pid = None
    # rc=0: selection made, rc=1: no match (just typed text), other: ESC/signal → None
    if proc.returncode not in (0, 1): return None
    lines = out.decode().splitlines()
    return lines[0] if lines else ''

def _read_password(prompt: str) -> str:
    """Read a password silently. Works in tmux, pty, and fallback stty mode."""
    try:
        import getpass as _gp
        # getpass uses /dev/tty directly — works in tmux
        return _gp.getpass(prompt)
    except Exception:
        pass
    # Fallback: manual stty -echo + readline (always works in tmux)
    sys.stdout.write(prompt); sys.stdout.flush()
    try:
        os.system('stty -echo 2>/dev/null')
        pw = sys.stdin.readline().rstrip('\n')
    finally:
        os.system('stty echo 2>/dev/null')
        print()
    return pw

def menu(header: str, *items) -> Optional[str]:
    """Simple menu with auto back-button. Returns clean selection or None."""
    rows = [f'{DIM} {x}{NC}' if '\033' not in x else x for x in items]
    rows += [_nav_sep(), _back_item()]
    while True:
        sel = fzf_run(rows, header=f'{BLD}── {header} ──{NC}')
        if sel is None:
            if G.usr1_fired: G.usr1_fired = False; continue
            return None
        if clean(sel) == L['back']: return None
        if clean(sel).startswith('──'): continue
        return clean(sel)

# ══════════════════════════════════════════════════════════════════════════════
# core/state.py — container state r/w
# ══════════════════════════════════════════════════════════════════════════════

def _state_file(cid: str) -> Path:
    return G.containers_dir/cid/'state.json'

def st(cid: str, key: str, default=None):
    try:
        with open(_state_file(cid)) as f: return json.load(f).get(key, default)
    except: return default

def set_st(cid: str, key: str, val):
    p = _state_file(cid)
    try: data = json.loads(p.read_text())
    except: data = {}
    data[key] = val
    p.write_text(json.dumps(data, indent=2))

def cname(cid: str) -> str:
    return st(cid,'name') or f'(unnamed-{cid})'

def cpath(cid: str) -> Optional[Path]:
    rel = st(cid,'install_path')
    return G.installations_dir/rel if rel else None

def sj(cid: str) -> dict:
    """Load service.json for cid."""
    try:
        return json.loads((G.containers_dir/cid/'service.json').read_text())
    except: return {}

def sj_get(cid: str, *keys, default=None):
    d = sj(cid)
    for k in keys:
        if not isinstance(d,dict): return default
        d = d.get(k)
    return d if d is not None else default

def rand_id() -> str:
    import random, string
    while True:
        i = ''.join(random.choices(string.ascii_lowercase+string.digits, k=8))
        if not (G.containers_dir/i).exists(): return i

def load_containers(force=False):
    G.CT_IDS, G.CT_NAMES = [], []
    if not G.containers_dir or not G.containers_dir.is_dir(): return
    for d in sorted(G.containers_dir.iterdir()):
        if not (d/'state.json').exists(): continue
        cid = d.name
        try: data = json.loads((d/'state.json').read_text())
        except: data = {}
        if data.get('hidden'): continue
        G.CT_IDS.append(cid); G.CT_NAMES.append(cname(cid))

def is_installing(cid: str) -> bool:
    return tmux_up(inst_sess(cid))

def log_path(cid: str, kind='start') -> Path:
    return G.logs_dir/f'{cname(cid)}-{cid}-{kind}.log'

def log_write(cid: str, kind: str, *lines: str):
    """Append lines to a capped log file (max 10MB). Matches shell _log_write."""
    if not G.logs_dir: return
    f = log_path(cid, kind)
    try:
        with open(f, 'a') as fh:
            for line in lines: fh.write(line + '\n')
        # Rotate if > 10MB
        sz = f.stat().st_size
        if sz > 10_485_760:
            keep = int(sz * 0.8)
            data = f.read_bytes()
            f.write_bytes(data[-keep:])
    except: pass

# ══════════════════════════════════════════════════════════════════════════════
# image/btrfs.py — btrfs snapshot helpers
# ══════════════════════════════════════════════════════════════════════════════

def snap_dir(cid: str) -> Path:
    """Backup snapshots live in Backup/<cname>/ — matches .sh _snap_dir exactly."""
    return G.backup_dir/cname(cid)

def rand_snap_id(sdir: Path) -> str:
    import random, string
    while True:
        i = ''.join(random.choices(string.ascii_lowercase+string.digits, k=8))
        if not (sdir/i).exists(): return i

def snap_meta_get(sdir: Path, snap_id: str, key: str) -> str:
    f = sdir/f'{snap_id}.meta'
    if not f.exists(): return ''
    for line in f.read_text().splitlines():
        if line.startswith(f'{key}='):
            return line.split('=',1)[1]
    return ''

def snap_meta_set(sdir: Path, snap_id: str, **kv):
    f = sdir/f'{snap_id}.meta'
    data = {}
    if f.exists():
        for line in f.read_text().splitlines():
            if '=' in line: k,v=line.split('=',1); data[k]=v
    data.update(kv)
    f.write_text('\n'.join(f'{k}={v}' for k,v in data.items()))

def btrfs_snap(src: Path, dst: Path, readonly=True) -> bool:
    args = ['btrfs','subvolume','snapshot']
    if readonly: args.append('-r')
    r = _run(args+[str(src),str(dst)], capture=True)
    return r.returncode == 0

def btrfs_delete(path: Path):
    _run(['btrfs','property','set',str(path),'ro','false'], capture=True)
    if _run(['btrfs','subvolume','delete',str(path)], capture=True).returncode != 0:
        shutil.rmtree(str(path), ignore_errors=True)

def rotate_and_snapshot(cid: str) -> bool:
    ip = cpath(cid)
    if not ip or not ip.is_dir(): return False
    sdir = snap_dir(cid); sdir.mkdir(parents=True, exist_ok=True)
    auto_ids = [f.stem for f in sdir.glob('*.meta')
                if snap_meta_get(sdir,f.stem,'type')=='auto' and (sdir/f.stem).is_dir()]
    while len(auto_ids) >= 2:
        btrfs_delete(sdir/auto_ids[0]); (sdir/f'{auto_ids[0]}.meta').unlink(missing_ok=True)
        auto_ids.pop(0)
    sid = rand_snap_id(sdir)
    if not btrfs_snap(ip, sdir/sid): return False
    snap_meta_set(sdir, sid, type='auto', ts=time.strftime('%Y-%m-%d %H:%M'))
    return True

def update_size_cache(cid: str):
    ip = cpath(cid)
    if not ip or not ip.is_dir(): return
    def _bg():
        r = _run(['du','-sb',str(ip)], capture=True)
        if r.returncode==0:
            gb = float(r.stdout.split()[0])/(1<<30)
            sc = G.cache_dir/'sd_size'/cid
            sc.parent.mkdir(parents=True, exist_ok=True)
            sc.write_text(f'{gb:.2f}')
    pass  # size cache update skipped (no background threads)

# ══════════════════════════════════════════════════════════════════════════════
# image/luks.py — LUKS encryption operations
# ══════════════════════════════════════════════════════════════════════════════

def luks_mapper(img: Path) -> str:
    return 'sd_'+re.sub(r'[^a-zA-Z0-9_]','',img.stem)

def luks_dev(img: Path) -> Path:
    return Path('/dev/mapper')/luks_mapper(img)

def luks_is_open(img: Path) -> bool:
    return luks_dev(img).is_block_device()

def img_is_luks(img: Path) -> bool:
    return _sudo('cryptsetup','isLuks',str(img)).returncode == 0

def luks_open(img: Path) -> bool:
    if luks_is_open(img): return True
    mapper = luks_mapper(img)
    for method in SD_UNLOCK_ORDER:
        if method == 'verified_system':
            r = subprocess.run(['sudo','-n','cryptsetup','open','--key-file=-',str(img),mapper],
                input=G.verification_cipher.encode(), capture_output=True)
            if r.returncode==0: return True
        elif method == 'default_keyword':
            r = subprocess.run(['sudo','-n','cryptsetup','open','--key-file=-',str(img),mapper],
                input=SD_DEFAULT_KEYWORD.encode(), capture_output=True)
            if r.returncode==0: return True
        elif method == 'prompt':
            for _ in range(3):
                os.system('clear')
                print(f'\n  {BLD}── simpleDocker ──{NC}')
                print(f'  {DIM}{img.name} is encrypted. Enter passphrase.{NC}\n')
                try:
                    pw = _read_password('  Passphrase: ')
                except (KeyboardInterrupt, EOFError):
                    pw = ''
                r = subprocess.run(['sudo','-n','cryptsetup','open','--key-file=-',str(img),mapper],
                    input=pw.encode(), capture_output=True)
                if r.returncode==0: os.system('clear'); return True
                print(f'  {RED}Wrong passphrase.{NC}')
    os.system('clear'); return False

def luks_close(img: Path):
    if luks_is_open(img): _sudo('cryptsetup','close',luks_mapper(img))

def enc_auto_unlock_enabled() -> bool:
    r = subprocess.run(['sudo','-n','cryptsetup','open','--test-passphrase','--key-file=-',str(G.img_path)],
        input=G.verification_cipher.encode(), capture_output=True)
    return r.returncode == 0

def enc_system_agnostic_enabled() -> bool:
    r = subprocess.run(['sudo','-n','cryptsetup','open','--test-passphrase','--key-slot','1','--key-file=-',str(G.img_path)],
        input=SD_DEFAULT_KEYWORD.encode(), capture_output=True)
    return r.returncode == 0

def enc_verified_dir() -> Path: return G.mnt_dir/'.sd/verified'
def enc_verified_id() -> str:
    """Stable per-machine ID. Tries machine-id, dbus machine-id, hostname — never a shared fallback."""
    for src in ['/etc/machine-id', '/var/lib/dbus/machine-id']:
        try:
            data = Path(src).read_text().strip()
            if data:
                return hashlib.sha256(data.encode()).hexdigest()[:8]
        except: pass
    # Fallback: hostname hash — unique per machine, stable
    try:
        hn = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
        if hn:
            return hashlib.sha256(hn.encode()).hexdigest()[:8]
    except: pass
    return 'unknown0'
def enc_verified_pass() -> str: return G.verification_cipher

def enc_authkey_path() -> Path: return G.mnt_dir/'.sd/auth.key'
def _authkey_bytes() -> bytes:
    """Read auth.key in Python (no sudo needed) — pipe via --key-file=- stdin."""
    return enc_authkey_path().read_bytes()
def enc_authkey_slot_file() -> Path: return G.mnt_dir/'.sd/auth.slot'
def enc_authkey_slot() -> str:
    f = enc_authkey_slot_file()
    return f.read_text().strip() if f.exists() else ''

def enc_authkey_valid() -> bool:
    kf = enc_authkey_path()
    if not kf.exists(): return False
    slot = enc_authkey_slot()
    args = ['sudo','-n','cryptsetup','open','--test-passphrase']
    if slot: args += ['--key-slot',slot]
    args += ['--key-file',str(kf),str(G.img_path)]
    return subprocess.run(args, capture_output=True).returncode == 0

def enc_free_slot() -> Optional[str]:
    r = _sudo('cryptsetup','luksDump',str(G.img_path), capture=True)
    used = set(re.findall(r'^\s+(\d+): luks2',r.stdout,re.M))
    for s in range(SD_LUKS_SLOT_MIN, SD_LUKS_SLOT_MAX+1):
        if str(s) not in used: return str(s)
    return None

def enc_slots_used() -> int:
    r = _sudo('cryptsetup','luksDump',str(G.img_path), capture=True)
    slots = re.findall(r'^\s+(\d+): luks2',r.stdout,re.M)
    return sum(1 for s in slots if SD_LUKS_SLOT_MIN <= int(s) <= SD_LUKS_SLOT_MAX)

def enc_authkey_create(auth_kf: Path) -> bool:
    """Create random 64-byte auth key in slot SD_AUTH_SLOT_A (2).
    auth_kf = file containing the EXISTING authorising key (read in Python, piped via stdin).
    New key is written to a /tmp file (root-readable) then moved to auth.key."""
    kf = enc_authkey_path()
    kf.parent.mkdir(parents=True, exist_ok=True)
    new_key = os.urandom(64)
    # Write new key to /tmp so sudo cryptsetup can read it
    tmp_new = Path(tempfile.mktemp(dir='/tmp', prefix='.sd_newk_'))
    try:
        with open(tmp_new, 'wb') as f: f.write(new_key)
        tmp_new.chmod(0o644)
        existing_key = auth_kf.read_bytes()
        r = subprocess.run(
            ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
             '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
             '--key-slot', str(SD_AUTH_SLOT_A), '--key-file', '-',
             str(G.img_path), str(tmp_new)],
            input=existing_key, capture_output=True)
        if r.returncode == 0:
            with open(kf, 'wb') as f: f.write(new_key)
            kf.chmod(0o600)
            enc_authkey_slot_file().write_text(str(SD_AUTH_SLOT_A))
        return r.returncode == 0
    finally:
        tmp_new.unlink(missing_ok=True)

def enc_authkey_rotate() -> tuple:
    """Rotate auth key between SD_AUTH_SLOT_A (2) and SD_AUTH_SLOT_B (3).
    Never touches passkey range (7-31). Keys passed via stdin — no sudo file-read issues.
    Returns (ok: bool, new_slot: str, error: str)."""
    old_kf   = enc_authkey_path()
    old_slot = enc_authkey_slot()
    if not old_kf.exists() or not old_slot:
        return False, '', 'auth.key or auth.slot missing'
    old_key = old_kf.read_bytes()
    # Verify old key still valid
    test = subprocess.run(
        ['sudo','-n','cryptsetup','open','--test-passphrase',
         '--key-file', '-', str(G.img_path)],
        input=old_key, capture_output=True)
    if test.returncode != 0:
        return False, '', 'existing auth.key is no longer valid'
    # Target slot: whichever of A/B is not currently in use
    new_slot = str(SD_AUTH_SLOT_B if str(old_slot) == str(SD_AUTH_SLOT_A) else SD_AUTH_SLOT_A)
    new_key  = os.urandom(64)
    tmp_new  = Path(tempfile.mktemp(dir='/tmp', prefix='.sd_rot_'))
    try:
        with open(tmp_new, 'wb') as f: f.write(new_key)
        tmp_new.chmod(0o644)
        # Step 1: add new key to target slot using old key via stdin
        r1 = subprocess.run(
            ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
             '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
             '--key-slot', new_slot, '--key-file', '-',
             str(G.img_path), str(tmp_new)],
            input=old_key, capture_output=True)
        if r1.returncode != 0:
            return False, '', f'luksAddKey to slot {new_slot} failed: {r1.stderr.decode().strip()}'
        # Step 2: kill old slot using new key via stdin
        r2 = subprocess.run(
            ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
             '--key-file', str(tmp_new), str(G.img_path), str(old_slot)],
            capture_output=True)
        if r2.returncode != 0:
            # Rollback
            subprocess.run(
                ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                 '--key-file', str(tmp_new), str(G.img_path), new_slot],
                capture_output=True)
            return False, '', f'luksKillSlot {old_slot} failed — rolled back'
        # Atomically update auth.key and auth.slot
        with open(old_kf, 'wb') as f: f.write(new_key)
        old_kf.chmod(0o600)
        enc_authkey_slot_file().write_text(new_slot)
        return True, new_slot, ''
    finally:
        tmp_new.unlink(missing_ok=True)

def enc_vs_write(vid: str, slot: str):
    vdir = enc_verified_dir(); vdir.mkdir(parents=True, exist_ok=True)
    hostname = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip() or vid
    (vdir/vid).write_text(f'{hostname}\n{slot}\n{G.verification_cipher}\n')

def enc_vs_slot(vid: str) -> str:
    f = enc_verified_dir()/vid
    if not f.exists(): return ''
    lines = f.read_text().splitlines()
    return lines[1] if len(lines) > 1 else ''

def enc_vs_hostname(vid: str) -> str:
    f = enc_verified_dir()/vid
    if not f.exists(): return vid
    return f.read_text().splitlines()[0]

def enc_vs_pass(vid: str) -> str:
    f = enc_verified_dir()/vid
    if not f.exists(): return ''
    lines = f.read_text().splitlines()
    return lines[2] if len(lines) > 2 else ''

def proxy_start(background=False) -> bool:
    return _proxy_start(background=background)

def proxy_stop():
    try: _proxy_stop()
    except: pass

# ══════════════════════════════════════════════════════════════════════════════
# image/mount.py — disk image setup, mount, create
# ══════════════════════════════════════════════════════════════════════════════

def validate_containers():
    """Clear stale installed=true entries for containers whose install path no longer exists.
    Matches shell _validate_containers — called once after mount."""
    if not G.containers_dir or not G.containers_dir.is_dir(): return
    for d in G.containers_dir.iterdir():
        sf = d/'state.json'
        if not sf.exists(): continue
        try: data = json.loads(sf.read_text())
        except: continue
        if not data.get('installed'): continue
        ip = G.installations_dir/data['install_path'] if data.get('install_path') else None
        if ip and ip.is_dir(): continue
        # Installation path missing — clear installed flag
        data['installed'] = False
        sf.write_text(json.dumps(data, indent=2))

def _cleanup_stale_installing():
    """Clear SD_INSTALLING if the tracked sdInst_ session has died.
    Matches shell _cleanup_stale_lock — called at top of each major menu render."""
    installing_cid = tmux_get('SD_INSTALLING')
    if installing_cid and not tmux_up(inst_sess(installing_cid)):
        tmux_set('SD_INSTALLING', '')

def set_img_dirs():
    G.blueprints_dir    = G.mnt_dir/'Blueprints'
    G.containers_dir    = G.mnt_dir/'Containers'
    G.installations_dir = G.mnt_dir/'Installations'
    G.backup_dir        = G.mnt_dir/'Backup'
    G.storage_dir       = G.mnt_dir/'Storage'
    G.ubuntu_dir        = G.mnt_dir/'Ubuntu'
    G.groups_dir        = G.mnt_dir/'Groups'
    G.logs_dir          = G.mnt_dir/'Logs'
    G.cache_dir         = G.mnt_dir/'.cache'
    for d in [G.blueprints_dir,G.containers_dir,G.installations_dir,
              G.backup_dir,G.storage_dir,G.ubuntu_dir,G.groups_dir,
              G.logs_dir,G.cache_dir/'gh_tag',G.cache_dir/'sd_size']:
        d.mkdir(parents=True, exist_ok=True)
    # chown dirs to current user (§2.11)
    _sudo('chown',f'{os.getuid()}:{os.getgid()}',
          str(G.blueprints_dir), str(G.containers_dir), str(G.installations_dir),
          str(G.backup_dir), str(G.storage_dir), str(G.ubuntu_dir),
          str(G.groups_dir), str(G.logs_dir), capture=True)
    # Clear stale installed=true entries (§2.5)
    validate_containers()
    # TODO-009: background ubuntu cache check on every mount/remount (matches shell _set_img_dirs)
    pass  # ub_cache_check skipped (no background threads)


def mount_img(img: Path) -> bool:
    mnt = G.sd_mnt_base/f'mnt_{img.stem}'
    if subprocess.run(['mountpoint','-q',str(mnt)], capture_output=True).returncode == 0:
        G.img_path = img; G.mnt_dir = mnt
        set_img_dirs(); return True
    mnt.mkdir(parents=True, exist_ok=True)
    if img_is_luks(img):
        if not luks_open(img): mnt.rmdir(); return False
        dev = str(luks_dev(img))
        r = _sudo('mount','-o','compress=zstd',dev,str(mnt))
    else:
        # Always attach via losetup explicitly so the kernel loop device carries
        # the image path as its backing file. Using -o loop would create a new
        # /dev/loopX that Dolphin/udisks picks up as a removable drive (bug 7).
        lo_r = _run(['sudo','-n','losetup','-j',str(img)], capture=True)
        lo = lo_r.stdout.split(':')[0].strip() if lo_r.returncode==0 and lo_r.stdout.strip() else ''
        if lo:
            # Reuse existing loop only if it's still valid
            if _run(['sudo','-n','losetup',lo], capture=True).returncode != 0:
                _sudo('losetup','-d',lo, capture=True); lo = ''
        if not lo:
            lo_r2 = _run(['sudo','-n','losetup','--find','--show',str(img)], capture=True)
            lo = lo_r2.stdout.strip()
        if not lo:
            pause(f'Could not attach loop device for {img.name}.'); return False
        r = _sudo('mount','-o','compress=zstd',lo,str(mnt))
    if r.returncode != 0:
        if img_is_luks(img): luks_close(img)
        try: mnt.rmdir()
        except: pass
        pause(f'Mount failed for {img.name}.\nIs it a valid BTRFS image? Check with: sudo mount -o loop {img}')
        return False
    _sudo('chown', f'{os.getuid()}:{os.getgid()}', str(mnt))  # mount point only, not inside image
    G.img_path = img; G.mnt_dir = mnt
    # TODO-017: rm -rf TMP_DIR before set_img_dirs (matches shell _mount_img first rmtree)
    if G.tmp_dir and G.tmp_dir.exists():
        try: shutil.rmtree(str(G.tmp_dir), ignore_errors=True)
        except: pass
    set_img_dirs()
    # TODO-017: rm -rf TMP_DIR again after set_img_dirs, then recreate clean (matches shell second rmtree)
    G.tmp_dir = mnt/'.tmp'
    try: shutil.rmtree(str(G.tmp_dir), ignore_errors=True)
    except: pass
    G.tmp_dir.mkdir(parents=True, exist_ok=True)
    (mnt/'.sd').mkdir(exist_ok=True)
    # Clear stale log files on mount — matches shell _mount_img
    if G.logs_dir and G.logs_dir.is_dir():
        for lf in G.logs_dir.glob('*.log'):
            try: lf.unlink()
            except: pass
    netns_setup(mnt)
    # Auto-create auth.key on first mount if LUKS image doesn't have one yet

    proxy_cfg = mnt/'.sd/proxy.json'
    if proxy_cfg.exists():
        try:
            if json.loads(proxy_cfg.read_text()).get('autostart'):
                proxy_start(background=True)
        except: pass
    return True

def unmount_img():
    if not G.mnt_dir: return
    try: proxy_stop()
    except: pass
    try: netns_teardown(G.mnt_dir)
    except: pass
    # Collect loop devices ONCE before any unmounting
    loops = []
    if G.img_path:
        lo_r = _run(['sudo','-n','losetup','-j',str(G.img_path)], capture=True)
        loops = [l.split(':')[0].strip() for l in lo_r.stdout.splitlines() if l.strip()]
    # Unmount all submounts + main mount with one lazy umount pass
    r = _run(['findmnt','-n','-o','TARGET','-R',str(G.mnt_dir)], capture=True)
    submounts = sorted([l for l in r.stdout.splitlines()
                        if l.strip() and l.strip() != str(G.mnt_dir)], key=len, reverse=True)
    for sm in submounts: _sudo('umount','-lf',sm, capture=True)
    _sudo('umount','-lf',str(G.mnt_dir), capture=True)
    try: G.mnt_dir.rmdir()
    except: pass
    # Close LUKS mapper directly by name
    if G.img_path:
        lm = luks_mapper(G.img_path)
        if Path(f'/dev/mapper/{lm}').is_block_device():
            _sudo('cryptsetup','close',lm, capture=True)
    # Detach all loop devices
    for lo in loops:
        _sudo('losetup','-d',lo, capture=True)
    G.img_path = G.mnt_dir = None
    G.tmp_dir = G.sd_mnt_base/'.tmp'
    G.tmp_dir.mkdir(parents=True, exist_ok=True)

def create_img(name: str, size_gb: int, dest_dir: Path) -> bool:
    """Match shell _create_img exactly: always LUKS, full key hierarchy, btrfs subvolumes."""
    img = dest_dir/f'{name}.img'
    if img.exists(): pause(f'Already exists: {img}'); return False
    # Allocate sparse file
    if _run(['truncate','-s',f'{size_gb}G',str(img)]).returncode != 0:
        pause('Failed to allocate image file.'); return False
    # luksFormat with SD_VERIFICATION_CIPHER on slot 31 (temporary bootstrap slot)
    r = subprocess.run(
        ['sudo','-n','cryptsetup','luksFormat','--type','luks2','--batch-mode',
         '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
         '--key-slot','31','--key-file=-',str(img)],
        input=G.verification_cipher.encode(), capture_output=True)
    if r.returncode != 0:
        img.unlink(missing_ok=True); pause('luksFormat failed.'); return False
    # Open with bootstrap key
    mapper = luks_mapper(img)
    r = subprocess.run(
        ['sudo','-n','cryptsetup','open','--key-file=-',str(img),mapper],
        input=G.verification_cipher.encode(), capture_output=True)
    if r.returncode != 0:
        img.unlink(missing_ok=True); pause('LUKS open failed.'); return False
    # Format btrfs
    if _sudo('mkfs.btrfs','-q','-f',f'/dev/mapper/{mapper}').returncode != 0:
        _sudo('cryptsetup','close',mapper); img.unlink(missing_ok=True)
        pause('mkfs.btrfs failed.'); return False
    # Mount
    mnt = G.sd_mnt_base/f'mnt_{img.stem}'
    mnt.mkdir(parents=True, exist_ok=True)
    if _sudo('mount','-o','compress=zstd',f'/dev/mapper/{mapper}',str(mnt)).returncode != 0:
        _sudo('cryptsetup','close',mapper); img.unlink(missing_ok=True)
        try: mnt.rmdir()
        except: pass
        pause('Mount failed.'); return False
    _sudo('chown', f'{os.getuid()}:{os.getgid()}', str(mnt))
    G.img_path = img; G.mnt_dir = mnt
    G.tmp_dir = mnt/'.tmp'
    G.tmp_dir.mkdir(parents=True, exist_ok=True)
    (mnt/'.sd').mkdir(exist_ok=True)
    # ── Key hierarchy (matches shell exactly) ──────────────────────────────
    # 1. Create random auth keyfile → slot 0
    auth_tmp = G.tmp_dir/'.sd_imgauth_tmp'
    auth_tmp.write_text(G.verification_cipher)
    if not enc_authkey_create(auth_tmp):
        auth_tmp.unlink(missing_ok=True)
        pause('Auth keyfile creation failed.'); return False
    # 2. Kill bootstrap slot 31
    subprocess.run(
        ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
         '--key-file','-',str(img),'31'],
        input=_authkey_bytes(), capture_output=True)
    auth_tmp.unlink(missing_ok=True)
    # 3. Add default keyword → slot 1
    # existing key via stdin (--key-file=-), new key written to /tmp (root-readable)
    _ak = _authkey_bytes()
    _tmp_dk = __import__('tempfile').mktemp(dir='/tmp', prefix='.sd_k_')
    try:
        open(_tmp_dk,'w').write(SD_DEFAULT_KEYWORD); __import__('os').chmod(_tmp_dk,0o644)
        subprocess.run(
            ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
             '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
             '--key-slot','1','--key-file','-',str(img),_tmp_dk],
            input=_ak, capture_output=True)
    finally: __import__('pathlib').Path(_tmp_dk).unlink(missing_ok=True)
    # 4. Add verified-system key → free slot
    free_slot = enc_free_slot()
    if free_slot:
        _tmp_vs = __import__('tempfile').mktemp(dir='/tmp', prefix='.sd_k_')
        try:
            open(_tmp_vs,'w').write(G.verification_cipher); __import__('os').chmod(_tmp_vs,0o644)
            r = subprocess.run(
                ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                 '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                 '--key-slot',free_slot,'--key-file','-',str(img),_tmp_vs],
                input=_ak, capture_output=True)
            if r.returncode == 0: enc_vs_write(enc_verified_id(), free_slot)
        finally: __import__('pathlib').Path(_tmp_vs).unlink(missing_ok=True)
    # ── BTRFS subvolumes ───────────────────────────────────────────────────
    for sv in ['Blueprints','Containers','Installations','Backup','Storage','Ubuntu','Groups']:
        _sudo('btrfs','subvolume','create',str(mnt/sv), capture=True)
        _sudo('chown', f'{os.getuid()}:{os.getgid()}', str(mnt/sv), capture=True)
    set_img_dirs()
    netns_setup(mnt)
    # TODO-019: shell _create_img does NOT call save_known_img — removed to match
    pause(f'Image created: {img}')
    return True

def images_list_file() -> Path:
    return G.root_dir/'images.list'

def load_known_imgs() -> List[Path]:
    f = images_list_file()
    if not f.exists(): return []
    return [Path(l.strip()) for l in f.read_text().splitlines() if l.strip() and Path(l.strip()).exists()]

def save_known_img(img: Path):
    f = images_list_file(); f.parent.mkdir(parents=True, exist_ok=True)
    existing = load_known_imgs()
    if img not in existing:
        with open(f,'a') as fh: fh.write(str(img)+'\n')

def detect_imgs() -> List[Path]:
    """Find .img files under HOME, skip hidden dirs, no validation."""
    seen: set = set()
    found: List[Path] = []
    try:
        r = subprocess.run(
            ['find', str(Path.home()), '-maxdepth', '4',
             '-not', '-path', '*/.*',
             '-name', '*.img', '-type', 'f'],
            capture_output=True, text=True, timeout=8)
        for line in r.stdout.splitlines():
            p = Path(line.strip())
            if p.exists() and str(p) not in seen:
                found.append(p); seen.add(str(p))
    except Exception:
        pass
    return found

def _fzf_browse(start: Path, only_dirs: bool) -> Optional[Path]:
    cur = start.expanduser().resolve()
    while True:
        try: children = sorted(cur.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        except PermissionError: cur = cur.parent; continue
        visible = [p for p in children if not p.name.startswith('.')]
        hidden  = [p for p in children if p.name.startswith('.')]
        entries = []
        _home = Path.home()
        _outside_home = not str(cur).startswith(str(_home))
        entries.append(_sep('General'))
        if only_dirs: entries.append(f' {GRN}✓  Select here{NC}')
        if _outside_home: entries.append(f' {DIM}⌂  Return to home{NC}')
        if cur.parent != cur: entries.append(f' {DIM}↑  parent{NC}')
        entries.append(_sep('Folders & files'))
        for p in visible:
            if p.is_dir(): entries.append(f' {DIM}◈  {p.name}/{NC}')
            elif not only_dirs: entries.append(f' {DIM}◈  {p.name}{NC}')
        if hidden:
            entries.append(_sep('Hidden (type . to filter)'))
            for p in hidden:
                if p.is_dir(): entries.append(f' {DIM}◈  {p.name}/{NC}')
                elif not only_dirs: entries.append(f' {DIM}◈  {p.name}{NC}')
        hdr = (f'{BLD}── {"Select directory" if only_dirs else "Select file"} ──{NC}\n'
               f'{DIM}  {cur}{NC}')
        sel = fzf_run(entries, header=hdr)
        if sel is None: return None
        sc = strip_ansi(sel).strip()
        if sc.startswith('✓'):
            if not str(cur).startswith(str(Path.home())):
                if not confirm(f'Use folder outside home?\n\n  {cur}'): return None
            return cur
        if sc.startswith('⌂'): cur = Path.home(); continue
        if sc.startswith('↑'): cur = cur.parent; continue
        if sc.startswith('──'): continue
        name = sc.lstrip('◈ ').rstrip('/')
        candidate = cur / name
        if candidate.is_dir(): cur = candidate; continue
        if not only_dirs and candidate.is_file(): return candidate

def pick_dir() -> Optional[Path]:
    return _fzf_browse(Path.home(), only_dirs=True)

def pick_file() -> Optional[Path]:
    return _fzf_browse(Path.home(), only_dirs=False)

def setup_image():
    # Already mounted
    if G.mnt_dir and subprocess.run(['mountpoint','-q',str(G.mnt_dir)], capture_output=True).returncode == 0:
        set_img_dirs(); return
    # Auto-mount DEFAULT_IMG if set
    if DEFAULT_IMG and Path(DEFAULT_IMG).exists():
        mount_img(Path(DEFAULT_IMG)); return
    while True:
        detected = detect_imgs()
        # Build lines exactly as shell does:
        # 1. Select existing image
        # 2. Create new image
        # 3. (optional) "── Detected images ──" separator + detected entries
        lines = []
        lines.append(f' {CYN}◈{NC}  {L["img_select"]}')
        lines.append(f' {CYN}◈{NC}  {L["img_create"]}')
        if detected:
            lines.append(f'{DIM}  ── Detected images ──────────────────{NC}')
            for di in detected:
                lines.append(f' {CYN}◈{NC}  {di.name}  {DIM}({di.parent}){NC}')
        choice = fzf_run(lines,
            header=f'{BLD}── simpleDocker ──{NC}',
            extra=['--height=40%','--reverse','--border=rounded','--margin=1,2','--no-info'])
        if choice is None:
            if G.usr1_fired: G.usr1_fired = False; continue
            os.system('clear'); _force_quit()
        sc = clean(choice)
        if L['img_select'] in sc:
            f = pick_file()
            if f and f.suffix == '.img':
                if mount_img(f): save_known_img(f); return
        elif L['img_create'] in sc:
            v = None
            while not v:
                v = finput(f'Image name (e.g. simpleDocker):\n\n  {RED}⚠  WARNING:{NC}  The name cannot be changed after creation.')
                if v is None: break  # ESC
                name = re.sub(r'[^a-zA-Z0-9_\-]', '', v)
                if not name: pause('Please enter a valid name (letters, numbers, _ -)'); v = None
            if v is None: continue
            sv = finput('Max size in GB (sparse — only uses actual disk space, leave blank for 50 GB):')
            if sv is None: continue
            sz = int(sv) if sv and sv.isdigit() else 50
            d = pick_dir()
            if not d: pause('No directory selected.'); continue
            if create_img(name, sz, d): return
        else:
            for di in detected:
                if di.name in sc:
                    if mount_img(di): return
                    break


# ══════════════════════════════════════════════════════════════════════════════
# container/network.py — network namespace, port exposure
# ══════════════════════════════════════════════════════════════════════════════

def netns_name(mnt: Path=None) -> str:
    s = str(mnt or G.mnt_dir)
    return 'sd_'+hashlib.md5(s.encode()).hexdigest()[:8]

def netns_idx(mnt: Path=None) -> int:
    s = str(mnt or G.mnt_dir)
    return int(hashlib.md5(s.encode()).hexdigest()[:2],16) % 254

def netns_ct_ip(cid: str, mnt: Path=None) -> str:
    idx = netns_idx(mnt)
    last = (int(hashlib.md5(cid.encode()).hexdigest()[:2],16) % 252)+2
    return f'10.88.{idx}.{last}'

def netns_hosts(mnt: Path=None) -> Path:
    return (mnt or G.mnt_dir)/'.sd/.netns_hosts'

def netns_setup(mnt: Path=None):
    mnt = mnt or G.mnt_dir
    ns = netns_name(mnt); idx = netns_idx(mnt)
    subnet = f'10.88.{idx}'
    br=f'sd-br{idx}'; vh=f'sd-h{idx}'; vns=f'sd-ns{idx}'
    r = _run(['sudo','-n','ip','netns','list'], capture=True)
    if ns in r.stdout: return
    # Pre-cleanup stale interfaces from previous crashed session
    _sudo('ip','link','del',vh, capture=True)
    _sudo('ip','netns','del',ns, capture=True)
    for cmd in [
        ['ip','netns','add',ns],
        ['ip','link','add',vh,'type','veth','peer','name',vns],
        ['ip','link','set',vns,'netns',ns],
        ['ip','netns','exec',ns,'ip','link','add',br,'type','bridge'],
        ['ip','netns','exec',ns,'ip','link','set',vns,'master',br],
        ['ip','netns','exec',ns,'ip','addr','add',f'{subnet}.1/24','dev',br],
        ['ip','netns','exec',ns,'ip','link','set',br,'up'],
        ['ip','netns','exec',ns,'ip','link','set',vns,'up'],
        ['ip','netns','exec',ns,'ip','link','set','lo','up'],
        ['ip','addr','add',f'{subnet}.254/24','dev',vh],
        ['ip','link','set',vh,'up'],
    ]: _sudo(*cmd)
    # Enable ip_forward inside namespace (§2.12)
    _sudo('ip','netns','exec',ns,'sysctl','-qw','net.ipv4.ip_forward=1', capture=True)
    # Write metadata files — matches shell _netns_setup
    sd_dir = mnt/'.sd'
    sd_dir.mkdir(exist_ok=True)
    try: (sd_dir/'.netns_name').write_text(ns)
    except: pass
    try: (sd_dir/'.netns_idx').write_text(str(idx))
    except: pass

def netns_ct_add(cid: str, name: str, mnt: Path=None):
    mnt = mnt or G.mnt_dir; ns=netns_name(mnt); idx=netns_idx(mnt)
    ip=netns_ct_ip(cid,mnt); br=f'sd-br{idx}'
    vh=f'sd-c{idx}-{cid[:6]}'; vns=f'sd-i{idx}-{cid[:6]}'
    for cmd in [
        ['ip','link','add',vh,'type','veth','peer','name',vns],
        ['ip','link','set',vns,'netns',ns],
        ['ip','netns','exec',ns,'ip','link','set',vns,'master',br],
        ['ip','netns','exec',ns,'ip','addr','add',f'{ip}/24','dev',vns],
        ['ip','netns','exec',ns,'ip','link','set',vns,'up'],
        ['ip','link','set',vh,'up'],
    ]: _sudo(*cmd)
    hf=netns_hosts(mnt)
    lines=[l for l in (hf.read_text().splitlines() if hf.exists() else []) if not l.endswith(f' {name}')]
    lines.append(f'{ip} {name}')
    hf.parent.mkdir(parents=True,exist_ok=True); hf.write_text('\n'.join(lines)+'\n')

def netns_ct_del(cid: str, name: str, mnt: Path=None):
    mnt=mnt or G.mnt_dir; idx=netns_idx(mnt)
    _sudo('ip','link','del',f'sd-c{idx}-{cid[:6]}')
    hf=netns_hosts(mnt)
    if hf.exists():
        lines=[l for l in hf.read_text().splitlines() if not l.endswith(f' {name}')]
        hf.write_text('\n'.join(lines)+'\n')

def netns_teardown(mnt: Path=None):
    mnt = mnt or G.mnt_dir
    if not mnt: return
    ns = netns_name(mnt); idx = netns_idx(mnt)
    _sudo('ip','link','del',f'sd-h{idx}', capture=True)
    _sudo('ip','netns','del',ns, capture=True)
    # Clean up metadata files — matches shell _netns_teardown exactly
    for fname in ('.netns_name', '.netns_idx', '.netns_hosts'):
        try: (mnt/'.sd'/fname).unlink(missing_ok=True)
        except: pass

def exposure_file(cid: str) -> Path: return G.containers_dir/cid/'exposure'
def exposure_get(cid: str) -> str:
    v=(exposure_file(cid).read_text().strip() if exposure_file(cid).exists() else '')
    return v if v in ('isolated','localhost','public') else 'localhost'
def exposure_set(cid: str, mode: str): exposure_file(cid).write_text(mode)
def exposure_next(cid: str) -> str:
    return {'isolated':'localhost','localhost':'public','public':'isolated'}.get(exposure_get(cid),'localhost')
def exposure_label(mode: str) -> str:
    return {
        'isolated': f'{DIM}⬤  isolated{NC}',
        'localhost':f'{YLW}⬤  localhost{NC}',
        'public':   f'{GRN}⬤  public{NC}',
    }.get(mode, f'{YLW}⬤  localhost{NC}')

def exposure_flush(cid: str, port: str, ip: str):
    if not port or port=='0': return
    for cmd in [
        ['iptables','-D','INPUT','-p','tcp','--dport',port,'-j','DROP'],
        ['iptables','-D','OUTPUT','-p','tcp','-d',f'{ip}/32','--dport',port,'-j','DROP'],
        ['iptables','-D','FORWARD','-d',f'{ip}/32','-p','tcp','--dport',port,'-j','DROP'],
        ['iptables','-t','nat','-D','PREROUTING','-p','tcp','--dport',port,'-j','DNAT','--to-destination',f'{ip}:{port}'],
        ['iptables','-t','nat','-D','POSTROUTING','-d',f'{ip}/32','-p','tcp','--dport',port,'-j','MASQUERADE'],
        ['iptables','-D','FORWARD','-d',f'{ip}/32','-p','tcp','--dport',port,'-j','ACCEPT'],
        ['iptables','-D','FORWARD','-s',f'{ip}/32','-p','tcp','--sport',port,'-j','ACCEPT'],
    ]: _sudo(*cmd)

def exposure_apply(cid: str):
    mode=exposure_get(cid)
    port=sj_get(cid,'meta','port',default=''); ep=sj_get(cid,'environment','PORT',default='')
    if ep: port=ep
    if not port or port=='0': return
    ip=netns_ct_ip(cid)
    exposure_flush(cid,str(port),ip)
    if mode=='isolated':
        _sudo('iptables','-I','INPUT','-p','tcp','--dport',str(port),'-j','DROP')
        _sudo('iptables','-I','OUTPUT','-p','tcp','-d',f'{ip}/32','--dport',str(port),'-j','DROP')
        _sudo('iptables','-I','FORWARD','-d',f'{ip}/32','-p','tcp','--dport',str(port),'-j','DROP')
    elif mode=='localhost':
        _sudo('sysctl','-qw','net.ipv4.ip_forward=1')
        _sudo('iptables','-I','FORWARD','-d',f'{ip}/32','-p','tcp','--dport',str(port),'-j','ACCEPT')
        _sudo('iptables','-I','FORWARD','-s',f'{ip}/32','-p','tcp','--sport',str(port),'-j','ACCEPT')
    elif mode=='public':
        _sudo('sysctl','-qw','net.ipv4.ip_forward=1')
        _sudo('iptables','-t','nat','-A','PREROUTING','-p','tcp','--dport',str(port),
              '-j','DNAT','--to-destination',f'{ip}:{port}')
        _sudo('iptables','-t','nat','-A','POSTROUTING','-d',f'{ip}/32','-p','tcp','--dport',str(port),'-j','MASQUERADE')
        _sudo('iptables','-I','FORWARD','-d',f'{ip}/32','-p','tcp','--dport',str(port),'-j','ACCEPT')
        _sudo('iptables','-I','FORWARD','-s',f'{ip}/32','-p','tcp','--sport',str(port),'-j','ACCEPT')

# ══════════════════════════════════════════════════════════════════════════════
# container/blueprint.py — parse, compile, validate
# ══════════════════════════════════════════════════════════════════════════════

_CODE_SECS = {'install','update','start','build'}
_LIST_SECS = {'deps','storage','dirs','pip','npm'}

def bp_parse(text: str) -> dict:
    """Parse .toml blueprint source into a Python dict."""
    out: dict = {'meta':{},'environment':{},'storage':[],'deps':[],'dirs':[],'pip':[],'npm':[],
                 'git':[],'build':'','install':'','update':'','start':'','crons':[],'actions':[]}
    sec = None
    _blk = {}        # current [@block] accumulator for cron/actions
    _cmd_indent = '' # indent prefix when reading multiline cmd
    _reading_cmd = False
    for line in text.splitlines():
        raw = line.rstrip()
        stripped = raw.strip()
        # section header
        m = re.match(r'^\[([a-zA-Z_/]+)\]$', stripped)
        if m:
            # flush any open block
            if _blk and sec == 'jobs':
                _flush_block(out, _blk)
                _blk = {}; _reading_cmd = False
            sec = m.group(1).lower()
            if sec in ('container','/container'): sec = None
            continue
        if sec is None: continue
        if stripped.startswith('#') and sec not in _CODE_SECS: continue
        # multiline cmd continuation
        if _reading_cmd:
            if raw.startswith(_cmd_indent) and raw.strip():
                _blk['cmd'] = _blk.get('cmd','') + raw.strip() + '\n'
                continue
            else:
                _blk['cmd'] = _blk.get('cmd','').rstrip('\n')
                _reading_cmd = False
                # fall through to process current line normally
        if sec in _CODE_SECS:
            out[sec] = out.get(sec,'') + line + '\n'
        elif sec in _LIST_SECS:
            parts = [p.strip() for part in stripped.split(',') for p in [part.strip()] if p and not p.startswith('#')]
            out.setdefault(sec,[]).extend(p for p in parts if p)
        elif sec == 'env':
            if '=' in stripped and not stripped.startswith('#'):
                k,_,v = stripped.partition('=')
                out['environment'][k.strip()] = v.strip()
        elif sec == 'meta':
            if '=' in stripped and not stripped.startswith('#'):
                k,_,v = stripped.partition('=')
                k=k.strip(); v=v.strip()
                if v.lower()=='true': v=True
                elif v.lower()=='false': v=False
                elif v.isdigit(): v=int(v)
                out['meta'][k] = v
        elif sec == 'git':
            if stripped and not stripped.startswith('#'):
                out['git'].append(_parse_git_line(stripped))
        elif sec == 'jobs':
            bm = re.match(r'^\[@([^\]]+)\]$', stripped)
            if bm:
                if _blk: _flush_block(out, _blk)
                _blk = {'_type': bm.group(1).lower()}; _reading_cmd = False
                continue
            if not _blk: continue
            if '=' in stripped and not stripped.startswith('#'):
                k, _, v = stripped.partition('=')
                k = k.strip(); v = v.strip()
                if k == 'cmd':
                    if v:
                        _blk['cmd'] = v
                    else:
                        _cmd_indent = raw[:len(raw)-len(raw.lstrip())] + '  '
                        _blk['cmd'] = ''
                        _reading_cmd = True
                else:
                    _blk[k] = v
    # flush last open block
    if _blk and sec == 'jobs':
        _flush_block(out, _blk)
    # strip trailing whitespace from code blocks
    for s in _CODE_SECS: out[s] = out.get(s,'').rstrip()
    return out

def _parse_git_line(line: str) -> dict:
    line = re.sub(r'#.*','',line).strip()
    m = re.match(r'^([a-zA-Z0-9_.\-]+/[a-zA-Z0-9_.\-]+)(.*)',line)
    if not m: return {}
    repo,rest = m.group(1), m.group(2).strip()
    source = bool(re.search(r'\bsource\b',rest))
    hints=[]; asset_type=''
    for bv in re.findall(r'\[([^\]]+)\]',rest):
        if bv.upper() in ('BIN','ZIP','TAR'): asset_type=bv.upper()
        else: hints.append(bv)
    dest_m = re.search(r'→\s*([^\s]+)',rest)
    dest = dest_m.group(1).rstrip('/') if dest_m else ''
    return {'repo':repo,'hint':hints[0] if hints else '','type':asset_type,
            'dest':dest,'source':source}

def _flush_block(out: dict, blk: dict):
    """Flush a completed [@type] block into out['crons'] or out['actions']."""
    typ = blk.get('_type','')
    name = blk.get('name','').strip('\"\' ')
    cmd  = blk.get('cmd','').strip()
    if typ == 'cron':
        interval = blk.get('schedule','').strip('\"\' ')
        if not interval or not name or not cmd: return
        log  = blk.get('log','').strip('\"\' ')
        flags_parts = []
        if blk.get('autostart','').strip('\"\' ').lower() in ('true','1','yes'): flags_parts.append('--autostart')
        if blk.get('unjailed','').strip('\"\' ').lower() in ('true','1','yes'): flags_parts.append('--unjailed')
        if blk.get('sudo','').strip('\"\' ').lower() in ('true','1','yes'): flags_parts.append('--sudo')
        out['crons'].append({'interval':interval,'name':name,'cmd':cmd,'flags':' '.join(flags_parts),'log':log})
    elif typ == 'action':
        if not name or not cmd: return
        out['actions'].append({'label':name,'dsl':cmd})

def _parse_action_line(line: str) -> Optional[dict]:
    """Legacy single-line action: Label | cmd"""
    if not line or line.startswith('#'): return None
    if '|' not in line: return None
    label, _, dsl = line.partition('|')
    label=label.strip(); dsl=dsl.strip()
    if not label: return None
    return {'label':label,'dsl':dsl}

def bp_validate(parsed: dict) -> List[str]:
    errs=[]
    meta=parsed.get('meta',{})
    if not meta.get('name'):
        errs.append("  [meta]  'name' is required")
    if not meta.get('entrypoint') and not parsed.get('start'):
        errs.append("  [meta]  'entrypoint' or a [start] block is required")
    port=re.sub(r'\s','',str(meta.get('port','')))
    if port and not re.match(r'^\d+$',port):
        errs.append(f"  [meta]  'port' must be a number, got: {port}")
    storage=parsed.get('storage','')
    if storage:
        st_lines=[l.split('#')[0].strip() for l in str(storage).replace(',',' ').split() if l.split('#')[0].strip()]
        if st_lines and not meta.get('storage_type'):
            errs.append("  [storage]  'storage_type' in [meta] is required when [storage] paths are declared")
    git_block=parsed.get('git','')
    if git_block:
        for gln,gl in enumerate(str(git_block).splitlines(),1):
            gl=gl.split('#')[0].strip()
            if not gl: continue
            m=re.match(r'^[a-zA-Z_][a-zA-Z0-9_-]*\s*=\s*(.*)',gl)
            if m: gl=m.group(1).strip()
            repo=gl.split()[0] if gl.split() else ''
            if repo and not re.match(r'^[a-zA-Z0-9_.\-]+/[a-zA-Z0-9_.\-]+$',repo):
                errs.append(f"  [git]  line {gln}: invalid repo format \'{repo}\' (expected org/repo)")
    dirs_block=parsed.get('dirs','')
    if dirs_block:
        opens=str(dirs_block).count('('); closes=str(dirs_block).count(')')
        if opens!=closes:
            errs.append(f"  [dirs]  unbalanced parentheses ({opens} open, {closes} close)")
    for i,act in enumerate(parsed.get('actions',[])):
        lbl=act.get('label',''); dsl=act.get('dsl',act.get('script',''))
        if not lbl: errs.append(f"  [actions]  action {i+1} has an empty label")
        if '|' in dsl:
            segs=[s.strip() for s in dsl.split('|')]
            has_prompt=any(s.startswith('prompt:') for s in segs)
            has_select=any(s.startswith('select:') for s in segs)
            if '{input}' in dsl and not has_prompt:
                errs.append(f"  [actions]  \'{lbl}\': uses {{input}} but no \'prompt:\' segment")
            if '{selection}' in dsl and not has_select:
                errs.append(f"  [actions]  \'{lbl}\': uses {{selection}} but no \'select:\' segment")
    if parsed.get('pip'):
        deps=str(parsed.get('deps','')).replace(',',' ')
        if not re.search(r'\bpython3\b',deps):
            errs.append("  [pip]  requires 'python3' in [deps]")
    return errs

def bp_compile(src_path: Path, cid: str) -> bool:
    """Parse src → write service.json. If src is already valid JSON, copy directly.
    Writes sha256 hash to service.src.hash — matches shell _compile_service."""
    if not src_path.exists(): return False
    dst = G.containers_dir/cid/'service.json'
    text = src_path.read_text()
    # F6: if src is already valid JSON, copy directly (previously compiled)
    try:
        json.loads(text)
        dst.write_text(text)
        _src_write_hash(src_path)
        return True
    except json.JSONDecodeError:
        pass
    parsed = bp_parse(text)
    errs = bp_validate(parsed)
    if errs: return False
    dst.write_text(json.dumps(parsed, indent=2))
    _src_write_hash(src_path)
    return True

def _src_write_hash(src_path: Path):
    try:
        h = hashlib.sha256(src_path.read_bytes()).hexdigest()
        (src_path.parent/(src_path.name+'.hash')).write_text(h)
    except: pass

def _ensure_src(cid: str):
    """If service.src missing but service.json exists, bootstrap src from json — F7."""
    src = G.containers_dir/cid/'service.src'
    if src.exists(): return
    sj = G.containers_dir/cid/'service.json'
    if sj.exists():
        shutil.copy(str(sj), str(src))
        _src_write_hash(src)


def bp_template() -> str:
    return '''
[meta]
name = my-service
version = 1.0.0
dialogue = Short label shown in the container list
description = Longer notes about this service.
port = 8080
storage_type = my-service
entrypoint = bin/my-service --port 8080
# log = logs/service.log # log file shown in View log (default: start.log)
# health = [true | false] # enable health check ping on port
# gpu = [nvidia | amd] # pass GPU into container
# cap_drop = [true | false] # drop Linux capabilities (default: true)
# seccomp = [true | false] # apply seccomp profile (default: true)

[env]
PORT = 8080
HOST = 127.0.0.1
DATA_DIR = data
# API_KEY = secret

[storage]
# Paths inside CONTAINER_ROOT that persist across reinstalls
data, logs

[deps]
# apt packages installed into the container chroot
curl, tar

[dirs]
# Directories created automatically inside CONTAINER_ROOT
# Supports nested: lib(subdir1, subdir2)
bin, data, logs

[pip]
# Python packages installed into CONTAINER_ROOT/venv
# Supports version pins: requests==2.31.0 or bare: requests

[npm]
# Node packages installed into CONTAINER_ROOT/node_modules
# e.g. express, lodash

[git]
# org/repo → auto-detect archive/binary, extract to CONTAINER_ROOT
# org/repo [asset-name.tar.zst] → match exact release asset filename, then extract
# org/repo [asset-name][TYPE] → match asset and filter by type before selecting
# org/repo → subdir/ → extract to subdir
# org/repo source → git clone to src/
# TYPE tokens: [BIN] raw binary [ZIP] .zip [TAR] .tar.gz/.tar.zst/etc (default: auto/ZIP)

[build]
# Compile steps — run once during install, after git source clone
# cd src && make

[install]
# Extra setup steps run once after deps/dirs/git

[update]
# Steps run when manually triggering Update from the container menu

[start]
# Script run to start the container (runs inside namespace+chroot)
# $root = install path, $out/path = host path, $out~/path = host home path

[jobs]
# [@cron]   schedule=5m  name=ping  log=logs/x.log  autostart=true
#           cmd = printf "ping\n"
#
# [@action] name=Show logs
#           cmd = tail -f logs/service.log
'''

def expand_dirs(dirs_list: list) -> List[str]:
    """Expand 'lib(sub1,sub2)' → ['lib','lib/sub1','lib/sub2']"""
    result=[]
    for entry in dirs_list:
        m=re.match(r'^(\w[\w/\-]*)\(([^)]+)\)$',entry.strip())
        if m:
            parent=m.group(1)
            result.append(parent)
            for sub in m.group(2).split(','):
                result.append(f'{parent}/{sub.strip()}')
        else:
            result.append(entry.strip())
    return result

# ══════════════════════════════════════════════════════════════════════════════
# container/lifecycle.py — start, stop, install, run_job
# ══════════════════════════════════════════════════════════════════════════════

def health_check(cid: str) -> bool:
    d=sj(cid); health=d.get('meta',{}).get('health',False)
    if not health: return False
    port=d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT')
    if not port or str(port)=='0': return False
    r=_run(['nc','-z','-w1','127.0.0.1',str(port)])
    return r.returncode==0

_SD_CAP_DROP_DEFAULT = ('cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,'
                        'cap_mknod,cap_audit_write,cap_audit_control,cap_syslog')
_SD_SECCOMP_BLOCKLIST = [
    'kexec_load','kexec_file_load','reboot','init_module','finit_module','delete_module',
    'ioperm','iopl',
    'mount','umount2','pivot_root',
    'unshare','setns','clone',
    'perf_event_open','ptrace','process_vm_readv','process_vm_writev',
    'add_key','request_key','keyctl',
    'acct','swapon','swapoff','syslog','quotactl','nfsservctl',
]

def _cap_drop_enabled(cid: str) -> bool:
    v = sj_get(cid, 'meta', 'cap_drop', default=True)
    return v is not False and str(v).lower() != 'false'

def _cap_drop_apply(cid: str):
    """Drop Linux capabilities from container child PIDs. Matches shell _cap_drop_apply."""
    if not _cap_drop_enabled(cid): return
    if not shutil.which('capsh'): return
    sess = tsess(cid)
    r = _tmux('list-panes','-t',sess,'-F','#{pane_pid}', capture=True)
    if r.returncode != 0: return
    pane_pid = r.stdout.strip().splitlines()[0].strip() if r.stdout.strip() else ''
    if not pane_pid: return
    r2 = _run(['pgrep','-P',pane_pid], capture=True)
    for cpid in r2.stdout.splitlines():
        cpid = cpid.strip()
        if cpid:
            _sudo('capsh', f'--drop={_SD_CAP_DROP_DEFAULT}', f'--pid={cpid}')

def _seccomp_enabled(cid: str) -> bool:
    v = sj_get(cid, 'meta', 'seccomp', default=True)
    return v is not False and str(v).lower() != 'false'

def _seccomp_apply(cid: str):
    """Apply seccomp filter to container. Matches shell _seccomp_apply."""
    if not _seccomp_enabled(cid): return
    res_cfg = G.containers_dir/cid/'resources.json'
    if res_cfg.exists():
        try:
            rc = json.loads(res_cfg.read_text())
            if rc.get('enabled') in (True, 'true'):
                unit = f'sd-{cid}.scope'
                if _run(['systemctl','--user','is-active',unit], capture=True).returncode == 0:
                    block_str = ' '.join(f'~{s}' for s in _SD_SECCOMP_BLOCKLIST)
                    _run(['systemctl','--user','set-property',unit,f'SystemCallFilter={block_str}'])
                    return
        except: pass
    profile = G.containers_dir/cid/'.seccomp_profile.json'
    if not profile.exists():
        names_json = ','.join(f'"{s}"' for s in _SD_SECCOMP_BLOCKLIST)
        syscall_list = f'{{"names":[{names_json}],"action":"SCMP_ACT_ERRNO"}}'
        try:
            profile.write_text(f'{{"defaultAction":"SCMP_ACT_ALLOW","syscalls":[{syscall_list}]}}\n')
        except: pass

def start_ct(cid: str, mode='background', profile_cid: str=''):
    if not _guard_space(): return
    if tmux_up(tsess(cid)): return
    # TODO-001: compile service.json from source before starting (matches shell _start_container)
    compile_service(cid)
    ip = cpath(cid)
    if not ip: return
    # TODO-003: storage link — unlink previous, pick profile, link new (matches shell _start_container)
    if _stor_count(cid) > 0:
        prev_scid = st(cid, 'storage_id', '')
        if prev_scid and _stor_read_active(prev_scid) == cid:
            _stor_clear_active(prev_scid)
        _stor_unlink(cid, ip)
        scid = profile_cid or _auto_pick_storage_profile(cid)
        if not scid: return
        _stor_link(cid, ip, scid)
    # TODO-002: auto-backup snapshot before start (matches shell _rotate_and_snapshot call)
    rotate_and_snapshot(cid)
    build_start_script(cid)
    netns_setup(); netns_ct_add(cid, cname(cid))
    # Set default exposure from HOST env var on first start (matches shell _start_container)
    if not exposure_file(cid).exists():
        host_env = sj_get(cid, 'environment', 'HOST', default='')
        if host_env == '0.0.0.0':
            exposure_set(cid, 'public')
        elif host_env in ('127.0.0.1', 'localhost'):
            exposure_set(cid, 'localhost')
    exposure_apply(cid)
    start_sh = ip / 'start.sh'
    sess = tsess(cid)
    if G.logs_dir:
        G.logs_dir.mkdir(parents=True, exist_ok=True)
        log_path(cid, 'start').touch()
    log_write(cid, 'start', f'── started {time.strftime("%Y-%m-%d %H:%M:%S")} ──')
    _start_lf = str(log_path(cid, 'start'))
    res_cfg = G.containers_dir/cid/'resources.json'
    base_cmd = f'cd {str(ip)!r} && bash {str(start_sh)!r}'
    # systemd-run resource limits
    run_cmd = base_cmd
    if res_cfg.exists():
        try: rc = json.loads(res_cfg.read_text())
        except: rc = {}
        if (rc.get('enabled') == True or rc.get('enabled') == 'true') and shutil.which('systemd-run'):
            sr = f'systemd-run --user --scope --unit=sd-{cid}'
            if rc.get('cpu_quota'):  sr += f' -p CPUQuota={rc["cpu_quota"]}'
            if rc.get('mem_max'):    sr += f' -p MemoryMax={rc["mem_max"]}'
            if rc.get('mem_swap'):   sr += f' -p MemorySwapMax={rc["mem_swap"]}'
            if rc.get('cpu_weight'): sr += f' -p CPUWeight={rc["cpu_weight"]}'
            run_cmd = f'{sr} -- bash -c {base_cmd!r}'
    tmux_launch(sess, f'({run_cmd}) 2>&1 | tee -a {_start_lf!r}')
    # Background watcher: fire SIGUSR1 to refresh UI when container session ends (DIV-004)
    def _ct_watcher(s=sess):
        while G.running and tmux_up(s):
            time.sleep(0.5)
        if G.running:
            G.usr1_fired = True
            if G.active_fzf_pid:
                try: os.kill(G.active_fzf_pid, signal.SIGUSR1)
                except: pass
    threading.Thread(target=_ct_watcher).start()
    # Background cap_drop + seccomp apply after 2s (DIV-006)
    try: _cap_drop_apply(cid)
    except: pass
    try: _seccomp_apply(cid)
    except: pass
    # start cron jobs
    d=sj(cid)
    for i,cr in enumerate(d.get('crons',[])):
        if '--autostart' in cr.get('flags',''):
            _cron_start_one(cid,i,cr)
    if mode=='attach':
        _tmux('switch-client','-t',sess)
    time.sleep(0.5)

def stop_ct(cid: str):
    sess=tsess(cid)
    ip=cpath(cid)
    if tmux_up(sess):
        _tmux('send-keys','-t',sess,'C-c','')
        _w = 0
        while tmux_up(sess) and _w < 40:
            time.sleep(0.2); _w += 1
        _tmux('kill-session','-t',sess)
    _tmux('kill-session','-t',f'sdTerm_{cid}', capture=True)
    netns_ct_del(cid, cname(cid))
    # flush iptables rules for this container — matches shell _stop_container
    port = str(sj_get(cid,'meta','port',default='') or sj_get(cid,'environment','PORT',default=''))
    if port and port != '0':
        exposure_flush(cid, port, netns_ct_ip(cid))
    # kill cron + action sessions
    r=_tmux('list-sessions','-F','#{session_name}', capture=True)
    for s in (r.stdout.splitlines() if r.returncode==0 else []):
        if s.startswith(f'sdCron_{cid}_') or s.startswith(f'sdAction_{cid}_'):
            _tmux('kill-session','-t',s)
    # Clean cron next-timestamp files (matches shell _cron_stop_all)
    if G.containers_dir:
        for nf in (G.containers_dir/cid).glob('cron_*_next'):
            nf.unlink(missing_ok=True)
    time.sleep(0.2)
    # TODO-003: storage unlink on stop (matches shell _stop_container)
    if ip and _stor_count(cid) > 0:
        _stor_unlink(cid, ip)
        scid = st(cid, 'storage_id', '')
        if scid: _stor_clear_active(scid)
    update_size_cache(cid)
    os.system('clear')
    pause(f"'{cname(cid)}' stopped.")

def _cron_interval_secs(iv: str) -> int:
    m=re.match(r'^(\d+)(s|m|h|d|w|mo)$',iv)
    if not m: return 3600
    n,u=int(m.group(1)),m.group(2)
    return n*{'s':1,'m':60,'h':3600,'d':86400,'w':604800,'mo':2592000}[u]

def _cron_start_one(cid: str, idx: int, cr: dict):
    sname=cron_sess(cid,idx); ip=cpath(cid)
    secs=_cron_interval_secs(cr.get('interval','5m'))
    cmd=cr.get('cmd',''); name=cr.get('name',f'cron_{idx}'); _log=cr.get('log','')
    _debug=('--debug' in sys.argv)
    _flags=cr.get('flags',''); unjailed='--unjailed' in _flags; use_sudo='--sudo' in _flags
    if use_sudo:
        import shlex as _sx
        cmd_resolved = cmd.replace('$root', str(ip) if ip else '').replace('$CONTAINER_ROOT', str(ip) if ip else '')
        cmd = f"sudo -n bash <<'__SD_SUDO__'\n{cmd_resolved}\n__SD_SUDO__"
    ns=netns_name(); ub=str(G.ubuntu_dir)
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_cron_')
    next_file = str(G.containers_dir/cid/f'cron_{idx}_next')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(f'_secs={secs}\n')
        f.write(f'_cron_next_file={next_file!r}\n')

        if unjailed:
            f.write(f'export CONTAINER_ROOT={ip!r}\n')
            f.write('while true; do\n')
            f.write(f'    _next=$(( $(date +%s) + _secs ))\n')
            f.write(f'    printf "%d" "$_next" > "$_cron_next_file"\n')
            f.write(f'    sleep "$_secs" &\n')
            f.write(f'    wait $!\n')
            f.write(f'    [[ -f "$_cron_next_file" ]] || exit 0\n')
            f.write(f'    printf "\\n\\033[1m── Cron: {name} ──\\033[0m\\n"\n')
            f.write("cat <<'__SD_CMD__' | bash\n")
            f.write(cmd + "\n")
            f.write("__SD_CMD__\n")
            f.write(f'    _cron_next_ts=$(( $(date +%s) + _secs ))\n')
            f.write('    _cron_next_time=$(date -d "@$_cron_next_ts" +%H:%M:%S 2>/dev/null || date +%H:%M:%S)\n')
            f.write('    _cron_next_date=$(date -d "@$_cron_next_ts" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)\n')
            f.write('    printf "\\n\\033[2mDone. Next execution: %s [%s]\\033[0m\\n" "$_cron_next_time" "$_cron_next_date"\n')
            f.write('done\n')
        else:
            import shlex as _sx2
            inner=cmd.replace('$root','/').replace('$CONTAINER_ROOT','/').replace('$out~/',str(G.mnt_dir)+'/').replace('$out/',str(G.mnt_dir)+'/').replace('$out',str(G.mnt_dir))
            f.write('while true; do\n')
            f.write(f'    _next=$(( $(date +%s) + _secs ))\n')
            f.write(f'    printf "%d" "$_next" > "$_cron_next_file"\n')
            f.write(f'    sleep "$_secs" &\n')
            f.write(f'    wait $!\n')
            f.write(f'    [[ -f "$_cron_next_file" ]] || exit 0\n')
            f.write(f'    printf "\\n\\033[1m── Cron: {name} ──\\033[0m\\n"\n')
            import shlex as _sx_cron
            _inner_chroot = f'/tmp/.sd_ci_{os.urandom(4).hex()}.sh'
            _inner_host = str(ip) + _inner_chroot
            Path(str(ip) + '/tmp').mkdir(parents=True, exist_ok=True)
            with open(_inner_host, 'w') as _if:
                _if.write('#!/bin/bash\ncd /\n')
                _if.write(cmd)
                _if.write('\n')
            os.chmod(_inner_host, 0o755)
            if _debug:
                f.write(f'    printf "\\033[2m[debug] inner script:\\033[0m\\n"\n')
                f.write(f'    cat {_inner_host!r}\n')
                f.write(f'    printf "\\n"\n')
            _nsenter_cmd = ' && '.join([
                f'mount -t proc proc {str(ip)}/proc 2>/dev/null||true',
                f'mount --bind /sys {str(ip)}/sys 2>/dev/null||true',
                f'mount --bind /dev {str(ip)}/dev 2>/dev/null||true',
                f'sudo -n chroot {str(ip)} /bin/bash {_inner_chroot}',
            ])
            f.write(f'    sudo -n nsenter --net=/run/netns/{ns} -- unshare --mount --pid --uts --ipc --fork bash <<\'__SD_NS__\'\n{_nsenter_cmd}\n__SD_NS__\n')
            f.write(f'    _cron_next_ts=$(( $(date +%s) + _secs ))\n')
            f.write('    _cron_next_time=$(date -d "@$_cron_next_ts" +%H:%M:%S 2>/dev/null || date +%H:%M:%S)\n')
            f.write('    _cron_next_date=$(date -d "@$_cron_next_ts" +%Y-%m-%d 2>/dev/null || date +%Y-%m-%d)\n')
            f.write('    printf "\\n\\033[2mDone. Next execution: %s [%s]\\033[0m\\n" "$_cron_next_time" "$_cron_next_date"\n')
            f.write('done\n')
    os.chmod(runner.name, 0o755)
    tmux_launch(sname, f'bash {runner.name}; rm -f {runner.name}')

def _cr_prefix(val: str) -> str:
    """$root=$CONTAINER_ROOT, $out/p=host /p, $out~/p=host ~/p, else prefix with $CONTAINER_ROOT."""
    if not val: return val
    if val.startswith('$root'): return val.replace('$root','$CONTAINER_ROOT',1)
    if val.startswith('$out~/') or val=='$out~': return val.replace('$out~','$HOME',1)
    if val.startswith('$out'): return val[4:] or '/'
    if val.startswith(('/', '$', '~', '"', "'")): return val
    if re.match(r'^\d+$', val): return val
    if ':' in val: return val
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', val): return val
    if '://' in val: return val
    return f'$CONTAINER_ROOT/{val}'


def _env_exports(cid: str, install_path: Path) -> str:
    d=sj(cid); ip=str(install_path)
    lines=[f'export CONTAINER_ROOT={ip!r}',
            f'export root={ip!r}',
            f'export OUT={str(G.mnt_dir)!r}']
    lines+=['export HOME="$CONTAINER_ROOT"',
            'export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"',
            'export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"',
            'export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"',
            'export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"',
            'export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/python/bin:$CONTAINER_ROOT/.local/bin:$CONTAINER_ROOT/bin:$PATH"',
            'export PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV="$CONTAINER_ROOT/venv"',
            # NOTE: _sd_sp/PYTHONPATH lines are Python additions not present in shell _env_exports (divergence DIV-006)
            '_sd_sp=$(python3 -c "import sys; print(next((p for p in sys.path if \'site-packages\' in p and \'/usr\' not in p), \'\'))" 2>/dev/null)',
            '_sd_vsp=$(compgen -G "$CONTAINER_ROOT/venv/lib/python*/site-packages" 2>/dev/null | head -1) || true',
            '[[ -n "$_sd_vsp" ]] && export PYTHONPATH="$_sd_vsp${PYTHONPATH:+:$PYTHONPATH}"',
            'mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$CONTAINER_ROOT/.local/bin" 2>/dev/null',
            '[[ ! -e "$CONTAINER_ROOT/bin" ]] && mkdir -p "$CONTAINER_ROOT/bin" 2>/dev/null || true']
    # GPU auto-detect block
    gpu_flag=d.get('meta',{}).get('gpu','')
    if gpu_flag in ('cuda_auto','auto'):
        lines+=['if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then',
                '    export NVIDIA_GPU=1 CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"',
                "    printf '[gpu] CUDA mode\\n'",
                'else',
                "    printf '[gpu] CPU mode\\n'",
                'fi']
    # Environment variables
    for k,v in d.get('environment',{}).items():
        sv=str(v)
        if sv=='generate:hex32':
            # TODO-005: persistent secret — reuse from storage or container dir (matches shell _build_start_script)
            scid = st(cid, 'storage_id', '')
            if scid and G.storage_dir:
                secret_f = G.storage_dir/scid/f'.sd_secret_{k}'
            else:
                secret_f = G.containers_dir/cid/f'.sd_secret_{k}'
            sf_q = str(secret_f)
            # Shell: check file, reuse if exists, else generate and save
            pv = (f'$(if [[ -f {sf_q!r} ]]; then cat {sf_q!r}; '
                  f'else v=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret"); '
                  f'printf "%s" "$v" > {sf_q!r} 2>/dev/null || true; printf "%s" "$v"; fi)')
        else:
            pv=_cr_prefix(sv)
        if k in ('LD_LIBRARY_PATH','LIBRARY_PATH','PKG_CONFIG_PATH'):
            lines.append(f'export {k}="{pv}:${{{k}:-}}"')
        else:
            lines.append(f'export {k}="{pv}"')
    return '\n'.join(lines)+'\n'

def build_start_script(cid: str):
    """Generate start.sh inside the installation directory."""
    ip=cpath(cid)
    if not ip: return
    d=sj(cid); ns=netns_name()
    start_block=d.get('start',''); ep=d.get('meta',{}).get('entrypoint','')
    if ep:
        ep_parts = ep.split(' ', 1)
        ep_bin = ep_parts[0]
        ep_args = ep_parts[1] if len(ep_parts) > 1 else ''
        ep_bin_prefixed = _cr_prefix(ep_bin)
        exec_cmd = f'exec {ep_bin_prefixed}' + (f' {ep_args}' if ep_args else '')
    else:
        exec_cmd = start_block
    hostname=re.sub(r'[^a-z0-9\-]','-',cname(cid).lower())[:63]
    sh=ip/'start.sh'
    # TODO-004: log path for tee redirect and rotation trap (matches shell _build_start_script)
    slog = str(log_path(cid, 'start'))
    mnt_dir_q = str(G.mnt_dir) if G.mnt_dir else ''
    nhf=netns_hosts()
    with open(sh,'w') as f:
        _dbg = 'set -ex' if '--debug' in __import__('sys').argv else 'set -e'
        f.write(f'#!/usr/bin/env bash\n{_dbg}\n')
        f.write('printf "[sd] starting...\\n"\n')
        # Ensure log dir exists
        if G.logs_dir:
            f.write(f'python3 -c "import os; os.makedirs({str(G.logs_dir)!r}, exist_ok=True)" 2>/dev/null || true\n')
        # logging handled externally by tmux tee command
        # TODO-006: NVIDIA cuda_auto block — detect driver, cache-invalidate on version change,
        # copy libcuda.so* / libnvidia*.so* from host into chroot (matches shell _build_start_script)
        gpu_flag = d.get('meta',{}).get('gpu','')
        nv_chroot_lib = str(ip/'usr/local/lib/sd_nvidia')
        if gpu_flag == 'cuda_auto':
            f.write('# NVIDIA: copy host driver .so files into chroot (exact version match)\n')
            f.write('_SD_NV_MAJ=""\n')
            f.write('if [[ -f /sys/module/nvidia/version ]]; then\n')
            f.write('  _SD_NV_MAJ=$(cut -d. -f1 /sys/module/nvidia/version 2>/dev/null)\n')
            f.write('fi\n')
            f.write('if [[ -z "$_SD_NV_MAJ" ]] && [[ -f /proc/driver/nvidia/version ]]; then\n')
            f.write(r"  _SD_NV_MAJ=$(grep -oP 'Kernel Module[[:space:]]+\K[0-9]+' /proc/driver/nvidia/version 2>/dev/null | head -1)" + '\n')
            f.write('fi\n')
            f.write('_SD_EXTRA=""\n')
            f.write('if [[ -z "$_SD_NV_MAJ" ]]; then\n')
            f.write('  printf "[sd] No NVIDIA kernel module -- CPU mode\\n"\n')
            f.write('  _SD_EXTRA="--cpu"\n')
            f.write('else\n')
            f.write('  printf "[sd] NVIDIA driver major version: %s\\n" "$_SD_NV_MAJ"\n')
            f.write('  # ── Version mismatch check: clear stale libs if driver changed ──\n')
            f.write('  _SD_NV_CACHED_VER=""\n')
            f.write(f'  [[ -f {nv_chroot_lib!r}/.sd_nv_ver ]] && _SD_NV_CACHED_VER=$(cat {nv_chroot_lib!r}/.sd_nv_ver 2>/dev/null)\n')
            f.write('  if [[ -n "$_SD_NV_CACHED_VER" && "$_SD_NV_CACHED_VER" != "$_SD_NV_MAJ" ]]; then\n')
            f.write('    printf "[sd] WARNING: NVIDIA driver changed (%s → %s) -- clearing cached libs\\n" "$_SD_NV_CACHED_VER" "$_SD_NV_MAJ"\n')
            f.write(f'    rm -rf {nv_chroot_lib!r} 2>/dev/null || true\n')
            f.write('  fi\n')
            f.write(f'  _SD_NV_DIR={nv_chroot_lib!r}\n')
            f.write('  mkdir -p "$_SD_NV_DIR"\n')
            f.write('  _SD_NV_COUNT=0\n')
            f.write('  for _sd_f in'
                    ' /usr/lib/libcuda.so* /usr/lib/libnvidia*.so*'
                    ' /usr/lib64/libcuda.so* /usr/lib64/libnvidia*.so*'
                    ' /usr/lib/x86_64-linux-gnu/libcuda.so* /usr/lib/x86_64-linux-gnu/libnvidia*.so*'
                    ' /usr/lib/aarch64-linux-gnu/libcuda.so* /usr/lib/aarch64-linux-gnu/libnvidia*.so*; do\n')
            f.write('    [[ -e "$_sd_f" ]] && cp -Lf "$_sd_f" "$_SD_NV_DIR/" 2>/dev/null && (( _SD_NV_COUNT++ )) || true\n')
            f.write('  done\n')
            f.write('  if [[ "$_SD_NV_COUNT" -eq 0 ]]; then\n')
            f.write('    printf "[sd] WARNING: no NVIDIA .so files found on host -- CPU mode\\n"\n')
            f.write('    _SD_EXTRA="--cpu"\n')
            f.write('  else\n')
            f.write(f'    printf "%s" "$_SD_NV_MAJ" > {nv_chroot_lib!r}/.sd_nv_ver\n')
            f.write('    printf "[sd] Copied %d NVIDIA lib files into chroot (driver %s) -- GPU enabled\\n" "$_SD_NV_COUNT" "$_SD_NV_MAJ"\n')
            f.write('  fi\n')
            f.write('fi\n')
        # Build env_str with CONTAINER_ROOT=/ (chroot-relative) and bake inline into chroot -c arg.
        # This matches shell: env is part of the -c string so sudo env_reset cannot strip it.
        env_str = ('export CONTAINER_ROOT=/ HOME=/ VIRTUAL_ENV=/venv PYTHONNOUSERSITE=1 PIP_USER=false'
                   ' PATH="/venv/bin:/python/bin:/.local/bin:/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"')
        for k, v in d.get('environment', {}).items():
            sv = str(v)
            if sv == 'generate:hex32':
                scid2 = st(cid, 'storage_id', '')
                if scid2 and G.storage_dir:
                    secret_f2 = G.storage_dir/scid2/f'.sd_secret_{k}'
                else:
                    secret_f2 = G.containers_dir/cid/f'.sd_secret_{k}'
                sf_q2 = str(secret_f2)
                sv = (f'$(if [[ -f {sf_q2!r} ]]; then cat {sf_q2!r}; '
                      f'else v=$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret"); '
                      f'printf "%s" "$v" > {sf_q2!r} 2>/dev/null || true; printf "%s" "$v"; fi)')
            else:
                sv = sv.replace('$CONTAINER_ROOT/', '/').replace('$CONTAINER_ROOT', '/')
            if k in ('LD_LIBRARY_PATH', 'LIBRARY_PATH', 'PKG_CONFIG_PATH'):
                env_str += f' {k}="{sv}:${{{k}:-}}"'
            else:
                env_str += f' {k}="{sv}"'
        nv_ld = f' LD_LIBRARY_PATH="/usr/local/lib/sd_nvidia:${{LD_LIBRARY_PATH:-}}"' if gpu_flag == 'cuda_auto' else ''
        exec_cmd_inner = exec_cmd.replace('$root/','/').replace('$root','/').replace('$CONTAINER_ROOT/','/').replace('$CONTAINER_ROOT','/').replace('$out~/',"${HOME}/").replace('$out/',str(G.mnt_dir)+'/').replace('$out',str(G.mnt_dir))
        if gpu_flag == 'cuda_auto':
            nsenter_line = (f'sudo -n nsenter --net=/run/netns/{ns} -- '
                            f'unshare --mount --pid --uts --ipc --fork bash -s "$_SD_EXTRA" << \'_SDNS_WRAP\'\n')
        else:
            nsenter_line = (f'sudo -n nsenter --net=/run/netns/{ns} -- '
                            f'unshare --mount --pid --uts --ipc --fork bash -s << \'_SDNS_WRAP\'\n')
        f.write(f'if ! sudo -n ip netns list 2>/dev/null | grep -q {ns!r}; then\n')
        f.write( '  printf "[sd] ERROR: network namespace not found, cannot start.\\n"\n')
        f.write( '  exit 1\n')
        f.write( 'fi\n')
        f.write(nsenter_line)
        f.write('_chroot_bash(){ local r=$1; shift; local b=/bin/bash; [[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n')
        if gpu_flag == 'cuda_auto':
            f.write('_NS_EXTRA="${1:-}"\n')
        f.write(f'printf "%s" {hostname!r} > /proc/sys/kernel/hostname 2>/dev/null||true\n')
        f.write(f'mkdir -p {str(ip)!r}/proc {str(ip)!r}/sys {str(ip)!r}/dev 2>/dev/null||true\n')
        f.write(f'mount -t proc proc {str(ip)}/proc 2>/dev/null||true\n')
        f.write(f'mount --bind /sys  {str(ip)}/sys  2>/dev/null||true\n')
        f.write(f'mount --bind /dev  {str(ip)}/dev  2>/dev/null||true\n')
        # Bind-mount MNT_DIR inside container so storage symlinks resolve
        if mnt_dir_q:
            f.write(f'mkdir -p {str(ip)}{mnt_dir_q} 2>/dev/null||true\n')
            f.write(f'mount --bind {mnt_dir_q!r} {str(ip)}{mnt_dir_q!r} \\\n'
                    f'  || printf "[sd] WARNING: MNT_DIR bind mount failed -- storage symlinks may not resolve\\n"\n')
        f.write(f'[[ -f {str(nhf)!r} ]] && mount --bind {str(nhf)!r} {str(ip)}/etc/hosts 2>/dev/null||true\n')
        # Write exec script to a file inside the heredoc to avoid -c quoting issues
        f.write(f'cat > {str(ip)!r}/tmp/.sd_start.sh << \'_SD_START_EOF\'\n')
        f.write('#!/bin/sh\n')
        f.write(f'cd / && {env_str}{nv_ld}\n')
        f.write(exec_cmd_inner + '\n')
        f.write('_SD_START_EOF\n')
        f.write(f'chmod +x {str(ip)!r}/tmp/.sd_start.sh\n')
        f.write(f'_chroot_bash {str(ip)!r} /tmp/.sd_start.sh\n')
        f.write('_SDNS_WRAP\n')
    os.chmod(sh, 0o755)

def _gen_install_script(cid: str, mode: str) -> str:
    """Generate the bash install/update script content."""
    d=sj(cid); ip=str(cpath(cid))
    ub=str(G.ubuntu_dir); ok_f=str(G.containers_dir/cid/'.install_ok')
    fail_f=str(G.containers_dir/cid/'.install_fail')
    _debug_flag = '--debug' in sys.argv
    lines=['#!/usr/bin/env bash', 'set -ex' if _debug_flag else 'set -e']
    lines+=[f'_ok={ok_f!r}', f'_fail={fail_f!r}',
            '_finish(){ local c=$?; [[ $c -eq 0 ]] && touch "$_ok" || touch "$_fail"; }',
            'trap _finish EXIT', f'trap \'touch "$_fail"; exit 130\' INT TERM',
            '_chroot_bash(){ local r=$1; shift; local b=/bin/bash; '
            '[[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; '
            'sudo -n chroot "$r" "$b" "$@"; }',
            f'_SD_INSTALL={ip!r}', f'_UB={ub!r}',
            '_mnt(){ sudo -n mount --bind /proc "$_UB/proc"; sudo -n mount --bind /sys "$_UB/sys"; sudo -n mount --bind /dev "$_UB/dev"; }',
            '_umnt(){ sudo -n umount -lf "$_UB/dev" "$_UB/sys" "$_UB/proc" 2>/dev/null||true; }',
            # _sd_best_url and _sd_extract_auto helpers (DIV-014)
            '_sd_arch=$(uname -m); case "$_sd_arch" in x86_64) _SD_ARCH=amd64;; aarch64) _SD_ARCH=arm64;; armv7l) _SD_ARCH=armv7;; *) _SD_ARCH=amd64;; esac',
            '_sd_best_url() {',
            '  local repo="$1" arch="$2" hint="${3:-}" atype="${4:-}"',
            '  local rel; rel=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || true',
            '  local urls; urls=$(printf \'%s\' "$rel" | grep -o \'"browser_download_url": *"[^"]*"\' | grep -ivE \'sha256|\\.sig|\\.txt|\\.json|rocm|jetpack\' | grep -o \'https://[^"]*\') || true',
            '  local type_urls="$urls"',
            '  case "${atype^^}" in',
            '    BIN) type_urls=$(printf \'%s\' "$urls" | grep -ivE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz|zip)$\') ;;',
            '    ZIP) type_urls=$(printf \'%s\' "$urls" | grep -iE \'\\.zip$\') ;;',
            '    TAR) type_urls=$(printf \'%s\' "$urls" | grep -iE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz)$\') ;;',
            '  esac',
            '  local url=""',
            '  [[ -n "$hint" ]] && url=$(printf \'%s\' "$type_urls" | grep -iF "$hint" | head -1) || true',
            '  if [[ -z "$url" && "${_SD_GPU:-cpu}" == "cuda" ]]; then',
            '    url=$(printf \'%s\' "$type_urls" | grep -iE "cuda" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true',
            '    [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE "cuda" | grep -iE "$arch" | head -1) || true',
            '  fi',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz|zip)$\' | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz|zip)$\' | grep -iE "$arch" | head -1) || true',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE "linux.*${arch}|${arch}.*linux" | head -1) || true',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE "$arch" | head -1) || true',
            '  [[ -z "$url" && -n "$hint" ]] && url=$(printf \'%s\' "$urls" | grep -i "$hint" | head -1) || true',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$type_urls" | grep -iE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz|zip)$\' | head -1) || true',
            '  [[ -z "$url" ]] && url=$(printf \'%s\' "$rel" | grep -o \'"tarball_url": *"[^"]*"\' | grep -o \'https://[^"]*\' | head -1) || true',
            '  printf \'%s\' "$url"',
            '}',
            '_sd_extract_auto() {',
            '  local url="$1" dest="$2"; mkdir -p "$dest"',
            '  local _tmp; _tmp=$(mktemp "$dest/.sd_dl_XXXXXX")',
            '  curl -fL --progress-bar --retry 5 --retry-delay 3 --retry-all-errors -C - "$url" -o "$_tmp" || { rm -f "$_tmp"; printf "[!] Download failed: %s\\n" "$url"; return 1; }',
            '  local strip=1 _extracted=false',
            '  if [[ "$url" =~ \\.tar\\.zst$ ]]; then',
            '    tar --use-compress-program=unzstd -x -C "$dest" --strip-components="$strip" -f "$_tmp" 2>/dev/null && _extracted=true || true',
            '    if [[ "$_extracted" == false ]]; then',
            '      python3 -c "import tarfile,sys; t=tarfile.open(sys.argv[1],\'r:*\'); [t.extract(m,sys.argv[2]) for m in t.getmembers()]" "$_tmp" "$dest" 2>/dev/null && _extracted=true || true',
            '    fi',
            '  elif [[ "$url" =~ \\.(tar\\.(gz|bz2|xz)|tgz)$ ]]; then',
            '    tar -xa -C "$dest" --strip-components="$strip" -f "$_tmp" 2>/dev/null && _extracted=true || { tar -xa -C "$dest" -f "$_tmp" 2>/dev/null && _extracted=true || true; }',
            '  elif [[ "$url" =~ \\.zip$ ]]; then',
            '    unzip -o -d "$dest" "$_tmp" 2>/dev/null && _extracted=true || true',
            '  fi',
            '  if [[ "$_extracted" == false ]]; then',
            '    local _bn; _bn=$(basename "$url" | sed \'s/[?#].*//\')',
            '    mkdir -p "$dest/bin"; mv "$_tmp" "$dest/bin/$_bn"; chmod +x "$dest/bin/$_bn"; return',
            '  fi',
            '  rm -f "$_tmp"',
            '}',
            '']
    # Create install dir (btrfs subvolume or mkdir)
    if mode=='install':
        lines+=[f'btrfs subvolume create {ip!r} >/dev/null 2>&1 || true',
                f'mkdir -p {ip!r}/logs',
                '']
        # Storage bind mounts
        for sp in d.get('storage',[]):
            sp_src=str(G.storage_dir/cid/sp) if G.storage_dir else ''
            if sp_src:
                lines+=[f'if [[ -d {sp_src!r} ]]; then',
                        f'  mkdir -p {ip!r}/{sp}',
                        f'  sudo -n mount --bind {sp_src!r} {ip!r}/{sp} 2>/dev/null||true',
                        'fi']
    # Ensure Ubuntu base
    lines+=['# ── Ubuntu bootstrap ──',
            f'if [[ ! -f {ub!r}/.ubuntu_ready ]]; then',
            f'  printf "\\033[1m[ubuntu] Installing base packages...\\033[0m\\n"',
            f'  printf "[ubuntu] This may take a few minutes.\\n"',
            f'  _sd_ub_arch=$(uname -m)',
            f'  case "$_sd_ub_arch" in x86_64) _sd_ub_arch=amd64;; aarch64) _sd_ub_arch=arm64;; armv7l) _sd_ub_arch=armhf;; *) _sd_ub_arch=amd64;; esac',
            f'  _base="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"',
            f'  _ver=$(curl -fsSL "$_base" 2>/dev/null|grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${{_sd_ub_arch}}"|head -1)',
            f'  [[ -z "$_ver" ]]&&_ver="24.04.3-base-${{_sd_ub_arch}}"',
            f'  _tmp=$(mktemp /tmp/.sd_ub_dl_XXXXXX.tar.gz)',
            f'  mkdir -p {ub!r}',
            f'  printf "[ubuntu] Downloading %s...\\n" "$_ver"',
            f'  curl -fL --progress-bar "${{_base}}ubuntu-base-${{_ver}}.tar.gz" -o "$_tmp"',
            f'  tar -xzf "$_tmp" -C {ub!r} 2>&1||true; rm -f "$_tmp"',
            f'  [[ ! -e {ub!r}/bin ]]&&ln -sf usr/bin {ub!r}/bin 2>/dev/null||true',
            f'  [[ ! -e {ub!r}/lib ]]&&ln -sf usr/lib {ub!r}/lib 2>/dev/null||true',
            f'  [[ ! -e {ub!r}/lib64 ]]&&ln -sf usr/lib64 {ub!r}/lib64 2>/dev/null||true',
            f'  printf "nameserver 8.8.8.8\\n" > {ub!r}/etc/resolv.conf',
            f'  printf "APT::Sandbox::User \\"root\\";\\n" > {ub!r}/etc/apt/apt.conf.d/99sandbox',
            f'  _host_arch=$(uname -m)',
            f'  if [[ "$_host_arch" != x86_64 && "$_sd_ub_arch" == amd64 ]] || [[ "$_host_arch" != aarch64 && "$_sd_ub_arch" == arm64 ]]; then',
            f'    if ! ls /proc/sys/fs/binfmt_misc/qemu-* >/dev/null 2>&1; then',
            f'      printf "\\033[31m[ubuntu] ERROR: host arch (%s) != image arch (%s). Install qemu-user-static + binfmt-support.\\n\\033[0m" "$_host_arch" "$_sd_ub_arch"',
            f'      exit 1',
            f'    fi',
            f'    _qemu=$(ls /usr/bin/qemu-*-static 2>/dev/null | head -1) || true',
            f'    [[ -n "$_qemu" ]] && sudo -n cp "$_qemu" {ub!r}/usr/bin/ 2>/dev/null||true',
            f'  fi',
            f'  _mnt',
            f'  _chroot_bash {ub!r} -c "apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {DEFAULT_UBUNTU_PKGS}"',
            f'  _umnt',
            f'  touch {ub!r}/.ubuntu_ready',
            f'  date +%Y-%m-%d > {ub!r}/.sd_ubuntu_stamp',
            f'fi',
            # If ip is still empty (ubuntu wasn't ready when run_job started),
            # snapshot ub into ip now so chroot has a working /bin/bash
            f'if [[ ! -f {ip!r}/usr/bin/bash && ! -f {ip!r}/bin/bash ]]; then',
            f'  sudo -n btrfs subvolume delete {ip!r} >/dev/null 2>&1 || true',
            f'  sudo -n btrfs subvolume snapshot {ub!r} {ip!r} >/dev/null 2>&1',
            f'  sudo -n chown "$(id -u)":"$(id -g)" {ip!r} 2>/dev/null || true',
            f'  _qemu=$(ls /usr/bin/qemu-*-static 2>/dev/null | head -1) || true',
            f'  [[ -n "$_qemu" ]] && sudo -n cp "$_qemu" {ip!r}/usr/bin/ 2>/dev/null||true',
            f'fi',
            '']
    # apt deps
    deps=d.get('deps',[])
    if deps:
        pkg_str=' '.join(deps)
        lines+=[f'printf "\\033[1m[apt] Installing: {pkg_str}\\033[0m\\n"',
                '_mnt',
                f'_sd_apt=$(mktemp /tmp/.sd_apt_XXXXXX.sh)',
                f'printf \'#!/bin/sh\\nset -e\\napt-get update -qq\\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {pkg_str} 2>&1\\n\' > "$_sd_apt"',
                f'chmod +x "$_sd_apt"',
                f'sudo -n mount --bind "$_sd_apt" {ub!r}/tmp/.sd_apt.sh 2>/dev/null||cp "$_sd_apt" {ub!r}/tmp/.sd_apt.sh',
                f'_chroot_bash {ub!r} /tmp/.sd_apt.sh',
                f'sudo -n umount -lf {ub!r}/tmp/.sd_apt.sh 2>/dev/null||true',
                'rm -f "$_sd_apt"', '_umnt','']
    # dirs
    for dd in expand_dirs(d.get('dirs',[])):
        lines.append(f'mkdir -p {ip!r}/{dd}')
    if d.get('dirs'): lines.append('')
    # pip
    pip_pkgs=d.get('pip',[])
    if pip_pkgs:
        pkg_str=' '.join(pip_pkgs)
        lines+=[f'printf "\\\\033[1m[pip] Installing: {pkg_str}\\\\033[0m\\\\n"',
                '_mnt',
                f'_chroot_bash {ub!r} -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-full python3-pip python3-venv 2>&1 || (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-full python3-pip python3-venv 2>&1)"',
                '_umnt',
                f'python3 -m venv {ip!r}/venv 2>/dev/null||true',
                '_mnt',
                f'sudo -n mount --bind {ip!r} {ub!r}/mnt',
                f'_chroot_bash {ub!r} -c "/mnt/venv/bin/pip install {pkg_str} 2>&1"',
                f'sudo -n umount -lf {ub!r}/mnt 2>/dev/null||true',
                '_umnt','']
    # npm
    npm_pkgs=d.get('npm',[])
    if npm_pkgs:
        pkg_str=' '.join(npm_pkgs)
        lines+=[f'printf "\\033[1m[npm] Installing: {pkg_str}\\033[0m\\n"',
                '_mnt',
                f'sudo -n mount --bind {ip!r} {ub!r}/mnt',
                f'_chroot_bash {ub!r} -c "cd /mnt && npm install {pkg_str} 2>&1"',
                f'sudo -n umount -lf {ub!r}/mnt 2>/dev/null||true',
                '_umnt','']
    # git (DIV-014: use _sd_best_url/_sd_extract_auto helpers defined above)
    for g in d.get('git',[]):
        repo=g.get('repo',''); dest=g.get('dest','.') or '.'; hint=g.get('hint','')
        asset_type=g.get('type',''); src=g.get('source',False)
        dest_expr=f'{ip}/{dest}' if dest!='.' else ip
        if src:
            # tag lookup uses single quotes inside bash – build string to avoid Python quoting issues
            _q = "'"
            _tag_line = (
                f"_sd_tag=$(curl -fsSL https://api.github.com/repos/{repo}/releases/latest"
                f" 2>/dev/null | grep -o {_q}tag_name{_q} | tr -d {_q}\":{_q} | head -1) || true"
            )
            lines+=[
                f'printf "Cloning {repo}...\\n"',
                f'_sd_tag=$(curl -fsSL "https://api.github.com/repos/{repo}/releases/latest" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get(chr(116)+chr(97)+chr(103)+chr(95)+chr(110)+chr(97)+chr(109)+chr(101),chr(0)))" 2>/dev/null || true)',
                f'[ -z "$_sd_tag" ] && _sd_tag=""',
                'if [ -n "$_sd_tag" ]; then',
                f'  git clone --depth=1 --branch "$_sd_tag" "https://github.com/{repo}.git" {dest_expr!r} 2>&1',
                'else',
                f'  git clone --depth=1 "https://github.com/{repo}.git" {dest_expr!r} 2>&1',
                'fi',
                '']
        else:
            lines+=[f'printf "Fetching {repo} (%s)...\\n" "$_SD_ARCH"',
                    f'_sd_url=$(_sd_best_url {repo!r} "$_SD_ARCH" {hint!r} {asset_type!r})',
                    f'[[ -z "$_sd_url" ]] && {{ printf "[!] No asset found for {repo}\\n"; exit 1; }}',
                    f'_sd_extract_auto "$_sd_url" {dest_expr!r}',
                    f'printf "✓ {repo} → {dest_expr}\\n"',
                    '']
    # build
    if mode=='install' and d.get('build','').strip():
        lines+=[f'# ── Build ──', d['build'],'']
    # install/update script
    script=d.get(mode,'').strip()
    if script:
        lines+=[f'# ── {mode} script ──',
                f'mkdir -p {ip!r}/tmp {ip!r}/proc {ip!r}/sys {ip!r}/dev 2>/dev/null||true',
                f'sudo -n mount --bind /proc {ip!r}/proc 2>/dev/null||true',
                f'sudo -n mount --bind /sys  {ip!r}/sys  2>/dev/null||true',
                f'sudo -n mount --bind /dev  {ip!r}/dev  2>/dev/null||true',
                f'_sd_run=$(mktemp {ip!r}/tmp/.sd_run_XXXXXX.sh)',
                'cat > "$_sd_run" << \'_SD_RUN_EOF\'',
                '#!/bin/bash', 'set -ex' if '--debug' in __import__('sys').argv else 'set -e', 'cd /',
                script,
                '_SD_RUN_EOF',
                'chmod +x "$_sd_run"',
                f'_chroot_bash {ip!r} /tmp/$(basename "$_sd_run")',
                f'sudo -n umount -lf {ip!r}/dev {ip!r}/sys {ip!r}/proc 2>/dev/null||true',
                'rm -f "$_sd_run"','']
    return '\n'.join(lines)

def write_pkg_manifest(cid: str):
    import shlex as _shlex
    d=sj(cid)
    deps_raw = d.get('deps','')
    if isinstance(deps_raw, str):
        dep_list = _shlex.split(deps_raw.replace(',',' ')) if deps_raw.strip() else []
    else:
        dep_list = deps_raw
    pip_raw = d.get('pip',[])
    if isinstance(pip_raw, str):
        pip_list = [p.strip() for p in pip_raw.replace(',',' ').split() if p.strip() and not p.strip().startswith('#')]
    else:
        pip_list = pip_raw
    npm_raw = d.get('npm',[])
    if isinstance(npm_raw, str):
        npm_list = [p.strip() for p in npm_raw.replace(',',' ').split() if p.strip() and not p.strip().startswith('#')]
    else:
        npm_list = npm_raw
    m={'deps':dep_list,'pip':pip_list,'npm':npm_list,
       'git':[g.get('repo','') for g in d.get('git',[])],'updated':time.strftime('%Y-%m-%d %H:%M')}
    (G.containers_dir/cid/'pkg_manifest.json').write_text(json.dumps(m,indent=2))

def run_job(cid: str, mode='install', force=False):
    """Launch install/update in a tmux session, capturing output to Logs/."""
    compile_service(cid)
    if not _guard_space(): return
    ip=cpath(cid)
    if not ip: pause('No install path set.'); return
    ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    # DIV-013: snapshot Ubuntu base as container root before running install script
    if mode == 'install' and G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists():
        if not ip.exists():
            r_snap = _sudo('btrfs','subvolume','snapshot',str(G.ubuntu_dir),str(ip), capture=True)
            if r_snap.returncode == 0:
                _sudo('chown', f'{os.getuid()}:{os.getgid()}', str(ip), capture=True)
    script_content=_gen_install_script(cid,mode)
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_inst_')
    runner.write(script_content); runner.close(); os.chmod(runner.name,0o755)
    sess=inst_sess(cid)
    lf = log_path(cid, mode)
    if G.logs_dir:
        G.logs_dir.mkdir(parents=True, exist_ok=True)
        lf.touch()  # pre-create so tee never fails on missing file
    log_write(cid, mode, f'── {mode} started {time.strftime("%Y-%m-%d %H:%M:%S")} ──')
    # pane-exited hook: write .install_fail if neither sentinel exists
    hook = tempfile.NamedTemporaryFile(mode='w', dir=str(G.tmp_dir),
                                       suffix='.sh', delete=False, prefix='.sd_inst_hook_')
    hook.write(f'#!/usr/bin/env bash\n[[ -f {str(ok_f)!r} || -f {str(fail_f)!r} ]] || touch {str(fail_f)!r}\n')
    hook.close(); os.chmod(hook.name, 0o755)
    n = cname(cid)
    cmd = f'bash -o pipefail {runner.name!r}'
    if not launch_job(sess, f'{mode.capitalize()}: {n}', cmd, str(ok_f), str(fail_f), str(lf)):
        os.unlink(runner.name); os.unlink(hook.name); return
    tmux_set('SD_INSTALLING', cid)
    _tmux('set-hook','-t',sess,'pane-exited',
          f'run-shell "bash {hook.name!r}; rm -f {hook.name!r} {runner.name!r}"')

def compile_service(cid: str) -> bool:
    src=G.containers_dir/cid/'service.src'
    if not src.exists(): return False
    return bp_compile(src, cid)

def process_install_finish(cid: str):
    """Called after install completes — update state, offer backup."""
    ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
    _tmux('kill-session','-t',inst_sess(cid))
    tmux_set('SD_INSTALLING','')
    if ok_f.exists():
        # Stale result guard — matches shell: if ok_age > 600s and session gone, reject
        try:
            ok_age = time.time() - ok_f.stat().st_mtime
            if ok_age > 600 and not tmux_up(inst_sess(cid)):
                ok_f.unlink(missing_ok=True)
                pause('⚠  Installation result is stale. Please reinstall.')
                return
        except: pass
        ok_f.unlink()
        already=st(cid,'installed')
        if already:
            write_pkg_manifest(cid)
            if G.cache_dir:
                inst_f = G.cache_dir/'gh_tag'/f'{cid}.inst'
                cache_f = G.cache_dir/'gh_tag'/cid
                if cache_f.exists():
                    inst_f.write_text(cache_f.read_text())
            pause(f"'{cname(cid)}' packages updated.")
            return
        set_st(cid,'installed',True)
        write_pkg_manifest(cid)
        ip=cpath(cid)
        if ip and (G.ubuntu_dir/'.sd_ubuntu_stamp').exists():
            shutil.copy(str(G.ubuntu_dir/'.sd_ubuntu_stamp'),str(ip/'.sd_ubuntu_stamp'))
        if confirm(f"'{cname(cid)}' {L['msg_install_ok']}\n\nCreate a Post-Install backup?\n  (Instant revert to clean install)"):
            sdir=snap_dir(cid); sdir.mkdir(parents=True,exist_ok=True)
            sid='Post-Installation'
            if (sdir/sid).is_dir(): btrfs_delete(sdir/sid); (sdir/f'{sid}.meta').unlink(missing_ok=True)
            if btrfs_snap(ip,sdir/sid):
                snap_meta_set(sdir,sid,type='manual',ts=time.strftime('%Y-%m-%d %H:%M'))
                pause(f"Backup 'Post-Installation' created for '{cname(cid)}'.")
            else:
                shutil.copytree(str(ip),str(sdir/sid))
                snap_meta_set(sdir,sid,type='manual',ts=time.strftime('%Y-%m-%d %H:%M'))
                pause(f"Backup created (plain copy) for '{cname(cid)}'.")
        else:
            pause(f"'{cname(cid)}' {L['msg_install_ok']}")
    elif fail_f.exists():
        fail_f.unlink()
        pause(L['msg_install_fail'])
    update_size_cache(cid)

# ══════════════════════════════════════════════════════════════════════════════
# container/backup.py — snapshots, restore, clone
# ══════════════════════════════════════════════════════════════════════════════

def create_backup_manual(cid: str):
    ip=cpath(cid)
    if not ip or not ip.is_dir(): pause(f"No installation for '{cname(cid)}'."); return
    if tmux_up(tsess(cid)): pause(f"Stop '{cname(cid)}' before creating a backup."); return
    sdir=snap_dir(cid); sdir.mkdir(parents=True,exist_ok=True)
    sid=rand_snap_id(sdir)
    v=finput(f'Backup name:\n  (leave blank for random: {sid})')
    if v is None: return
    sid=re.sub(r'[^a-zA-Z0-9_\-]','',v) or sid
    if (sdir/sid).is_dir(): pause(f"Backup '{sid}' already exists."); return
    ts=time.strftime('%Y-%m-%d %H:%M')
    if not btrfs_snap(ip,sdir/sid):
        shutil.copytree(str(ip),str(sdir/sid))
    snap_meta_set(sdir,sid,type='manual',ts=ts)
    pause(f"Backup '{sid}' created.")

def restore_snap(cid: str, snap_path: Path, snap_label: str):
    n=cname(cid); ip=cpath(cid)
    if not confirm(f"Restore '{n}' from '{snap_label}'?\n\n  Current installation will be overwritten.\n  Persistent storage profiles are untouched."): return
    _run(['btrfs','property','set',str(snap_path),'ro','false'],capture=True)
    if ip and ip.is_dir(): btrfs_delete(ip)
    if not btrfs_snap(snap_path,ip,readonly=False):
        shutil.copytree(str(snap_path),str(ip))
    _run(['btrfs','property','set',str(snap_path),'ro','true'],capture=True)
    pause(f"Restored '{n}' from '{snap_label}'.")

def clone_from_snap(src_cid: str, snap_path: Path, snap_label: str, clone_name: str):
    if not snap_path.is_dir(): pause('Snapshot not found.'); return
    if not clone_name: pause('No name given.'); return
    new_cid=rand_id()
    clone_dir=G.containers_dir/new_cid; clone_dir.mkdir(parents=True,exist_ok=True)
    clone_path=G.installations_dir/new_cid
    for f in ('service.json','state.json','resources.json'):
        src=G.containers_dir/src_cid/f
        if src.exists(): shutil.copy(str(src),str(clone_dir/f))
    try:
        data=json.loads((clone_dir/'state.json').read_text())
        data['name']=clone_name; data['install_path']=new_cid
        (clone_dir/'state.json').write_text(json.dumps(data,indent=2))
    except: pass
    if not btrfs_snap(snap_path,clone_path,readonly=False):
        shutil.copytree(str(snap_path),str(clone_path))
    pause(f"Cloned '{cname(src_cid)}' ({snap_label}) → '{clone_name}'")

# ══════════════════════════════════════════════════════════════════════════════
# services/ubuntu.py — Ubuntu base management
# ══════════════════════════════════════════════════════════════════════════════

def ub_cache_check():
    try:
        if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists(): return
    except Exception: return
    drift_f = G.sd_mnt_base/'.tmp'/f'.sd_ub_drift_{os.getpid()}'
    upd_f   = G.sd_mnt_base/'.tmp'/f'.sd_ub_upd_{os.getpid()}'
    saved = G.ubuntu_dir/'.ubuntu_default_pkgs'
    cur   = sorted(DEFAULT_UBUNTU_PKGS.split())
    drift = (sorted(saved.read_text().splitlines()) != cur) if saved.exists() else True
    drift_f.write_text('true' if drift else 'false')
    upd_f.write_text('false')  # written immediately so ub_cache_read never blocks
    stamp = G.ubuntu_dir/'.sd_last_apt_update'
    last  = int(stamp.read_text().strip()) if stamp.exists() else 0
    if time.time() - last > 86400:
        r = _run(['sudo','-n','chroot',str(G.ubuntu_dir),'bash','-c',
                  'apt-get update -qq 2>/dev/null; '
                  'apt-get --simulate upgrade 2>/dev/null | grep -c "^Inst "'],
                 capture=True)
        has_upd = (r.stdout.strip() != '0') if r.returncode == 0 else False
        upd_f.write_text('true' if has_upd else 'false')
        stamp.write_text(str(int(time.time())))

def ub_cache_read():
    if G.ub_cache_loaded: return
    # Non-blocking: only consume files if BOTH are ready (bg thread writes drift first, upd second)
    try:
        drift_f = G.sd_mnt_base/'.tmp'/f'.sd_ub_drift_{os.getpid()}'
        upd_f   = G.sd_mnt_base/'.tmp'/f'.sd_ub_upd_{os.getpid()}'
        if not drift_f.exists() or not upd_f.exists(): return  # still computing, keep defaults
        G.ub_cache_loaded = True
        for f, attr in [(drift_f,'ub_pkg_drift'), (upd_f,'ub_has_updates')]:
            try:
                setattr(G, attr, f.read_text().strip() == 'true')
                f.unlink(missing_ok=True)
            except OSError:
                pass  # img unmounted mid-read, keep False
    except OSError:
        pass  # .tmp dir gone (e.g. after failed resize), silently keep defaults

def _ubuntu_pkg_list() -> list:
    if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists(): return []
    r=_run(['sudo','-n','chroot',str(G.ubuntu_dir),'dpkg-query','-W',
            '-f=${binary:Package}\t${Version}\t${Essential}\n'], capture=True)
    pkgs=[]
    for line in r.stdout.splitlines():
        parts=line.split('\t')
        if len(parts)>=2: pkgs.append((parts[0],parts[1],parts[2].strip()=='yes' if len(parts)>2 else False))
    return pkgs

def _guard_ubuntu_pkg() -> bool:
    """Return True if safe to proceed. If sdUbuntuPkg running, offer Attach/Kill."""
    if not tmux_up('sdUbuntuPkg'): return True
    sel = menu(f'{BLD}⚠  Ubuntu pkg operation in progress{NC}',
               '→  Attach', '×  Kill')
    if not sel: return False
    sc = clean(sel)
    if '→' in sc or 'Attach' in sc:
        _tmux('switch-client','-t','sdUbuntuPkg')
        return False
    if '×' in sc or 'Kill' in sc:
        if not confirm('Kill the running operation?'): return False
        _tmux('kill-session','-t','sdUbuntuPkg')
        return True
    return False

def _ubuntu_pkg_op(sess: str, title: str, apt_cmd: str):
    ok_f=G.ubuntu_dir/'.upkg_ok'; fail_f=G.ubuntu_dir/'.upkg_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    ub = str(G.ubuntu_dir)
    # Runner in sd_mnt_base/.tmp — outside image, survives mount/unmount
    _ub_tmp = G.sd_mnt_base/'.tmp'
    _ub_tmp.mkdir(parents=True, exist_ok=True)
    runner = tempfile.NamedTemporaryFile(mode='w', dir=str(_ub_tmp),
                                         suffix='.sh', delete=False, prefix='.sd_ubpkg_')
    runner.write(
        f'#!/bin/bash\nset -euo pipefail\n'
        f'_cleanup(){{ local rc=$?; '
        f'sudo -n umount -lf {ub}/dev {ub}/sys {ub}/proc 2>/dev/null||true; '
        f'[[ $rc -ne 0 ]] && touch {str(fail_f)!r} || touch {str(ok_f)!r}; '
        f'tmux kill-session -t {sess} 2>/dev/null||true; }}\n'
        f'trap _cleanup EXIT\n'
        f'sudo -n mount --bind /proc {ub}/proc\n'
        f'sudo -n mount --bind /sys  {ub}/sys\n'
        f'sudo -n mount --bind /dev  {ub}/dev\n'
        f'sudo -n chroot {ub!r} /usr/bin/env DEBIAN_FRONTEND=noninteractive sh -c {apt_cmd!r}\n'
    )
    runner.close(); os.chmod(runner.name, 0o755)
    lf = str(G.logs_dir/f'{sess}.log') if G.logs_dir else ''
    if not launch_job(sess, title,
                      f'bash {runner.name!r}; rm -f {runner.name!r}',
                      str(ok_f), str(fail_f), lf):
        os.unlink(runner.name); return
    _installing_wait_loop(sess, str(ok_f), str(fail_f), title)
    G.ub_cache_loaded = False

def _installing_wait_loop(sess: str, ok_f: str, fail_f: str, title: str):
    """Re-entry wait menu — shown only when navigating to a menu where a job is already running.
    Auto-closes when job finishes. Attach switches to the session."""
    use_sess_exit = (ok_f == '/dev/null' and fail_f == '/dev/null')
    items = [f'{DIM}→  Attach to {title}{NC}', _nav_sep(), _back_item()]
    while True:
        if not tmux_up(sess): return   # already done, skip menu entirely
        done_evt = threading.Event()
        def _watch(evt=done_evt):
            if use_sess_exit:
                while tmux_up(sess): time.sleep(0.3)
            else:
                while not Path(ok_f).exists() and not Path(fail_f).exists():
                    if not tmux_up(sess): break
                    time.sleep(0.3)
            evt.set()
        wt = threading.Thread(target=_watch); wt.start()
        proc = subprocess.Popen(
            ['fzf'] + FZF_BASE + [f'--header={BLD}── {title} ──{NC}'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        G.active_fzf_pid = proc.pid
        proc.stdin.write(('\n'.join(items)+'\n').encode()); proc.stdin.close()
        def _kill_when_done(p=proc, evt=done_evt):
            evt.wait()
            try: p.kill()
            except: pass
        threading.Thread(target=_kill_when_done).start()
        out, _ = proc.communicate()
        G.active_fzf_pid = None
        if done_evt.is_set(): os.system('clear'); return
        sel = out.decode().strip()
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if 'Attach' in sel and tmux_up(sess):
            _tmux('switch-client', '-t', sess)
            continue


def launch_job(sess: str, title: str, cmd: str,
               ok_f: str = '/dev/null', fail_f: str = '/dev/null',
               log_f: str = '') -> bool:
    """Show Attach/Background prompt, start tmux session.
    Attach → switch-client (user watches live, returns to caller menu on detach).
    Background → start silently, return immediately to prev menu.
    Returns False if user cancelled (Escape)."""
    sel = fzf_run(
        [f'{GRN}▶  Attach — follow live output{NC}',
         f'{DIM}   Background — run silently{NC}'],
        header=(f'{BLD}── {title} ──{NC}\n'
                f'{DIM}  Press {KB["tmux_detach"]} to detach without stopping.{NC}'))
    if sel is None:
        return False
    # Log to caller-supplied log_f; only add internal tmp_dir log if it's outside the image
    # (tmp_dir is inside the image during normal ops — don't double-log to an about-to-unmount path)
    tmp_lf = ''
    if G.tmp_dir and G.mnt_dir:
        _tl = G.tmp_dir/f'{sess}.log'
        # Only use internal log if tmp_dir is NOT under mnt_dir (i.e. it's the fallback external path)
        if not str(_tl).startswith(str(G.mnt_dir)):
            tmp_lf = str(_tl)
    if log_f and tmp_lf and log_f != tmp_lf:
        full_cmd = f'{cmd} 2>&1 | tee -a {log_f!r} {tmp_lf!r}'
    elif log_f:
        full_cmd = f'{cmd} 2>&1 | tee -a {log_f!r}'
    elif tmp_lf:
        full_cmd = f'{cmd} 2>&1 | tee -a {tmp_lf!r}'
    else:
        full_cmd = cmd
    tmux_launch(sess, full_cmd)  # logging handled above via tee
    if 'Attach' in strip_ansi(sel):
        _tmux('switch-client', '-t', sess)
    # Background: return immediately — caller menu redraws, job runs silently
    return True


def wait_for_job(sess: str, ok_f: str, fail_f: str, title: str):
    """Post-launch wait loop — shows Attach option, auto-closes when done.
    Alias kept: _installing_wait_loop → wait_for_job."""
    _installing_wait_loop(sess, ok_f, fail_f, title)

def _proxy_pidfile() -> Path: return G.mnt_dir/'.sd/.caddy.pid'
def _proxy_caddyfile() -> Path: return G.mnt_dir/'.sd/Caddyfile'

# ══════════════════════════════════════════════════════════════════════════════
# menus/encryption.py — LUKS key management menu
# ══════════════════════════════════════════════════════════════════════════════

def enc_menu():
    """Full encryption management menu. Matches .sh _enc_menu exactly."""
    while True:
        if not G.img_path or not G.mnt_dir: return
        os.system('clear')
        auto    = enc_auto_unlock_enabled()
        agnostic= enc_system_agnostic_enabled()
        auto_lbl= f'{GRN}Enabled{NC}' if auto else f'{RED}Disabled{NC}'
        ag_lbl  = f'{GRN}Enabled{NC}' if agnostic else f'{RED}Disabled{NC}'
        vdir    = enc_verified_dir()
        vid     = enc_verified_id()
        slots_used  = enc_slots_used()
        slots_total = SD_LUKS_SLOT_MAX - SD_LUKS_SLOT_MIN + 1
        auth_slot   = enc_authkey_slot()

        # Collect verified system IDs from cache dir
        vs_ids = ([f.name for f in vdir.iterdir() if f.is_file()] if vdir.is_dir() else [])

        # Build set of slots occupied by verified systems (using enc_vs_slot, NOT snap_meta_get)
        vs_slot_set = set()
        for vsid in vs_ids:
            sl = enc_vs_slot(vsid)
            if sl and sl != '0': vs_slot_set.add(sl)

        # Passkeys: active slots in user range not used by vs or auth
        r = _sudo('cryptsetup','luksDump',str(G.img_path), capture=True)
        pk_slots = []
        for m in re.finditer(r'^\s+(\d+): luks2', r.stdout, re.M):
            sl = m.group(1)
            if sl == '0': continue
            if sl == auth_slot: continue
            if sl == '1': continue          # slot 1 = default keyword
            if sl in vs_slot_set: continue
            if not (SD_LUKS_SLOT_MIN <= int(sl) <= SD_LUKS_SLOT_MAX): continue
            pk_slots.append(sl)

        nf = G.mnt_dir/'.sd/keyslot_names.json'
        try: slot_names = json.loads(nf.read_text()) if nf.exists() else {}
        except: slot_names = {}

        items = [
            _sep('General'),
            f' {DIM}◈  System Agnostic: {ag_lbl}{NC}',
            f' {DIM}◈  Auto-Unlock: {auto_lbl}{NC}',
            f' {DIM}◈  Reset Auth Token{NC}',
            _sep('Verified Systems'),
        ]
        for vsid in vs_ids:
            host = enc_vs_hostname(vsid)
            items.append(f' {DIM}◈  {host}  [vs:{vsid}]{NC}')
        items.append(f' {GRN}+  Verify this system{NC}')
        items.append(_sep('Passkeys'))
        if not pk_slots:
            items.append(f'{DIM}  (no passkeys added yet){NC}')
        for sl in pk_slots:
            nm = slot_names.get(sl, f'Key {sl}')
            items.append(f' {DIM}◈  {nm}  [s:{sl}]{NC}')
        items.append(f' {GRN}+  Add Key{NC}')
        items += [_nav_sep(), _back_item()]

        sel = fzf_run(items, header=f'{BLD}── Manage Encryption ──{NC}  {DIM}{slots_used}/{slots_total} slots{NC}')
        if sel is None:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if sc == L['back'] or not sc: return

        # ── System Agnostic toggle (slot 1 = SD_DEFAULT_KEYWORD) ────────────
        if 'System Agnostic' in sc:
            if agnostic:
                # Lockout check: need at least one other method
                active_vs = sum(1 for vsid in vs_ids if enc_vs_slot(vsid) not in ('','0'))
                if not pk_slots and active_vs == 0:
                    pause('Cannot disable — no other unlock method exists.\nAdd a passkey or verify a system first.'); continue
                if not confirm('Disable System Agnostic?\nThis image will no longer open on unknown machines.'): continue
                # Auth with auth key if valid, else prompt
                # Shell fallback: if auth.key invalid, use SD_DEFAULT_KEYWORD (the key in slot 1)
                # as authorisation — the image was opened via that key, so it must be valid.
                # Python previously prompted the user, which diverges from .sh behaviour.
                if enc_authkey_valid():
                    rc = subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                         '--key-file','-',str(G.img_path),'1'],
                                        input=_authkey_bytes(), capture_output=True).returncode
                else:
                    rc = subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                         '--key-file','-',str(G.img_path),'1'],
                                        input=SD_DEFAULT_KEYWORD.encode(), capture_output=True).returncode
                pause('System Agnostic disabled.' if rc==0 else 'Failed.')
            else:
                if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth Token first.'); continue
                rc = subprocess.run(
                    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                     '--key-slot','1','--key-file','-',str(G.img_path)],
                    input=SD_DEFAULT_KEYWORD.encode(), capture_output=True).returncode
                pause('System Agnostic enabled.' if rc==0 else 'Failed.')

        # ── Auto-Unlock toggle (verified system slots) ───────────────────────
        elif 'Auto-Unlock' in sc:
            if auto:
                if not pk_slots:
                    pause('Cannot disable Auto-Unlock — no passkeys exist.\nAdd a passkey first so you can still open the image.'); continue
                if not confirm('Disable Auto-Unlock? All verified system LUKS slots will be removed (cache kept).'): continue
                if not enc_authkey_valid(): pause('Auth keyfile missing.'); continue
                ok = True
                for vsid in vs_ids:
                    sl = enc_vs_slot(vsid)
                    if not sl or sl == '0': continue
                    rc = subprocess.run(
                        ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                         '--key-file','-',str(G.img_path),sl],
                        input=_authkey_bytes(), capture_output=True).returncode
                    if rc != 0: ok = False
                    # Clear slot in cache file but keep hostname and pass for re-enable
                    lines = (vdir/vsid).read_text().splitlines()
                    while len(lines) < 3: lines.append('')
                    lines[1] = ''   # clear slot number
                    (vdir/vsid).write_text('\n'.join(lines))
                pause('Auto-Unlock disabled.' if ok else 'Partially failed.')
            else:
                if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth first.'); continue
                ok = True; count = 0
                for vsid in vs_ids:
                    vspass = enc_vs_pass(vsid)
                    if not vspass: continue
                    free = enc_free_slot()
                    if not free: pause('No free slots.'); ok = False; break
                    rc = subprocess.run(
                        ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                         '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                         '--key-slot',free,'--key-file','-',str(G.img_path)],
                        input=vspass.encode(), capture_output=True).returncode
                    if rc == 0:
                        enc_vs_write(vsid, free); count += 1
                    else: ok = False
                if ok: pause(f'Auto-Unlock enabled ({count} system(s) restored).')
                else: pause('Partially failed.')

        # ── Reset Auth Token ─────────────────────────────────────────────────
        elif 'Reset Auth Token' in sc:
            ok, new_slot, err = enc_authkey_rotate()
            if ok:
                pause(f'Auth token rotated successfully.\nNew key in LUKS slot {new_slot} (auth.key updated).')
            else:
                # Rotation requires a valid auth.key. If it's missing/invalid,
                # offer a one-time bootstrap via passphrase so the user can
                # get back to a clean state.
                # Auto-create auth key using known keys (no passphrase needed)
                _existing2 = None
                for _k2 in [G.verification_cipher.encode(), SD_DEFAULT_KEYWORD.encode()]:
                    if subprocess.run(['sudo','-n','cryptsetup','open','--test-passphrase',
                                       '--batch-mode','--key-file=-',str(G.img_path)],
                                      input=_k2, capture_output=True).returncode == 0:
                        _existing2 = _k2; break
                if _existing2 is None:
                    pause(f'Cannot auto-create auth key.\n{err}'); continue
                import tempfile as _tf3
                _tmp_e2 = Path(_tf3.mktemp(prefix='.sd_ek2_'))
                try:
                    _tmp_e2.write_bytes(_existing2); _tmp_e2.chmod(0o600)
                    if enc_authkey_create(_tmp_e2):
                        pause('Auth key created automatically.')
                    else:
                        pause(f'Auth key creation failed: {err}')
                finally:
                    _tmp_e2.unlink(missing_ok=True)
                continue
                _base_tmp = G.sd_mnt_base/'.tmp'
                _base_tmp.mkdir(parents=True, exist_ok=True)
                _tf = Path(tempfile.mktemp(dir=str(_base_tmp), prefix='.sd_rak_'))
                _tf.write_bytes(pw.encode()); _tf.chmod(0o600)
                try:
                    # Kill stale slot 0 if it exists
                    _old = enc_authkey_path()
                    if _old.exists():
                        subprocess.run(
                            ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                             '--key-file', str(_tf), str(G.img_path), '0'],
                            capture_output=True)
                        _old.unlink(missing_ok=True)
                    ok2 = enc_authkey_create(_tf)
                finally:
                    _tf.unlink(missing_ok=True)
                os.system('clear')
                if ok2:
                    pause('Auth token created in LUKS slot 0 (auth.key).\nFuture resets will be passwordless.')
                else:
                    pause('Bootstrap failed — wrong passphrase?')

        # ── Verify this system ───────────────────────────────────────────────
        elif 'Verify this system' in sc:
            vid = enc_verified_id()
            hostname = subprocess.run(['cat','/etc/hostname'], capture_output=True, text=True).stdout.strip() or 'unknown'
            if vid in vs_ids:
                sl = enc_vs_slot(vid)
                if sl and sl != '0':
                    pause(f'Already verified: {hostname} (slot {sl}).'); continue
                else:
                    pause('System cached but Auto-Unlock is disabled.\nEnable Auto-Unlock to activate it.'); continue
            if not enc_authkey_valid(): pause('Auth keyfile missing or invalid.\nUse Reset Auth first.'); continue
            if auto:
                free = enc_free_slot()
                if not free: pause(f'No free slots (slots {SD_LUKS_SLOT_MIN}–{SD_LUKS_SLOT_MAX} full).'); continue
                vspass = enc_verified_pass()
                rc = subprocess.run(
                    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                     '--key-slot',free,'--key-file','-',str(G.img_path)],
                    input=vspass.encode(), capture_output=True).returncode
                os.system('clear')
                if rc == 0:
                    enc_vs_write(vid, free)
                    pause(f'Verified: {hostname} (slot {free}, auto-unlock active).')
                else:
                    pause('Failed to add key slot.')
            else:
                enc_vs_write(vid, '')
                pause(f'Cached: {hostname} (Auto-Unlock disabled — enable to activate).')

        # ── Add passkey ──────────────────────────────────────────────────────
        elif 'Add Key' in sc:
            if not enc_authkey_valid(): pause('Auth keyfile missing.'); continue
            free = enc_free_slot()
            if not free: pause(f'No free slots ({SD_LUKS_SLOT_MIN}–{SD_LUKS_SLOT_MAX} full).'); continue
            # Parameter editor — matches .sh exactly
            import random as _random, string as _string
            kname   = ''.join(_random.choices(_string.ascii_lowercase+_string.digits, k=8))
            pbkdf   = 'argon2id'; ram = '262144'; threads = '4'; iter_ms = '1000'
            cipher  = 'aes-xts-plain64'; keybits = '512'; khash = 'sha256'; sector = '512'
            param_done = False
            while not param_done:
                param_items = [
                    _sep('Parameters'),
                    f'  {"name":<10}{CYN}{kname}{NC}',
                    f'  {"pbkdf":<10}{CYN}{pbkdf}{NC}',
                    f'  {"ram":<10}{CYN}{ram} KiB{NC}',
                    f'  {"threads":<10}{CYN}{threads}{NC}',
                    f'  {"iter-ms":<10}{CYN}{iter_ms}{NC}',
                    f'  {"cipher":<10}{CYN}{cipher}{NC}',
                    f'  {"key-bits":<10}{CYN}{keybits}{NC}',
                    f'  {"hash":<10}{CYN}{khash}{NC}',
                    f'  {"sector":<10}{CYN}{sector}{NC}',
                    _sep('Navigation'),
                    f'{GRN}▷  Continue{NC}',
                    f'{RED}×  Cancel{NC}',
                ]
                psel = fzf_run(param_items,
                    header=f'{BLD}── Encryption parameters ──{NC}\n{DIM}  Select a param to change it.{NC}')
                if not psel: break
                psc = clean(psel)
                if '▷' in psc or 'Continue' in psc: param_done = True
                elif '×' in psc or 'Cancel' in psc: break
                elif 'name' in psc:
                    v = finput(f'Key name (blank = {kname}):')
                    if v is not None: kname = v.strip() or kname
                elif 'pbkdf' in psc:
                    v = fzf_run(['argon2id','argon2i','pbkdf2'],
                                header=f'{BLD}── pbkdf ──{NC}')
                    if v: pbkdf = clean(v)
                elif 'ram' in psc:
                    v = finput('RAM in KiB (e.g. 262144 = 256 MB):')
                    if v and v.strip().isdigit(): ram = v.strip()
                elif 'threads' in psc:
                    v = finput('Threads (e.g. 4):')
                    if v and v.strip().isdigit(): threads = v.strip()
                elif 'iter-ms' in psc:
                    v = finput('Iteration time in ms (e.g. 1000):')
                    if v and v.strip().isdigit(): iter_ms = v.strip()
                elif 'cipher' in psc:
                    v = fzf_run(['aes-xts-plain64','chacha20-poly1305'],
                                header=f'{BLD}── cipher ──{NC}')
                    if v: cipher = clean(v)
                elif 'key-bits' in psc:
                    v = fzf_run(['256','512'], header=f'{BLD}── key-bits ──{NC}')
                    if v: keybits = clean(v)
                elif 'hash' in psc:
                    v = fzf_run(['sha256','sha512','sha1'],
                                header=f'{BLD}── hash ──{NC}')
                    if v: khash = clean(v)
                elif 'sector' in psc:
                    v = fzf_run(['512','1024','2048','4096'],
                                header=f'{BLD}── sector size ──{NC}')
                    if v: sector = clean(v)
            if not param_done: continue
            os.system('clear')
            print(f'\n  {BLD}── Add Key: {kname} ──{NC}\n')
            try:
                pw  = _read_password(f'  Passphrase for "{kname}": ')
                pw2 = _read_password(f'  Confirm passphrase for "{kname}": ')
            except (KeyboardInterrupt, EOFError):
                os.system('clear'); continue
            os.system('clear')
            if pw != pw2: pause('Passphrases do not match.'); continue
            extra_args = []
            if pbkdf == 'pbkdf2':
                extra_args = ['--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash',khash,
                              '--cipher',cipher,'--key-size',keybits,'--sector-size',sector]
            else:
                extra_args = ['--pbkdf',pbkdf,'--pbkdf-memory',ram,
                              '--pbkdf-parallel',threads,'--iter-time',iter_ms,
                              '--cipher',cipher,'--key-size',keybits,'--hash',khash,
                              '--sector-size',sector]
            rc = subprocess.run(
                ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                 *extra_args,'--key-slot',free,
                 '--key-file','-',str(G.img_path)],
                input=pw.encode(), capture_output=True).returncode
            if rc == 0:
                nf.parent.mkdir(parents=True, exist_ok=True)
                try: names = json.loads(nf.read_text()) if nf.exists() else {}
                except: names = {}
                names[free] = kname; nf.write_text(json.dumps(names, indent=2))
                pause(f"Key '{kname}' added (slot {free}).")
            else:
                pause('Failed to add key.')

        # ── Unauthorize a verified system ────────────────────────────────────
        elif '[vs:' in sc:
            m = re.search(r'\[vs:([^\]]+)\]', sc)
            if not m: continue
            vsid = m.group(1)
            host = enc_vs_hostname(vsid)
            action = menu(f'{host}', 'Unauthorize', 'Cancel')
            if not action or 'Cancel' in action: continue
            # Lockout check
            active_vs = sum(1 for v in vs_ids if v != vsid and enc_vs_slot(v) not in ('','0'))
            if vsid == vid and auto and not pk_slots and active_vs == 0:
                pause('Cannot unauthorize — this is the only unlock method.\nAdd a passkey first.'); continue
            if not confirm(f"Unauthorize '{host}'?"): continue
            sl = enc_vs_slot(vsid)
            ok = True
            if sl and sl != '0':
                if enc_authkey_valid():
                    rc = subprocess.run(
                        ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                         '--key-file','-',str(G.img_path),sl],
                        input=_authkey_bytes(), capture_output=True).returncode
                else:
                    rc = subprocess.run(
                        ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                         '--key-file=-',str(G.img_path),sl],
                        input=G.verification_cipher.encode(), capture_output=True).returncode
                if rc != 0: ok = False
            (vdir/vsid).unlink(missing_ok=True)
            pause('Unauthorize complete.' if ok else 'Slot removal failed (cache entry removed).')

        # ── Delete a passkey ─────────────────────────────────────────────────
        elif '[s:' in sc:
            m = re.search(r'\[s:([^\]]+)\]', sc)
            if not m: continue
            sl = m.group(1)
            nm = slot_names.get(sl, f'Key {sl}')
            action = menu(f'{nm}', 'Rename', 'Remove', 'Cancel')
            if not action or 'Cancel' in action: continue
            if 'Rename' in action:
                v = finput(f'New name for "{nm}":')
                if not v: continue
                nf.parent.mkdir(parents=True, exist_ok=True)
                try: names = json.loads(nf.read_text()) if nf.exists() else {}
                except: names = {}
                names[sl] = v.strip(); nf.write_text(json.dumps(names, indent=2))
                pause(f'Renamed to "{v.strip()}".')
                continue
            # Remove
            active_vs = sum(1 for vsid in vs_ids if enc_vs_slot(vsid) not in ('','0'))
            if not auto and len(pk_slots) <= 1:
                pause('Cannot remove — Auto-Unlock is disabled.\nKeep at least one passkey or re-enable Auto-Unlock first.'); continue
            if auto and len(pk_slots) <= 1 and active_vs == 0:
                pause('Cannot remove — this is the only non-auto-unlock key.\nVerify a system or keep this key.'); continue
            if not confirm(f"Delete key '{nm}' (slot {sl})?"): continue
            if enc_authkey_valid():
                rc = subprocess.run(
                    ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                     '--key-file','-',str(G.img_path),sl],
                    input=_authkey_bytes(), capture_output=True).returncode
            else:
                pw = finput(f'Passphrase for "{nm}" to authorise removal:')
                if not pw: continue
                rc = subprocess.run(
                    ['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                     '--key-file=-',str(G.img_path),sl],
                    input=pw.encode(), capture_output=True).returncode
            if rc == 0:
                try:
                    names = json.loads(nf.read_text()) if nf.exists() else {}
                    names.pop(sl, None)
                    nf.write_text(json.dumps(names, indent=2))
                except: pass
                pause(f"Key '{nm}' deleted.")
            else:
                pause('Failed to delete key.')

# ══════════════════════════════════════════════════════════════════════════════
# menus/storage.py — persistent storage / profiles
# ══════════════════════════════════════════════════════════════════════════════

def _stor_count(cid: str) -> int:
    if not _stor_type_from_sj(cid): return 0
    try:
        d = json.loads((G.containers_dir/cid/'service.json').read_text())
        return len(d.get('storage', []))
    except: return 0

def _stor_meta_path(scid: str) -> Path:
    return G.storage_dir/scid/'.sd_meta.json'

def _stor_read_field(scid: str, key: str) -> str:
    mp = _stor_meta_path(scid)
    try: return json.loads(mp.read_text()).get(key,'') or ''
    except: return ''

def _stor_read_name(scid: str) -> str:   return _stor_read_field(scid,'name')
def _stor_read_type(scid: str) -> str:   return _stor_read_field(scid,'storage_type')
def _stor_read_active(scid: str) -> str: return _stor_read_field(scid,'active_container')
def _stor_clear_active(scid: str):
    mp = _stor_meta_path(scid)
    try:
        d = json.loads(mp.read_text()) if mp.exists() else {}
        d['active_container'] = ''
        mp.write_text(json.dumps(d, indent=2))
    except: pass

def _stor_meta_set_fields(scid: str, **kwargs):
    mp = _stor_meta_path(scid)
    try: d = json.loads(mp.read_text()) if mp.exists() else {}
    except: d = {}
    d.update(kwargs)
    mp.write_text(json.dumps(d, indent=2))

def _stor_type_from_sj(cid: str) -> str:
    try: return json.loads((G.containers_dir/cid/'service.json').read_text()).get('meta',{}).get('storage_type','') or ''
    except: return ''

def _stor_path(scid: str) -> Path:
    return G.storage_dir/scid

def _stor_paths(cid: str) -> List[str]:
    try:
        d = json.loads((G.containers_dir/cid/'service.json').read_text())
        return [p for p in d.get('storage', []) if p]
    except: return []

def _stor_set_active(scid: str, cid: str):
    _stor_meta_set_fields(scid, active_container=cid)

def _stor_unlink(cid: str, install_path: Path):
    """Remove storage symlinks, recreate empty dirs. Matches shell _stor_unlink."""
    for rel in _stor_paths(cid):
        link = install_path/rel
        if link.is_symlink():
            link.unlink()
            link.mkdir(parents=True, exist_ok=True)

def _stor_link(cid: str, install_path: Path, scid: str):
    """Establish storage symlinks for a container. Matches shell _stor_link exactly."""
    sdir = _stor_path(scid)
    sdir.mkdir(parents=True, exist_ok=True)
    active = set(_stor_paths(cid))
    # Handle paths previously in storage_paths that are no longer active
    try:
        prev_paths = json.loads(_state_file(cid).read_text()).get('storage_paths', [])
    except: prev_paths = []
    for prev in prev_paths:
        if not prev or prev in active: continue
        real_path = sdir/prev
        link_path = install_path/prev
        if not real_path.is_dir(): continue
        if link_path.is_symlink(): link_path.unlink()
        link_path.mkdir(parents=True, exist_ok=True)
        try:
            if any(real_path.iterdir()):
                _run(['cp','-a',str(real_path)+'/.', str(link_path)+'/'])
        except: pass
        shutil.rmtree(str(real_path), ignore_errors=True)
    # For each active path: copy dir data to storage, replace with symlink
    for rel in active:
        real_path = sdir/rel
        link_path = install_path/rel
        real_path.mkdir(parents=True, exist_ok=True)
        (link_path.parent).mkdir(parents=True, exist_ok=True)
        if link_path.is_symlink(): link_path.unlink()
        if link_path.is_dir():
            try:
                if any(link_path.iterdir()):
                    _run(['cp','-a',str(link_path)+'/.', str(real_path)+'/'])
            except: pass
            shutil.rmtree(str(link_path), ignore_errors=True)
        link_path.symlink_to(real_path)
    # Update state.json with storage_id and storage_paths
    try:
        data = json.loads(_state_file(cid).read_text())
    except: data = {}
    data['storage_id'] = scid
    data['storage_paths'] = list(active)
    _state_file(cid).write_text(json.dumps(data, indent=2))
    _stor_set_active(scid, cid)

def _auto_pick_storage_profile(cid: str) -> Optional[str]:
    """Priority: default profile → last used → any free → create new. Matches shell."""
    stype = _stor_type_from_sj(cid)
    if not G.storage_dir or not G.storage_dir.is_dir():
        return _stor_create_profile_silent(cid, stype)
    # 1. Default profile
    def_scid = st(cid, 'default_storage_id', '')
    if def_scid and (_stor_path(def_scid)).is_dir():
        ac = _stor_read_active(def_scid)
        if not ac or ac == cid or not tmux_up(tsess(ac)):
            if ac and ac != cid: _stor_clear_active(def_scid)
            return def_scid
    # 2. Last used
    last_scid = st(cid, 'storage_id', '')
    if last_scid and (_stor_path(last_scid)).is_dir():
        ac = _stor_read_active(last_scid)
        if not ac or ac == cid or not tmux_up(tsess(ac)):
            if ac and ac != cid: _stor_clear_active(last_scid)
            return last_scid
    # 3. Any free profile matching storage_type
    for sdir in sorted(G.storage_dir.iterdir()):
        if not sdir.is_dir(): continue
        scid = sdir.name
        if _stor_read_type(scid) != stype: continue
        ac = _stor_read_active(scid)
        if not ac or ac == cid or not tmux_up(tsess(ac)):
            if ac and ac != cid: _stor_clear_active(scid)
            return scid
    # 4. Create new
    return _stor_create_profile_silent(cid, stype)

def _stor_create_profile_silent(cid: str, stype: str) -> str:
    """Create a new storage profile silently. Matches shell _stor_create_profile_silent."""
    import random, string
    while True:
        new_scid = ''.join(random.choices(string.ascii_lowercase+string.digits, k=8))
        if not (_stor_path(new_scid)).exists(): break
    (_stor_path(new_scid)).mkdir(parents=True, exist_ok=True)
    _stor_meta_set_fields(new_scid, storage_type=stype, name='Default',
                          created=time.strftime('%Y-%m-%d'), active_container='')
    set_st(cid, 'default_storage_id', new_scid)
    return new_scid

def _stor_create_profile(cid: str, stype: str, pname: str = 'Default') -> Optional[str]:
    """Create a named storage profile, rejecting duplicates. Matches shell _stor_create_profile."""
    pname = re.sub(r'[^a-zA-Z0-9_\- ]', '', pname) or 'Default'
    if G.storage_dir and G.storage_dir.is_dir():
        for sdir in G.storage_dir.iterdir():
            if not sdir.is_dir(): continue
            if (_stor_read_name(sdir.name) == pname and
                    _stor_read_type(sdir.name) == stype):
                pause(f"A profile named '{pname}' already exists for this type."); return None
    return _stor_create_profile_silent(cid, stype)


def _pick_storage_profile(cid: str) -> Optional[str]:
    stype = _stor_type_from_sj(cid)
    if _stor_count(cid) == 0: return ''
    if not G.storage_dir or not G.storage_dir.is_dir():
        v = finput('New storage profile name:\n  (leave blank for Default)')
        if v is None: return None
        return _stor_create_profile(cid, stype, v or 'Default')
    options: list = []; scid_map: list = []
    new_label = f'{GRN}+  New profile\u2026{NC}'
    for sdir in sorted(G.storage_dir.iterdir()):
        if not sdir.is_dir(): continue
        scid = sdir.name
        if _stor_read_type(scid) != stype: continue
        pname = _stor_read_name(scid) or '(unnamed)'
        try: sz = _run(['du','-sh',str(sdir)], capture=True).stdout.split()[0]
        except: sz = '?'
        active_cid = _stor_read_active(scid)
        if active_cid and active_cid != cid and tmux_up(tsess(active_cid)):
            options.append(f'{DIM}\u25cb  {pname}  [{scid}]  {sz}  \u2014 in use by {cname(active_cid)}{NC}')
            scid_map.append('__inuse__'); continue
        elif active_cid and active_cid != cid:
            _stor_clear_active(scid)
        options.append(f'\u25cf  {pname}  [{scid}]  {sz}'); scid_map.append(scid)
    options.append(new_label); scid_map.append('__new__')
    sel = fzf_run(options, header=f'{BLD}\u2500\u2500 Storage profile \u2500\u2500{NC}')
    if not sel: return None
    sc = clean(sel)
    for i, opt in enumerate(options):
        if clean(opt) == sc:
            mapped = scid_map[i]
            if mapped == '__inuse__': pause('That profile is in use by another running container.'); return None
            if mapped == '__new__':
                v = finput('New storage profile name:\n  (leave blank for Default)')
                if v is None: return None
                return _stor_create_profile(cid, stype, v or 'Default')
            return mapped
    return None

def persistent_storage_menu(cid: str=''):
    """Unified storage menu — matches shell _persistent_storage_menu exactly.
    Shows all profiles across all containers when cid='', or filters by cid when set."""
    while True:
        if not G.storage_dir or not G.storage_dir.is_dir():
            pause('No storage directory found.'); return
        load_containers()
        all_cids = list(G.CT_IDS)

        entries = []; scids = []
        for sdir in sorted(G.storage_dir.iterdir()):
            if not sdir.is_dir(): continue
            scid = sdir.name
            # Filter by container context if provided
            if cid:
                # Only show profiles whose directory is under storage/cid
                if sdir.parent.name != G.storage_dir.name: continue
                # storage layout is storage_dir/scid — we need storage_dir/cid/pname
                # actually shell uses STORAGE_DIR/scid flat, not nested by cid
                pass
            try: sz = _run(['du','-sh',str(sdir)], capture=True).stdout.split()[0]
            except: sz = '?'
            pname = _stor_read_name(scid) or '(unnamed)'
            stype = _stor_read_type(scid)
            active_cid = _stor_read_active(scid)
            # Find which container this is the default for
            def_for = ''
            for c2 in all_cids:
                if st(c2,'default_storage_id','') == scid:
                    def_for = cname(c2); break
            # Filter by cid context
            if cid and active_cid != cid and def_for != cname(cid):
                # Only show profiles associated with this container
                # Shell shows all profiles but caller sets _ctx
                # We keep all profiles visible (matches shell unified list)
                pass
            base = f'{BLD}{pname}{NC}  {DIM}[{scid}]{NC}'
            if stype: base += f'  {DIM}({stype}){NC}'
            if active_cid and tmux_up(tsess(active_cid)):
                dot = f'{GRN}★{NC}' if def_for else f'{GRN}●{NC}'
                label = f'{dot}  {base:<40}  {DIM}{sz}  — running in {cname(active_cid)}{NC}'
            elif active_cid:
                _stor_clear_active(scid)
                dot = f'{YLW}★{NC}' if def_for else f'{YLW}○{NC}'
                label = f'{dot}  {base:<40}  {DIM}{sz}  [stale]{NC}'
            else:
                dot = f'{DIM}★{NC}' if def_for else f'{DIM}○{NC}'
                label = f'{dot}  {base:<40}  {DIM}{sz}{NC}'
            entries.append(label); scids.append(scid)

        entries.append(f'{BLD}  ── Backup data ──────────────────────{NC}'); scids.append('')
        exp_running = tmux_up('sdStorExport')
        imp_running = tmux_up('sdStorImport')
        if exp_running:
            entries.append(f'{YLW}↑{NC}{DIM}  Export running — click to manage{NC}'); scids.append('__export_running__')
        else:
            entries.append(f'{DIM}↑  Export{NC}'); scids.append('__export__')
        if imp_running:
            entries.append(f'{YLW}↓{NC}{DIM}  Import running — click to manage{NC}'); scids.append('__import_running__')
        else:
            entries.append(f'{DIM}↓  Import{NC}'); scids.append('__import__')

        if cid:
            hdr = (f'{BLD}── Profiles: {cname(cid)} ──{NC}\n'
                   f'{DIM}  {GRN}●{NC}{DIM} running  {YLW}○{NC}{DIM} stale  ○ free  {YLW}★{NC}{DIM} default{NC}')
        else:
            hdr = (f'{BLD}── Persistent storage ──{NC}\n'
                   f'{DIM}  {GRN}●{NC}{DIM} running  {YLW}○{NC}{DIM} stale  ○ free  {YLW}★{NC}{DIM} default{NC}')

        numbered = [f'{i:04d}\t{e}' for i, e in enumerate(entries)]
        sel = fzf_run(numbered, header=hdr, with_nth='2..', delimiter='\t')
        if not sel:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if clean(sel) == L['back']: return
        # Extract index from tab-delimited line
        try: sel_idx = int(strip_ansi(sel).split('\t')[0].strip())
        except: continue
        sel_scid = scids[sel_idx] if sel_idx < len(scids) else ''
        if not sel_scid: continue

        if sel_scid == '__export__':
            # Pick a container/profile to export
            if cid:
                d2 = G.storage_dir/cid
                profiles = sorted(d2.iterdir()) if d2.is_dir() else []
                if not profiles: pause('No profiles to export.'); continue
                psel = fzf_run([f' {DIM}◈{NC}  {p.name}' for p in profiles]+[_back_item()],
                               header=f'{BLD}── Export profile ──{NC}')
                if not psel or clean(psel)==L['back']: continue
                pname2 = clean(psel).lstrip('◈').strip()
                prof = next((p for p in profiles if p.name==pname2), None)
                if prof: _stor_export(cid, prof)
            else:
                # Global export: pick profile from all storage profiles
                all_scids = [d.name for d in sorted(G.storage_dir.iterdir()) if d.is_dir()]
                if not all_scids: pause('No storage profiles to export.'); continue
                opts = [f' {DIM}◈{NC}  {_stor_read_name(s) or s}  [{s}]' for s in all_scids]
                psel3 = fzf_run(opts + [_back_item()], header=f'{BLD}── Export: select profile ──{NC}')
                if not psel3 or clean(psel3) == L['back']: continue
                pidx3 = next((i for i,o in enumerate(opts) if clean(o) == clean(psel3)), -1)
                if pidx3 < 0: continue
                sel_scid3 = all_scids[pidx3]
                _stor_export(sel_scid3, G.storage_dir/sel_scid3)
            continue
        elif sel_scid == '__export_running__':
            sel2 = menu('Export running', 'Attach to export', 'Kill export')
            if not sel2: continue
            if 'Attach' in sel2: _tmux('switch-client','-t','sdStorExport')
            elif 'Kill' in sel2:
                if confirm('Kill the running export?'):
                    _tmux('kill-session','-t','sdStorExport'); pause('Export killed.')
            continue
        elif sel_scid == '__import__':
            if cid: _stor_import(cid)
            else: pause('Select a container first to import.')
            continue
        elif sel_scid == '__import_running__':
            sel2 = menu('Import running', 'Attach to import', 'Kill import')
            if not sel2: continue
            if 'Attach' in sel2: _tmux('switch-client','-t','sdStorImport')
            elif 'Kill' in sel2:
                if confirm('Kill the running import?'):
                    _tmux('kill-session','-t','sdStorImport'); pause('Import killed.')
            continue

        # Profile selected
        active_cid2 = _stor_read_active(sel_scid)
        if active_cid2 and tmux_up(tsess(active_cid2)):
            pause(f"Storage is currently running in '{cname(active_cid2)}'.\nStop the container first.")
            continue
        pname2 = _stor_read_name(sel_scid) or '(unnamed)'
        stype2 = _stor_read_type(sel_scid)
        # Find current default container
        cur_def_cid = ''
        for c2 in all_cids:
            if st(c2,'default_storage_id','') == sel_scid:
                cur_def_cid = c2; break
        # Determine action_ctx (which container to assign defaults to)
        action_ctx = cid
        if not action_ctx and stype2:
            matches = [c2 for c2 in all_cids if _stor_type_from_sj(c2) == stype2]
            if len(matches) == 1: action_ctx = matches[0]
        act_items = ['☆  Unset default' if cur_def_cid else '★  Set as default',
                     L['stor_rename'], L['stor_delete']]
        sel3 = menu(f'Storage: {pname2}', *act_items)
        if not sel3: continue
        sc3 = clean(sel3)
        if '☆' in sc3 or 'Unset' in sc3:
            set_st(cur_def_cid,'default_storage_id','')
            pause(f"'{pname2}' is no longer the default for {cname(cur_def_cid)}.")
        elif '★' in sc3 or 'Set as default' in sc3:
            if not action_ctx:
                ct_names = [cname(c2) for c2 in all_cids]
                psel2 = fzf_run(ct_names, header=f'{BLD}── Assign container ──{NC}')
                if not psel2: continue
                chosen = clean(psel2)
                action_ctx = next((c2 for c2 in all_cids if cname(c2)==chosen), '')
            if not action_ctx: continue
            old_def = st(action_ctx,'default_storage_id','')
            if old_def and old_def != sel_scid:
                if _stor_read_type(old_def) == stype2:
                    set_st(action_ctx,'default_storage_id','')
            set_st(action_ctx,'default_storage_id',sel_scid)
            pause(f"'{pname2}' set as default for {cname(action_ctx)}.")
        elif sc3 == L['stor_rename']:
            while True:
                v = finput(f"New name for '{pname2}':")
                if not v: break
                new_sname = re.sub(r'[^a-zA-Z0-9_\- ]','',v)
                if not new_sname: pause('Name cannot be empty.'); continue
                dup = any(_stor_read_name(sd.name)==new_sname and
                          _stor_read_type(sd.name)==stype2 and sd.name!=sel_scid
                          for sd in G.storage_dir.iterdir() if sd.is_dir())
                if dup: pause(f"A profile named '{new_sname}' already exists for this type."); continue
                _stor_meta_set_fields(sel_scid, name=new_sname)
                pause(f"Storage renamed to '{new_sname}'."); break
        elif sc3 == L['stor_delete']:
            try: sz_del = _run(['du','-sh',str(G.storage_dir/sel_scid)],capture=True).stdout.split()[0]
            except: sz_del = '?'
            if confirm(f"Permanently delete storage profile?\n\n  Name: {pname2}\n  ID:   {sel_scid}\n  Size: {sz_del}\n\n  This cannot be undone."):
                for c2 in all_cids:
                    if st(c2,'default_storage_id','') == sel_scid:
                        set_st(c2,'default_storage_id','')
                btrfs_delete(G.storage_dir/sel_scid)
                if (G.storage_dir/sel_scid).exists():
                    pause(f"Could not delete '{pname2}' — try stopping all containers first.")
                else:
                    pause(f"Storage '{pname2}' deleted.")

def _stor_export(cid: str, profile: Path):
    """Export a storage profile to a .tar.zst archive — matches shell _stor_export_menu."""
    dest_dir = pick_dir()
    if not dest_dir: return
    archive = dest_dir/f'{cname(cid)}-{profile.name}.tar.zst'
    if archive.exists():
        if not confirm(f'Overwrite existing archive?\n\n  {archive.name}'): return
    os.system('clear')
    print(f'\n  {BLD}── Exporting profile ──{NC}\n  {DIM}{profile.name} → {archive}{NC}\n')
    # Try tar --zstd first; fall back to tar | zstd pipe if not supported
    r = _run(['tar','--zstd','-cf',str(archive),'-C',str(profile.parent),profile.name])
    if r.returncode != 0:
        archive.unlink(missing_ok=True)
        if shutil.which('zstd'):
                tar_proc = subprocess.Popen(
                    ['tar','-cf','-','-C',str(profile.parent),profile.name],
                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
                zst_proc = subprocess.Popen(
                    ['zstd','-q','-o',str(archive)],
                    stdin=tar_proc.stdout, stderr=subprocess.DEVNULL)
                tar_proc.stdout.close()
                zst_proc.communicate()
                r_ok = (tar_proc.wait() == 0 and zst_proc.returncode == 0)
        else:
            r_ok = False
    else:
        r_ok = True
    if r_ok:
        pause(f'✓ Exported to:\n  {archive}')
    else:
        archive.unlink(missing_ok=True)
        pause('✗ Export failed. (tar --zstd and zstd pipe both unavailable)')

def _stor_import(cid: str):
    """Import a .tar.zst storage profile archive — matches shell _stor_import_menu."""
    f = pick_file()
    if not f: return
    if f.suffix not in ('.zst','.gz','.bz2','.xz') and '.tar' not in f.name:
        pause('Select a .tar.zst (or other tar archive) file.'); return
    # Extract profile name from archive name: strip container prefix and extension
    name = re.sub(r'^.*?-','',f.stem).split('.')[0]
    v = finput(f'Profile name (blank = {name}):')
    if v is None: return
    pname = re.sub(r'[^a-zA-Z0-9_\-]','',v or name)
    if not pname: return
    dest = G.storage_dir/cid/pname
    if dest.exists():
        if not confirm(f"Profile '{pname}' already exists. Overwrite?"): return
        btrfs_delete(dest) if dest.is_dir() else shutil.rmtree(str(dest),True)
    dest.mkdir(parents=True, exist_ok=True)
    _run(['btrfs','subvolume','create',str(dest)], capture=True)
    os.system('clear')
    print(f'\n  {BLD}── Importing profile ──{NC}\n  {DIM}{f.name} → {pname}{NC}\n')
    r = _run(['tar','--zstd' if f.name.endswith('.zst') else '-a',
              '-xf',str(f),'--strip-components=1','-C',str(dest)])
    if r.returncode == 0:
        pause(f"✓ Profile '{pname}' imported.")
    else:
        shutil.rmtree(str(dest), True)
        pause('✗ Import failed.')

def _profile_submenu(cid: str, profile: Path):
    while True:
        sel = menu(f'{profile.name}',
                   L['stor_rename'], '⊕  Export', L['stor_delete'])
        if not sel:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if sel == L['stor_rename']:
            while True:
                v = finput(f"New name for '{profile.name}':")
                if not v: break
                nn = re.sub(r'[^a-zA-Z0-9_\- ]','',v)
                if not nn: pause('Name cannot be empty.'); continue
                # TODO-018: reject if same name + same storage_type already exists (matches shell)
                stype = _stor_read_field(profile.name, 'storage_type') if G.storage_dir else ''
                dup = G.storage_dir and any(
                    _stor_read_field(sd.name,'name') == nn and
                    _stor_read_field(sd.name,'storage_type') == stype and
                    sd.name != profile.name
                    for sd in G.storage_dir.iterdir() if sd.is_dir()
                )
                if dup: pause(f"A profile named '{nn}' already exists for this type."); continue
                nd = profile.parent/nn
                if nd.exists(): pause(f"Path '{nn}' already exists."); continue
                profile.rename(nd)
                pause(f"Profile renamed to '{nn}'."); return
        elif '⊕  Export' in sel:
            _stor_export(cid, profile)
        elif sel == L['stor_delete']:
            if confirm(f"Delete profile '{profile.name}'?"):
                btrfs_delete(profile) if profile.is_dir() else shutil.rmtree(str(profile),True)
                pause(f"Profile '{profile.name}' deleted."); return

# ══════════════════════════════════════════════════════════════════════════════
# menus/logs.py — logs browser
# ══════════════════════════════════════════════════════════════════════════════

def logs_browser():
    while True:
        if not G.logs_dir or not G.logs_dir.is_dir(): pause('No Logs folder found.'); return
        files=sorted(G.logs_dir.rglob('*.log'), key=lambda f: str(f), reverse=True)
        if not files: pause('No log files yet.'); return
        items=[f'{DIM}{f.relative_to(G.logs_dir)}{NC}' for f in files]+[_back_item()]
        sel=fzf_run(items,header=f'{BLD}── Logs ──{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        match=[f for f in files if str(f.relative_to(G.logs_dir))==sc]
        if not match: continue
        content=match[0].read_text(errors='replace')
        fzf_run(content.splitlines(),
                header=f'{BLD}── {sc}  {DIM}(read only){NC} ──{NC}',
                extra=['--no-multi','--disabled'])

# ══════════════════════════════════════════════════════════════════════════════
# menus/container.py — single container submenu
# ══════════════════════════════════════════════════════════════════════════════

def _guard_space() -> bool:
    if not G.mnt_dir: return True
    if _run(['mountpoint','-q',str(G.mnt_dir)]).returncode != 0: return True
    r=_run(['df','-k',str(G.mnt_dir)],capture=True)
    avail=int(r.stdout.splitlines()[-1].split()[3]) if r.returncode==0 else 9999999
    if avail < 2097152:
        pause('⚠  Less than 2 GiB free in the image.\nUse Other → Resize image to increase the size first.'); return False
    return True

def _guard_install() -> bool:
    if not _guard_space(): return False
    if not G.containers_dir or not G.containers_dir.is_dir(): return True
    running = []
    for d in G.containers_dir.iterdir():
        if not (d/'state.json').exists(): continue
        cid = d.name
        if is_installing(cid): running.append(cname(cid))
    if not running: return True
    return confirm(f'⚠  Installation already running: {" ".join(running)}\n\n'
                   f'  Running another simultaneously may slow both down.\n  Continue anyway?')

def _open_url(url: str):
    """Open URL in existing browser tab — matches shell _sd_open_url exactly."""
    import subprocess as sp
    # Detect default browser via xdg-settings
    try:
        r = sp.run(['xdg-settings','get','default-web-browser'], capture_output=True, text=True)
        browser = r.stdout.strip().removesuffix('.desktop').lower() if r.returncode == 0 else ''
    except: browser = ''
    def _try(*cmds):
        for c in cmds:
            if shutil.which(c):
                sp.Popen([c,'--new-tab',url], stderr=sp.DEVNULL, start_new_session=True); return True
        return False
    if 'firefox' in browser or 'librewolf' in browser or 'waterfox' in browser or 'floorp' in browser:
        if _try('firefox','librewolf','waterfox','floorp'): return
    elif 'vivaldi' in browser:
        if _try('vivaldi-stable','vivaldi'): return
    elif 'google-chrome' in browser or 'chrome' in browser:
        if _try('google-chrome-stable','google-chrome'): return
    elif 'chromium' in browser:
        if _try('chromium','chromium-browser'): return
    elif 'brave' in browser:
        if _try('brave-browser','brave'): return
    elif 'microsoft-edge' in browser or 'msedge' in browser:
        if _try('microsoft-edge'): return
    # Fallback: gtk-launch with detected browser, then xdg-open
    if browser:
        try: sp.Popen(['gtk-launch', browser+'.desktop', url], stderr=sp.DEVNULL, start_new_session=True); return
        except: pass
    for cmd in ['xdg-open','firefox','firefox-esr','chromium','chromium-browser','google-chrome']:
        if shutil.which(cmd):
            sp.Popen([cmd, url], stderr=sp.DEVNULL, start_new_session=True); return

def _open_in_best_url(cid: str, port: str) -> str:
    """Check proxy config for registered route; fallback to localhost — matches shell."""
    try:
        cfg = _proxy_cfg_path()
        if cfg.exists():
            data = json.loads(cfg.read_text())
            for route in data.get('routes', []):
                if route.get('cid') == cid:
                    url = route.get('url', '')
                    proto = 'https' if route.get('https') else 'http'
                    return f'{proto}://{url}'
    except: pass
    return f'http://localhost:{port}'

def _open_in_submenu(cid: str):
    n = cname(cid); d = sj(cid)
    port = str(d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT',''))
    if port == 'None': port = ''
    is_running = tmux_up(tsess(cid))
    ct_path = cpath(cid)
    install_path = ct_path or G.installations_dir
    # QR code available?
    qr_ok = (G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists() and
             _run(['sudo','-n','chroot',str(G.ubuntu_dir),'sh','-c','command -v qrencode'],
                  capture=True).returncode == 0)
    while True:
        items = []
        if port and port != '0':
            items.append('⊕  Browser')
        if qr_ok and port and port != '0':
            items.append('⊞  Show QR code')
        items += ['◧  File manager', '◉  Terminal']
        sel = menu(f'Open in — {n}', *items)
        if not sel:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if 'Browser' in sc:
            if not is_running: pause('Please start the container first.'); continue
            _open_url(_open_in_best_url(cid, port))
            return
        elif 'QR code' in sc:
            if not is_running: pause('Please start the container first.'); continue
            exp = exposure_get(cid)
            if exp != 'public':
                pause(f'Exposure is {exposure_label(exp)} — QR code requires public.\n\n  Set this container to public in Reverse Proxy → Port exposure.')
                continue
            qr_url = f'http://{cid}.local'
            r = _run(['sudo','-n','chroot',str(G.ubuntu_dir),
                      'sh','-c',f"qrencode -t UTF8 -o - '{qr_url}'"], capture=True)
            qr_render = r.stdout if r.returncode == 0 else ''
            fzf_run((qr_render + f'\n\n  {qr_url}\n').splitlines(),
                    header=f'{BLD}── QR Code ──{NC}\n{DIM}  Scan to open on any LAN device (mDNS){NC}',
                    extra=['--no-multi','--disabled'])
        elif 'File manager' in sc:
            open_path = str(install_path) if install_path else ''
            if not open_path: pause('No install path found.'); continue
            subprocess.Popen(['xdg-open', open_path],
                             stderr=subprocess.DEVNULL, start_new_session=True)
        elif 'Terminal' in sc:
            sess = f'sdTerm_{cid}'
            tip = str(ct_path) if ct_path else str(Path.home())
            if not tmux_up(sess):
                tmux_launch(sess, f'cd {tip!r} && exec bash')
            pause(f"Opening terminal for '{n}'\n\n  {tip}\n  Press {KB['tmux_detach']} to detach.")
            _tmux('switch-client','-t',sess)


def _exposure_toggle_menu(cid: str):
    """Cycle port exposure: isolated → localhost → public, then apply."""
    while True:
        current = exposure_get(cid)
        nxt = exposure_next(cid)
        port = sj_get(cid,'meta','port',default='') or sj_get(cid,'environment','PORT',default='')
        ip   = netns_ct_ip(cid)
        items = [
            _sep('Current exposure'),
            f'  {exposure_label(current)}  {DIM}— port {port}  {ip}{NC}',
            _sep('Set to'),
            f' {GRN}→{NC}  {exposure_label("isolated")}  {DIM}blocked{NC}',
            f' {GRN}→{NC}  {exposure_label("localhost")}  {DIM}this machine{NC}',
            f' {GRN}→{NC}  {exposure_label("public")}  {DIM}local network{NC}',
            _nav_sep(), _back_item(),
        ]
        sel = fzf_run(items, header=f'{BLD}── Port exposure — {cname(cid)} ──{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        new_mode = None
        if 'isolated' in sc:  new_mode = 'isolated'
        elif 'localhost' in sc: new_mode = 'localhost'
        elif 'public' in sc:   new_mode = 'public'
        if new_mode and new_mode != current:
            exposure_set(cid, new_mode)
            if tmux_up(tsess(cid)): exposure_apply(cid)
            pause(f'Port exposure set to: {exposure_label(new_mode)}\n\n'
                  f'  isolated  — blocked\n  localhost — this machine\n  public    — local network')
        return

def container_submenu(cid: str):
    while True:
        os.system('clear')
        _cleanup_stale_installing()
        n=cname(cid)
        installed=st(cid,'installed',False)
        running=tmux_up(tsess(cid))
        installing=is_installing(cid)
        ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
        install_done=ok_f.exists() or fail_f.exists()
        d=sj(cid)
        port=d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT','')
        # dot
        if installing or install_done: dot=f'{YLW}◈{NC}'
        elif running: dot=f'{GRN}◈{NC}' if health_check(cid) else f'{YLW}◈{NC}'
        elif installed: dot=f'{RED}◈{NC}'
        else: dot=f'{DIM}◈{NC}'
        dlg=d.get('meta',{}).get('dialogue','')
        hdr=f'{dot}  {n}  {DIM}— {dlg}{NC}' if dlg else f'{dot}  {n}'
        if port and str(port)!='0' and installed:
            hdr+=f'  {DIM}{netns_ct_ip(cid)}:{port}{NC}'
        items=[_sep('General')]
        action_labels=[]; action_dsls=[]
        cron_entries=[]
        if installed and not installing:
            for a in d.get('actions',[]):
                lbl=a['label']
                if re.match(r'^[a-zA-Z0-9]',lbl): lbl=f'{DIM}⊙  {lbl}{NC}'
                else: lbl=f'{DIM}{lbl}{NC}'
                action_labels.append(lbl); action_dsls.append(a['dsl'])
            cron_entries=d.get('crons',[])
        _UPD_ITEMS=[]; _UPD_IDX=[]
        if not installing and not running:
            _build_update_items_for(cid,_UPD_ITEMS,_UPD_IDX)
            if installed:
                _build_ubuntu_update_item_for(cid, _UPD_ITEMS, _UPD_IDX)
                _build_pkg_manifest_item_for(cid, _UPD_ITEMS, _UPD_IDX)
        if installing or install_done:
            if install_done:
                fin_lbl=L['ct_finish_inst'] if not installed else '✓  Finish update'
                items.append(fin_lbl)
            else: items.append(L['ct_attach_inst'])
        elif running:
            items+=[f'{RED}{L["ct_stop"]}{NC}',f'{DIM}{L["ct_restart"]}{NC}',f'{DIM}{L["ct_attach"]}{NC}',f'{DIM}{L["ct_open_in"]}{NC}',f'{DIM}{L["ct_log"]}{NC}']
            if action_labels:
                items.append(_sep('Actions'))
                items.extend(action_labels)
            if cron_entries:
                items.append(_sep('Cron'))
                for i,cr in enumerate(cron_entries):
                    sess=cron_sess(cid,i)
                    auto='--autostart' in cr.get('flags','')
                    if tmux_up(sess):
                        items.append(f'{DIM}⏱  {cr["name"]}  [{cr["interval"]}]{NC}')
                    else:
                        items.append(f'{DIM}⏱  {cr["name"]}  [stopped]{NC}')
        elif installed:
            local_SEP_STO = _sep('Storage')
            local_SEP_DNG = _sep('Caution')
            items+=[f'{GRN}{L["ct_start"]}{NC}', f'{DIM}{L["ct_open_in"]}{NC}']
            items+=[local_SEP_STO, f'{DIM}{L["ct_backups"]}{NC}', f'{DIM}{L["ct_profiles"]}{NC}']
            items+=[f'{DIM}{L["ct_edit"]}{NC}']
            if _UPD_ITEMS:
                pending=any('→' in strip_ansi(x) or 'Changes detected' in strip_ansi(x) for x in _UPD_ITEMS)
                lbl=f' {YLW}⬆  Updates{NC}' if pending else f'{DIM}⬆  Updates{NC}'
                items.append(lbl)
            items+=[local_SEP_DNG, f'{RED}{L["ct_uninstall"]}{NC}']
        else:
            items+=[f'{GRN}{L["ct_install"]}{NC}',
                    f'{DIM}{L["ct_edit"]}{NC}',f'{DIM}{L["ct_rename"]}{NC}',
                    _sep('Caution'),f'{RED}{L["ct_remove"]}{NC}']
        items+=[_nav_sep(),_back_item()]
        if installing or install_done:
            sel,auto=_fzf_with_watcher(items,hdr,ok_f,fail_f)
            if auto: process_install_finish(cid); continue
        else:
            sel=fzf_run(items,header=f'{BLD}── {hdr} ──{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        # dispatch
        if sc==L['ct_attach_inst']:
            sess_inst = inst_sess(cid)
            if tmux_up(sess_inst):
                                    _tmux('switch-client','-t',sess_inst)
        elif sc in (L['ct_finish_inst'],'✓  Finish update'): process_install_finish(cid)
        elif sc==L['ct_install']:
            if not _guard_install(): continue
            if is_installing(cid):
                if confirm(f'⚠  {n} is already installing.\n\n  Running it again will restart from scratch.\n  Continue?'):
                    run_job(cid,'install',force=True)
            else: run_job(cid,'install')
        elif sc==L['ct_start']:
            profile=''
            if _stor_count(cid)>0:
                profile=_pick_storage_profile(cid) or ''
                if profile is None: continue
            sel2=fzf_run([f'{GRN}▶  Start and show live output{NC}',f'{DIM}   Start in the background{NC}'],
                         header=f'{BLD}── Start ──{NC}')
            if not sel2: continue
            mode='attach' if 'show live output' in strip_ansi(sel2) else 'background'
            start_ct(cid,mode,profile)
        elif sc==L['ct_stop']:
            if confirm(f"Stop '{n}'?"): stop_ct(cid)
        elif sc==L['ct_restart']: stop_ct(cid); time.sleep(0.3); start_ct(cid,'background')
        elif sc==L['ct_attach']:
            sess_ct = tsess(cid)
            if tmux_up(sess_ct):
                if confirm(f"Attach to '{n}'\n\n  Press {KB['tmux_detach']} to detach without stopping."):
                                            _tmux('switch-client','-t',sess_ct)
        elif sc==L['ct_open_in']: _open_in_submenu(cid)
        elif sc==L['ct_log']:
            meta_log=d.get('meta',{}).get('log','')
            lf=cpath(cid)/meta_log if meta_log and cpath(cid) else log_path(cid,'start')
            if lf and lf.exists():
                r_tail=_run(['tail','-100',str(lf)], capture=True)
                pause(r_tail.stdout if r_tail.returncode==0 else '')
            else: pause(f"No log yet for '{n}'.")
        elif sc==L['ct_exposure'] or '⬤  Exposure' in sc:
            new_mode=exposure_next(cid)
            exposure_set(cid,new_mode)
            if tmux_up(tsess(cid)): exposure_apply(cid)
            pause(f'Port exposure set to: {exposure_label(new_mode)}\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network')
        elif sc==L['ct_edit']:
            _edit_container_bp(cid)
        elif sc==L['ct_rename']:
            v=finput(f"New name for '{n}':"); _rename_container(cid,v) if v else None
        elif sc==L['ct_backups']: container_backups_menu(cid)
        elif sc==L['ct_profiles']: G.stor_ctx_cid=cid; persistent_storage_menu(cid); G.stor_ctx_cid=''
        elif sc==L['ct_uninstall']:
            ip=cpath(cid)
            if confirm(f"Uninstall '{n}'?\n\n  ✕  Installation: {ip}\n  ✕  Snapshots\n\n  Persistent storage is kept.\n  Container entry stays — select Install to reinstall."):
                if ip and ip.is_dir(): btrfs_delete(ip)
                sdir2=snap_dir(cid)
                if sdir2.is_dir():
                    for sf in sdir2.iterdir():
                        if sf.is_dir(): btrfs_delete(sf)
                    shutil.rmtree(str(sdir2),True)
                set_st(cid,'installed',False)
                pause(f"'{n}' uninstalled. Persistent storage kept.")
        elif sc==L['ct_remove']:
            if confirm(f"Remove container entry '{n}'?\n\n  No installation or storage files deleted."):
                for f in ['sd_size','gh_tag']:
                    (G.cache_dir/f/cid).unlink(missing_ok=True)
                    (G.cache_dir/f/f'{cid}.inst').unlink(missing_ok=True)
                shutil.rmtree(str(G.containers_dir/cid),True)
                pause(f"'{n}' removed."); return
        elif '⬆  Updates' in sc:
            if not _UPD_ITEMS: continue
            sel3=fzf_run([f'{BLD}  ── Updates ──────────────────────────{NC}']+_UPD_ITEMS+[_nav_sep(),_back_item()],
                         header=f'{BLD}── Update — {n} ──{NC}')
            if not sel3 or clean(sel3)==L['back']: continue
            sc3=clean(sel3)
            for ui,item in enumerate(_UPD_ITEMS):
                if sc3==clean(item):
                    idx=_UPD_IDX[ui]
                    if idx=='__ubuntu__': _do_ubuntu_update(cid)
                    elif idx=='__pkgs__': _do_pkg_update(cid)
                    else: _do_blueprint_update(cid,int(idx))
                    break
        elif '⏱' in sc:
            cron_clicked=re.sub(r'.*⏱\s+','',strip_ansi(sc)).split('[')[0].strip()
            for i,cr in enumerate(cron_entries):
                if cr.get('name','')==cron_clicked:
                    cs=cron_sess(cid,i)
                    while True:
                        if tmux_up(cs):
                            sub=fzf_run([f'{YLW}⏎  Attach{NC}',f'{RED}■  Stop{NC}',_back_item()],
                                        header=f'{BLD}── Cron: {cr["name"]} ──{NC}')
                            if not sub or clean(sub)==L['back']: break
                            if 'Stop' in strip_ansi(sub):
                                _tmux('kill-session','-t',cs)
                                (G.containers_dir/cid/f'cron_{i}_next').unlink(missing_ok=True)
                                # loop continues -> now stopped -> shows Start
                            elif 'Attach' in strip_ansi(sub):
                                _tmux('switch-client','-t',cs); break
                        else:
                            sub=fzf_run([f'{GRN}▶  Start{NC}',_back_item()],
                                        header=f'{BLD}── Cron: {cr["name"]} ──{NC}')
                            if not sub or clean(sub)==L['back']: break
                            if 'Start' in strip_ansi(sub):
                                _cron_start_one(cid,i,cr)
                                # loop continues -> now running -> shows Stop/Attach
                    break
        else:
            # action labels
            for ai,lbl in enumerate(action_labels):
                if sc==clean(lbl): _run_action(cid,ai,lbl,action_dsls[ai]); break

def _fzf_with_watcher(items, header, ok_f, fail_f):
    """Like fzf_run but kills fzf when ok_f or fail_f appear. Returns (sel, auto_triggered)."""
    done_evt=threading.Event()
    def _watch():
        while not ok_f.exists() and not fail_f.exists(): time.sleep(0.3)
        done_evt.set()
    wt=threading.Thread(target=_watch); wt.start()
    dimmed=[x if '\033[' in x else f'{DIM} {x}{NC}' for x in items]
    proc=subprocess.Popen(['fzf']+FZF_BASE+[f'--header={BLD}── {header} ──{NC}'],
                          stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    G.active_fzf_pid=proc.pid
    proc.stdin.write(('\n'.join(dimmed)+'\n').encode()); proc.stdin.close()
    def _kw(): done_evt.wait(); proc.kill()
    threading.Thread(target=_kw).start()
    out,_=proc.communicate(); G.active_fzf_pid=None
    if done_evt.is_set(): os.system('clear'); return None,True
    return (out.decode().strip() or None), False

def _edit_container_bp(cid: str):
    if tmux_up(tsess(cid)) or is_installing(cid):
        pause('⚠  Stop the container before editing.'); return
    if not _guard_space(): return
    src=G.containers_dir/cid/'service.src'
    if not src.exists():
        _ensure_src(cid)
    if not src.exists():
        src.write_text(bp_template())
    editor=os.environ.get('EDITOR','vi')
    subprocess.run([editor,str(src)])
    parsed=bp_parse(src.read_text()); errs=bp_validate(parsed)
    if errs: pause(f'⚠  Blueprint has errors (not saved):\n\n'+'\n'.join(errs)+'\n\n  Re-open editor to fix.'); return
    bp_compile(src,cid)
    if st(cid,'installed'): build_start_script(cid)

def _rename_container(cid: str, new_name: str) -> bool:
    if st(cid,'installed',False):
        pause('Rename is only available for uninstalled containers.'); return False
    new_name = re.sub(r'[^a-zA-Z0-9_\-]','',new_name).strip()
    if not new_name: pause('Name cannot be empty.'); return False
    load_containers()
    for c in G.CT_IDS:
        if c != cid and cname(c) == new_name:
            pause(f"Container '{new_name}' already exists."); return False
    set_st(cid,'name',new_name)
    pause(f"Container renamed to '{new_name}'."); return True

def _run_action(cid: str, ai: int, label: str, dsl: str):
    ip=cpath(cid); sess=f'sdAction_{cid}_{ai}'
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_action_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(_env_exports(cid,ip))
        f.write(f'cd {str(ip)!r}\n')
        if '|' in dsl:
            segs=[s.strip() for s in dsl.split('|') if s.strip()]
            for seg in segs:
                if seg.startswith('prompt:'):
                    txt=seg[7:].strip().strip('"\'')
                    f.write(f'printf "{txt}\\n> "; read -r _sd_input\n')
                    f.write('[[ -z "$_sd_input" ]] && exit 0\n')
                elif seg.startswith('select:'):
                    scmd=seg[7:].strip()
                    skip=1 if '--skip-header' in scmd else 0
                    col_m=re.search(r'--col\s+(\d+)',scmd); col=col_m.group(1) if col_m else '1'
                    scmd=re.sub(r'--skip-header','',scmd); scmd=re.sub(r'--col\s+\d+','',scmd).strip()
                    scmd_parts=scmd.split(None,1)
                    scmd_bin=_cr_prefix(scmd_parts[0]) if scmd_parts else scmd
                    scmd_rest=scmd_parts[1] if len(scmd_parts)>1 else ''
                    full_scmd=f'{scmd_bin} {scmd_rest}'.strip()
                    f.write(f'_sd_list=$({full_scmd} 2>/dev/null)\n')
                    f.write('[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n')
                    if skip: f.write('_sd_list=$(printf "%s" "$_sd_list" | tail -n +2)\n')
                    f.write(f'_sd_selection=$(printf "%s\\n" "$_sd_list"'
                            f'|awk \'{{print ${col}}}\'|fzf --ansi --no-sort --prompt="  ❯ "'
                            f' --pointer="▶" --height=40% --reverse --border=rounded'
                            f' --margin=1,2 --no-info 2>/dev/null)||exit 0\n')
                else:
                    parts=seg.split(None,1)
                    cmd_bin=_cr_prefix(parts[0]) if parts else seg
                    cmd_rest=parts[1] if len(parts)>1 else ''
                    cmd_out=f'{cmd_bin} {cmd_rest}'.strip()
                    cmd_out=cmd_out.replace('{input}','$_sd_input').replace('{selection}','$_sd_selection')
                    f.write(cmd_out+'\n')
        else:
            f.write(dsl+'\n')
    os.chmod(runner.name,0o755)
    if tmux_up(sess):
        pause(f"Action '{label}' is still running.\n\n  Press {KB['tmux_detach']} to detach.")
        _tmux('switch-client','-t',sess)
    else:
        inner = (f'bash {runner.name!r}; rm -f {runner.name!r}; '
                 f'printf "\\n\\033[0;32m══ Done ══\\033[0m\\n"; '
                 f'printf "Press Enter to return...\\n"; read -rs _; '
                 f'tmux switch-client -t simpleDocker 2>/dev/null||true; '
                 f'tmux kill-session -t {sess!r} 2>/dev/null||true')
        tmux_launch(sess, inner)
        _tmux('switch-client','-t',sess)

# ══════════════════════════════════════════════════════════════════════════════
# menus/container.py — update item builders
# ══════════════════════════════════════════════════════════════════════════════

def _build_update_items_for(cid: str, items: list, idx: list):
    """Append update menu items for blueprint, ubuntu, and package updates."""
    d=sj(cid); cur_ver=d.get('meta',{}).get('version','')
    stype=d.get('meta',{}).get('storage_type','')
    if not stype: return
    # Blueprint updates: scan BLUEPRINTS_DIR for matching storage_type
    if G.blueprints_dir and G.blueprints_dir.is_dir():
        seen_stems = set()
        for ext in ('*'+SD_BP_EXT,):
            for bf in G.blueprints_dir.glob(ext):
                if bf.stem in seen_stems: continue
                seen_stems.add(bf.stem)
                try:
                    bp=bp_parse(bf.read_text())
                    if bp.get('meta',{}).get('storage_type')!=stype: continue
                    new_ver=str(bp.get('meta',{}).get('version',''))
                    bname=bf.stem
                    src=G.containers_dir/cid/'service.src'
                    if cur_ver==new_ver:
                        same=(src.exists() and src.read_text()==bf.read_text())
                        if same: entry=f'{DIM}[B] {bname} Blueprints — ✓ {cur_ver}{NC}'
                        else: entry=f'{DIM}[B]{NC} {bname} {DIM}Blueprints{NC} — {YLW}Changes detected{NC}{DIM}  v{cur_ver}{NC}'
                    else:
                        entry=f'{DIM}[B]{NC} {bname} {DIM}Blueprints{NC} — {YLW}{cur_ver or "?"}{NC} → {GRN}{new_ver or "?"}{NC}'
                    items.append(entry); idx.append(str(len(idx)))
                except: pass
    # Persistent blueprint scan with [P] tag
    presets_dir = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
    if presets_dir and presets_dir.is_dir():
        seen_p = set()
        for ext in ('*'+SD_BP_EXT,):
            for pf in presets_dir.glob(ext):
                if pf.stem in seen_p: continue
                seen_p.add(pf.stem)
                try:
                    bp=bp_parse(pf.read_text())
                    if bp.get('meta',{}).get('storage_type')!=stype: continue
                    new_ver=str(bp.get('meta',{}).get('version',''))
                    bname=pf.stem
                    src=G.containers_dir/cid/'service.src'
                    if cur_ver==new_ver:
                        same=(src.exists() and src.read_text()==pf.read_text())
                        if same: entry=f'{BLU}[P]{NC}{DIM} {bname} Persistent — ✓ {cur_ver}{NC}'
                        else: entry=f'{BLU}[P]{NC} {bname} {DIM}Persistent{NC} — {YLW}Changes detected{NC}{DIM}  v{cur_ver}{NC}'
                    else:
                        entry=f'{BLU}[P]{NC} {bname} {DIM}Persistent{NC} — {YLW}{cur_ver or "?"}{NC} → {GRN}{new_ver or "?"}{NC}'
                    items.append(entry); idx.append(str(len(idx)))
                except: pass

def _build_ubuntu_update_item_for(cid: str, items: list, idx: list):
    install_path = cpath(cid)
    if not install_path or not Path(install_path).is_dir(): return
    ubuntu_dir = G.ubuntu_dir
    if not ubuntu_dir or not (ubuntu_dir/'.ubuntu_ready').exists():
        items.append(f'{DIM}[U]{NC} Ubuntu base {DIM}—{NC} {YLW}Not installed{NC}')
    else:
        def _ct_ubuntu_stamp(p): 
            try: return (Path(p)/'.sd_ubuntu_stamp').read_text().strip()
            except: return ''
        def _ct_ubuntu_ver(p):
            try:
                for line in (Path(p)/'etc/os-release').read_text().splitlines():
                    if line.startswith('VERSION_ID='): return line.split('=',1)[1].strip('"')
            except: pass
            return 'unknown'
        ct_stamp   = _ct_ubuntu_stamp(install_path)
        base_stamp = _ct_ubuntu_stamp(ubuntu_dir)
        ct_ver     = _ct_ubuntu_ver(ubuntu_dir) or 'unknown'
        if not base_stamp or (ct_stamp and ct_stamp == base_stamp):
            items.append(f'{DIM}[U] Ubuntu base — ✓ {ct_ver}{NC}')
        else:
            items.append(f'{DIM}[U]{NC} Ubuntu base — {YLW}{ct_ver} — Update available{NC}')
    idx.append('__ubuntu__')

def _build_pkg_manifest_item_for(cid: str, items: list, idx: list):
    mf=G.containers_dir/cid/'pkg_manifest.json'
    if not mf.exists(): return
    try: m=json.loads(mf.read_text())
    except: return
    n=sum(len(m.get(k,[])) for k in ('deps','pip','npm','git'))
    if n==0: return
    ts=m.get('updated','never')
    # Check GitHub repos for updates (matches shell _build_pkg_update_item)
    git_repos = m.get('git',[])
    has_update = False
    if git_repos and G.cache_dir:
        tag_dir = G.cache_dir/'gh_tag'
        tag_dir.mkdir(parents=True, exist_ok=True)
        cache_f = tag_dir/cid
        inst_f  = tag_dir/f'{cid}.inst'
        # Refresh combined cache if >1 hour old
        try:
            age = time.time() - cache_f.stat().st_mtime if cache_f.exists() else 9999
        except: age = 9999
        if age > 3600:
            tags = []
            for repo in git_repos:
                if not repo: continue
                try:
                    r = _run(['curl','-fsSL',
                              f'https://api.github.com/repos/{repo}/releases/latest'],
                             capture=True)
                    tag_m = re.search(r'"tag_name"\s*:\s*"([^"]+)"', r.stdout)
                    if tag_m: tags.append(tag_m.group(1))
                except: pass
            if tags: cache_f.write_text('\n'.join(tags))
        latest = cache_f.read_text().strip() if cache_f.exists() else ''
        installed = inst_f.read_text().strip() if inst_f.exists() else ''
        if latest and installed and latest != installed:
            has_update = True
        elif latest and not installed:
            has_update = True
    if has_update:
        items.append(f'{DIM}[P]{NC} Packages {DIM}\u2014 {ts}{NC} \u2014 {YLW}Update available{NC}')
    else:
        items.append(f'{DIM}[P] Packages \u2014 \u2713 {ts}{NC}')
    idx.append('__pkgs__')

def _do_ubuntu_update(cid: str):
    if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists():
        pause('Ubuntu base not installed.'); return
    if not _guard_ubuntu_pkg(): return
    n = cname(cid)
    base_ver = (G.ubuntu_dir/'.sd_ubuntu_stamp').read_text().strip() if (G.ubuntu_dir/'.sd_ubuntu_stamp').exists() else '(unknown)'
    if not confirm(f"Update Ubuntu base for '{n}'?\n\n  Base : {base_ver}"): return
    snap_label = f"Update-{base_ver.replace(' ','-').replace('.','-')}"
    if confirm(f"Create a backup first?\n\n  Will appear in Backups as '{snap_label}'."):
        sdir = snap_dir(cid); ip = cpath(cid)
        sdir.mkdir(parents=True, exist_ok=True)
        snap_id = snap_label; nn = 1
        while (sdir/snap_id).exists(): snap_id = f'{snap_label}-{nn}'; nn += 1
        if ip and (btrfs_snap(ip, sdir/snap_id) or
                   (_run(['cp','-a',str(ip),str(sdir/snap_id)]).returncode == 0)):
            snap_meta_set(sdir, snap_id, type='manual', ts=time.strftime('%Y-%m-%d %H:%M'))
            pause(f"✓ Backup '{snap_id}' created.")
        else:
            if not confirm('⚠  Backup failed. Continue anyway?'): return
    cmd = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1'
    _ubuntu_pkg_op(f'sdUbuntuCtUpd_{cid}', f'Ubuntu update — {n}', cmd)
    stamp = time.strftime('%Y-%m-%d')
    try: (G.ubuntu_dir/'.sd_ubuntu_stamp').write_text(stamp)
    except: pass
    ip2 = cpath(cid)
    if ip2:
        try: import shutil as _sh; _sh.copy(str(G.ubuntu_dir/'.sd_ubuntu_stamp'), str(ip2/'.sd_ubuntu_stamp'))
        except: pass
    G.ub_cache_loaded = False

def _do_pkg_update(cid: str):
    mf = G.containers_dir/cid/'pkg_manifest.json'
    ip = cpath(cid)
    if not mf.exists(): pause('No manifest. Reinstall first.'); return
    try: m = json.loads(mf.read_text())
    except: pause('Corrupt manifest.'); return
    dep_pkgs = ' '.join(m.get('deps', []))
    pip_pkgs = ' '.join(m.get('pip', []))
    npm_pkgs = ' '.join(m.get('npm', []))
    gh_repos = m.get('git', [])
    if not any([dep_pkgs, pip_pkgs, npm_pkgs, gh_repos]):
        pause('Nothing to update.'); return
    um = ''
    if dep_pkgs: um += f'  apt: {dep_pkgs}\n'
    if pip_pkgs: um += f'  pip: {pip_pkgs}\n'
    if npm_pkgs: um += f'  npm: {npm_pkgs}\n'
    if gh_repos: um += f'  git: {" ".join(gh_repos)}'
    if not confirm(f"Update packages for '{cname(cid)}'?\n\n{um}"): return
    ok_f  = G.containers_dir/cid/'.install_ok'
    fail_f = G.containers_dir/cid/'.install_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    import shlex as _sx3
    scr = tempfile.NamedTemporaryFile(mode='w', dir=str(G.tmp_dir),
                                      suffix='.sh', delete=False, prefix='.sd_pkgupd_')
    ub = str(G.ubuntu_dir) if G.ubuntu_dir else ''
    import platform; arch = 'arm64' if platform.machine() == 'aarch64' else 'amd64'
    ok_q = _sx3.quote(str(ok_f)); fail_q = _sx3.quote(str(fail_f))
    mf_q = _sx3.quote(str(mf))
    lines = ['#!/usr/bin/env bash',
             '_chroot_bash() { local r=$1; shift; local b=/bin/bash; [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash; [[ ! -e "$r$b" ]] && b=/bin/sh; sudo -n chroot "$r" "$b" "$@"; }',
             f'_finish() {{ local c=$?; [[ $c -eq 0 ]] && touch {ok_q} || touch {fail_q}; }}',
             'trap _finish EXIT',
             f'trap \'touch {fail_q}; exit 130\' INT TERM',
             f'_mnt_ubuntu() {{ sudo -n mount --bind /proc {_sx3.quote(ub+"/proc")}; sudo -n mount --bind /sys {_sx3.quote(ub+"/sys")}; sudo -n mount --bind /dev {_sx3.quote(ub+"/dev")}; }}',
             f'_umnt_ubuntu() {{ sudo -n umount -lf {_sx3.quote(ub+"/dev")} {_sx3.quote(ub+"/sys")} {_sx3.quote(ub+"/proc")} 2>/dev/null||true; }}',
             '']
    if dep_pkgs and ub and (Path(ub)/'.ubuntu_ready').exists():
        ub_q = _sx3.quote(ub)
        lines += [f'printf "\\033[1m[apt] Upgrading: {dep_pkgs}\\033[0m\\n"',
                  '_mnt_ubuntu',
                  f'_sd_apt_upd=$(mktemp {_sx3.quote(ub+"/../.sd_aptupd_XXXXXX.sh")} 2>/dev/null || echo /tmp/.sd_aptupd_$$.sh)',
                  f'printf \'#!/bin/sh\\nset -e\\napt-get update -qq\\nDEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade {dep_pkgs} 2>&1\\n\' > "$_sd_apt_upd"',
                  'chmod +x "$_sd_apt_upd"',
                  f'sudo -n mount --bind "$_sd_apt_upd" {ub_q}/tmp/.sd_aptupd_run.sh 2>/dev/null || cp "$_sd_apt_upd" {ub_q}/tmp/.sd_aptupd_run.sh 2>/dev/null || true',
                  f'_chroot_bash {ub_q} /tmp/.sd_aptupd_run.sh',
                  f'sudo -n umount -lf {ub_q}/tmp/.sd_aptupd_run.sh 2>/dev/null || true',
                  f'rm -f "$_sd_apt_upd" {ub_q}/tmp/.sd_aptupd_run.sh 2>/dev/null || true',
                  '_umnt_ubuntu', '']
    ip_q = _sx3.quote(str(ip)) if ip else "''"
    if pip_pkgs and ip and (ip/'venv'/'bin'/'pip').exists():
        ub_q = _sx3.quote(ub)
        lines += [f'printf "\\033[1m[pip] Upgrading: {pip_pkgs}\\033[0m\\n"',
                  '_mnt_ubuntu',
                  f'sudo -n mount --bind {ip_q} {ub_q}/mnt',
                  f'_sd_pip_upd=$(mktemp {_sx3.quote(ub+"/../.sd_pipupd_XXXXXX.sh")} 2>/dev/null || echo /tmp/.sd_pipupd_$$.sh)',
                  f'printf \'#!/bin/sh\\nset -e\\n/mnt/venv/bin/pip install --upgrade {pip_pkgs} 2>&1\\n\' > "$_sd_pip_upd"',
                  'chmod +x "$_sd_pip_upd"',
                  f'sudo -n mount --bind "$_sd_pip_upd" {ub_q}/tmp/.sd_pipupd_run.sh 2>/dev/null || cp "$_sd_pip_upd" {ub_q}/tmp/.sd_pipupd_run.sh 2>/dev/null || true',
                  f'_chroot_bash {ub_q} /tmp/.sd_pipupd_run.sh',
                  f'sudo -n umount -lf {ub_q}/tmp/.sd_pipupd_run.sh 2>/dev/null || true',
                  f'sudo -n umount -lf {ub_q}/mnt 2>/dev/null||true',
                  f'rm -f "$_sd_pip_upd" {ub_q}/tmp/.sd_pipupd_run.sh 2>/dev/null || true',
                  '_umnt_ubuntu', '']
    if npm_pkgs and ip and (ip/'node_modules').is_dir():
        ub_q = _sx3.quote(ub)
        lines += [f'printf "\\033[1m[npm] Upgrading: {npm_pkgs}\\033[0m\\n"',
                  '_mnt_ubuntu',
                  f'sudo -n mount --bind {ip_q} {ub_q}/mnt',
                  f'_sd_npm_upd=$(mktemp {_sx3.quote(ub+"/../.sd_npmupd_XXXXXX.sh")} 2>/dev/null || echo /tmp/.sd_npmupd_$$.sh)',
                  f'printf \'#!/bin/sh\\nset -e\\ncd /mnt && npm update {npm_pkgs} 2>&1\\n\' > "$_sd_npm_upd"',
                  'chmod +x "$_sd_npm_upd"',
                  f'sudo -n mount --bind "$_sd_npm_upd" {ub_q}/tmp/.sd_npmupd_run.sh 2>/dev/null || cp "$_sd_npm_upd" {ub_q}/tmp/.sd_npmupd_run.sh 2>/dev/null || true',
                  f'_chroot_bash {ub_q} /tmp/.sd_npmupd_run.sh',
                  f'sudo -n umount -lf {ub_q}/tmp/.sd_npmupd_run.sh 2>/dev/null || true',
                  f'sudo -n umount -lf {ub_q}/mnt 2>/dev/null||true',
                  f'rm -f "$_sd_npm_upd" {ub_q}/tmp/.sd_npmupd_run.sh 2>/dev/null || true',
                  '_umnt_ubuntu', '']
    if gh_repos:
        inst_f = _sx3.quote(str(G.cache_dir/f'gh_tag/{cid}.inst')) if G.cache_dir else "'/dev/null'"
        lines += [f'printf "\\033[1m[git] Checking releases\\xe2\\x80\\xa6\\033[0m\\n"',
                  f'_SD_ARCH={_sx3.quote(arch)}',
                  f'_SD_INSTALL={ip_q}',
                  '_new_tags=""',
                  '_sd_ltag(){ curl -fsSL "https://api.github.com/repos/$1/releases/latest" 2>/dev/null | grep -o \'"tag_name":"[^"]*"\' | cut -d\'"\' -f4; }',
                  '_sd_burl(){ local r=$1 a=$2 rel urls u; rel=$(curl -fsSL "https://api.github.com/repos/$r/releases/latest" 2>/dev/null); urls=$(printf \'%s\' "$rel" | grep -o \'"browser_download_url":"[^"]*"\' | grep -ivE \'sha256|\\.sig|\\.txt|\\.json|rocm\' | grep -o \'https://[^"]*\'); u=$(printf \'%s\\n\' "$urls" | grep -iE \'\\.(tar\\.(gz|zst|xz|bz2)|tgz|zip)$\' | grep -iE "linux.*$a|$a.*linux" | head -1); [[ -z "$u" ]] && u=$(printf \'%s\\n\' "$urls" | grep -iE "$a" | head -1); printf \'%s\' "$u"; }',
                  '_sd_xauto(){ local u=$1 d=$2; mkdir -p "$d"; local t; t=$(mktemp "$d/.dl_X"); curl -fL --progress-bar --retry 3 -C - "$u" -o "$t" || { rm -f "$t"; return 1; }; if [[ "$u" =~ \\.(tar\\.(gz|bz2|xz|zst)|tgz)$ ]]; then tar -xa -C "$d" --strip-components=1 -f "$t" 2>/dev/null || tar -xa -C "$d" -f "$t" 2>/dev/null; elif [[ "$u" =~ \\.zip$ ]]; then unzip -o -d "$d" "$t" 2>/dev/null; else mkdir -p "$d/bin"; mv "$t" "$d/bin/$(basename "$u" | sed \'s/[?#].*//)"; chmod +x "$d/bin/"*; return; fi; rm -f "$t"; }',
                  '']
        for repo in gh_repos:
            rq = _sx3.quote(repo)
            lines += [f'printf "  checking {repo}\\n"',
                      f'_latest=$(_sd_ltag {rq})',
                      f'_inst=$(grep -x {rq} {inst_f} 2>/dev/null | head -1 || true)',
                      f'if [[ -z "$_latest" ]]; then printf "  [!] could not fetch tag for {repo}, skipping\\n"',
                      'elif [[ "$_latest" == "$_inst" ]]; then',
                      f'    printf "  \\033[2m✓ {repo} already at %s\\033[0m\\n" "$_latest"',
                      'else',
                      f'    printf "  \\033[1m{repo}: %s → %s\\033[0m\\n" "${{_inst:-(unknown)}}" "$_latest"',
                      f'    _url=$(_sd_burl {rq} "$_SD_ARCH")',
                      '    if [[ -n "$_url" ]]; then',
                      f'        _sd_xauto "$_url" "$_SD_INSTALL" && printf "  \\033[0;32m✓ updated %s\\033[0m\\n" "$_latest"',
                      f'    else printf "  [!] no release asset found for {repo}\\n"; fi',
                      'fi',
                      f'_new_tags="${{_new_tags}}${{_latest}}\\n"']
        lines += [f'printf "%s" "$_new_tags" > {inst_f}', '']
    lines += [f'jq --arg t "$(date \'+%Y-%m-%d %H:%M\')" \'.updated=$t\' {mf_q} > {mf_q}.tmp && mv {mf_q}.tmp {mf_q}',
              'printf "\\n\\033[0;32m══ Package update complete ══\\033[0m\\n"']
    with open(scr.name, 'w') as f:
        f.write('\n'.join(lines) + '\n')
    os.chmod(scr.name, 0o755)
    tmux_set('SD_INSTALLING', cid)
    pu_sess = inst_sess(cid)
    tmux_launch(pu_sess, f'bash {scr.name}; rm -f {scr.name}')
    if G.cache_dir: (G.cache_dir/'gh_tag'/cid).unlink(missing_ok=True)

def _do_blueprint_update(cid: str, idx: int):
    d=sj(cid); stype=d.get('meta',{}).get('storage_type','')
    bps=[]; presets_dir = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
    if G.blueprints_dir:
        seen=set()
        for ext in ('*'+SD_BP_EXT,):
            for f in G.blueprints_dir.glob(ext):
                if f.stem not in seen: bps.append(f); seen.add(f.stem)
    # Also include persistent blueprints (DIV-055)
    if presets_dir and presets_dir.is_dir():
        seen_p=set(f.stem for f in bps)
        for ext in ('*'+SD_BP_EXT,):
            for pf in presets_dir.glob(ext):
                if pf.stem not in seen_p: bps.append(pf); seen_p.add(pf.stem)
    try: bf=bps[int(idx)] if int(idx)<len(bps) else None
    except: bf=None
    if not bf: pause('Blueprint not found.'); return
    cur_ver=d.get('meta',{}).get('version','')
    bp=bp_parse(bf.read_text()); new_ver=str(bp.get('meta',{}).get('version',''))
    src=G.containers_dir/cid/'service.src'
    if cur_ver == new_ver:
        same = src.exists() and bf.exists() and src.read_text() == bf.read_text()
        if same:
            pause(f"Nothing to do — '{cname(cid)}' is already up to date\n  (version {cur_ver or '?'}, configuration unchanged.)")
            return
        if not confirm(f"Changes detected in '{cname(cid)}' (version {cur_ver or '?'} unchanged).\n\n  Blueprint: {bf.stem}\n  Apply configuration changes?"): return
        shutil.copy(str(bf), str(src))
        if bp_compile(src, cid):
            if st(cid,'installed'): build_start_script(cid)
            pause(f"Configuration updated for '{cname(cid)}' (version {cur_ver or '?'}).")
        else: pause('⚠  Update applied but compile had errors. Check Edit configuration.')
        return
    if not confirm(f"Update '{cname(cid)}' from blueprint '{bf.stem}'?\n  Version: {cur_ver} → {new_ver}"): return
    shutil.copy(str(bf),str(src))
    if bp_compile(src,cid):
        if st(cid,'installed'): build_start_script(cid)
        pause(f"'{cname(cid)}' updated to {new_ver}.")
    else: pause('⚠  Update applied but compile had errors. Check Edit configuration.')

# ══════════════════════════════════════════════════════════════════════════════
# menus/container.py — backups submenu
# ══════════════════════════════════════════════════════════════════════════════

def container_backups_menu(cid: str):
    # TODO-010: auto/manual section split + Remove all submenu + confirm before create
    # Matches shell _container_backups_menu exactly.
    SEP_AUTO = f'{BLD}  ── Automatic backups ────────────────{NC}'
    SEP_MAN  = f'{BLD}  ── Manual backups ───────────────────{NC}'
    while True:
        sdir = snap_dir(cid)
        sdir.mkdir(parents=True, exist_ok=True)
        auto_ids=[]; auto_ts=[]; man_ids=[]; man_ts=[]
        if sdir.is_dir():
            for f in sdir.glob('*.meta'):
                sid = f.stem
                if not (sdir/sid).is_dir(): continue
                tp  = snap_meta_get(sdir, sid, 'type')
                ts  = snap_meta_get(sdir, sid, 'ts')
                if tp == 'auto':
                    auto_ids.append(sid); auto_ts.append(ts)
                else:
                    man_ids.append(sid); man_ts.append(ts)

        # Build display lines + parallel id list for selection matching
        items=[]; line_ids=[]
        items.append(SEP_AUTO); line_ids.append('')
        if auto_ids:
            for sid,ts in zip(auto_ids, auto_ts):
                disp = f' {DIM}◈  {sid}{NC}'
                if ts: disp += f'  {DIM}({ts}){NC}'
                items.append(disp); line_ids.append(sid)
        else:
            items.append(f'{DIM}  (none yet){NC}'); line_ids.append('')

        items.append(SEP_MAN); line_ids.append('')
        if man_ids:
            for sid,ts in zip(man_ids, man_ts):
                disp = f' {DIM}◈  {sid}{NC}'
                if ts: disp += f'  {DIM}({ts}){NC}'
                items.append(disp); line_ids.append(sid)
        else:
            items.append(f'{DIM}  (none yet){NC}'); line_ids.append('')

        items.append(f'{BLD}  ── Actions ──────────────────────────{NC}'); line_ids.append('')
        items.append(f' {GRN}+{NC}{DIM}  Create manual backup{NC}');        line_ids.append('__create__')
        items.append(f' {RED}×{NC}{DIM}  Remove all backups{NC}');           line_ids.append('__remove_all__')
        items.append(_nav_sep()); line_ids.append('')
        items.append(_back_item()); line_ids.append('__back__')

        sel = fzf_run(items, header=f'{BLD}── Backups: {cname(cid)} ──{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return

        # Match selection to id
        sel_clean = clean(sel)
        sel_id = ''
        for i, line in enumerate(items):
            if clean(line) == sel_clean:
                sel_id = line_ids[i]; break

        if sel_id == '__back__' or not sel_id:
            return

        if sel_id == '__create__':
            if tmux_up(tsess(cid)):
                pause('Stop the container before creating a backup.'); continue
            if confirm(f"Create manual backup of '{cname(cid)}'?"):
                create_backup_manual(cid)
            continue

        if sel_id == '__remove_all__':
            if tmux_up(tsess(cid)):
                pause('Stop the container before removing backups.'); continue
            choice = menu('Remove backups', 'All automatic', 'All manual', 'All (automatic + manual)')
            if not choice: continue
            rm_auto = 'automatic' in choice.lower() or 'all (' in choice.lower()
            rm_man  = 'manual'    in choice.lower() or 'all (' in choice.lower()
            rm_count = 0
            if rm_auto:
                for sid in auto_ids: btrfs_delete(sdir/sid); (sdir/f'{sid}.meta').unlink(missing_ok=True); rm_count+=1
            if rm_man:
                for sid in man_ids:  btrfs_delete(sdir/sid); (sdir/f'{sid}.meta').unlink(missing_ok=True); rm_count+=1
            pause(f'{rm_count} backup(s) removed.')
            continue

        # Backup entry selected — open submenu
        if not (sdir/sel_id).is_dir():
            pause('Backup not found.'); continue
        _snap_submenu(cid, sdir/sel_id, sel_id)

def _snap_submenu(cid: str, snap_path: Path, label: str):
    sdir = snap_dir(cid)
    ts = snap_meta_get(sdir, label, 'ts') or '?'
    sel=menu(f'Backup: {label}  ({ts})','Restore this snapshot','Clone as new container',L['stor_delete'])
    if not sel: return
    if 'Restore' in sel:
        if tmux_up(tsess(cid)): pause('Stop the container before restoring.'); return
        restore_snap(cid,snap_path,label)
    elif 'Clone' in sel:
        if tmux_up(tsess(cid)): pause('Stop the container before cloning.'); return
        v=finput('Name for the clone:')
        if v: clone_from_snap(cid,snap_path,label,v)
    elif sel==L['stor_delete']:
        if confirm(f"Delete backup '{label}'?"):
            btrfs_delete(snap_path)
            (sdir/f'{label}.meta').unlink(missing_ok=True)
            pause(f"Backup '{label}' deleted.")

# ══════════════════════════════════════════════════════════════════════════════
# menus/containers.py — containers list + new container
# ══════════════════════════════════════════════════════════════════════════════

def containers_submenu():
    while True:
        os.system('clear')
        _cleanup_stale_installing()    # NF8: clear stale SD_INSTALLING on each render
        load_containers()
        n_running=sum(1 for c in G.CT_IDS if tmux_up(tsess(c)))
        items=[f'{BLD}  ── Containers ──────────────────────{NC}']
        for cid in G.CT_IDS:
            try: _sj = json.loads((G.containers_dir/cid/'service.json').read_text())
            except: _sj = {}
            try: _st = json.loads((G.containers_dir/cid/'state.json').read_text())
            except: _st = {}
            n        = _st.get('name') or f'(unnamed-{cid})'
            installed= _st.get('installed', False)
            port     = str(_sj.get('meta',{}).get('port') or _sj.get('environment',{}).get('PORT',''))
            sj_health= _sj.get('meta',{}).get('health', False)
            ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
            if is_installing(cid) or ok_f.exists() or fail_f.exists(): dot=f'{YLW}◈{NC}'
            elif tmux_up(tsess(cid)):
                n_running  # already counted above
                # health check skipped in list view for speed; shown in container_submenu
                dot=f'{GRN}◈{NC}'
            elif installed: dot=f'{RED}◈{NC}'
            else: dot=f'{DIM}◈{NC}' 
            dlg=_sj.get('meta',{}).get('dialogue','')
            disp=f'{n}  {DIM}— {dlg}{NC}' if dlg else n
            sz_lbl=''; sc_path=G.cache_dir/'sd_size'/cid
            if sc_path.exists(): sz_lbl=f'{DIM}[{sc_path.read_text().strip()}gb]{NC} '
            # NF4: background size cache refresh if >60s stale
            ipath = cpath(cid)
            if ipath and ipath.is_dir():
                try:
                    sz_age = (time.time() - sc_path.stat().st_mtime) if sc_path.exists() else 999
                except: sz_age = 999
                if sz_age > 60:
                    pass  # size cache skipped
            ip_lbl=''
            if port and port!='0' and installed:
                ip_lbl=f'{DIM}[{netns_ct_ip(cid)}:{port}]{NC} '
            name_col = f'{DIM}{disp}{NC}' if not (tmux_up(tsess(cid)) or is_installing(cid) or ok_f.exists() or fail_f.exists()) else disp
            items.append(f' {dot}  {name_col}  {DIM}{sz_lbl}{ip_lbl}[{cid}]{NC}')
        if not G.CT_IDS: items.append(f'{DIM}  (no containers yet){NC}')
        items+=[f'{GRN} +  {L["new_container"]}{NC}',
                _nav_sep(),_back_item()]
        hdr_extra=f'  {DIM}[{len(G.CT_IDS)} · {GRN}{n_running} ▶{NC}{DIM}]{NC}'
        sel=fzf_run(items,header=f'{BLD}── Containers ──{NC}{hdr_extra}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if L['new_container'] in sc: install_method_menu(); continue
        m=re.search(r'\[([a-z0-9]{8})\]$',strip_ansi(sel).strip())
        if m: container_submenu(m.group(1))

def install_method_menu():
    """New container — matches .sh _install_method_menu exactly."""
    bps  = _list_blueprint_names()
    ibps = _list_imported_names()
    load_containers()

    items = [f'{BLD}  ── Install from blueprint ───────────{NC}\t__sep__']
    if bps or ibps:
        for n in bps:  items.append(f'   {DIM}◈{NC}  {n}\tbp:{n}')
        for n in ibps: items.append(f'   {CYN}◈{NC}  {n}  {DIM}[Imported]{NC}\tibp:{n}')
    else:
        items.append(f'{DIM}  No blueprints found{NC}\t__sep__')

    items.append(f'{BLD}  ── Clone existing container ─────────{NC}\t__sep__')
    has_inst = False
    for cid in G.CT_IDS:
        if not st(cid,'installed'): continue
        has_inst = True
        items.append(f'   {DIM}◈{NC}  {cname(cid)}\tclone:{cid}')
    if not has_inst:
        items.append(f'{DIM}  No installed containers found{NC}\t__sep__')

    items += [f'{BLD}  ── Navigation ───────────────────────{NC}\t__sep__',
              f'{DIM} {L["back"]}{NC}\t__back__']

    sel = fzf_run(items, header=f'{BLD}── Select installation method ──{NC}',
                  with_nth='1', delimiter='\t')
    if not sel: return
    tag = sel.split('\t')[-1].strip() if '\t' in sel else ''
    if not tag or tag in ('__back__','__sep__'): return

    if tag.startswith('bp:'):
        bname = tag[3:]
        bf = _bp_find_file(bname)
        if not bf: pause(f"Blueprint '{bname}' not found."); return
        try:
            sug = bp_parse(bf.read_text()).get('meta',{}).get('name','') or bname
        except: sug = bname
        v = finput(f'Container name (default: {sug}):')
        if v is None: return
        ct_name = v.strip() or sug
        cid = rand_id(); cdir = G.containers_dir/cid; cdir.mkdir(parents=True, exist_ok=True)
        shutil.copy(str(bf), str(cdir/'service.src'))
        bp_compile(cdir/'service.src', cid)


    elif tag.startswith('ibp:'):
        bname = tag[4:]
        bf = _get_imported_bp_path(bname)
        if not bf: pause(f"Could not locate imported blueprint '{bname}'."); return
        try:
            sug = bp_parse(bf.read_text()).get('meta',{}).get('name','') or bname
        except: sug = bname
        v = finput(f'Container name (default: {sug}):')
        if v is None: return
        ct_name = v.strip() or sug
        cid = rand_id(); cdir = G.containers_dir/cid; cdir.mkdir(parents=True, exist_ok=True)
        shutil.copy(str(bf), str(cdir/'service.src'))
        bp_compile(cdir/'service.src', cid)

    elif tag.startswith('clone:'):
        src_cid = tag[6:]
        _clone_source_submenu(src_cid)
        return

    else:
        return

    ct_name = re.sub(r'[^a-zA-Z0-9_\-]','',ct_name) or cname(cid) or 'container'
    sf = cdir/'state.json'
    try: data = json.loads(sf.read_text()) if sf.exists() else {}
    except: data = {}
    data.update({'name': ct_name, 'install_path': cid, 'installed': False})
    sf.write_text(json.dumps(data, indent=2))
    set_st(cid, 'name', ct_name)
    pause(f"Container '{ct_name}' created. Select it to install.")

def _clone_source_submenu(src_cid: str):
    """Match .sh _clone_source_submenu — choose current state or a snapshot to clone from."""
    src_name = cname(src_cid); src_path = cpath(src_cid)
    sdir = snap_dir(src_cid)
    if tmux_up(tsess(src_cid)): pause(f"Stop '{src_name}' before cloning."); return
    if not src_path or not src_path.is_dir(): pause('Container not installed.'); return

    items = [f'{BLD}  ── Main ─────────────────────────────{NC}\t__sep__',
             f'   {DIM}◈{NC}  Current state\tcurrent']
    pi = sdir/'Post-Installation' if sdir.is_dir() else None
    if pi and pi.is_dir():
        ts = snap_meta_get(sdir,'Post-Installation','ts')
        items.append(f'   {DIM}◈{NC}  Post-Installation  {DIM}({ts}){NC}\tpost')

    other_ids = []
    if sdir.is_dir():
        for f in sdir.glob('*.meta'):
            sid = f.stem
            if sid == 'Post-Installation' or not (sdir/sid).is_dir(): continue
            other_ids.append(sid)

    items.append(f'{BLD}  ── Other ────────────────────────────{NC}\t__sep__')
    if other_ids:
        for sid in other_ids:
            ts = snap_meta_get(sdir, sid, 'ts')
            items.append(f'   {DIM}◈{NC}  {sid}  {DIM}({ts}){NC}\t{sid}')
    else:
        items.append(f'{DIM}  No other backups found{NC}\t__sep__')

    items += [f'{BLD}  ── Navigation ───────────────────────{NC}\t__sep__',
              f'{DIM} {L["back"]}{NC}\t__back__']

    sel = fzf_run(items, header=f'{BLD}── Clone \'{src_name}\' from ──{NC}',
                  with_nth='1', delimiter='\t')
    if not sel: return
    tag = sel.split('\t')[-1].strip() if '\t' in sel else ''
    if not tag or tag in ('__back__','__sep__'): return

    v = finput('Name for the clone:')
    if not v: return
    clone_name = re.sub(r'[^a-zA-Z0-9_\-]','',v)
    if not clone_name: return

    if tag == 'current':
        _clone_container(src_cid, clone_name)
    elif tag == 'post':
        clone_from_snap(src_cid, pi, 'Post-Installation', clone_name)
    else:
        clone_from_snap(src_cid, sdir/tag, tag, clone_name)

def _clone_container(src_cid: str, clone_name: str):
    """Clone an installed container's current state."""
    src_path = cpath(src_cid)
    if not src_path or not src_path.is_dir(): pause('Container not installed.'); return
    clone_cid = rand_id()
    clone_dir = G.containers_dir/clone_cid; clone_dir.mkdir(parents=True, exist_ok=True)
    clone_path = G.installations_dir/clone_cid
    for f in ('service.json','state.json','resources.json'):
        src = G.containers_dir/src_cid/f
        if src.exists(): shutil.copy(str(src), str(clone_dir/f))
    try:
        data = json.loads((clone_dir/'state.json').read_text())
        data['name'] = clone_name; data['install_path'] = clone_cid
        (clone_dir/'state.json').write_text(json.dumps(data, indent=2))
    except: pass
    if btrfs_snap(src_path, clone_path, readonly=False):
        pause(f"Cloned '{cname(src_cid)}' → '{clone_name}'")
    else:
        shutil.copytree(str(src_path), str(clone_path))
        pause(f"Cloned '{cname(src_cid)}' → '{clone_name}' (plain copy)")

# ══════════════════════════════════════════════════════════════════════════════
# menus/groups.py
# ══════════════════════════════════════════════════════════════════════════════

def _grp_path(gid: str) -> Path:
    return G.groups_dir/f'{gid}.toml'

def _list_groups() -> List[str]:
    if not G.groups_dir or not G.groups_dir.is_dir(): return []
    return [f.stem for f in G.groups_dir.glob('*.toml')]

def _grp_read_field(gid: str, field: str) -> str:
    try:
        for line in _grp_path(gid).read_text().splitlines():
            if re.match(rf'^{field}\s*=', line):
                return line.split('=',1)[1].strip()
    except: pass
    return ''

def _grp_containers(gid: str) -> List[str]:
    raw = _grp_read_field(gid, 'start').strip('{}')
    steps = [s.strip() for s in raw.split(',') if s.strip()]
    return sorted(set(s for s in steps if not s.lower().startswith('wait')))

def _grp_seq_steps(gid: str) -> List[str]:
    raw = _grp_read_field(gid, 'start').strip('{}')
    return [s.strip() for s in raw.split(',') if s.strip()]

def _grp_seq_save(gid: str, steps: List[str]):
    joined = ', '.join(steps)
    p = _grp_path(gid)
    try: text = p.read_text()
    except: text = f'name = {gid}\ndesc =\ncontainers =\nstart = {{  }}\n'
    if re.search(r'^start\s*=', text, re.M):
        text = re.sub(r'^start\s*=.*', f'start = {{ {joined} }}', text, flags=re.M)
    else:
        text += f'start = {{ {joined} }}\n'
    cts = ', '.join(sorted(set(s for s in steps if not s.lower().startswith('wait'))))
    if re.search(r'^containers\s*=', text, re.M):
        text = re.sub(r'^containers\s*=.*', f'containers = {cts}', text, flags=re.M)
    else:
        text += f'containers = {cts}\n'
    p.write_text(text)

def _ct_id_by_name(ct_name: str) -> Optional[str]:
    if not G.containers_dir: return None
    for d in G.containers_dir.iterdir():
        sf = d/'state.json'
        if not sf.exists(): continue
        try:
            if json.loads(sf.read_text()).get('name') == ct_name: return d.name
        except: pass
    return None

def _create_group(gname: str):
    gname = re.sub(r'[^a-zA-Z0-9_\- ]','',gname)
    if not gname: pause('Name cannot be empty.'); return
    import random as _r, string as _s
    while True:
        gid = ''.join(_r.choices(_s.ascii_lowercase+_s.digits, k=8))
        if not _grp_path(gid).exists(): break
    _grp_path(gid).write_text(f'name = {gname}\ndesc =\ncontainers =\nstart = {{  }}\n')
    pause(f"Group '{gname}' created.")

def _start_group(gid: str):
    steps = _grp_seq_steps(gid)
    batch: List[str] = []
    def _flush():
        for bname in batch:
            bcid = _ct_id_by_name(bname)
            if bcid:
                if not tmux_up(tsess(bcid)): start_ct(bcid, 'background')
        batch.clear()
    for step in steps:
        sl = step.lower().strip()
        m = re.match(r'^wait\s+(\d+)$', sl)
        mf = re.match(r'^wait\s+for\s+(.+)$', sl)
        if m:
            _flush(); time.sleep(int(m.group(1)))
        elif mf:
            _flush()
            wcid = _ct_id_by_name(mf.group(1))
            if wcid:
                waited = 0
                while not tmux_up(tsess(wcid)) and waited < 60:
                    time.sleep(1); waited += 1
                time.sleep(2)
        else:
            batch.append(step)
    _flush()

def _stop_group(gid: str):
    steps = _grp_seq_steps(gid)
    for step in reversed(steps):
        if step.lower().startswith('wait'): continue
        cid = _ct_id_by_name(step)
        if not cid or not tmux_up(tsess(cid)): continue
        # Check if this container is also in another running group
        in_other = False
        if G.groups_dir and G.groups_dir.is_dir():
            for gf in G.groups_dir.glob('*.toml'):
                ogid = gf.stem
                if ogid == gid: continue
                other_members = _grp_containers(ogid)
                if step not in other_members: continue
                # Another group contains this container — check if any other member of that group is running
                for oc in other_members:
                    if oc == step: continue
                    ocid = _ct_id_by_name(oc)
                    if ocid and tmux_up(tsess(ocid)):
                        in_other = True
                        break
                if in_other: break
        if not in_other:
            stop_ct(cid)

def _grp_pick_container() -> Optional[str]:
    if not G.containers_dir: return None
    names = [cname(d.name) for d in G.containers_dir.iterdir()
             if (d/'state.json').exists() and cname(d.name)]
    if not names: pause('No containers found.'); return None
    sel = fzf_run([f' {DIM}◈  {n}{NC}' for n in sorted(names)],
                  header=f'{BLD}── Select container ──{NC}')
    if not sel: return None
    return clean(sel).lstrip('◈').strip() or None

def _grp_pick_wait() -> Optional[str]:
    sel = fzf_run(['Wait seconds', 'Wait for container'],
                  header=f'{BLD}── Wait type ──{NC}')
    if not sel: return None
    sc = clean(sel)
    if 'seconds' in sc:
        v = finput('Seconds to wait:')
        if not v: return None
        n = re.sub(r'[^0-9]','',v)
        if not n: pause('Invalid number.'); return None
        return f'Wait {n}'
    else:
        ct = _grp_pick_container()
        if not ct: return None
        return f'Wait for {ct}'

def _grp_pick_step() -> Optional[str]:
    sel = fzf_run(['Container', 'Wait'],
                  header=f'{BLD}── Add step ──{NC}')
    if not sel: return None
    sc = clean(sel)
    if sc == 'Container': return _grp_pick_container()
    else: return _grp_pick_wait()

def groups_menu():
    while True:
        load_containers()
        gids = _list_groups()
        n_active = 0
        for gid in gids:
            for mn in _grp_containers(gid):
                cid = _ct_id_by_name(mn)
                if cid and tmux_up(tsess(cid)): n_active += 1; break
        items = [f'{BLD}  ── Groups ───────────────────────────{NC}']
        for gid in gids:
            gname = _grp_read_field(gid,'name') or gid
            containers = _grp_containers(gid)
            n_running = sum(1 for mn in containers
                            for c in [_ct_id_by_name(mn)] if c and tmux_up(tsess(c)))
            n_total = len(containers)
            dot = f'{GRN}▶{NC}' if n_running > 0 else f'{DIM}▶{NC}'
            items.append(f' {dot}  {gname:<24} {DIM}{n_running}/{n_total} running{NC}')
        if not gids: items.append(f'{DIM}  (no groups yet){NC}')
        items += [f'{GRN} +  {L["grp_new"]}{NC}', _nav_sep(), _back_item()]
        n_grp_active = sum(1 for gid in gids
                           for mn in _grp_containers(gid)
                           for cid in [_ct_id_by_name(mn)] if cid and tmux_up(tsess(cid)))
        sel = fzf_run(items,
            header=f'{BLD}── Groups ──{NC}  {DIM}[{len(gids)} · {GRN}{n_active} active{NC}{DIM}]{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if L['grp_new'] in sc:
            v = finput('Group name:')
            if not v: continue
            _create_group(v); continue
        for gid in gids:
            gname = _grp_read_field(gid,'name') or gid
            if gname in sc: _group_submenu(gid); break

def _group_submenu(gid: str):
    while True:
        clear = os.system('clear')
        gname = _grp_read_field(gid,'name') or gid
        gdesc = _grp_read_field(gid,'desc')
        steps = _grp_seq_steps(gid)
        n_running = sum(1 for s in steps if not s.lower().startswith('wait')
                        for cid in [_ct_id_by_name(s)] if cid and tmux_up(tsess(cid)))
        is_running = n_running > 0
        items = [f'{BLD}  ── General ──────────────────────────{NC}']
        if is_running:
            items.append(f' {RED}■  Stop group{NC}')
        else:
            items += [f' {GRN}▶  Start group{NC}',
                      f' {BLU}≡  Edit name/desc{NC}',
                      f' {RED}×  Delete group{NC}']
        items.append(f'{BLD}  ── Sequence ─────────────────────────{NC}')
        for s in steps:
            if s.lower().startswith('wait'):
                items.append(f' {YLW}⏱{NC}  {DIM}{s}{NC}')
            else:
                cid = _ct_id_by_name(s)
                if not cid:
                    dot = f'{RED}◈{NC}'; st_s = f'{DIM} — not found{NC}'
                elif tmux_up(tsess(cid)):
                    dot = f'{GRN}◈{NC}'; st_s = f'  {GRN}running{NC}'
                else:
                    dot = f'{RED}◈{NC}'; st_s = f'  {DIM}stopped{NC}'
                items.append(f' {dot}  {s}{st_s}')
        if not steps: items.append(f' {DIM}(empty — add a step below){NC}')
        items += [f' {GRN}+  Add step{NC}', _nav_sep(), _back_item()]
        hdr_dot = f'{GRN}▶{NC}' if is_running else f'{DIM}▶{NC}'
        hdr = f'{hdr_dot}  {BLD}{gname}{NC}'
        if gdesc: hdr += f'  {DIM}— {gdesc}{NC}'
        sel = fzf_run(items, header=f'{BLD}── {hdr} ──{NC}  {DIM}[{n_running} running]{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if 'Start group' in sc:
            _start_group(gid)
        elif 'Stop group' in sc:
            _stop_group(gid)
        elif 'Edit name/desc' in sc:
            v = finput(f'Group name ({gname}):')
            if v:
                nn = v.strip() or gname
                try:
                    text = _grp_path(gid).read_text()
                    text = re.sub(r'^name\s*=.*', f'name = {nn}', text, flags=re.M)
                    _grp_path(gid).write_text(text)
                except: pass
            v2 = finput(f'Description ({gdesc}):')
            if v2 is not None:
                try:
                    text = _grp_path(gid).read_text()
                    if re.search(r'^desc\s*=', text, re.M):
                        text = re.sub(r'^desc\s*=.*', f'desc = {v2}', text, flags=re.M)
                    else:
                        text += f'desc = {v2}\n'
                    _grp_path(gid).write_text(text)
                except: pass
        elif 'Delete group' in sc:
            if confirm(f"Delete group '{gname}'?"):
                _grp_path(gid).unlink(missing_ok=True)
                pause('Group deleted.'); return
        elif 'Add step' in sc or '(empty' in sc:
            step = _grp_pick_step()
            if step:
                steps.append(step)
                _grp_seq_save(gid, steps)
        else:
            # Step clicked — edit sub-menu
            matched = None
            for i, s in enumerate(steps):
                if s in sc: matched = i; break
            if matched is None: continue
            action = fzf_run(['Add before','Edit','Add after','Remove'],
                             header=f'{BLD}── Edit step ──{NC}')
            if not action: continue
            ac = clean(action)
            if 'Add before' in ac:
                step = _grp_pick_step()
                if step: steps.insert(matched, step); _grp_seq_save(gid, steps)
            elif 'Add after' in ac:
                step = _grp_pick_step()
                if step: steps.insert(matched+1, step); _grp_seq_save(gid, steps)
            elif 'Edit' in ac:
                old = steps[matched]
                if old.lower().startswith('wait'):
                    step = _grp_pick_wait()
                else:
                    step = _grp_pick_container()
                if step: steps[matched] = step; _grp_seq_save(gid, steps)
            elif 'Remove' in ac:
                steps.pop(matched); _grp_seq_save(gid, steps)

# ══════════════════════════════════════════════════════════════════════════════
# menus/blueprints.py
# ══════════════════════════════════════════════════════════════════════════════

def _list_blueprint_names() -> List[str]:
    if not G.blueprints_dir or not G.blueprints_dir.is_dir(): return []
    found = []
    seen = set()
    for ext in ('*'+SD_BP_EXT,):
        for f in G.blueprints_dir.glob(ext):
            if f.stem not in seen:
                found.append(f.stem); seen.add(f.stem)
    return sorted(found)

def _bp_settings_get(key: str, default: str='') -> str:
    f=G.mnt_dir/'.sd/bp_settings.json' if G.mnt_dir else None
    if not f or not f.exists(): return default
    try: return json.loads(f.read_text()).get(key,default)
    except: return default

# ══════════════════════════════════════════════════════════════════════════════
# menus/blueprints.py — continued
# ══════════════════════════════════════════════════════════════════════════════

def _bp_settings_set(key: str, val) -> None:
    f = G.mnt_dir/'.sd/bp_settings.json' if G.mnt_dir else None
    if not f: return
    f.parent.mkdir(parents=True, exist_ok=True)
    try: data = json.loads(f.read_text()) if f.exists() else {}
    except: data = {}
    data[key] = val
    f.write_text(json.dumps(data, indent=2))


def _bp_autodetect_mode() -> str:
    return _bp_settings_get('autodetect_blueprints','Home')

def _bp_custom_paths_get() -> List[str]:
    v = _bp_settings_get('custom_paths','')
    if not v: return []
    try: return json.loads(v)
    except: return [x for x in v.split('\n') if x.strip()]

def _bp_custom_paths_add(p: str):
    cur = _bp_custom_paths_get()
    if p not in cur: cur.append(p)
    _bp_settings_set('custom_paths', json.dumps(cur))

def _bp_custom_paths_remove(p: str):
    cur = [x for x in _bp_custom_paths_get() if x != p]
    _bp_settings_set('custom_paths', json.dumps(cur))


_imported_bp_cache: list = []
_imported_bp_cache_ts: float = 0.0

def _list_imported_names() -> List[str]:
    """Autodetect blueprint files per autodetect mode. Prunes hidden dirs and vendor."""
    global _imported_bp_cache, _imported_bp_cache_ts
    if time.time() - _imported_bp_cache_ts < 5.0:
        return _imported_bp_cache
    mode = _bp_autodetect_mode()
    if mode == 'Disabled': return []
    search_dirs: List[Path] = []
    if mode == 'Home': search_dirs = [Path.home()]
    elif mode == 'Root': search_dirs = [Path('/')]
    elif mode == 'Everywhere': search_dirs = [Path('/')]
    elif mode == 'Custom': search_dirs = [Path(p) for p in _bp_custom_paths_get() if Path(p).is_dir()]
    _PRUNE = {'node_modules','__pycache__','.git','vendor'}
    found = []
    for sd in search_dirs:
        depth = 5 if mode in ('Home','Custom') else 8
        base_depth = str(sd).count('/')
        for root, dirs, files in os.walk(str(sd)):
            cur_depth = root.count('/') - base_depth
            if cur_depth > depth:
                dirs.clear(); continue
            if cur_depth == depth:
                dirs.clear()  # don't recurse deeper, but still process files here
            # prune hidden and vendor dirs in-place
            dirs[:] = [d for d in dirs if not d.startswith('.') and d not in _PRUNE]
            for fname in files:
                if not fname.endswith(SD_BP_EXT): continue
                p = Path(root)/fname
                if G.blueprints_dir and p.parent == G.blueprints_dir: continue
                found.append(p.stem)
    _imported_bp_cache = list(dict.fromkeys(found))
    _imported_bp_cache_ts = time.time()
    return _imported_bp_cache

def _get_imported_bp_path(name: str) -> Optional[Path]:
    mode = _bp_autodetect_mode()
    search_dirs: List[Path] = []
    if mode == 'Home': search_dirs = [Path.home()]
    elif mode in ('Root','Everywhere'): search_dirs = [Path('/')]
    elif mode == 'Custom': search_dirs = [Path(p) for p in _bp_custom_paths_get() if Path(p).is_dir()]
    _PRUNE = {'node_modules','__pycache__','.git','vendor'}
    for sd in search_dirs:
        for p in sd.rglob('*'+SD_BP_EXT):
            parts = p.relative_to(sd).parts
            if any(part.startswith('.') for part in parts[:-1]): continue
            if any(part in _PRUNE for part in parts): continue
            if p.stem == name and (not G.blueprints_dir or p.parent != G.blueprints_dir):
                return p
    return None


def _bp_find_file(name: str) -> Optional[Path]:
    """Locate a blueprint file by stem."""
    if not G.blueprints_dir: return None
    for ext in (SD_BP_EXT,):
        f = G.blueprints_dir/f'{name}{ext}'
        if f.exists(): return f
    return None

def _blueprint_submenu(name: str):
    bp_file = _bp_find_file(name)
    if not bp_file:
        pause(f"Blueprint file for '{name}' not found."); return
    while True:
        sel = menu(f'Blueprint: {name}', L['bp_edit'], L['bp_rename'], L['bp_delete'])
        if not sel:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if sel == L['bp_edit']:
            if not _guard_space(): continue
            editor = os.environ.get('EDITOR','vi')
            subprocess.run([editor, str(bp_file)])
        elif sel == L['bp_rename']:
            while True:
                v = finput(f"New name for blueprint '{name}':")
                if not v: break
                nn = re.sub(r'[^a-zA-Z0-9_\- ]','',v)
                if not nn: pause('Name cannot be empty.'); continue
                new_f = G.blueprints_dir/f'{nn}{bp_file.suffix}'
                if new_f.exists(): pause(f"Blueprint '{nn}' already exists."); continue
                try:
                    bp_file.rename(new_f)
                    pause(f"Blueprint renamed to '{nn}'."); return
                except Exception as e:
                    pause(f'Could not rename: {e}'); break
        elif sel == L['bp_delete']:
            if confirm(f"Delete blueprint '{name}'?\nThis cannot be undone."):
                try: bp_file.unlink()
                except: pause('Could not delete.'); continue
                pause(f"Blueprint '{name}' deleted."); return
def blueprints_submenu():
    """menus/blueprints.py"""
    while True:
        os.system('clear')
        bps = _list_blueprint_names()
        ibps = _list_imported_names()
        items = [f'{BLD}  ── Blueprints ───────────────────────{NC}']
        for n in bps:  items.append(f' {DIM}◈{NC}  {n}')
        for n in ibps: items.append(f' {CYN}◈{NC}  {n}  {DIM}[Imported]{NC}')
        if not bps and not ibps:
            items.append(f'{DIM}  (no blueprints yet){NC}')
        items += [f'{GRN} +  {L["bp_new"]}{NC}',
                  _nav_sep(), _back_item()]
        hdr = (f'{BLD}── Blueprints ──{NC}  '
               f'{DIM}[{len(bps)} file · {len(ibps)} imported]{NC}')
        sel = fzf_run(items, header=hdr)
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if L['bp_new'] in sc:
            if not G.blueprints_dir: pause('No image mounted.'); continue
            if not _guard_space(): continue
            v = finput('Blueprint name:')
            if v is None or not v.strip(): continue
            bname = re.sub(r'[^a-zA-Z0-9_\- ]','',v).strip()
            if not bname: continue
            bfile = G.blueprints_dir/f'{bname}{SD_BP_EXT}'
            if bfile.exists(): pause(f"Blueprint '{bname}' already exists."); continue
            bfile.write_text(bp_template())
            pause(f"Blueprint '{bname}' created. Select it to edit.")
            continue
        elif '[Imported]' in sc:
            iname = re.sub(r'^\s*◈\s*','',strip_ansi(sc)).split('[Imported]')[0].strip()
            ipath = _get_imported_bp_path(iname)
            if ipath and ipath.exists():
                fzf_run(ipath.read_text().splitlines(),
                        header=f'{BLD}── [Imported] {iname}  {DIM}({ipath}){NC} ──{NC}',
                        extra=['--no-multi','--disabled'])
            else:
                pause(f"Could not locate imported blueprint '{iname}'.")
        else:
            for n in bps:
                if n in sc: _blueprint_submenu(n); break

def blueprints_settings_menu():
    """menus/blueprints.py"""
    while True:
        ad_mode = _bp_autodetect_mode()
        ad_lbl = {
            'Home':      f'{GRN}[Home]{NC}',
            'Root':      f'{YLW}[Root]{NC}',
            'Everywhere':f'{CYN}[Everywhere]{NC}',
            'Custom':    f'{BLU}[Custom]{NC}',
            'Disabled':  f'{DIM}[Disabled]{NC}',
        }.get(ad_mode, f'{DIM}[{ad_mode}]{NC}')
        items = [
            _sep('General'),
            f' {DIM}◈{NC}  Autodetect blueprints  {ad_lbl}  {DIM}— scan for {SD_BP_EXT} files{NC}',
        ]
        items.append(_sep('Scanned paths'))
        cpaths = _bp_custom_paths_get()
        if not cpaths:
            items.append(f'{DIM}  (no paths configured){NC}')
        else:
            for cp in cpaths:
                if Path(cp).is_dir(): items.append(f' {DIM}◈{NC}  {DIM}{cp}{NC}')
                else:                 items.append(f' {DIM}◈{NC}  {DIM}{cp}{NC}  {RED}[missing]{NC}')
        items.append(f'{GRN} +  Add path{NC}')
        items += [_nav_sep(), _back_item()]
        sel = fzf_run(items, header=f'{BLD}── Blueprints — Settings ──{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if 'Autodetect blueprints' in sc:
            cycle = ['Home','Root','Everywhere','Custom','Disabled']
            next_m = cycle[(cycle.index(ad_mode)+1) % len(cycle)] if ad_mode in cycle else 'Home'
            _bp_settings_set('autodetect_blueprints', next_m)
        elif 'Add path' in sc:
            d = pick_dir()
            if d: _bp_custom_paths_add(str(d))
        else:
            for cp in _bp_custom_paths_get():
                if cp in sc:
                    if confirm(f'Remove path from scan list?\n\n  {cp}'):
                        _bp_custom_paths_remove(cp)
                    break

# ══════════════════════════════════════════════════════════════════════════════
# services/ubuntu.py — Ubuntu base management menu
# ══════════════════════════════════════════════════════════════════════════════

def ubuntu_menu():
    """Full Ubuntu base management — services/ubuntu.py"""
    ok_f  = G.ubuntu_dir/'.ubuntu_ok_flag'  if G.ubuntu_dir else Path('/tmp/.sd_ubuntu_ok_flag')
    fail_f= G.ubuntu_dir/'.ubuntu_fail_flag'if G.ubuntu_dir else Path('/tmp/.sd_ubuntu_fail_flag')
    upkg_ok   = G.ubuntu_dir/'.upkg_ok'   if G.ubuntu_dir else Path('/tmp/.sd_upkg_ok')
    upkg_fail = G.ubuntu_dir/'.upkg_fail' if G.ubuntu_dir else Path('/tmp/.sd_upkg_fail')
    while True:
        os.system('clear')
        # Check if Ubuntu op already running
        for sess,sfok,sffail,title in [
            ('sdUbuntuSetup', ok_f,   fail_f,   'Ubuntu setup'),
            ('sdUbuntuPkg',   upkg_ok, upkg_fail,'Ubuntu pkg op'),
        ]:
            if tmux_up(sess):
                _installing_wait_loop(sess, str(sfok), str(sffail), title)
                break
        if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists():
            if not confirm('Ubuntu base not installed. Download and install now?'): return
            _ensure_ubuntu(); continue

        ub_cache_read()
        ub_ver = ''
        ub_size = '?'
        try:
            osr = G.ubuntu_dir/'etc/os-release'
            for line in osr.read_text().splitlines():
                if line.startswith('PRETTY_NAME='): ub_ver = line.split('=',1)[1].strip('"'); break
        except: pass
        try: ub_size = _run(['du','-sh',str(G.ubuntu_dir)],capture=True).stdout.split()[0]
        except: pass

        pkgs = _ubuntu_pkg_list()
        default_set = set(DEFAULT_UBUNTU_PKGS.split())
        def_lines, sys_lines, pkg_lines = [], [], []
        for pkg,ver,is_sys in sorted(pkgs, key=lambda x: x[0]):
            line = f' {CYN}◈{NC}  {pkg:<28} {DIM}{ver}{NC}'
            if pkg in default_set:     def_lines.append((line, pkg, ver, 'default'))
            elif is_sys:               sys_lines.append((line, pkg, ver, 'system'))
            else:                      pkg_lines.append((line, pkg, ver, 'extra'))

        drift_tag = f'  {YLW}[changes detected]{NC}' if G.ub_pkg_drift else f'  {GRN}[up to date]{NC}'
        upd_tag   = f'  {YLW}[updates available]{NC}' if G.ub_has_updates else f'  {GRN}[up to date]{NC}'
        items = [
            f'{BLD} ── Actions ─────────────────────────────{NC}',
            f' {CYN}◈{NC}  Updates',
            f' {CYN}◈{NC}  Uninstall Ubuntu base',
            f'{BLD} ── Default packages ────────────────────{NC}',
        ]
        for l,*_ in def_lines: items.append(l)
        if not def_lines: items.append(f' {DIM} (none installed yet){NC}')
        items.append(f'{BLD} ── System packages ─────────────────────{NC}')
        for l,*_ in sys_lines: items.append(l)
        if not sys_lines: items.append(f' {DIM} (none){NC}')
        items.append(f'{BLD} ── Packages ────────────────────────────{NC}')
        for l,*_ in pkg_lines: items.append(l)
        if not pkg_lines: items.append(f' {DIM} (no extra packages){NC}')
        items += [f' {GRN}+{NC}  Add package',
                  f'{BLD} ── Navigation ──────────────────────────{NC}',
                  f'{DIM} {L["back"]}{NC}']
        hdr = (f'{BLD}── Ubuntu base ──{NC}  {DIM}{ub_ver or "Ubuntu 24.04"}{NC}'
               f'  {DIM}Size:{NC} {ub_size}  {CYN}[P]{NC}')
        sel = fzf_run(items, header=hdr)
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if sc.startswith('──'): continue
        if sc.startswith('─'): continue
        if 'Updates' in sc and 'Uninstall' not in sc:
            # Updates sub-menu
            upd_items = [
                f'{BLD} ── Updates ─────────────────────────────{NC}',
                f' {CYN}◈{NC}  Sync default pkgs{drift_tag}',
                f' {CYN}◈{NC}  Update all pkgs{upd_tag}',
                f'{BLD} ── Navigation ──────────────────────────{NC}',
                f'{DIM} {L["back"]}{NC}',
            ]
            sel2 = fzf_run(upd_items, header=f'{BLD}── Updates ──{NC}')
            if not sel2 or clean(sel2) == L['back']: continue
            sc2 = clean(sel2)
            if 'Sync default pkgs' in sc2:
                installed_names = {p for p,v,s in pkgs}
                missing = [p for p in DEFAULT_UBUNTU_PKGS.split() if p not in installed_names]
                if not missing and not G.ub_pkg_drift:
                    pause('Already up to date.'); continue
                sync_pkgs = ' '.join(missing) if missing else DEFAULT_UBUNTU_PKGS
                cmd = f'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {sync_pkgs} 2>&1'
                if not _guard_ubuntu_pkg(): continue
                _ubuntu_pkg_op('sdUbuntuPkg','Sync default pkgs',cmd)
                try:
                    (G.ubuntu_dir/'.ubuntu_default_pkgs').write_text('\n'.join(DEFAULT_UBUNTU_PKGS.split()))
                except: pass
                G.ub_pkg_drift = False; G.ub_cache_loaded = False
            elif 'Update all pkgs' in sc2:
                cmd = 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1'
                if not _guard_ubuntu_pkg(): continue
                _ubuntu_pkg_op('sdUbuntuPkg','Update all pkgs',cmd)
                G.ub_has_updates = False; G.ub_cache_loaded = False
        elif 'Uninstall Ubuntu base' in sc:
            if confirm(f'{YLW}⚠  Uninstall Ubuntu base?{NC}\n\nThis wipes the Ubuntu chroot.\nAll containers that depend on it will stop working.'):
                shutil.rmtree(str(G.ubuntu_dir), ignore_errors=True)
                G.ubuntu_dir.mkdir(parents=True, exist_ok=True)
                pause('✓ Ubuntu base removed.'); return
        elif 'Add package' in sc:
            v = finput('Package name (e.g. ffmpeg, nodejs):')
            if v is None or not v.strip(): continue
            pkg_name = v.strip().replace(' ','')
            if not pkg_name: continue
            v2 = finput('Version (leave blank for latest):')
            pkg_ver = (v2 or '').strip().replace(' ','') if v2 is not None else ''
            apt_target = f'{pkg_name}={pkg_ver}' if pkg_ver else pkg_name
            cmd = (f'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {apt_target} 2>&1'
                   f' || {{ apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {apt_target}; }}')
            if not _guard_ubuntu_pkg(): continue
            _ubuntu_pkg_op('sdUbuntuPkg', f'Installing {apt_target}', cmd)
        else:
            # Package click
            for l,pkg,ver,kind in def_lines:
                if clean(l) == sc:
                    pause(f'Protected package\n\n\'{pkg}\' is a default Ubuntu package.\nUnable to modify.'); break
            for l,pkg,ver,kind in sys_lines:
                if clean(l) == sc:
                    pause(f'System package\n\n\'{pkg}\' is an Ubuntu system package.\nRemoving it would break the system.'); break
            for l,pkg,ver,kind in pkg_lines:
                if clean(l) == sc:
                    if confirm(f"Remove '{BLD}{pkg}{NC}' from Ubuntu base?\n\n{DIM}{ver}{NC}"):
                        cmd = f'DEBIAN_FRONTEND=noninteractive apt-get remove -y {pkg} 2>&1'
                        if not _guard_ubuntu_pkg(): continue
                        _ubuntu_pkg_op('sdUbuntuPkg', f'Removing {pkg}', cmd)
                    break

def _ensure_ubuntu():
    """Install ubuntu base in a tmux session — services/ubuntu.py"""
    # DIV-015: sanity check — ready flag exists but apt-get missing → stale, remove flag
    ready_f = G.ubuntu_dir/'.ubuntu_ready'
    if ready_f.exists() and not (G.ubuntu_dir/'usr/bin/apt-get').exists():
        ready_f.unlink(missing_ok=True)
    if ready_f.exists(): return
    os.system('clear')
    ok_f  = G.ubuntu_dir/'.ubuntu_ok_flag'
    fail_f= G.ubuntu_dir/'.ubuntu_fail_flag'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    ub = str(G.ubuntu_dir)
    # Write runner to sd_mnt_base/.tmp (outside image — survives mount/unmount)
    _ub_tmp = G.sd_mnt_base/'.tmp'
    _ub_tmp.mkdir(parents=True, exist_ok=True)
    runner = tempfile.NamedTemporaryFile(mode='w', dir=str(_ub_tmp),
                                         suffix='.sh', delete=False, prefix='.sd_ubsetup_')
    with open(runner.name, 'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write('set -euo pipefail\n')
        f.write('trap \'sudo -n umount -lf ' + ub + '/dev ' + ub + '/sys ' + ub + '/proc 2>/dev/null||true\' EXIT\n')
        f.write('_sd_ub_arch=$(uname -m)\n')
        f.write('case "$_sd_ub_arch" in x86_64) _sd_ub_arch=amd64;; aarch64) _sd_ub_arch=arm64;; armv7l) _sd_ub_arch=armhf;; *) _sd_ub_arch=amd64;; esac\n')
        f.write('_base="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"\n')
        f.write('_ver=$(curl -fsSL "$_base" 2>/dev/null|grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${_sd_ub_arch}"|head -1)\n')
        f.write('[[ -z "$_ver" ]] && _ver="24.04.3-base-${_sd_ub_arch}"\n')
        f.write(f'mkdir -p {ub!r}\n')
        f.write('_tmp=$(mktemp /tmp/.sd_ub_dl_XXXXXX.tar.gz)\n')
        f.write('printf "[ubuntu] Downloading Ubuntu 24.04 LTS Noble (%s)...\\n" "$_sd_ub_arch"\n')
        f.write(f'curl -fsSL --progress-bar "${{_base}}ubuntu-base-${{_ver}}.tar.gz" -o "$_tmp"\n')
        f.write('printf "[ubuntu] Extracting...\\n"\n')
        f.write(f'tar -xzf "$_tmp" -C {ub!r}; rm -f "$_tmp"\n')
        # Compatibility symlinks
        f.write(f'[[ ! -e {ub!r}/bin   ]] && ln -sf usr/bin   {ub!r}/bin   2>/dev/null||true\n')
        f.write(f'[[ ! -e {ub!r}/lib   ]] && ln -sf usr/lib   {ub!r}/lib   2>/dev/null||true\n')
        f.write(f'[[ ! -e {ub!r}/lib64 ]] && ln -sf usr/lib64 {ub!r}/lib64 2>/dev/null||true\n')
        f.write(f'printf "nameserver 8.8.8.8\\n" > {ub!r}/etc/resolv.conf\n')
        f.write(f'mkdir -p {ub!r}/etc/apt/apt.conf.d\n')
        f.write(f'printf \'APT::Sandbox::User "root";\\n\' > {ub!r}/etc/apt/apt.conf.d/99sandbox\n')
        # Mount binds for chroot
        f.write(f'sudo -n mount --bind /proc {ub!r}/proc\n')
        f.write(f'sudo -n mount --bind /sys  {ub!r}/sys\n')
        f.write(f'sudo -n mount --bind /dev  {ub!r}/dev\n')
        # Arch-mismatch guard before chroot
        f.write('_host_arch=$(uname -m)\n')
        f.write('_need_binfmt=0\n')
        f.write('case \"$_host_arch/$_sd_ub_arch\" in\n')
        f.write('  x86_64/amd64|aarch64/arm64|armv7l/armhf) _need_binfmt=0 ;;\n')
        f.write('  *) _need_binfmt=1 ;;\n')
        f.write('esac\n')
        f.write('if [ \"$_need_binfmt\" -eq 1 ]; then\n')
        f.write('  if ! ls /proc/sys/fs/binfmt_misc/qemu-* >/dev/null 2>&1; then\n')
        f.write('    printf \"[ubuntu] ERROR: Host arch (%s) != image arch (%s). Install qemu-user-static + binfmt-support on host.\\n\" \"$_host_arch\" \"$_sd_ub_arch\"\n')
        f.write('    exit 1\n')
        f.write('  fi\n')
        f.write('  _qemu_bin=$(ls /usr/bin/qemu-*-static 2>/dev/null | head -1)\n')
        f.write(f'  [ -n \"$_qemu_bin\" ] && sudo -n cp \"$_qemu_bin\" {ub!r}/usr/bin/ 2>/dev/null||true\n')
        f.write('fi\n')
        # Run apt directly via chroot
        f.write('printf \"[ubuntu] Installing default packages...\\n\"\n')
        f.write(f'sudo -n chroot {ub!r} /usr/bin/apt-get update -qq\n')
        f.write(f'sudo -n chroot {ub!r} /usr/bin/env DEBIAN_FRONTEND=noninteractive '
                f'apt-get install -y --no-install-recommends {DEFAULT_UBUNTU_PKGS}\n')
        f.write(f'sudo -n umount -lf {ub!r}/dev {ub!r}/sys {ub!r}/proc 2>/dev/null||true\n')
        f.write(f'touch {ub!r}/.ubuntu_ready\n')
        f.write(f'date +%Y-%m-%d > {ub!r}/.sd_ubuntu_stamp\n')
        pkgs_lines = '\\n'.join(DEFAULT_UBUNTU_PKGS.split())
        f.write(f'printf "{pkgs_lines}\\n" > {ub!r}/.ubuntu_default_pkgs\n')
        ok = str(G.ubuntu_dir/'.ubuntu_ok_flag'); fail = str(G.ubuntu_dir/'.ubuntu_fail_flag')
        f.write(f'touch {ok!r}\n')
        f.write('printf "\\033[0;32m[ubuntu] Ubuntu base ready.\\033[0m\\n\\n"\n')
        f.write('tmux kill-session -t sdUbuntuSetup 2>/dev/null||true\n')
    lf_ub = str(G.logs_dir/f'sdUbuntuSetup.log') if G.logs_dir else ''
    if not launch_job('sdUbuntuSetup', 'Ubuntu base setup',
                      f'bash {runner.name!r}; rm -f {runner.name!r}',
                      str(ok_f), str(fail_f), lf_ub):
        os.unlink(runner.name); return
    _installing_wait_loop('sdUbuntuSetup', str(ok_f), str(fail_f), 'Ubuntu base setup')
    G.ub_cache_loaded = False
    # Always write correct .ubuntu_default_pkgs from Python constant (never stale)
    if G.ubuntu_dir and ok_f.exists():
        try: (G.ubuntu_dir/'.ubuntu_default_pkgs').write_text('\n'.join(DEFAULT_UBUNTU_PKGS.split()))
        except: pass

# ══════════════════════════════════════════════════════════════════════════════
# services/caddy.py — reverse proxy / Caddy menu
# ══════════════════════════════════════════════════════════════════════════════

def _proxy_cfg_path() -> Path:  return G.mnt_dir/'.sd/proxy.json'
def _proxy_caddy_bin() -> Path: return G.mnt_dir/'.sd/caddy/caddy'
def _proxy_caddy_log() -> Path: return G.mnt_dir/'.sd/caddy/caddy.log'
def _proxy_caddy_storage() -> Path: return G.mnt_dir/'.sd/caddy/data'
def _proxy_sudoers_path() -> Path:
    return Path(f'/etc/sudoers.d/simpledocker_caddy_{__import__("pwd").getpwuid(os.getuid()).pw_name}')

def _proxy_lan_ip() -> str:
    r = _run(['ip','route','get','1'], capture=True)
    toks = r.stdout.split()
    for i,t in enumerate(toks):
        if t == 'src' and i+1 < len(toks): return toks[i+1]
    r2 = _run(['hostname','-I'], capture=True)
    return r2.stdout.split()[0] if r2.stdout.strip() else ''

def _avahi_piddir() -> Path: return G.mnt_dir/'.sd/caddy/avahi'
def _avahi_mdns_name(url: str) -> str:
    return url if url.endswith('.local') else f'{url}.local'

def _avahi_stop():
    piddir = _avahi_piddir()
    if not piddir.is_dir(): return
    for pf in piddir.glob('*.pid'):
        try:
            pid = int(pf.read_text().strip())
            os.kill(pid, signal.SIGTERM)
        except: pass
        pf.unlink(missing_ok=True)
    _run(['pkill','-f','avahi-publish.*--address'])

def _avahi_start():
    if not shutil.which('avahi-publish'): return
    _avahi_stop()
    _avahi_piddir().mkdir(parents=True, exist_ok=True)
    lan_ip = _proxy_lan_ip()
    if not lan_ip: return
    log = str(_proxy_caddy_log())
    load_containers()
    seen = set()
    # Per-container {cid}.local entries
    for cid2 in G.CT_IDS:
        if not st(cid2, 'installed', False): continue
        port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
        if not port or port == '0': continue
        mdns = f'{cid2}.local'
        if mdns in seen: continue
        seen.add(mdns)
        pf = _avahi_piddir()/f'{mdns.replace(".","_").replace("/","_")}.pid'
        proc = subprocess.Popen(['avahi-publish','--address','-R',mdns,lan_ip],
                                 stdin=subprocess.DEVNULL,
                                 stdout=open(log,'a'), stderr=subprocess.STDOUT,
                                 start_new_session=True)
        pf.write_text(str(proc.pid))
    # Per-route public mDNS entries
    try:
        data = json.loads(_proxy_cfg_path().read_text())
        for route in data.get('routes',[]):
            url = route.get('url',''); rcid = route.get('cid','')
            if exposure_get(rcid) != 'public': continue
            mdns = _avahi_mdns_name(url)
            if mdns in seen: continue
            seen.add(mdns)
            pf = _avahi_piddir()/f'{mdns.replace(".","_").replace("/","_")}.pid'
            proc = subprocess.Popen(['avahi-publish','--address','-R',mdns,lan_ip],
                                     stdin=subprocess.DEVNULL,
                                     stdout=open(log,'a'), stderr=subprocess.STDOUT,
                                     start_new_session=True)
            pf.write_text(str(proc.pid))
    except: pass

def _proxy_update_hosts(action='add'):
    """Update /etc/hosts with simpleDocker route entries. Matches shell _proxy_update_hosts."""
    try:
        with open('/etc/hosts') as f:
            lines = [l for l in f.readlines() if '# simpleDocker' not in l]
    except: lines = []
    if action == 'add':
        lan_ip = _proxy_lan_ip()
        try:
            data = json.loads(_proxy_cfg_path().read_text())
            for route in data.get('routes',[]):
                url = route.get('url',''); rcid = route.get('cid','')
                if not url: continue
                exp_mode = exposure_get(rcid)
                host_ip = lan_ip if (exp_mode == 'public' and lan_ip) else '127.0.0.1'
                lines.append(f'{host_ip} {url}  # simpleDocker\n')
                mdns = _avahi_mdns_name(url)
                if mdns != url:
                    lines.append(f'{host_ip} {mdns}  # simpleDocker\n')
                lines.append(f'127.0.0.1 {rcid}.local  # simpleDocker\n')
        except: pass
        load_containers()
        for cid2 in G.CT_IDS:
            if not st(cid2,'installed',False): continue
            port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
            if not port or port == '0': continue
            exp_mode = exposure_get(cid2)
            if exp_mode == 'isolated': continue
            host_ip = lan_ip if (exp_mode == 'public' and lan_ip) else '127.0.0.1'
            lines.append(f'{host_ip} {cid2}.local  # simpleDocker\n')
    tmp = tempfile.mktemp(dir=str(G.tmp_dir))
    Path(tmp).write_text(''.join(lines))
    _run(['sudo','-n','tee','/etc/hosts'], input=''.join(lines).encode(),
         capture=True)
    Path(tmp).unlink(missing_ok=True)

def _proxy_dns_pidfile() -> Path: return G.mnt_dir/'.sd/caddy/dnsmasq.pid'
def _proxy_dns_conf()    -> Path: return G.mnt_dir/'.sd/caddy/dnsmasq.conf'

def _proxy_dns_start():
    """Start dnsmasq for .local DNS. Matches shell _proxy_dns_start."""
    if not shutil.which('dnsmasq'): return
    _proxy_dns_stop()
    lan_ip = _proxy_lan_ip()
    if not lan_ip: return
    conf = _proxy_dns_conf()
    conf.parent.mkdir(parents=True, exist_ok=True)
    conf.write_text(
        f'interface=*\nbind-interfaces\nlisten-address={lan_ip}\n'
        f'domain=local\nlocal=/local/\nno-resolv\n'
    )
    log = str(_proxy_caddy_log())
    proc = subprocess.Popen(
        ['sudo','-n','dnsmasq',f'--conf-file={conf}',
         f'--pid-file={_proxy_dns_pidfile()}','--keep-in-foreground'],
        stdout=open(log,'a'), stderr=subprocess.STDOUT, start_new_session=True)

def _proxy_trust_ca():
    _sudo('chown','-R',f'{os.getuid()}:{os.getgid()}',str(_proxy_caddy_storage()))
    ca_root = _proxy_caddy_storage()/'pki/authorities/local/root.crt'
    _waited = 0
    while not ca_root.exists() and _waited < 10:
        time.sleep(0.5); _waited += 1
    _sudo('chown','-R',f'{os.getuid()}:{os.getgid()}',str(_proxy_caddy_storage()))
    if not ca_root.exists(): return
    _sudo('cp',str(ca_root),'/usr/local/share/ca-certificates/simpleDocker-caddy.crt')
    _sudo('update-ca-certificates','--fresh')
    try:
        dst = G.mnt_dir/'.sd/caddy/ca.crt'
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(str(ca_root), str(dst))
    except Exception: pass

def _proxy_ensure_sudoers():
    """Create caddy runner script (run.sh) and write sudoers rule for it."""
    storage = str(_proxy_caddy_storage())
    caddy   = str(_proxy_caddy_bin())
    runner  = _proxy_caddy_storage().parent / 'run.sh'
    runner.parent.mkdir(parents=True, exist_ok=True)
    runner.write_text(
        f'#!/bin/bash\nexport CADDY_STORAGE_DIR={storage!r}\nexec {caddy!r} "$@"\n'
    )
    runner.chmod(0o755)
    import pwd as _pwd; me = _pwd.getpwuid(os.getuid()).pw_name
    sp = _proxy_sudoers_path()
    parts = [str(runner), '/usr/sbin/update-ca-certificates', '/usr/bin/update-ca-certificates']
    dnsmasq_bin = shutil.which('dnsmasq')
    if dnsmasq_bin:
        pkill_bin = shutil.which('pkill') or '/usr/bin/pkill'
        parts += [dnsmasq_bin, pkill_bin]
    systemctl_bin = shutil.which('systemctl')
    if systemctl_bin:
        parts += [f'{systemctl_bin} start avahi-daemon', f'{systemctl_bin} enable avahi-daemon']
    rule = f'{me} ALL=(ALL) NOPASSWD: {", ".join(p for p in parts if p)}\n'
    try:
        _sudo('tee', str(sp), input=rule)
    except: pass

def _proxy_start(background=False) -> bool:
    if not _proxy_caddy_bin().exists(): return False
    if not _proxy_cfg_path().exists(): return False
    _proxy_write()
    _proxy_update_hosts('add')
    _proxy_ensure_sudoers()
    _proxy_dns_start()
    # Start avahi-daemon if not running
    if _run(['systemctl','is-active','--quiet','avahi-daemon']).returncode != 0:
        _sudo('systemctl','start','avahi-daemon')
    _avahi_start()
    log = str(_proxy_caddy_log())
    pf  = str(_proxy_pidfile())
    storage = str(_proxy_caddy_storage())
    caddy = str(_proxy_caddy_bin())
    cf = str(_proxy_caddyfile())
    env = {**os.environ, 'CADDY_STORAGE_DIR': storage}
    try:
        proc = subprocess.Popen(
            ['sudo','-n',caddy,'run','--config',cf,'--pidfile',pf],
            stdout=open(log,'a'), stderr=subprocess.STDOUT,
            env=env, start_new_session=True)
        if background:
            def _bg_trust():
                w = 0
                while not proxy_running() and w < 20: time.sleep(0.3); w += 1
                _proxy_trust_ca()
            _bg_trust()
            return True
        time.sleep(1.2)
        if not proxy_running(): return False
        _proxy_trust_ca()
        return True
    except: return False

def _proxy_cfg_set(key: str, val):
    p = _proxy_cfg_path()
    try: data = json.loads(p.read_text())
    except: data = {'autostart': False, 'routes': []}
    data[key] = val
    tmp = tempfile.mktemp(dir=str(G.tmp_dir))
    Path(tmp).write_text(json.dumps(data, indent=2)); Path(tmp).rename(p)

def _proxy_cfg_get(key: str) -> str:
    try: return json.loads(_proxy_cfg_path().read_text()).get(key,'')
    except: return ''

def proxy_running() -> bool:
    pf = _proxy_pidfile()
    if not pf.exists(): return False
    try: os.kill(int(pf.read_text().strip()), 0); return True
    except: return False

def _proxy_stop():
    pf = _proxy_pidfile()
    if pf.exists():
        try: _sudo('kill', pf.read_text().strip())
        except: pass
        pf.unlink(missing_ok=True)
    # Also stop avahi/dnsmasq
    try: _avahi_stop()
    except: pass
    _proxy_update_hosts('remove')

def _proxy_write():
    """Generate Caddyfile from proxy.json routes + per-container {cid}.local stanzas."""
    cf = _proxy_caddyfile(); cf.parent.mkdir(parents=True, exist_ok=True)
    r = _run(['ip','route','get','1'], capture=True)
    lan_ip = ''
    for tok in r.stdout.split():
        if tok == 'src':
            idx = r.stdout.split().index(tok)
            lan_ip = r.stdout.split()[idx+1]
            break
    lines = ['{\n  admin off\n  local_certs\n}\n']

    def _pw_stanza(exp_mode, scheme, host, ct_ip, port):
        if exp_mode == 'isolated': return ''
        if scheme == 'https':
            return f'https://{host} {{\n  tls internal\n  reverse_proxy {ct_ip}:{port}\n}}\n\n'
        return f'http://{host} {{\n  reverse_proxy {ct_ip}:{port}\n}}\n\n'

    try:
        data = json.loads(_proxy_cfg_path().read_text())
        for route in data.get('routes', []):
            url = route.get('url',''); cid2 = route.get('cid','')
            https = route.get('https', False)
            port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
            if not port or port == '0': continue
            ct_ip = netns_ct_ip(cid2)
            exp = exposure_get(cid2)
            scheme = 'https' if https else 'http'
            stanza = _pw_stanza(exp, scheme, url, ct_ip, port)
            if stanza: lines.append(stanza)
            # also add .local mDNS variant for non-.local URLs
            mdns_url = _avahi_mdns_name(url)
            if mdns_url != url:
                stanza2 = _pw_stanza(exp, scheme, mdns_url, ct_ip, port)
                if stanza2: lines.append(stanza2)
    except: pass
    # Per-container {cid}.local stanzas (DIV-020)
    load_containers()
    seen_cids = set()
    for cid2 in G.CT_IDS:
        if not st(cid2,'installed',False): continue
        if cid2 in seen_cids: continue
        seen_cids.add(cid2)
        port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
        if not port or port == '0': continue
        ct_ip = netns_ct_ip(cid2)
        exp = exposure_get(cid2)
        stanza = _pw_stanza(exp, 'http', f'{cid2}.local', ct_ip, port)
        if stanza: lines.append(stanza)
    cf.write_text('\n'.join(lines))

def _proxy_install_caddy_menu(reinstall: bool = False):
    """Launch Caddy + mDNS install in tmux session."""
    caddy_dest = _proxy_caddy_bin()
    caddy_dest.parent.mkdir(parents=True, exist_ok=True)
    apt_flags = '--reinstall' if reinstall else ''
    sess = f'sdCaddyMdnsInst_{os.getpid()}'
    ok_f  = G.sd_mnt_base/'.tmp'/f'.sd_caddy_ok_{os.getpid()}'
    fail_f= G.sd_mnt_base/'.tmp'/f'.sd_caddy_fail_{os.getpid()}'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    # Runner in sd_mnt_base/.tmp — outside image
    _ub_tmp = G.sd_mnt_base/'.tmp'
    _ub_tmp.mkdir(parents=True, exist_ok=True)
    runner = tempfile.NamedTemporaryFile(mode='w', dir=str(_ub_tmp),
                                         suffix='.sh', delete=False, prefix='.sd_caddy_inst_')
    with open(runner.name, 'w') as f:
        f.write('#!/usr/bin/env bash\nset -euo pipefail\n')
        f.write(f'_cleanup(){{ local rc=$?; [[ $rc -ne 0 ]] && touch {str(fail_f)!r} || touch {str(ok_f)!r}; '
                f'tmux kill-session -t {sess} 2>/dev/null||true; }}\n')
        f.write('trap _cleanup EXIT\n')
        f.write('printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"\n')
        f.write('case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l) ARCH=armv7;; *) ARCH=amd64;; esac\n')
        f.write('VER=""\n')
        f.write('printf "Fetching latest Caddy version...\\n"\n')
        f.write('VER=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null'
                '|tr -d \'\\n\'|grep -o \'"tag_name":"[^"]*"\'|cut -d: -f2|tr -d \'"v \')||true\n')
        f.write('[[ -z "$VER" ]] && VER=$(curl -fsSL --max-time 15 -o /dev/null -w "%{url_effective}" \\\n')
        f.write('    "https://github.com/caddyserver/caddy/releases/latest" 2>/dev/null | grep -o \'[0-9]*\\.[0-9]*\\.[0-9]*\' | head -1)||true\n')
        f.write('[[ -z "$VER" ]] && { printf "Using fallback version 2.9.1\\n"; VER="2.9.1"; }\n')
        f.write('printf "Version: %s\\n" "$VER"\n')
        f.write('TMPD=$(mktemp -d)\n')
        f.write('URL="https://github.com/caddyserver/caddy/releases/download/v${VER}/caddy_${VER}_linux_${ARCH}.tar.gz"\n')
        f.write('printf "Downloading: %s\\n" "$URL"\n')
        f.write(f'curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz"\n')
        f.write('tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy\n')
        f.write(f'mv "$TMPD/caddy" {caddy_dest!r}; chmod +x {caddy_dest!r}\n')
        f.write('rm -rf "$TMPD"\n')
        f.write('printf "\\033[0;32m✓ Caddy binary ready\\033[0m\\n"\n')
        f.write(f'printf "%s ALL=(ALL) NOPASSWD: {caddy_dest}\\n" "$(id -un)" | sudo -n tee {_proxy_sudoers_path()!r} >/dev/null 2>/dev/null||true\n')
        f.write('printf "\\033[1m── Checking mDNS (avahi-utils) ──────────────\\033[0m\\n"\n')
        f.write('if command -v avahi-publish >/dev/null 2>&1; then\n')
        f.write('  printf "\\033[0;32m✓ avahi-publish found — mDNS will work\\033[0m\\n"\n')
        f.write('else\n')
        f.write('  printf "\\033[0;33m⚠  avahi-utils not found on host.\\n'\
                '   mDNS (.local domains) will be disabled.\\n'\
                '   Install on host: apt/pacman/dnf install avahi-utils\\033[0m\\n"\n')
        f.write('fi\n')
        f.write('printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"\n')
    os.chmod(runner.name, 0o755)
    lf_caddy = str(G.logs_dir/f'{sess}.log') if G.logs_dir else ''
    if not launch_job(sess, 'Install Caddy + mDNS',
                      f'bash {runner.name!r}; rm -f {runner.name!r}',
                      str(ok_f), str(fail_f), lf_caddy):
        os.unlink(runner.name); return
    _installing_wait_loop(sess, str(ok_f), str(fail_f), 'Install Caddy + mDNS')
    # Brief settle so binary is fully written before caller re-checks caddy_ok
    time.sleep(0.3)

def proxy_menu():
    """services/caddy.py — full Caddy / reverse proxy menu"""
    cp = _proxy_cfg_path()
    if not cp.exists(): cp.parent.mkdir(parents=True,exist_ok=True); cp.write_text('{"autostart":false,"routes":[]}')
    while True:
        autostart = str(_proxy_cfg_get('autostart')).lower() == 'true'
        caddy_ok  = _proxy_caddy_bin().exists() and os.access(str(_proxy_caddy_bin()),os.X_OK)
        inst_s    = f'{GRN}installed{NC}' if caddy_ok else f'{RED}not installed{NC}'
        run_s     = f'{GRN}running{NC}'   if proxy_running() else f'{RED}stopped{NC}'
        at_s      = f'{GRN}on{NC}'        if autostart else f'{DIM}off{NC}'
        # Routes
        route_lines = []; route_urls = []
        try:
            data = json.loads(cp.read_text())
            for route in data.get('routes', []):
                rurl = route.get('url',''); rcid = route.get('cid','')
                rhttps = route.get('https', False)
                rname = cname(rcid) if rcid else rcid
                proto = 'https' if rhttps else 'http'
                mdns = _avahi_mdns_name(rurl)
                route_lines.append(f' {CYN}◈{NC}  {CYN}{rurl}{NC}  →  {rname}  {DIM}({proto}  mDNS: {mdns}){NC}')
                route_urls.append(rurl)
        except: pass
        load_containers()
        exp_lines = []; exp_cids2 = []; exp_names2 = []
        for cid2 in G.CT_IDS:
            if not st(cid2,'installed',False): continue
            port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
            if not port or port == '0': continue
            ct_ip = netns_ct_ip(cid2); n2 = cname(cid2)
            exp_lines.append(f' {exposure_label(exposure_get(cid2))}  {n2}  {DIM}{ct_ip}:{port}  {cid2}.local{NC}')
            exp_cids2.append(cid2); exp_names2.append(n2)
        items = [
            _sep('Installation'),
            f' {DIM}◈{NC}  Caddy + mDNS — {inst_s}',
            _sep('Startup'),
            f' {DIM}◈{NC}  Running — {run_s}',
            f' {DIM}◈{NC}  Autostart — {at_s}  {DIM}(starts with img mount){NC}',
            _sep('Rerouting'),
        ]
        items += route_lines
        items.append(f'{GRN} +{NC}  Add URL')
        items.append(_sep('Port exposure'))
        items += exp_lines
        if not exp_cids2: items.append(f'{DIM}  (no installed containers with ports){NC}')
        items += [_nav_sep(), _back_item()]
        idx = netns_idx()
        sel = fzf_run(items, header=f'{BLD}── Reverse proxy ──{NC}  {DIM}ns: 10.88.{idx}.0/24{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if 'Caddy + mDNS' in sc:
            if caddy_ok:
                sel2 = menu('Caddy + mDNS','Reinstall / update','Uninstall','View log','View Caddyfile','Reset proxy config')
                if not sel2: continue
                if 'Reinstall' in sel2: _proxy_install_caddy_menu(reinstall=True)
                elif 'Uninstall' in sel2:
                    _proxy_stop()
                    try: _avahi_stop()
                    except: pass
                    _proxy_caddy_bin().unlink(missing_ok=True)
                    (_proxy_caddy_storage().parent / 'run.sh').unlink(missing_ok=True)
                    _sudo('rm','-f',str(_proxy_sudoers_path()))
                    runner2=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),suffix='.sh',delete=False,prefix='.sd_avahi_')
                    with open(runner2.name,'w') as fh: fh.write('#!/bin/bash\nsudo -n apt-get remove -y avahi-utils 2>&1\n')
                    os.chmod(runner2.name,0o755)
                    tmux_launch('sdAvahiUninst', f'bash {runner2.name!r}; rm -f {runner2.name!r}')
                    pause('Caddy uninstalled.')
                elif 'View log' in sel2:
                    try: tail=_proxy_caddy_log().read_text().splitlines()[-50:]
                    except: tail=['(no log)']
                    pause('\n'.join(tail))
                elif 'View Caddyfile' in sel2:
                    try: content=_proxy_caddyfile().read_text().splitlines()
                    except: content=['(no Caddyfile)']
                    fzf_run(content,header=f'{BLD}── Caddyfile ──{NC}',extra=['--no-multi','--disabled'])
                elif 'Reset proxy config' in sel2:
                    if confirm('⚠  Remove all routes and reset exposure to localhost?'):
                        _proxy_stop()
                        cp.write_text('{"autostart":false,"routes":[]}')
                        for cid2 in G.CT_IDS: exposure_file(cid2).unlink(missing_ok=True)
                        _proxy_write(); _proxy_start()
                        pause('Proxy config reset and restarted.')
            else:
                _proxy_install_caddy_menu(); continue
        elif 'Autostart' in sc:
            _proxy_cfg_set('autostart', not autostart)
        elif 'Running' in sc:
            if proxy_running():
                _proxy_stop(); pause('Proxy stopped.')
            else:
                if _proxy_start(): pause('Proxy started.')
                else:
                    try: tail=_proxy_caddy_log().read_text().splitlines()[-30:]
                    except: tail=['(no log yet)']
                    extra = ''
                    try:
                        log_str = '\n'.join(tail)
                        m = re.search(r'ambiguous site definition: https?://[^:]+:(\d+)', log_str)
                        if not m: m = re.search(r'address already in use.*:(\d+)', log_str)
                        if m:
                            conflict_port = m.group(1)
                            conflicting = [cname(_cc) for _cc in G.CT_IDS
                                           if st(_cc,'installed',False) and
                                           str(sj_get(_cc,'meta','port',default='') or sj_get(_cc,'environment','PORT',default='')) == conflict_port]
                            if len(conflicting) > 1:
                                clist = ''.join(f'  - {n}\n' for n in conflicting)
                                extra = f'\n\n  Port conflict on :{conflict_port} — containers sharing this port:\n{clist}  Fix: change one container port or set one to isolated.'
                    except: pass
                    pause(f'⚠  Caddy failed to start.{extra}\n\nLog:\n'+'\n'.join(tail))
        elif 'Add URL' in sc:
            if not G.CT_IDS: pause('No containers found.'); continue
            ctnames = [cname(c) for c in G.CT_IDS]
            sel2 = fzf_run([f' {DIM}◈  {n}{NC}' for n in ctnames]+[_back_item()],
                           header=f'{BLD}── Add route ──{NC}  {DIM}Select container{NC}')
            if not sel2 or clean(sel2)==L['back']: continue
            sel_ct = clean(sel2).lstrip('◈').strip()
            ncid = next((c for c in G.CT_IDS if cname(c)==sel_ct), None)
            if not ncid: continue
            nport = str(sj_get(ncid,'meta','port',default='') or sj_get(ncid,'environment','PORT',default=''))
            if not nport or nport=='0':
                pause(f'⚠  {sel_ct} has no port.\n  Add port under [meta] in its blueprint.'); continue
            # TODO-014: full prompt matching shell — includes "Other TLDs" DNS note
            v = finput('Enter URL  (e.g. comfyui.local, myapp.local)\n\n'
                       '  Use .local for zero-config LAN access on all devices (mDNS).\n'
                       '  Other TLDs (e.g. .sd) only work on this machine unless you configure DNS.')
            if not v: continue
            nurl = v.strip().lstrip('https://').lstrip('http://').rstrip('/')
            if not nurl: continue
            sel3 = menu(f'Protocol for {nurl}','http  (no cert needed)','https  (tls internal)')
            nhttps = sel3 and 'https' in sel3
            try:
                data2 = json.loads(cp.read_text())
                data2.setdefault('routes',[]).append({'url':nurl,'cid':ncid,'https':nhttps})
                tmp=tempfile.mktemp(dir=str(G.tmp_dir)); Path(tmp).write_text(json.dumps(data2,indent=2)); Path(tmp).rename(cp)
            except: pass
            # TODO-013: call caddy trust in background after adding an https route (matches shell _proxy_menu)
            if nhttps and _proxy_caddy_bin().exists():
                env2 = {**os.environ, 'CADDY_STORAGE_DIR': str(_proxy_caddy_storage())}
                subprocess.Popen(['sudo','-n',str(_proxy_caddy_bin()),'trust'],
                                 env=env2, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if proxy_running(): _proxy_stop(); _proxy_start()
            elif autostart: _proxy_start()
            # TODO-015: include "Visit:" line in success pause (matches shell _proxy_menu)
            scheme = 'https' if nhttps else 'http'
            pause(f'✓ Added: {nurl} → {sel_ct} (port {nport})\n\n  Visit: {scheme}://{nurl}')
        else:
            # Exposure cycle
            for i,n2 in enumerate(exp_names2):
                if n2 in sc:
                    ecid = exp_cids2[i]
                    new_exp = exposure_next(ecid)
                    exposure_set(ecid, new_exp)
                    if tmux_up(tsess(ecid)): exposure_apply(ecid)
                    pause(f'Port exposure set to: {exposure_label(new_exp)}\n\n  isolated — blocked\n  localhost — this machine\n  public — local network')
                    break
            else:
                # Route sub-menu
                for i,rline in enumerate(route_lines):
                    if clean(rline)==sc:
                        rurl=route_urls[i]
                        try:
                            data_r=json.loads(cp.read_text())
                            cur_https=str(next((r.get('https',False) for r in data_r.get('routes',[]) if r.get('url')==rurl),False)).lower()
                        except: cur_https='false'
                        sel2=menu(f'Edit: {rurl}','Change URL','Change container',f'Toggle HTTPS (currently: {cur_https})','Remove')
                        if not sel2: break
                        try: data2=json.loads(cp.read_text())
                        except: break
                        ridx=next((j for j,r in enumerate(data2.get('routes',[])) if r.get('url')==rurl),-1)
                        if ridx<0: break
                        if 'Change URL' in sel2:
                            v=finput(f'New URL for {rurl}:')
                            if v: data2['routes'][ridx]['url']=v.strip()
                        elif 'Change container' in sel2:
                            ctnames2=[cname(c) for c in G.CT_IDS]
                            sel3=fzf_run([f' {DIM}◈  {n}{NC}' for n in ctnames2]+[_back_item()],
                                         header=f'{BLD}── Reassign route ──{NC}')
                            if sel3 and clean(sel3)!=L['back']:
                                new_ct=clean(sel3).lstrip('◈').strip()
                                new_cid2=next((c for c in G.CT_IDS if cname(c)==new_ct),None)
                                if new_cid2: data2['routes'][ridx]['cid']=new_cid2
                        elif 'Toggle HTTPS' in sel2:
                            data2['routes'][ridx]['https']=not data2['routes'][ridx].get('https',False)
                        elif 'Remove' in sel2:
                            if confirm(f"Remove route '{rurl}'?"):
                                data2['routes'].pop(ridx)
                        tmp=tempfile.mktemp(dir=str(G.tmp_dir)); Path(tmp).write_text(json.dumps(data2,indent=2)); Path(tmp).rename(cp)
                        if proxy_running(): _proxy_stop(); _proxy_start()
                        break

# ══════════════════════════════════════════════════════════════════════════════
# menus/resources.py — resource limits
# ══════════════════════════════════════════════════════════════════════════════

def _res_cfg(cid: str) -> Path:  return G.containers_dir/cid/'resources.json'
def _res_get(cid: str, key: str) -> str:
    try: return json.loads(_res_cfg(cid).read_text()).get(key, '')
    except: return ''
def _res_set(cid: str, key: str, val: str):
    f = _res_cfg(cid)
    try: data = json.loads(f.read_text()) if f.exists() else {}
    except: data = {}
    data[key] = val
    tmp = tempfile.mktemp(dir=str(G.tmp_dir)); Path(tmp).write_text(json.dumps(data,indent=2)); Path(tmp).rename(f)
def _res_del(cid: str, key: str):
    f = _res_cfg(cid)
    if not f.exists(): return
    try:
        data = json.loads(f.read_text()); data.pop(key, None)
        tmp = tempfile.mktemp(dir=str(G.tmp_dir)); Path(tmp).write_text(json.dumps(data,indent=2)); Path(tmp).rename(f)
    except: pass

def resources_menu():
    """menus/resources.py"""
    load_containers()
    if not G.CT_IDS: pause('No containers found.'); return
    items = [_sep('Containers')]
    for cid2 in G.CT_IDS:
        rs = ''
        try:
            if json.loads(_res_cfg(cid2).read_text()).get('enabled') == True:
                rs = f'  {GRN}[cgroups on]{NC}'
        except: pass
        items.append(f' {DIM}◈{NC}  {cname(cid2)}{rs}')
    items += [_nav_sep(), _back_item()]
    sel = fzf_run(items, header=f'{BLD}── Resource limits ──{NC}  {DIM}[{len(G.CT_IDS)} containers]{NC}')
    if not sel or clean(sel) == L['back']: return
    sc = strip_ansi(sel).strip().lstrip('◈').strip().split()[0]
    cid2 = next((c for c in G.CT_IDS if cname(c) == sc), None)
    if not cid2: return
    if not _res_cfg(cid2).exists(): _res_cfg(cid2).write_text('{"enabled":false}')
    while True:
        enabled   = str(_res_get(cid2,'enabled')).lower() == 'true'
        cpu_q     = _res_get(cid2,'cpu_quota')   or '(unlimited)'
        mem_max   = _res_get(cid2,'mem_max')      or '(unlimited)'
        mem_swap  = _res_get(cid2,'mem_swap')     or '(unlimited)'
        cpu_wt    = _res_get(cid2,'cpu_weight')   or '(default 100)'
        tog = f'{GRN}● Enabled{NC}' if enabled else f'{RED}○ Disabled{NC}'
        lines = [
            _sep('Configuration'),
            f' {tog}  — toggle cgroups on/off (applies on next start)',
            f'  CPU quota    {CYN}{cpu_q}{NC}  — e.g. 200% = 2 cores',
            f'  Memory max   {CYN}{mem_max}{NC}  — e.g. 8G, 512M',
            f'  Memory+swap  {CYN}{mem_swap}{NC}  — e.g. 10G',
            f'  CPU weight   {CYN}{cpu_wt}{NC}  — 1-10000, default=100',
            _sep('Info'),
            f'  {DIM}GPU/VRAM{NC}     not configurable via cgroups (planned separately)',
            f'  {DIM}Network{NC}      not configurable via cgroups (planned separately)',
            _nav_sep(), _back_item(),
        ]
        sel2 = fzf_run(lines,
                        header=f'{BLD}── Resources: {cname(cid2)} ──{NC}\n{DIM}  Limits apply on container restart via systemd cgroups.{NC}')
        if not sel2 or clean(sel2)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc2 = clean(sel2)
        if 'toggle' in sc2:
            _res_set(cid2,'enabled', 'false' if enabled else 'true')
        elif 'CPU quota' in sc2:
            v = finput('CPU quota (e.g. 200% = 2 cores, blank = remove):')
            if v is None: continue
            if not v.strip(): _res_del(cid2,'cpu_quota')
            else: _res_set(cid2,'cpu_quota',v.strip())
        elif 'Memory max' in sc2:
            v = finput('Memory max (e.g. 8G, 512M, blank = remove):')
            if v is None: continue
            if not v.strip(): _res_del(cid2,'mem_max')
            else: _res_set(cid2,'mem_max',v.strip())
        elif 'Memory+swap' in sc2:
            v = finput('Memory+swap max (e.g. 10G, blank = remove):')
            if v is None: continue
            if not v.strip(): _res_del(cid2,'mem_swap')
            else: _res_set(cid2,'mem_swap',v.strip())
        elif 'CPU weight' in sc2:
            v = finput('CPU weight (1-10000, blank = default 100):')
            if v is None: continue
            if not v.strip(): _res_del(cid2,'cpu_weight')
            else: _res_set(cid2,'cpu_weight',v.strip())

# ══════════════════════════════════════════════════════════════════════════════
# menus/processes.py — active processes
# ══════════════════════════════════════════════════════════════════════════════

def active_processes_menu():
    """menus/processes.py"""
    while True:
        gpu_hdr = ''
        if shutil.which('nvidia-smi'):
            r = _run(['nvidia-smi','--query-gpu=utilization.gpu,memory.used,memory.total',
                      '--format=csv,noheader,nounits'], capture=True)
            if r.returncode == 0:
                parts = [x.strip() for x in r.stdout.strip().split(',')]
                if len(parts) >= 3:
                    gpu_hdr = f'  ·  GPU:{parts[0]}%  VRAM:{parts[1]}/{parts[2]} MiB'
        r = _tmux('list-sessions','-F','#{session_name}', capture=True)
        sd_sessions = [s for s in r.stdout.splitlines()
                       if re.match(r'^sd_[a-z0-9]{8}$|^sdInst_|^sdCron_|^sdResize$|^sdTerm_|^sdAction_|^sdCaddyMdnsInst_|^simpleDocker$', s)]
        display_lines = []; display_sess = []
        for sess in sd_sessions:
            cpu='-'; mem='-'; pid=''
            pr = _tmux('list-panes','-t',sess,'-F','#{pane_pid}', capture=True)
            if pr.returncode == 0:
                pid = pr.stdout.strip().splitlines()[0] if pr.stdout.strip() else ''
            if pid:
                rp = _run(['ps','-p',pid,'-o','pcpu=,rss=,comm=','--no-headers'], capture=True)
                if rp.returncode == 0:
                    parts = rp.stdout.split()
                    if parts:
                        cpu = parts[0]+'%' if parts else '-'
                        rss = int(parts[1]) if len(parts)>1 else 0
                        # sum children
                        rp2 = _run(['ps','--ppid',pid,'-o','pcpu=,rss=','--no-headers'], capture=True)
                        for ch in rp2.stdout.splitlines():
                            ch_parts = ch.split()
                            if ch_parts:
                                try: rss += int(ch_parts[1])
                                except: pass
                        mem = f'{rss//1024}M'
            stats = f'{DIM}CPU:{cpu:<6} RAM:{mem:<6}{NC}'
            if sess == 'simpleDocker':   label = 'simpleDocker  (UI)'
            elif sess.startswith('sdCron_'):
                m2 = re.match(r'^sdCron_([a-z0-9]+)_(\d+)$', sess)
                if m2:
                    cc,ci = m2.group(1),int(m2.group(2))
                    crons = sj_get(cc,'crons') or []
                    cname2 = crons[ci].get('name',f'cron_{ci}') if ci < len(crons) else f'cron_{ci}'
                    label = f'Cron › {cname2}  ({cname(cc)})'
                else: label = sess
            elif sess.startswith('sdInst_'):
                icid = sess[len('sdInst_'):]
                label = f'Install › {cname(icid)}'
            elif sess == 'sdResize':     label = 'Resize operation'
            elif sess.startswith('sdTerm_'):
                tcid = sess[len('sdTerm_'):]
                label = f'Terminal › {cname(tcid)}'
            elif sess.startswith('sdAction_'):
                m = re.match(r'^sdAction_([a-z0-9]+)_(\d+)$', sess)
                if m:
                    ac,ai = m.group(1),m.group(2)
                    albl = sj_get(ac,'actions',int(ai),'label') if isinstance(sj_get(ac,'actions'),list) else ai
                    label = f'Action › {albl or ai}  ({cname(ac)})'
                else: label = sess
            elif re.match(r'^sd_[a-z0-9]{8}$', sess):
                label = cname(sess[3:])
            else: label = sess
            display_lines.append(f'  {label:<36} {stats}  PID:{pid or "-":<7}\t{sess}')
            display_sess.append(sess)
        if not display_lines: pause('No active processes.'); return
        rows  = [_sep('Processes', 38)] + display_lines + [_nav_sep(), _back_item()]
        rsess = ['__sep__'] + display_sess + ['__sep__','__back__']
        sel = fzf_run(rows, header=f'{BLD}── Processes ──{NC}  {DIM}[{len(display_lines)} active]{NC}{gpu_hdr}',
                      with_nth='1', delimiter='\t')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        target = sel.split('\t')[-1].strip() if '\t' in sel else ''
        if not target or target in ('__sep__','__back__'): return
        if confirm(f"Kill '{target}'?"):
            _tmux('send-keys','-t',target,'C-c','')
            time.sleep(0.3)
            _tmux('kill-session','-t',target)
            pause('Killed.')

# ══════════════════════════════════════════════════════════════════════════════
# image/btrfs.py — resize image
# ══════════════════════════════════════════════════════════════════════════════

def resize_image(new_size_arg: str = ''):
    """Resize mounted image — matches shell _resize_image exactly.
    Shrink: btrfs resize → umount → truncate → fresh mount via temp mapper
    Grow:   truncate → fresh mount via temp mapper → btrfs resize max → umount
    Uses a RAM-only temp LUKS keyfile (slot 4) so no passphrase is ever needed.
    """
    if not G.img_path or not G.mnt_dir:
        pause('No image mounted.'); return

    new_size_arg = re.sub(r'[^0-9]', '', new_size_arg.strip())
    if not new_size_arg:
        pause('Invalid size. Must be a whole number.'); return
    new_gib = int(new_size_arg)

    cur_bytes_r = _run(['stat', '--printf=%s', str(G.img_path)], capture=True)
    cur_gib_f   = int(cur_bytes_r.stdout.strip()) / (1 << 30) if cur_bytes_r.returncode == 0 else 0

    # Minimum safe size
    used_bytes = 0
    if subprocess.run(['mountpoint', '-q', str(G.mnt_dir)], capture_output=True).returncode == 0:
        r_btrfs = _run(['btrfs', 'filesystem', 'usage', '-b', str(G.mnt_dir)], capture=True)
        if r_btrfs.returncode == 0:
            for ln in r_btrfs.stdout.splitlines():
                if 'used' in ln.lower():
                    m = re.search(r'(\d+)', ln); used_bytes = int(m.group(1)) if m else 0; break
        if not used_bytes:
            r_df = _run(['df', '-k', str(G.mnt_dir)], capture=True)
            if r_df.returncode == 0:
                used_bytes = int(r_df.stdout.splitlines()[-1].split()[2]) * 1024
    min_gib = int(used_bytes / (1 << 30)) + 1 + 10
    if new_gib < min_gib:
        pause(f'Invalid size. Must be ≥ {min_gib} GB.'); return

    load_containers()
    running_cts  = [c for c in G.CT_IDS if tmux_up(tsess(c))]
    running_names= [cname(c) for c in running_cts]
    cur_gib_s    = f'{cur_gib_f:.1f}'
    confirm_msg  = (f'Running services will be stopped:\n' +
                    ''.join(f'  • {n}\n' for n in running_names) +
                    f'\nResize image from {cur_gib_s} GB → {new_gib} GB?'
                    if running_names else
                    f'Resize image from {cur_gib_s} GB → {new_gib} GB?')
    if not confirm(confirm_msg): return

    for c in running_cts:
        _tmux('send-keys', '-t', tsess(c), 'C-c', '')
        time.sleep(0.3)
        _tmux('kill-session', '-t', tsess(c))
    r2 = _tmux('list-sessions', '-F', '#{session_name}', capture=True)
    for s in (r2.stdout.splitlines() if r2.returncode == 0 else []):
        if s.startswith('sdInst_'): _tmux('kill-session', '-t', s)
    tmux_set('SD_INSTALLING', '')
    if running_cts: time.sleep(0.5)

    sess  = 'sdResize'
    if tmux_up(sess): pause('A resize is already running.'); return

    import uuid as _uuid
    _uid     = _uuid.uuid4().hex[:8]
    is_luks  = img_is_luks(G.img_path)
    action   = 'shrink' if new_gib < cur_gib_f else 'extend'
    new_bytes= new_gib * (1 << 30)
    img      = str(G.img_path)
    mnt      = str(G.mnt_dir)
    # Temp mapper name for resize mounts (matches shell sd_rsz_$$)
    rsz_mapper = f'sd_rsz_{os.getpid()}'

    # All temp files outside the image so they survive umount
    _rz_ext_tmp = G.sd_mnt_base / '.tmp'
    _rz_ext_tmp.mkdir(parents=True, exist_ok=True)
    ok_f   = _rz_ext_tmp / f'.sd_resize_ok_{_uid}'
    fail_f = _rz_ext_tmp / f'.sd_resize_fail_{_uid}'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    _runner_path = _rz_ext_tmp / 'sd_resize_last.sh'

    # ── Prepare RAM keyfile for LUKS (no passphrase interaction) ──────────────
    # Add a random 64-byte key to slot 4 using whichever key currently has the
    # image open. Write to /dev/shm (RAM only). Kill slot 4 + wipe file after resize.
    _auth_kf_tmp: Optional[Path] = None
    _tmp_slot: Optional[str]     = None
    if is_luks:
        _ram = Path('/dev/shm')
        _kf_dir = _ram if _ram.is_dir() and os.access(str(_ram), os.W_OK) else _rz_ext_tmp

        # Try auth.key first, then known raw keys
        _src_kf = enc_authkey_path()
        if _src_kf.exists():
            import shutil as _sh2
            _auth_kf_tmp = Path(tempfile.mktemp(dir=str(_kf_dir), prefix='.sd_rzk_'))
            _sh2.copy2(str(_src_kf), str(_auth_kf_tmp))
            _auth_kf_tmp.chmod(0o644)
        else:
            _existing_key: Optional[bytes] = None
            for _k in [G.verification_cipher.encode(), SD_DEFAULT_KEYWORD.encode()]:
                if subprocess.run(
                        ['sudo', '-n', 'cryptsetup', 'open', '--test-passphrase',
                         '--batch-mode', '--key-file=-', str(G.img_path)],
                        input=_k, capture_output=True).returncode == 0:
                    _existing_key = _k; break
            if _existing_key is not None:
                # Find a genuinely free slot (never kill existing keys)
                _free = enc_free_slot()
                if _free:
                    _tmp_key = os.urandom(64)
                    _auth_kf_tmp = Path(tempfile.mktemp(dir=str(_kf_dir), prefix='.sd_rzk_'))
                    _auth_kf_tmp.write_bytes(_tmp_key)
                    _auth_kf_tmp.chmod(0o644)
                    _add = subprocess.run(
                        ['sudo', '-n', 'cryptsetup', 'luksAddKey', '--batch-mode',
                         '--pbkdf', 'pbkdf2', '--pbkdf-force-iterations', '1000', '--hash', 'sha1',
                         '--key-slot', _free, '--key-file', '-',
                         str(G.img_path), str(_auth_kf_tmp)],
                        input=_existing_key, capture_output=True)
                    if _add.returncode == 0:
                        _tmp_slot = _free
                    else:
                        _auth_kf_tmp.unlink(missing_ok=True); _auth_kf_tmp = None

    # ── Build bash script matching shell _do_mount / _do_umount pattern ───────
    kf_path  = str(_auth_kf_tmp) if _auth_kf_tmp else ''
    is_luks_i= int(is_luks)

    # _do_mount: losetup --find --show, then if LUKS open with keyfile, then mount
    def _do_mount_lines(img_var, mnt_var, mapper_name):
        ls = [
            f'  _lo=$(sudo -n losetup --find --show {img_var})',
            f'  if [[ {is_luks_i} -eq 1 ]]; then',
        ]
        if kf_path:
            ls.append(f'    sudo -n cryptsetup open --batch-mode --key-file={kf_path!r} "$_lo" {mapper_name!r}')
        else:
            ls.append(f'    sudo -n cryptsetup open --batch-mode --key-file=- "$_lo" {mapper_name!r} <<< {SD_DEFAULT_KEYWORD!r}')
        ls += [
            f'    sudo -n mount -o compress=zstd /dev/mapper/{mapper_name!r} {mnt_var}',
            f'  else',
            f'    sudo -n mount -o compress=zstd "$_lo" {mnt_var}',
            f'  fi',
        ]
        return '\n'.join(ls)

    # _do_umount: umount, close LUKS, detach loop
    def _do_umount_lines(mnt_var, mapper_name):
        ls = [
            f'  sudo -n umount {mnt_var}',
            f'  if [[ {is_luks_i} -eq 1 ]]; then',
            f'    sudo -n cryptsetup close {mapper_name!r} 2>/dev/null || true',
            f'  fi',
            f'  [[ -n "$_lo" ]] && sudo -n losetup -d "$_lo" 2>/dev/null || true',
        ]
        return '\n'.join(ls)

    script = [
        '#!/usr/bin/env bash',
        'set -euo pipefail',
        f'_ok_f={str(ok_f)!r}',
        f'_fail_f={str(fail_f)!r}',
        f'_kf={kf_path!r}',
        '_cleanup(){ local c=$?',
        '  [[ -n "$_kf" ]] && { dd if=/dev/zero of="$_kf" bs=64 count=1 2>/dev/null||true; rm -f "$_kf"; }',
        '  [[ $c -ne 0 ]] && touch "$_fail_f" || touch "$_ok_f"; }',
        'trap _cleanup EXIT',
        r"trap 'exit 130' INT TERM",
        f'printf "\033[1mResize: {action} to {new_gib} GB\033[0m\n"',
        '_tmp_mnt=$(mktemp -d /tmp/.sd_mnt_XXXXXX)',
        f'printf "Syncing...\n"',
        f'sudo -n btrfs filesystem sync {mnt!r} 2>/dev/null || true',
        '_lo=""',
    ]

    if action == 'shrink':
        # LUKS payload offset: btrfs starts after the LUKS header.
        # btrfs resize target = new_bytes - luks_overhead, so truncate doesn't cut into fs.
        _luks_payload_bytes = 0
        if is_luks:
            _dump = subprocess.run(['sudo','-n','cryptsetup','luksDump',str(G.img_path)],
                                    capture_output=True).stdout.decode()
            for _line in _dump.splitlines():
                # LUKS2: "Payload offset: NNNN" in 512-byte sectors
                # LUKS1: "Payload offset:	 NNNN" in 512-byte sectors  
                if 'Payload offset' in _line:
                    try:
                        _sectors = int(_line.split()[-1])
                        _luks_payload_bytes = _sectors * 512
                    except: pass
                    break
            if not _luks_payload_bytes:
                _luks_payload_bytes = 16 * 1024 * 1024  # safe default: 16MB
        _btrfs_new_bytes = new_bytes - _luks_payload_bytes
        script += [
            f'printf "Shrinking BTRFS filesystem...\n"',
            f'sudo -n btrfs filesystem resize {_btrfs_new_bytes} {mnt!r}',
            f'printf "Unmounting original...\n"',
            f'sudo -n umount {mnt!r}',
            f'if [[ {is_luks_i} -eq 1 ]]; then',
            f'  sudo -n cryptsetup close {luks_mapper(G.img_path)!r} 2>/dev/null || true',
            f'fi',
            f'sudo -n losetup -j {img!r} 2>/dev/null | cut -d: -f1 | while read _ld; do sudo -n losetup -d "$_ld" 2>/dev/null||true; done',
            f'printf "Truncating image to {new_gib}G...\n"',
            f'truncate -s {new_bytes} {img!r}',
        ]
    else:
        # Grow: truncate first, then fresh mount
        script += [
            f'printf "Unmounting original...\n"',
            f'sudo -n umount {mnt!r}',
            f'if [[ {is_luks_i} -eq 1 ]]; then',
            f'  sudo -n cryptsetup close {luks_mapper(G.img_path)!r} 2>/dev/null || true',
            f'fi',
            f'sudo -n losetup -j {img!r} 2>/dev/null | cut -d: -f1 | while read _ld; do sudo -n losetup -d "$_ld" 2>/dev/null||true; done',
            f'printf "Extending image to {new_gib}G...\n"',
            f'truncate -s {new_bytes} {img!r}',
        ]

    # Fresh mount to tmp dir using temp mapper
    script += [
        f'printf "Remounting (temp)...\n"',
        _do_mount_lines(repr(img), '"$_tmp_mnt"', rsz_mapper),
    ]

    if action == 'extend':
        script += [
            f'printf "Resizing BTRFS filesystem...\n"',
            f'sudo -n btrfs filesystem resize max "$_tmp_mnt"',
        ]

    # Unmount temp, final remount to original path
    script += [
        f'printf "Final remount...\n"',
        _do_umount_lines('"$_tmp_mnt"', rsz_mapper),
        f'rm -rf "$_tmp_mnt" 2>/dev/null || true',
        f'_lo=""',
        f'mkdir -p {mnt!r}',
        _do_mount_lines(repr(img), repr(mnt), luks_mapper(G.img_path)),
        f'sudo -n chown "$(id -u)":"$(id -g)" {mnt!r} 2>/dev/null || true',
        f'printf "\033[0;32m✓ Resize to {new_gib} GB complete.\033[0m\n"',
    ]

    script = [l for l in script if l != '']
    _runner_path.write_text('\n'.join(script) + '\n')
    os.chmod(str(_runner_path), 0o755)

    lf_rz = str(_rz_ext_tmp / 'sd_resize_last.log')
    if not launch_job(sess, f'Resize image → {new_gib} GB',
                      f'bash {str(_runner_path)!r}',
                      str(ok_f), str(fail_f), lf_rz):
        _runner_path.unlink(missing_ok=True)
        if _auth_kf_tmp: _auth_kf_tmp.unlink(missing_ok=True)
        return

    _installing_wait_loop(sess, str(ok_f), str(fail_f), 'Resize image')
    while tmux_up(sess): time.sleep(0.3)
    resize_ok = ok_f.exists()
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)

    # Kill temp slot + wipe RAM key
    if _tmp_slot and _auth_kf_tmp and _auth_kf_tmp.exists():
        subprocess.run(
            ['sudo', '-n', 'cryptsetup', 'luksKillSlot', '--batch-mode',
             '--key-file', str(_auth_kf_tmp), str(G.img_path), _tmp_slot],
            capture_output=True)
    if _auth_kf_tmp:
        try: _auth_kf_tmp.write_bytes(b'\x00' * 64)
        except: pass
        _auth_kf_tmp.unlink(missing_ok=True)

    if not resize_ok:
        if G.img_path and G.mnt_dir and not G.mnt_dir.is_mount():
            mount_img(G.img_path)

def help_menu():
    """menus/help.py — the Other / ? menu"""
    while True:
        ub_cache_read()
        if G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists():
            ubuntu_status = f'{GRN}ready{NC}  {CYN}[P]{NC}'
            ubuntu_upd_tag = ''
            if G.ub_pkg_drift or G.ub_has_updates:
                ubuntu_upd_tag = f'  {YLW}Updates available{NC}'
        else:
            ubuntu_status = f'{YLW}not installed{NC}'
            ubuntu_upd_tag = ''
        proxy_s = f'{GRN}running{NC}' if proxy_running() else f'{DIM}stopped{NC}'
        # Fast file-existence check instead of slow chroot call every render
        qr_installed = bool(G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists()
                            and (G.ubuntu_dir/'usr/bin/qrencode').exists())
        qr_s = f'{GRN}installed{NC}' if qr_installed else f'{DIM}not installed{NC}'
        items = [
            _sep('Storage'),
            f'{DIM} ◈  Profiles & data{NC}',
            f'{DIM} ◈  Backups{NC}',
            f'{DIM} ◈  Blueprint detection{NC}',
            _sep('Plugins'),
            f' {CYN}◈{NC}{DIM}  Ubuntu base — {ubuntu_status}{ubuntu_upd_tag}{NC}',
            f' {CYN}◈{NC}{DIM}  Caddy — {proxy_s}{NC}',
            f' {CYN}◈{NC}{DIM}  QRencode — {qr_s}{NC}',
            _sep('Tools'),
            f'{DIM} ◈  Active processes{NC}',
            f'{DIM} ◈  Resource limits{NC}',
            f'{DIM} ≡  Blueprint preset{NC}',
            _sep('Caution'),
            f'{DIM} ≡  View logs{NC}',
            f'{DIM} ⊘  Clear cache{NC}',
            f'{DIM} ▷  Resize image{NC}',
            f'{DIM} ◈  Manage Encryption{NC}',
            f' {RED}×{NC}{DIM}  Delete image file{NC}',
            _nav_sep(), _back_item(),
        ]
        sel = fzf_run(items, header=f'{BLD}── {L["help"]} ──{NC}  {DIM}Ubuntu:{NC} {ubuntu_status}  {DIM}Proxy:{NC} {proxy_s}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if   'Profiles & data' in sc:  persistent_storage_menu()
        elif 'Backups' in sc:          _global_backups_menu()
        elif 'Blueprint detection' in sc: blueprints_settings_menu()
        elif 'Ubuntu base' in sc:      ubuntu_menu()
        elif 'Caddy' in sc:            proxy_menu()
        elif 'QRencode' in sc:         _qrencode_menu()
        elif 'Active processes' in sc: active_processes_menu()
        elif 'Resource limits' in sc:  resources_menu()
        elif 'Blueprint preset' in sc:
            fzf_run(bp_template().splitlines(),
                    header=f'{BLD}── Blueprint preset  {DIM}(read only){NC} ──{NC}',
                    extra=['--no-multi','--disabled'])
        elif 'View logs' in sc:        logs_browser()
        elif 'Clear cache' in sc:
            if confirm('Clear all cached data?'):
                shutil.rmtree(str(G.cache_dir/'sd_size'), ignore_errors=True)
                shutil.rmtree(str(G.cache_dir/'gh_tag'), ignore_errors=True)
                (G.cache_dir/'sd_size').mkdir(parents=True, exist_ok=True)
                (G.cache_dir/'gh_tag').mkdir(parents=True, exist_ok=True)
                pause('Cache cleared.')
        elif 'Resize image' in sc:
            if not G.img_path or not G.mnt_dir: pause('No image mounted.'); continue
            cur_bytes_r = _run(['stat','--printf=%s',str(G.img_path)], capture=True)
            cur_gib = int(cur_bytes_r.stdout.strip())/(1<<30) if cur_bytes_r.returncode==0 else 0
            used_bytes = 0
            if subprocess.run(['mountpoint','-q',str(G.mnt_dir)], capture_output=True).returncode==0:
                r_btrfs = _run(['btrfs','filesystem','usage','-b',str(G.mnt_dir)], capture=True)
                if r_btrfs.returncode==0:
                    for ln in r_btrfs.stdout.splitlines():
                        if 'used' in ln.lower():
                            m=re.search(r'(\d+)',ln); used_bytes=int(m.group(1)) if m else 0; break
                if not used_bytes:
                    r_df=_run(['df','-k',str(G.mnt_dir)], capture=True)
                    if r_df.returncode==0:
                        parts=r_df.stdout.splitlines()[-1].split()
                        used_bytes=int(parts[2])*1024
            used_gib = used_bytes/(1<<30)
            min_gib  = int(used_bytes/(1<<30))+1+10
            v = finput(f'Current: {cur_gib:.1f} GB   Used: {used_gib:.1f} GB   Minimum: {min_gib} GB\n\nNew size in GB:')
            if v: resize_image(v)
        elif 'Manage Encryption' in sc:
            enc_menu()
        elif 'Delete image file' in sc:
            if not G.img_path: pause('No image currently loaded.'); continue
            img_name = G.img_path.name; img_save = G.img_path
            if not confirm(f'PERMANENTLY DELETE IMAGE?\n\n  File: {img_name}\n  Path: {img_save}\n\n  THIS CANNOT BE UNDONE!'): continue
            load_containers()
            for cid2 in G.CT_IDS:
                sess2 = tsess(cid2)
                if tmux_up(sess2):
                    _tmux('send-keys','-t',sess2,'C-c',''); time.sleep(0.3)
                    _tmux('kill-session','-t',sess2)
            r2 = _tmux('list-sessions','-F','#{session_name}', capture=True)
            for s in (r2.stdout.splitlines() if r2.returncode==0 else []):
                if s.startswith('sdInst_'): _tmux('kill-session','-t',s)
            tmux_set('SD_INSTALLING','')
            unmount_img()
            try: img_save.unlink()
            except Exception as e: pause(f'Failed: {e}'); continue
            pause(f'✓ Image deleted: {img_name}\n\n  Select or create a new image.')
            setup_image(); return

def _global_backups_menu():
    """All containers — matches shell _manage_backups_menu."""
    load_containers()
    if not G.CT_IDS: pause('No containers found.'); return
    items = [_sep('Containers')]
    for cid2 in G.CT_IDS:
        items.append(f' {DIM}◈{NC}  {cname(cid2)}')
    items += [_nav_sep(), _back_item()]
    sel = fzf_run(items, header=f'{BLD}── Manage backups ──{NC}')
    if not sel or clean(sel) == L['back']: return
    sc = clean(sel)
    for cid2 in G.CT_IDS:
        if cname(cid2) in sc: container_backups_menu(cid2); return

def _qrencode_menu():
    """Plugin: QRencode — menus/help.py"""
    while True:
        if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists():
            pause('Ubuntu base not installed. Install Ubuntu first.'); return
        for _qr_sess in ('sdQrInst', 'sdQrUninst'):
            if tmux_up(_qr_sess):
                _upkg_ok   = G.ubuntu_dir/'.upkg_ok'
                _upkg_fail = G.ubuntu_dir/'.upkg_fail'
                _installing_wait_loop(_qr_sess, str(_upkg_ok), str(_upkg_fail), 'QRencode operation')
                break
        qr_ok = bool(G.ubuntu_dir and (G.ubuntu_dir/'usr/bin/qrencode').exists())
        if qr_ok:
            sel = menu('QRencode',f'{CYN}↑  Update{NC}',f'{RED}×  Uninstall{NC}')
            if not sel: return
            if 'Update' in sel:
                cmd = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1'
                _ubuntu_pkg_op('sdQrInst','Update QRencode',cmd)
            elif 'Uninstall' in sel:
                if confirm('Uninstall QRencode from Ubuntu?'):
                    cmd = 'DEBIAN_FRONTEND=noninteractive apt-get remove -y qrencode 2>&1'
                    _ubuntu_pkg_op('sdQrUninst','Uninstall QRencode',cmd)
            continue
        else:
            sel = menu('QRencode',f'{GRN}↓  Install{NC}')
            if not sel: return
            if 'Install' in sel:
                cmd = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1'
                _ubuntu_pkg_op('sdQrInst','Install QRencode',cmd)
            continue

# ══════════════════════════════════════════════════════════════════════════════
# menus/main_menu.py — main menu + quit
# ══════════════════════════════════════════════════════════════════════════════

def quit_menu():
    """menus/main_menu.py"""
    sel = fzf_run(
        [f'{DIM}⊙  {L["detach"]}{NC}', f'{RED}■  {L["quit_stop_all"]}{NC}'],
        header=f'{BLD}── {L["quit"]} ──{NC}\n{DIM}  Detach leaves everything running in background.{NC}'
    )
    if not sel: return
    sc = strip_ansi(sel).strip()
    if '⊙' in sc or L['detach'] in sc:
        tmux_set('SD_DETACH','1')
        _tmux('detach-client')
    elif '■' in sc or L['quit_stop_all'] in sc:
        quit_all()

def quit_all():
    """menus/main_menu.py — stop all + exit"""
    if not confirm('Stop all containers and quit?'): return
    load_containers()
    for cid2 in G.CT_IDS:
        sess = tsess(cid2)
        if tmux_up(sess):
            _tmux('send-keys','-t',sess,'C-c','')
            time.sleep(0.3)
            _tmux('kill-session','-t',sess)
        ok_f = G.containers_dir/cid2/'.install_ok'
        fail_f= G.containers_dir/cid2/'.install_fail'
        if is_installing(cid2) and not ok_f.exists() and not fail_f.exists():
            fail_f.touch()
    r = _tmux('list-sessions','-F','#{session_name}', capture=True)
    for s in r.stdout.splitlines():
        if s.startswith('sdInst_'): _tmux('kill-session','-t',s)
    tmux_set('SD_INSTALLING','')
    unmount_img()
    os.system('clear')
    _tmux('kill-session','-t','simpleDocker')
    sys.exit(0)

def main_menu():
    """menus/main_menu.py"""
    while True:
        os.system('clear')
        _cleanup_stale_installing()
        load_containers()
        n_running = sum(1 for c in G.CT_IDS if tmux_up(tsess(c)))
        n_ct = len(G.CT_IDS)
        gids  = _list_groups()
        n_grp = len(gids)
        # Count groups with at least one running container — matches .sh grp_n_active
        grp_n_active = sum(
            1 for gid in gids
            if any(
                _ct_id_by_name(mn) and tmux_up(tsess(_ct_id_by_name(mn)))
                for mn in _grp_containers(gid)
            )
        )
        n_bp  = len(_list_blueprint_names()) + len(_list_imported_names())
        # Image label
        img_label = ''
        if G.img_path and G.mnt_dir:
            r = _run(['df','-k',str(G.mnt_dir)], capture=True)
            if r.returncode == 0:
                parts = r.stdout.splitlines()[-1].split()
                used_gb = int(parts[2])/1048576
                total_gb = G.img_path.stat().st_size / 1073741824 if G.img_path.exists() else int(parts[1])/1048576
                img_label = f'  {DIM}{G.img_path.stem}  [{used_gb:.1f}/{total_gb:.1f} GB]{NC}'
        if n_running > 0:
            ct_status = f'{GRN}{n_running} running{NC}{DIM}/{n_ct}{NC}'
        else:
            ct_status = f'{DIM}{n_ct}{NC}'
        if grp_n_active > 0:
            grp_status = f'{GRN}{grp_n_active} active{NC}{DIM}/{n_grp}{NC}'
        else:
            grp_status = f'{DIM}{n_grp}{NC}'
        items = [
            f' {GRN}◈{NC}  {"Containers":<28} {ct_status}',
            f' {CYN}▶{NC}  {"Groups":<28} {grp_status}',
            f' {BLU}◈{NC}  {"Blueprints":<28} {DIM}{n_bp}{NC}',
            f'{BLD}  ─────────────────────────────────────{NC}',
            f' {DIM}?  {L["help"]}{NC}',
            f' {RED}×  {L["quit"]}{NC}',
        ]
        hdr = f'{BLD}── {L["title"]} ──{NC}{img_label}'
        sel = fzf_run(items, header=hdr, extra=[
            f'--bind={KB["quit"]}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort',
        ])
        if sel is None:
            if G.usr1_fired: G.usr1_fired = False; continue
            if tmux_get('SD_QUIT') == '1':
                tmux_set('SD_QUIT','0'); quit_menu(); continue
            quit_all(); continue
        sc = clean(sel)
        if   'Containers' in sc:  containers_submenu()
        elif 'Groups' in sc:      groups_menu()
        elif 'Blueprints' in sc:  blueprints_submenu()
        elif L['help'] in sc or '?' in sc: help_menu()
        elif L['quit'] in sc or '×' in sc: quit_menu()

# ══════════════════════════════════════════════════════════════════════════════
# main.py — startup bootstrap
# ══════════════════════════════════════════════════════════════════════════════

def _bootstrap_tmux():
    """Outer shell: create tmux session if needed, then re-attach loop.
    Inner process detected via SD_INNER=1 env var OR $TMUX being set (already inside tmux).
    Matches .sh which uses [[ -z "$TMUX" ]] to detect the outer shell."""
    if os.environ.get('SD_INNER') == '1' or os.environ.get('TMUX'):
        return  # inner process — skip outer bootstrap
    me = os.path.abspath(sys.argv[0])
    if not shutil.which('tmux'):
        print(f'{RED}✗  tmux is required but not found.{NC}'); sys.exit(1)
    # Write sudoers and validate credentials — matches shell _sd_outer_sudo exactly.
    # Shell always: sudo -k (invalidate cache), then sudo -v (prompt with retry).
    # We must do this every launch so a revoked/changed password is caught immediately.
    sudoers = f'/etc/sudoers.d/simpledocker_{os.popen("id -un").read().strip()}'
    write_sudoers()
    sess = 'simpleDocker'
    # Match .sh exactly: only kill if session exists but SD_READY≠1 (stuck/crashed)
    if tmux_up(sess):
        r_ready = subprocess.run(
            ['tmux','show-environment','-t',sess,'SD_READY'],
            capture_output=True, text=True)
        if r_ready.stdout.strip() != 'SD_READY=1':
            subprocess.run(['tmux','kill-session','-t',sess], capture_output=True)
            time.sleep(0.5)
    # Create session if not running
    if not tmux_up(sess):
        _extra_args = ' '.join(sys.argv[1:])
        cmd = f'env SD_INNER=1 python3 {me!r} {_extra_args}'.strip()
        r = subprocess.run(
            ['tmux','new-session','-d','-s',sess,cmd],
            capture_output=True)
        if r.returncode != 0:
            print(f'{RED}✗  Failed to create tmux session:{NC}', r.stderr.decode().strip())
            sys.exit(1)
        subprocess.run(['tmux','set-option','-t',sess,'status','off'], capture_output=True)
    # Give inner process a moment to start
    time.sleep(0.3)
    # Re-attach loop: keep attaching until user deliberately detaches (SD_DETACH=1)
    # Matches the shell version exactly — re-attaches on accidental detach,
    # only breaks on ctrl-d (which sets SD_DETACH=1) or when session dies.
    while tmux_up(sess):
        subprocess.run(['tmux','attach-session','-t',sess])
        os.system('stty sane 2>/dev/null')
        # Drain buffered stdin — mirrors the shell's:
        #   while IFS= read -r -t 0.1 -n 256 _ 2>/dev/null; do :; done
        try:
            import termios, select
            fd = sys.stdin.fileno()
            # Flush kernel tty input buffer via tcflush, then drain any remaining
            try: termios.tcflush(fd, termios.TCIFLUSH)
            except: pass
            # Read-discard loop: consume anything left in the Python/OS buffer
            while select.select([sys.stdin], [], [], 0.05)[0]:
                try: os.read(fd, 256)
                except: break
        except: pass
        os.system('clear')
        if tmux_get('SD_DETACH') == '1':
            subprocess.run(['tmux','set-environment','-g','SD_DETACH','0'], capture_output=True)
            os.system('clear')
            break
    # If session died unexpectedly, capture pane contents for diagnosis
    if not tmux_up(sess):
        r = subprocess.run(['tmux','capture-pane','-p','-t',f'{sess}:0'],
                           capture_output=True)
        out = r.stdout.decode().strip() if r.returncode == 0 else ''
        if out:
            print(f'\n{RED}simpleDocker session ended unexpectedly:{NC}\n{out}\n')
    os.system('clear')
    sys.exit(0)

def _force_quit():
    """Emergency cleanup: stop all containers, unmount image, kill tmux session.
    Mirrors shell _force_quit — called from INT/TERM/HUP handlers."""
    G.running = False
    if G.containers_dir and G.containers_dir.is_dir():
        try:
            for cid2 in G.CT_IDS:
                sess = tsess(cid2)
                if tmux_up(sess):
                    _tmux('send-keys','-t',sess,'C-c','')
                    time.sleep(0.2)
                    _tmux('kill-session','-t',sess)
                ok_f  = G.containers_dir/cid2/'.install_ok'
                fail_f= G.containers_dir/cid2/'.install_fail'
                if is_installing(cid2) and not ok_f.exists() and not fail_f.exists():
                    fail_f.touch()
        except: pass
    try:
        r = _tmux('list-sessions','-F','#{session_name}', capture=True)
        for s in (r.stdout.splitlines() if r.returncode==0 else []):
            if s.startswith('sdInst_'): _tmux('kill-session','-t',s)
    except: pass
    try: unmount_img()
    except: pass
    # Quick mapper+loop cleanup (only if something is actually there)
    try:
        mnt_dirs = list(G.sd_mnt_base.glob('mnt_*/'))
        if mnt_dirs:
            for mnt in mnt_dirs:
                _sudo('umount','-lf',str(mnt), capture=True)
                try: mnt.rmdir()
                except: pass
        sd_maps = [mp for mp in Path('/dev/mapper').glob('sd_*')
                   if stat.S_ISBLK(os.stat(str(mp)).st_mode)]
        for mp in sd_maps:
            _sudo('cryptsetup','close',mp.name, capture=True)
        lo_r = _run(['sudo','-n','losetup','-a'], capture=True)
        for line in lo_r.stdout.splitlines():
            if '.img' in line:
                _sudo('losetup','-d',line.split(':')[0], capture=True)
    except: pass
    os.system('clear')
    _tmux('kill-session','-t','simpleDocker')
    sys.exit(0)

def _signal_handler(signum, frame):
    """SIGUSR1 → refresh active fzf (used for auto-refresh on state change)."""
    G.usr1_fired = True
    if G.active_fzf_pid:
        try: os.kill(G.active_fzf_pid, signal.SIGUSR1)
        except: pass

def _quit_signal_handler(signum, frame):
    """INT/TERM/HUP/QUIT → force quit with full cleanup. Never prints a traceback."""
    # Kill active fzf so terminal is clean before we clear
    if G.active_fzf_pid:
        try: os.kill(G.active_fzf_pid, signal.SIGTERM)
        except: pass
    try: _force_quit()
    except SystemExit: raise
    except: pass
    sys.exit(0)

def _check_btrfs_kernel():
    r = _run(['grep','-qw','btrfs','/proc/filesystems'], capture=True)
    if r.returncode != 0:
        r2 = _sudo('modprobe','btrfs')
        if r2.returncode != 0:
            print(f'{RED}✗  BTRFS kernel module not available.{NC}')
            print('  Enable BTRFS support or use a kernel that includes it.')
            sys.exit(1)

def _main():
    # ── Dependency check — runs BEFORE anything else ───────────────────────────
    _missing_deps = [t for t in REQUIRED_TOOLS if not shutil.which(t)]
    if _missing_deps:
        _pkg_map = {
            'btrfs':      'btrfs-progs',
            'ip':         'iproute2',
            'fzf':        'fzf',
            'tmux':       'tmux',
            'jq':         'jq',
            'sudo':       'sudo',
            'curl':       'curl',
            'cryptsetup': 'cryptsetup',
            'losetup':    'util-linux',
        }
        _apt_pkgs  = [_pkg_map.get(t, t) for t in _missing_deps]
        _pacman_pkgs = [('btrfs-progs' if t == 'btrfs' else ('iproute2' if t == 'ip' else t)) for t in _missing_deps]
        print(f'\n{BLD}── simpleDocker ──{NC}')
        print(f'\n{RED}  ✗  Missing required tools:{NC}\n')
        for t in _missing_deps:
            print(f'      {BLD}{t}{NC}  {DIM}→  {_pkg_map.get(t, t)}{NC}')
        print(f'\n{DIM}  Install with one of:{NC}\n')
        print(f'    {BLD}apt{NC}     sudo apt-get install {" ".join(_apt_pkgs)}')
        print(f'    {BLD}pacman{NC}  sudo pacman -S {" ".join(_pacman_pkgs)}')
        print(f'    {BLD}dnf{NC}     sudo dnf install {" ".join(_apt_pkgs)}')
        _missing_opt = {k: v for k,v in OPTIONAL_HOST_TOOLS.items() if not shutil.which(k)}
        if _missing_opt:
            print(f'\n{DIM}  Optional (features degrade gracefully if absent):{NC}')
            for tool, pkg in _missing_opt.items():
                print(f'      {DIM}{tool}{NC}  →  {pkg}')
        print()
        sys.exit(1)

    _check_btrfs_kernel()
    _init_g()

    # ── Bootstrap into tmux session ────────────────────────────────────────────
    _bootstrap_tmux()

    # ── Inside the simpleDocker tmux session from here ─────────────────────────
    os.system('stty -ixon 2>/dev/null || true')   # disable flow control (ctrl-s/ctrl-q)
    _tmux('bind-key','-n','C-\\','detach-client')  # ctrl-\ detaches inside tmux
    signal.signal(signal.SIGUSR1, _signal_handler)
    signal.signal(signal.SIGINT,  _quit_signal_handler)
    signal.signal(signal.SIGTERM, _quit_signal_handler)
    signal.signal(signal.SIGHUP,  _quit_signal_handler)
    signal.signal(signal.SIGQUIT, _quit_signal_handler)  # Ctrl+Q / Ctrl+\
    require_sudo()    # background keepalive

    # ubuntu cache check removed

    threading.Thread(target=sweep_stale).start()
    tmux_set('SD_READY', '1')
    try:
        setup_image()
    except Exception as _se:
        import traceback as _tb2
        _el = Path.home()/'.cache/simpleDocker/error.log'
        _el.parent.mkdir(parents=True, exist_ok=True)
        _el.write_text(_tb2.format_exc())
        pause(f'Error (logged to {_el}):\n\n{_se}')

if __name__ == '__main__':
    import traceback as _tb
    _errlog = Path.home() / '.cache/simpleDocker/error.log'
    _errlog.parent.mkdir(parents=True, exist_ok=True)
    try:
        _main()
    except KeyboardInterrupt:
        print(f'\n  {DIM}Bye.{NC}\n')
        sys.exit(0)
    except Exception as _e:
        _errlog.write_text(_tb.format_exc())
        print(f'\n{RED}✗  Crash logged to {_errlog}{NC}')
        sys.exit(1)
    main_menu()