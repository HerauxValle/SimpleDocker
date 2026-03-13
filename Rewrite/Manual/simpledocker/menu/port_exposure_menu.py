"""Standalone port exposure menu."""
from __future__ import annotations
from pathlib import Path

from functions.constants import FZF_BASE, L, BLD, DIM, NC, GRN, RED, YLW
from functions.tui import fzf, pause, sig_rc, strip_ansi
from functions.container import load_containers
from functions.network import exposure_get, exposure_next, exposure_set, exposure_label, exposure_apply
from functions.utils import tmux_up
from functions.container import tsess


def port_exposure_menu(ctx):
    while True:
        ids, names, sjs = load_containers(ctx.containers_dir, False)
        lines=[f"{BLD}  ── Containers ───────────────────────{NC}"]
        cids=[]; cnames=[]
        for i, cid in enumerate(ids):
            sj=sjs[i] if i<len(sjs) else {}
            installed=str(sj.get("state",{}).get("installed","")).lower()=="true"
            if not installed: continue
            port=(sj.get("environment",{}).get("PORT","") or sj.get("meta",{}).get("port","") or "")
            if not port or str(port)=="0": continue
            mode=exposure_get(ctx.containers_dir, cid)
            lines.append(f" {exposure_label(mode)}  {names[i]} {DIM}({port}){NC}")
            cids.append(cid); cnames.append(names[i])
        if not cids: lines.append(f"{DIM}  (no installed containers with ports){NC}")
        lines+=[f"{BLD}  ── Navigation ───────────────────────{NC}", f"{DIM} {L['back']}{NC}"]

        rc,sl=fzf(lines,
                  "--header",f"{BLD}── Port Exposure ──{NC}\n{DIM}  Enter to cycle: isolated → localhost → public{NC}")
        if sig_rc(rc): continue
        if rc!=0 or not sl: return
        sel=sl[0].strip()
        if L["back"] in sel: return

        clean=strip_ansi(sel).strip()
        for i,cname_ in enumerate(cnames):
            if cname_ not in clean: continue
            cid=cids[i]; new=exposure_next(ctx.containers_dir, cid)
            exposure_set(ctx.containers_dir, cid, new)
            if tmux_up(tsess(cid)): exposure_apply(cid, ctx.mnt_dir)
            pause(f"Port exposure set to: {exposure_label(new)}\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network")
            break
