# -*- mode: python ; coding: utf-8 -*-
# Build:  pyinstaller simpledocker.spec
# Output: dist/simpledocker  (single binary)

block_cipher = None

a = Analysis(
    ['main.py'],
    pathex=['.'],
    binaries=[],
    datas=[],
    hiddenimports=[
        'functions.constants',
        'functions.utils',
        'functions.tui',
        'functions.image',
        'functions.blueprint',
        'functions.network',
        'functions.container',
        'functions.storage',
        'functions.installer',
        'menu.backup_menu',
        'menu.container_menu',
        'menu.enc_menu',
        'menu.group_menu',
        'menu.logs_menu',
        'menu.main_menu',
        'menu.port_exposure_menu',
        'menu.proxy_menu',
        'menu.resources_menu',
        'menu.storage_menu',
        'menu.ubuntu_menu',
        'cli.app',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['tkinter', 'matplotlib', 'numpy', 'PIL', 'PyQt5', 'wx'],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='simpledocker',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)
