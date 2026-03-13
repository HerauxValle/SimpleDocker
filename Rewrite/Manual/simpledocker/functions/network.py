"""
network.py — Network namespaces, container IP assignment, port exposure, iptables
"""

import hashlib
import json
import os
import subprocess

from .constants import GRN, YLW, DIM, NC
from .utils import run_out, sudo_run, sudo_out, read_json


# ── Network namespace helpers ─────────────────────────────────────────────

def netns_name(mnt_dir: str) -> str:
    h = hashlib.md5(mnt_dir.encode()).hexdigest()[:8]
    return f"sd_{h}"


def netns_idx(mnt_dir: str) -> int:
    h = hashlib.md5(mnt_dir.encode()).hexdigest()[:2]
    return int(h, 16) % 254


def netns_hosts_file(mnt_dir: str) -> str:
    return os.path.join(mnt_dir, ".sd", ".netns_hosts")


def netns_setup(mnt_dir: str):
    ns  = netns_name(mnt_dir)
    idx = netns_idx(mnt_dir)
    subnet   = f"10.88.{idx}"
    br       = f"sd-br{idx}"
    veth_h   = f"sd-h{idx}"
    veth_ns  = f"sd-ns{idx}"
    ip_ns    = f"{subnet}.1"
    ip_h     = f"{subnet}.254"

    # Check if already exists
    r = subprocess.run(["ip", "netns", "list"],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    if ns.encode() in r.stdout:
        return

    cmds = [
        ["ip", "link", "del", veth_h],
        ["ip", "netns", "del", ns],
        ["ip", "netns", "add", ns],
        ["ip", "link", "add", veth_h, "type", "veth", "peer", "name", veth_ns],
        ["ip", "link", "set", veth_ns, "netns", ns],
        ["ip", "netns", "exec", ns, "ip", "link", "add", br, "type", "bridge"],
        ["ip", "netns", "exec", ns, "ip", "link", "set", veth_ns, "master", br],
        ["ip", "netns", "exec", ns, "ip", "addr", "add", f"{ip_ns}/24", "dev", br],
        ["ip", "netns", "exec", ns, "ip", "link", "set", br, "up"],
        ["ip", "netns", "exec", ns, "ip", "link", "set", veth_ns, "up"],
        ["ip", "netns", "exec", ns, "ip", "link", "set", "lo", "up"],
        ["ip", "addr", "add", f"{ip_h}/24", "dev", veth_h],
        ["ip", "link", "set", veth_h, "up"],
        ["ip", "netns", "exec", ns, "sysctl", "-qw", "net.ipv4.ip_forward=1"],
    ]

    sd_dir = os.path.join(mnt_dir, ".sd")
    os.makedirs(sd_dir, exist_ok=True)

    for cmd in cmds:
        sudo_run(cmd)

    with open(os.path.join(sd_dir, ".netns_name"), "w") as fp:
        fp.write(ns + "\n")
    with open(os.path.join(sd_dir, ".netns_idx"), "w") as fp:
        fp.write(str(idx) + "\n")


def netns_teardown(mnt_dir: str):
    ns  = netns_name(mnt_dir)
    idx = netns_idx(mnt_dir)
    sudo_run(["ip", "netns", "del", ns])
    sudo_run(["ip", "link", "del", f"sd-h{idx}"])
    for f in [".netns_name", ".netns_idx", ".netns_hosts"]:
        try:
            os.unlink(os.path.join(mnt_dir, ".sd", f))
        except Exception:
            pass


def netns_ct_ip(cid: str, mnt_dir: str) -> str:
    idx  = netns_idx(mnt_dir)
    last = (int(hashlib.md5(cid.encode()).hexdigest()[:2], 16) % 252) + 2
    return f"10.88.{idx}.{last}"


def netns_ct_add(cid: str, name: str, mnt_dir: str):
    ns  = netns_name(mnt_dir)
    idx = netns_idx(mnt_dir)
    ip  = netns_ct_ip(cid, mnt_dir)
    br       = f"sd-br{idx}"
    veth_h   = f"sd-c{idx}-{cid[:6]}"
    veth_ns  = f"sd-i{idx}-{cid[:6]}"

    sudo_run(["ip", "link", "add", veth_h, "type", "veth", "peer", "name", veth_ns])
    sudo_run(["ip", "link", "set", veth_ns, "netns", ns])
    sudo_run(["ip", "netns", "exec", ns, "ip", "link", "set", veth_ns, "master", br])
    sudo_run(["ip", "netns", "exec", ns, "ip", "addr", "add", f"{ip}/24", "dev", veth_ns])
    sudo_run(["ip", "netns", "exec", ns, "ip", "link", "set", veth_ns, "up"])
    sudo_run(["ip", "link", "set", veth_h, "up"])

    # Update hosts file
    hf = netns_hosts_file(mnt_dir)
    lines = []
    if os.path.isfile(hf):
        with open(hf) as fp:
            lines = [l for l in fp if not l.rstrip().endswith(f" {name}")]
    lines.append(f"{ip} {name}\n")
    with open(hf + ".tmp", "w") as fp:
        fp.writelines(lines)
    os.replace(hf + ".tmp", hf)


def netns_ct_del(cid: str, name: str, mnt_dir: str, containers_dir: str):
    idx    = netns_idx(mnt_dir)
    ip     = netns_ct_ip(cid, mnt_dir)
    sj     = os.path.join(containers_dir, cid, "service.json")
    port   = ""
    try:
        with open(sj) as fp:
            d = json.load(fp)
        port = str(d.get("meta", {}).get("port", "") or "")
    except Exception:
        pass

    sudo_run(["ip", "link", "del", f"sd-c{idx}-{cid[:6]}"])
    exposure_flush(cid, port, ip)

    hf = netns_hosts_file(mnt_dir)
    lines = []
    if os.path.isfile(hf):
        with open(hf) as fp:
            lines = [l for l in fp if not l.rstrip().endswith(f" {name}")]
    with open(hf + ".tmp", "w") as fp:
        fp.writelines(lines)
    os.replace(hf + ".tmp", hf)


# ── Port exposure ─────────────────────────────────────────────────────────

def exposure_file(containers_dir: str, cid: str) -> str:
    return os.path.join(containers_dir, cid, "exposure")


def exposure_get(containers_dir: str, cid: str) -> str:
    f = exposure_file(containers_dir, cid)
    try:
        v = open(f).read().strip()
        if v in ("isolated", "localhost", "public"):
            return v
    except Exception:
        pass
    return "localhost"


def exposure_set(containers_dir: str, cid: str, mode: str):
    with open(exposure_file(containers_dir, cid), "w") as fp:
        fp.write(mode)


def exposure_next(containers_dir: str, cid: str) -> str:
    modes = {"isolated": "localhost", "localhost": "public", "public": "isolated"}
    return modes.get(exposure_get(containers_dir, cid), "localhost")


def exposure_label(mode: str) -> str:
    if mode == "isolated":
        return f"{DIM}⬤  isolated{NC}"
    elif mode == "localhost":
        return f"{YLW}⬤  localhost{NC}"
    elif mode == "public":
        return f"{GRN}⬤  public{NC}"
    return f"{YLW}⬤  localhost{NC}"


def exposure_apply(cid: str, containers_dir: str, mnt_dir: str):
    mode = exposure_get(containers_dir, cid)
    sj   = os.path.join(containers_dir, cid, "service.json")
    data = read_json(sj)
    port = str(data.get("meta", {}).get("port", "") or "")
    ep   = str(data.get("environment", {}).get("PORT", "") or "")
    if ep:
        port = ep
    if not port or port == "0":
        return

    ct_ip = netns_ct_ip(cid, mnt_dir)
    exposure_flush(cid, port, ct_ip)

    if mode == "isolated":
        sudo_run(["iptables", "-I", "INPUT", "-p", "tcp", "--dport", port, "-j", "DROP"])
        sudo_run(["iptables", "-I", "OUTPUT", "-p", "tcp", "-d", f"{ct_ip}/32", "--dport", port, "-j", "DROP"])
        sudo_run(["iptables", "-I", "FORWARD", "-d", f"{ct_ip}/32", "-p", "tcp", "--dport", port, "-j", "DROP"])

    elif mode == "localhost":
        sudo_run(["sysctl", "-qw", "net.ipv4.ip_forward=1"])
        sudo_run(["iptables", "-I", "FORWARD", "-d", f"{ct_ip}/32", "-p", "tcp", "--dport", port, "-j", "ACCEPT"])
        sudo_run(["iptables", "-I", "FORWARD", "-s", f"{ct_ip}/32", "-p", "tcp", "--sport", port, "-j", "ACCEPT"])

    elif mode == "public":
        sudo_run(["sysctl", "-qw", "net.ipv4.ip_forward=1"])
        sudo_run(["iptables", "-t", "nat", "-A", "PREROUTING", "-p", "tcp", "--dport", port,
                  "-j", "DNAT", "--to-destination", f"{ct_ip}:{port}"])
        sudo_run(["iptables", "-t", "nat", "-A", "POSTROUTING", "-d", f"{ct_ip}/32",
                  "-p", "tcp", "--dport", port, "-j", "MASQUERADE"])
        sudo_run(["iptables", "-I", "FORWARD", "-d", f"{ct_ip}/32", "-p", "tcp", "--dport", port, "-j", "ACCEPT"])
        sudo_run(["iptables", "-I", "FORWARD", "-s", f"{ct_ip}/32", "-p", "tcp", "--sport", port, "-j", "ACCEPT"])


def exposure_flush(cid: str, port: str, ct_ip: str):
    if not port or port == "0":
        return
    sudo_run(["iptables", "-D", "INPUT",   "-p", "tcp", "--dport", port, "-j", "DROP"])
    sudo_run(["iptables", "-D", "OUTPUT",  "-p", "tcp", "-d", f"{ct_ip}/32", "--dport", port, "-j", "DROP"])
    sudo_run(["iptables", "-D", "FORWARD", "-d", f"{ct_ip}/32", "-p", "tcp", "--dport", port, "-j", "DROP"])
    sudo_run(["iptables", "-t", "nat", "-D", "PREROUTING",  "-p", "tcp", "--dport", port,
              "-j", "DNAT", "--to-destination", f"{ct_ip}:{port}"])
    sudo_run(["iptables", "-t", "nat", "-D", "POSTROUTING", "-d", f"{ct_ip}/32",
              "-p", "tcp", "--dport", port, "-j", "MASQUERADE"])
    sudo_run(["iptables", "-D", "FORWARD", "-d", f"{ct_ip}/32", "-p", "tcp", "--dport", port, "-j", "ACCEPT"])
    sudo_run(["iptables", "-D", "FORWARD", "-s", f"{ct_ip}/32", "-p", "tcp", "--sport", port, "-j", "ACCEPT"])
