"""menu/resources_menu.py — CPU/memory resource limits via cgroups. Matches bash _resources_menu 1:1."""
import os, json, subprocess
from functions.constants import GRN, RED, CYN, BLD, DIM, NC, L, FZF_BASE
from functions.tui import confirm, pause, finput
from functions.utils import trim_s, strip_ansi, make_tmp, read_json, write_json
from functions.container import load_containers, cname as ct_cname
import functions.tui as _tui


def _fzf_raw(items, *extra_args):
    out_f = make_tmp(".sd_res_fzf_")
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


def _res_cfg(containers_dir, cid):
    return os.path.join(containers_dir, cid, "resources.json")

def _res_get(containers_dir, cid, key):
    d = read_json(_res_cfg(containers_dir, cid)) or {}
    return d.get(key, "")

def _res_set(containers_dir, cid, key, val):
    cfg = _res_cfg(containers_dir, cid)
    d = read_json(cfg) or {}
    d[key] = val
    write_json(cfg, d)

def _res_del(containers_dir, cid, key):
    cfg = _res_cfg(containers_dir, cid)
    d = read_json(cfg) or {}
    d.pop(key, None)
    write_json(cfg, d)


def resources_menu_global(ctx):
    """Global resources menu — pick a container then edit its limits."""
    ids, names, _ = load_containers(ctx.containers_dir)
    if not ids:
        pause("No containers found.")
        return

    lines = [f"{BLD}  ── Containers ───────────────────────{NC}"]
    for cid, name in zip(ids, names):
        rs = ""
        enabled = _res_get(ctx.containers_dir, cid, "enabled")
        if str(enabled).lower() == "true":
            rs = f"  {GRN}[cgroups on]{NC}"
        lines.append(f" {DIM}◈{NC}  {name}{rs}")
    lines.append(f"{BLD}  ── Navigation ───────────────────────{NC}")
    lines.append(f"{DIM} {L['back']}{NC}")

    rc, sel = _fzf_raw(
        lines,
        f"--header={BLD}── Resource limits ──{NC}  {DIM}[{len(ids)} containers]{NC}"
    )
    if rc != 0 or not sel:
        return
    clean = strip_ansi(trim_s(sel)).strip()
    if clean == L["back"] or clean.startswith("──") or not clean:
        return

    sel_name = clean.replace("◈", "").replace("[cgroups on]", "").strip().split()[0]
    cid = ""
    for c, n in zip(ids, names):
        if n == sel_name:
            cid = c
            break
    if not cid:
        return
    resources_submenu(cid, ctx.containers_dir)


def resources_submenu(cid, containers_dir):
    """Per-container resource limits editor."""
    cfg = _res_cfg(containers_dir, cid)
    if not os.path.isfile(cfg):
        write_json(cfg, {"enabled": False})

    name = ct_cname(containers_dir, cid)

    while True:
        enabled    = str(_res_get(containers_dir, cid, "enabled")).lower() == "true"
        cpu_quota  = _res_get(containers_dir, cid, "cpu_quota")  or "(unlimited)"
        mem_max    = _res_get(containers_dir, cid, "mem_max")    or "(unlimited)"
        mem_swap   = _res_get(containers_dir, cid, "mem_swap")   or "(unlimited)"
        cpu_weight = _res_get(containers_dir, cid, "cpu_weight") or "(default 100)"

        tog = f"{GRN}● Enabled{NC}" if enabled else f"{RED}○ Disabled{NC}"

        lines = [
            f"{BLD}  ── Configuration ────────────────────{NC}",
            f" {tog}  — toggle cgroups on/off (applies on next start)",
            f"  CPU quota    {CYN}{cpu_quota}{NC}  — e.g. 200% = 2 cores",
            f"  Memory max   {CYN}{mem_max}{NC}  — e.g. 8G, 512M",
            f"  Memory+swap  {CYN}{mem_swap}{NC}  — e.g. 10G",
            f"  CPU weight   {CYN}{cpu_weight}{NC}  — 1-10000, default=100 (relative priority)",
            f"{BLD}  ── Info ──────────────────────────────{NC}",
            f"  {DIM}GPU/VRAM{NC}     not configurable via cgroups (planned separately)",
            f"  {DIM}Network{NC}      not configurable via cgroups (planned separately)",
            f"{BLD}  ── Navigation ───────────────────────{NC}",
            f"{DIM} {L['back']}{NC}",
        ]

        hdr = (f"{BLD}── Resources: {name} ──{NC}\n"
               f"{DIM}  Limits apply on container restart via systemd cgroups.{NC}")
        rc, sel = _fzf_raw(lines, f"--header={hdr}")
        if rc != 0 or not sel:
            return
        sc = strip_ansi(trim_s(sel)).strip()
        if sc == L["back"] or not sc:
            return

        if "toggle" in sc:
            _res_set(containers_dir, cid, "enabled", not enabled)
        elif "CPU quota" in sc:
            if not finput("CPU quota (e.g. 200% = 2 cores, blank = remove limit):"):
                continue
            v = _tui.FINPUT_RESULT.strip()
            if not v: _res_del(containers_dir, cid, "cpu_quota")
            else:     _res_set(containers_dir, cid, "cpu_quota", v)
        elif "Memory max" in sc:
            if not finput("Memory max (e.g. 8G, 512M, blank = remove limit):"):
                continue
            v = _tui.FINPUT_RESULT.strip()
            if not v: _res_del(containers_dir, cid, "mem_max")
            else:     _res_set(containers_dir, cid, "mem_max", v)
        elif "Memory+swap" in sc:
            if not finput("Memory+swap max (e.g. 10G, blank = remove limit):"):
                continue
            v = _tui.FINPUT_RESULT.strip()
            if not v: _res_del(containers_dir, cid, "mem_swap")
            else:     _res_set(containers_dir, cid, "mem_swap", v)
        elif "CPU weight" in sc:
            if not finput("CPU weight (1-10000, blank = default 100):"):
                continue
            v = _tui.FINPUT_RESULT.strip()
            if not v: _res_del(containers_dir, cid, "cpu_weight")
            else:     _res_set(containers_dir, cid, "cpu_weight", v)


resources_menu = resources_menu_global

