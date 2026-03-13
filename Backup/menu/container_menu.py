"""
menu/container_menu.py — Container submenu and related sub-menus
"""

import os
import re
import subprocess
import time

from functions.constants import (
    GRN, RED, YLW, BLU, CYN, BLD, DIM, NC, L, KB, TMP_DIR
)
from functions.tui import (
    menu, fzf, confirm, pause, finput, FINPUT_RESULT, sep, REPLY
)
from functions.utils import (
    run, run_out, tmux_up, tsess, inst_sess, cron_sess,
    state_get, state_set, read_json, write_json, trim_s, strip_ansi, make_tmp,
)
from functions.container import (
    cname, cpath, is_installing, installing_id, cleanup_stale_lock,
    health_check, load_containers, start_container, stop_container,
    cron_start_all, cron_stop_all, cron_countdown,
    snap_dir, rotate_and_snapshot, env_exports, update_size_cache,
    build_start_script,
)
from functions.blueprint import compile_service, ensure_src
from functions.network import (
    netns_ct_ip, exposure_get, exposure_set, exposure_apply,
    exposure_next, exposure_label,
)
from functions.installer import run_job, guard_install
from functions.storage import (
    stor_count, pick_storage_profile, stor_unlink, stor_link,
    stor_clear_active, auto_pick_storage_profile,
)


# ── tmux attach hint ──────────────────────────────────────────────────────

def tmux_attach_hint(title: str, session: str):
    """Show attach hint and switch to tmux session."""
    from functions.constants import KB
    pause(f"Attaching to '{title}'…\n\n  Press {KB['tmux_detach']} to detach.")
    subprocess.run(["tmux", "switch-client", "-t", session],
                   stderr=subprocess.DEVNULL)
    time.sleep(0.1)
    subprocess.run(["stty", "sane"], stderr=subprocess.DEVNULL)


# ── Process install finish ────────────────────────────────────────────────

def process_install_finish(
    cid: str, containers_dir: str, installations_dir: str
):
    ok_file   = os.path.join(containers_dir, cid, ".install_ok")
    fail_file = os.path.join(containers_dir, cid, ".install_fail")

    cleanup_stale_lock()

    if os.path.isfile(ok_file):
        os.unlink(ok_file)
        ct_name = cname(containers_dir, cid)
        # Set installed = true
        state_data = read_json(os.path.join(containers_dir, cid, "state.json")) or {}
        state_data["installed"] = "true"
        write_json(os.path.join(containers_dir, cid, "state.json"), state_data)
        pause(f"'{ct_name}' {L['msg_install_ok']}")
    elif os.path.isfile(fail_file):
        os.unlink(fail_file)
        ct_name = cname(containers_dir, cid)
        pause(f"'{ct_name}' {L['msg_install_fail']}")


# ── Installing sub-menu (shown while install in progress) ─────────────────

def installing_menu(cid: str, header: str, items: list) -> int:
    """Like _menu but also handles install in-progress state. Returns 0/1/2."""
    import functions.tui as _tui
    rc = menu(header, *items)
    _tui.REPLY = _tui.REPLY  # ensure global is accessible
    return rc


# ── Open-in submenu ───────────────────────────────────────────────────────

def open_in_submenu(
    cid: str, containers_dir: str, mnt_dir: str
):
    """⊕ Open in… — terminal, browser, yazi, etc."""
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj) or {}
    port = str(data.get("meta", {}).get("port", "") or data.get("environment", {}).get("PORT", "") or "")
    ct_ip = netns_ct_ip(cid, mnt_dir) if port and port != "0" else ""
    ct_name = cname(containers_dir, cid)

    items = []
    if port and port != "0":
        items.append(f"{GRN}⊙  Open browser  {DIM}({ct_ip}:{port}){NC}")
    items.append("◉  Terminal")
    items.append("◈  File manager (yazi)")

    rc = menu(f"Open in — {ct_name}", *items)
    if rc != 0:
        return

    import functions.tui as _tui
    choice = _tui.REPLY

    if "browser" in strip_ansi(choice).lower():
        url = f"http://{ct_ip}:{port}"
        _open_url(url)

    elif "Terminal" in choice:
        sess = tsess(cid)
        ip   = cpath(containers_dir, _get_installations_dir(containers_dir, mnt_dir), cid)
        if not ip:
            pause("Container not installed.")
            return
        env_block = env_exports(containers_dir, cid, ip)
        term_sess = f"sdTerm_{cid}"
        script = make_tmp(".sd_term_")
        with open(script, "w") as fp:
            fp.write(f"#!/usr/bin/env bash\n{env_block}\ncd \"$CONTAINER_ROOT\"\nexec bash\n")
        os.chmod(script, 0o755)
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", term_sess,
             f"bash {script}; rm -f {script}"],
            stderr=subprocess.DEVNULL
        )
        tmux_attach_hint(f"{ct_name} — terminal", term_sess)

    elif "yazi" in choice.lower():
        ip = cpath(containers_dir, _get_installations_dir(containers_dir, mnt_dir), cid)
        if ip and os.path.isdir(ip):
            subprocess.run(["yazi", ip], stderr=subprocess.DEVNULL)


def _open_url(url: str):
    """Open URL in default browser."""
    import subprocess
    try:
        browser = run_out(["xdg-settings", "get", "default-web-browser"])
        browser = browser.replace(".desktop", "").lower()
        for b_name, b_cmd in [
            ("firefox", "firefox"), ("librewolf", "librewolf"),
            ("vivaldi", "vivaldi-stable"), ("chrome", "google-chrome-stable"),
            ("chromium", "chromium"), ("brave", "brave-browser"),
        ]:
            if b_name in browser:
                subprocess.Popen([b_cmd, "--new-tab", url],
                                  stderr=subprocess.DEVNULL)
                return
        subprocess.Popen(["xdg-open", url], stderr=subprocess.DEVNULL)
    except Exception:
        pass


def _get_installations_dir(containers_dir: str, mnt_dir: str) -> str:
    return os.path.join(os.path.dirname(containers_dir), "Installations")


# ── Container submenu (main) ──────────────────────────────────────────────

def container_submenu(cid: str, ctx_or_containers_dir, installations_dir=None,
                      backup_dir=None, logs_dir=None, ubuntu_dir=None,
                      tmp_dir=None, mnt_dir=None, cache_dir=None):
    # Support both ctx object and positional args
    if hasattr(ctx_or_containers_dir, 'containers_dir'):
        ctx = ctx_or_containers_dir
        containers_dir = ctx.containers_dir
        installations_dir = ctx.installations_dir
        backup_dir = ctx.backup_dir
        logs_dir = ctx.logs_dir
        ubuntu_dir = ctx.ubuntu_dir
        tmp_dir = ctx.tmp_dir
        mnt_dir = ctx.mnt_dir
        cache_dir = ctx.cache_dir
    else:
        containers_dir = ctx_or_containers_dir
    import functions.tui as _tui

    while True:
        os.system("clear")
        cleanup_stale_lock()
        ct_name   = cname(containers_dir, cid)
        installed = state_get(containers_dir, cid, "installed") == "true"
        is_run    = tmux_up(tsess(cid))
        is_inst   = is_installing(cid)
        ok_file   = os.path.join(containers_dir, cid, ".install_ok")
        fail_file = os.path.join(containers_dir, cid, ".install_fail")
        inst_done = os.path.isfile(ok_file) or os.path.isfile(fail_file)

        sj   = os.path.join(containers_dir, cid, "service.json")
        data = read_json(sj) or {}
        meta = data.get("meta", {})
        svc_port = str(meta.get("port", "") or data.get("environment", {}).get("PORT", "") or "0")

        # Build action list
        action_labels, action_dsls = [], []
        cron_names, cron_intervals, cron_idxs = [], [], []
        if installed and not is_inst:
            for ai, act in enumerate(data.get("actions", [])):
                lbl = act.get("label", "")
                dsl = act.get("dsl", act.get("script", ""))
                if not lbl:
                    continue
                if lbl.lower() == "open browser":
                    continue
                if lbl[0:1].isalnum():
                    lbl = f"⊙  {lbl}"
                action_labels.append(lbl)
                action_dsls.append(dsl)
            for ci, cron in enumerate(data.get("crons", [])):
                cn = cron.get("name", "")
                civ = cron.get("interval", "")
                if cn:
                    cron_names.append(cn)
                    cron_intervals.append(civ)
                    cron_idxs.append(ci)

        # Header dot
        if is_inst or inst_done:
            hdr_dot = f"{YLW}◈{NC}"
        elif is_run:
            hdr_dot = f"{GRN}◈{NC}" if health_check(containers_dir, cid) else f"{YLW}◈{NC}"
        elif installed:
            hdr_dot = f"{RED}◈{NC}"
        else:
            hdr_dot = f"{DIM}◈{NC}"

        dlg = meta.get("dialogue", "")
        if dlg:
            hdr = f"{hdr_dot}  {ct_name}  {DIM}— {dlg}{NC}"
        else:
            hdr = f"{hdr_dot}  {ct_name}"
        if svc_port != "0" and svc_port:
            ct_ip = netns_ct_ip(cid, mnt_dir)
            hdr += f"  {DIM}{ct_ip}:{svc_port}{NC}"

        # Build items list
        SEP = sep
        items = []

        if is_inst or inst_done:
            if inst_done:
                fin_lbl = "✓  Finish update" if installed else L["ct_finish_inst"]
                items.append(fin_lbl)
            else:
                items.append(L["ct_attach_inst"])

        elif is_run:
            items.append(L["ct_stop"])
            items.append(L["ct_restart"])
            items.append(L["ct_attach"])
            items.append(L["ct_open_in"])
            items.append(L["ct_log"])
            if action_labels:
                items.append(SEP("Actions"))
                items.extend(action_labels)
            if cron_names:
                items.append(SEP("Cron"))
                for ci in range(len(cron_names)):
                    cidx = cron_idxs[ci]
                    csess = cron_sess(cid, cidx)
                    if tmux_up(csess):
                        items.append(f" {CYN}⏱{NC}  {DIM}{cron_names[ci]}  {CYN}[{cron_intervals[ci]}]{NC}")
                    else:
                        items.append(f" {DIM}⏱  {cron_names[ci]}  [stopped]{NC}")

        elif installed:
            items.append(L["ct_start"])
            items.append(L["ct_open_in"])
            items.append(SEP("Storage"))
            items.append(L["ct_backups"])
            items.append(L["ct_profiles"])
            items.append(L["ct_edit"])
            items.append(L["ct_rename"])
            items.append("◦  Clone container")
            items.append(SEP("Management"))
            from functions.network import exposure_get, exposure_label as _exp_lbl
            _exp_mode = exposure_get(containers_dir, cid)
            items.append(f"{_exp_lbl(_exp_mode)}  {L['ct_exposure']}")
            items.append(SEP("Caution"))
            items.append(L["ct_uninstall"])

        else:
            items.append(L["ct_install"])
            items.append(L["ct_edit"])
            items.append(L["ct_rename"])
            items.append(SEP("Caution"))
            items.append(L["ct_remove"])

        # Show menu
        if is_inst or inst_done:
            rc = installing_menu(cid, hdr, items)
        else:
            rc = menu(hdr, *items)

        if rc == 2:
            continue
        if rc != 0:
            return

        reply = _tui.REPLY

        # Handle selection
        if reply in (L["ct_attach_inst"],):
            tmux_attach_hint("installation", inst_sess(cid))
            cleanup_stale_lock()

        elif reply in (L["ct_finish_inst"], "✓  Finish update"):
            process_install_finish(cid, containers_dir, installations_dir)

        elif reply == L["ct_install"]:
            if not guard_install(containers_dir):
                continue
            if is_installing(cid):
                if not confirm(f"⚠  {ct_name} is already installing.\n\n  Running it again will restart from scratch.\n  Continue?"):
                    continue
                run_job("install", cid, containers_dir, installations_dir,
                        ubuntu_dir, logs_dir, tmp_dir, force="yes")
            else:
                run_job("install", cid, containers_dir, installations_dir,
                        ubuntu_dir, logs_dir, tmp_dir)

        elif reply == L["ct_start"]:
            scid = ""
            if stor_count(containers_dir, cid) > 0:
                scid = pick_storage_profile(cid, containers_dir, mnt_dir)
                if not scid:
                    continue
            # Ask attach mode
            rc2, sel2 = fzf(
                [f"{GRN}▶  Start and show live output{NC}", f"{DIM}   Start in the background{NC}"],
                f"--header={BLD}── Start ──{NC}", "--no-multi"
            )
            if rc2 != 0 or not sel2:
                continue
            attach = "attach" if "show live output" in strip_ansi(sel2[0]) else "background"
            start_container(cid, containers_dir, installations_dir, mnt_dir, attach, scid)

        elif reply == L["ct_attach"]:
            tmux_attach_hint(ct_name, tsess(cid))

        elif reply == L["ct_stop"]:
            if not confirm(f"Stop '{ct_name}'?"):
                continue
            stop_container(cid, containers_dir, installations_dir, mnt_dir, cache_dir)
            pause(f"'{ct_name}' stopped.")

        elif reply == L["ct_restart"]:
            stop_container(cid, containers_dir, installations_dir, mnt_dir, cache_dir)
            time.sleep(0.3)
            start_container(cid, containers_dir, installations_dir, mnt_dir)

        elif reply == L["ct_open_in"]:
            open_in_submenu(cid, containers_dir, mnt_dir)

        elif reply == L["ct_log"]:
            meta_log = meta.get("log", "")
            ip = cpath(containers_dir, installations_dir, cid)
            if meta_log and ip:
                lf = os.path.join(ip, meta_log)
            else:
                ct_n = cname(containers_dir, cid)
                lf = os.path.join(logs_dir, f"{ct_n}-{cid}-start.log")
            if os.path.isfile(lf):
                content = run_out(["tail", "-100", lf])
                pause(content)
            else:
                pause(f"No log yet for '{ct_name}'.")

        elif reply == L["ct_edit"]:
            ensure_src(cid, containers_dir)
            src = os.path.join(containers_dir, cid, "service.src")
            editor = os.environ.get("EDITOR", "nano")
            subprocess.run([editor, src])
            compile_service(cid, containers_dir)

        elif reply == L["ct_rename"]:
            if not finput(f"New name for '{ct_name}':"):
                continue
            new_name = _tui.FINPUT_RESULT.strip()
            if not new_name:
                continue
            state_data = read_json(os.path.join(containers_dir, cid, "state.json")) or {}
            state_data["name"] = new_name
            write_json(os.path.join(containers_dir, cid, "state.json"), state_data)

        elif reply == L["ct_backups"]:
            from menu.backup_menu import container_backups_menu
            container_backups_menu(cid, containers_dir, installations_dir, backup_dir)

        elif reply == L["ct_profiles"]:
            from menu.storage_menu import persistent_storage_menu
            # Build a minimal ctx-like object if we don't have real ctx
            class _FakeCtx:
                pass
            _ctx2 = _FakeCtx()
            _ctx2.containers_dir = containers_dir
            _ctx2.installations_dir = installations_dir
            _ctx2.storage_dir = os.path.join(mnt_dir, "Storage")
            _ctx2.backup_dir = backup_dir
            _ctx2.mnt_dir = mnt_dir
            _ctx2.cache_dir = cache_dir
            _ctx2.ubuntu_dir = ubuntu_dir
            _ctx2.logs_dir = logs_dir
            _ctx2.groups_dir = os.path.join(mnt_dir, ".sd", "groups")
            _ctx2.blueprints_dir = os.path.join(mnt_dir, "Blueprints")
            persistent_storage_menu(cid, _ctx2)

        elif L["ct_exposure"] in reply:
            from functions.network import exposure_next, exposure_set, exposure_apply, exposure_label
            new_mode = exposure_next(containers_dir, cid)
            exposure_set(containers_dir, cid, new_mode)
            if tmux_up(tsess(cid)):
                exposure_apply(cid, containers_dir, mnt_dir)
            pause(
                f"Port exposure set to: {exposure_label(new_mode)}\n\n"
                "  isolated  — blocked even on host\n"
                "  localhost — only this machine\n"
                "  public    — visible on local network"
            )

        elif "Clone container" in reply:
            if not finput(f"Name for the clone of '{ct_name}':"):
                continue
            new_name = _tui.FINPUT_RESULT.strip()
            if not new_name:
                continue
            import shutil, secrets
            new_cid = secrets.token_hex(4)
            os.makedirs(os.path.join(containers_dir, new_cid), exist_ok=True)
            for f_ in ["service.json", "service.src", "service.src.hash"]:
                src_f = os.path.join(containers_dir, cid, f_)
                if os.path.isfile(src_f):
                    shutil.copy2(src_f, os.path.join(containers_dir, new_cid, f_))
            write_json(os.path.join(containers_dir, new_cid, "state.json"), {
                "name": new_name, "installed": "false", "install_path": new_cid,
            })
            pause(f"Clone '{new_name}' created.")

        elif reply == L["ct_uninstall"]:
            ip = cpath(containers_dir, installations_dir, cid)
            if not confirm(
                f"Uninstall '{ct_name}'?\n\n"
                f"  ✕  Installation subvolume: {ip}\n"
                "  ✕  Snapshots\n\n"
                "  Persistent storage is kept.\n"
                "  Container entry stays — select Install to reinstall."
            ):
                continue
            if ip and os.path.isdir(ip):
                r = subprocess.run(["sudo", "-n", "btrfs", "subvolume", "delete", ip],
                                   stderr=subprocess.DEVNULL)
                if r.returncode != 0:
                    subprocess.run(["rm", "-rf", ip], stderr=subprocess.DEVNULL)
            # Delete snapshots
            ct_snap_dir = snap_dir(backup_dir, cid, ct_name)
            if os.path.isdir(ct_snap_dir):
                import shutil
                shutil.rmtree(ct_snap_dir, ignore_errors=True)
            state_set(containers_dir, cid, "installed", False)
            pause(f"'{ct_name}' uninstalled. Persistent storage kept.")

        elif reply == L["ct_remove"]:
            if not confirm(
                f"Remove container entry '{ct_name}'?\n\n"
                "  No installation or storage files deleted."
            ):
                continue
            for f in [
                os.path.join(cache_dir, "sd_size", cid),
                os.path.join(cache_dir, "gh_tag", cid),
                os.path.join(cache_dir, "gh_tag", cid + ".inst"),
            ]:
                try:
                    os.unlink(f)
                except Exception:
                    pass
            import shutil
            shutil.rmtree(os.path.join(containers_dir, cid), ignore_errors=True)
            pause(f"'{ct_name}' removed.")
            return

        # Cron item click
        elif "⏱" in reply:
            cron_clean = strip_ansi(reply).strip()
            m = re.search(r'⏱\s+(.+?)\s+\[', cron_clean)
            clicked_name = m.group(1).strip() if m else ""
            for ci in range(len(cron_names)):
                if cron_names[ci] == clicked_name:
                    cidx = cron_idxs[ci]
                    csess = cron_sess(cid, cidx)
                    if tmux_up(csess):
                        tmux_attach_hint(f"cron: {cron_names[ci]}", csess)
                    else:
                        pause(f"Cron '{cron_names[ci]}' is not running.")
                    break

        # Action items
        else:
            for ai in range(len(action_labels)):
                if reply != action_labels[ai]:
                    continue
                ip = cpath(containers_dir, installations_dir, cid)
                dsl = action_dsls[ai]
                _run_action(cid, ai, action_labels[ai], dsl, ip, containers_dir)
                break


# ── Action runner ─────────────────────────────────────────────────────────

def _run_action(
    cid: str, ai: int, label: str, dsl: str,
    install_path: str, containers_dir: str,
):
    env_block = env_exports(containers_dir, cid, install_path)
    sname = f"sdAction_{cid}_{ai}"
    runner = make_tmp(f".sd_action_")
    lines = ["#!/usr/bin/env bash", env_block, 'cd "$CONTAINER_ROOT"', ""]

    if "|" in dsl:
        segs = [s.strip() for s in dsl.split("|") if s.strip()]
        for seg in segs:
            if seg.startswith("prompt:"):
                ptxt = seg[7:].strip().strip('"\'')
                lines.append(f'printf "{ptxt}\\n> "')
                lines.append('read -r _sd_input')
                lines.append('[[ -z "$_sd_input" ]] && exit 0')
            elif seg.startswith("select:"):
                scmd = seg[7:].strip()
                skip_hdr = "--skip-header" in scmd
                col_m = re.search(r'--col\s+(\d+)', scmd)
                col_n = int(col_m.group(1)) if col_m else 1
                scmd = re.sub(r'--skip-header', '', scmd)
                scmd = re.sub(r'--col\s*\d*', '', scmd).strip()
                scmd_parts = scmd.split(None, 1)
                if scmd_parts:
                    bin_p = cr_prefix_cmd(scmd_parts[0])
                    rest  = scmd_parts[1] if len(scmd_parts) > 1 else ""
                    full_scmd = f"{bin_p} {rest}".strip()
                lines.append(f'_sd_list=$({full_scmd} 2>/dev/null)')
                lines.append('[[ -z "$_sd_list" ]] && { printf "Nothing found.\\n"; exit 0; }')
                if skip_hdr:
                    lines.append('_sd_list=$(printf "%s" "$_sd_list" | tail -n +2)')
                lines.append(f"_sd_selection=$(printf '%s\\n' \"$_sd_list\" | awk '{{print ${col_n}}}' | fzf --ansi --no-sort --prompt='  ❯ ' --pointer='▶' --height=40% --reverse --border=rounded --margin=1,2 --no-info 2>/dev/null) || exit 0")
                lines.append('[[ -z "$_sd_selection" ]] && exit 0')
            else:
                cmd = seg
                parts = cmd.split(None, 1)
                if parts:
                    bin_p = cr_prefix_cmd(parts[0])
                    rest  = parts[1] if len(parts) > 1 else ""
                    cmd   = f"{bin_p} {rest}".strip()
                cmd = cmd.replace("{input}", "$_sd_input").replace("{selection}", "$_sd_selection")
                lines.append(cmd)
    else:
        lines.append(dsl)

    with open(runner, "w") as fp:
        fp.write("\n".join(lines) + "\n")
    os.chmod(runner, 0o755)

    if tmux_up(sname):
        from functions.constants import KB
        pause(f"Action '{label}' is still running.\n\n  Press {KB['tmux_detach']} to detach.")
        subprocess.run(["tmux", "switch-client", "-t", sname], stderr=subprocess.DEVNULL)
    else:
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", sname,
             f"bash {runner}; rm -f {runner}; printf '\\n\\033[0;32m══ Done ══\\033[0m\\n'; printf 'Press Enter to return...\\n'; read -rs _; tmux switch-client -t simpleDocker 2>/dev/null || true; tmux kill-session -t {sname} 2>/dev/null || true"],
            stderr=subprocess.DEVNULL
        )
        subprocess.run(["tmux", "set-option", "-t", sname, "detach-on-destroy", "off"],
                       stderr=subprocess.DEVNULL)
        from functions.constants import KB
        pause(f"Starting '{label}'…\n\n  Press {KB['tmux_detach']} to detach.")
        subprocess.run(["tmux", "switch-client", "-t", sname], stderr=subprocess.DEVNULL)


def cr_prefix_cmd(s: str) -> str:
    from functions.blueprint import cr_prefix
    return cr_prefix(s)
