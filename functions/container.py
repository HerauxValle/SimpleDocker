"""
container.py — Container lifecycle: load, start, stop, install, cron, backup, storage, groups
"""

import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path

from .constants import (
    TMP_DIR, SD_MNT_BASE, GRN, RED, YLW, BLD, DIM, NC,
    SD_SECCOMP_BLOCKLIST, SD_CAP_DROP_DEFAULT, DEFAULT_UBUNTU_PKGS,
)
from .utils import (
    run, run_out, sudo_run, sudo_out,
    tmux_get, tmux_set, tmux_up, tsess, inst_sess, cron_sess,
    state_get, state_set, read_json, write_json,
    rand_id, make_tmp, current_user, sha256_file, log_path,
)
from .blueprint import compile_service, cr_prefix, ensure_src
from .network import (
    netns_ct_add, netns_ct_del, netns_ct_ip,
    exposure_apply, exposure_file, exposure_get, exposure_set,
)


# ── Container state helpers ───────────────────────────────────────────────

def cname(containers_dir: str, cid: str) -> str:
    return state_get(containers_dir, cid, "name", f"(unnamed-{cid})")


def cpath(containers_dir: str, installations_dir: str, cid: str) -> str:
    rel = state_get(containers_dir, cid, "install_path", "")
    if rel:
        return os.path.join(installations_dir, rel)
    return ""


def load_containers(containers_dir: str, show_hidden: bool = False) -> tuple:
    """Returns (ids: list, names: list, service_jsons: list).
    service_jsons[i] is the merged dict from service.json for ids[i].
    """
    ids, names, sjs = [], [], []
    if not os.path.isdir(containers_dir):
        return ids, names, sjs
    for entry in sorted(os.listdir(containers_dir)):
        d = os.path.join(containers_dir, entry)
        sj_path = os.path.join(d, "service.json")
        st_path = os.path.join(d, "state.json")
        if not os.path.isfile(st_path):
            continue
        state = read_json(st_path)
        if not show_hidden and state.get("hidden", False):
            continue
        sj = read_json(sj_path) if os.path.isfile(sj_path) else {}
        # Merge state into sj for convenience
        sj.setdefault("state", {}).update(state)
        n = (sj.get("meta", {}).get("name")
             or state.get("name")
             or f"(unnamed-{entry})")
        ids.append(entry)
        names.append(n)
        sjs.append(sj)
    return ids, names, sjs


def validate_containers(containers_dir: str, installations_dir: str):
    if not os.path.isdir(containers_dir):
        return
    for cid in os.listdir(containers_dir):
        if state_get(containers_dir, cid, "installed") != "true":
            continue
        ip = cpath(containers_dir, installations_dir, cid)
        if not (ip and os.path.isdir(ip)):
            state_set(containers_dir, cid, "installed", False)


def is_installing(cid: str) -> bool:
    return tmux_up(inst_sess(cid))


def installing_id() -> str:
    return tmux_get("SD_INSTALLING")


def cleanup_stale_lock():
    cur = installing_id()
    if not cur:
        return
    if tmux_up(inst_sess(cur)):
        return
    tmux_set("SD_INSTALLING", "")


# ── Health check ─────────────────────────────────────────────────────────

def health_check(containers_dir: str, cid: str) -> bool:
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    if not data:
        return False
    if str(data.get("meta", {}).get("health", "")).lower() != "true":
        return False
    port = str(data.get("meta", {}).get("port", "") or "")
    if not port or port == "0":
        return False
    r = subprocess.run(["nc", "-z", "-w1", "127.0.0.1", port],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return r.returncode == 0


# ── Size cache ────────────────────────────────────────────────────────────

def update_size_cache(cid: str, install_path: str, cache_dir: str):
    def _do():
        if not install_path or not os.path.isdir(install_path):
            return
        cache_f = os.path.join(cache_dir, "sd_size", cid)
        os.makedirs(os.path.dirname(cache_f), exist_ok=True)
        try:
            total = sum(
                f.stat().st_size
                for f in Path(install_path).rglob('*')
                if f.is_file()
            )
            with open(cache_f + ".tmp", "w") as fp:
                fp.write(f"{total / 1073741824:.2f}")
            os.replace(cache_f + ".tmp", cache_f)
        except Exception:
            pass
    threading.Thread(target=_do, daemon=True).start()


# ── env_exports (generates bash env block for install/start scripts) ──────

def env_exports(containers_dir: str, cid: str, install_path: str) -> str:
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    env  = data.get("environment", {})
    gpu  = data.get("meta", {}).get("gpu", "")

    lines = []
    lines.append(f"export CONTAINER_ROOT={_shquote(install_path)}")
    lines.append(r"""export HOME="$CONTAINER_ROOT"
export XDG_CACHE_HOME="$CONTAINER_ROOT/.cache"
export XDG_CONFIG_HOME="$CONTAINER_ROOT/.config"
export XDG_DATA_HOME="$CONTAINER_ROOT/.local/share"
export XDG_STATE_HOME="$CONTAINER_ROOT/.local/state"
export PATH="$CONTAINER_ROOT/venv/bin:$CONTAINER_ROOT/python/bin:$CONTAINER_ROOT/.local/bin:$CONTAINER_ROOT/bin:$PATH"
export PYTHONNOUSERSITE=1 PIP_USER=false VIRTUAL_ENV="$CONTAINER_ROOT/venv"
_sd_vsp=$(compgen -G "$CONTAINER_ROOT/venv/lib/python*/site-packages" 2>/dev/null | head -1) || true
[[ -n "$_sd_vsp" ]] && export PYTHONPATH="$_sd_vsp${PYTHONPATH:+:$PYTHONPATH}"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" \
         "$CONTAINER_ROOT/.local/bin" 2>/dev/null
[[ ! -e "$CONTAINER_ROOT/bin" ]] && mkdir -p "$CONTAINER_ROOT/bin" 2>/dev/null || true""")

    if gpu in ("cuda_auto", "auto"):
        lines.append(r"""if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
    export NVIDIA_GPU=1 CUDA_VISIBLE_DEVICES="${CUDA_VISIBLE_DEVICES:-0}"
    printf '[gpu] CUDA mode\n'
else
    printf '[gpu] CPU mode\n'
fi""")

    for k, v in env.items():
        pv = v
        if v == "generate:hex32":
            pv = '$(openssl rand -hex 32 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d - || echo "changeme_set_secret")'
        else:
            pv = cr_prefix(str(v))
        if k in ("LD_LIBRARY_PATH", "LIBRARY_PATH", "PKG_CONFIG_PATH"):
            lines.append(f'export {k}="{pv}:${{{k}:-}}"')
        else:
            lines.append(f'export {k}="{pv}"')

    return "\n".join(lines)


def _shquote(s: str) -> str:
    import shlex
    return shlex.quote(s)


# ── Build start script ────────────────────────────────────────────────────

def build_start_script(containers_dir: str, installations_dir: str, cid: str):
    """Write start.sh into the container's install path."""
    ip   = cpath(containers_dir, installations_dir, cid)
    if not ip:
        return
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    meta = data.get("meta", {})

    start_block = data.get("start", "").strip()
    entrypoint  = meta.get("entrypoint", "").strip()
    cron_list   = data.get("crons", [])

    env_block = env_exports(containers_dir, cid, ip)

    lines = ["#!/usr/bin/env bash", "set -e", "", env_block, "", 'cd "$CONTAINER_ROOT"', ""]

    # chroot_bash helper
    lines.append(r"""_chroot_bash() {
    local r=$1; shift; local b=/bin/bash
    [[ ! -e "$r/bin/bash" && -e "$r/usr/bin/bash" ]] && b=/usr/bin/bash
    [[ ! -e "$r$b" ]] && b=/bin/sh
    sudo -n chroot "$r" "$b" "$@"
}""")

    if start_block:
        lines.append(start_block)
    elif entrypoint:
        lines.append(_build_entrypoint_cmd(entrypoint, meta))

    script_path = os.path.join(ip, "start.sh")
    with open(script_path, "w") as fp:
        fp.write("\n".join(lines) + "\n")
    os.chmod(script_path, 0o755)


def _build_entrypoint_cmd(entrypoint: str, meta: dict) -> str:
    """Build the exec line for start.sh from entrypoint."""
    # Namespace / chroot wrapping
    use_chroot = meta.get("chroot", "true").lower() != "false"
    cmd = entrypoint
    if use_chroot:
        cmd = f'sudo -n nsenter --mount --uts --ipc --net --pid --root="$CONTAINER_ROOT" -- bash -c {_shquote(cmd)}'
    return cmd


# ── Start / stop container ────────────────────────────────────────────────

def start_container(
    cid: str, containers_dir: str, installations_dir: str, mnt_dir: str,
    attach: str = "background", scid: str = ""
) -> bool:
    ip   = cpath(containers_dir, installations_dir, cid)
    sess = tsess(cid)

    if not ip or not os.path.isdir(ip):
        return False

    # Storage
    from .storage import (
        stor_count, auto_pick_storage_profile,
        stor_unlink, stor_link, stor_clear_active,
    )
    if stor_count(containers_dir, cid) > 0:
        prev_scid = state_get(containers_dir, cid, "storage_id", "")
        if prev_scid:
            stor_clear_active(containers_dir, mnt_dir, prev_scid)
        stor_unlink(containers_dir, cid, ip)
        if not scid:
            scid = auto_pick_storage_profile(cid, containers_dir, mnt_dir)
        if not scid:
            return False
        stor_link(containers_dir, cid, ip, scid, mnt_dir)

    # Snapshot
    rotate_and_snapshot(cid, containers_dir, installations_dir)
    build_start_script(containers_dir, installations_dir, cid)
    ct_name = cname(containers_dir, cid)
    netns_ct_add(cid, ct_name, mnt_dir)

    # Default exposure from service.json HOST env
    if not os.path.isfile(exposure_file(containers_dir, cid)):
        sj = os.path.join(containers_dir, cid, "service.json")
        data = read_json(sj)
        host_env = data.get("environment", {}).get("HOST", "")
        if host_env == "0.0.0.0":
            exposure_set(containers_dir, cid, "public")
        elif host_env in ("127.0.0.1", "localhost"):
            exposure_set(containers_dir, cid, "localhost")

    exposure_apply(cid, containers_dir, mnt_dir)

    base_cmd = f"cd {_shquote(ip)} && bash {_shquote(os.path.join(ip, 'start.sh'))}"

    # Resource limits
    res_cfg = os.path.join(containers_dir, cid, "resources.json")
    res = read_json(res_cfg)
    if res and res.get("enabled") is True:
        run_prefix = f"systemd-run --user --scope --unit=sd-{cid}"
        if res.get("cpu_quota"):  run_prefix += f" -p CPUQuota={res['cpu_quota']}"
        if res.get("mem_max"):    run_prefix += f" -p MemoryMax={res['mem_max']}"
        if res.get("mem_swap"):   run_prefix += f" -p MemorySwapMax={res['mem_swap']}"
        if res.get("cpu_weight"): run_prefix += f" -p CPUWeight={res['cpu_weight']}"
        run_prefix += " -- bash -c"
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", sess,
             f"{run_prefix} {_shquote(base_cmd)}"],
            stderr=subprocess.DEVNULL
        )
    else:
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", sess, base_cmd],
            stderr=subprocess.DEVNULL
        )

    subprocess.run(["tmux", "set-option", "-t", sess, "detach-on-destroy", "off"],
                   stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "set-hook", "-t", sess, "pane-exited",
                    f"kill-session -t {sess}"],
                   stderr=subprocess.DEVNULL)

    # Background watcher — sends SIGUSR1 when container exits
    import os as _os
    main_pid = _os.getpid()

    def _watcher():
        while tmux_up(sess):
            time.sleep(0.5)
        try:
            _os.kill(main_pid, _os.SIGUSR1 if hasattr(_os, 'SIGUSR1') else 10)
        except Exception:
            pass

    threading.Thread(target=_watcher, daemon=True).start()

    cron_start_all(cid, containers_dir, ip)

    # Apply seccomp/cap_drop after 2s in background
    def _apply_security():
        time.sleep(2)
        cap_drop_apply(cid, containers_dir)
        seccomp_apply(cid, containers_dir)

    threading.Thread(target=_apply_security, daemon=True).start()
    time.sleep(0.5)

    if attach == "attach":
        subprocess.run(["tmux", "switch-client", "-t", sess],
                       stderr=subprocess.DEVNULL)
        time.sleep(0.1)
        subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)

    return True


def stop_container(cid: str, containers_dir: str, installations_dir: str, mnt_dir: str, cache_dir: str):
    sess = tsess(cid)
    ip   = cpath(containers_dir, installations_dir, cid)
    ct_name = cname(containers_dir, cid)

    subprocess.run(["tmux", "send-keys", "-t", sess, "C-c", ""],
                   stderr=subprocess.DEVNULL)
    for _ in range(40):
        if not tmux_up(sess):
            break
        time.sleep(0.2)
    subprocess.run(["tmux", "kill-session", "-t", sess], stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "kill-session", "-t", f"sdTerm_{cid}"], stderr=subprocess.DEVNULL)

    netns_ct_del(cid, ct_name, mnt_dir, containers_dir)

    # Kill action sessions
    r = subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for s in r.stdout.decode().splitlines():
        if s.startswith(f"sdAction_{cid}_"):
            subprocess.run(["tmux", "kill-session", "-t", s], stderr=subprocess.DEVNULL)

    cron_stop_all(cid, containers_dir)
    time.sleep(0.2)

    from .storage import stor_count, stor_unlink, stor_clear_active
    if stor_count(containers_dir, cid) > 0 and ip:
        stor_unlink(containers_dir, cid, ip)
        scid = state_get(containers_dir, cid, "storage_id", "")
        if scid:
            stor_clear_active(containers_dir, mnt_dir, scid)

    update_size_cache(cid, ip or "", cache_dir)


# ── Security: cap_drop, seccomp ───────────────────────────────────────────

def cap_drop_enabled(containers_dir: str, cid: str) -> bool:
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    return str(data.get("meta", {}).get("cap_drop", "true")).lower() != "false"


def cap_drop_apply(cid: str, containers_dir: str):
    if not cap_drop_enabled(containers_dir, cid):
        return
    if not shutil.which("capsh"):
        return
    sess = tsess(cid)
    r = subprocess.run(["tmux", "list-panes", "-t", sess, "-F", "#{pane_pid}"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    pane_pid = r.stdout.decode().strip().splitlines()[0] if r.returncode == 0 else ""
    if not pane_pid:
        return
    r2 = subprocess.run(["pgrep", "-P", pane_pid], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    for cpid in r2.stdout.decode().split():
        sudo_run(["capsh", f"--drop={SD_CAP_DROP_DEFAULT}", f"--pid={cpid}"])


def seccomp_enabled(containers_dir: str, cid: str) -> bool:
    sj = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    return str(data.get("meta", {}).get("seccomp", "true")).lower() != "false"


def seccomp_apply(cid: str, containers_dir: str):
    if not seccomp_enabled(containers_dir, cid):
        return
    profile_file = os.path.join(containers_dir, cid, ".seccomp_profile.json")
    if not os.path.isfile(profile_file):
        syscalls = [{"names": SD_SECCOMP_BLOCKLIST, "action": "SCMP_ACT_ERRNO"}]
        profile = {"defaultAction": "SCMP_ACT_ALLOW", "syscalls": syscalls}
        write_json(profile_file, profile)


# ── Cron ─────────────────────────────────────────────────────────────────

def cron_interval_secs(interval: str) -> int:
    m = re.match(r'^(\d+)(s|m|h)$', interval.strip())
    if not m:
        return 300
    n, unit = int(m.group(1)), m.group(2)
    return n * {"s": 1, "m": 60, "h": 3600}[unit]


def cron_next_file(containers_dir: str, cid: str, idx) -> str:
    return os.path.join(containers_dir, cid, f"cron_{idx}_next")


def cron_start_one(cid: str, containers_dir: str, install_path: str, idx: int, entry: dict):
    sess = cron_sess(cid, idx)
    if tmux_up(sess):
        return
    interval  = entry.get("interval", "5m")
    cmd       = entry.get("cmd", "")
    flags     = entry.get("flags", "")
    name      = entry.get("name", f"cron_{idx}")
    secs      = cron_interval_secs(interval)
    unjailed  = "--unjailed" in flags
    use_sudo  = "--sudo" in flags

    env_block = env_exports(containers_dir, cid, install_path)
    next_f    = cron_next_file(containers_dir, cid, idx)

    # Build cron runner script
    runner = make_tmp(f".sd_cron_{cid}_{idx}_")
    with open(runner, "w") as fp:
        fp.write("#!/usr/bin/env bash\n")
        if not unjailed:
            fp.write(env_block + "\n")
            fp.write('cd "$CONTAINER_ROOT"\n')
        fp.write(f"""
_cron_loop() {{
    while true; do
        printf '%s' "$(( $(date +%s) + {secs} ))" > {_shquote(next_f)}
        if {('sudo ' if use_sudo else '') + cmd}; then :; fi
        sleep {secs}
    done
}}
_cron_loop
""")
    os.chmod(runner, 0o755)

    subprocess.run(
        ["tmux", "new-session", "-d", "-s", sess, f"bash {_shquote(runner)}"],
        stderr=subprocess.DEVNULL
    )


def cron_start_all(cid: str, containers_dir: str, install_path: str):
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    for i, entry in enumerate(data.get("crons", [])):
        cron_start_one(cid, containers_dir, install_path, i, entry)


def cron_stop_all(cid: str, containers_dir: str):
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    for i in range(len(data.get("crons", []))):
        sess = cron_sess(cid, i)
        subprocess.run(["tmux", "kill-session", "-t", sess], stderr=subprocess.DEVNULL)
        try:
            os.unlink(cron_next_file(containers_dir, cid, i))
        except Exception:
            pass


def cron_countdown(containers_dir: str, cid: str, idx: int) -> str:
    """Return human-readable time until next cron run."""
    nf = cron_next_file(containers_dir, cid, idx)
    try:
        nxt = int(open(nf).read().strip())
        remaining = nxt - int(time.time())
        if remaining <= 0:
            return "now"
        if remaining < 60:
            return f"{remaining}s"
        return f"{remaining // 60}m{remaining % 60}s"
    except Exception:
        return "?"


# ── Snapshots / backups ───────────────────────────────────────────────────

def snap_dir(backup_dir: str, cid: str, ct_name: str) -> str:
    return os.path.join(backup_dir, ct_name)


def rand_snap_id() -> str:
    import random, string
    return "".join(random.choices(string.ascii_lowercase + string.digits, k=12))


def snap_meta_get(snap_path: str, key: str) -> str:
    meta_f = snap_path + ".meta"
    if not os.path.isfile(meta_f):
        return ""
    for line in open(meta_f):
        if line.startswith(f"{key}="):
            return line.split("=", 1)[1].rstrip()
    return ""


def snap_meta_set(snap_path: str, **kv):
    meta_f = snap_path + ".meta"
    lines = {}
    if os.path.isfile(meta_f):
        for line in open(meta_f):
            if "=" in line:
                k, _, v = line.partition("=")
                lines[k.strip()] = v.rstrip()
    lines.update({str(k): str(v) for k, v in kv.items()})
    with open(meta_f, "w") as fp:
        for k, v in lines.items():
            fp.write(f"{k}={v}\n")


def delete_snap(snap_path: str):
    r = sudo_run(["btrfs", "subvolume", "delete", snap_path])
    if r.returncode != 0:
        shutil.rmtree(snap_path, ignore_errors=True)


def rotate_and_snapshot(cid: str, containers_dir: str, installations_dir: str):
    ip = cpath(containers_dir, installations_dir, cid)
    if not ip or not os.path.isdir(ip):
        return
    ct_name = cname(containers_dir, cid)
    bd  = snap_dir(os.path.join(installations_dir, "..", "Backup"), cid, ct_name)
    os.makedirs(bd, exist_ok=True)
    snap_id = rand_snap_id()
    snap_path = os.path.join(bd, snap_id)
    r = sudo_run(["btrfs", "subvolume", "snapshot", "-r", ip, snap_path])
    if r.returncode != 0:
        return
    snap_meta_set(snap_path,
                  created=str(int(time.time())),
                  label="auto",
                  source=ip)
    # Rotate: keep max 5 auto snaps
    all_snaps = sorted([
        os.path.join(bd, d) for d in os.listdir(bd)
        if os.path.isdir(os.path.join(bd, d))
        and snap_meta_get(os.path.join(bd, d), "label") == "auto"
    ], key=lambda p: snap_meta_get(p, "created"))
    while len(all_snaps) > 5:
        oldest = all_snaps.pop(0)
        delete_snap(oldest)
        meta_f = oldest + ".meta"
        try:
            os.unlink(meta_f)
        except Exception:
            pass


# ── Groups ────────────────────────────────────────────────────────────────

def grp_path(groups_dir: str, gid: str) -> str:
    return os.path.join(groups_dir, f"{gid}.toml")


def list_groups(groups_dir: str) -> list:
    if not os.path.isdir(groups_dir):
        return []
    return [
        f[:-5] for f in sorted(os.listdir(groups_dir))
        if f.endswith(".toml")
    ]


def grp_read_field(groups_dir: str, gid: str, field: str) -> str:
    p = grp_path(groups_dir, gid)
    if not os.path.isfile(p):
        return ""
    for line in open(p):
        m = re.match(rf'^{re.escape(field)}\s*=\s*(.*)', line)
        if m:
            return m.group(1).strip()
    return ""


def grp_containers(groups_dir: str, gid: str) -> list:
    raw = grp_read_field(groups_dir, gid, "start")
    raw = raw.strip("{}")
    names = [n.strip() for n in raw.split(",") if n.strip()]
    names = [n for n in names if n.lower() != "wait"]
    return sorted(set(names))


def grp_seq_steps(groups_dir: str, gid: str) -> list:
    """Return ordered start steps including wait tokens."""
    raw = grp_read_field(groups_dir, gid, "start")
    raw = raw.strip("{}")
    return [s.strip() for s in raw.split(",") if s.strip()]


def ct_id_by_name(containers_dir: str, name: str) -> str:
    ids, names = load_containers(containers_dir)
    for cid, n in zip(ids, names):
        if n == name:
            return cid
    return ""


def start_group(gid: str, groups_dir: str, containers_dir: str,
                installations_dir: str, mnt_dir: str):
    steps = grp_seq_steps(groups_dir, gid)
    for step in steps:
        if step.lower().startswith("wait"):
            m = re.search(r'\d+', step)
            secs = int(m.group()) if m else 3
            time.sleep(secs)
            continue
        cid = ct_id_by_name(containers_dir, step)
        if cid and not tmux_up(tsess(cid)):
            start_container(cid, containers_dir, installations_dir, mnt_dir)


def stop_group(gid: str, groups_dir: str, containers_dir: str,
               installations_dir: str, mnt_dir: str, cache_dir: str):
    for name in grp_containers(groups_dir, gid):
        cid = ct_id_by_name(containers_dir, name)
        if cid and tmux_up(tsess(cid)):
            stop_container(cid, containers_dir, installations_dir, mnt_dir, cache_dir)


# ── install / update job ──────────────────────────────────────────────────
# See functions/installer.py for the full _run_job implementation
