# ebusd working environment

This VM runs **ebusd** (eBUS daemon) talking to a TEM heat-pump heating system.
Goal of this project: decode telegrams seen on the bus and turn them into ebusd config
read/write definitions. Primary workflow lives in the `ebus` skill (`.claude/skills/ebus`).

## How I work here (orchestrator + subagents)
- I keep this main context **clean**. The heavy, noisy work — reading 70+-telegram grab
  dumps, decoding, editing CSV — is delegated to subagents that return only a compact
  result. See the `ebus` skill for the exact dispatch points (decoder agent, modifier agent).
- The deterministic helper is `.claude/skills/ebus/scripts/ebus.sh` (run `ebus.sh help`).
  Prefer it over ad-hoc `ebusctl` pipelines so actions are reproducible and output is small.

## Safety contract
- **reads / grab / decode / scanvalue**: run freely.
- **config edits, `reload`, and live `write` to the bus**: show the exact change/command and
  get explicit user OK first. This controls a real, running heat pump.
- Every applied config change is git-committed in `/etc/ebusd/config`.

## Git / tracking
- `/etc/ebusd` — git repo (root), the **config history** (rollback-ready). Tracks
  `config/15.22102.csv` **and** the `.cfg` files (`mqtt-hassio.cfg`, `mqtt-integration.cfg`,
  `knx.cfg`). Commit on every applied change via `ebus.sh commit "<msg>"`. Operated as
  `thomas` on a root-owned dir → added to git `safe.directory`.
- `/home/thomas/claude` — git repo, the **tooling + notes** (CLAUDE.md, the `ebus` skill,
  decode-session notes). `recordings/` (raw grab snapshots) is gitignored.

## System facts (verified 2026-06-29)
- ebusd **25.1**, systemd service `ebusd.service`, options in `/etc/default/ebusd`.
- Device: `ens:192.168.5.36:9999` (network eBUS adapter, enhanced proto). Signal acquired.
- MQTT bridge to Home Assistant at `192.168.4.11:1883` (`--mqttjson`, `mqtt-hassio.cfg`).
- `ebusctl` on `localhost:8888`.
- Manufacturer **TEM**. Slaves seen: `15` (=circuit **22102**, the main controller),
  `08`/`18` (WE_1/WE_2 = Wärmeerzeuger), `06`. ebusd's own address: master `31` / slave `36`.
- **Active config: only `/etc/ebusd/config/15.22102.csv`** (custom, not from the public repo).
  After cleanup (2026-06-29): **29 `r1` (polled) read messages, no `w` yet** — building writes
  is the point. Each row skips the 8-byte TEM metadata block via `IGN:8` and exposes one value
  field. All are `r1` so ebusd polls them (`poll: 29`, ~2.5 min cycle) → HA stays current.
- **Passwordless sudo is available** for `thomas` (`/etc/sudoers.d/`), so I can
  `sudo systemctl restart ebusd` myself (needed to reload `mqtt-hassio.cfg`; `ebusctl reload`
  only reloads CSV defs, not the MQTT integration file).
- **HA MQTT discovery is now retained** (`definition-retain = 1` in `mqtt-hassio.cfg`).
  Discovery is published per message only after it has produced data at least once.

## Heat pump (the device behind circuit 22102)
- **Ochsner GMDW 11 HK plus** (Baureihe *Golf Midi Plus*, Best.-Nr. 274600). TEM controller,
  config matches public `ebus.github.io/de/ochsner/15.22102.csv`.
- **Erdreich-Direktverdampfung** (DX ground-source), **monovalent**. Refrigerant **R407C**.
  → No brine/water source circuit ⇒ source-side water sensors don't exist (HpSourceTempIn/Out
  were dummy `unit=0x00` and got removed; `HpVolume2` "Volumenstrom Wärmequelle" is suspect too).
- **Compressor: single-stage FIXED-SPEED Scroll, ~2900 rpm.** No inverter/modulation ⇒ the HP
  runs strictly **on/off**. This validates `HpCycles` = compressor speed in **RPS** (≈0 off /
  ~constant running), and rules out the "modulation %" reading.
- Heating-side nominal flow **2.1 m³/h ≈ 35 l/min** (supports `HpVolume1` in l/min, ~part-load
  now). **Max flow temp (TV) 65 °C**, DHW max 65 °C → sane upper bound when we build *write*
  setpoints (don't command above 65 °C).

## eBUS / ebusd mental model (quick)
- Telegram = `QQ ZZ PB SB NN <data...>` (master→slave); slave may answer with `NN <data>`.
  `QQ`=source master addr, `ZZ`=destination, `PB SB`=service (command) bytes, then ID+payload.
- ebusd loads CSV "message definitions" matching scanned slave IDs (`--scanconfig`). Each row
  is `type,circuit,level,name,comment,QQ,ZZ,PBSB,ID,<fields...>`. See
  `.claude/skills/ebus/reference/datatypes-and-csv.md` for columns + datatypes.
- `grab` continuously records every telegram seen; `grab result all` lists them (telegram
  bytes `= count`). A value change = a telegram with **new bytes** → shows up as a new grab
  entry. That's how we isolate "which message is this".
- **This bus**: reads use `PBSB=0621` + a 4-byte memory address as `ID` (read-memory service).
  Writes/setpoints use a different service — discover it from the grab, don't assume `0621`.
- Temperatures here are mostly `SIN` (2 bytes, little-endian, signed) with divisor `10`
  (raw 230 = 23.0 °C), encoded in the telegram as `e6 00`.

## Useful commands
- `ebus.sh info` — device/signal/scan/addresses.
- `ebus.sh msg <Name>` — definition + current value of a loaded message.
- `ebus.sh snapshot <label>` / `ebus.sh diff <a> <b>` / `ebus.sh scanvalue <n>` — decode loop.
- `ebusctl find -V <name>` / `ebusctl read [-f] <name>` / `ebusctl write -c 22102 <name> <v>`.
