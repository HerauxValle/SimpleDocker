"""
menu/main_menu.py — Top-level menus: main, containers, groups, blueprints, help/other, quit
Matches services.sh visually and functionally 1:1.
"""

import os
import re
import subprocess
import sys
import time

from functions.constants import (
    GRN, RED, YLW, BLU, CYN, BLD, DIM, NC, L, KB, TMP_DIR, FZF_BASE,
)
from functions.tui import fzf, confirm, pause, finput
from functions.utils import (
    run, run_out, tmux_up, tsess, tmux_get, tmux_set,
    strip_ansi, trim_s, make_tmp, read_json, write_json, rand_id,
)
from functions.container import (
    load_containers, cleanup_stale_lock, is_installing,
    cname as ct_cname, cpath,
    start_group, stop_group,
    grp_containers, list_groups, grp_path, grp_read_field,
)
from functions.blueprint import (
    list_blueprint_names, list_persistent_names, list_imported_names,
    get_imported_bp_path, view_persistent_bp,
    bp_persistent_enabled, bp_autodetect_mode,
    bp_cfg_set, bp_custom_paths_get, bp_custom_paths_add, bp_custom_paths_remove,
    bp_autodetect_dirs,
)
from functions.network import netns_ct_ip


BLUEPRINT_TEMPLATE = """\
[container]

[meta]
name         = my-service
version      = 1.0.0
dialogue     = Short label shown in the container list
description  = Longer notes about this service.
port         = 8080
storage_type = my-service
entrypoint   = bin/my-service --port 8080

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

[start]

[cron]

[actions]
Show logs | tail -f logs/service.log

[/container]
"""


# ── Helpers ────────────────────────────────────────────────────────────────

def _ct_id_by_name(containers_dir, name, ids, names):
    for cid, n in zip(ids, names):
        if n == name:
            return cid
    return ""


def _fzf_raw(items, *extra_args):
    """Run fzf with raw item list, return (rc, selected_line)."""
    out_f = make_tmp(".sd_fzf_")
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


# ── Main menu ──────────────────────────────────────────────────────────────

def main_menu(ctx):
    while True:
        os.system("clear")
        cleanup_stale_lock()

        ids, names, _ = load_containers(ctx.containers_dir)
        n_running = sum(1 for cid in ids if tmux_up(tsess(cid)))
        grp_ids   = list_groups(ctx.groups_dir)
        n_groups  = len(grp_ids)
        bp_names  = list_blueprint_names(ctx.blueprints_dir)
        pbp_names = list_persistent_names()
        ibp_names = list_imported_names(ctx.blueprints_dir)
        n_bps     = len(bp_names) + len(pbp_names) + len(ibp_names)

        ct_status = (f"{GRN}{n_running} running{NC}{DIM}/{len(ids)}{NC}"
                     if n_running > 0 else f"{DIM}{len(ids)}{NC}")

        grp_n_active = 0
        for gid in grp_ids:
            for ct in grp_containers(ctx.groups_dir, gid):
                cid = _ct_id_by_name(ctx.containers_dir, ct, ids, names)
                if cid and tmux_up(tsess(cid)):
                    grp_n_active += 1
                    break
        grp_status = (f"{GRN}{grp_n_active} active{NC}{DIM}/{n_groups}{NC}"
                      if grp_n_active > 0 else f"{DIM}{n_groups}{NC}")

        img_label = ""
        if ctx.img_path and os.path.isfile(ctx.img_path):
            try:
                st = os.statvfs(ctx.mnt_dir)
                used_kb  = (st.f_blocks - st.f_bfree) * st.f_frsize // 1024
                total_b  = os.path.getsize(ctx.img_path)
                used_gb  = f"{used_kb / 1048576:.1f}"
                total_gb = f"{total_b / 1073741824:.1f}"
                img_label = f"  {DIM}{os.path.basename(ctx.img_path)}  [{used_gb}/{total_gb} GB]{NC}"
            except Exception:
                img_label = f"  {DIM}{os.path.basename(ctx.img_path)}{NC}"

        SEP = f"{BLD}  ─────────────────────────────────────{NC}"
        items = [
            f" {GRN}◈{NC}  {'Containers':<28} {ct_status}",
            f" {CYN}▶{NC}  {'Groups':<28} {grp_status}",
            f" {BLU}◈{NC}  {'Blueprints':<28} {DIM}{n_bps}{NC}",
            SEP,
            f"{DIM} ?  {L['help']}{NC}",
            f"{RED} ×  {L['quit']}{NC}",
        ]

        hdr = f"{BLD}── {L['title']} ──{NC}{img_label}"

        rc, sel = _fzf_raw(
            items,
            f"--header={hdr}",
            f"--bind={KB['quit']}:execute-silent(tmux set-environment -g SD_QUIT 1)+abort",
        )

        if rc != 0 or not sel:
            if tmux_get("SD_QUIT") == "1":
                tmux_set("SD_QUIT", "0")
                _quit_menu(ctx)
                continue
            _quit_all(ctx)
            continue

        clean = trim_s(sel)
        if L["quit"] in clean:
            _quit_menu(ctx)
        elif L["help"] in clean:
            _help_menu(ctx)
        elif "Containers" in clean:
            containers_submenu(ctx)
        elif "Groups" in clean:
            groups_menu(ctx)
        elif "Blueprints" in clean:
            blueprints_submenu(ctx)


# ── Containers submenu ─────────────────────────────────────────────────────

def containers_submenu(ctx):
    while True:
        os.system("clear")
        subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)
        cleanup_stale_lock()

        ids, names, _ = load_containers(ctx.containers_dir)
        n_running = 0
        lines = [f"{BLD}  ── Containers ──────────────────────{NC}"]

        for cid, ct_name in zip(ids, names):
            sj    = os.path.join(ctx.containers_dir, cid, "service.json")
            stj   = os.path.join(ctx.containers_dir, cid, "state.json")
            data  = read_json(sj) or {}
            state = read_json(stj) or {}
            meta  = data.get("meta", {})
            dialogue  = meta.get("dialogue", "")
            port      = str(meta.get("port", "") or data.get("environment", {}).get("PORT", "") or "")
            sj_health = str(meta.get("health", "false")).lower() == "true"
            installed = state.get("installed") == "true"
            ip_rel    = state.get("install_path", "")
            ipath     = os.path.join(ctx.installations_dir, ip_rel) if ip_rel else ""

            ok_f   = os.path.join(ctx.containers_dir, cid, ".install_ok")
            fail_f = os.path.join(ctx.containers_dir, cid, ".install_fail")

            if is_installing(cid) or os.path.isfile(ok_f) or os.path.isfile(fail_f):
                dot = f"{YLW}◈{NC}"
            elif tmux_up(tsess(cid)):
                n_running += 1
                if (sj_health and port and port != "0" and
                        subprocess.run(
                            ["nc", "-z", "-w1", "127.0.0.1", port],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
                        ).returncode == 0):
                    dot = f"{GRN}◈{NC}"
                else:
                    dot = f"{YLW}◈{NC}"
            elif installed:
                dot = f"{RED}◈{NC}"
            else:
                dot = f"{DIM}◈{NC}"

            disp = f"{ct_name}  {DIM}— {dialogue}{NC}" if dialogue else ct_name

            sz_lbl = ""
            sz_cache = os.path.join(ctx.cache_dir, "sd_size", cid)
            if os.path.isfile(sz_cache):
                sz = open(sz_cache).read().strip()
                sz_lbl = f"{DIM}[{sz}gb]{NC}"
                try:
                    age = int(time.time()) - int(os.path.getmtime(sz_cache))
                    if age > 60 and ipath and os.path.isdir(ipath):
                        _refresh_size_cache(cid, ipath, sz_cache)
                except Exception:
                    pass
            elif ipath and os.path.isdir(ipath):
                _refresh_size_cache(cid, ipath, sz_cache)

            ip_lbl = ""
            if port and port != "0" and installed:
                ct_ip = netns_ct_ip(cid, ctx.mnt_dir)
                ip_lbl = f"{DIM}[{ct_ip}:{port}]{NC} "

            lines.append(f" {dot}  {disp}{NC}  {DIM}{sz_lbl} {ip_lbl}[{cid}]{NC}")

        if not ids:
            lines.append(f"{DIM}  (no containers yet){NC}")
        lines.append(f"{GRN} +  {L['new_container']}{NC}")
        lines.append(f"{BLD}  ── Navigation ───────────────────────{NC}")
        lines.append(f"{DIM} {L['back']}{NC}")

        ct_hdr_extra = f"  {DIM}[{len(ids)} · {GRN}{n_running} ▶{NC}{DIM}]{NC}"
        rc, sel = _fzf_raw(
            lines,
            f"--header={BLD}── Containers ──{NC}{ct_hdr_extra}",
        )
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        if not chosen or chosen == L["back"]:
            return

        if L["new_container"] in chosen:
            _install_method_menu(ctx)
            continue

        m = re.search(r'\[([a-z0-9]{8})\]', chosen)
        if m and os.path.isdir(os.path.join(ctx.containers_dir, m.group(1))):
            from menu.container_menu import container_submenu
            container_submenu(m.group(1), ctx)


def _refresh_size_cache(cid, ipath, sz_cache):
    try:
        os.makedirs(os.path.dirname(sz_cache), exist_ok=True)
        subprocess.Popen(
            ["sh", "-c",
             f"du -sb '{ipath}' 2>/dev/null | awk '{{printf \"%.2f\",$1/1073741824}}'"
             f" > '{sz_cache}.tmp' && mv '{sz_cache}.tmp' '{sz_cache}'"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def _install_method_menu(ctx):
    bp_names  = list_blueprint_names(ctx.blueprints_dir)
    pbp_names = list_persistent_names()
    ibp_names = list_imported_names(ctx.blueprints_dir)

    SEP_BP  = f"{BLD}  ── Blueprints ───────────────────────{NC}"
    SEP_OTH = f"{BLD}  ── Other ────────────────────────────{NC}"
    SEP_NAV = f"{BLD}  ── Navigation ───────────────────────{NC}"

    lines = [SEP_BP]
    for n in bp_names:
        lines.append(f"{DIM} ◈{NC}  {n}")
    for n in pbp_names:
        lines.append(f"{BLU} ◈{NC}  {n}  {DIM}[Persistent]{NC}")
    for n in ibp_names:
        lines.append(f"{CYN} ◈{NC}  {n}  {DIM}[Imported]{NC}")
    if not bp_names and not pbp_names and not ibp_names:
        lines.append(f"{DIM}  (no blueprints — create one first){NC}")
    lines += [
        SEP_OTH,
        f"{DIM} ◈{NC}  Blank canvas",
        f"{DIM} ◈{NC}  Import JSON",
        SEP_NAV,
        f"{DIM} {L['back']}{NC}",
    ]

    rc, sel = _fzf_raw(lines, f"--header={BLD}── New container ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = trim_s(sel)
    if not chosen or chosen == L["back"]:
        return

    if "Blank canvas" in chosen or "Import JSON" in chosen:
        _create_from_json(ctx)
    elif "[Persistent]" in chosen:
        pname = strip_ansi(chosen).replace("◈", "").replace("[Persistent]", "").strip()
        _create_from_bp_name(ctx, pname, persistent=True)
    elif "[Imported]" in chosen:
        iname = strip_ansi(chosen).replace("◈", "").replace("[Imported]", "").strip()
        _create_from_bp_name(ctx, iname, imported=True)
    else:
        bp_name = strip_ansi(chosen).replace("◈", "").strip()
        _create_from_bp_name(ctx, bp_name)


def _create_from_bp_name(ctx, bp_name, persistent=False, imported=False):
    import functions.tui as _tui
    if not finput(f"Container name (from '{bp_name}'):"):
        return
    ct_name = _tui.FINPUT_RESULT.strip()
    if not ct_name:
        return

    cid = rand_id(ctx.containers_dir)
    os.makedirs(os.path.join(ctx.containers_dir, cid), exist_ok=True)

    if persistent:
        from functions.blueprint import get_persistent_bp
        bp_text = get_persistent_bp(bp_name)
    elif imported:
        bp_path = get_imported_bp_path(ctx.blueprints_dir, bp_name)
        bp_text = open(bp_path).read() if bp_path and os.path.isfile(bp_path) else ""
    else:
        bp_file = os.path.join(ctx.blueprints_dir, bp_name + ".container")
        if not os.path.isfile(bp_file):
            bp_file = os.path.join(ctx.blueprints_dir, bp_name + ".toml")
        bp_text = open(bp_file).read() if os.path.isfile(bp_file) else ""

    if not bp_text:
        pause(f"Blueprint '{bp_name}' not found.")
        return

    src = os.path.join(ctx.containers_dir, cid, "service.src")
    with open(src, "w") as fp:
        fp.write(bp_text)
    from functions.blueprint import compile_service
    compile_service(cid, ctx.containers_dir)
    sj = os.path.join(ctx.containers_dir, cid, "service.json")
    sj_data = read_json(sj) or {}
    sj_data.setdefault("meta", {})["name"] = ct_name
    write_json(sj, sj_data)
    write_json(os.path.join(ctx.containers_dir, cid, "state.json"), {
        "name": ct_name, "installed": "false", "install_path": cid,
    })
    pause(f"Container '{ct_name}' created. Select it to install.")


def _create_from_json(ctx):
    import functions.tui as _tui
    tmp = make_tmp(".sd_json_edit_", ".json")
    editor = os.environ.get("EDITOR", "nano")
    subprocess.run([editor, tmp])
    try:
        import json
        with open(tmp) as fp:
            data = json.load(fp)
    except Exception:
        pause("Invalid JSON — container not created.")
        return
    finally:
        try:
            os.unlink(tmp)
        except Exception:
            pass

    ct_name = data.get("meta", {}).get("name", "")
    if not ct_name:
        if not finput("Container name:"):
            return
        ct_name = _tui.FINPUT_RESULT.strip()
    if not ct_name:
        return

    cid = rand_id(ctx.containers_dir)
    os.makedirs(os.path.join(ctx.containers_dir, cid), exist_ok=True)
    write_json(os.path.join(ctx.containers_dir, cid, "state.json"), {
        "name": ct_name, "installed": "false", "install_path": cid,
    })
    write_json(os.path.join(ctx.containers_dir, cid, "service.json"), data)
    pause(f"Container '{ct_name}' created. Select it to install.")


# ── Groups menu ────────────────────────────────────────────────────────────

def groups_menu(ctx):
    while True:
        os.system("clear")
        subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)

        gids  = list_groups(ctx.groups_dir)
        ids, names, _ = load_containers(ctx.containers_dir)

        n_active = 0
        SEP_GRP = f"{BLD}  ── Groups ───────────────────────────{NC}"
        lines = [SEP_GRP]

        for gid in gids:
            gname   = grp_read_field(ctx.groups_dir, gid, "name") or gid
            members = list(grp_containers(ctx.groups_dir, gid))
            n_run   = sum(
                1 for ct in members
                for cid in [_ct_id_by_name(ctx.containers_dir, ct, ids, names)]
                if cid and tmux_up(tsess(cid))
            )
            if n_run > 0:
                n_active += 1
            dot = f"{GRN}▶{NC}" if n_run > 0 else f"{DIM}▶{NC}"
            lines.append(f" {dot}  {gname:<24} {DIM}{n_run}/{len(members)} running{NC}")

        if not gids:
            lines.append(f"{DIM}  (no groups yet){NC}")
        lines.append(f"{GRN} +  {L['grp_new']}{NC}")
        lines.append(f"{BLD}  ── Navigation ───────────────────────{NC}")
        lines.append(f"{DIM} {L['back']}{NC}")

        hdr_extra = f"  {DIM}[{len(gids)} · {GRN}{n_active} active{NC}{DIM}]{NC}"
        rc, sel = _fzf_raw(lines, f"--header={BLD}── Groups ──{NC}{hdr_extra}")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        if not chosen or chosen == L["back"]:
            return

        if L["grp_new"] in chosen:
            import functions.tui as _tui
            if not finput("Group name:"):
                continue
            gname_new = _tui.FINPUT_RESULT.strip()
            if gname_new:
                _create_group(ctx.groups_dir, gname_new)
            continue

        for gid in gids:
            gname = grp_read_field(ctx.groups_dir, gid, "name") or gid
            if gname in chosen or gid in chosen:
                from menu.group_menu import group_submenu
                group_submenu(gid, ctx)
                break


def _create_group(groups_dir, gname):
    gname = re.sub(r'[^a-zA-Z0-9_\- ]', '', gname).strip()
    if not gname:
        pause("Name cannot be empty.")
        return
    import secrets
    gid = secrets.token_hex(4)
    gf  = grp_path(groups_dir, gid)
    with open(gf, "w") as fp:
        fp.write(f"[group]\nname = {gname}\ndesc = \nstart = {{}}\n")
    pause(f"Group '{gname}' created.")


# ── Blueprints submenu ─────────────────────────────────────────────────────

def blueprints_submenu(ctx):
    while True:
        os.system("clear")
        bps  = list_blueprint_names(ctx.blueprints_dir)
        pbps = list_persistent_names()
        ibps = list_imported_names(ctx.blueprints_dir)

        lines = [f"{BLD}  ── Blueprints ───────────────────────{NC}"]
        for n in bps:
            lines.append(f"{DIM} ◈{NC}  {n}")
        for n in pbps:
            lines.append(f"{BLU} ◈{NC}  {n}  {DIM}[Persistent]{NC}")
        for n in ibps:
            lines.append(f"{CYN} ◈{NC}  {n}  {DIM}[Imported]{NC}")
        if not bps and not pbps and not ibps:
            lines.append(f"{DIM}  (no blueprints yet){NC}")
        lines.append(f"{GRN} +  {L['bp_new']}{NC}")
        lines.append(f"{BLD}  ── Settings ─────────────────────────{NC}")
        lines.append(f"{DIM} ◈  Blueprint settings{NC}")
        lines.append(f"{BLD}  ── Navigation ───────────────────────{NC}")
        lines.append(f"{DIM} {L['back']}{NC}")

        hdr = (f"{BLD}── Blueprints ──{NC}  "
               f"{DIM}[{len(bps)} file · {len(pbps)} built-in · {len(ibps)} imported]{NC}")
        rc, sel = _fzf_raw(lines, f"--header={hdr}")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        if not chosen or chosen == L["back"]:
            return

        if L["bp_new"] in chosen:
            import functions.tui as _tui
            if not finput("Blueprint name:"):
                continue
            bname = re.sub(r'[^a-zA-Z0-9_ -]', '', _tui.FINPUT_RESULT).strip()
            if not bname:
                continue
            bfile = os.path.join(ctx.blueprints_dir, bname + ".container")
            if os.path.isfile(bfile):
                pause(f"Blueprint '{bname}' already exists.")
                continue
            with open(bfile, "w") as fp:
                fp.write(BLUEPRINT_TEMPLATE)
            pause(f"Blueprint '{bname}' created.")
            continue

        if "Blueprint settings" in chosen:
            _blueprints_settings_menu(ctx)
            continue

        if "[Persistent]" in chosen:
            pname = strip_ansi(chosen).replace("◈", "").replace("[Persistent]", "").strip()
            view_persistent_bp(pname)
            continue

        if "[Imported]" in chosen:
            iname = strip_ansi(chosen).replace("◈", "").replace("[Imported]", "").strip()
            ipath = get_imported_bp_path(ctx.blueprints_dir, iname)
            if ipath and os.path.isfile(ipath):
                with open(ipath) as fp:
                    ls2 = fp.readlines()
                _fzf_raw([l.rstrip() for l in ls2],
                         f"--header={BLD}── [Imported] {iname} {DIM}({ipath}){NC} ──{NC}",
                         "--disabled")
            else:
                pause(f"Could not locate imported blueprint '{iname}'.")
            continue

        for n in bps:
            if n in strip_ansi(chosen):
                _blueprint_submenu(n, ctx)
                break


def _blueprint_submenu(bp_name, ctx):
    import functions.tui as _tui
    bfile = os.path.join(ctx.blueprints_dir, bp_name + ".container")
    if not os.path.isfile(bfile):
        bfile = os.path.join(ctx.blueprints_dir, bp_name + ".toml")

    lines = [
        f"{DIM}{L['bp_edit']}{NC}",
        f"{DIM}{L['bp_rename']}{NC}",
        f"{RED}{L['bp_delete']}{NC}",
        f"{BLD}  ── Navigation ───────────────────────{NC}",
        f"{DIM} {L['back']}{NC}",
    ]
    rc, sel = _fzf_raw(lines, f"--header={BLD}── {bp_name} ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = trim_s(sel)

    if L["bp_edit"] in chosen:
        editor = os.environ.get("EDITOR", "nano")
        subprocess.run([editor, bfile])
    elif L["bp_rename"] in chosen:
        if not finput(f"New name for '{bp_name}':"):
            return
        new_name = re.sub(r'[^a-zA-Z0-9_ -]', '', _tui.FINPUT_RESULT).strip()
        if not new_name:
            return
        new_file = os.path.join(ctx.blueprints_dir, new_name + ".container")
        if os.path.isfile(new_file):
            pause(f"Blueprint '{new_name}' already exists.")
            return
        os.rename(bfile, new_file)
    elif L["bp_delete"] in chosen:
        if confirm(f"Delete blueprint '{bp_name}'?"):
            try:
                os.unlink(bfile)
            except Exception:
                pass


def _blueprints_settings_menu(ctx):
    import functions.tui as _tui
    while True:
        pers_enabled = bp_persistent_enabled(ctx.mnt_dir)
        pers_tog = (f"{GRN}[Enabled]{NC}" if pers_enabled else f"{DIM}[Disabled]{NC}")
        mode = bp_autodetect_mode(ctx.mnt_dir)
        custom_paths = bp_custom_paths_get(ctx.mnt_dir)
        scan_dirs = list(bp_autodetect_dirs(ctx.mnt_dir))

        SEP_GEN   = f"{BLD}  ── General ───────────────────────────{NC}"
        SEP_PATHS = f"{BLD}  ── Scanned paths ─────────────────────{NC}"
        SEP_NAV   = f"{BLD}  ── Navigation ───────────────────────{NC}"

        lines = [
            SEP_GEN,
            f"{DIM} ◈{NC}  Persistent blueprints — {pers_tog}",
            f"{DIM} ◈{NC}  Autodetect mode — {DIM}{mode}{NC}",
            SEP_PATHS,
        ]
        for d in scan_dirs:
            lines.append(f"{DIM} ◈{NC}  {d}")
        for cp in custom_paths:
            lines.append(f"{CYN} +{NC}  {cp}  {DIM}[custom]{NC}")
        lines += [
            f"{GRN} +  Add custom path{NC}",
            SEP_NAV,
            f"{DIM} {L['back']}{NC}",
        ]

        rc, sel = _fzf_raw(lines, f"--header={BLD}── Blueprint settings ──{NC}")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        if not chosen or chosen == L["back"]:
            return

        if "Persistent blueprints" in chosen:
            bp_cfg_set(ctx.mnt_dir, "persistent_blueprints",
                       "false" if pers_enabled else "true")
        elif "Autodetect mode" in chosen:
            modes = ["Home", "XDG", "Custom", "Off"]
            cur_idx = modes.index(mode) if mode in modes else 0
            bp_cfg_set(ctx.mnt_dir, "autodetect_blueprints",
                       modes[(cur_idx + 1) % len(modes)])
        elif "Add custom path" in chosen:
            if not finput("Custom scan path (absolute):"):
                continue
            p = _tui.FINPUT_RESULT.strip()
            if p:
                bp_custom_paths_add(ctx.mnt_dir, p)
        elif "[custom]" in chosen:
            cp = strip_ansi(chosen).replace("+", "").replace("[custom]", "").strip()
            if confirm(f"Remove custom path '{cp}'?"):
                bp_custom_paths_remove(ctx.mnt_dir, cp)


# ── Help / Other menu ──────────────────────────────────────────────────────

def _help_menu(ctx):
    """Match bash _help_menu — Storage/Plugins/Tools/Caution sections."""
    while True:
        ubuntu_ready  = os.path.isfile(os.path.join(ctx.ubuntu_dir, ".ubuntu_ready"))
        ubuntu_status = f"{GRN}ready{NC}  {CYN}[P]{NC}" if ubuntu_ready else f"{YLW}not installed{NC}"

        proxy_pid = os.path.join(ctx.mnt_dir, ".sd", ".caddy.pid")
        proxy_run = False
        if os.path.isfile(proxy_pid):
            try:
                pid = int(open(proxy_pid).read().strip())
                os.kill(pid, 0)
                proxy_run = True
            except Exception:
                pass
        proxy_status = f"{GRN}running{NC}" if proxy_run else f"{DIM}stopped{NC}"

        qr_installed = False
        if ubuntu_ready:
            qr_installed = subprocess.run(
                ["chroot", ctx.ubuntu_dir, "which", "qrencode"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            ).returncode == 0

        qr_s = f"{GRN}installed{NC}" if qr_installed else f"{DIM}not installed{NC}"

        SEP_STORAGE = f"{BLD}  ── Storage ───────────────────────────{NC}"
        SEP_PLUGINS = f"{BLD}  ── Plugins ───────────────────────────{NC}"
        SEP_TOOLS   = f"{BLD}  ── Tools ─────────────────────────────{NC}"
        SEP_DANGER  = f"{BLD}  ── Caution ───────────────────────────{NC}"
        SEP_NAV     = f"{BLD}  ── Navigation ────────────────────────{NC}"

        lines = [
            SEP_STORAGE,
            f"{DIM} ◈  Profiles & data{NC}",
            f"{DIM} ◈  Backups{NC}",
            f"{DIM} ◈  Blueprints{NC}",
            SEP_PLUGINS,
            f" {CYN}◈{NC}{DIM}  Ubuntu base — {ubuntu_status}{NC}",
            f" {CYN}◈{NC}{DIM}  Caddy — {proxy_status}{NC}",
            f" {CYN}◈{NC}{DIM}  QRencode — {qr_s}{NC}",
            SEP_TOOLS,
            f"{DIM} ◈  Active processes{NC}",
            f"{DIM} ◈  Resource limits{NC}",
            f"{DIM} ≡  Blueprint preset{NC}",
            SEP_DANGER,
            f"{DIM} ≡  View logs{NC}",
            f"{DIM} ⊘  Clear cache{NC}",
            f"{DIM} ▷  Resize image{NC}",
            f"{DIM} ◈  Manage Encryption{NC}",
            f" {RED}×{NC}{DIM}  Delete image file{NC}",
            SEP_NAV,
            f"{DIM} {L['back']}{NC}",
        ]

        hdr = (f"{BLD}── {L['help']} ──{NC}  "
               f"{DIM}Ubuntu:{NC}{ubuntu_status}  {DIM}Proxy:{NC}{proxy_status}")
        rc, sel = _fzf_raw(lines, f"--header={hdr}")
        if rc != 0 or not sel:
            return
        chosen = trim_s(sel)
        if not chosen or chosen == L["back"]:
            return
        clean = strip_ansi(chosen).strip()

        if "Clear cache" in clean:
            if confirm("Clear all cached data?"):
                import shutil
                for d in ["sd_size", "gh_tag"]:
                    dp = os.path.join(ctx.cache_dir, d)
                    shutil.rmtree(dp, ignore_errors=True)
                    os.makedirs(dp, exist_ok=True)
                pause("Cache cleared.")

        elif "Resize image" in clean:
            _resize_image_menu(ctx)

        elif "Manage Encryption" in clean:
            from menu.enc_menu import enc_menu
            enc_menu(ctx)

        elif "Profiles & data" in clean:
            from menu.storage_menu import persistent_storage_menu
            persistent_storage_menu(None, ctx)

        elif "Backups" in clean:
            _manage_backups_menu(ctx)

        elif "Blueprints" in clean:
            _blueprints_settings_menu(ctx)

        elif "Active processes" in clean:
            _active_processes_menu(ctx)

        elif "Resource limits" in clean:
            from menu.resources_menu import resources_menu_global
            resources_menu_global(ctx)

        elif "Caddy" in clean:
            from menu.proxy_menu import proxy_menu
            proxy_menu(ctx)

        elif "QRencode" in clean:
            from menu.proxy_menu import qrencode_menu
            qrencode_menu(ctx)

        elif "Ubuntu base" in clean:
            from menu.ubuntu_menu import ubuntu_menu
            ubuntu_menu(ctx)

        elif "Blueprint preset" in clean:
            _show_blueprint_preset()

        elif "View logs" in clean:
            from menu.logs_menu import logs_browser
            logs_browser(ctx)

        elif "Delete image file" in clean:
            _delete_image_file(ctx)
            return


def _show_blueprint_preset():
    lines = BLUEPRINT_TEMPLATE.splitlines()
    _fzf_raw(lines,
             f"--header={BLD}── Blueprint preset  {DIM}(read only){NC} ──{NC}",
             "--disabled")


def _delete_image_file(ctx):
    if not ctx.img_path:
        pause("No image currently loaded.")
        return
    img_name = os.path.basename(ctx.img_path)
    img_path_save = ctx.img_path
    if not confirm(
        f"PERMANENTLY DELETE IMAGE?\n\n"
        f"  File: {img_name}\n  Path: {img_path_save}\n\n"
        f"  THIS CANNOT BE UNDONE!"
    ):
        return

    ids, _, _ = load_containers(ctx.containers_dir, show_hidden=True)
    for cid in ids:
        sess = tsess(cid)
        if tmux_up(sess):
            subprocess.run(["tmux", "send-keys", "-t", sess, "C-c", ""],
                           stderr=subprocess.DEVNULL)
            time.sleep(0.3)
            subprocess.run(["tmux", "kill-session", "-t", sess],
                           stderr=subprocess.DEVNULL)
    r = subprocess.run(["tmux", "list-sessions", "-F", "#{session_name}"],
                       capture_output=True, text=True)
    for s in r.stdout.splitlines():
        if s.startswith("sdInst_"):
            subprocess.run(["tmux", "kill-session", "-t", s], stderr=subprocess.DEVNULL)
    tmux_set("SD_INSTALLING", "")

    from functions.image import do_umount
    do_umount(ctx.mnt_dir, ctx.img_path)
    try:
        os.unlink(img_path_save)
    except Exception:
        pass
    pause(f"✓ Image deleted: {img_name}\n\n  Select or create a new image.")
    from cli.app import pick_or_create_image
    new_img = pick_or_create_image()
    if new_img:
        ctx.img_path = new_img
        ctx.set_img_dirs()


def _manage_backups_menu(ctx):
    ids, names, _ = load_containers(ctx.containers_dir)
    if not ids:
        pause("No containers.")
        return
    lines = [f"{BLD}  ── Containers ──────────────────────{NC}"]
    for cid, ct_name in zip(ids, names):
        bd = os.path.join(ctx.backup_dir, ct_name)
        n_snaps = 0
        if os.path.isdir(bd):
            n_snaps = sum(1 for d in os.listdir(bd)
                          if os.path.isdir(os.path.join(bd, d)))
        lines.append(f" {DIM}◈{NC}  {ct_name}  {DIM}[{cid}]  {n_snaps} snapshot(s){NC}")
    lines += [f"{BLD}  ── Navigation ───────────────────────{NC}", f"{DIM} {L['back']}{NC}"]

    rc, sel = _fzf_raw(lines, f"--header={BLD}── Backups ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = trim_s(sel)
    if not chosen or chosen == L["back"]:
        return
    m = re.search(r'\[([a-z0-9]{8})\]', chosen)
    if m:
        from menu.backup_menu import container_backups_menu
        container_backups_menu(m.group(1), ctx.containers_dir,
                                ctx.installations_dir, ctx.backup_dir)


# ── Resize image ───────────────────────────────────────────────────────────

def _resize_image_menu(ctx):
    import functions.tui as _tui
    if not ctx.img_path:
        pause("No image loaded.")
        return
    try:
        cur_bytes  = os.path.getsize(ctx.img_path)
        cur_gib    = f"{cur_bytes / 1073741824:.1f}"
        used_bytes = 0
        try:
            r = subprocess.run(
                ["btrfs", "filesystem", "usage", "-b", ctx.mnt_dir],
                capture_output=True, text=True
            )
            for line in r.stdout.splitlines():
                if "used" in line.lower():
                    nums = re.findall(r'\d+', line)
                    if nums:
                        used_bytes = int(nums[-1])
                        break
        except Exception:
            pass
        if not used_bytes:
            try:
                st = os.statvfs(ctx.mnt_dir)
                used_bytes = (st.f_blocks - st.f_bfree) * st.f_frsize
            except Exception:
                pass
        used_gib = f"{used_bytes / 1073741824:.1f}"
        min_gib  = int(used_bytes / 1073741824) + 11
    except Exception:
        cur_gib = "?"; used_gib = "?"; min_gib = 10

    if not finput(
        f"Current: {cur_gib} GB   Used: {used_gib} GB   Minimum: {min_gib} GB\n\nNew size in GB:"
    ):
        return
    try:
        new_gb = int(_tui.FINPUT_RESULT.strip())
    except ValueError:
        pause("Invalid size.")
        return
    from functions.image import resize_image
    if resize_image(ctx.img_path, ctx.mnt_dir, new_gb):
        pause(f"Image resized to {new_gb} GB.")
    else:
        pause("Resize failed.")


# ── Active processes ────────────────────────────────────────────────────────

def _active_processes_menu(ctx):
    while True:
        gpu_hdr = ""
        try:
            r = subprocess.run(
                ["nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total",
                 "--format=csv,noheader,nounits"],
                capture_output=True, text=True, timeout=2
            )
            if r.returncode == 0 and r.stdout.strip():
                parts = r.stdout.strip().split(",")
                if len(parts) >= 3:
                    gpu_hdr = (f"  ·  GPU:{parts[0].strip()}%  "
                               f"VRAM:{parts[1].strip()}/{parts[2].strip()} MiB")
        except Exception:
            pass

        r = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True, text=True
        )
        sessions = [
            s for s in r.stdout.splitlines()
            if re.match(r'^sd_[a-z0-9]{8}$|^sdInst_|^sdResize$|^sdTerm_|^sdAction_|^simpleDocker$', s)
        ]

        display_lines = []
        display_sess  = []
        for sess in sessions:
            pid_r = subprocess.run(
                ["tmux", "list-panes", "-t", sess, "-F", "#{pane_pid}"],
                capture_output=True, text=True
            )
            pid = (pid_r.stdout.strip().split("\n")[0].strip()
                   if pid_r.returncode == 0 else "")
            cpu = "-"; mem = "-"
            if pid:
                ps_r = subprocess.run(
                    ["ps", "-p", pid, "-o", "pcpu=,rss=", "--no-headers"],
                    capture_output=True, text=True
                )
                if ps_r.returncode == 0 and ps_r.stdout.strip():
                    parts = ps_r.stdout.split()
                    if len(parts) >= 2:
                        cpu = f"{float(parts[0]):.1f}%"
                        mem = f"{int(parts[1]) // 1024}M"

            stats = f"{DIM}CPU:{cpu:<6} RAM:{mem:<6}{NC}"

            if sess == "simpleDocker":
                label = "simpleDocker  (UI)"
            elif sess.startswith("sdInst_"):
                icid  = tmux_get("SD_INSTALLING")
                iname = ct_cname(ctx.containers_dir, icid) if icid else "unknown"
                label = f"Install › {iname}"
            elif sess == "sdResize":
                label = "Resize operation"
            elif sess.startswith("sdTerm_"):
                cid   = sess[7:]
                label = f"Terminal › {ct_cname(ctx.containers_dir, cid) or cid}"
            elif sess.startswith("sdAction_"):
                parts2 = sess.split("_")
                cid    = parts2[1] if len(parts2) > 1 else ""
                aidx   = parts2[2] if len(parts2) > 2 else "0"
                sj     = os.path.join(ctx.containers_dir, cid, "service.json")
                albl   = aidx
                if os.path.isfile(sj):
                    try:
                        import json
                        with open(sj) as fp:
                            sd = json.load(fp)
                        albl = sd.get("actions", [{}])[int(aidx)].get("label", aidx)
                    except Exception:
                        pass
                label = f"Action › {albl}  ({ct_cname(ctx.containers_dir, cid) or cid})"
            elif sess.startswith("sd_"):
                cid   = sess[3:]
                label = ct_cname(ctx.containers_dir, cid) or cid
            else:
                label = sess

            display_lines.append(
                f"  {label:<36} {stats}  PID:{pid or '-':<7}\t{sess}"
            )
            display_sess.append(sess)

        if not display_lines:
            pause("No active processes.")
            return

        SEP = f"{BLD}  ── Processes ────────────────────────{NC}\t__sep__"
        NAV = f"{BLD}  ── Navigation ───────────────────────{NC}\t__sep__"
        BCK = f"{DIM} {L['back']}{NC}\t__back__"
        all_lines = [SEP] + display_lines + [NAV, BCK]

        rc, sel = _fzf_raw(
            all_lines,
            f"--header={BLD}── Processes ──{NC}  {DIM}[{len(display_lines)} active]{NC}{gpu_hdr}",
            "--with-nth=1", "--delimiter=\t",
        )
        if rc != 0 or not sel:
            return

        target = sel.split("\t")[-1].strip() if "\t" in sel else ""
        if target in ("__back__", "__sep__", ""):
            return

        if confirm(f"Kill '{target}'?"):
            subprocess.run(["tmux", "send-keys", "-t", target, "C-c", ""],
                           stderr=subprocess.DEVNULL)
            time.sleep(0.3)
            subprocess.run(["tmux", "kill-session", "-t", target],
                           stderr=subprocess.DEVNULL)
            pause("Killed.")


# ── Quit menus ─────────────────────────────────────────────────────────────

def _quit_menu(ctx):
    lines = [
        f"{DIM}{L['detach']}{NC}",
        f"{RED}{L['quit_stop_all']}{NC}",
        f"{BLD}  ── Navigation ───────────────────────{NC}",
        f"{DIM} {L['back']}{NC}",
    ]
    rc, sel = _fzf_raw(lines, f"--header={BLD}── {L['quit']} ──{NC}")
    if rc != 0 or not sel:
        return
    chosen = trim_s(sel)
    if L["detach"] in chosen:
        tmux_set("SD_DETACH", "1")
        subprocess.run(["tmux", "detach-client"], stderr=subprocess.DEVNULL)
    elif L["quit_stop_all"] in chosen:
        _quit_all(ctx)


def _quit_all(ctx):
    ids, _, _ = load_containers(ctx.containers_dir, show_hidden=True)
    for cid in ids:
        sess = tsess(cid)
        if tmux_up(sess):
            subprocess.run(["tmux", "send-keys", "-t", sess, "C-c", ""],
                           stderr=subprocess.DEVNULL)
            time.sleep(0.3)
            subprocess.run(["tmux", "kill-session", "-t", sess],
                           stderr=subprocess.DEVNULL)
    from functions.image import do_umount
    try:
        do_umount(ctx.mnt_dir, ctx.img_path)
    except Exception:
        pass
    subprocess.run(["tmux", "kill-session", "-t", "simpleDocker"],
                   stderr=subprocess.DEVNULL)
    sys.exit(0)
