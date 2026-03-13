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
    if shutil.which('pacman'):   pm = ['sudo','pacman','-S','--noconfirm']
    elif shutil.which('apt-get'): pm = ['sudo','apt-get','install','-y']
    elif shutil.which('dnf'):     pm = ['sudo','dnf','install','-y']
    else: print("No package manager"); sys.exit(1)
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

_SIG_RCS = {130, 137, 138, 143}  # SIGUSR1/SIGTERM/SIGKILL killed fzf

def fzf_run(items: List[str], header: str='', extra: list=None,
            with_nth: str=None, delimiter: str=None) -> Optional[str]:
    """Core fzf wrapper — returns stripped selection or None.
    Sets G.usr1_fired=True when fzf was signal-killed (SIGUSR1 refresh)."""
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
    if proc.returncode != 0: return None
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
    """Returns typed text or None on ESC."""
    args = ['fzf'] + FZF_BASE + [
        f'--header={BLD}{prompt}{NC}\n{DIM}  {L["type_enter"]}{NC}',
        '--print-query','--read0',
    ]
    proc = subprocess.Popen(['fzf']+FZF_BASE+[
        f'--header={BLD}{prompt}{NC}\n{DIM}  {L["type_enter"]}{NC}',
        '--print-query'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    G.active_fzf_pid = proc.pid
    out, _ = proc.communicate(b'')
    G.active_fzf_pid = None
    if proc.returncode not in (0,1): return None
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

# ══════════════════════════════════════════════════════════════════════════════
# image/btrfs.py — btrfs snapshot helpers
# ══════════════════════════════════════════════════════════════════════════════

def snap_dir(cid: str) -> Path:
    return G.installations_dir/'.snaps'/cid

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

def mount_img(img: Path) -> bool:
    mnt = G.sd_mnt_base/f'mnt_{hashlib.md5(str(img).encode()).hexdigest()[:8]}'
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
    mnt = G.sd_mnt_base/f'mnt_{hashlib.md5(str(img).encode()).hexdigest()[:8]}'
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
        _sudo('btrfs','subvolume','create',str(mnt/sv))
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
        if choice is None: os.system('clear'); _force_quit()
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
    if not parsed.get('meta',{}).get('name'):
        errs.append('meta.name is required')
    return errs

def bp_compile(src_path: Path, cid: str) -> bool:
    """Parse src → write service.json. Return True on success."""
    text = src_path.read_text()
    parsed = bp_parse(text)
    errs = bp_validate(parsed)
    if errs: return False
    dst = G.containers_dir/cid/'service.json'
    dst.write_text(json.dumps(parsed, indent=2))
    return True

def bp_template() -> str:
    return '''\
[container]

[meta]
name         = my-service
version      = 1.0.0
dialogue     = Short label shown in the container list
description  = Longer notes about this service.
port         = 8080
storage_type = my-service
entrypoint   = bin/my-service --port 8080
# log        = logs/service.log
# health     = true
# gpu        = nvidia
# cap_drop   = true
# seccomp    = true

[env]
PORT     = 8080
HOST     = 127.0.0.1
DATA_DIR = data

[storage]
data, logs

[deps]
curl, tar

[dirs]
bin, data, logs

[pip]

[npm]

[git]

[build]

[install]

[update]

[start]

[cron]
# 5m [heartbeat] | printf '[cron] ping\\n' >> logs/cron.log

[actions]
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
    _tmux('new-session','-d','-s',sess,f'bash {start_sh}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    # start cron jobs
    d=sj(cid)
    for i,cr in enumerate(d.get('crons',[])):
        _cron_start_one(cid,i,cr)
    if mode=='attach': _tmux('switch-client','-t',sess)

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
            f.write(f'_cb(){{ sudo -n chroot "$1" bash "${{@:2}}"; }}\n')
            f.write(f'mount --bind {ip} {ub}/mnt 2>/dev/null||true\n')
            f.write(f'_cb {ub} -c "cd /mnt && {inner}"\n')
            f.write('_SDCRON\n')
            f.write('done\n')
    os.chmod(runner.name, 0o755)
    _tmux('new-session','-d','-s',sname,f'bash {runner.name}; rm -f {runner.name}')
    _tmux('set-option','-t',sname,'detach-on-destroy','off')

def _env_exports(cid: str, install_path: Path) -> str:
    d=sj(cid); lines=[f'export CONTAINER_ROOT={install_path!r}']
    lines+=['export HOME="$CONTAINER_ROOT"',
            'export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"',
            'export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"',
            'export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"',
            'export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"',
            'export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/bin:$PATH"',
            'export PYTHONNOUSERSITE=1 PIP_USER=false']
    for k,v in d.get('environment',{}).items():
        lines.append(f'export {k}="{v}"')
    return '\n'.join(lines)+'\n'

def build_start_script(cid: str):
    """Generate start.sh inside the installation directory."""
    ip=cpath(cid)
    if not ip: return
    d=sj(cid); ns=netns_name()
    start_block=d.get('start',''); ep=d.get('meta',{}).get('entrypoint','')
    exec_cmd=ep if ep else start_block
    hostname=re.sub(r'[^a-z0-9\-]','-',cname(cid).lower())[:63]
    sh=ip/'start.sh'
    with open(sh,'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write(_env_exports(cid,ip))
        f.write(f'sudo -n nsenter --net=/run/netns/{ns} -- '
                f'unshare --mount --pid --uts --ipc --fork bash -s << \'_SDNS_WRAP\'\n')
        f.write('_chroot_bash(){ local r=$1; shift; sudo -n chroot "$r" bash "$@"; }\n')
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
            '_chroot_bash(){ local r=$1; shift; sudo -n chroot "$r" bash "$@"; }',
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
                f'sudo -n chroot {ip!r} bash /tmp/$(basename "$_sd_run")',
                f'sudo -n umount -lf {ip!r}/dev {ip!r}/sys {ip!r}/proc 2>/dev/null||true',
                'rm -f "$_sd_run"','']
    return '\n'.join(lines)

def write_pkg_manifest(cid: str):
    d=sj(cid)
    m={'deps':d.get('deps',[]),'pip':d.get('pip',[]),'npm':d.get('npm',[]),
       'git':[g.get('repo','') for g in d.get('git',[])],'updated':time.strftime('%Y-%m-%d %H:%M')}
    (G.containers_dir/cid/'pkg_manifest.json').write_text(json.dumps(m,indent=2))

def run_job(cid: str, mode='install', force=False):
    """Launch install/update in a tmux session."""
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
    _tmux('new-session','-d','-s',sess,
          f'bash {runner.name!r}; rm -f {runner.name!r}; '
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

def _ubuntu_pkg_op(sess: str, title: str, apt_cmd: str):
    ok_f=G.ubuntu_dir/'.upkg_ok'; fail_f=G.ubuntu_dir/'.upkg_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    runner=tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                       suffix='.sh',delete=False,prefix='.sd_ubpkg_')
    runner.write(f'#!/bin/bash\nset -e\n'
                 f'_cb(){{ sudo -n chroot "$1" bash "${{@:2}}"; }}\n'
                 f'sudo -n mount --bind /proc {G.ubuntu_dir}/proc; '
                 f'sudo -n mount --bind /sys {G.ubuntu_dir}/sys; '
                 f'sudo -n mount --bind /dev {G.ubuntu_dir}/dev\n'
                 f'_sd_apt=$(mktemp /tmp/.sd_apt_XXXXXX.sh)\n'
                 f'printf \'#!/bin/sh\\nset -e\\n{apt_cmd}\\n\' > "$_sd_apt"\n'
                 f'chmod +x "$_sd_apt"\n'
                 f'sudo -n mount --bind "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||cp "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh\n'
                 f'_cb {G.ubuntu_dir!r} /tmp/.sd_apt.sh\n'
                 f'sudo -n umount -lf {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||true\n'
                 f'sudo -n umount -lf {G.ubuntu_dir}/dev {G.ubuntu_dir}/sys {G.ubuntu_dir}/proc 2>/dev/null||true\n'
                 f'rm -f "$_sd_apt" {G.ubuntu_dir}/tmp/.sd_apt.sh 2>/dev/null||true\n'
                 f'touch {ok_f!r}\n'
                 f'tmux kill-session -t {sess} 2>/dev/null||true\n')
    runner.close(); os.chmod(runner.name,0o755)
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    # wait with fzf "attach" option
    _installing_wait_loop(sess, str(ok_f), str(fail_f), title)
    G.ub_cache_loaded=False

def _installing_wait_loop(sess: str, ok_f: str, fail_f: str, title: str):
    """Show fzf menu with attach option; auto-close when done."""
    items=[f'{DIM}→  Attach to {title}{NC}', _nav_sep(), _back_item()]
    while True:
        done_evt=threading.Event()
        def _watch():
            while not Path(ok_f).exists() and not Path(fail_f).exists(): time.sleep(0.3)
            done_evt.set()
        wt=threading.Thread(target=_watch,daemon=True); wt.start()
        proc=subprocess.Popen(['fzf']+FZF_BASE+[f'--header={BLD}── {title} ──{NC}'],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        G.active_fzf_pid=proc.pid
        proc.stdin.write(('\n'.join(items)+'\n').encode()); proc.stdin.close()
        def _kill_when_done():
            done_evt.wait(); proc.kill()
        kt=threading.Thread(target=_kill_when_done,daemon=True); kt.start()
        out,_=proc.communicate()
        G.active_fzf_pid=None
        if done_evt.is_set(): return   # auto-advanced
        sel=out.decode().strip()
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if 'Attach' in sel and tmux_up(sess): _tmux('switch-client','-t',sess)

# ══════════════════════════════════════════════════════════════════════════════
# services/caddy.py — reverse proxy
# ══════════════════════════════════════════════════════════════════════════════

def _proxy_pidfile() -> Path: return G.mnt_dir/'.sd/.caddy.pid'
def _proxy_caddyfile() -> Path: return G.mnt_dir/'.sd/Caddyfile'
def proxy_running() -> bool:
    pf=_proxy_pidfile()
    if not pf.exists(): return False
    try: os.kill(int(pf.read_text().strip()),0); return True
    except: return False

# ══════════════════════════════════════════════════════════════════════════════
# menus/encryption.py — LUKS key management menu
# ══════════════════════════════════════════════════════════════════════════════

def enc_menu():
    while True:
        auto=enc_auto_unlock_enabled(); agnostic=enc_system_agnostic_enabled()
        auto_lbl=f'{GRN}Enabled{NC}' if auto else f'{RED}Disabled{NC}'
        ag_lbl=f'{GRN}Enabled{NC}' if agnostic else f'{RED}Disabled{NC}'
        vdir=enc_verified_dir(); vid=enc_verified_id()
        slots_used=enc_slots_used(); slots_total=SD_LUKS_SLOT_MAX-SD_LUKS_SLOT_MIN+1
        vs_ids=([f.stem for f in vdir.glob('*') if f.is_file()] if vdir.is_dir() else [])
        # Passkeys: slots 7-31 not used by verified systems or auth token
        r=_sudo('cryptsetup','luksDump',str(G.img_path),capture=True)
        auth_slot=enc_authkey_slot()
        vs_slots={snap_meta_get(vdir,vsid,'slot') for vsid in vs_ids if snap_meta_get(vdir,vsid,'slot')}
        pk_slots=[m.group(1) for m in re.finditer(r'^\s+(\d+): luks2',r.stdout,re.M)
                  if m.group(1)!='0' and m.group(1)!=auth_slot and m.group(1) not in vs_slots
                  and SD_LUKS_SLOT_MIN<=int(m.group(1))<=SD_LUKS_SLOT_MAX]
        nf=G.mnt_dir/'.sd/keyslot_names.json'
        try: slot_names=json.loads(nf.read_text()) if nf.exists() else {}
        except: slot_names={}
        items=[_sep('General'),
               f' {DIM}◈  System Agnostic: {ag_lbl}{NC}',
               f' {DIM}◈  Auto-Unlock: {auto_lbl}{NC}',
               f' {DIM}◈  Reset Auth Token{NC}',
               _sep('Verified Systems')]
        for vsid in vs_ids:
            host=vdir.joinpath(vsid).read_text().splitlines()[0] if vdir.joinpath(vsid).exists() else vsid
            items.append(f' {DIM}◈  {host}  [vs:{vsid}]{NC}')
        items.append(f' {GRN}+  Verify this system{NC}')
        items.append(_sep('Passkeys'))
        if not pk_slots: items.append(f'{DIM}  (no passkeys added yet){NC}')
        for sl in pk_slots:
            nm=slot_names.get(sl,f'Key {sl}')
            items.append(f' {DIM}◈  {nm}  [s:{sl}]{NC}')
        items.append(f' {GRN}+  Add Key{NC}')
        items+=[_nav_sep(),_back_item()]
        sel=fzf_run(items,header=f'{BLD}── Manage Encryption ──{NC}  {DIM}{slots_used}/{slots_total} slots{NC}')
        if sel is None:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if sc==L['back'] or not sc: return
        if 'System Agnostic' in sc:
            if agnostic:
                if not pk_slots and not [v for v in vs_ids if snap_meta_get(vdir,v,'slot')]:
                    pause('Cannot disable — no other unlock method exists.\nAdd a passkey or verify a system first.'); continue
                if not confirm('Disable System Agnostic? This image will no longer open on unknown machines.'): continue
                subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                '--key-file=-',str(G.img_path),'1'],
                               input=SD_DEFAULT_KEYWORD.encode(), capture_output=True)
                pause('System Agnostic disabled.')
            else:
                if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth Token first.'); continue
                subprocess.run(['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                                '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                                '--key-slot','1','--key-file',str(enc_authkey_path()),str(G.img_path)],
                               input=SD_DEFAULT_KEYWORD.encode(), capture_output=True)
                pause('System Agnostic enabled.')
        elif 'Auto-Unlock' in sc:
            if auto:
                if confirm('Disable Auto-Unlock? All verified system slots will be removed (cache kept).'):
                    for vsid in vs_ids:
                        sl=snap_meta_get(vdir,vsid,'slot')
                        if sl and sl!='0':
                            subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                            '--key-file=-',str(G.img_path),sl],
                                           input=G.verification_cipher.encode(), capture_output=True)
                            lns=vdir.joinpath(vsid).read_text().splitlines()
                            lns[1]='' if len(lns)>1 else ''
                            vdir.joinpath(vsid).write_text('\n'.join(lns))
                    pause('Auto-Unlock disabled.')
            else:
                if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth first.'); continue
                for vsid in vs_ids:
                    vspass=snap_meta_get(vdir,vsid,'pass')
                    if not vspass: continue
                    free=enc_free_slot()
                    if not free: pause('No free slots.'); break
                    subprocess.run(['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                                    '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                                    '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
                                   input=vspass.encode(), capture_output=True)
                    snap_meta_set(vdir,vsid,slot=free)
                pause('Auto-Unlock enabled.')
        elif 'Reset Auth Token' in sc:
            import getpass
            pw=getpass.getpass('  Current passphrase: ')
            kf=enc_authkey_path(); kf.parent.mkdir(parents=True,exist_ok=True)
            kf.write_bytes(os.urandom(64)); kf.chmod(0o600)
            tf=tempfile.mktemp(dir=str(G.tmp_dir))
            Path(tf).write_bytes(pw.encode())
            r=subprocess.run(['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                              '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                              '--key-slot','0','--key-file',tf,str(G.img_path),str(kf)],
                             capture_output=True)
            Path(tf).unlink(missing_ok=True)
            if r.returncode==0: enc_authkey_slot_file().write_text('0'); pause('Auth token reset.')
            else: pause('Failed — wrong passphrase?')
        elif 'Verify this system' in sc:
            free=enc_free_slot()
            if not free: pause(f'No free slots ({SD_LUKS_SLOT_MIN}–{SD_LUKS_SLOT_MAX} full).'); continue
            if not enc_authkey_valid(): pause('Auth keyfile missing. Use Reset Auth Token first.'); continue
            vspass=enc_verified_pass()
            r=subprocess.run(['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                              '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                              '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
                             input=vspass.encode(), capture_output=True)
            if r.returncode==0:
                vid2=enc_verified_id(); vdir.mkdir(parents=True,exist_ok=True)
                hostname=open('/etc/hostname').read().strip() if Path('/etc/hostname').exists() else 'unknown'
                vdir.joinpath(vid2).write_text(f'{hostname}\n{free}\n{vspass}')
                pause('This system verified for auto-unlock.')
            else: pause('Failed.')
        elif '+ Add Key' in sc:
            kname=finput('Key name:')
            if not kname: continue
            import getpass; pw=getpass.getpass('  Passphrase: '); pw2=getpass.getpass('  Confirm: ')
            if pw!=pw2: pause('Passphrases do not match.'); continue
            if not enc_authkey_valid(): pause('Auth keyfile missing.'); continue
            free=enc_free_slot()
            if not free: pause('No free slots.'); continue
            r=subprocess.run(['sudo','-n','cryptsetup','luksAddKey','--batch-mode',
                              '--pbkdf','pbkdf2','--pbkdf-force-iterations','1000','--hash','sha1',
                              '--key-slot',free,'--key-file',str(enc_authkey_path()),str(G.img_path)],
                             input=pw.encode(), capture_output=True)
            if r.returncode==0:
                nf.parent.mkdir(parents=True,exist_ok=True)
                try: names=json.loads(nf.read_text()) if nf.exists() else {}
                except: names={}
                names[free]=kname; nf.write_text(json.dumps(names,indent=2))
                pause(f"Key '{kname}' added (slot {free}).")
            else: pause('Failed.')
        elif '[vs:' in sc:
            vsid=re.search(r'\[vs:([^\]]+)\]',sc)
            if vsid:
                vsid=vsid.group(1)
                if confirm(f"Forget system '{vsid}' and remove its LUKS slot?"):
                    sl=snap_meta_get(vdir,vsid,'slot')
                    if sl and sl!='0':
                        subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                        '--key-file=-',str(G.img_path),sl],
                                       input=G.verification_cipher.encode(), capture_output=True)
                    vdir.joinpath(vsid).unlink(missing_ok=True)
                    pause('Verified system removed.')
        elif '[s:' in sc:
            sl=re.search(r'\[s:([^\]]+)\]',sc)
            if sl:
                sl=sl.group(1); nm=slot_names.get(sl,f'Key {sl}')
                if confirm(f"Delete key '{nm}' (slot {sl})?"):
                    if enc_authkey_valid():
                        subprocess.run(['sudo','-n','cryptsetup','luksKillSlot','--batch-mode',
                                        '--key-file',str(enc_authkey_path()),str(G.img_path),sl],
                                       capture_output=True)
                    try: names=json.loads(nf.read_text()); del names[sl]; nf.write_text(json.dumps(names,indent=2))
                    except: pass
                    pause(f"Key '{nm}' deleted.")

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
                items.append(f' {DIM}◈{NC}  {n}')
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
        items=[_sep('Storage profiles')]
        for p in profiles:
            try: sz=_run(['du','-sh',str(p)],capture=True).stdout.split()[0]
            except: sz='?'
            items.append(f' {DIM}◈{NC}  {p.name}  {DIM}({sz}){NC}')
        if not profiles: items.append(f'{DIM}  (no profiles yet){NC}')
        items.append(f' {GRN}+  New profile{NC}')
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
        else:
            # find which profile
            for p in profiles:
                if p.name in sc:
                    _profile_submenu(cid, p); break

def _profile_submenu(cid: str, profile: Path):
    while True:
        sel=menu(f'{profile.name}',L['stor_rename'],L['stor_delete'])
        if not sel:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        if sel==L['stor_rename']:
            v=finput(f'New name for \'{profile.name}\':')
            if not v: continue
            nn=re.sub(r'[^a-zA-Z0-9_\-]','',v)
            if not nn: continue
            nd=profile.parent/nn; profile.rename(nd)
            pause(f"Profile renamed to '{nn}'."); return
        elif sel==L['stor_delete']:
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
    import subprocess as sp
    for cmd in ['xdg-open','firefox','chromium','google-chrome']:
        if shutil.which(cmd):
            sp.Popen([cmd,url], stderr=sp.DEVNULL); return

def _open_in_submenu(cid: str):
    d=sj(cid); port=d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT')
    items=[]
    if port and str(port)!='0':
        ip=netns_ct_ip(cid)
        items.append(f' {GRN}◈{NC}  Open browser  {DIM}→ http://{ip}:{port}{NC}')
    items+=[f' {DIM}◈{NC}  Terminal (shell into container)',
            f' {DIM}◈{NC}  File manager (yazi)',
            _nav_sep(),_back_item()]
    sel=fzf_run(items,header=f'{BLD}── Open in ──{NC}')
    if not sel or clean(sel)==L['back']: return
    sc=clean(sel)
    if 'Open browser' in sc and port:
        _open_url(f'http://{netns_ct_ip(cid)}:{port}')
    elif 'Terminal' in sc:
        ip=cpath(cid); sess=f'sdTerm_{cid}'
        if not tmux_up(sess):
            _tmux('new-session','-d','-s',sess,
                  f'sudo -n chroot {ip!r} bash; tmux kill-session -t {sess} 2>/dev/null||true')
            _tmux('set-option','-t',sess,'detach-on-destroy','off')
        _tmux('switch-client','-t',sess)
    elif 'File manager' in sc:
        ip=cpath(cid)
        if ip: subprocess.run(['yazi',str(ip)])

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
            items+=[L['ct_start'],L['ct_open_in'],
                    _sep('Storage'),L['ct_backups'],L['ct_profiles'],L['ct_edit']]
            if _UPD_ITEMS:
                pending=any('→' in strip_ansi(x) or 'Changes detected' in strip_ansi(x) for x in _UPD_ITEMS)
                lbl=f' {YLW}⬆  Updates{NC}' if pending else '⬆  Updates'
                items.append(_sep('Caution')); items.append(lbl); items.append(L['ct_uninstall'])
            else:
                items+=[_sep('Caution'),L['ct_uninstall']]
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
        if sc==L['ct_attach_inst']: _tmux('switch-client','-t',inst_sess(cid))
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
        elif sc==L['ct_attach']: _tmux('switch-client','-t',tsess(cid))
        elif sc==L['ct_open_in']: _open_in_submenu(cid)
        elif sc==L['ct_log']:
            meta_log=d.get('meta',{}).get('log','')
            lf=cpath(cid)/meta_log if meta_log and cpath(cid) else log_path(cid,'start')
            if lf.exists(): pause('\n'.join(lf.read_text().splitlines()[-100:]))
            else: pause(f"No log yet for '{n}'.")
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
                    if tmux_up(cs): _tmux('switch-client','-t',cs)
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
        bp_compile(src,cid) if (G.containers_dir/cid/'service.json').exists() else src.write_text(bp_template())
    editor=os.environ.get('EDITOR','nano')
    subprocess.run([editor,str(src)])
    # validate
    parsed=bp_parse(src.read_text()); errs=bp_validate(parsed)
    if errs: pause(f'⚠  Blueprint has errors (not saved):\n\n'+'\n'.join(errs)+'\n\n  Re-open editor to fix.'); return
    bp_compile(src,cid)
    if st(cid,'installed'): build_start_script(cid)

def _rename_container(cid: str, new_name: str) -> bool:
    if st(cid,'installed'): pause('Rename only available for uninstalled containers.'); return False
    new_name=re.sub(r'[^a-zA-Z0-9_\-]','',new_name)
    if not new_name: pause('Name cannot be empty.'); return False
    load_containers()
    for c in G.CT_IDS:
        if c!=cid and cname(c)==new_name: pause(f"Container '{new_name}' already exists."); return False
    set_st(cid,'name',new_name)
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
        pause(f"Action is still running.\n\n  Press {KB['tmux_detach']} to detach.")
        _tmux('switch-client','-t',sess)
    else:
        _tmux('new-session','-d','-s',sess,
              f'bash {runner.name!r}; rm -f {runner.name!r}; '
              f'printf "\\n\\033[0;32m══ Done ══\\033[0m\\n"; '
              f'printf "Press Enter to return...\\n"; read -rs _; '
              f'tmux switch-client -t simpleDocker 2>/dev/null||true; '
              f'tmux kill-session -t {sess!r} 2>/dev/null||true')
        _tmux('set-option','-t',sess,'detach-on-destroy','off')
        pause(f"Starting action...\n\n  Press {KB['tmux_detach']} to detach.")
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
        for bf in G.blueprints_dir.glob('*.toml'):
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
    bps=[f for f in (G.blueprints_dir.glob('*.toml') if G.blueprints_dir else []) if True]
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
            d=sj(cid); n=cname(cid)
            port=str(d.get('meta',{}).get('port') or d.get('environment',{}).get('PORT',''))
            installed=st(cid,'installed',False)
            ok_f=G.containers_dir/cid/'.install_ok'; fail_f=G.containers_dir/cid/'.install_fail'
            if is_installing(cid) or ok_f.exists() or fail_f.exists(): dot=f'{YLW}◈{NC}'
            elif tmux_up(tsess(cid)):
                dot=f'{GRN}◈{NC}' if health_check(cid) else f'{YLW}◈{NC}'
            elif installed: dot=f'{RED}◈{NC}'
            else: dot=f'{DIM}◈{NC}'
            dlg=d.get('meta',{}).get('dialogue','')
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
    bps=([f.stem for f in G.blueprints_dir.glob('*.toml')] if G.blueprints_dir and G.blueprints_dir.is_dir() else [])
    items=[f'{BLD}  ── Method ──────────────────────────{NC}',
           f' {GRN}◈{NC}  From blueprint',
           f' {GRN}◈{NC}  Blank container',
           f' {GRN}◈{NC}  Import .toml file',
           _nav_sep(),_back_item()]
    sel=fzf_run(items,header=f'{BLD}── New container ──{NC}')
    if not sel or clean(sel)==L['back']: return
    sc=clean(sel)
    cid=rand_id(); cdir=G.containers_dir/cid; cdir.mkdir(parents=True,exist_ok=True)
    if 'From blueprint' in sc:
        if not bps: pause('No blueprints found. Create one first.'); shutil.rmtree(str(cdir),True); return
        items2=[f' {DIM}◈{NC}  {b}' for b in bps]+[_nav_sep(),_back_item()]
        sel2=fzf_run(items2,header=f'{BLD}── Select blueprint ──{NC}')
        if not sel2 or clean(sel2)==L['back']: shutil.rmtree(str(cdir),True); return
        bname=clean(sel2).lstrip('◈').strip()
        bf=G.blueprints_dir/f'{bname}.toml'
        if not bf.exists(): shutil.rmtree(str(cdir),True); return
        shutil.copy(str(bf),str(cdir/'service.src'))
        bp_compile(cdir/'service.src',cid)
        name=sj_get(cid,'meta','name') or bname
    elif 'Blank container' in sc:
        v=finput('Container name:')
        if not v: shutil.rmtree(str(cdir),True); return
        name=re.sub(r'[^a-zA-Z0-9_\-]','',v)
        if not name: shutil.rmtree(str(cdir),True); return
        src=cdir/'service.src'; src.write_text(bp_template())
        bp_compile(src,cid)
    elif 'Import' in sc:
        f=pick_file()
        if not f or f.suffix not in ('.toml','.container'):
            shutil.rmtree(str(cdir),True); return
        shutil.copy(str(f),str(G.blueprints_dir/f.name))
        shutil.copy(str(f),str(cdir/'service.src'))
        bp_compile(cdir/'service.src',cid)
        name=sj_get(cid,'meta','name') or f.stem
    else: shutil.rmtree(str(cdir),True); return
    (cdir/'state.json').write_text(json.dumps({'name':name,'install_path':cid,'installed':False},indent=2))
    pause(f"Container '{name}' created. Select it to install.")

# ══════════════════════════════════════════════════════════════════════════════
# menus/groups.py
# ══════════════════════════════════════════════════════════════════════════════

def _list_groups() -> List[str]:
    if not G.groups_dir or not G.groups_dir.is_dir(): return []
    return [d.name for d in G.groups_dir.iterdir() if (d/'meta.json').exists()]

def _grp_name(gid: str) -> str:
    try: return json.loads((G.groups_dir/gid/'meta.json').read_text()).get('name',gid)
    except: return gid

def _grp_members(gid: str) -> List[str]:
    f=G.groups_dir/gid/'members'
    return f.read_text().splitlines() if f.exists() else []

def groups_menu():
    while True:
        gids=_list_groups()
        n_active=0
        for gid in gids:
            for mn in _grp_members(gid):
                for c in G.CT_IDS:
                    if cname(c)==mn and tmux_up(tsess(c)): n_active+=1; break
        items=[f'{BLD}  ── Groups ──────────────────────────{NC}']
        for gid in gids:
            members=_grp_members(gid)
            running=sum(1 for mn in members for c in G.CT_IDS if cname(c)==mn and tmux_up(tsess(c)))
            lbl=f'{GRN}{running} active{NC}{DIM}/{len(members)}{NC}' if running else f'{DIM}{len(members)}{NC}'
            items.append(f' {CYN}▶{NC}  {_grp_name(gid)}  {lbl}')
        if not gids: items.append(f'{DIM}  (no groups yet){NC}')
        items+=[f'{GRN} +  {L["grp_new"]}{NC}',_nav_sep(),_back_item()]
        sel=fzf_run(items,header=f'{BLD}── Groups ──{NC}  {DIM}[{len(gids)} · {GRN}{n_active} active{NC}{DIM}]{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if L['grp_new'] in sc:
            v=finput('Group name:')
            if not v: continue
            gname=re.sub(r'[^a-zA-Z0-9_\- ]','',v)
            if not gname: continue
            gid=rand_id(); gd=G.groups_dir/gid; gd.mkdir(parents=True,exist_ok=True)
            (gd/'meta.json').write_text(json.dumps({'name':gname},indent=2))
            continue
        for gid in gids:
            if _grp_name(gid) in sc: _group_submenu(gid); break

def _group_submenu(gid: str):
    while True:
        members=_grp_members(gid); name=_grp_name(gid)
        load_containers()
        running=sum(1 for mn in members for c in G.CT_IDS if cname(c)==mn and tmux_up(tsess(c)))
        items=[_sep('Actions'),
               f' {GRN}▶{NC}  Start all', f' {RED}■{NC}  Stop all',
               _sep('Members')]
        for mn in members:
            cid_m=next((c for c in G.CT_IDS if cname(c)==mn), None)
            if cid_m:
                dot=f'{GRN}◈{NC}' if tmux_up(tsess(cid_m)) else f'{RED}◈{NC}'
            else: dot=f'{DIM}◈{NC}'
            items.append(f' {dot}  {mn}')
        if not members: items.append(f'{DIM}  (no members){NC}')
        items+=[f' {GRN}+  Add container{NC}',_sep('Management'),
                f' {DIM}✎  Rename{NC}',f' {DIM}×  Delete group{NC}',_nav_sep(),_back_item()]
        sel=fzf_run(items,header=f'{BLD}── {name} ──{NC}  {DIM}[{running} running/{len(members)}]{NC}')
        if not sel or clean(sel)==L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc=clean(sel)
        if 'Start all' in sc:
            for mn in members:
                cid_m=next((c for c in G.CT_IDS if cname(c)==mn),None)
                if cid_m and st(cid_m,'installed') and not tmux_up(tsess(cid_m)):
                    start_ct(cid_m,'background')
        elif 'Stop all' in sc:
            for mn in members:
                cid_m=next((c for c in G.CT_IDS if cname(c)==mn),None)
                if cid_m and tmux_up(tsess(cid_m)): stop_ct(cid_m)
        elif 'Add container' in sc:
            avail=[cname(c) for c in G.CT_IDS if cname(c) not in members]
            if not avail: pause('All containers are already in this group.'); continue
            items2=[f' {DIM}◈{NC}  {n}' for n in avail]+[_nav_sep(),_back_item()]
            sel2=fzf_run(items2,header=f'{BLD}── Add to {name} ──{NC}')
            if sel2 and clean(sel2)!=L['back']:
                mname=clean(sel2).lstrip('◈').strip()
                mf=G.groups_dir/gid/'members'
                with open(mf,'a') as f2: f2.write(mname+'\n')
        elif '✎  Rename' in sc:
            v=finput(f"New name for '{name}':"); 
            if v:
                nn=re.sub(r'[^a-zA-Z0-9_\- ]','',v)
                if nn:
                    (G.groups_dir/gid/'meta.json').write_text(json.dumps({'name':nn},indent=2))
        elif '×  Delete group' in sc:
            if confirm(f"Delete group '{name}'?\n\n  Containers are not affected."):
                shutil.rmtree(str(G.groups_dir/gid),True)
                pause(f"Group '{name}' deleted."); return
        else:
            # member selected — sub-menu
            for mn in members:
                if mn in sc:
                    sel3=menu(mn,'Open container menu','Remove from group')
                    if sel3=='Open container menu':
                        cid_m=next((c for c in G.CT_IDS if cname(c)==mn),None)
                        if cid_m: container_submenu(cid_m)
                    elif sel3=='Remove from group':
                        if confirm(f"Remove '{mn}' from group '{name}'?"):
                            mf=G.groups_dir/gid/'members'
                            lines=[l for l in mf.read_text().splitlines() if l!=mn]
                            mf.write_text('\n'.join(lines)+'\n')
                    break

# ══════════════════════════════════════════════════════════════════════════════
# menus/blueprints.py
# ══════════════════════════════════════════════════════════════════════════════

def _list_blueprint_names() -> List[str]:
    if not G.blueprints_dir or not G.blueprints_dir.is_dir(): return []
    return [f.stem for f in G.blueprints_dir.glob('*.toml')]

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
    return [f.stem for f in presets_dir.glob('*.toml')]

def _list_imported_names() -> List[str]:
    """Autodetect .container / .toml files per autodetect mode."""
    mode = _bp_autodetect_mode()
    if mode == 'Disabled': return []
    search_dirs: List[Path] = []
    if mode == 'Home': search_dirs = [Path.home()]
    elif mode == 'Root': search_dirs = [Path('/')]
    elif mode == 'Everywhere': search_dirs = [Path('/')]
    elif mode == 'Custom': search_dirs = [Path(p) for p in _bp_custom_paths_get() if Path(p).is_dir()]
    found = []
    for sd in search_dirs:
        depth = 3 if mode in ('Home','Custom') else 5
        for p in sd.rglob('*.container'):
            if str(p).count('/') - str(sd).count('/') <= depth:
                found.append(p.stem)
        for p in sd.rglob('*.toml'):
            if str(p).count('/') - str(sd).count('/') <= depth:
                if p.parent != G.blueprints_dir:
                    found.append(p.stem)
    return list(dict.fromkeys(found))  # dedup, preserve order

def _get_imported_bp_path(name: str) -> Optional[Path]:
    mode = _bp_autodetect_mode()
    search_dirs: List[Path] = []
    if mode == 'Home': search_dirs = [Path.home()]
    elif mode in ('Root','Everywhere'): search_dirs = [Path('/')]
    elif mode == 'Custom': search_dirs = [Path(p) for p in _bp_custom_paths_get() if Path(p).is_dir()]
    for sd in search_dirs:
        for ext in ('*.container','*.toml'):
            for p in sd.rglob(ext):
                if p.stem == name and p.parent != G.blueprints_dir: return p
    return None

def _view_persistent_bp(name: str):
    presets_dir = G.mnt_dir/'.sd/persistent_blueprints' if G.mnt_dir else None
    f = presets_dir/f'{name}.toml' if presets_dir else None
    if not f or not f.exists(): pause(f"Persistent blueprint '{name}' not found."); return
    fzf_run(f.read_text().splitlines(),
            header=f'{BLD}── [Persistent] {name}  {DIM}(read only){NC} ──{NC}',
            extra=['--no-multi','--disabled'])

def _blueprint_submenu(name: str):
    bp_file = G.blueprints_dir/f'{name}.toml'
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
            new_f = G.blueprints_dir/f'{nn}.toml'
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
        for n in bps:  items.append(f'{DIM} ◈{NC}  {n}')
        for n in pbps: items.append(f'{BLU} ◈{NC}  {n}  {DIM}[Persistent]{NC}')
        for n in ibps: items.append(f'{CYN} ◈{NC}  {n}  {DIM}[Imported]{NC}')
        if not bps and not pbps and not ibps:
            items.append(f'{DIM}  (no blueprints yet){NC}')
        items += [f'{GRN} +  {L["bp_new"]}{NC}',
                  _sep('Settings') ,
                  f'{DIM} ◈  Blueprint Settings{NC}',
                  _nav_sep(), _back_item()]
        hdr = (f'{BLD}── Blueprints ──{NC}  '
               f'{DIM}[{len(bps)} file · {len(pbps)} built-in · {len(ibps)} imported]{NC}')
        sel = fzf_run(items, header=hdr)
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if L['bp_new'] in sc:
            if not _guard_space(): continue
            v = finput('Blueprint name:')
            if not v: continue
            bname = re.sub(r'[^a-zA-Z0-9_\- ]','',v)
            if not bname: continue
            bfile = G.blueprints_dir/f'{bname}.toml'
            if bfile.exists(): pause(f"Blueprint '{bname}' already exists."); continue
            bfile.write_text(bp_template())
            pause(f"Blueprint '{bname}' created. Select it to edit.")
        elif 'Blueprint Settings' in sc:
            blueprints_settings_menu()
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
        if 'Updates' in sc:
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
                _ubuntu_pkg_op('sdUbuntuPkg','Sync default pkgs',cmd)
                G.ub_pkg_drift = False; G.ub_cache_loaded = True
            elif 'Update all pkgs' in sc2:
                cmd = 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y 2>&1'
                _ubuntu_pkg_op('sdUbuntuPkg','Update all pkgs',cmd)
                G.ub_has_updates = False; G.ub_cache_loaded = True
        elif 'Uninstall Ubuntu base' in sc:
            if confirm(f'{YLW}⚠  Uninstall Ubuntu base?{NC}\n\nThis wipes the Ubuntu chroot.\nAll containers that depend on it will stop working.'):
                shutil.rmtree(str(G.ubuntu_dir), ignore_errors=True)
                G.ubuntu_dir.mkdir(parents=True, exist_ok=True)
                pause('✓ Ubuntu base removed.'); return
        elif 'Add package' in sc:
            v = finput('Package name (e.g. ffmpeg, nodejs):')
            if not v: continue
            pkg_name = v.strip().replace(' ','')
            if not pkg_name: continue
            v2 = finput('Version (leave blank for latest):')
            pkg_ver = (v2 or '').strip().replace(' ','')
            apt_target = f'{pkg_name}={pkg_ver}' if pkg_ver else pkg_name
            cmd = (f'DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {apt_target} 2>&1'
                   f' || {{ apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends {apt_target}; }}')
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
                        _ubuntu_pkg_op('sdUbuntuPkg', f'Removing {pkg}', cmd)
                    break

def _ensure_ubuntu():
    """Install ubuntu base in a tmux session — services/ubuntu.py"""
    ok_f  = G.ubuntu_dir/'.ub_ok'
    fail_f= G.ubuntu_dir/'.ub_fail'
    ok_f.unlink(missing_ok=True); fail_f.unlink(missing_ok=True)
    ub = str(G.ubuntu_dir)
    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_ubsetup_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\nset -e\n')
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
        f.write(f'sudo -n chroot {ub!r} bash /tmp/.sd_ubinit.sh\n')
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
    log = G.tmp_dir/f'.sd_caddy_log_{os.getpid()}'
    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_caddy_inst_')
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\nset -uo pipefail\n')
        f.write(f'exec > >(tee -a {log!r}) 2>&1\n')
        f.write('printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"\n')
        f.write('case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l) ARCH=armv7;; *) ARCH=amd64;; esac\n')
        f.write('VER=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>/dev/null'
                '|tr -d \'\\n\'|grep -o \'"tag_name":"[^"]*"\'|cut -d: -f2|tr -d \'"v \')\n')
        f.write('[[ -z "$VER" ]] && VER="2.9.1"\n')
        f.write('TMPD=$(mktemp -d)\n')
        f.write('URL="https://github.com/caddyserver/caddy/releases/download/v${VER}/caddy_${VER}_linux_${ARCH}.tar.gz"\n')
        f.write('curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz" || { printf "Download failed\\n"; exit 1; }\n')
        f.write('tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy\n')
        f.write(f'mv "$TMPD/caddy" {caddy_dest!r}; chmod +x {caddy_dest!r}\n')
        f.write('rm -rf "$TMPD"\n')
        f.write(f'printf "%s ALL=(ALL) NOPASSWD: {caddy_dest}\\n" "$(id -un)" | sudo -n tee {_proxy_sudoers_path()!r} >/dev/null 2>/dev/null||true\n')
        f.write('sudo -n apt-get install -y avahi-utils 2>&1\n')
        f.write('printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"\n')
    os.chmod(runner.name, 0o755)
    sess = f'sdCaddyInst_{os.getpid()}'
    if tmux_up(sess): _tmux('kill-session','-t',sess)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    # wait with attach option
    _installing_wait_loop(sess, '/dev/null', '/dev/null', 'Install Caddy + mDNS')
    while tmux_up(sess): time.sleep(0.3)

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
            sel2 = fzf_run([f' {DIM}◈{NC}  {n}' for n in ctnames]+[_back_item()],
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
                            sel3=fzf_run([f' {DIM}◈{NC}  {n}' for n in ctnames2]+[_back_item()],
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
                       if re.match(r'^sd_[a-z0-9]{8}$|^sdInst_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$', s)]
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
        rows  = [_sep('Processes','38')] + display_lines + [_nav_sep(), _back_item()]
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

def resize_image():
    """image/btrfs.py — interactive resize"""
    if not G.img_path or not G.mnt_dir:
        pause('No image mounted.'); return
    r = _run(['df','-k',str(G.mnt_dir)], capture=True)
    if r.returncode == 0:
        parts = r.stdout.splitlines()[-1].split()
        total_kb = int(parts[1]); used_kb = int(parts[2])
        total_gb = total_kb/1048576; used_gb = used_kb/1048576
    else:
        total_gb = used_gb = 0
    cur_size_r = _run(['stat','--printf=%s',str(G.img_path)], capture=True)
    cur_gb = int(cur_size_r.stdout.strip())/(1<<30) if cur_size_r.returncode==0 else 0
    v = finput(f'Current size: {cur_gb:.1f} GB  (used: {used_gb:.1f} GB)\n\n  Enter new size in GB (must be larger):')
    if not v: return
    try: new_gb = int(v.strip())
    except: pause('Invalid size.'); return
    if new_gb <= cur_gb:
        pause(f'New size must be larger than current ({cur_gb:.0f} GB).'); return
    if not confirm(f'Resize image to {new_gb} GB?\n\n  This will briefly unmount and remount the image.'): return
    sess = 'sdResize'
    if tmux_up(sess): pause('A resize is already running.'); return
    runner = tempfile.NamedTemporaryFile(mode='w',dir=str(G.tmp_dir),
                                         suffix='.sh',delete=False,prefix='.sd_resize_')
    img = str(G.img_path); mnt = str(G.mnt_dir)
    is_luks = img_is_luks(G.img_path)
    mapper = luks_mapper(G.img_path) if is_luks else ''
    with open(runner.name,'w') as f:
        f.write('#!/usr/bin/env bash\nset -e\n')
        f.write(f'printf "Unmounting {mnt}...\\n"\n')
        f.write(f'sudo -n umount -lf {mnt!r}\n')
        if is_luks:
            f.write(f'sudo -n cryptsetup close {mapper!r} 2>/dev/null||true\n')
        f.write(f'_lo=$(sudo -n losetup -j {img!r} | cut -d: -f1 | head -1)\n')
        f.write('[ -n "$_lo" ] && sudo -n losetup -d "$_lo"\n')
        f.write(f'printf "Resizing {img} to {new_gb}G...\\n"\n')
        f.write(f'truncate -s {new_gb}G {img!r}\n')
        f.write('printf "Reattaching loop...\\n"\n')
        f.write(f'_lo2=$(sudo -n losetup --find --show {img!r})\n')
        if is_luks:
            f.write(f'sudo -n cryptsetup resize {mapper!r} --key-file=- <<< "{SD_DEFAULT_KEYWORD}" 2>/dev/null || true\n')
            f.write(f'_dev=/dev/mapper/{mapper}\n')
        else:
            f.write('_dev="$_lo2"\n')
        f.write(f'sudo -n mount -t btrfs "$_dev" {mnt!r}\n')
        f.write(f'sudo -n btrfs filesystem resize max {mnt!r}\n')
        f.write(f'printf "\\033[0;32m✓ Resize complete.\\033[0m\\n"\n')
    os.chmod(runner.name, 0o755)
    _tmux('new-session','-d','-s',sess,f'bash {runner.name!r}; rm -f {runner.name!r}')
    _tmux('set-option','-t',sess,'detach-on-destroy','off')
    _installing_wait_loop(sess, '/dev/null', '/dev/null', 'Resize image')
    while tmux_up(sess): time.sleep(0.3)
    # Re-init dirs after remount
    set_img_dirs()
    pause('Resize complete.')

# ══════════════════════════════════════════════════════════════════════════════
# menus/help.py — Other / help menu
# ══════════════════════════════════════════════════════════════════════════════

def help_menu():
    """menus/help.py — the Other / ? menu"""
    while True:
        ub_cache_read()
        if G.ubuntu_dir and (G.ubuntu_dir/'.ubuntu_ready').exists():
            ubuntu_status = f'{GRN}ready{NC}  {CYN}[P]{NC}'
            if G.ub_pkg_drift or G.ub_has_updates:
                ubuntu_status += f'  {YLW}Updates available{NC}'
        else:
            ubuntu_status = f'{YLW}not installed{NC}'
        proxy_s = f'{GRN}running{NC}' if proxy_running() else f'{DIM}stopped{NC}'
        # QRencode
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
            f' {CYN}◈{NC}{DIM}  Ubuntu base — {ubuntu_status}{NC}',
            f' {CYN}◈{NC}{DIM}  Caddy — {proxy_s}{NC}',
            f' {CYN}◈{NC}{DIM}  QRencode — {qr_s}{NC}',
            _sep('Tools'),
            f'{DIM} ◈  Active processes{NC}',
            f'{DIM} ◈  Resource limits{NC}',
            f'{DIM} ≡  Blueprint preset{NC}',
            _sep('Caution'),
            f'{DIM} ≡  View logs{NC}',
            f'{DIM} ⊘  Clear cache{NC}',
            f'{DIM} ↕  Resize image{NC}',
        ]
        if G.img_path and img_is_luks(G.img_path):
            items.append(f'{DIM} ⚷  Manage Encryption{NC}')
        items += [
            f'{DIM} ×  Delete image file{NC}',
            _nav_sep(), _back_item(),
        ]
        sel = fzf_run(items, header=f'{BLD}── {L["help"]} ──{NC}')
        if not sel or clean(sel) == L['back']:
            if G.usr1_fired: G.usr1_fired = False; continue
            return
        sc = clean(sel)
        if   'Profiles & data' in sc:  persistent_storage_menu()
        elif 'Backups' in sc:          _global_backups_menu()
        elif sc == 'Blueprints':       blueprints_submenu()
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
            if confirm('Clear size/version cache?\n\n  This is harmless; caches will rebuild automatically.'):
                shutil.rmtree(str(G.cache_dir), ignore_errors=True)
                G.cache_dir.mkdir(parents=True, exist_ok=True)
                pause('Cache cleared.')
        elif 'Resize image' in sc:     resize_image()
        elif 'Manage Encryption' in sc:
            if G.img_path and img_is_luks(G.img_path): enc_menu()
            else: pause('Image is not encrypted.')
        elif 'Delete image file' in sc:
            if confirm(f'⚠  Permanently delete {G.img_path}?\n\n  This removes ALL data — containers, installations, storage.\n  This cannot be undone.'):
                if confirm('SECOND CONFIRMATION — are you absolutely sure?'):
                    img = G.img_path
                    unmount_img()
                    try: img.unlink()
                    except Exception as e: pause(f'Failed: {e}'); continue
                    pause(f'Image deleted. Exiting.')
                    sys.exit(0)

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
    sel = fzf_run([f'{DIM}{L["detach"]}{NC}', f'{RED}{L["quit_stop_all"]}{NC}'],
                  header=f'{BLD}── {L["quit"]} ──{NC}')
    if not sel: return
    sc = strip_ansi(sel).strip()
    if L['detach'] in sc or '⊙' in sc:
        tmux_set('SD_DETACH','1'); _tmux('detach-client')
    elif L['quit_stop_all'] in sc or '■' in sc:
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
        n_grp = len(_list_groups())
        n_bp  = len(_list_blueprint_names()) + len(_list_persistent_names()) + len(_list_imported_names())
        # Image label
        img_label = ''
        if G.img_path and G.mnt_dir:
            r = _run(['df','-k',str(G.mnt_dir)], capture=True)
            if r.returncode == 0:
                parts = r.stdout.splitlines()[-1].split()
                used_gb = int(parts[2])/1048576; total_gb = int(parts[1])/1048576
                img_label = f'  {DIM}{G.img_path.stem}  [{used_gb:.1f}/{total_gb:.1f} GB]{NC}'
        items = [
            f' {GRN}◈{NC}  Containers  {DIM}[{n_ct} · {GRN}{n_running} ▶{NC}{DIM}]{NC}',
            f' {CYN}▶{NC}  Groups  {DIM}[{n_grp} active]{NC}',
            f' {BLU}◈{NC}  Blueprints  {DIM}[{n_bp}]{NC}',
            f'{DIM}─────────────────────────────────────────{NC}',
            f' {DIM}?  {L["help"]}{NC}',
            f' {RED}×  {L["quit"]}{NC}',
        ]
        hdr = f'{BLD}── {L["title"]} ──{NC}{img_label}'
        sel = fzf_run(items, header=hdr, extra=[
            f'--bind={KB["quit"]}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort',
        ])
        if sel is None:
            if tmux_get('SD_QUIT') == '1':
                tmux_set('SD_QUIT','0'); quit_menu(); continue
            quit_all()
            continue
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
    Inner process detected via SD_INNER=1 env var — returns immediately."""
    if os.environ.get('SD_INNER') == '1':
        return  # inner process — skip outer bootstrap
    me = os.path.abspath(sys.argv[0])
    if not shutil.which('tmux'):
        print(f'{RED}✗  tmux is required but not found.{NC}'); sys.exit(1)
    # Write sudoers only once (outer shell has a real tty for password prompt)
    sudoers = f'/etc/sudoers.d/simpledocker_{os.popen("id -un").read().strip()}'
    if not os.path.exists(sudoers):
        write_sudoers()
    sess = 'simpleDocker'
    # Kill any existing simpleDocker session — this ensures a clean startup each time.
    # The inner process (SD_INNER=1) does cleanup via signal handlers; killing the session
    # here lets sweep_stale (run inside the new inner process) reclaim stale mounts.
    if tmux_up(sess):
        # If the session is ready, give it a moment to unmount cleanly via kill-session
        subprocess.run(['tmux','kill-session','-t',sess], capture_output=True)
        time.sleep(0.5)
    # Create new session
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
        # Flush any remaining terminal input (mirrors bash drain loop)
        try:
            import termios, tty
            old = termios.tcgetattr(sys.stdin.fileno())
            tty.setraw(sys.stdin.fileno())
            termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, old)
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
    # ── Dep check ──────────────────────────────────────────────────────────────
    if not check_deps('no'):
        print(f'\n{RED}Missing dependencies:{NC}')
        missing = [t for t in REQUIRED_TOOLS if not shutil.which(t)]
        for m in missing: print(f'  ✗  {m}')
        print(f'\nInstall with:\n  sudo apt-get install {" ".join(missing)}')
        sys.exit(1)

    _check_btrfs_kernel()
    _init_g()

    # ── Bootstrap into tmux session ────────────────────────────────────────────
    _bootstrap_tmux()

    # ── Inside the simpleDocker tmux session from here ─────────────────────────
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