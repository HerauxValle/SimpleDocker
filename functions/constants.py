"""
constants.py — Global constants, ANSI color codes, labels, keybindings
"""

import os

# ── Paths ──────────────────────────────────────────────────────────────────
ROOT_DIR = os.path.expanduser("~/.config/simpleDocker")
SD_MNT_BASE = os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", os.path.expanduser("~/.local/share")),
    "simpleDocker"
)
TMP_DIR = os.path.join(SD_MNT_BASE, ".tmp")

DEFAULT_IMG = ""
DEFAULT_UBUNTU_PKGS = (
    "curl git wget ca-certificates zstd tar xz-utils "
    "python3 python3-venv python3-pip build-essential"
)

# ── LUKS / encryption constants ───────────────────────────────────────────
SD_LUKS_KEY_SLOT_MIN = 7
SD_LUKS_KEY_SLOT_MAX = 31
SD_DEFAULT_KEYWORD = "1991316125415311518"
SD_UNLOCK_ORDER = ["verified_system", "default_keyword", "prompt"]

def _compute_verification_cipher() -> str:
    try:
        import subprocess as _sp
        r = _sp.run(["sha256sum", "/etc/machine-id"], capture_output=True, text=True)
        v = r.stdout[:32].strip()
        return v if len(v) == 32 else "simpledocker_fallback"
    except Exception:
        return "simpledocker_fallback"

SD_VERIFICATION_CIPHER: str = _compute_verification_cipher()

# ── ANSI colors ───────────────────────────────────────────────────────────
GRN = "\033[0;32m"
RED = "\033[0;31m"
YLW = "\033[0;33m"
BLU = "\033[0;34m"
CYN = "\033[0;36m"
BLD = "\033[1m"
DIM = "\033[2m"
NC  = "\033[0m"

def grn(s): return f"{GRN}{s}{NC}"
def red(s): return f"{RED}{s}{NC}"
def ylw(s): return f"{YLW}{s}{NC}"
def blu(s): return f"{BLU}{s}{NC}"
def cyn(s): return f"{CYN}{s}{NC}"
def bld(s): return f"{BLD}{s}{NC}"
def dim(s): return f"{DIM}{s}{NC}"

# ── Keybindings ───────────────────────────────────────────────────────────
KB = {
    "detach":      "ctrl-d",
    "quit":        "ctrl-q",
    "tmux_detach": "ctrl-\\",
}

# ── UI Labels ─────────────────────────────────────────────────────────────
L = {
    "title":            "simpleDocker",
    "detach":           "⊙  Detach",
    "quit":             "Quit",
    "quit_stop_all":    "■  Stop all & quit",
    "new_container":    "New container",
    "help":             "Other",
    "help_resize":      "Resize image",
    "help_storage":     "Persistent storage",
    "ct_start":         "▶  Start",
    "ct_stop":          "■  Stop",
    "ct_restart":       "↺  Restart",
    "ct_attach":        "→  Attach",
    "ct_install":       "↓  Install",
    "ct_edit":          "◦  Edit toml",
    "ct_terminal":      "◉  Terminal",
    "ct_update":        "↑  Update",
    "ct_uninstall":     "○  Uninstall",
    "ct_remove":        "×  Remove",
    "ct_rename":        "✎  Rename",
    "ct_backups":       "◈  Backups",
    "ct_profiles":      "◧  Profiles",
    "ct_open_in":       "⊕  Open in",
    "ct_exposure":      "⬤  Port exposure",
    "ct_attach_inst":   "→  Attach to installation",
    "ct_kill_inst":     "×  Kill installation",
    "ct_finish_inst":   "✓  Finish installation",
    "ct_log":           "≡  View log",
    "bp_new":           "New blueprint",
    "bp_edit":          "◦  Edit",
    "bp_delete":        "×  Delete",
    "bp_rename":        "✎  Rename",
    "grp_new":          "New group",
    "stor_rename":      "✎  Rename",
    "stor_delete":      "×  Delete",
    "back":             "← Back",
    "yes":              "Yes, confirm",
    "no":               "No",
    "ok_press":         "Press Enter or ESC to continue",
    "type_enter":       "Type and press Enter  (ESC to cancel)",
    "msg_install_running": "An installation is already running",
    "msg_install_ok":   "installed successfully.",
    "msg_install_fail": "Installation failed — attach to check output.",
    "img_select":       "Select existing image",
    "img_create":       "Create new image",
}

# ── seccomp blocklist ─────────────────────────────────────────────────────
SD_SECCOMP_BLOCKLIST = [
    "kexec_load", "kexec_file_load", "reboot", "init_module",
    "finit_module", "delete_module",
    "ioperm", "iopl",
    "mount", "umount2", "pivot_root",
    "unshare", "setns", "clone",
    "perf_event_open", "ptrace", "process_vm_readv", "process_vm_writev",
    "add_key", "request_key", "keyctl",
    "acct", "swapon", "swapoff", "syslog", "quotactl", "nfsservctl",
]

SD_CAP_DROP_DEFAULT = (
    "cap_sys_ptrace,cap_sys_rawio,cap_sys_boot,cap_sys_module,"
    "cap_mknod,cap_audit_write,cap_audit_control,cap_syslog"
)

# ── FZF base args ─────────────────────────────────────────────────────────
FZF_BASE = [
    "--ansi", "--no-sort", "--prompt=  ❯ ", "--pointer=▶",
    "--height=100%", "--reverse", "--border=rounded",
    "--margin=1,2", "--no-info",
]
