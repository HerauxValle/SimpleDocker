"""
menu/group_menu.py — Group management menu
Matches services.sh _group_submenu visually and functionally 1:1.
"""

import os
import re
import subprocess
import time

from functions.constants import GRN, RED, YLW, BLU, BLD, DIM, NC, L, FZF_BASE, TMP_DIR
from functions.tui import confirm, pause, finput
from functions.utils import (
    trim_s, strip_ansi, tmux_up, tsess, make_tmp,
)
from functions.container import (
    cname as ct_cname, load_containers,
    start_group, stop_group,
    grp_containers, grp_path, grp_read_field, grp_seq_steps,
)
import functions.tui as _tui


def _fzf_raw(items, *extra_args):
    out_f = make_tmp(".sd_grp_fzf_")
    try:
        proc = subprocess.Popen(
            ["fzf"] + list(FZF_BASE) + list(extra_args),
            stdin=subprocess.PIPE,
            stdout=open(out_f, "wb"),
        )
        proc.stdin.write("\n".join(items).encode())
        proc.stdin.close()
        rc = proc.wait()
        try:
            sel = open(out_f).read().strip()
        except Exception:
            sel = ""
        return rc, sel
    finally:
        try:
            os.unlink(out_f)
        except Exception:
            pass


def group_submenu(gid: str, ctx):
    while True:
        os.system("clear")
        gname   = grp_read_field(ctx.groups_dir, gid, "name") or gid
        gdesc   = grp_read_field(ctx.groups_dir, gid, "desc") or ""
        steps   = list(grp_seq_steps(ctx.groups_dir, gid))
        ids, names, _ = load_containers(ctx.containers_dir)

        # Count running members
        n_running = 0
        for ct in grp_containers(ctx.groups_dir, gid):
            if not ct:
                continue
            cid = _ct_id_by_name(ctx.containers_dir, ct, ids, names)
            if cid and tmux_up(tsess(cid)):
                n_running += 1
        is_running = n_running > 0

        SEP_GEN = f"{BLD}  ── General ──────────────────────────{NC}"
        SEP_SEQ = f"{BLD}  ── Sequence ─────────────────────────{NC}"

        D_START = f" {GRN}▶  Start group{NC}"
        D_STOP  = f" {RED}■  Stop group{NC}"
        D_EDIT  = f" {BLU}≡  Edit name/desc{NC}"
        D_DEL   = f" {RED}×  Delete group{NC}"
        D_ADD   = f" {GRN}+  Add step{NC}"

        items = [SEP_GEN]
        if is_running:
            items.append(D_STOP)
        else:
            items += [D_START, D_EDIT, D_DEL]

        items.append(SEP_SEQ)

        for i, s in enumerate(steps):
            if s.lower().startswith("wait"):
                items.append(f" {YLW}⏱{NC}  {DIM}{s}{NC}")
            else:
                cid = _ct_id_by_name(ctx.containers_dir, s, ids, names)
                if not cid:
                    dot = f"{RED}◈{NC}"
                    status_str = f"{DIM} — not found{NC}"
                elif tmux_up(tsess(cid)):
                    dot = f"{GRN}◈{NC}"
                    status_str = f"  {GRN}running{NC}"
                else:
                    dot = f"{RED}◈{NC}"
                    status_str = f"  {DIM}stopped{NC}"
                items.append(f" {dot}  {s}{status_str}")

        if not steps:
            items.append(f" {DIM}(empty — add a step below){NC}")
        items.append(D_ADD)

        # Header
        hdr_dot = f"{GRN}▶{NC}" if is_running else f"{DIM}▶{NC}"
        hdr = f"{hdr_dot}  {BLD}{gname}{NC}"
        if gdesc:
            hdr += f"  {DIM}— {gdesc}{NC}"

        rc, sel = _fzf_raw(items, f"--header={hdr}")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        clean  = strip_ansi(chosen).strip()

        if "Start group" in clean:
            start_group(gid, ctx.groups_dir, ctx.containers_dir,
                        ctx.installations_dir, ctx.mnt_dir)

        elif "Stop group" in clean:
            stop_group(gid, ctx.groups_dir, ctx.containers_dir,
                       ctx.installations_dir, ctx.mnt_dir, ctx.cache_dir)

        elif "Edit name/desc" in clean:
            if finput(f"Group name ({gname}):"):
                nn = _tui.FINPUT_RESULT.strip() or gname
                _grp_field_set(ctx.groups_dir, gid, "name", nn)
            if finput(f"Description ({gdesc}):"):
                _grp_field_set(ctx.groups_dir, gid, "desc", _tui.FINPUT_RESULT.strip())

        elif "Delete group" in clean:
            if confirm(f"Delete group '{gname}'?"):
                try:
                    os.unlink(grp_path(ctx.groups_dir, gid))
                except Exception:
                    pass
                pause("Group deleted.")
                return

        elif "Add step" in clean or "(empty — add a step below)" in clean:
            step = _grp_pick_step(ctx)
            if step:
                steps.append(step)
                _grp_seq_save(ctx.groups_dir, gid, steps)

        else:
            # Clicked a step — edit/remove/insert sub-menu
            matched_idx = -1
            for i, s in enumerate(steps):
                if s in clean or clean.endswith(s):
                    matched_idx = i
                    break
            if matched_idx < 0:
                # Try wait steps
                for i, s in enumerate(steps):
                    if s.lower().startswith("wait") and s in clean:
                        matched_idx = i
                        break
            if matched_idx < 0:
                continue

            action_lines = ["Add before", "Edit", "Add after", "Remove"]
            rc2, sel2 = _fzf_raw(action_lines, f"--header={BLD}── Edit step ──{NC}")
            if rc2 != 0 or not sel2:
                continue
            action = trim_s(sel2)

            if action == "Add before":
                step = _grp_pick_step(ctx)
                if step:
                    steps.insert(matched_idx, step)
                    _grp_seq_save(ctx.groups_dir, gid, steps)
            elif action == "Add after":
                step = _grp_pick_step(ctx)
                if step:
                    steps.insert(matched_idx + 1, step)
                    _grp_seq_save(ctx.groups_dir, gid, steps)
            elif action == "Edit":
                new_step = _grp_edit_step(ctx, steps[matched_idx])
                if new_step:
                    steps[matched_idx] = new_step
                    _grp_seq_save(ctx.groups_dir, gid, steps)
            elif action == "Remove":
                del steps[matched_idx]
                _grp_seq_save(ctx.groups_dir, gid, steps)


def _ct_id_by_name(containers_dir, name, ids, names):
    for cid, n in zip(ids, names):
        if n == name:
            return cid
    return ""


def _grp_field_set(groups_dir, gid, field, value):
    gf = grp_path(groups_dir, gid)
    if not os.path.isfile(gf):
        return
    lines = open(gf).readlines()
    new_lines = []
    found = False
    for line in lines:
        if re.match(rf'^{field}\s*=', line):
            new_lines.append(f"{field} = {value}\n")
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f"{field} = {value}\n")
    with open(gf, "w") as fp:
        fp.writelines(new_lines)


def _grp_pick_step(ctx):
    """Pick a container or wait step. Returns step string or ''."""
    ids, names, _ = load_containers(ctx.containers_dir)

    lines = [f"{BLD}  ── Containers ───────────────────────{NC}"]
    for n in names:
        lines.append(f" {DIM}◈{NC}  {n}")
    lines += [
        f"{BLD}  ── Other ────────────────────────────{NC}",
        f" {YLW}⏱{NC}  wait:3s",
        f" {YLW}⏱{NC}  wait:10s",
        f" {YLW}⏱{NC}  wait:30s",
        f" {YLW}⏱{NC}  Custom wait...",
    ]

    rc, sel = _fzf_raw(lines, f"--header={BLD}── Add step ──{NC}")
    if rc != 0 or not sel:
        return ""
    chosen = strip_ansi(trim_s(sel)).replace("◈", "").replace("⏱", "").strip()

    if "Custom wait" in chosen:
        if not finput("Wait duration (e.g. 3s, 5m):"):
            return ""
        return f"wait:{_tui.FINPUT_RESULT.strip()}"
    elif chosen.startswith("wait:"):
        return chosen
    elif chosen in names:
        return chosen
    return ""


def _grp_edit_step(ctx, current_step):
    """Edit an existing step — container name or wait duration."""
    if current_step.lower().startswith("wait"):
        if not finput(f"Edit wait ({current_step}):"):
            return ""
        v = _tui.FINPUT_RESULT.strip()
        return f"wait:{v}" if v and not v.startswith("wait:") else v
    else:
        return _grp_pick_step(ctx) or current_step


def _grp_seq_save(groups_dir, gid, steps):
    gf = grp_path(groups_dir, gid)
    if not os.path.isfile(gf):
        return
    lines = open(gf).readlines()
    step_str = ", ".join(steps)
    new_lines = []
    found = False
    for line in lines:
        if re.match(r'^start\s*=', line):
            new_lines.append(f"start = {{{step_str}}}\n")
            found = True
        else:
            new_lines.append(line)
    if not found:
        new_lines.append(f"start = {{{step_str}}}\n")
    with open(gf, "w") as fp:
        fp.writelines(new_lines)
