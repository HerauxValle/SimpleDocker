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
DEFAULT_UBUNTU_PKGS = 'curl git wget ca-certificates zstd tar xz-utils python3 python3-venv python3-pip build-essential'
SD_DEFAULT_KEYWORD  = '1991316125415311518'
SD_LUKS_SLOT_MIN, SD_LUKS_SLOT_MAX = 7, 31
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
    try:
        r = _run(['sha256sum','/etc/machine-id'], capture=True)
        G.verification_cipher = r.stdout[:32] if r.returncode==0 else 'simpledocker_fallback'
    except: G.verification_cipher = 'simpledocker_fallback'

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

def tsess(cid: str) -> str: return f'sd_{cid}'
def inst_sess(cid: str) -> str: return f'sdInst_{cid}'
def cron_sess(cid: str, idx) -> str: return f'sdCron_{cid}_{idx}'

REQUIRED_TOOLS = ['jq','tmux','yazi','fzf','btrfs','sudo','curl','ip']

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
    t = threading.Thread(target=_keep, daemon=True); t.start()

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
    # Close any leftover LUKS mappers
    for mp in Path('/dev/mapper').glob('sd_*'):
        if mp.is_block_device():
            nm = mp.name
            r2 = _sudo('cryptsetup','status',nm, capture=True)
            lo = ''
            for line in r2.stdout.splitlines():
                if 'device:' in line:
                    lo = line.split()[-1]
            _sudo('cryptsetup','close',nm)
            if lo.startswith('/dev/loop'): _sudo('losetup','-d',lo)
    # Detach any leftover loop devices from simpleDocker images
    r = _run(['sudo','-n','losetup','-a'], capture=True)
    for line in r.stdout.splitlines():
        if 'simpleDocker' in line:
            lo = line.split(':')[0]; _sudo('losetup','-d',lo)
    # Recreate clean tmp dir — do NOT rmtree the whole sd_mnt_base (mount points live there)
    G.sd_mnt_base.mkdir(parents=True, exist_ok=True)
    G.tmp_dir.mkdir(parents=True, exist_ok=True)

def write_sudoers():
    """Prompt for sudo password (with retry loop like the shell), then write NOPASSWD rule."""
    me = os.popen('id -un').read().strip()
    cmds = ('/bin/mount,/bin/umount,/usr/bin/mount,/usr/bin/umount,'
            '/usr/bin/btrfs,/usr/sbin/btrfs,/bin/btrfs,/sbin/btrfs,'
            '/usr/bin/mkfs.btrfs,/sbin/mkfs.btrfs,/usr/bin/chown,/bin/chown,'
            '/bin/mkdir,/usr/bin/mkdir,/usr/bin/rm,/bin/rm,/usr/bin/chmod,'
            '/bin/chmod,/usr/bin/tee /etc/hosts,/usr/bin/nsenter,/usr/sbin/nsenter,'
            '/usr/bin/unshare,/usr/bin/chroot,/usr/sbin/chroot,/bin/bash,'
            '/usr/bin/bash,/usr/bin/ip,/bin/ip,/sbin/ip,/usr/sbin/ip,'
            '/usr/sbin/iptables,/usr/bin/iptables,/sbin/iptables,'
            '/usr/sbin/sysctl,/usr/bin/sysctl,/bin/cp,/usr/bin/cp,'
            '/usr/bin/apt-get,/usr/bin/apt,/usr/sbin/cryptsetup,'
            '/usr/bin/cryptsetup,/sbin/cryptsetup,/sbin/losetup,'
            '/usr/sbin/losetup,/bin/losetup,/sbin/blockdev,/usr/sbin/blockdev,'
            '/usr/bin/dmsetup,/usr/sbin/dmsetup,/usr/bin/rsync')
    rule = f'{me} ALL=(ALL) NOPASSWD: {cmds}\n'
    # Invalidate cached credentials, then prompt until success — mirrors shell _sd_outer_sudo
    subprocess.run(['sudo','-k'], capture_output=True)
    print(f'\n  {BLD}── simpleDocker ──{NC}')
    print(f'  {DIM}simpleDocker requires sudo access.{NC}\n')
    while subprocess.run(['sudo','-v']).returncode != 0:
        print(f'  {RED}Incorrect password.{NC} Try again.\n')
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
        cid = d.name; G.CT_IDS.append(cid); G.CT_NAMES.append(cname(cid))

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
    """Backup snapshots live in Backup/<cid>/ — matches .sh _snap_dir exactly."""
    return G.backup_dir/cid

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
    r = _run(args+[str(src),str(dst)])
    return r.returncode == 0

def btrfs_delete(path: Path):
    _run(['btrfs','property','set',str(path),'ro','false'], capture=True)
    if _run(['btrfs','subvolume','delete',str(path)]).returncode != 0:
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
    threading.Thread(target=_bg, daemon=True).start()

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
                import getpass
                pw = getpass.getpass('  Passphrase: ')
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
    r = _run(['sha256sum','/etc/machine-id'], capture=True)
    return r.stdout[:8] if r.returncode==0 else 'fallback0'
def enc_verified_pass() -> str: return G.verification_cipher

def enc_authkey_path() -> Path: return G.mnt_dir/'.sd/auth.key'
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
    """Create random 64-byte auth key, add to LUKS slot 0 using auth_kf as existing key."""
    kf = enc_authkey_path()
    kf.parent.mkdir(parents=True, exist_ok=True)
    with open(kf,'wb') as f: f.write(os.urandom(64))
    kf.chmod(0o600)
    r = subprocess.run(
        ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
         '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
         '--key-slot','0','--key-file',str(auth_kf),str(G.img_path),str(kf)],
        capture_output=True)
    if r.returncode == 0:
        enc_authkey_slot_file().write_text('0')
    return r.returncode == 0

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
    # Seed persistent blueprints on first mount (§2.10)
    _seed_persistent_blueprints()

_SD_PERSISTENT_BLUEPRINTS = {
    'Counter': '''\
[container]
[meta]
name = counter-test
version = 2.0.0
port = 8833
dialogue = Feature test
storage_type = counter-test
health = true
log = logs/counter.log

[dirs]
logs

[install]
for i in $(seq 1 10); do
  printf '%d\\n' "$i"
  sleep 0.2
done
printf 'Install done.\\n'

[start]
mkdir -p "$CONTAINER_ROOT/logs"
n=1
while true; do
  printf '[%s] tick %d\\n' "$(date '+%H:%M:%S')" "$n" | tee -a "$CONTAINER_ROOT/logs/counter.log"
  (( n++ ))
  sleep 1
done

[actions]
Reset log | printf '' > "$CONTAINER_ROOT/logs/counter.log" && printf 'Log cleared.\\n'
Show log tail | tail -20 "$CONTAINER_ROOT/logs/counter.log"

[cron]
10s [ping] | printf '[cron] ping at %s\\n' "$(date '+%H:%M:%S')" >> logs/counter.log
1m [minutely] | printf '[cron] 1min heartbeat\\n' >> logs/counter.log

[/container]
''',
}

def _seed_persistent_blueprints():
    """Write built-in blueprints to .sd/persistent_blueprints/, always overwriting so
    any update to _SD_PERSISTENT_BLUEPRINTS is immediately reflected on disk.
    Matches shell behaviour: persistent BPs are embedded in the script and always
    current — they never go stale."""
    if not G.mnt_dir: return
    pd = G.mnt_dir/'.sd/persistent_blueprints'
    pd.mkdir(parents=True, exist_ok=True)
    for name, content in _SD_PERSISTENT_BLUEPRINTS.items():
        dest = pd/f'{name}.container'
        dest.write_text(content)  # always overwrite — keeps disk in sync with dict

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
        lo_r = _run(['sudo','-n','losetup','-j',str(img)], capture=True)
        lo = lo_r.stdout.split(':')[0].strip() if lo_r.returncode==0 and lo_r.stdout.strip() else ''
        if lo:
            r = _sudo('mount','-o','compress=zstd',lo,str(mnt))
        else:
            r = _sudo('mount','-o','loop,compress=zstd',str(img),str(mnt))
    if r.returncode != 0:
        if img_is_luks(img): luks_close(img)
        try: mnt.rmdir()
        except: pass
        pause(f'Mount failed for {img.name}.\nIs it a valid BTRFS image? Check with: sudo mount -o loop {img}')
        return False
    _sudo('chown',f'{os.getuid()}:{os.getgid()}',str(mnt))
    G.img_path = img; G.mnt_dir = mnt
    G.tmp_dir = mnt/'.tmp'
    G.tmp_dir.mkdir(parents=True, exist_ok=True)
    (mnt/'.sd').mkdir(exist_ok=True)
    set_img_dirs()
    # Clear stale log files on mount — matches shell _mount_img
    if G.logs_dir and G.logs_dir.is_dir():
        for lf in G.logs_dir.glob('*.log'):
            try: lf.unlink()
            except: pass
    netns_setup(mnt)
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
    # Unmount submounts deepest first
    r = _run(['findmnt','-n','-o','TARGET','-R',str(G.mnt_dir)], capture=True)
    submounts = sorted([l for l in r.stdout.splitlines()
                        if l.strip() and l.strip() != str(G.mnt_dir)], key=len, reverse=True)
    for sm in submounts: _sudo('umount','-lf',sm)
    # Find loop device before unmounting
    lo = ''
    if G.img_path:
        lo_r = _run(['sudo','-n','losetup','-j',str(G.img_path)], capture=True)
        lo = lo_r.stdout.split(':')[0].strip() if lo_r.returncode==0 and lo_r.stdout.strip() else ''
    if not lo:
        fm = _run(['findmnt','-n','-o','SOURCE',str(G.mnt_dir)], capture=True)
        s = fm.stdout.strip()
        if s.startswith('/dev/loop'): lo = s
    _sudo('umount','-lf',str(G.mnt_dir))
    try: G.mnt_dir.rmdir()
    except: pass
    # Close LUKS
    if G.img_path:
        lm = luks_mapper(G.img_path)
        lo_r2 = _run(['sudo','-n','losetup','-j',str(G.img_path)], capture=True)
        for line in lo_r2.stdout.splitlines():
            l = line.split(':')[0].strip()
            dm_r = _run(['sudo','-n','dmsetup','ls','--target','crypt'], capture=True)
            for dml in dm_r.stdout.splitlines():
                if l in dml: _sudo('cryptsetup','close',dml.split()[0])
        if Path(f'/dev/mapper/{lm}').is_block_device(): _sudo('cryptsetup','close',lm)
    # Detach loop devices
    if G.img_path:
        lo_r3 = _run(['sudo','-n','losetup','-j',str(G.img_path)], capture=True)
        for line in lo_r3.stdout.splitlines():
            l = line.split(':')[0].strip()
            if l: _sudo('losetup','-d',l)
    if lo: _sudo('losetup','-d',lo)
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
    _sudo('chown',f'{os.getuid()}:{os.getgid()}',str(mnt))
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
         '--key-file',str(enc_authkey_path()),str(img),'31'],
        capture_output=True)
    auth_tmp.unlink(missing_ok=True)
    # 3. Add default keyword → slot 1
    dk_auth = G.tmp_dir/'.sd_dk_auth'; dk_new = G.tmp_dir/'.sd_dk_new'
    import shutil as _shutil
    _shutil.copy(str(enc_authkey_path()), str(dk_auth))
    dk_new.write_text(SD_DEFAULT_KEYWORD)
    subprocess.run(
        ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
         '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
         '--key-slot','1','--key-file',str(dk_auth),str(img),str(dk_new)],
        capture_output=True)
    dk_auth.unlink(missing_ok=True); dk_new.unlink(missing_ok=True)
    # 4. Add verified-system key → free slot
    free_slot = enc_free_slot()
    if free_slot:
        vs_auth = G.tmp_dir/'.sd_vs_auth'; vs_new = G.tmp_dir/'.sd_vs_new'
        _shutil.copy(str(enc_authkey_path()), str(vs_auth))
        vs_new.write_text(G.verification_cipher)
        r = subprocess.run(
            ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
             '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
             '--key-slot',free_slot,'--key-file',str(vs_auth),str(img),str(vs_new)],
            capture_output=True)
        if r.returncode == 0:
            enc_vs_write(enc_verified_id(), free_slot)
        vs_auth.unlink(missing_ok=True); vs_new.unlink(missing_ok=True)
    # ── BTRFS subvolumes ───────────────────────────────────────────────────
    for sv in ['Blueprints','Containers','Installations','Backup','Storage','Ubuntu','Groups']:
        _sudo('btrfs','subvolume','create',str(mnt/sv), capture=True)  # suppress "Create subvolume" stdout
    set_img_dirs()
    netns_setup(mnt)
    save_known_img(img)
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
    """Find .img files under $HOME (maxdepth 4) that are BTRFS or LUKS — matches shell exactly."""
    found: List[Path] = []
    seen: set = set()
    r = _run(['find', str(Path.home()), '-maxdepth', '4', '-name', '*.img', '-type', 'f'], capture=True)
    for line in r.stdout.splitlines():
        p = Path(line.strip())
        if not p.exists() or str(p) in seen: continue
        # Check btrfs or luks — same as shell: `file` grep BTRFS or cryptsetup isLuks
        is_btrfs = 'BTRFS' in _run(['file', str(p)], capture=True).stdout
        is_luks  = img_is_luks(p)
        if is_btrfs or is_luks:
            found.append(p); seen.add(str(p))
    return found

def pick_dir() -> Optional[Path]:
    tmp = tempfile.mktemp(dir=str(G.tmp_dir))
    subprocess.run(['yazi','--chooser-file',tmp])
    p = Path(tmp)
    if not p.exists(): return None
    line = p.read_text().strip(); p.unlink(missing_ok=True)
    if not line or not Path(line).is_dir(): return None
    return Path(line)

def pick_file() -> Optional[Path]:
    tmp = tempfile.mktemp(dir=str(G.tmp_dir))
    subprocess.run(['yazi','--chooser-file',tmp])
    p = Path(tmp)
    if not p.exists(): return None
    line = p.read_text().strip(); p.unlink(missing_ok=True)
    return Path(line) if line else None

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
            v = finput(f'Image name (e.g. simpleDocker):\n\n  {RED}⚠  WARNING:{NC}  The name cannot be changed after creation.')
            if not v: continue
            name = re.sub(r'[^a-zA-Z0-9_\-]', '', v)
            if not name: pause('No name given.'); continue
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
    _sudo('ip','link','del',f'sd-h{idx}')
    _sudo('ip','netns','del',ns)
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
    for line in text.splitlines():
        stripped = line.rstrip()
        # section header
        m = re.match(r'^\[([a-zA-Z_/]+)\]$', stripped)
        if m:
            sec = m.group(1).lower()
            continue
        if sec is None: continue
        if stripped.startswith('#') and sec not in _CODE_SECS: continue
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
                # type coerce
                if v.lower()=='true': v=True
                elif v.lower()=='false': v=False
                elif v.isdigit(): v=int(v)
                out['meta'][k] = v
        elif sec == 'git':
            if stripped and not stripped.startswith('#'):
                out['git'].append(_parse_git_line(stripped))
        elif sec == 'cron':
            c = _parse_cron_line(stripped)
            if c: out['crons'].append(c)
        elif sec == 'actions':
            a = _parse_action_line(stripped)
            if a: out['actions'].append(a)
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

def _parse_cron_line(line: str) -> Optional[dict]:
    if not line or line.startswith('#'): return None
    if '|' not in line: return None
    head, _, cmd = line.partition('|')
    head=head.strip(); cmd=cmd.strip()
    m = re.match(r'^(\d+[smhdw]|mo)\s*(?:\[([^\]]+)\])?\s*(.*)',head)
    if not m: return None
    interval,name,flags = m.group(1),m.group(2) or '',m.group(3).strip()
    sudo = '--sudo' in flags; unjailed = '--unjailed' in flags
    return {'interval':interval,'name':name,'command':cmd,'sudo':sudo,'unjailed':unjailed}

def _parse_action_line(line: str) -> Optional[dict]:
    if not line or line.startswith('#'): return None
    if '|' not in line: return None
    label, _, dsl = line.partition('|')
    label=label.strip(); dsl=dsl.strip()
    if not label: return None
    if re.match(r'^[a-zA-Z0-9]',label): label='⊙  '+label
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
    return '''\
[container]

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
# $CONTAINER_ROOT is always available and points to the install path

[cron]
# interval [name] [--sudo] [--unjailed] | command
# interval: [N][s|m|h] e.g. 30s, 5m, 1h
# --unjailed: run on host instead of inside container
# --sudo: wrap command with sudo
# 5m [heartbeat] | printf '[cron] ping\n' >> logs/cron.log

[actions]
# One action per line: Label | [prompt: "text" |] [select: cmd [--skip-header] [--col N] |] cmd [{input}|{selection}]
# ⊙ auto-prepended if label starts with a plain letter
Show logs | tail -f logs/service.log

[/container]
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

def start_ct(cid: str, mode='background', profile_cid: str=''):
    if tmux_up(tsess(cid)): return
    netns_setup(); netns_ct_add(cid, cname(cid))
    exposure_apply(cid)
    start_sh = cpath(cid)/'start.sh' if cpath(cid) else None
    if not start_sh or not start_sh.exists():
        build_start_script(cid)
    sess = tsess(cid)
    lf = log_path(cid, 'start')
    if G.logs_dir:
        G.logs_dir.mkdir(parents=True, exist_ok=True)
    log_write(cid, 'start', f'── started {time.strftime("%Y-%m-%d %H:%M:%S")} ──')
    _tmux('new-session','-d','-s',sess,
          f'bash -o pipefail {start_sh!s} 2>&1 | tee -a {str(lf)!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    # start cron jobs
    d=sj(cid)
    for i,cr in enumerate(d.get('crons',[])):
        _cron_start_one(cid,i,cr)
    if mode=='attach':
        if os.environ.get('TMUX'):
            _tmux('new-window', '-t', 'simpleDocker', f'tmux attach-session -t {sess}')
        else:
            _tmux('switch-client','-t',sess)

def stop_ct(cid: str):
    sess=tsess(cid)
    if tmux_up(sess):
        _tmux('send-keys','-t',sess,'C-c','')
        time.sleep(0.3)
        _tmux('kill-session','-t',sess)
    # kill cron sessions
    r=_tmux('list-sessions','-F','#{session_name}', capture=True)
    for s in (r.stdout.splitlines() if r.returncode==0 else []):
        if s.startswith(f'sdCron_{cid}_'): _tmux('kill-session','-t',s)
    netns_ct_del(cid, cname(cid))

def _cron_interval_secs(iv: str) -> int:
    m=re.match(r'^(\d+)(s|m|h|d|w|mo)$',iv)
    if not m: return 3600
    n,u=int(m.group(1)),m.group(2)
    return n*{'s':1,'m':60,'h':3600,'d':86400,'w':604800,'mo':2592000}[u]

def _cron_start_one(cid: str, idx: int, cr: dict):
    sname=cron_sess(cid,idx); ip=cpath(cid)
    secs=_cron_interval_secs(cr.get('interval','5m'))
    cmd=cr.get('command',''); name=cr.get('name',f'cron_{idx}')
    unjailed=cr.get('unjailed',False); use_sudo=cr.get('sudo',False)
    ns=netns_name(); ub=str(G.ubuntu_dir)
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_cron_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(f'_secs={secs}\n')
        if unjailed:
            f.write(f'export CONTAINER_ROOT={ip!r}\n')
            f.write('while true; do\n')
            f.write(f'    sleep "$_secs"\n')
            f.write(f'    printf "\\n\\033[1m── Cron: {name} ──\\033[0m\\n"\n')
            f.write(f'    (eval {cmd!r})\n')
            f.write('done\n')
        else:
            f.write('while true; do\n')
            f.write(f'    sleep "$_secs"\n')
            f.write(f'    printf "\\n\\033[1m── Cron: {name} ──\\033[0m\\n"\n')
            inner=cmd.replace('$CONTAINER_ROOT','/mnt')
            f.write(f'    sudo -n nsenter --net=/run/netns/{ns} -- unshare --mount --pid --uts --ipc --fork bash -s << \'_SDCRON\'\n')
            f.write(f'_cb(){{ local r=$1; shift; local b=/bin/bash; [[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "${{@}}"; }}\n')
            f.write(f'mount --bind {ip} {ub}/mnt 2>/dev/null||true\n')
            f.write(f'_cb {ub} -c "cd /mnt && {inner}"\n')
            f.write('_SDCRON\n')
            f.write('done\n')
    os.chmod(runner.name, 0o755)
    _tmux('new-session','-d','-s',sname,f'bash {runner.name}; rm -f {runner.name}')
    _tmux('set-option','-t',sname,'detach-on-destroy','off')

def _cr_prefix(val: str) -> str:
    """Prefix relative paths with $CONTAINER_ROOT — matches shell _cr_prefix exactly.
    A value is relative if it doesn't start with /, $, ~, or a variable reference."""
    if not val: return val
    if val.startswith(('/', '$', '~', '"', "'")): return val
    # Looks like a relative path (no leading slash/sigil)
    return f'$CONTAINER_ROOT/{val}'

def _env_exports(cid: str, install_path: Path) -> str:
    d=sj(cid); ip=str(install_path)
    lines=[f'export CONTAINER_ROOT={ip!r}']
    lines+=['export HOME="$CONTAINER_ROOT"',
            'export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"',
            'export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"',
            'export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"',
            'export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"',
            'export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/python/bin:$CONTAINER_ROOT/.local/bin:$CONTAINER_ROOT/bin:$PATH"',
            'export PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV="$CONTAINER_ROOT/venv"',
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
            pv='$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret")'
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
    exec_cmd=_cr_prefix(ep) if ep else start_block
    hostname=re.sub(r'[^a-z0-9\-]','-',cname(cid).lower())[:63]
    sh=ip/'start.sh'
    with open(sh,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(_env_exports(cid,ip))
        f.write(f'sudo -n nsenter --net=/run/netns/{ns} -- '
                f'unshare --mount --pid --uts --ipc --fork bash -s << \'_SDNS_WRAP\'\n')
        f.write('_chroot_bash(){ local r=$1; shift; local b=/bin/bash; [[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n')
        f.write(f'printf "%s" {hostname!r} > /proc/sys/kernel/hostname 2>/dev/null||true\n')
        f.write(f'mount -t proc proc {ip}/proc 2>/dev/null||true\n')
        f.write(f'mount --bind /sys  {ip}/sys  2>/dev/null||true\n')
        f.write(f'mount --bind /dev  {ip}/dev  2>/dev/null||true\n')
        nhf=netns_hosts(); 
        f.write(f'[[ -f {nhf!r} ]] && mount --bind {nhf!r} {ip}/etc/hosts 2>/dev/null||true\n')
        f.write(f'_chroot_bash {ip!r} -c {exec_cmd!r}\n')
        f.write('_SDNS_WRAP\n')
    os.chmod(sh, 0o755)

def _gen_install_script(cid: str, mode: str) -> str:
    """Generate the bash install/update script content."""
    d=sj(cid); ip=str(cpath(cid))
    ub=str(G.ubuntu_dir); ok_f=str(G.containers_dir/cid/'.install_ok')
    fail_f=str(G.containers_dir/cid/'.install_fail')
    lines=['#!/usr/bin/env bash','set -e']
    lines+=[f'_ok={ok_f!r}', f'_fail={fail_f!r}',
            '_finish(){ local c=$?; [[ $c -eq 0 ]] && touch "$_ok" || touch "$_fail"; }',
            'trap _finish EXIT', f'trap \'touch "$_fail"; exit 130\' INT TERM',
            '_chroot_bash(){ local r=$1; shift; local b=/bin/bash; '
            '[[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; '
            'sudo -n chroot "$r" "$b" "$@"; }',
            f'_SD_INSTALL={ip!r}', f'_UB={ub!r}',
            '_mnt(){ sudo -n mount --bind /proc "$_UB/proc"; sudo -n mount --bind /sys "$_UB/sys"; sudo -n mount --bind /dev "$_UB/dev"; }',
            '_umnt(){ sudo -n umount -lf "$_UB/dev" "$_UB/sys" "$_UB/proc" 2>/dev/null||true; }',
            '']
    # Create install dir (btrfs subvolume or mkdir)
    if mode=='install':
        lines+=[f'sudo -n btrfs subvolume create {ip!r} 2>/dev/null || mkdir -p {ip!r}',
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
            f'  printf "\\033[1m[ubuntu] Base not found — installing...\\033[0m\\n"',
            f'  _sd_ub_arch=$(uname -m); [[ "$_sd_ub_arch"==x86_64 ]]&&_sd_ub_arch=amd64||true',
            f'  _sd_ub_arch=$([[ "$_sd_ub_arch"==aarch64 ]]&&echo arm64||echo "$_sd_ub_arch")',
            f'  _base="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"',
            f'  _ver=$(curl -fsSL "$_base" 2>/dev/null|grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${{_sd_ub_arch}}"|head -1)',
            f'  [[ -z "$_ver" ]]&&_ver="24.04.3-base-${{_sd_ub_arch}}"',
            f'  _tmp=$(mktemp /tmp/.sd_ub_dl_XXXXXX.tar.gz)',
            f'  mkdir -p {ub!r}',
            f'  curl -fsSL --progress-bar "${{_base}}ubuntu-base-${{_ver}}.tar.gz" -o "$_tmp"',
            f'  tar -xzf "$_tmp" -C {ub!r} 2>&1||true; rm -f "$_tmp"',
            f'  [[ ! -e {ub!r}/bin ]]&&ln -sf usr/bin {ub!r}/bin 2>/dev/null||true',
            f'  [[ ! -e {ub!r}/lib ]]&&ln -sf usr/lib {ub!r}/lib 2>/dev/null||true',
            f'  printf "nameserver 8.8.8.8\\n" > {ub!r}/etc/resolv.conf',
            f'  printf "APT::Sandbox::User \\"root\\";\\n" > {ub!r}/etc/apt/apt.conf.d/99sandbox',
            f'  _mnt',
            f'  _chroot_bash {ub!r} -c "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {DEFAULT_UBUNTU_PKGS}"',
            f'  _umnt',
            f'  touch {ub!r}/.ubuntu_ready',
            f'  date +%Y-%m-%d > {ub!r}/.sd_ubuntu_stamp',
            f'fi','']
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
        lines+=[f'printf "\\033[1m[pip] Installing: {pkg_str}\\033[0m\\n"',
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
    # git
    for g in d.get('git',[]):
        repo=g.get('repo',''); dest=g.get('dest','.') or '.'; hint=g.get('hint',''); src=g.get('source',False)
        dest_path=f'{ip!r}/{dest}' if dest!='.' else ip
        if src:
            lines+=[f'printf "Cloning {repo}...\\n"',
                    f'git clone --depth=1 https://github.com/{repo}.git {dest_path}','']
        else:
            lines+=[f'printf "Fetching {repo}...\\n"',
                    f'_sd_arch=$(uname -m); [[ "$_sd_arch"==x86_64 ]]&&_sd_arch=amd64||true',
                    f'_sd_arch=$([[ "$_sd_arch"==aarch64 ]]&&echo arm64||echo "$_sd_arch")',
                    f'_sd_rel=$(curl -fsSL "https://api.github.com/repos/{repo}/releases/latest" 2>/dev/null)',
                    f'_sd_url=$(printf "%s" "$_sd_rel"|grep -o \'"browser_download_url":"[^"]*"\''
                    r'|grep -io "https://[^\"]*$_sd_arch[^\"]*\.\(tar\.\(gz\|zst\|xz\)\|zip\)" | head -1)',
                    f'[[ -z "$_sd_url" ]]&&_sd_url=$(printf "%s" "$_sd_rel"|grep -o \'"tarball_url":"[^"]*"\'|grep -o "https://[^\"]*"|head -1)',
                    f'_sd_tmp=$(mktemp /tmp/.sd_gh_XXXXXX)',
                    f'curl -fL --progress-bar --retry 3 -C - "$_sd_url" -o "$_sd_tmp"',
                    f'mkdir -p {dest_path!r}',
                    f'if [[ "$_sd_url" =~ \\.(tar\\.(gz|bz2|xz|zst)|tgz)$ ]]; then',
                    f'  tar -xa -C {dest_path!r} --strip-components=1 -f "$_sd_tmp" 2>/dev/null||tar -xa -C {dest_path!r} -f "$_sd_tmp"',
                    f'elif [[ "$_sd_url" =~ \\.zip$ ]]; then unzip -o -d {dest_path!r} "$_sd_tmp"',
                    f'else mkdir -p {dest_path!r}/bin; mv "$_sd_tmp" {dest_path!r}/bin/$(basename "$_sd_url"); chmod +x {dest_path!r}/bin/*; fi',
                    'rm -f "$_sd_tmp"','']
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
                '#!/bin/bash','set -e','cd /',
                script,
                '_SD_RUN_EOF',
                'chmod +x "$_sd_run"',
                f'_chroot_bash {ip!r} bash /tmp/$(basename "$_sd_run")',
                f'sudo -n umount -lf {ip!r}/dev {ip!r}/sys {ip!r}/proc 2>/dev/null||true',
                'rm -f "$_sd_run"','']
    return '\n'.join(lines)

def write_pkg_manifest(cid: str):
    d=sj(cid)
    m={'deps':d.get('deps',[]),'pip':d.get('pip',[]),'npm':d.get('npm',[]),
       'git':[g.get('repo','') for g in d.get('git',[])],'updated':time.strftime('%Y-%m-%d %H:%M')}
    (G.containers_dir/cid/'pkg_manifest.json').write_text(json.dumps(m,indent=2))

def run_job(cid: str, mode='install', force=False):
    """Launch install/update in a tmux session, capturing output to Logs/."""
    compile_service(cid)
    ip=cpath(cid)
    if not ip: pause('No install path set.'); return
    ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    script_content=_gen_install_script(cid,mode)
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_inst_')
    runner.write(script_content); runner.close(); os.chmod(runner.name,0o755)
    sess=inst_sess(cid)
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    # Capture output to the Logs directory
    lf = log_path(cid, mode)
    if G.logs_dir:
        G.logs_dir.mkdir(parents=True, exist_ok=True)
    log_write(cid, mode,
              f'── {mode} started {time.strftime("%Y-%m-%d %H:%M:%S")} ──')
    _tmux('new-session','-d','-s',sess,
          f'bash -o pipefail {runner.name!r} 2>&1 | tee -a {str(lf)!r}; rm -f {runner.name!r}; '
          f'tmux kill-session -t {sess} 2>/dev/null||true')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')

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
    if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists(): return
    drift_f=G.sd_mnt_base/'.tmp'/f'.sd_ub_drift_{os.getpid()}'
    upd_f=G.sd_mnt_base/'.tmp'/f'.sd_ub_upd_{os.getpid()}'
    saved=G.ubuntu_dir/'.ubuntu_default_pkgs'
    cur=sorted(DEFAULT_UBUNTU_PKGS.split())
    drift=(sorted(saved.read_text().splitlines()) != cur) if saved.exists() else True
    drift_f.write_text('true' if drift else 'false')
    stamp=G.ubuntu_dir/'.sd_last_apt_update'
    last=int(stamp.read_text().strip()) if stamp.exists() else 0
    if time.time()-last > 86400:
        r=_run(['sudo','-n','chroot',str(G.ubuntu_dir),'bash','-c',
                'apt-get update -qq 2>/dev/null; apt-get --simulate upgrade 2>/dev/null | grep -c "^Inst "'],
               capture=True)
        has_upd=(r.stdout.strip()!='0') if r.returncode==0 else False
        upd_f.write_text('true' if has_upd else 'false')
        stamp.write_text(str(int(time.time())))
    else: upd_f.write_text('false')

def ub_cache_read():
    if G.ub_cache_loaded: return
    G.ub_cache_loaded=True
    for f,attr in [(G.sd_mnt_base/'.tmp'/f'.sd_ub_drift_{os.getpid()}','ub_pkg_drift'),
                   (G.sd_mnt_base/'.tmp'/f'.sd_ub_upd_{os.getpid()}','ub_has_updates')]:
        i=0
        while not f.exists() and i<30: time.sleep(0.1); i+=1
        setattr(G,attr,(f.read_text().strip()=='true') if f.exists() else False)
        f.unlink(missing_ok=True)

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
        if os.environ.get('TMUX'):
            _tmux('new-window','-t','simpleDocker','tmux attach-session -t sdUbuntuPkg')
        else:
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
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_ubpkg_')
    runner.write(
        f'#!/bin/bash\nset -e\n'
        f'_chroot_bash(){{ local r=$1; shift; local b=/bin/bash; [[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }}\n'
        f'_cleanup(){{ local rc=$?; sudo -n umount -lf {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||true;'
        f' sudo -n umount -lf {G.ubuntu_dir}/dev {G.ubuntu_dir}/sys {G.ubuntu_dir}/proc 2>/dev/null||true;'
        f' [[ $rc -ne 0 ]] && touch {fail_f!r} || true; tmux kill-session -t {sess} 2>/dev/null||true; }}\n'
        f'trap _cleanup EXIT\n'
        f'sudo -n mount --bind /proc {G.ubuntu_dir}/proc\n'
        f'sudo -n mount --bind /sys {G.ubuntu_dir}/sys\n'
        f'sudo -n mount --bind /dev {G.ubuntu_dir}/dev\n'
        f'_sd_apt=$(mktemp /tmp/.sd_apt_XXXXXX.sh)\n'
        f'printf \'#!/bin/sh\\nset -e\\n{apt_cmd}\\n\' > "$_sd_apt"\n'
        f'chmod +x "$_sd_apt"\n'
        f'sudo -n mount --bind "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||'
        f'cp "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh\n'
        f'_chroot_bash {G.ubuntu_dir!r} bash /tmp/.sd_apt.sh\n'
        f'sudo -n umount -lf {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||true\n'
        f'rm -f "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||true\n'
        f'touch {ok_f!r}\n'
    )
    runner.close(); os.chmod(runner.name,0o755)
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    _installing_wait_loop(sess, str(ok_f), str(fail_f), title)
    G.ub_cache_loaded=False
    if fail_f.exists():
        pause(f'✗ {title} failed. Select "Attach" to see output.')
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)

def _installing_wait_loop(sess: str, ok_f: str, fail_f: str, title: str):
    """Show fzf menu with attach option; auto-close when session ends or ok/fail file appears.
    Uses a tmp sentinel file when ok_f/fail_f are /dev/null (e.g. Caddy install)."""
    # If caller passed /dev/null we can't use it as a sentinel — watch for session exit instead
    use_sess_exit = (ok_f == '/dev/null' and fail_f == '/dev/null')

    items = [f'{DIM}→  Attach to {title}{NC}', _nav_sep(), _back_item()]
    while True:
        done_evt = threading.Event()

        def _watch(evt=done_evt):
            if use_sess_exit:
                # Poll until tmux session disappears
                while tmux_up(sess): time.sleep(0.3)
                evt.set()
            else:
                while not Path(ok_f).exists() and not Path(fail_f).exists():
                    if not tmux_up(sess): break   # session died unexpectedly
                    time.sleep(0.3)
                evt.set()

        wt = threading.Thread(target=_watch, daemon=True); wt.start()
        proc = subprocess.Popen(
            ['fzf'] + FZF_BASE + [f'--header={BLD}── {title} ──{NC}'],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        G.active_fzf_pid = proc.pid
        proc.stdin.write(('\n'.join(items)+'\n').encode()); proc.stdin.close()

        def _kill_when_done(p=proc, evt=done_evt):
            evt.wait()
            try: p.kill()
            except: pass
        kt = threading.Thread(target=_kill_when_done, daemon=True); kt.start()

        out, _ = proc.communicate()
        G.active_fzf_pid = None
        if done_evt.is_set(): return   # auto-advanced when install finished

        sel = out.decode().strip()
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if 'Attach' in sel and tmux_up(sess):
            if os.environ.get('TMUX'):
                _tmux('new-window', '-t', 'simpleDocker', f'tmux attach-session -t {sess}')
            else:
                _tmux('switch-client', '-t', sess)
            continue  # stay in wait loop — user may detach and come back

# ══════════════════════════════════════════════════════════════════════════════
# services/caddy.py — reverse proxy
# ══════════════════════════════════════════════════════════════════════════════

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
                                         '--key-file',str(enc_authkey_path()),str(G.img_path),'1'],
                                        capture_output=True).returncode
                else:
                    import tempfile as _tf2
                    _dk_f = _tf2.mktemp(dir=str(G.tmp_dir))
                    try:
                        open(_dk_f,'w').write(SD_DEFAULT_KEYWORD)
                        rc = subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                             '--key-file',_dk_f,str(G.img_path),'1'],
                                            capture_output=True).returncode
                    finally:
                        try: Path(_dk_f).unlink(missing_ok=True)
                        except: pass
                pause('System Agnostic disabled.' if rc==0 else 'Failed.')
            else:
                if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth Token first.'); continue
                rc = subprocess.run(
                    ['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                     '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                     '--key-slot','1','--key-file',str(enc_authkey_path()),str(G.img_path)],
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
                         '--key-file',str(enc_authkey_path()),str(G.img_path),sl],
                        capture_output=True).returncode
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
                         '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
                        input=vspass.encode(), capture_output=True).returncode
                    if rc == 0:
                        enc_vs_write(vsid, free); count += 1
                    else: ok = False
                if ok: pause(f'Auto-Unlock enabled ({count} system(s) restored).')
                else: pause('Partially failed.')

        # ── Reset Auth Token ─────────────────────────────────────────────────
        elif 'Reset Auth Token' in sc:
            import getpass as _gp
            os.system('clear')
            print(f'\n  {BLD}── Reset Auth Token ──{NC}\n')
            pw = _gp.getpass('  Passphrase to authorise reset: ')
            if not pw: os.system('clear'); continue
            os.system('clear')
            print(f'\n  {BLD}── Reset Auth Token ──{NC}\n  {DIM}Generating new keyfile…{NC}\n')
            # Kill old slot 0 first — but only if auth.key file exists AND is
            # currently a valid key (--test-passphrase). Matches shell:
            #   [[ -f "$_old_kf" ]] && sudo cryptsetup open --test-passphrase --key-file "$_old_kf" ...
            old_kf = enc_authkey_path()
            if old_kf.exists():
                _test = subprocess.run(
                    ['sudo','-n','cryptsetup','open','--test-passphrase',
                     '--key-file',str(old_kf),str(G.img_path)],
                    capture_output=True)
                if _test.returncode == 0:
                    # Auth.key is valid — use the user-provided passphrase to authorise kill
                    subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                    '--key-file=-',str(G.img_path),'0'],
                                   input=pw.encode(), capture_output=True)
                old_kf.unlink(missing_ok=True)
            # Create new auth key using the provided passphrase as authorisation
            tf = Path(tempfile.mktemp(dir=str(G.tmp_dir)))
            tf.write_bytes(pw.encode())
            try:
                ok = enc_authkey_create(tf)
            finally:
                tf.unlink(missing_ok=True)
            os.system('clear')
            pause('Auth token reset successfully.' if ok else 'Failed — wrong passphrase?')

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
                     '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
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
        elif '+ Add Key' in sc:
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
            import getpass as _gp
            os.system('clear')
            print(f'\n  {BLD}── Add Key: {kname} ──{NC}\n')
            pw = _gp.getpass(f'  Passphrase for "{kname}": ')
            if not pw: os.system('clear'); continue
            pw2 = _gp.getpass(f'  Confirm passphrase for "{kname}": ')
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
                 '--key-file',str(enc_authkey_path()),str(G.img_path)],
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
                         '--key-file',str(enc_authkey_path()),str(G.img_path),sl],
                        capture_output=True).returncode
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
                     '--key-file',str(enc_authkey_path()),str(G.img_path),sl],
                    capture_output=True).returncode
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
    d=G.storage_dir/cid if G.storage_dir else None
    return len(list(d.iterdir())) if d and d.is_dir() else 0

def _pick_storage_profile(cid: str) -> Optional[str]:
    d=G.storage_dir/cid
    if not d.is_dir(): return None
    profiles=sorted(d.iterdir())
    items=[f' {DIM}◈{NC}  {p.name}' for p in profiles]+[_nav_sep(),_back_item()]
    sel=fzf_run(items,header=f'{BLD}── Select Profile — {cname(cid)} ──{NC}')
    if not sel or clean(sel)==L['back']: return None
    return clean(sel).lstrip('◈').strip()

def persistent_storage_menu(cid: str=''):
    """Global (cid='') or per-container persistent storage menu."""
    while True:
        if not cid:
            # global: list containers with storage
            load_containers()
            items=[_sep('Containers')]
            ct_with_stor=[(c,cname(c)) for c in G.CT_IDS if _stor_count(c)>0]
            for c,n in ct_with_stor:
                items.append(f' {DIM}◈  {n}{NC}')
            if not ct_with_stor: items.append(f'{DIM}  (no persistent storage yet){NC}')
            items+=[_nav_sep(),_back_item()]
            sel=fzf_run(items,header=f'{BLD}── Profiles & data ──{NC}')
            if not sel or clean(sel)==L['back']:
                if G.usr1_fired: G.usr1_fired = False; continue
                return
            sc=clean(sel)
            for c,n in ct_with_stor:
                if n in sc: persistent_storage_menu(c); break
            continue
        # per-container
        d=G.storage_dir/cid if G.storage_dir else None
        profiles=sorted(d.iterdir()) if d and d.is_dir() else []
        load_containers()
        installed = st(cid,'installed',False)
        running   = tmux_up(tsess(cid))
        items=[_sep('Storage profiles')]
        for p in profiles:
            try: sz=_run(['du','-sh',str(p)],capture=True).stdout.split()[0]
            except: sz='?'
            # Status: running = container is up (profile likely in use), stale = container gone/uninstalled
            if running:
                status = f'  {GRN}[running]{NC}'
            elif not installed:
                status = f'  {DIM}[stale]{NC}'
            else:
                status = f'  {DIM}[free]{NC}'
            items.append(f' {DIM}◈{NC}  {p.name}  {DIM}({sz}){NC}{status}')
        if not profiles: items.append(f'{DIM}  (no profiles yet){NC}')
        items.append(f' {GRN}+  New profile{NC}')
        items.append(f' {DIM}⊕  Import profile{NC}')
        items+=[_nav_sep(),_back_item()]
        sel=fzf_run(items,header=f'{BLD}── Profiles — {cname(cid)} ──{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if 'New profile' in sc:
            v=finput('Profile name:')
            if not v: continue
            pname=re.sub(r'[^a-zA-Z0-9_\-]','',v)
            if not pname: continue
            pd=(G.storage_dir/cid/pname); pd.mkdir(parents=True,exist_ok=True)
            _run(['btrfs','subvolume','create',str(pd)],capture=True)
            pause(f"Profile '{pname}' created.")
        elif 'Import profile' in sc:
            _stor_import(cid)
        else:
            # find which profile
            for p in profiles:
                if p.name in sc:
                    _profile_submenu(cid, p); break

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
            v = finput(f"New name for '{profile.name}':")
            if not v: continue
            nn = re.sub(r'[^a-zA-Z0-9_\-]','',v)
            if not nn: continue
            nd = profile.parent/nn; profile.rename(nd)
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
        files=sorted(G.logs_dir.rglob('*.log'), key=lambda f: f.stat().st_mtime, reverse=True)
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
    r=_run(['df','-k',str(G.mnt_dir)],capture=True)
    avail=int(r.stdout.splitlines()[-1].split()[3]) if r.returncode==0 else 9999999
    if avail < 2097152:
        pause('⚠  Less than 2 GiB free. Use Other → Resize image first.'); return False
    return True

def _guard_install() -> bool:
    return _guard_space()

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

def _open_in_submenu(cid: str):
    d=sj(cid); port=d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT')
    items=[]
    if port and str(port)!='0':
        ip=netns_ct_ip(cid)
        items.append(f' {GRN}◈{NC}  Open browser  {DIM}→ http://{ip}:{port}{NC}')
    items+=[f' {DIM}◈  Terminal (shell into container){NC}',
            f' {DIM}◈  File manager (yazi){NC}',
            _nav_sep(),_back_item()]
    sel=fzf_run(items,header=f'{BLD}── Open in ──{NC}')
    if not sel or clean(sel)==L['back']: return
    sc=clean(sel)
    if 'Open browser' in sc and port:
        _open_url(f'http://{netns_ct_ip(cid)}:{port}')
    elif 'Terminal' in sc:
        ct_path=cpath(cid); sess=f'sdTerm_{cid}'
        ns=netns_name()
        if not tmux_up(sess):
            # Detect bash location for Noble merged-usr (/bin→usr/bin)
            bash_detect = (f'_b=/bin/bash; [[ ! -f {str(ct_path)!r}/bin/bash && ! -L {str(ct_path)!r}/bin/bash'
                           f' && -f {str(ct_path)!r}/usr/bin/bash ]] && _b=/usr/bin/bash; ')
            _tmux('new-session','-d','-s',sess,
                  f'sudo -n nsenter --net=/run/netns/{ns} -- '
                  f'unshare --mount --pid --uts --ipc --fork bash -c '
                  f'"{bash_detect}sudo -n chroot {str(ct_path)!r} \\"$_b\\""; '
                  f'tmux kill-session -t {sess} 2>/dev/null||true')
            _tmux('set-option','-t',sess,'detach-on-destroy','off')
        if os.environ.get('TMUX'):
            _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess}')
        else:
            _tmux('switch-client','-t',sess)
    elif 'File manager' in sc:
        ip=cpath(cid)
        if ip: subprocess.run(['yazi',str(ip)])

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
            for a in d.get('actions',[]): action_labels.append(a['label']); action_dsls.append(a['dsl'])
            cron_entries=d.get('crons',[])
        _UPD_ITEMS=[]; _UPD_IDX=[]
        if not installing and not running:
            _build_update_items_for(cid,_UPD_ITEMS,_UPD_IDX)
        if installing or install_done:
            if install_done:
                fin_lbl=L['ct_finish_inst'] if not installed else '✓  Finish update'
                items.append(fin_lbl)
            else: items.append(L['ct_attach_inst'])
        elif running:
            items+=[L['ct_stop'],L['ct_restart'],L['ct_attach'],L['ct_open_in'],L['ct_log']]
            if action_labels:
                items.append(_sep('Actions'))
                items.extend(action_labels)
            if cron_entries:
                items.append(_sep('Cron'))
                for i,cr in enumerate(cron_entries):
                    sess=cron_sess(cid,i)
                    if tmux_up(sess):
                        items.append(f' {CYN}⏱{NC}  {DIM}{cr["name"]}  {CYN}[{cr["interval"]}]{NC}')
                    else:
                        items.append(f' {DIM}⏱  {cr["name"]}  [stopped]{NC}')
        elif installed:
            local_SEP_STO = _sep('Storage')
            local_SEP_DNG = _sep('Caution')
            items+=[L['ct_start'],L['ct_open_in']]
            items+=[local_SEP_STO,L['ct_backups'],L['ct_profiles']]
            items+=[L['ct_edit']]
            if _UPD_ITEMS:
                pending=any('→' in strip_ansi(x) or 'Changes detected' in strip_ansi(x) for x in _UPD_ITEMS)
                lbl=f' {YLW}⬆  Updates{NC}' if pending else '⬆  Updates'
                items.append(lbl)
            items+=[local_SEP_DNG,L['ct_uninstall']]
        else:
            items+=[L['ct_install'],L['ct_edit'],L['ct_rename'],
                    _sep('Caution'),L['ct_remove']]
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
                if os.environ.get('TMUX'):
                    _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess_inst}')
                else:
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
                if os.environ.get('TMUX'):
                    _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess_ct}')
                else:
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
            new_mode=_exposure_next(cid)
            _exposure_set(cid,new_mode)
            _exposure_apply(cid)
            pause(f'Port exposure set to: {_exposure_label(new_mode)}\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network')
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
                    if tmux_up(cs):
                        if os.environ.get('TMUX'):
                            _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {cs}')
                        else:
                            _tmux('switch-client','-t',cs)
                    else: pause(f"Cron '{cr['name']}' is not running.")
                    break
        else:
            # action labels
            for ai,lbl in enumerate(action_labels):
                if sc==clean(lbl): _run_action(cid,ai,action_dsls[ai]); break

def _fzf_with_watcher(items, header, ok_f, fail_f):
    """Like fzf_run but kills fzf when ok_f or fail_f appear. Returns (sel, auto_triggered)."""
    done_evt=threading.Event()
    def _watch():
        while not ok_f.exists() and not fail_f.exists(): time.sleep(0.3)
        done_evt.set()
    wt=threading.Thread(target=_watch,daemon=True); wt.start()
    proc=subprocess.Popen(['fzf']+FZF_BASE+[f'--header={BLD}── {header} ──{NC}'],
                          stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    G.active_fzf_pid=proc.pid
    proc.stdin.write(('\n'.join(items)+'\n').encode()); proc.stdin.close()
    def _kw(): done_evt.wait(); proc.kill()
    threading.Thread(target=_kw,daemon=True).start()
    out,_=proc.communicate(); G.active_fzf_pid=None
    if done_evt.is_set(): return None,True
    return (out.decode().strip() or None), False

def _edit_container_bp(cid: str):
    src=G.containers_dir/cid/'service.src'
    if not src.exists():
        _ensure_src(cid)
    if not src.exists():
        src.write_text(bp_template())
    editor=os.environ.get('EDITOR','nano')
    subprocess.run([editor,str(src)])
    parsed=bp_parse(src.read_text()); errs=bp_validate(parsed)
    if errs: pause(f'⚠  Blueprint has errors (not saved):\n\n'+'\n'.join(errs)+'\n\n  Re-open editor to fix.'); return
    bp_compile(src,cid)
    if st(cid,'installed'): build_start_script(cid)

def _rename_container(cid: str, new_name: str) -> bool:
    new_name = re.sub(r'[^a-zA-Z0-9_\-]','',new_name).strip()
    if not new_name: pause('Name cannot be empty.'); return False
    load_containers()
    for c in G.CT_IDS:
        if c != cid and cname(c) == new_name:
            pause(f"Container '{new_name}' already exists."); return False
    set_st(cid,'name',new_name)
    # Rebuild start script if installed so log paths etc. use new name
    if st(cid,'installed') and cpath(cid): build_start_script(cid)
    pause(f"Container renamed to '{new_name}'."); return True

def _run_action(cid: str, ai: int, dsl: str):
    ip=cpath(cid); sess=f'sdAction_{cid}_{ai}'
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_action_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(_env_exports(cid,ip))
        f.write(f'cd {ip!r}\n')
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
                    f.write(f'_sd_list=$({scmd} 2>/dev/null)\n')
                    f.write('[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }\n')
                    if skip: f.write('_sd_list=$(printf "%s" "$_sd_list" | tail -n +2)\n')
                    f.write(f'_sd_selection=$(printf "%s\\n" "$_sd_list"'
                            f'|awk \'{{print ${col}}}\'|fzf --ansi --no-sort --prompt="  ❯ "'
                            f' --pointer="▶" --height=40% --reverse --border=rounded'
                            f' --margin=1,2 --no-info 2>/dev/null)||exit 0\n')
                else:
                    cmd=seg.replace('{input}','$_sd_input').replace('{selection}','$_sd_selection')
                    f.write(cmd+'\n')
        else:
            f.write(dsl+'\n')
    os.chmod(runner.name,0o755)
    if tmux_up(sess):
        if os.environ.get('TMUX'):
            _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess}')
        else:
            _tmux('switch-client','-t',sess)
    else:
        _tmux('new-session','-d','-s',sess,
              f'bash {runner.name!r}; rm -f {runner.name!r}; '
              f'printf "\\n\\033[0;32m══ Done ══\\033[0m\\n"; '
              f'printf "Press Enter to return...\\n"; read -rs _; '
              f'tmux switch-client -t simpleDocker 2>/dev/null||true; '
              f'tmux kill-session -t {sess!r} 2>/dev/null||true')
        _tmux('set-option','-t',sess,'detach-on-destroy','off')
        if os.environ.get('TMUX'):
            _tmux('new-window','-t','simpleDocker',f'tmux attach-session -t {sess}')
        else:
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
        for ext in ('*.container', '*.toml'):
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
                        if same: entry=f'{DIM}[B] {bname} — ✓ v{cur_ver}{NC}'
                        else: entry=f'{DIM}[B]{NC} {bname} {DIM}—{NC} {YLW}Changes detected{NC}'
                    else:
                        entry=f'{DIM}[B]{NC} {bname} {DIM}—{NC} {YLW}{cur_ver or "?"}{NC} → {GRN}{new_ver or "?"}{NC}'
                    items.append(entry); idx.append(str(len(idx)))
                except: pass

def _build_ubuntu_update_item_for(cid: str, items: list, idx: list):
    ub_cache_read()
    if G.ub_pkg_drift or G.ub_has_updates:
        items.append(f'{DIM}[U]{NC} Ubuntu base {YLW}Updates available{NC}')
    else:
        items.append(f'{DIM}[U] Ubuntu base — ✓{NC}')
    idx.append('__ubuntu__')

def _build_pkg_manifest_item_for(cid: str, items: list, idx: list):
    mf=G.containers_dir/cid/'pkg_manifest.json'
    if not mf.exists(): return
    try: m=json.loads(mf.read_text())
    except: return
    n=sum(len(m.get(k,[])) for k in ('deps','pip','npm','git'))
    if n==0: return
    ts=m.get('updated','never')
    items.append(f'{DIM}[P] Packages — ✓ {ts}{NC}')
    idx.append('__pkgs__')

def _do_ubuntu_update(cid: str):
    if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists():
        pause('Ubuntu base not installed.'); return
    if not _guard_ubuntu_pkg(): return
    cmd=f'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y 2>&1'
    _ubuntu_pkg_op('sdUbuntuPkg','Ubuntu update',cmd)
    G.ub_cache_loaded=False

def _do_pkg_update(cid: str):
    mf=G.containers_dir/cid/'pkg_manifest.json'
    if not mf.exists(): pause('No manifest. Reinstall first.'); return
    try: m=json.loads(mf.read_text())
    except: pause('Corrupt manifest.'); return
    if confirm(f"Update packages for '{cname(cid)}'?"): run_job(cid,'update')

def _do_blueprint_update(cid: str, idx: int):
    d=sj(cid); stype=d.get('meta',{}).get('storage_type','')
    bps=[]
    if G.blueprints_dir:
        seen=set()
        for ext in ('*.container','*.toml'):
            for f in G.blueprints_dir.glob(ext):
                if f.stem not in seen: bps.append(f); seen.add(f.stem)
    try: bf=bps[idx] if idx<len(bps) else None
    except: bf=None
    if not bf: pause('Blueprint not found.'); return
    cur_ver=d.get('meta',{}).get('version','')
    bp=bp_parse(bf.read_text()); new_ver=str(bp.get('meta',{}).get('version',''))
    if not confirm(f"Update '{cname(cid)}' from blueprint '{bf.stem}'?\n  Version: {cur_ver} → {new_ver}"): return
    src=G.containers_dir/cid/'service.src'; shutil.copy(str(bf),str(src))
    if bp_compile(src,cid):
        if st(cid,'installed'): build_start_script(cid)
        pause(f"'{cname(cid)}' updated to {new_ver}.")
    else: pause('⚠  Update applied but compile had errors. Check Edit configuration.')

# ══════════════════════════════════════════════════════════════════════════════
# menus/container.py — backups submenu
# ══════════════════════════════════════════════════════════════════════════════

def container_backups_menu(cid: str):
    while True:
        sdir=snap_dir(cid)
        pi=(sdir/'Post-Installation') if sdir.is_dir() else None
        others=[]
        if sdir.is_dir():
            for f in sdir.glob('*.meta'):
                sid=f.stem
                if sid=='Post-Installation': continue
                if (sdir/sid).is_dir(): others.append(sid)
        items=[_sep('Snapshots')]
        if pi and pi.is_dir():
            ts=snap_meta_get(sdir,'Post-Installation','ts')
            items.append(f' {DIM}◈{NC}  Post-Installation  {DIM}({ts}){NC}')
        for sid in others:
            ts=snap_meta_get(sdir,sid,'ts'); tp=snap_meta_get(sdir,sid,'type')
            items.append(f' {DIM}◈{NC}  {sid}  {DIM}({ts}) [{tp}]{NC}')
        if not pi and not others: items.append(f'{DIM}  (no backups yet){NC}')
        items+=[_sep('Actions'),f' {GRN}+  Create backup{NC}',_nav_sep(),_back_item()]
        sel=fzf_run(items,header=f'{BLD}── Backups — {cname(cid)} ──{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if 'Create backup' in sc: create_backup_manual(cid)
        elif 'Post-Installation' in sc: _snap_submenu(cid,sdir/'Post-Installation','Post-Installation')
        else:
            for sid in others:
                if sid in sc: _snap_submenu(cid,sdir/sid,sid); break

def _snap_submenu(cid: str, snap_path: Path, label: str):
    sel=menu(f'{label}','Restore this snapshot','Clone as new container',L['stor_delete'])
    if not sel: return
    if 'Restore' in sel: restore_snap(cid,snap_path,label)
    elif 'Clone' in sel:
        v=finput('Name for the clone:')
        if v: clone_from_snap(cid,snap_path,label,v)
    elif sel==L['stor_delete']:
        if confirm(f"Delete backup '{label}'?"):
            sdir=snap_dir(cid); btrfs_delete(snap_path)
            (sdir/f'{label}.meta').unlink(missing_ok=True)
            pause(f"Backup '{label}' deleted.")

# ══════════════════════════════════════════════════════════════════════════════
# menus/containers.py — containers list + new container
# ══════════════════════════════════════════════════════════════════════════════

def containers_submenu():
    while True:
        os.system('clear')
        load_containers()
        n_running=sum(1 for c in G.CT_IDS if tmux_up(tsess(c)))
        items=[f'{BLD}  ── Containers ──────────────────────{NC}']
        for cid in G.CT_IDS:
            # Batch-load service.json + state.json once per container — matches .sh
            # single jq call optimisation (avoids 2 file opens per container per render)
            try: _sj = json.loads((G.containers_dir/cid/'service.json').read_text())
            except: _sj = {}
            try: _st = json.loads((G.containers_dir/cid/'state.json').read_text())
            except: _st = {}
            n        = _st.get('name') or f'(unnamed-{cid})'
            installed= _st.get('installed', False)
            port     = str(_sj.get('meta',{}).get('port') or _sj.get('environment',{}).get('PORT',''))
            ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
            if is_installing(cid) or ok_f.exists() or fail_f.exists(): dot=f'{YLW}◈{NC}'
            elif tmux_up(tsess(cid)):
                dot=f'{GRN}◈{NC}' if health_check(cid) else f'{YLW}◈{NC}'
            elif installed: dot=f'{RED}◈{NC}'
            else: dot=f'{DIM}◈{NC}'
            dlg=_sj.get('meta',{}).get('dialogue','')
            disp=f'{n}  {DIM}— {dlg}{NC}' if dlg else n
            sz_lbl=''; sc_path=G.cache_dir/'sd_size'/cid
            if sc_path.exists(): sz_lbl=f'{DIM}[{sc_path.read_text().strip()}gb]{NC} '
            ip_lbl=''
            if port and port!='0' and installed:
                ip_lbl=f'{DIM}[{netns_ct_ip(cid)}:{port}]{NC} '
            items.append(f' {dot}  {disp}  {DIM}{sz_lbl}{ip_lbl}[{cid}]{NC}')
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
    pbps = _list_persistent_names()
    ibps = _list_imported_names()
    load_containers()

    items = [f'{BLD}  ── Install from blueprint ───────────{NC}\t__sep__']
    if bps or pbps or ibps:
        for n in bps:  items.append(f'   {DIM}◈{NC}  {n}\tbp:{n}')
        for n in pbps: items.append(f'   {BLU}◈{NC}  {n}  {DIM}[Persistent]{NC}\tpbp:{n}')
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

    cid = rand_id()
    cdir = G.containers_dir/cid
    cdir.mkdir(parents=True, exist_ok=True)

    if tag.startswith('bp:'):
        bname = tag[3:]
        bf = _bp_find_file(bname)
        if not bf: pause(f"Blueprint '{bname}' not found."); shutil.rmtree(str(cdir),True); return
        # suggest name from blueprint
        try:
            sug = bp_parse(bf.read_text()).get('meta',{}).get('name','') or bname
        except: sug = bname
        v = finput(f'Container name (default: {sug}):')
        if v is None: shutil.rmtree(str(cdir),True); return
        ct_name = v.strip() or sug
        shutil.copy(str(bf), str(cdir/'service.src'))
        bp_compile(cdir/'service.src', cid)

    elif tag.startswith('pbp:'):
        bname = tag[4:]
        pd = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
        bf = None
        if pd:
            for ext in ('.container','.toml'):
                t = pd/f'{bname}{ext}'
                if t.exists(): bf = t; break
        if not bf: pause(f"Blueprint '{bname}' not found."); shutil.rmtree(str(cdir),True); return
        v = finput(f'Container name (default: {bname}):')
        if v is None: shutil.rmtree(str(cdir),True); return
        ct_name = v.strip() or bname
        shutil.copy(str(bf), str(cdir/'service.src'))
        bp_compile(cdir/'service.src', cid)

    elif tag.startswith('ibp:'):
        bname = tag[4:]
        bf = _get_imported_bp_path(bname)
        if not bf: pause(f"Could not locate imported blueprint '{bname}'."); shutil.rmtree(str(cdir),True); return
        v = finput(f'Container name (default: {bname}):')
        if v is None: shutil.rmtree(str(cdir),True); return
        ct_name = v.strip() or bname
        shutil.copy(str(bf), str(cdir/'service.src'))
        bp_compile(cdir/'service.src', cid)

    elif tag.startswith('clone:'):
        src_cid = tag[6:]
        shutil.rmtree(str(cdir), True)  # clone uses its own dir
        _clone_source_submenu(src_cid)
        return

    else:
        shutil.rmtree(str(cdir), True); return

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
    for ext in ('*.container', '*.toml'):
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

def _bp_persistent_enabled() -> bool:
    return str(_bp_settings_get('persistent_blueprints','true')).lower() not in ('false','0')

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

def _list_persistent_names() -> List[str]:
    """Return built-in/persistent blueprint names when enabled."""
    if not _bp_persistent_enabled(): return []
    presets_dir = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
    if not presets_dir or not presets_dir.is_dir(): return []
    found = []; seen = set()
    for ext in ('*.container', '*.toml'):
        for f in presets_dir.glob(ext):
            if f.stem not in seen:
                found.append(f.stem); seen.add(f.stem)
    return found

def _list_imported_names() -> List[str]:
    """Autodetect .container files per autodetect mode. Prunes hidden dirs and vendor."""
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
        depth = 3 if mode in ('Home','Custom') else 5
        for p in sd.rglob('*.container'):
            # skip hidden dirs (any path component starting with '.')
            parts = p.relative_to(sd).parts
            if any(part.startswith('.') for part in parts[:-1]): continue
            # skip pruned dirs
            if any(part in _PRUNE for part in parts): continue
            if str(p).count('/') - str(sd).count('/') > depth: continue
            if G.blueprints_dir and p.parent == G.blueprints_dir: continue
            found.append(p.stem)
    return list(dict.fromkeys(found))

def _get_imported_bp_path(name: str) -> Optional[Path]:
    mode = _bp_autodetect_mode()
    search_dirs: List[Path] = []
    if mode == 'Home': search_dirs = [Path.home()]
    elif mode in ('Root','Everywhere'): search_dirs = [Path('/')]
    elif mode == 'Custom': search_dirs = [Path(p) for p in _bp_custom_paths_get() if Path(p).is_dir()]
    _PRUNE = {'node_modules','__pycache__','.git','vendor'}
    for sd in search_dirs:
        for p in sd.rglob('*.container'):
            parts = p.relative_to(sd).parts
            if any(part.startswith('.') for part in parts[:-1]): continue
            if any(part in _PRUNE for part in parts): continue
            if p.stem == name and (not G.blueprints_dir or p.parent != G.blueprints_dir):
                return p
    return None

def _view_persistent_bp(name: str):
    presets_dir = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
    if not presets_dir: return
    f = next((presets_dir/f'{name}{ext}' for ext in ('.container','.toml')
               if (presets_dir/f'{name}{ext}').exists()), None)
    if not f: pause(f"Persistent blueprint '{name}' not found."); return
    fzf_run(f.read_text().splitlines(),
            header=f'{BLD}── [Persistent] {name}  {DIM}(read only){NC} ──{NC}',
            extra=['--no-multi','--disabled'])

def _bp_find_file(name: str) -> Optional[Path]:
    """Locate a blueprint file by stem, preferring .container over .toml."""
    if not G.blueprints_dir: return None
    for ext in ('.container', '.toml'):
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
            editor = os.environ.get('EDITOR','nano')
            subprocess.run([editor, str(bp_file)])
            parsed = bp_parse(bp_file.read_text())
            errs = bp_validate(parsed)
            if errs: pause('⚠  Blueprint has errors:\n\n'+'\n'.join(errs))
        elif sel == L['bp_rename']:
            v = finput(f"New name for '{name}':"); 
            if not v: continue
            nn = re.sub(r'[^a-zA-Z0-9_\- ]','',v)
            if not nn: continue
            new_f = G.blueprints_dir/f'{nn}{bp_file.suffix}'
            if new_f.exists(): pause(f"Blueprint '{nn}' already exists."); continue
            bp_file.rename(new_f)
            pause(f"Renamed to '{nn}'."); return
        elif sel == L['bp_delete']:
            if confirm(f"Delete blueprint '{name}'?\n\n  This does not affect containers."):
                bp_file.unlink(missing_ok=True)
                pause(f"Blueprint '{name}' deleted."); return

def blueprints_submenu():
    """menus/blueprints.py"""
    while True:
        os.system('clear')
        bps = _list_blueprint_names()
        pbps = _list_persistent_names()
        ibps = _list_imported_names()
        items = [f'{BLD}  ── Blueprints ───────────────────────{NC}']
        for n in bps:  items.append(f' {DIM}◈{NC}  {n}')
        for n in pbps: items.append(f' {BLU}◈{NC}  {n}  {DIM}[Persistent]{NC}')
        for n in ibps: items.append(f' {CYN}◈{NC}  {n}  {DIM}[Imported]{NC}')
        if not bps and not pbps and not ibps:
            items.append(f'{DIM}  (no blueprints yet){NC}')
        items += [f'{GRN} +  {L["bp_new"]}{NC}',
                  _nav_sep(), _back_item()]
        hdr = (f'{BLD}── Blueprints ──{NC}  '
               f'{DIM}[{len(bps)} file · {len(pbps)} built-in · {len(ibps)} imported]{NC}')
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
            bfile = G.blueprints_dir/f'{bname}.container'
            if bfile.exists(): pause(f"Blueprint '{bname}' already exists."); continue
            bfile.write_text(bp_template())
            pause(f"Blueprint '{bname}' created. Select it to edit.")
            continue
        elif '[Persistent]' in sc:
            pname = re.sub(r'^\s*◈\s*','',strip_ansi(sc)).split('[Persistent]')[0].strip()
            if pname: _view_persistent_bp(pname)
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
        pers = _bp_persistent_enabled()
        pers_tog = f'{GRN}[Enabled]{NC}' if pers else f'{RED}[Disabled]{NC}'
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
            f' {DIM}◈{NC}  Persistent blueprints  {pers_tog}  {DIM}— toggle built-in visibility{NC}',
            f' {DIM}◈{NC}  Autodetect blueprints  {ad_lbl}  {DIM}— scan for .container files{NC}',
        ]
        if ad_mode == 'Custom':
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
        if 'Persistent blueprints' in sc:
            _bp_settings_set('persistent_blueprints', not pers)
        elif 'Autodetect blueprints' in sc:
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
    ok_f  = G.ubuntu_dir/'.ub_ok'  if G.ubuntu_dir else Path('/tmp/.sd_ub_ok')
    fail_f= G.ubuntu_dir/'.ub_fail'if G.ubuntu_dir else Path('/tmp/.sd_ub_fail')
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
                sync_pkgs = ' '.join(missing) if missing else DEFAULT_UBUNTU_PKGS
                cmd = f'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {sync_pkgs} 2>&1'
                if not _guard_ubuntu_pkg(): continue
                _ubuntu_pkg_op('sdUbuntuPkg','Sync default pkgs',cmd)
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
    os.system('clear')
    ok_f  = G.ubuntu_dir/'.ub_ok'
    fail_f= G.ubuntu_dir/'.ub_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    ub = str(G.ubuntu_dir)
    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_ubsetup_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\nset -e\n')
        f.write('_chroot_bash(){ local r=$1; shift; local b=/bin/bash; [[ ! -f "$r/bin/bash" && ! -L "$r/bin/bash" && -f "$r/usr/bin/bash" ]] && b=/usr/bin/bash; sudo -n chroot "$r" "$b" "$@"; }\n')
        f.write('_sd_ub_arch=$(uname -m)\n')
        f.write('case "$_sd_ub_arch" in x86_64) _sd_ub_arch=amd64;; aarch64) _sd_ub_arch=arm64;; armv7l) _sd_ub_arch=armhf;; *) _sd_ub_arch=amd64;; esac\n')
        f.write('_base="https://cdimage.ubuntu.com/ubuntu-base/releases/noble/release/"\n')
        f.write('_ver=$(curl -fsSL "$_base" 2>/dev/null|grep -oP "ubuntu-base-\\K[0-9]+\\.[0-9]+\\.[0-9]+-base-${_sd_ub_arch}"|head -1)\n')
        f.write('[[ -z "$_ver" ]] && _ver="24.04.3-base-${_sd_ub_arch}"\n')
        f.write(f'mkdir -p {ub!r}\n')
        f.write('_tmp=$(mktemp /tmp/.sd_ub_dl_XXXXXX.tar.gz)\n')
        f.write('printf "[ubuntu] Downloading Ubuntu 24.04 LTS Noble (%s)...\\n" "$_sd_ub_arch"\n')
        f.write(f'curl -fsSL --progress-bar "${{_base}}ubuntu-base-${{_ver}}.tar.gz" -o "$_tmp"\n')
        f.write(f'printf "[ubuntu] Extracting...\\n"\n')
        f.write(f'tar -xzf "$_tmp" -C {ub!r} 2>&1||true; rm -f "$_tmp"\n')
        f.write(f'[[ ! -e {ub!r}/bin ]] && ln -sf usr/bin {ub!r}/bin 2>/dev/null||true\n')
        f.write(f'[[ ! -e {ub!r}/lib ]] && ln -sf usr/lib {ub!r}/lib 2>/dev/null||true\n')
        f.write(f'printf "nameserver 8.8.8.8\\n" > {ub!r}/etc/resolv.conf\n')
        f.write(f'mkdir -p {ub!r}/etc/apt/apt.conf.d\n')
        f.write(f'printf \'APT::Sandbox::User "root";\\n\' > {ub!r}/etc/apt/apt.conf.d/99sandbox\n')
        f.write(f'sudo -n mount --bind /proc {ub!r}/proc 2>/dev/null||true\n')
        f.write(f'sudo -n mount --bind /sys  {ub!r}/sys  2>/dev/null||true\n')
        f.write(f'sudo -n mount --bind /dev  {ub!r}/dev  2>/dev/null||true\n')
        f.write(f'_apt=$(mktemp /tmp/.sd_ubinit_XXXXXX.sh)\n')
        f.write(f'printf \'#!/bin/sh\\nset -e\\napt-get update -qq\\nDEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {DEFAULT_UBUNTU_PKGS} 2>&1\\n\' > "$_apt"\n')
        f.write(f'chmod +x "$_apt"\n')
        f.write(f'sudo -n mount --bind "$_apt" {ub!r}/tmp/.sd_ubinit.sh 2>/dev/null||cp "$_apt" {ub!r}/tmp/.sd_ubinit.sh\n')
        f.write(f'_chroot_bash {ub!r} bash /tmp/.sd_ubinit.sh\n')
        f.write(f'sudo -n umount -lf {ub!r}/tmp/.sd_ubinit.sh {ub!r}/dev {ub!r}/sys {ub!r}/proc 2>/dev/null||true\n')
        f.write(f'rm -f "$_apt" {ub!r}/tmp/.sd_ubinit.sh 2>/dev/null||true\n')
        f.write(f'touch {ub!r}/.ubuntu_ready\n')
        f.write(f'date +%Y-%m-%d > {ub!r}/.sd_ubuntu_stamp\n')
        ok = str(G.ubuntu_dir/'.ub_ok'); fail = str(G.ubuntu_dir/'.ub_fail')
        f.write(f'touch {ok!r}\n')
        f.write(f'printf "\\033[0;32m[ubuntu] Ubuntu base ready.\\033[0m\\n\\n"\n')
    os.chmod(runner.name, 0o755)
    if tmux_up('sdUbuntuSetup'): _tmux('kill-session','-t','sdUbuntuSetup')
    _tmux('new-session','-d','-s','sdUbuntuSetup',
          f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t','sdUbuntuSetup','detach-on-destroy','off')
    _installing_wait_loop('sdUbuntuSetup', str(ok_f), str(fail_f), 'Ubuntu base setup')
    G.ub_cache_loaded = False

# ══════════════════════════════════════════════════════════════════════════════
# services/caddy.py — reverse proxy / Caddy menu
# ══════════════════════════════════════════════════════════════════════════════

def _proxy_cfg_path() -> Path:  return G.mnt_dir/'.sd/proxy.json'
def _proxy_caddy_bin() -> Path: return G.mnt_dir/'.sd/caddy/caddy'
def _proxy_caddy_log() -> Path: return G.mnt_dir/'.sd/caddy/caddy.log'
def _proxy_caddy_storage() -> Path: return G.mnt_dir/'.sd/caddy/data'
def _proxy_sudoers_path() -> Path:
    return Path(f'/etc/sudoers.d/simpledocker_caddy_{os.popen("id -un").read().strip()}')

def _proxy_cfg_get(key: str) -> str:
    try: return json.loads(_proxy_cfg_path().read_text()).get(key,'')
    except: return ''

def _proxy_cfg_set(key: str, val):
    p = _proxy_cfg_path()
    try: data = json.loads(p.read_text())
    except: data = {'autostart': False, 'routes': []}
    data[key] = val
    tmp = tempfile.mktemp(dir=str(G.tmp_dir))
    Path(tmp).write_text(json.dumps(data, indent=2)); Path(tmp).rename(p)

def proxy_running() -> bool:
    pf = _proxy_pidfile()
    if not pf.exists(): return False
    try: os.kill(int(pf.read_text().strip()), 0); return True
    except: return False

def _proxy_start(background=False) -> bool:
    if not _proxy_caddy_bin().exists(): return False
    _proxy_write()
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
        time.sleep(0.5)
        return proc.poll() is None
    except: return False

def _proxy_stop():
    pf = _proxy_pidfile()
    if pf.exists():
        try: _sudo('kill', pf.read_text().strip())
        except: pass
        time.sleep(0.3); pf.unlink(missing_ok=True)

def _proxy_write():
    """Generate Caddyfile from proxy.json routes."""
    cf = _proxy_caddyfile(); cf.parent.mkdir(parents=True, exist_ok=True)
    r = _run(['ip','route','get','1'], capture=True)
    lan_ip = ''
    for tok in r.stdout.split():
        if tok == 'src':
            idx = r.stdout.split().index(tok)
            lan_ip = r.stdout.split()[idx+1]
            break
    lines = ['{\n  admin off\n  local_certs\n}\n']
    try:
        data = json.loads(_proxy_cfg_path().read_text())
        for route in data.get('routes', []):
            url = route.get('url',''); cid2 = route.get('cid','')
            https = route.get('https', False)
            port = str(sj_get(cid2,'meta','port',default='') or sj_get(cid2,'environment','PORT',default=''))
            if not port or port == '0': continue
            ct_ip = netns_ct_ip(cid2)
            exp = exposure_get(cid2)
            if exp == 'isolated': continue
            proto = 'https' if https else 'http'
            if https:
                lines.append(f'https://{url} {{\n  tls internal\n  reverse_proxy {ct_ip}:{port}\n}}\n')
            else:
                lines.append(f'http://{url} {{\n  reverse_proxy {ct_ip}:{port}\n}}\n')
    except: pass
    cf.write_text('\n'.join(lines))

def _proxy_install_caddy_menu():
    """Launch Caddy + mDNS install in tmux session."""
    caddy_dest = _proxy_caddy_bin()
    caddy_dest.parent.mkdir(parents=True, exist_ok=True)
    ok_f  = G.tmp_dir/'.sd_caddy_ok'
    fail_f= G.tmp_dir/'.sd_caddy_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_caddy_inst_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\nset -uo pipefail\n')
        f.write(f'_fail(){{ touch {fail_f!r}; exit 1; }}\n')
        f.write('printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"\n')
        f.write('case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l) ARCH=armv7;; *) ARCH=amd64;; esac\n')
        f.write('VER=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null'
                '|tr -d \'\\n\'|grep -o \'"tag_name":"[^"]*"\'|cut -d: -f2|tr -d \'"v \')\n')
        f.write('[[ -z "$VER" ]] && VER="2.9.1"\n')
        f.write('TMPD=$(mktemp -d)\n')
        f.write('URL="https://github.com/caddyserver/caddy/releases/download/v${VER}/caddy_${VER}_linux_${ARCH}.tar.gz"\n')
        f.write(f'curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz" || _fail caddy_install\n')
        f.write('tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy\n')
        f.write(f'mv "$TMPD/caddy" {caddy_dest!r}; chmod +x {caddy_dest!r}\n')
        f.write('rm -rf "$TMPD"\n')
        f.write(f'printf "%s ALL=(ALL) NOPASSWD: {caddy_dest}\\n" "$(id -un)" | sudo -n tee {_proxy_sudoers_path()!r} >/dev/null 2>/dev/null||true\n')
        f.write('sudo -n apt-get install -y avahi-utils 2>&1\n')
        f.write(f'touch {ok_f!r}\n')
        f.write('printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"\n')
        f.write('sleep 1\n')  # let user read the output before auto-dismiss
    os.chmod(runner.name, 0o755)
    sess = 'sdCaddyInst'
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    _installing_wait_loop(sess, str(ok_f), str(fail_f), 'Install Caddy + mDNS')
    while tmux_up(sess): time.sleep(0.3)
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    if _proxy_caddy_bin().exists():
        pause(f'✓ Caddy installed successfully.')
    else:
        pause('✗ Caddy install failed. Select "Attach" next time to see output.')

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
                route_lines.append(f' {CYN}◈{NC}  {CYN}{rurl}{NC}  →  {rname}  {DIM}({proto}  {rurl}.local){NC}')
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
                if 'Reinstall' in sel2: _proxy_install_caddy_menu()
                elif 'Uninstall' in sel2:
                    _proxy_stop()
                    _proxy_caddy_bin().unlink(missing_ok=True)
                    _sudo('rm','-f',str(_proxy_sudoers_path()))
                    runner2=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),suffix='.sh',delete=False,prefix='.sd_avahi_')
                    with open(runner2.name,'w') as fh: fh.write('#!/bin/bash\nsudo -n apt-get remove -y avahi-utils 2>&1\n')
                    os.chmod(runner2.name,0o755)
                    _tmux('new-session','-d','-s','sdAvahiUninst',f'bash {runner2.name!r}; rm -f {runner2.name!r}')
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
                    pause(f'⚠  Caddy failed to start.\n\nLog:\n'+'\n'.join(tail))
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
            v = finput('Enter URL (e.g. comfyui.local, myapp.local)\n\n  Use .local for zero-config LAN (mDNS).')
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
            if proxy_running(): _proxy_stop(); _proxy_start()
            elif autostart: _proxy_start()
            pause(f'✓ Added: {nurl} → {sel_ct} (port {nport})')
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
                        sel2=menu(f'Edit: {rurl}','Change URL','Change container','Toggle HTTPS','Remove')
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
                       if re.match(r'^sd_[a-z0-9]{8}$|^sdInst_|^sdCron_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$', s)]
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
    """image/btrfs.py — resize (caller in help_menu already prompted for size)"""
    if not G.img_path or not G.mnt_dir:
        pause('No image mounted.'); return

    new_size_arg = re.sub(r'[^0-9]','',new_size_arg.strip())
    if not new_size_arg:
        pause('Invalid size. Must be a whole number.'); return
    new_gib = int(new_size_arg)

    cur_bytes_r = _run(['stat','--printf=%s',str(G.img_path)], capture=True)
    cur_gib_f = int(cur_bytes_r.stdout.strip())/(1<<30) if cur_bytes_r.returncode==0 else 0

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
    min_gib = int(used_bytes/(1<<30))+1+10
    if new_gib < min_gib:
        pause(f'Invalid size. Must be a whole number ≥ {min_gib} GB.'); return

    # ── Stop running containers first (V14 confirm message matches shell) ──
    load_containers()
    running_cts = [c for c in G.CT_IDS if tmux_up(tsess(c))]
    running_names = [cname(c) for c in running_cts]
    cur_gib_s = f'{cur_gib_f:.1f}'
    if running_names:
        bullet_list = ''.join(f'  • {nm}\n' for nm in running_names)
        confirm_msg = f'Running services will be stopped:\n{bullet_list}\nResize image from {cur_gib_s} GB → {new_gib} GB?'
    else:
        confirm_msg = f'Resize image from {cur_gib_s} GB → {new_gib} GB?'
    if not confirm(confirm_msg): return

    if running_cts:
        for c in running_cts:
            stop_ct(c)
        r2 = _tmux('list-sessions','-F','#{session_name}', capture=True)
        for s in (r2.stdout.splitlines() if r2.returncode==0 else []):
            if s.startswith('sdInst_'): _tmux('kill-session','-t',s)
        tmux_set('SD_INSTALLING','')
        time.sleep(0.5)

    sess = 'sdResize'
    if tmux_up(sess): pause('A resize is already running.'); return
    import uuid as _uuid
    _uid = _uuid.uuid4().hex[:8]
    ok_f   = G.tmp_dir / f'.sd_resize_ok_{_uid}'
    fail_f = G.tmp_dir / f'.sd_resize_fail_{_uid}'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)

    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_resize_')
    img = str(G.img_path); mnt = str(G.mnt_dir)
    is_luks = img_is_luks(G.img_path)
    mapper = luks_mapper(G.img_path) if is_luks else ''
    auto_pass = G.verification_cipher
    action = 'shrink' if new_gib < cur_gib_f else 'extend'
    new_bytes = new_gib * (1 << 30)

    # Build _do_mount / _do_umount helpers — matches shell two-step mount approach (F9)
    def _luks_open_block(lo_var, mapper_name):
        lines = []
        lines.append(f'  _opened=0')
        lines.append(f'  printf %s {auto_pass!r} | sudo -n cryptsetup open --key-file=- "${lo_var}" {mapper_name!r} && _opened=1 || true')
        lines.append(f'  if [ "$_opened" -eq 0 ]; then')
        lines.append(f'    printf %s {SD_DEFAULT_KEYWORD!r} | sudo -n cryptsetup open --key-file=- "${lo_var}" {mapper_name!r} && _opened=1 || true')
        lines.append(f'  fi')
        lines.append(f'  if [ "$_opened" -eq 0 ]; then')
        lines.append(f'    for _try in 1 2 3; do')
        lines.append(f'      printf "Passphrase for LUKS image: "; read -rs _pp; printf "\\n"')
        lines.append(f'      printf %s "$_pp" | sudo -n cryptsetup open --key-file=- "${lo_var}" {mapper_name!r} && {{ _opened=1; break; }} || true')
        lines.append(f'      printf "Wrong passphrase.\\n"')
        lines.append(f'    done')
        lines.append(f'  fi')
        lines.append(f'  [ "$_opened" -eq 0 ] && {{ printf "Failed to open LUKS image.\\n"; exit 1; }}')
        lines.append(f'  sudo -n cryptsetup resize {mapper_name!r}')
        return '\n'.join(lines)

    if is_luks:
        luks_open_tmp  = _luks_open_block('_lo', mapper)
        luks_open_mnt  = _luks_open_block('_lo', mapper)
        mount_dev_tmp  = f'sudo -n mount -o compress=zstd /dev/mapper/{mapper} "$_tmp_mnt"'
        mount_dev_mnt  = f'sudo -n mount -o compress=zstd /dev/mapper/{mapper} {mnt!r}'
        close_luks     = f'sudo -n cryptsetup close {mapper!r} 2>/dev/null || true'
    else:
        luks_open_tmp  = ''
        luks_open_mnt  = ''
        mount_dev_tmp  = 'sudo -n mount -o compress=zstd "$_lo" "$_tmp_mnt"'
        mount_dev_mnt  = f'sudo -n mount -o compress=zstd "$_lo" {mnt!r}'
        close_luks     = ''

    script_lines = [
        '#!/usr/bin/env bash',
        f'_ok_f={str(ok_f)!r}',
        f'_fail_f={str(fail_f)!r}',
        '_finish(){ local c=$?; [[ $c -eq 0 ]] && touch "$_ok_f" || touch "$_fail_f"; }',
        'trap _finish EXIT',
        'trap \'touch "$_fail_f"; exit 130\' INT TERM',
        'set -e',
        f'printf "\033[1mResize: {action} to {new_gib} GB\033[0m\n"',
        '_tmp_mnt=$(mktemp -d /tmp/.sd_mnt_XXXXXX)',
        # --- unmount current ---
        f'printf "Syncing...\n"',
        f'sudo -n btrfs filesystem sync {mnt!r} 2>/dev/null || true',
    ]
    if action == 'shrink':
        script_lines += [
            f'printf "Shrinking BTRFS filesystem...\n"',
            f'sudo -n btrfs filesystem resize {new_bytes} {mnt!r} || {{ printf "ERROR: btrfs resize failed\n"; exit 1; }}',
        ]
    script_lines += [
        f'printf "Unmounting original...\n"',
        f'sudo -n umount -lf {mnt!r}',
        close_luks,
        f'_lo=$(sudo -n losetup -j {img!r} 2>/dev/null | cut -d: -f1 | head -1)',
        '[ -n "$_lo" ] && sudo -n losetup -d "$_lo" 2>/dev/null || true',
    ]
    if action == 'shrink':
        script_lines.append(f'printf "Truncating image to {new_gib}G...\n"')
    else:
        script_lines.append(f'printf "Extending image to {new_gib}G...\n"')
    script_lines.append(f'truncate -s {new_bytes} {img!r}')
    # --- mount to tmp dir ---
    script_lines += [
        f'printf "Remounting (temp)...\n"',
        f'_lo=$(sudo -n losetup --find --show {img!r})',
    ]
    if luks_open_tmp:
        script_lines.append(luks_open_tmp)
    script_lines.append(mount_dev_tmp)
    if action == 'extend':
        script_lines += [
            f'printf "Resizing BTRFS filesystem...\n"',
            f'sudo -n btrfs filesystem resize max "$_tmp_mnt" || {{ printf "ERROR: btrfs resize failed\n"; sudo -n umount -lf "$_tmp_mnt"; {close_luks}; rm -rf "$_tmp_mnt"; exit 1; }}',
        ]
    # --- unmount tmp, remount to original path ---
    script_lines += [
        f'sudo -n umount -lf "$_tmp_mnt"',
        close_luks,
        f'_lo=$(sudo -n losetup -j {img!r} 2>/dev/null | cut -d: -f1 | head -1)',
        '[ -n "$_lo" ] && sudo -n losetup -d "$_lo" 2>/dev/null || true',
        f'rm -rf "$_tmp_mnt" 2>/dev/null || true',
        f'printf "Final remount...\n"',
        f'mkdir -p {mnt!r}',
        f'_lo=$(sudo -n losetup --find --show {img!r})',
    ]
    if luks_open_mnt:
        script_lines.append(luks_open_mnt)
    script_lines += [
        mount_dev_mnt,
        f'printf "\033[0;32m✓ Resize to {new_gib} GB complete.\033[0m\n"',
    ]
    # Remove blank lines from close_luks='' entries
    script_lines = [l for l in script_lines if l != '']

    with open(runner.name,'w') as f:
        f.write('\n'.join(script_lines) + '\n')
    os.chmod(runner.name, 0o755)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    _installing_wait_loop(sess, str(ok_f), str(fail_f), 'Resize image')
    while tmux_up(sess): time.sleep(0.3)
    resize_ok = ok_f.exists()
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    if resize_ok:
        # Kill all container + install sessions, unmount, then exec-restart — matches shell
        load_containers()
        for cid2 in G.CT_IDS:
            _tmux('kill-session','-t',tsess(cid2))
        r2 = _tmux('list-sessions','-F','#{session_name}', capture=True)
        for s in (r2.stdout.splitlines() if r2.returncode==0 else []):
            if s.startswith('sdInst_'): _tmux('kill-session','-t',s)
        try: unmount_img()
        except: pass
        os.execv(sys.executable, [sys.executable] + sys.argv)
    else:
        G.tmp_dir = G.sd_mnt_base/'.tmp'
        G.tmp_dir.mkdir(parents=True, exist_ok=True)
        pause('Resize failed. Check that sudo commands succeeded.')
        if G.img_path and not subprocess.run(['mountpoint','-q',str(G.mnt_dir)],
                                              capture_output=True).returncode == 0:
            mount_img(G.img_path)

# ══════════════════════════════════════════════════════════════════════════════
# menus/help.py — Other / help menu
# ══════════════════════════════════════════════════════════════════════════════

def help_menu():
    """menus/help.py — the Other / ? menu"""
    # Read ubuntu cache once per menu open (non-blocking if already loaded)
    ub_cache_read()
    while True:
        if G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists():
            ubuntu_status = f'{GRN}ready{NC}  {CYN}[P]{NC}'
            ubuntu_upd_tag = ''
            if G.ub_pkg_drift or G.ub_has_updates:
                ubuntu_upd_tag = f'  {YLW}Updates available{NC}'
        else:
            ubuntu_status = f'{YLW}not installed{NC}'
            ubuntu_upd_tag = ''
        proxy_s = f'{GRN}running{NC}' if proxy_running() else f'{DIM}stopped{NC}'
        qr_installed = bool(G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists()
                            and _run(['sudo','-n','chroot',str(G.ubuntu_dir),'sh','-c',
                                      'command -v qrencode'], capture=True).returncode==0)
        qr_s = f'{GRN}installed{NC}' if qr_installed else f'{DIM}not installed{NC}'
        items = [
            _sep('Storage'),
            f'{DIM} ◈  Profiles & data{NC}',
            f'{DIM} ◈  Backups{NC}',
            f'{DIM} ◈  Blueprints{NC}',
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
            f'{DIM} ⚷  Manage Encryption{NC}',
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
        elif 'Blueprints' in sc and 'preset' not in sc: blueprints_settings_menu()
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
            if G.img_path and img_is_luks(G.img_path): enc_menu()
            else: pause('Image is not encrypted.')
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
    """All containers with backups — menus/help.py"""
    while True:
        load_containers()
        cts_with_snaps = []
        for cid2 in G.CT_IDS:
            sdir = snap_dir(cid2)
            if sdir.is_dir() and any(True for f in sdir.glob('*.meta')): cts_with_snaps.append(cid2)
        items = [_sep('Containers')]
        for cid2 in cts_with_snaps:
            sdir = snap_dir(cid2)
            count = len([f for f in sdir.glob('*.meta')])
            items.append(f' {DIM}◈{NC}  {cname(cid2)}  {DIM}[{count} backup{"s" if count!=1 else ""}]{NC}')
        if not cts_with_snaps: items.append(f'{DIM}  (no backups yet){NC}')
        items += [_nav_sep(), _back_item()]
        sel = fzf_run(items, header=f'{BLD}── Backups ──{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        for cid2 in cts_with_snaps:
            if cname(cid2) in sc: container_backups_menu(cid2); break

def _qrencode_menu():
    """Plugin: QRencode — menus/help.py"""
    if not G.ubuntu_dir or not (G.ubuntu_dir/'.ubuntu_ready').exists():
        pause('Ubuntu base not installed. Install Ubuntu first.'); return
    qr_ok = _run(['sudo','-n','chroot',str(G.ubuntu_dir),'sh','-c','command -v qrencode'],capture=True).returncode==0
    if qr_ok:
        sel = menu('QRencode',f'{YLW}↑  Update{NC}',f'{RED}Uninstall{NC}')
        if not sel: return
        if 'Update' in sel:
            cmd = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1'
            _ubuntu_pkg_op('sdQrInst','Update QRencode',cmd)
        elif 'Uninstall' in sel:
            if confirm('Uninstall QRencode from Ubuntu?'):
                cmd = 'DEBIAN_FRONTEND=noninteractive apt-get remove -y qrencode 2>&1'
                _ubuntu_pkg_op('sdQrUninst','Uninstall QRencode',cmd)
    else:
        sel = menu('QRencode',f'{GRN}↓  Install{NC}')
        if sel and 'Install' in sel:
            cmd = 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1'
            _ubuntu_pkg_op('sdQrInst','Install QRencode',cmd)

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
        n_bp  = len(_list_blueprint_names()) + len(_list_persistent_names())
        # Only count imported if autodetect is enabled (avoids slow rglob on every render)
        if _bp_autodetect_mode() != 'Disabled':
            n_bp += len(_list_imported_names())
        # Image label
        img_label = ''
        if G.img_path and G.mnt_dir:
            r = _run(['df','-k',str(G.mnt_dir)], capture=True)
            if r.returncode == 0:
                parts = r.stdout.splitlines()[-1].split()
                used_gb = int(parts[2])/1048576; total_gb = int(parts[1])/1048576
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
            f'{DIM}─────────────────────────────────────────{NC}',
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
    if not os.path.exists(sudoers):
        # First run: full write_sudoers (prompts for password, writes NOPASSWD rule)
        write_sudoers()
    else:
        # Subsequent runs: invalidate cached ticket and re-validate (mirrors sudo -k && sudo -v)
        subprocess.run(['sudo','-k'], capture_output=True)
        while subprocess.run(['sudo','-v']).returncode != 0:
            print(f'  {RED}Incorrect password.{NC} Try again.\n')
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
        cmd = f'env SD_INNER=1 python3 {me!r}'
        r = subprocess.run(
            ['tmux','new-session','-d','-s',sess,'-x','220','-y','50',cmd],
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
    try: shutil.rmtree(str(G.sd_mnt_base), ignore_errors=True)
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
    """INT/TERM/HUP → force quit with full cleanup (mirrors bash trap '_force_quit' INT TERM HUP)."""
    _force_quit()

def _check_btrfs_kernel():
    r = _run(['grep','-qw','btrfs','/proc/filesystems'], capture=True)
    if r.returncode != 0:
        r2 = _sudo('modprobe','btrfs')
        if r2.returncode != 0:
            print(f'{RED}✗  BTRFS kernel module not available.{NC}')
            print('  Enable BTRFS support or use a kernel that includes it.')
            sys.exit(1)

if __name__ == '__main__':
    # ── Dependency check — runs BEFORE anything else ───────────────────────────
    _missing_deps = [t for t in REQUIRED_TOOLS if not shutil.which(t)]
    if _missing_deps:
        _pkg_map = {
            'btrfs':  'btrfs-progs',
            'ip':     'iproute2',
            'fzf':    'fzf',
            'tmux':   'tmux',
            'jq':     'jq',
            'yazi':   'yazi',         # may need cargo / external repo on some distros
            'sudo':   'sudo',
            'curl':   'curl',
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
        print(f'\n{DIM}  Note: yazi may need a separate install — see https://yazi-rs.github.io{NC}\n')
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
    require_sudo()    # background keepalive

    # Background ubuntu cache check
    ub_thread = threading.Thread(target=ub_cache_check, daemon=True)
    ub_thread.start()

    sweep_stale()
    tmux_set('SD_READY', '1')
    setup_image()
    main_menu()