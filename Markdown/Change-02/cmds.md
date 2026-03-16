# Session extraction commands

Run the command for your session → paste `needed.txt` into the chat alongside the relevant `services.py` functions.
Every command overwrites `needed.txt`.

```bash
SH=services.sh
OUT=needed.txt
```

---

## Session 1 — Data integrity (DIV-001, DIV-002, DIV-004, DIV-054, DIV-055)

```bash
SH=services.sh; OUT=needed.txt
sed -n '1877,1889p' "$SH" > "$OUT"      # _load_containers (hidden flag)
echo "---" >> "$OUT"
sed -n '3795,3796p' "$SH" >> "$OUT"     # _snap_dir
echo "---" >> "$OUT"
sed -n '1998,2025p' "$SH" >> "$OUT"     # _bp_flush_section cron (>> rewrite)
echo "---" >> "$OUT"
sed -n '5530,5540p' "$SH" >> "$OUT"     # _container_submenu update calls
```

---

## Session 2 — Stop/start lifecycle (DIV-010, DIV-011, DIV-012, DIV-007, DIV-031, DIV-061)

```bash
SH=services.sh; OUT=needed.txt
sed -n '3368,3393p' "$SH" > "$OUT"      # _stop_container (clear + cron_stop_all)
echo "---" >> "$OUT"
sed -n '3145,3201p' "$SH" >> "$OUT"     # _cron_start_one full
echo "---" >> "$OUT"
sed -n '5067,5094p' "$SH" >> "$OUT"     # _do_ubuntu_update full
echo "---" >> "$OUT"
sed -n '4894,5035p' "$SH" >> "$OUT"     # _do_pkg_update full
```

---

## Session 3 — Proxy + CA trust (DIV-018, DIV-045, DIV-046, DIV-047, DIV-048, DIV-063)

```bash
SH=services.sh; OUT=needed.txt
sed -n '6379,6393p' "$SH" > "$OUT"      # _proxy_trust_ca full
echo "---" >> "$OUT"
sed -n '6319,6345p' "$SH" >> "$OUT"     # _proxy_ensure_sudoers full
echo "---" >> "$OUT"
sed -n '6200,6225p' "$SH" >> "$OUT"     # _proxy_dns_start + _proxy_dns_stop
echo "---" >> "$OUT"
sed -n '6457,6524p' "$SH" >> "$OUT"     # _proxy_install_caddy full
echo "---" >> "$OUT"
sed -n '5847,5860p' "$SH" >> "$OUT"     # _active_processes_menu session filter
```

---

## Session 4 — Update labels + ubuntu items (DIV-013, DIV-014, DIV-028)

```bash
SH=services.sh; OUT=needed.txt
sed -n '5096,5125p' "$SH" > "$OUT"      # _build_update_items (entry format with src label)
echo "---" >> "$OUT"
sed -n '5044,5065p' "$SH" >> "$OUT"     # _build_ubuntu_update_item (stamp comparison)
echo "---" >> "$OUT"
sed -n '5037,5043p' "$SH" >> "$OUT"     # _ct_ubuntu_stamp + _ct_ubuntu_ver
echo "---" >> "$OUT"
sed -n '3131,3143p' "$SH" >> "$OUT"     # _cron_countdown (seconds-only branch)
```

---

## Session 5 — UI fixes + misc (DIV-017, DIV-037, DIV-038, DIV-042, DIV-044, DIV-064, DIV-006)

```bash
SH=services.sh; OUT=needed.txt
sed -n '337,394p' "$SH" > "$OUT"        # _force_quit full (LUKS mapper block device check)
echo "---" >> "$OUT"
sed -n '7092,7115p' "$SH" >> "$OUT"     # _logs_browser (find | sort -r)
echo "---" >> "$OUT"
sed -n '6404,6455p' "$SH" >> "$OUT"     # _qrencode_menu full (while true loop)
echo "---" >> "$OUT"
sed -n '5748,5820p' "$SH" >> "$OUT"     # _container_submenu action dispatch (label arg)
echo "---" >> "$OUT"
sed -n '4600,4660p' "$SH" >> "$OUT"     # _stor_export_menu (full profile picker)
```

---

## Session 6 — Run job + ensure ubuntu (DIV-015, DIV-043)

```bash
SH=services.sh; OUT=needed.txt
sed -n '1499,1550p' "$SH" > "$OUT"      # _ensure_ubuntu ubuntu script (printf pkgs line)
echo "---" >> "$OUT"
sed -n '5244,5302p' "$SH" >> "$OUT"     # _tmux_launch (prompt before session create)
```