# simpleDocker — Python rewrite

Full Python rewrite of services.sh (7,627 lines → ~6,000 lines Python).  
Single binary output via PyInstaller.

## Requirements (host system)

```
sudo apt-get install -y \
    btrfs-progs \
    tmux \
    fzf \
    cryptsetup \
    iproute2 \
    iptables \
    ncat \
    yazi \
    python3 \
    python3-pip
```

## Option A — Run directly from source (no build needed)

```bash
cd simpledocker/
python3 main.py
```

To open a specific image:
```bash
python3 main.py /path/to/your.img
```

## Option B — Build a single binary with PyInstaller

```bash
cd simpledocker/
chmod +x build.sh
./build.sh
```

Binary will be at `dist/simpledocker`. Copy it anywhere:

```bash
cp dist/simpledocker ~/bin/simpledocker
simpledocker
```

## File structure

```
simpledocker/
├── main.py                   ← entry point
├── simpledocker.spec         ← PyInstaller build spec
├── build.sh                  ← one-command build script
├── cli/
│   ├── __init__.py
│   └── app.py                ← AppContext, mount/setup/teardown
├── functions/
│   ├── constants.py          ← all global constants, ANSI colors, keybindings
│   ├── utils.py              ← subprocess helpers, tmux, state, logging
│   ├── tui.py                ← fzf wrappers, confirm, pause, finput, menu
│   ├── image.py              ← BTRFS image create/mount, LUKS open/close
│   ├── blueprint.py          ← .container/.toml parser, compile to service.json
│   ├── network.py            ← netns setup/teardown, veth, iptables exposure
│   ├── container.py          ← start/stop/cron/groups/snapshots
│   ├── storage.py            ← persistent storage profiles
│   └── installer.py          ← generates install/update bash scripts, runs in tmux
└── menu/
    ├── main_menu.py          ← top-level fzf menu
    ├── container_menu.py     ← per-container actions
    ├── backup_menu.py        ← btrfs snapshot backups
    ├── storage_menu.py       ← persistent storage profiles
    ├── group_menu.py         ← container groups (start sequence)
    ├── enc_menu.py           ← LUKS key management
    ├── proxy_menu.py         ← Caddy reverse proxy + mDNS/avahi
    ├── ubuntu_menu.py        ← Ubuntu chroot apt management
    ├── logs_menu.py          ← log file browser
    ├── resources_menu.py     ← CPU/memory cgroup limits
    └── port_exposure_menu.py ← iptables port exposure
```

## Notes

- The script **must** run as a regular user with passwordless `sudo` for specific commands (cryptsetup, btrfs, ip, iptables, tee /etc/hosts).  
  It will prompt once at startup to cache credentials.
- On first launch with no existing image, it will guide you through image creation.
- Install scripts (inside containers) are still generated as **bash** and run inside tmux — Python only orchestrates them.
