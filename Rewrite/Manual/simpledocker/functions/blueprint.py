"""
blueprint.py — Blueprint (TOML-ish .container format) parse, validate, compile to JSON
"""

import json
import os
import re
import shutil
from dataclasses import dataclass, field
from typing import Optional

from .utils import make_tmp, sha256_file, write_json, read_json


# ── Blueprint data structure ──────────────────────────────────────────────

@dataclass
class Blueprint:
    meta: dict = field(default_factory=dict)
    env:  dict = field(default_factory=dict)
    storage: str = ""
    deps:    str = ""
    dirs:    str = ""
    pip:     str = ""
    github:  str = ""
    npm:     str = ""
    build:   str = ""
    install: str = ""
    update:  str = ""
    start:   str = ""
    actions_names:   list = field(default_factory=list)
    actions_scripts: list = field(default_factory=list)
    cron_names:     list = field(default_factory=list)
    cron_intervals: list = field(default_factory=list)
    cron_cmds:      list = field(default_factory=list)
    cron_flags:     list = field(default_factory=list)
    errors: list = field(default_factory=list)


# ── Parser ────────────────────────────────────────────────────────────────

def bp_parse(path: str) -> Optional[Blueprint]:
    if not os.path.isfile(path):
        return None

    bp = Blueprint()
    cur_section = ""
    cur_content_lines = []
    in_container = False

    try:
        with open(path) as fp:
            lines = fp.readlines()
    except Exception:
        return None

    def flush(sec, content):
        _flush_section(bp, sec, content)

    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = re.sub(r'#.*', '', line).rstrip()

        m_open = re.match(r'^\[([^/][^\]]*)\]$', stripped)
        m_close = re.match(r'^\[/(container|blueprint|end)\]$', stripped)

        if m_close:
            flush(cur_section, "\n".join(cur_content_lines))
            cur_section = ""
            cur_content_lines = []
            in_container = False
            continue

        if m_open:
            new_sec = m_open.group(1)
            flush(cur_section, "\n".join(cur_content_lines))
            cur_section = new_sec
            cur_content_lines = []
            if new_sec in ("container", "blueprint"):
                in_container = True
                cur_section = ""
            continue

        if cur_section:
            cur_content_lines.append(line)

    flush(cur_section, "\n".join(cur_content_lines))
    return bp


def _flush_section(bp: Blueprint, sec: str, content: str):
    if not sec:
        return
    content = content.rstrip()
    sec_lower = sec.lower()

    if sec_lower == "meta":
        for l in content.splitlines():
            l = re.sub(r'#.*', '', l).strip()
            if not l or '=' not in l:
                continue
            k, _, v = l.partition('=')
            bp.meta[k.strip()] = v.strip()

    elif sec_lower == "env":
        for l in content.splitlines():
            l = re.sub(r'#.*', '', l).strip()
            if not l or '=' not in l:
                continue
            k, _, v = l.partition('=')
            bp.env[k.strip()] = v.strip()

    elif sec_lower == "storage":
        bp.storage = content

    elif sec_lower in ("dependencies", "deps"):
        bp.deps = content

    elif sec_lower == "dirs":
        bp.dirs = content

    elif sec_lower in ("pip", "pypi"):
        bp.pip = content

    elif sec_lower == "git":
        bp.github = content

    elif sec_lower == "npm":
        bp.npm = content

    elif sec_lower == "build":
        bp.build = content

    elif sec_lower == "install":
        bp.install = content

    elif sec_lower == "update":
        bp.update = content

    elif sec_lower == "start":
        bp.start = content

    elif sec_lower == "actions":
        for l in content.splitlines():
            l = l.strip()
            if not l or l.startswith('#'):
                continue
            if '|' not in l:
                continue
            label, _, rest = l.partition('|')
            bp.actions_names.append(label.rstrip())
            bp.actions_scripts.append(rest.lstrip())

    elif sec_lower == "cron":
        for l in content.splitlines():
            l = l.strip()
            if not l or l.startswith('#'):
                continue
            if '|' not in l:
                continue
            interval_name, _, cmd = l.partition('|')
            cmd = cmd.lstrip()
            if not cmd:
                continue
            flags = ""
            if "--sudo" in interval_name:
                flags += " --sudo"
            if "--unjailed" in interval_name:
                flags += " --unjailed"
            flags = flags.strip()
            interval_name = interval_name.replace("--sudo", "").replace("--unjailed", "").rstrip()
            parts = interval_name.split(None, 1)
            interval = parts[0] if parts else ""
            name_part = parts[1].strip().strip("[]") if len(parts) > 1 else ""
            if not name_part:
                name_part = f"{interval} job"
            # Prefix relative log paths with $CONTAINER_ROOT/
            cmd = re.sub(r'>>\s*([a-zA-Z_][^\s]*)', r'>> $CONTAINER_ROOT/\1', cmd)
            bp.cron_names.append(name_part)
            bp.cron_intervals.append(interval)
            bp.cron_cmds.append(cmd)
            bp.cron_flags.append(flags)


# ── Validation ────────────────────────────────────────────────────────────

def bp_validate(bp: Blueprint) -> list:
    """Return list of error strings (empty = valid)."""
    errors = []

    if not bp.meta.get("name", "").strip():
        errors.append("  [meta]  'name' is required")

    has_entry = bool(bp.meta.get("entrypoint", "")) or bool(bp.start.strip())
    if not has_entry:
        errors.append("  [meta]  'entrypoint' or a [start] block is required")

    port = bp.meta.get("port", "").replace(" ", "")
    if port and not port.isdigit():
        errors.append(f"  [meta]  'port' must be a number, got: {port}")

    if bp.storage.strip():
        paths = [p.strip() for p in bp.storage.replace('\n', ',').split(',')
                 if p.strip() and not p.strip().startswith('#')]
        if paths and not bp.meta.get("storage_type", "").strip():
            errors.append("  [storage]  'storage_type' in [meta] is required when [storage] paths are declared")

    if bp.github.strip():
        for i, l in enumerate(bp.github.splitlines(), 1):
            l = re.sub(r'#.*', '', l).strip()
            if not l:
                continue
            # Handle "varname = org/repo" format
            m = re.match(r'^[a-zA-Z_]\w*\s*=\s*(.*)', l)
            if m:
                l = m.group(1).strip()
            repo = l.split()[0] if l.split() else ""
            if not re.match(r'^[a-zA-Z0-9_.\-]+/[a-zA-Z0-9_.\-]+$', repo):
                errors.append(f"  [git]  line {i}: invalid repo format '{repo}' (expected org/repo)")

    if bp.dirs.strip():
        opens = bp.dirs.count('(')
        closes = bp.dirs.count(')')
        if opens != closes:
            errors.append(f"  [dirs]  unbalanced parentheses ({opens} open, {closes} close)")

    for i, (lbl, dsl) in enumerate(zip(bp.actions_names, bp.actions_scripts), 1):
        if '|' in dsl:
            segs = [s.strip() for s in dsl.split('|')]
            has_prompt = any(s.startswith('prompt:') for s in segs)
            has_select = any(s.startswith('select:') for s in segs)
            if '{input}' in dsl and not has_prompt:
                errors.append(f"  [actions]  '{lbl}': uses {{input}} but no 'prompt:' segment")
            if '{selection}' in dsl and not has_select:
                errors.append(f"  [actions]  '{lbl}': uses {{selection}} but no 'select:' segment")
        if not lbl:
            errors.append(f"  [actions]  action {i} has an empty label")

    if bp.pip.strip():
        has_py = bool(re.search(r'python3', bp.deps or ""))
        if not has_py:
            errors.append("  [pip]  requires 'python3' in [deps]")

    return errors


# ── Compile to service.json ───────────────────────────────────────────────

def bp_compile_to_json(bp_path: str, cid: str, containers_dir: str, cname: str = "") -> bool:
    """
    Parse and compile a blueprint file to service.json.
    Returns True on success.
    """
    bp = bp_parse(bp_path)
    if bp is None:
        return False

    if cname:
        bp.meta["name"] = cname

    errors = bp_validate(bp)
    if errors:
        from .tui import pause
        msg = "⚠  Blueprint validation failed:\n\n" + "\n".join(errors) + "\n\n  Fix the blueprint and try again."
        pause(msg)
        return False

    # Storage list
    storage_list = []
    if bp.storage.strip():
        for item in re.split(r'[,\n]', bp.storage):
            item = re.sub(r'#.*', '', item).strip()
            if item:
                storage_list.append(item)

    # Actions
    actions = [
        {"label": lbl, "dsl": dsl}
        for lbl, dsl in zip(bp.actions_names, bp.actions_scripts)
    ]

    # Crons
    crons = [
        {"name": n, "interval": iv, "cmd": c, "flags": f}
        for n, iv, c, f in zip(
            bp.cron_names, bp.cron_intervals, bp.cron_cmds, bp.cron_flags
        )
    ]

    service = {
        "meta":        bp.meta,
        "environment": bp.env,
        "storage":     storage_list,
        "deps":        bp.deps,
        "dirs":        bp.dirs,
        "pip":         bp.pip,
        "npm":         bp.npm,
        "git":         bp.github,
        "build":       bp.build,
        "install":     bp.install,
        "update":      bp.update,
        "start":       bp.start,
        "actions":     actions,
        "crons":       crons,
    }

    sj_path = os.path.join(containers_dir, cid, "service.json")
    write_json(sj_path, service)
    return True


def bp_is_json(path: str) -> bool:
    try:
        with open(path) as fp:
            json.load(fp)
        return True
    except Exception:
        return False


def compile_service(cid: str, containers_dir: str) -> bool:
    """Compile service.src -> service.json. Returns True on success."""
    src = os.path.join(containers_dir, cid, "service.src")
    if not os.path.isfile(src):
        return False
    sj = os.path.join(containers_dir, cid, "service.json")
    if bp_is_json(src):
        shutil.copy2(src, sj)
        h = sha256_file(src)
        with open(src + ".hash", "w") as fp:
            fp.write(h)
        return True
    cname = ""
    # Read existing name from state
    state = read_json(os.path.join(containers_dir, cid, "state.json"))
    if state:
        cname = state.get("name", "")
    ok = bp_compile_to_json(src, cid, containers_dir, cname)
    if ok:
        h = sha256_file(src)
        with open(os.path.join(containers_dir, cid, "service.src.hash"), "w") as fp:
            fp.write(h)
    return ok


def bootstrap_src(cid: str, containers_dir: str):
    """Create service.src from service.json (for editing)."""
    sj = os.path.join(containers_dir, cid, "service.json")
    src = os.path.join(containers_dir, cid, "service.src")
    if not os.path.isfile(sj):
        return
    shutil.copy2(sj, src)
    h = sha256_file(src)
    with open(src + ".hash", "w") as fp:
        fp.write(h)


def ensure_src(cid: str, containers_dir: str):
    src = os.path.join(containers_dir, cid, "service.src")
    if not os.path.isfile(src):
        bootstrap_src(cid, containers_dir)


# ── Blueprint cfg (settings.json) ─────────────────────────────────────────

def bp_cfg_path(mnt_dir: str) -> str:
    return os.path.join(mnt_dir, ".sd", "bp_settings.json")


def bp_cfg_get(mnt_dir: str, key: str, default="") -> str:
    data = read_json(bp_cfg_path(mnt_dir))
    return data.get(key, default)


def bp_cfg_set(mnt_dir: str, key: str, value: str):
    path = bp_cfg_path(mnt_dir)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    data = read_json(path) or {}
    data[key] = value
    write_json(path, data)


def bp_persistent_enabled(mnt_dir: str) -> bool:
    return bp_cfg_get(mnt_dir, "persistent_blueprints", "true") != "false"


def bp_autodetect_mode(mnt_dir: str) -> str:
    return bp_cfg_get(mnt_dir, "autodetect_blueprints", "Home")


def bp_custom_paths_get(mnt_dir: str) -> list:
    data = read_json(bp_cfg_path(mnt_dir)) or {}
    return data.get("custom_paths", [])


def bp_custom_paths_add(mnt_dir: str, path: str):
    data = read_json(bp_cfg_path(mnt_dir)) or {}
    paths = data.get("custom_paths", [])
    if path not in paths:
        paths.append(path)
    data["custom_paths"] = paths
    write_json(bp_cfg_path(mnt_dir), data)


def bp_custom_paths_remove(mnt_dir: str, path: str):
    data = read_json(bp_cfg_path(mnt_dir)) or {}
    paths = [p for p in data.get("custom_paths", []) if p != path]
    data["custom_paths"] = paths
    write_json(bp_cfg_path(mnt_dir), data)


# ── Directory listing ─────────────────────────────────────────────────────

def list_blueprint_names(blueprints_dir: str) -> list:
    names = []
    if not os.path.isdir(blueprints_dir):
        return names
    for f in sorted(os.listdir(blueprints_dir)):
        if f.endswith(".toml") or f.endswith(".container"):
            names.append(f.rsplit(".", 1)[0])
    return names


def list_persistent_names() -> list:
    """Return names of built-in persistent blueprints from this script."""
    # The original script embeds blueprints in SD_PERSISTENT_END heredoc.
    # In Python we expose them from a built-in registry.
    return []  # Can be extended with embedded presets


def list_imported_names(blueprints_dir: str) -> list:
    """Return names of imported blueprint files."""
    names = []
    if not os.path.isdir(blueprints_dir):
        return names
    for f in sorted(os.listdir(blueprints_dir)):
        if f.endswith(".imported"):
            names.append(f.rsplit(".", 1)[0])
    return names


def get_imported_bp_path(blueprints_dir: str, name: str) -> str:
    p = os.path.join(blueprints_dir, name + ".imported")
    return p if os.path.isfile(p) else ""


def get_persistent_bp(name: str) -> str:
    """Return path to a built-in persistent blueprint (or "")."""
    # Built-in presets would be stored alongside this package
    pkg_dir = os.path.dirname(__file__)
    p = os.path.join(pkg_dir, "presets", name + ".toml")
    return p if os.path.isfile(p) else ""


def view_persistent_bp(name: str):
    """Show built-in blueprint in fzf read-only viewer."""
    p = get_persistent_bp(name)
    if not p or not os.path.isfile(p):
        from .tui import pause
        pause(f"Could not locate built-in blueprint '{name}'.")
        return
    with open(p) as fp:
        lines = fp.readlines()
    from .tui import fzf
    fzf([l.rstrip() for l in lines],
        f"--header={name}  (built-in)",
        "--no-multi", "--disabled")


def bp_autodetect_dirs(mnt_dir: str) -> list:
    """Return directories to scan for .container files based on autodetect mode."""
    mode = bp_autodetect_mode(mnt_dir)
    if mode == "Disabled":
        return []
    if mode == "Custom":
        return bp_custom_paths_get(mnt_dir)
    dirs = [os.path.expanduser("~")]
    if mode in ("Root", "Everywhere"):
        dirs.append("/")
    return dirs


# ── cr_prefix helper (used in install scripts) ────────────────────────────

def cr_prefix(v: str) -> str:
    """Prefix relative path values with $CONTAINER_ROOT/."""
    if not v:
        return v
    if v.startswith(("/", "~", "$", "http://", "https://")):
        return v
    if v.isdigit():
        return v
    if ":" in v:
        return v
    if re.match(r'^\d+\.\d+\.\d+\.\d+$', v):
        return v
    return f"$CONTAINER_ROOT/{v}"
