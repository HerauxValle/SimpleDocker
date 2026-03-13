"""LUKS encryption management menu."""
from __future__ import annotations
import os
import subprocess
import tempfile
import json
import shutil
import secrets as _sec
import getpass
import re
from pathlib import Path

from functions.constants import (
    FZF_BASE, L, BLD, DIM, NC, GRN, RED, CYN,
    SD_LUKS_KEY_SLOT_MIN, SD_LUKS_KEY_SLOT_MAX,
    SD_DEFAULT_KEYWORD, SD_VERIFICATION_CIPHER,
)
from functions.tui import fzf, confirm, pause, finput, sig_rc, strip_ansi, trim_s
import functions.tui as _tui


def _authkey_path(ctx): return str(Path(ctx.mnt_dir)/".sd"/"authkey")

def _authkey_valid(ctx):
    kp = _authkey_path(ctx)
    if not os.path.isfile(kp): return False
    return subprocess.run(["sudo","-n","cryptsetup","open","--test-passphrase","--key-file",kp,ctx.img_path],capture_output=True).returncode==0

def _authkey_create(ctx, key_file):
    kp = _authkey_path(ctx)
    os.makedirs(os.path.dirname(kp), exist_ok=True)
    kb = _sec.token_bytes(64)
    Path(kp).write_bytes(kb); os.chmod(kp, 0o600)
    return subprocess.run(["sudo","-n","cryptsetup","luksAddKey","--batch-mode","--pbkdf","pbkdf2","--pbkdf-force-iterations","1000","--hash","sha1","--key-slot","0","--key-file",key_file,ctx.img_path,kp],capture_output=True).returncode

def _verified_dir(ctx): return str(Path(ctx.mnt_dir)/".sd"/"verified")
def _verified_id(ctx):
    try: return Path("/etc/machine-id").read_text().strip()[:16]
    except: return ""
def _vs_file(ctx, vid): return os.path.join(_verified_dir(ctx), vid)
def _vs_lines(ctx, vid):
    vf = _vs_file(ctx, vid)
    return Path(vf).read_text().splitlines() if os.path.isfile(vf) else []
def _vs_hostname(ctx, vid): ls=_vs_lines(ctx,vid); return ls[0] if ls else vid
def _vs_slot(ctx, vid): ls=_vs_lines(ctx,vid); return ls[1].strip() if len(ls)>1 else ""
def _vs_pass(ctx, vid): ls=_vs_lines(ctx,vid); return ls[2] if len(ls)>2 else ""
def _vs_write(ctx, vid, slot, passphrase=""):
    vdir=_verified_dir(ctx); os.makedirs(vdir,exist_ok=True)
    hn=subprocess.run(["hostname"],capture_output=True,text=True).stdout.strip()
    Path(_vs_file(ctx,vid)).write_text(f"{hn}\n{slot}\n{passphrase}\n")
def _is_verified(ctx):
    vid=_verified_id(ctx); return bool(vid and os.path.isfile(_vs_file(ctx,vid)))

def _luks_dump(ctx):
    return subprocess.run(["sudo","-n","cryptsetup","luksDump",ctx.img_path],capture_output=True,text=True).stdout

def _slots_used(ctx):
    count=0
    for line in _luks_dump(ctx).splitlines():
        m=line.strip()
        if ": luks2" in m:
            try:
                sid=int(m.split(":")[0].strip())
                if SD_LUKS_KEY_SLOT_MIN<=sid<=SD_LUKS_KEY_SLOT_MAX: count+=1
            except: pass
    return count

def _free_slot(ctx):
    used=set()
    for line in _luks_dump(ctx).splitlines():
        m=line.strip()
        if ": luks2" in m:
            try: used.add(int(m.split(":")[0].strip()))
            except: pass
    for s in range(SD_LUKS_KEY_SLOT_MIN, SD_LUKS_KEY_SLOT_MAX+1):
        if s not in used: return str(s)
    return ""

def _system_agnostic_enabled(ctx):
    for line in _luks_dump(ctx).splitlines():
        if line.strip().startswith("1: luks2"): return True
    return False

def _auto_unlock_enabled(ctx):
    vid=_verified_id(ctx)
    if not vid: return False
    slot=_vs_slot(ctx,vid)
    return bool(slot and slot!="0")

def _knames_file(ctx): return str(Path(ctx.mnt_dir)/".sd"/"keyslot_names.json")
def _read_knames(ctx):
    f=_knames_file(ctx)
    if not os.path.isfile(f): return {}
    try: return json.loads(Path(f).read_text())
    except: return {}
def _write_knames(ctx, d):
    f=_knames_file(ctx); os.makedirs(os.path.dirname(f),exist_ok=True)
    Path(f).write_text(json.dumps(d,indent=2))


def enc_menu(ctx):
    while True:
        agnostic=_system_agnostic_enabled(ctx); auto=_auto_unlock_enabled(ctx)
        ag_lbl=f"{GRN}Enabled{NC}" if agnostic else f"{RED}Disabled{NC}"
        au_lbl=f"{GRN}Enabled{NC}" if auto else f"{RED}Disabled{NC}"
        vid=_verified_id(ctx); vdir=_verified_dir(ctx)
        vs_ids=[f.name for f in Path(vdir).iterdir() if f.is_file()] if os.path.isdir(vdir) else []
        vs_slot_set={_vs_slot(ctx,v) for v in vs_ids if _vs_slot(ctx,v) not in ("","0")}
        dump=_luks_dump(ctx); names=_read_knames(ctx)
        key_lines=[]; key_slots=[]; has_passkeys=False
        for line in dump.splitlines():
            m=line.strip()
            if ": luks2" not in m: continue
            try: sid=int(m.split(":")[0].strip())
            except: continue
            if sid in (0,1): continue
            if sid<SD_LUKS_KEY_SLOT_MIN: continue
            if str(sid) in vs_slot_set: continue
            has_passkeys=True; sname=names.get(str(sid),f"Key {sid}")
            key_lines.append(f" {DIM}◈  {sname}  [s:{sid}]{NC}"); key_slots.append(str(sid))
        slots_used=_slots_used(ctx); slots_total=SD_LUKS_KEY_SLOT_MAX-SD_LUKS_KEY_SLOT_MIN+1

        items=[f"{BLD}  ── General ─────────────────────────{NC}",
               f" {DIM}◈  System Agnostic: {ag_lbl}{NC}",
               f" {DIM}◈  Auto-Unlock: {au_lbl}{NC}",
               f" {DIM}◈  Reset Auth Token{NC}",
               f"{BLD}  ── Verified Systems ────────────────{NC}"]
        for vsid in vs_ids:
            items.append(f" {DIM}◈  {_vs_hostname(ctx,vsid)}  [vs:{vsid}]{NC}")
        items.append(f" {GRN}+  Verify this system{NC}")
        items.append(f"{BLD}  ── Passkeys ────────────────────────{NC}")
        if not has_passkeys: items.append(f"{DIM}  (no passkeys added yet){NC}")
        else: items.extend(key_lines)
        items+=[f" {GRN}+  Add Key{NC}", f"{BLD}  ── Navigation ──────────────────────{NC}", f"{DIM} {L['back']}{NC}"]

        rc,sl=fzf(items,"--header",f"{BLD}── Manage Encryption ──{NC}  {DIM}{slots_used}/{slots_total} slots{NC}")
        if sig_rc(rc): continue
        if rc!=0 or not sl: return
        sc=strip_ansi(sl[0]).strip()
        if L["back"] in sc: return

        # ── System Agnostic ──
        if "System Agnostic" in sc:
            if agnostic:
                sa_vs=sum(1 for v in vs_ids if _vs_slot(ctx,v) not in ("","0"))
                if not has_passkeys and sa_vs==0: pause("Cannot disable — no other unlock method exists.\nAdd a passkey or verify a system first."); continue
                if not confirm("Disable System Agnostic? This image will no longer open on unknown machines."): continue
                tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
                try:
                    (shutil.copy(_authkey_path(ctx),tf.name) if _authkey_valid(ctx) else Path(tf.name).write_text(SD_DEFAULT_KEYWORD))
                    r=subprocess.run(["sudo","-n","cryptsetup","luksKillSlot","--batch-mode","--key-file",tf.name,ctx.img_path,"1"],capture_output=True)
                    pause("System Agnostic disabled." if r.returncode==0 else "Failed.")
                finally: os.unlink(tf.name)
            else:
                if not _authkey_valid(ctx): pause("Auth keyfile missing or invalid.\nUse Reset Auth Token first."); continue
                t1=tempfile.NamedTemporaryFile(delete=False); t2=tempfile.NamedTemporaryFile(delete=False); t1.close(); t2.close()
                try:
                    shutil.copy(_authkey_path(ctx),t1.name); Path(t2.name).write_text(SD_DEFAULT_KEYWORD)
                    r=subprocess.run(["sudo","-n","cryptsetup","luksAddKey","--batch-mode","--pbkdf","pbkdf2","--pbkdf-force-iterations","1000","--hash","sha1","--key-slot","1","--key-file",t1.name,ctx.img_path,t2.name],capture_output=True)
                    pause("System Agnostic enabled." if r.returncode==0 else "Failed.")
                finally: os.unlink(t1.name); os.unlink(t2.name)

        # ── Auto-Unlock ──
        elif "Auto-Unlock" in sc:
            if auto:
                if not has_passkeys: pause("No passkeys exist.\nAdd a passkey first,\nthen disable Auto-Unlock."); continue
                if not confirm("Disable Auto-Unlock? All verified system slots will be removed (cache kept)."): continue
                tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
                try:
                    (shutil.copy(_authkey_path(ctx),tf.name) if _authkey_valid(ctx) else Path(tf.name).write_text(SD_VERIFICATION_CIPHER))
                    ok=True
                    for vsid in vs_ids:
                        dslot=_vs_slot(ctx,vsid)
                        if not dslot or dslot=="0": continue
                        if subprocess.run(["sudo","-n","cryptsetup","luksKillSlot","--batch-mode","--key-file",tf.name,ctx.img_path,dslot],capture_output=True).returncode!=0: ok=False
                        Path(_vs_file(ctx,vsid)).write_text(f"{_vs_hostname(ctx,vsid)}\n\n{_vs_pass(ctx,vsid)}\n")
                    pause("Auto-Unlock disabled." if ok else "Failed (some slots may remain).")
                finally: os.unlink(tf.name)
            else:
                if not _authkey_valid(ctx): pause("Auth keyfile missing or invalid.\nUse Reset Auth first."); continue
                tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
                try:
                    shutil.copy(_authkey_path(ctx),tf.name); en_ok=True; en_count=0
                    for vsid in vs_ids:
                        vspass=_vs_pass(ctx,vsid)
                        if not vspass: continue
                        free_s=_free_slot(ctx)
                        if not free_s: pause(f"No free slots (slots {SD_LUKS_KEY_SLOT_MIN}-{SD_LUKS_KEY_SLOT_MAX} full)."); en_ok=False; break
                        t2=tempfile.NamedTemporaryFile(delete=False); t2.close()
                        try:
                            Path(t2.name).write_text(vspass)
                            if subprocess.run(["sudo","-n","cryptsetup","luksAddKey","--batch-mode","--pbkdf","pbkdf2","--pbkdf-force-iterations","1000","--hash","sha1","--key-slot",free_s,"--key-file",tf.name,ctx.img_path,t2.name],capture_output=True).returncode==0:
                                Path(_vs_file(ctx,vsid)).write_text(f"{_vs_hostname(ctx,vsid)}\n{free_s}\n{vspass}\n"); en_count+=1
                            else: en_ok=False
                        finally: os.unlink(t2.name)
                    if en_ok: pause("No verified systems to restore. Use '+ Verify this system'." if en_count==0 else f"Auto-Unlock enabled ({en_count} system(s) restored).")
                    else: pause("Partially failed — some systems may not have been restored.")
                finally: os.unlink(tf.name)

        # ── Reset Auth Token ──
        elif "Reset Auth Token" in sc:
            print(f"\n  {BLD}── Reset Auth ──{NC}\n  {DIM}Enter any existing passphrase to authorize.{NC}\n")
            ra_pass=getpass.getpass("  Passphrase: ")
            print(f"\n  {BLD}── Reset Auth ──{NC}\n  {DIM}Generating auth keyfile, please wait...{NC}\n")
            tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
            try:
                Path(tf.name).write_text(ra_pass)
                old_kf=_authkey_path(ctx)
                if os.path.isfile(old_kf) and subprocess.run(["sudo","-n","cryptsetup","open","--test-passphrase","--key-file",old_kf,ctx.img_path],capture_output=True).returncode==0:
                    subprocess.run(["sudo","-n","cryptsetup","luksKillSlot","--batch-mode","--key-file",tf.name,ctx.img_path,"0"],capture_output=True)
                    os.unlink(old_kf)
                rrc=_authkey_create(ctx,tf.name)
                pause("Auth keyfile reset." if rrc==0 else "Failed — wrong passphrase?")
            finally: os.unlink(tf.name)

        # ── Verify this system ──
        elif "Verify this system" in sc:
            if _is_verified(ctx):
                my_slot=_vs_slot(ctx,vid)
                hn=subprocess.run(["hostname"],capture_output=True,text=True).stdout.strip()
                if my_slot and my_slot!="0": pause(f"Already verified: {hn} (slot {my_slot}).")
                else: pause("System cached but Auto-Unlock is disabled.\nEnable Auto-Unlock to activate it.")
                continue
            free_vs=_free_slot(ctx)
            if auto and not free_vs: pause(f"No free slots (slots {SD_LUKS_KEY_SLOT_MIN}-{SD_LUKS_KEY_SLOT_MAX} full)."); continue
            if not _authkey_valid(ctx): pause("Auth keyfile missing or invalid.\nUse Reset Auth first."); continue
            hn=subprocess.run(["hostname"],capture_output=True,text=True).stdout.strip()
            if auto:
                t1=tempfile.NamedTemporaryFile(delete=False); t2=tempfile.NamedTemporaryFile(delete=False); t1.close(); t2.close()
                try:
                    shutil.copy(_authkey_path(ctx),t1.name); Path(t2.name).write_text(SD_VERIFICATION_CIPHER)
                    r=subprocess.run(["sudo","-n","cryptsetup","luksAddKey","--batch-mode","--pbkdf","pbkdf2","--pbkdf-force-iterations","1000","--hash","sha1","--key-slot",free_vs,"--key-file",t1.name,ctx.img_path,t2.name],capture_output=True)
                    if r.returncode==0: _vs_write(ctx,vid,free_vs,SD_VERIFICATION_CIPHER); pause(f"Verified: {hn} (slot {free_vs}, auto-unlock active).")
                    else: pause("Failed to add key slot.")
                finally: os.unlink(t1.name); os.unlink(t2.name)
            else:
                _vs_write(ctx,vid,"",""); pause(f"Cached: {hn} (Auto-Unlock disabled — enable to activate).")

        # ── Verified system ──
        elif "[vs:" in sc:
            m=re.search(r'\[vs:([a-f0-9]+)\]',sc)
            if not m: continue
            sel_vsid=m.group(1); sel_vshost=_vs_hostname(ctx,sel_vsid); sel_vslot=_vs_slot(ctx,sel_vsid)
            rc2,al=fzf(["Unauthorize","Cancel"],"--header",f"{BLD}── {sel_vshost} ({sel_vsid}) ──{NC}")
            if rc2!=0 or not al or al[0].strip()!="Unauthorize": continue
            if sel_vsid==vid and auto and not has_passkeys:
                rem=sum(1 for ci in vs_ids if ci!=sel_vsid and _vs_slot(ctx,ci) not in ("","0"))
                if rem==0: pause("Cannot unauthorize — this is the only unlock method.\nAdd a passkey first."); continue
            if not confirm(f"Unauthorize {sel_vshost}?"): continue
            ok=True
            if sel_vslot and sel_vslot!="0":
                tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
                try:
                    (shutil.copy(_authkey_path(ctx),tf.name) if _authkey_valid(ctx) else Path(tf.name).write_text(SD_VERIFICATION_CIPHER))
                    if subprocess.run(["sudo","-n","cryptsetup","luksKillSlot","--batch-mode","--key-file",tf.name,ctx.img_path,sel_vslot],capture_output=True).returncode!=0: ok=False
                finally: os.unlink(tf.name)
            vf=_vs_file(ctx,sel_vsid)
            if os.path.isfile(vf): os.unlink(vf)
            pause("Unauthorize complete." if ok else "Failed to remove slot (cache removed).")

        # ── Passkey ──
        elif "[s:" in sc:
            m=re.search(r'\[s:(\d+)\]',sc)
            if not m: continue
            sn=m.group(1); names=_read_knames(ctx); cur_name=names.get(sn,f"Key {sn}")
            rc3,al3=fzf(["Rename","Remove","Cancel"],"--header",f"{BLD}── {cur_name} ──{NC}")
            if rc3!=0 or not al3: continue
            action=al3[0].strip()
            if action=="Rename":
                if not finput(f"New name for \"{cur_name}\":"): continue
                nn=_tui.FINPUT_RESULT
                if not nn: continue
                names[sn]=nn; _write_knames(ctx,names); pause(f"Renamed to \"{nn}\".")
            elif action=="Remove":
                pk_count=len(key_slots); vs_active=sum(1 for v in vs_ids if _vs_slot(ctx,v) not in ("","0"))
                if not auto and pk_count<=1: pause("Cannot remove — Auto-Unlock is disabled.\nKeep at least one passkey\nor re-enable Auto-Unlock first."); continue
                if auto and pk_count<=1 and vs_active==0: pause("Cannot remove — this is the only non-auto-unlock key.\nVerify a system or keep this key."); continue
                if not confirm(f"Remove key \"{cur_name}\"?"): continue
                tf=tempfile.NamedTemporaryFile(delete=False); tf.close()
                try:
                    if _authkey_valid(ctx): shutil.copy(_authkey_path(ctx),tf.name)
                    else:
                        rp=getpass.getpass(f"\n  Passphrase for \"{cur_name}\": ")
                        Path(tf.name).write_text(rp)
                    r=subprocess.run(["sudo","-n","cryptsetup","luksKillSlot","--batch-mode","--key-file",tf.name,ctx.img_path,sn],capture_output=True)
                    if r.returncode==0:
                        names=_read_knames(ctx); names.pop(sn,None); _write_knames(ctx,names); pause("Key removed.")
                    else: pause("Failed.")
                finally: os.unlink(tf.name)

        # ── Add Key ──
        elif "Add Key" in sc:
            free_k=_free_slot(ctx)
            if not free_k: pause(f"No free slots (slots {SD_LUKS_KEY_SLOT_MIN}-{SD_LUKS_KEY_SLOT_MAX} full)."); continue
            rname=_sec.token_hex(4); kname=rname
            pbkdf="argon2id"; ram="262144"; threads="4"; iter_ms="1000"
            cipher="aes-xts-plain64"; keybits="512"; hash_alg="sha256"; sector="512"
            param_done=False
            while not param_done:
                pl=[f"{BLD}  ── Parameters ──────────────────────{NC}",
                    f"  {'name':<10}{CYN}{kname}{NC}", f"  {'pbkdf':<10}{CYN}{pbkdf}{NC}",
                    f"  {'ram':<10}{CYN}{ram} KiB{NC}", f"  {'threads':<10}{CYN}{threads}{NC}",
                    f"  {'iter-ms':<10}{CYN}{iter_ms}{NC}", f"  {'cipher':<10}{CYN}{cipher}{NC}",
                    f"  {'key-bits':<10}{CYN}{keybits}{NC}", f"  {'hash':<10}{CYN}{hash_alg}{NC}",
                    f"  {'sector':<10}{CYN}{sector}{NC}",
                    f"{BLD}  ── Navigation ──────────────────────{NC}", f"{GRN}▷  Continue{NC}", f"{RED}×  Cancel{NC}"]
                rp2,psl=fzf(pl,"--header",f"{BLD}── Encryption parameters ──{NC}\n{DIM}  Select a param to change it.{NC}")
                if sig_rc(rp2): continue
                if rp2!=0 or not psl: break
                ps=strip_ansi(psl[0]).strip()
                if "Continue" in ps: param_done=True
                elif "Cancel" in ps: break
                elif ps.startswith("name") and finput(f"Key name (blank = {rname}):"): kname=_tui.FINPUT_RESULT or rname
                elif ps.startswith("pbkdf"):
                    r2,p2=fzf(["argon2id","argon2i","pbkdf2"],"--header","pbkdf")
                    if r2==0 and p2: pbkdf=p2[0].strip()
                elif ps.startswith("ram") and finput("RAM in KiB:") and _tui.FINPUT_RESULT.isdigit(): ram=_tui.FINPUT_RESULT
                elif ps.startswith("threads") and finput("Threads:") and _tui.FINPUT_RESULT.isdigit(): threads=_tui.FINPUT_RESULT
                elif ps.startswith("iter") and finput("Iteration ms:") and _tui.FINPUT_RESULT.isdigit(): iter_ms=_tui.FINPUT_RESULT
                elif ps.startswith("cipher"):
                    r2,p2=fzf(["aes-xts-plain64","chacha20-poly1305"],"--header","cipher")
                    if r2==0 and p2: cipher=p2[0].strip()
                elif ps.startswith("key-bits"):
                    r2,p2=fzf(["256","512"],"--header","key-bits")
                    if r2==0 and p2: keybits=p2[0].strip()
                elif ps.startswith("hash"):
                    r2,p2=fzf(["sha256","sha512","sha1"],"--header","hash")
                    if r2==0 and p2: hash_alg=p2[0].strip()
                elif ps.startswith("sector"):
                    r2,p2=fzf(["512","1024","2048","4096"],"--header","sector size")
                    if r2==0 and p2: sector=p2[0].strip()
            if not param_done: continue
            print(f"\n  {BLD}── Add Key: {kname} ──{NC}\n")
            np1=getpass.getpass("  New passphrase: "); np2=getpass.getpass("  Confirm:       ")
            if np1!=np2 or not np1: pause("Mismatch or empty."); continue
            t1=tempfile.NamedTemporaryFile(delete=False); t2=tempfile.NamedTemporaryFile(delete=False); t1.close(); t2.close()
            try:
                (shutil.copy(_authkey_path(ctx),t1.name) if _authkey_valid(ctx) else Path(t1.name).write_text(SD_VERIFICATION_CIPHER))
                Path(t2.name).write_text(np1)
                print(f"\n  {BLD}── Add Key: {kname} ──{NC}\n  {DIM}Adding key, this might take a few seconds...{NC}\n")
                r=subprocess.run(["sudo","-n","cryptsetup","luksAddKey","--batch-mode","--pbkdf",pbkdf,"--pbkdf-memory",ram,"--pbkdf-parallel",threads,"--iter-time",iter_ms,"--key-slot",free_k,"--key-file",t1.name,ctx.img_path,t2.name],capture_output=True)
                if r.returncode!=0: pause("Failed to add key."); continue
                names=_read_knames(ctx); names[free_k]=kname; _write_knames(ctx,names)
                pause(f"Key \"{kname}\" added (slot {free_k}).")
            finally: os.unlink(t1.name); os.unlink(t2.name)
