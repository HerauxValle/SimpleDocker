"""Caddy reverse proxy + mDNS menu."""
from __future__ import annotations
import os, subprocess, json, tempfile, shutil, re
from pathlib import Path

from functions.constants import FZF_BASE, L, BLD, DIM, NC, GRN, RED, CYN, YLW
from functions.tui import fzf, confirm, pause, finput, sig_rc, strip_ansi, trim_s
import functions.tui as _tui
from functions.network import netns_ct_ip, netns_idx
from functions.container import load_containers


# ── path helpers ─────────────────────────────────────────────────────────────

def _cfg(ctx): return str(Path(ctx.mnt_dir)/".sd"/"proxy.json")
def _caddyfile(ctx): return str(Path(ctx.mnt_dir)/".sd"/"Caddyfile")
def _pidfile(ctx): return str(Path(ctx.mnt_dir)/".sd"/".caddy.pid")
def _caddy_bin(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"caddy")
def _caddy_storage(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"data")
def _caddy_runner(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"run.sh")
def _caddy_log(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"caddy.log")
def _dns_pidfile(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"dnsmasq.pid")
def _dns_conf(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"dnsmasq.conf")
def _dns_log(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"dnsmasq.log")
def _avahi_piddir(ctx): return str(Path(ctx.mnt_dir)/".sd"/"caddy"/"avahi")
def _avahi_pidfile(ctx, name): return os.path.join(_avahi_piddir(ctx), name.replace('.','_').replace('/','_')+".pid")
def _sudoers_path(ctx): return f"/etc/sudoers.d/simpledocker_caddy_{os.environ.get('USER',subprocess.run(['id','-un'],capture_output=True,text=True).stdout.strip())}"
def _hostpkg_flagfile(ctx, pkg): return str(Path(ctx.mnt_dir)/".sd"/f".sd_hostpkg_{pkg}")
def _hostpkg_installed(ctx, pkg): return os.path.isfile(_hostpkg_flagfile(ctx, pkg))
def _hostpkg_mark(ctx, pkg): Path(_hostpkg_flagfile(ctx, pkg)).touch()
def _hostpkg_unmark(ctx, pkg):
    f=_hostpkg_flagfile(ctx, pkg)
    if os.path.isfile(f): os.unlink(f)


# ── state helpers ─────────────────────────────────────────────────────────────

def _proxy_running(ctx):
    try:
        pid=Path(_pidfile(ctx)).read_text().strip()
        if pid: os.kill(int(pid), 0); return True
    except: pass
    return False

def _proxy_get(ctx, key):
    try: return json.loads(Path(_cfg(ctx)).read_text()).get(key,"")
    except: return ""

def _lan_ip():
    r=subprocess.run(["ip","route","get","1"],capture_output=True,text=True)
    for tok in r.stdout.split():
        pass
    # parse src field
    parts=r.stdout.split()
    for i,p in enumerate(parts):
        if p=="src" and i+1<len(parts): return parts[i+1]
    r2=subprocess.run(["hostname","-I"],capture_output=True,text=True)
    return r2.stdout.split()[0] if r2.stdout.split() else ""

def _mdns_name(url):
    return url if url.endswith(".local") else url+".local"

def _exposure_get(ctx, cid):
    f=Path(ctx.containers_dir)/cid/"exposure"
    if not f.is_file(): return "localhost"
    v=f.read_text().strip()
    return v if v in ("isolated","localhost","public") else "localhost"


# ── avahi helpers ─────────────────────────────────────────────────────────────

def avahi_start(ctx, containers):
    if not shutil.which("avahi-publish"): return
    avahi_stop(ctx)
    os.makedirs(_avahi_piddir(ctx), exist_ok=True)
    lan=_lan_ip()
    if not lan: return
    seen=set()
    for cid, info in containers.items():
        if not info.get("installed"): continue
        port=info.get("port","")
        if not port or port=="0": continue
        mdns=f"{cid}.local"
        if mdns in seen: continue
        seen.add(mdns)
        p=subprocess.Popen(["setsid","avahi-publish","--address","-R",mdns,lan],
                           stdin=subprocess.DEVNULL, stdout=open(_dns_log(ctx),"a"), stderr=subprocess.STDOUT)
        Path(_avahi_pidfile(ctx,mdns)).write_text(str(p.pid))
    try:
        cfg=json.loads(Path(_cfg(ctx)).read_text())
        for r in cfg.get("routes",[]):
            url=r.get("url",""); cid=r.get("cid","")
            if _exposure_get(ctx,cid)!="public": continue
            mdns=_mdns_name(url)
            if mdns in seen: continue
            seen.add(mdns)
            p=subprocess.Popen(["setsid","avahi-publish","--address","-R",mdns,lan],
                               stdin=subprocess.DEVNULL, stdout=open(_dns_log(ctx),"a"), stderr=subprocess.STDOUT)
            Path(_avahi_pidfile(ctx,mdns)).write_text(str(p.pid))
    except: pass

def avahi_stop(ctx):
    pd=_avahi_piddir(ctx)
    if os.path.isdir(pd):
        for pf in Path(pd).glob("*.pid"):
            try: pid=int(pf.read_text()); os.kill(pid,15)
            except: pass
            pf.unlink(missing_ok=True)
    subprocess.run(["pkill","-f","avahi-publish.*--address"],capture_output=True)


# ── DNS (dnsmasq) ─────────────────────────────────────────────────────────────

def _dns_write(ctx):
    lan=_lan_ip()
    if not lan: return False
    r=subprocess.run(["awk","/^nameserver/{print $2; exit}","/etc/resolv.conf"],capture_output=True,text=True)
    upstream=r.stdout.strip() or "1.1.1.1"
    if upstream in (lan,"127.0.0.53"): upstream="1.1.1.1"
    conf=_dns_conf(ctx); os.makedirs(os.path.dirname(conf),exist_ok=True)
    lines=[f"listen-address={lan}","bind-interfaces","port=53",f"log-facility={_dns_log(ctx)}",f"server={upstream}"]
    try:
        cfg=json.loads(Path(_cfg(ctx)).read_text())
        for r2 in cfg.get("routes",[]):
            url=r2.get("url","")
            if url: lines.append(f"address=/{url}/{lan}")
    except: pass
    Path(conf).write_text("\n".join(lines)+"\n")
    return True

def _dns_start(ctx):
    if not shutil.which("dnsmasq"): return
    if not _dns_write(ctx): return
    lan=_lan_ip()
    if not lan: return
    _dns_stop(ctx)
    subprocess.Popen(["setsid","sudo","-n","dnsmasq",f"--conf-file={_dns_conf(ctx)}",f"--pid-file={_dns_pidfile(ctx)}"],
                     stdin=subprocess.DEVNULL, stdout=open(_dns_log(ctx),"a"), stderr=subprocess.STDOUT)

def _dns_stop(ctx):
    try:
        pid=Path(_dns_pidfile(ctx)).read_text().strip()
        if pid: subprocess.run(["sudo","-n","kill",pid],capture_output=True)
    except: pass
    Path(_dns_pidfile(ctx)).unlink(missing_ok=True)


# ── Caddy config write ────────────────────────────────────────────────────────

def _proxy_write(ctx, containers: dict):
    cf=_caddyfile(ctx)
    Path(cf).write_text("{\n  admin off\n  local_certs\n}\n\n")
    lan=_lan_ip()

    def stanza(exp, scheme, host, ct_ip, port):
        if exp=="isolated": return ""
        if scheme=="https": return f"https://{host} {{\n  tls internal\n  reverse_proxy {ct_ip}:{port}\n}}\n\n"
        return f"http://{host} {{\n  reverse_proxy {ct_ip}:{port}\n}}\n\n"

    try:
        cfg=json.loads(Path(_cfg(ctx)).read_text())
        seen_cid=set()
        for r in cfg.get("routes",[]):
            url=r.get("url",""); cid=r.get("cid",""); https=r.get("https","false")
            info=containers.get(cid,{}); port=info.get("port","")
            if not port or port=="0": continue
            ct_ip=netns_ct_ip(cid, ctx.mnt_dir)
            exp=_exposure_get(ctx,cid)
            scheme="https" if https==True or https=="true" else "http"
            with open(cf,"a") as f:
                f.write(stanza(exp,scheme,url,ct_ip,port))
                mdns=_mdns_name(url)
                if mdns!=url: f.write(stanza(exp,scheme,mdns,ct_ip,port))
            seen_cid.add(cid)

        for cid, info in containers.items():
            if not info.get("installed"): continue
            port=info.get("port","")
            if not port or port=="0": continue
            if cid in seen_cid: continue
            seen_cid.add(cid); ct_ip=netns_ct_ip(cid,ctx.mnt_dir); exp=_exposure_get(ctx,cid)
            with open(cf,"a") as f: f.write(stanza(exp,"http",f"{cid}.local",ct_ip,port))
    except Exception as e:
        pass


# ── hosts file ────────────────────────────────────────────────────────────────

def _update_hosts(ctx, action="add", containers: dict = None):
    tmp=tempfile.NamedTemporaryFile(delete=False,mode="w",suffix=".hosts")
    try:
        with open("/etc/hosts") as hf:
            for line in hf:
                if "# simpleDocker" not in line: tmp.write(line)
        if action=="add" and containers:
            lan=_lan_ip()
            try:
                cfg=json.loads(Path(_cfg(ctx)).read_text())
                for r in cfg.get("routes",[]):
                    url=r.get("url",""); cid=r.get("cid","")
                    if not url: continue
                    exp=_exposure_get(ctx,cid)
                    hip=lan if exp=="public" and lan else "127.0.0.1"
                    tmp.write(f"{hip} {url}  # simpleDocker\n")
                    mdns=_mdns_name(url)
                    if mdns!=url: tmp.write(f"{hip} {mdns}  # simpleDocker\n")
                    tmp.write(f"127.0.0.1 {cid}.local  # simpleDocker\n")
            except: pass
            for cid, info in containers.items():
                if not info.get("installed"): continue
                port=info.get("port","")
                if not port or port=="0": continue
                exp=_exposure_get(ctx,cid)
                if exp=="isolated": continue
                hip=lan if exp=="public" and lan else "127.0.0.1"
                tmp.write(f"{hip} {cid}.local  # simpleDocker\n")
        tmp_path=tmp.name; tmp.close()
        subprocess.run(["sudo","-n","tee","/etc/hosts"],stdin=open(tmp_path),capture_output=True)
    finally:
        tmp.close()
        try: os.unlink(tmp.name)
        except: pass


# ── sudoers / runner ──────────────────────────────────────────────────────────

def _ensure_sudoers(ctx):
    bin_=_caddy_bin(ctx); runner=_caddy_runner(ctx); storage=_caddy_storage(ctx)
    if not os.path.isfile(bin_) and not shutil.which("dnsmasq"): return False
    nopasswd=[]
    if os.path.isfile(bin_):
        Path(runner).write_text(f"#!/bin/bash\nexport CADDY_STORAGE_DIR={shutil.quote(storage)}\nexec {shutil.quote(bin_)} \"$@\"\n")
        os.chmod(runner,0o755)
        nopasswd+=[runner,"/usr/sbin/update-ca-certificates","/usr/bin/update-ca-certificates"]
    dm=shutil.which("dnsmasq"); pk=shutil.which("pkill") or "/usr/bin/pkill"
    if dm: nopasswd+=[dm,pk]
    sc=shutil.which("systemctl")
    if sc: nopasswd+=[f"{sc} start avahi-daemon", f"{sc} enable avahi-daemon"]
    me=subprocess.run(["id","-un"],capture_output=True,text=True).stdout.strip()
    line=f"{me} ALL=(ALL) NOPASSWD: {', '.join(nopasswd)}\n"
    subprocess.run(["sudo","-n","tee",_sudoers_path(ctx)],input=line.encode(),capture_output=True)
    return True

def shutil_quote(s): return shutil.which(s) or s  # placeholder


# ── proxy start/stop ──────────────────────────────────────────────────────────

def proxy_start(ctx, containers: dict, background=False):
    if not os.path.isfile(_caddy_bin(ctx)): return False
    if not os.path.isfile(_cfg(ctx)): return True
    _proxy_write(ctx, containers)
    _update_hosts(ctx,"add",containers)
    _ensure_sudoers(ctx)
    _dns_start(ctx)
    subprocess.run(["sudo","-n","systemctl","start","avahi-daemon"],capture_output=True)
    avahi_start(ctx, containers)
    runner=_caddy_runner(ctx)
    p=subprocess.Popen(["setsid","sudo","-n",runner,"run","--config",_caddyfile(ctx)],
                       stdin=subprocess.DEVNULL, stdout=open(_caddy_log(ctx),"a"), stderr=subprocess.STDOUT)
    Path(_pidfile(ctx)).write_text(str(p.pid))
    if background:
        import threading
        def _trust():
            import time; w=0
            while not _proxy_running(ctx) and w<20: time.sleep(0.3); w+=1
            _trust_ca(ctx)
        threading.Thread(target=_trust,daemon=True).start()
        return True
    import time; time.sleep(1.2)
    if not _proxy_running(ctx): return False
    _trust_ca(ctx); return True

def proxy_stop(ctx):
    try:
        pid=Path(_pidfile(ctx)).read_text().strip()
        if pid: subprocess.run(["kill",pid],capture_output=True)
    except: pass
    Path(_pidfile(ctx)).unlink(missing_ok=True)
    _dns_stop(ctx); avahi_stop(ctx)
    if os.path.isfile(_cfg(ctx)): _update_hosts(ctx,"remove")

def _trust_ca(ctx):
    subprocess.run(["sudo","-n","chown","-R",f"{os.getuid()}:{os.getgid()}",_caddy_storage(ctx)],capture_output=True)
    import time; waited=0
    ca=Path(_caddy_storage(ctx))/"pki"/"authorities"/"local"/"root.crt"
    while not ca.is_file() and waited<10: time.sleep(0.5); waited+=1
    subprocess.run(["sudo","-n","chown","-R",f"{os.getuid()}:{os.getgid()}",_caddy_storage(ctx)],capture_output=True)
    if not ca.is_file(): return
    subprocess.run(["sudo","-n","cp",str(ca),"/usr/local/share/ca-certificates/simpleDocker-caddy.crt"],capture_output=True)
    subprocess.run(["sudo","-n","update-ca-certificates"],capture_output=True)
    dest=Path(ctx.mnt_dir)/".sd"/"caddy"/"ca.crt"
    try: shutil.copy(str(ca),str(dest))
    except: pass


# ── Caddy install ─────────────────────────────────────────────────────────────

def _install_caddy(ctx, mode="install"):
    os.makedirs(str(Path(ctx.mnt_dir)/".sd"/"caddy"), exist_ok=True)
    dest=_caddy_bin(ctx)
    log=f"{ctx.tmp_dir}/.sd_caddy_log_{os.getpid()}"
    script=tempfile.NamedTemporaryFile(delete=False,suffix=".sh",mode="w")
    caddy_dir = str(Path(ctx.mnt_dir) / ".sd" / "caddy")
    script.write(f"""#!/usr/bin/env bash
exec > >(tee -a {log}) 2>&1
set -uo pipefail
die() {{ printf "\\033[0;31mFAIL: %s\\033[0m\\n" "$*"; exit 1; }}
printf "\\033[1m── Installing Caddy ──────────────────────────\\033[0m\\n"
mkdir -p {caddy_dir!r}
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; armv7l) ARCH=armv7;; *) ARCH=amd64;; esac
VER=""
API_RESP=$(curl -fsSL --max-time 15 "https://api.github.com/repos/caddyserver/caddy/releases/latest" 2>&1) && {{
    VER=$(printf "%s" "$API_RESP" | grep -o '"tag_name":"[^"]*"' | cut -d: -f2 | tr -d '"v ')
}} || printf "GitHub API unreachable\\n"
[[ -z "$VER" ]] && VER=$(curl -fsSL --max-time 15 -o /dev/null -w "%{{url_effective}}" "https://github.com/caddyserver/caddy/releases/latest" 2>&1 | grep -o "[0-9]*\\.[0-9]*\\.[0-9]*" | head -1)
[[ -z "$VER" ]] && {{ printf "Using fallback version 2.9.1\\n"; VER="2.9.1"; }}
printf "Version: %s\\n" "$VER"
TMPD=$(mktemp -d)
URL="https://github.com/caddyserver/caddy/releases/download/v${{VER}}/caddy_${{VER}}_linux_${{ARCH}}.tar.gz"
curl -fsSL --max-time 120 "$URL" -o "$TMPD/caddy.tar.gz" || die "Download failed"
tar -xzf "$TMPD/caddy.tar.gz" -C "$TMPD" caddy || die "Extraction failed"
mv "$TMPD/caddy" {dest!r}; chmod +x {dest!r}; rm -rf "$TMPD"
printf "\\033[0;32m✓ Caddy binary ready\\033[0m\\n"
printf "\\033[1m── Installing mDNS (avahi-utils) ─────────────\\033[0m\\n"
sudo -n apt-get {"install --reinstall" if mode=="reinstall" else "install"} -y avahi-utils 2>&1
printf "\\033[0;32m✓ mDNS ready\\033[0m\\n"
printf "\\033[1;32m✓ Caddy + mDNS installed.\\033[0m\\n"
""")
    script.close(); os.chmod(script.name,0o755)
    sess=f"sdCaddyMdnsInst_{os.getpid()}"
    subprocess.Popen(["tmux","new-session","-d","-s",sess,"-x","220","-y","50",script.name])
    return sess


# ── Load containers helper ────────────────────────────────────────────────────

def _get_containers(ctx):
    """Returns dict cid -> {name, port, installed}"""
    from functions.container import load_containers as _lc, validate_containers
    ids, names, sjs = _lc(ctx.containers_dir, False)
    result={}
    for i,cid in enumerate(ids):
        sj=sjs[i] if i<len(sjs) else {}
        port=(sj.get("environment",{}).get("PORT","") or sj.get("meta",{}).get("port","") or "")
        installed=str(sj.get("state",{}).get("installed","")).lower()=="true"
        result[cid]={"name":names[i],"port":str(port),"installed":installed}
    return result


# ── menu ──────────────────────────────────────────────────────────────────────

def proxy_menu(ctx):
    if not os.path.isfile(_cfg(ctx)):
        Path(_cfg(ctx)).write_text('{"autostart":false,"routes":[]}')
        os.makedirs(os.path.dirname(_cfg(ctx)), exist_ok=True)

    SEP_INST   =f"{BLD}  ── Installation ─────────────────────{NC}"
    SEP_STARTUP=f"{BLD}  ── Startup ──────────────────────────{NC}"
    SEP_ROUTES =f"{BLD}  ── Rerouting ────────────────────────{NC}"
    SEP_EXP    =f"{BLD}  ── Port exposure ────────────────────{NC}"
    SEP_NAV    =f"{BLD}  ── Navigation ───────────────────────{NC}"

    while True:
        containers=_get_containers(ctx)
        autostart=str(_proxy_get(ctx,"autostart")).lower()=="true"
        caddy_ok=os.path.isfile(_caddy_bin(ctx))
        at_s=f"{GRN}on{NC}" if autostart else f"{DIM}off{NC}"
        inst_s=f"{GRN}installed{NC}" if caddy_ok else f"{RED}not installed{NC}"
        run_s=f"{GRN}running{NC}" if _proxy_running(ctx) else f"{RED}stopped{NC}"

        # Build route lines
        route_lines=[]; route_urls=[]
        try:
            cfg=json.loads(Path(_cfg(ctx)).read_text())
            for r in cfg.get("routes",[]):
                rurl=r.get("url",""); rcid=r.get("cid",""); rhttps=r.get("https","false")
                rname=containers.get(rcid,{}).get("name",rcid)
                proto="https" if rhttps==True or rhttps=="true" else "http"
                mdns=_mdns_name(rurl)
                route_lines.append(f" {CYN}◈{NC}  {CYN}{rurl}{NC}  →  {rname}  {DIM}({proto}  mDNS: {mdns}){NC}")
                route_urls.append(rurl)
        except: pass

        items=[SEP_INST, f" {DIM}◈{NC}  Caddy + mDNS — {inst_s}",
               SEP_STARTUP, f" {DIM}◈{NC}  Running — {run_s}",
               f" {DIM}◈{NC}  Autostart — {at_s}  {DIM}(starts with img mount){NC}",
               SEP_ROUTES]
        items.extend(route_lines)
        items.append(f"{GRN} +{NC}  Add URL")
        items.append(SEP_EXP)

        exp_cids=[]; exp_names=[]
        for cid, info in containers.items():
            if not info.get("installed"): continue
            port=info.get("port","")
            if not port or port=="0": continue
            ct_ip=netns_ct_ip(cid, ctx.mnt_dir)
            ename=info.get("name",cid)
            items.append(f" {_exposure_label(_exposure_get(ctx,cid))}  {ename}  {DIM}{ct_ip}:{port}  {cid}.local{NC}")
            exp_cids.append(cid); exp_names.append(ename)
        if not exp_cids: items.append(f"{DIM}  (no installed containers with ports){NC}")

        items+=[SEP_NAV, f"{DIM} {L['back']}{NC}"]

        idx_str=str(netns_idx(ctx.mnt_dir))
        rc,sl=fzf(items,"--header",f"{BLD}── Reverse proxy ──{NC}  {DIM}ns: 10.88.{idx_str}.0/24{NC}")
        if sig_rc(rc): continue
        if rc!=0 or not sl: return
        sc=strip_ansi(sl[0]).strip()
        if L["back"] in sc: return

        if "Caddy + mDNS" in sc:
            if caddy_ok:
                rc2,al=fzf(["Reinstall / update","Uninstall","View log","View Caddyfile","Reset proxy config"],
                           "--header",f"{BLD}── Caddy + mDNS ──{NC}")
                if rc2!=0 or not al: continue
                act=al[0].strip()
                if act=="Reinstall / update":
                    _install_caddy(ctx,"reinstall"); _hostpkg_mark(ctx,"avahi-utils")
                elif act=="Uninstall":
                    proxy_stop(ctx); avahi_stop(ctx)
                    for f in [_caddy_bin(ctx),_caddy_runner(ctx)]:
                        try: os.unlink(f)
                        except: pass
                    subprocess.run(["sudo","-n","rm","-f",_sudoers_path(ctx)],capture_output=True)
                    scr=tempfile.NamedTemporaryFile(delete=False,suffix=".sh",mode="w")
                    scr.write("#!/usr/bin/env bash\nsudo -n apt-get remove -y avahi-utils 2>&1\n")
                    scr.close(); os.chmod(scr.name,0o755)
                    subprocess.Popen(["tmux","new-session","-d","-s","sdAvahiUninst","-x","200","-y","40",scr.name])
                    _hostpkg_unmark(ctx,"avahi-utils")
                elif act=="View log":
                    try: log_txt=Path(_caddy_log(ctx)).read_text()
                    except: log_txt="(no log)"
                    pause("\n".join(log_txt.splitlines()[-50:]))
                elif act=="View Caddyfile":
                    try: cf_txt=Path(_caddyfile(ctx)).read_text()
                    except: cf_txt="(no Caddyfile)"
                    pause(cf_txt)
                elif act=="Reset proxy config":
                    if not confirm("⚠  This will:\n  - Remove all custom rerouting URLs\n  - Reset all containers to default exposure (localhost)\n\nThe Caddyfile will be regenerated from scratch.\nContinue?"): continue
                    proxy_stop(ctx)
                    Path(_cfg(ctx)).write_text('{"autostart":false,"routes":[]}')
                    for cid in containers:
                        ef=Path(ctx.containers_dir)/cid/"exposure"
                        ef.unlink(missing_ok=True)
                    _proxy_write(ctx,containers); _update_hosts(ctx,"add",containers)
                    proxy_start(ctx,containers); pause("Proxy config reset and restarted.")
            else:
                sess=_install_caddy(ctx); _hostpkg_mark(ctx,"avahi-utils")
                import time
                while subprocess.run(["tmux","has-session","-t",sess],capture_output=True).returncode==0:
                    time.sleep(0.3)

        elif "Autostart" in sc:
            try:
                cfg=json.loads(Path(_cfg(ctx)).read_text())
                cfg["autostart"]=not autostart
                Path(_cfg(ctx)).write_text(json.dumps(cfg,indent=2))
            except: pass

        elif "Running" in sc:
            if _proxy_running(ctx):
                proxy_stop(ctx); avahi_stop(ctx); pause("Proxy stopped.")
            else:
                if proxy_start(ctx,containers):
                    if _hostpkg_installed(ctx,"avahi-utils"): avahi_start(ctx,containers)
                    pause("Proxy started.")
                else:
                    try: log_tail="\n".join(Path(_caddy_log(ctx)).read_text().splitlines()[-30:])
                    except: log_tail="(no log yet)"
                    pause(f"⚠  Caddy failed to start.\n\nLog:\n{log_tail}")

        elif "Add URL" in sc:
            if not containers: pause("No containers found."); continue
            cnames=[info["name"] for info in containers.values()]
            rc3,cl=fzf(cnames,"--header",f"{BLD}── Add route ──{NC}  {DIM}Select container{NC}")
            if rc3!=0 or not cl: continue
            csel=cl[0].strip()
            ncid=next((cid for cid,info in containers.items() if info["name"]==csel),"")
            if not ncid: continue
            nport=containers[ncid].get("port","")
            if not nport or nport=="0":
                pause(f"⚠  {csel} has no port defined.\n  Add 'port = XXXX' under [meta] in its blueprint.")
                continue
            if not finput("Enter URL  (e.g. comfyui.local, myapp.local)\n\n  Use .local for zero-config LAN access on all devices (mDNS)."): continue
            nurl=_tui.FINPUT_RESULT.strip().lstrip("http://").lstrip("https://").split("/")[0]
            if not nurl: continue
            rc4,pl=fzf(["http  (no cert needed)","https  (tls internal, CA trusted automatically)"],
                       "--header",f"Protocol for {nurl}")
            if rc4!=0 or not pl: continue
            nhttps=pl[0].strip().startswith("https")
            try:
                cfg=json.loads(Path(_cfg(ctx)).read_text())
                cfg.setdefault("routes",[]).append({"url":nurl,"cid":ncid,"https":nhttps})
                Path(_cfg(ctx)).write_text(json.dumps(cfg,indent=2))
            except: pass
            if _proxy_running(ctx): proxy_stop(ctx); proxy_start(ctx,containers)
            elif autostart: proxy_start(ctx,containers,background=True)
            scheme="https" if nhttps else "http"
            pause(f"✓ Added: {nurl} → {csel} (port {nport})\n\n  Visit: {scheme}://{nurl}")

        else:
            # Check exposure cycle
            for i,ename in enumerate(exp_names):
                if ename not in sc: continue
                ecid=exp_cids[i]
                cur=_exposure_get(ctx,ecid)
                nxt={"isolated":"localhost","localhost":"public","public":"isolated"}[cur]
                Path(ctx.containers_dir).joinpath(ecid,"exposure").write_text(nxt)
                # apply iptables if running
                from functions.network import exposure_apply
                from functions.utils import tmux_up
                from functions.container import cname, tsess
                if tmux_up(tsess(ecid)): exposure_apply(ecid,ctx.mnt_dir)
                pause(f"Port exposure set to: {_exposure_label(nxt)}\n\n  isolated  — blocked even on host\n  localhost — only this machine\n  public    — visible on local network")
                break
            else:
                # Check route click
                for i,rl in enumerate(route_lines):
                    if strip_ansi(rl).strip()!=sc: continue
                    matched=route_urls[i]
                    try:
                        cfg=json.loads(Path(_cfg(ctx)).read_text())
                        rr=next((r for r in cfg.get("routes",[]) if r.get("url")==matched),{})
                        rcid2=rr.get("cid",""); rh2=rr.get("https","false")
                    except: continue
                    rc5,al5=fzf(["Change URL","Change container",f"Toggle HTTPS (currently: {rh2})","Remove"],
                                "--header",f"{BLD}── Edit: {matched} ──{NC}")
                    if rc5!=0 or not al5: continue
                    act2=al5[0].strip()
                    def _save_cfg(cfg2):
                        Path(_cfg(ctx)).write_text(json.dumps(cfg2,indent=2))
                        if _proxy_running(ctx): proxy_stop(ctx); proxy_start(ctx,containers)
                    if "Change URL" in act2:
                        if not finput("New URL:"): continue
                        nu=_tui.FINPUT_RESULT.strip().lstrip("http://").lstrip("https://").split("/")[0]
                        if not nu: continue
                        try:
                            cfg=json.loads(Path(_cfg(ctx)).read_text())
                            for r in cfg.get("routes",[]):
                                if r.get("url")==matched: r["url"]=nu
                            _save_cfg(cfg)
                        except: pass
                    elif "Change container" in act2:
                        cnames2=[info["name"] for info in containers.values()]
                        rc6,cl2=fzf(cnames2,"--header",f"{BLD}── Route: new container ──{NC}")
                        if rc6!=0 or not cl2: continue
                        cs3=cl2[0].strip()
                        nc3=next((cid for cid,info in containers.items() if info["name"]==cs3),"")
                        if not nc3: continue
                        try:
                            cfg=json.loads(Path(_cfg(ctx)).read_text())
                            for r in cfg.get("routes",[]):
                                if r.get("url")==matched: r["cid"]=nc3
                            _save_cfg(cfg)
                        except: pass
                    elif "Toggle HTTPS" in act2:
                        try:
                            cfg=json.loads(Path(_cfg(ctx)).read_text())
                            for r in cfg.get("routes",[]):
                                if r.get("url")==matched: r["https"]=not (r.get("https")==True or r.get("https")=="true")
                            _save_cfg(cfg)
                        except: pass
                    elif act2=="Remove":
                        if not confirm(f"Remove {matched}?"): continue
                        try:
                            cfg=json.loads(Path(_cfg(ctx)).read_text())
                            cfg["routes"]=[r for r in cfg.get("routes",[]) if r.get("url")!=matched]
                            _save_cfg(cfg)
                        except: pass
                    break


def _exposure_label(mode):
    labels={"isolated":f"{RED}⬤{NC}","localhost":f"{YLW}⬤{NC}","public":f"{GRN}⬤{NC}"}
    return labels.get(mode,f"{DIM}⬤{NC}")


def qrencode_menu(ctx):
    """Match bash _qrencode_menu."""
    from functions.tui import confirm, pause
    from functions.utils import trim_s, strip_ansi, tmux_up, make_tmp
    from functions.constants import GRN, RED, CYN, BLD, DIM, NC, L, FZF_BASE
    import subprocess, os

    while True:
        if not os.path.isfile(os.path.join(ctx.ubuntu_dir, ".ubuntu_ready")):
            pause("QRencode runs inside the Ubuntu base layer.\n\n  Install Ubuntu base first (Other → Ubuntu base).")
            return

        for sess in ("sdQrInst", "sdQrUninst"):
            if tmux_up(sess):
                pause(f"QRencode operation running in '{sess}'. Attach to monitor.")
                return

        qr_installed = subprocess.run(
            ["chroot", ctx.ubuntu_dir, "which", "qrencode"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode == 0

        if qr_installed:
            items = [f"{CYN}↑{NC}  Update", f"{RED}×{NC}  Uninstall",
                     f"{BLD}  ── Navigation ───────────────────────{NC}", f"{DIM} {L['back']}{NC}"]
        else:
            items = [f"{GRN}↓{NC}  Install",
                     f"{BLD}  ── Navigation ───────────────────────{NC}", f"{DIM} {L['back']}{NC}"]

        out_f = make_tmp(".sd_qr_fzf_")
        proc = subprocess.Popen(["fzf"] + list(FZF_BASE) + [f"--header={BLD}── QRencode ──{NC}"],
                                stdin=subprocess.PIPE, stdout=open(out_f, "wb"))
        proc.stdin.write("\n".join(items).encode()); proc.stdin.close()
        rc = proc.wait()
        try: sel = open(out_f).read().strip()
        except: sel = ""
        try: os.unlink(out_f)
        except: pass
        if rc != 0 or not sel: return
        clean = strip_ansi(trim_s(sel)).strip()
        if clean == L["back"] or not clean: return

        sess = "sdQrInst" if "Uninstall" not in clean else "sdQrUninst"
        if "Install" in clean or "Update" in clean:
            cmd = "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends qrencode 2>&1"
        else:
            if not confirm("Uninstall QRencode from Ubuntu?"): continue
            cmd = "DEBIAN_FRONTEND=noninteractive apt-get remove -y qrencode 2>&1"
        script = make_tmp(".sd_qr_", ".sh")
        with open(script, "w") as fp:
            fp.write(f"#!/usr/bin/env bash\nchroot '{ctx.ubuntu_dir}' bash -c \"{cmd}\"\nrm -f '{script}'\nread -p 'Done — press Enter...'\n")
        os.chmod(script, 0o755)
        subprocess.run(["tmux", "new-session", "-d", "-s", sess, f"bash '{script}'"], stderr=subprocess.DEVNULL)
        subprocess.run(["tmux", "attach-session", "-t", sess], stderr=subprocess.DEVNULL)
