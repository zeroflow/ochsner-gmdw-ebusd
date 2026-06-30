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
- Every applied config change is git-committed in this repo (`/home/thomas/claude`) via
  `ebus.sh commit` — the files live in `ebusd-config/`, symlinked into `/etc/ebusd`.

## Git / tracking
- **Single repo: `/home/thomas/claude`** — tooling + notes (CLAUDE.md, the `ebus` skill,
  decode notes) **and** the live config under `ebusd-config/` (`config/15.22102.csv`,
  `mqtt-hassio.cfg`). This is the publishable repo and the single source of truth.
  `recordings/` (raw grab snapshots) is gitignored. `ebus.sh commit "<msg>"` commits here
  (`CONFIG_DIR=/home/thomas/claude`).
- **The live config is symlinked into `/etc/ebusd`** so ebusd reads it through the repo:
  `/etc/ebusd/config/15.22102.csv` → `ebusd-config/config/15.22102.csv` and
  `/etc/ebusd/mqtt-hassio.cfg` → `ebusd-config/mqtt-hassio.cfg`. ebusd runs as **root** with
  `ProtectHome=no`, so following the symlinks into `/home/thomas` is fine. Edit the files in
  the repo, then `ebusctl reload` (CSV) / `sudo systemctl restart ebusd` (mqtt-hassio.cfg).
- `/etc/ebusd/.git` is the **retired** old config history (archive only, pre-2026-06-30 move);
  its `15.22102.csv`/`mqtt-hassio.cfg` are now symlinks. Don't commit there anymore. The two
  stock cfgs (`knx.cfg`, `mqtt-integration.cfg`) are unused (not on the ebusd command line)
  and were intentionally left out of the published repo.

## System facts (verified 2026-06-29)
- ebusd **25.1**, systemd service `ebusd.service`, options in `/etc/default/ebusd`.
- Device: `ens:192.168.5.36:9999` (network eBUS adapter, enhanced proto). Signal acquired.
- MQTT bridge to Home Assistant at `192.168.4.11:1883` (`--mqttjson`, `mqtt-hassio.cfg`).
- `ebusctl` on `localhost:8888`.
- Manufacturer **TEM**. Slaves seen: `15` (=circuit **22102**, the main controller),
  `08`/`18` (WE_1/WE_2 = Wärmeerzeuger), `06`. ebusd's own address: master `31` / slave `36`.
- **Active config: only `ebusd-config/config/15.22102.csv`** (custom, not from the public repo;
  symlinked to `/etc/ebusd/config/15.22102.csv`).
  After cleanup (2026-06-29): **30 `r1` (polled) read messages + the first `w` (write)**. Each read
  row skips the 8-byte TEM metadata block via `IGN:8` and exposes one value field. All reads are
  `r1` so ebusd polls them (~2.5 min cycle) → HA stays current.
- **First working write (2026-06-29): `SetKuehlgrenze`** (cooling limit). TEM write pattern:
  **`ZZ=10`, `PBSB=0623`** (write-memory; `10` = controller master-face ≡ slave `15`), bare value
  (no `IGN`). Reads of the same datapoint use `ZZ=15`/`0621`/`IGN:8`. **Write rows need an explicit
  circuit** (`w,22102,…`) — a blank circuit + master ZZ=`10` makes ebusd silently drop the row.
  Verified live (`write -c 22102 SetKuehlgrenze 24` → ACK, no expert/password gate). Datapoint
  `6386000a`, `SIN`÷2 °C. Details + bus topology in `.claude/skills/ebus/reference/decode-findings.md`.
- **Read and write can live on DIFFERENT IDs for the same datapoint — don't assume the write reuses
  the read ID.** For Kühl/Heiz setpoints read==write ID (only `ZZ`/`PBSB` differ), but **Warmwasser
  Soll** reads via `7982000e` (`DesiredHwcTemp`, selector `000e`) yet **writes** via `05b3004e`
  (selector `004e`, the Warmwasserkreis-page block — same block as `WwPump`). Always capture the
  actual `ZZ=10`/`0623` write telegram from the grab and use ITS ID for the `w` row; cross-check
  by reading the paired getter (both showed 50.0). Verified live 2026-06-30, `SIN`÷10 °C.
- **Bus topology**: the adapter sits between the WP and the **cellar display** → changes on the
  **cellar display** cross our wire (capturable/replayable). The **EG room terminal** is on a
  separate sub-bus behind the controller → its writes are invisible to us. To decode a setpoint,
  change it on the **cellar display**.
- **Passwordless sudo is available** for `thomas` (`/etc/sudoers.d/`), so I can
  `sudo systemctl restart ebusd` myself (needed to reload `mqtt-hassio.cfg`; `ebusctl reload`
  only reloads CSV defs, not the MQTT integration file).
- **HA MQTT discovery is now retained** (`definition-retain = 1` in `mqtt-hassio.cfg`).
  Discovery is published per message only after it has produced data at least once.
- **HA discovery gotchas (mqtt-hassio.cfg) — a new message won't appear unless it passes the
  filters in that file, and the file is only re-read on a full `systemctl restart ebusd`** (not
  `ebusctl reload`):
  - `filter-name` is a **whitelist** of message-name substrings (`…|flow|part|kwh|grenze|…`). A
    message whose name contains none of the tokens is silently dropped from HA. Added `grenze`
    (Kühl/Heizgrenze), `raum` (Kühl/Heiz Raum-Setpoints; replaced the older full-word `kuehlraum`),
    and `pump` (`HcPump`/`WwPump`) — add/broaden a token when introducing a differently-named
    message, then `systemctl restart ebusd` (filter changes need the cfg file re-read).
  - `filter-direction = r|u|^w` — the `^w` was added to expose **write** messages as settable HA
    entities (a `w` temp field → `number` entity via `type_switch-w-number`). Without it writes are
    hidden. Write-message discovery is NOT gated by "seen" (publishes right after restart); read
    sensors publish after their first poll.
  - A settable number's state_topic is the write message (unpolled) → shows "unknown" until first
    set; the paired `r1` read message is the live-value sensor. ebusd derives the number's
    min/max from the field datatype (SIN÷2 → ±16383.5, step 0.5) — not bounded to a sane range.
  - **A new `r1` READ sensor only appears in HA after its POLL has published once — a manual
    `ebusctl read -f` does NOT trigger it** (it fills ebusd's cache only, no MQTT publish, no
    discovery). After adding reads, wait ~1 poll cycle (~2.5 min) and check
    `mqtt_dump.py 'ebusd/#' 2 '<name>'`; don't diagnose "HA broken" from a `read -f` value.
    Write/`number` entities publish discovery immediately (before any data).
  - **`ebusctl reload` DOES publish HA discovery for newly-added CSV messages** — confirmed
    2026-06-30: a freshly-added `w` row's `number` discovery appeared right after `reload`, no
    restart. So a **restart is only needed when `mqtt-hassio.cfg` itself changes** (filter tokens,
    `type_switch`, retain) — NOT for new CSV reads/writes. (Read sensors still wait for their first
    poll; write/`number` entities publish on the reload. The earlier "file only re-read on restart"
    caveat is about the *cfg file*, not about whether new CSV messages get discovery.)
- **HA entity-id scheme — name-based, NOT object_id (settled 2026-06-30 after testing).**
  ebusd *does* emit `"object_id":"%{TOPIC}_%FIELD"` in `definition-payload` (kept; it would give
  clean ids on a truly fresh HA), **but this HA ignores it.** The live entity_id is:
  `<domain>.<area>_<device-name>_<slug(message-comment)>` lowercased, i.e.
  `slugify("Heating" + "ebusd 22102" + <comment>)`, e.g.
  `number.heating_ebusd_22102_kuhlgrenze_sollwert_kuhlen` (setter, comment "Kühlgrenze Sollwert
  Kühlen") and `sensor.heating_ebusd_22102_kuhlgrenze_sollwert_kuhlen` (getter, comment
  "Kühlgrenze (Sollwert Kühlen)"). Setter/getter share the slug but differ by domain → no clash.
  **This name-based id is what the repo's `homeassistant/` templates reference.** It is stable
  (sticky in HA's registry) as long as the area, device name, and CSV comment don't change.
  - **Why object_id didn't win:** it only applies at the *first* discovery of a unique_id when no
    registry entry exists. These entities were created long before the pin, and the registry entry
    (keyed by unique_id) is **sticky** — HA restores the old entity_id on every rediscovery.
    Clearing retained discovery and even "delete device" in the UI did **not** purge the registry
    entry here (it came back name-based). So: don't fight it — reference the name-based ids.
  - To verify any new entity's real id: Developer Tools → States (don't assume the object_id form).
  - Tooling for a clean slate if ever needed: `mqtt_pub.py <config-topic>` clears one retained
    discovery; `systemctl restart ebusd` republishes (writes immediately, reads after ~2.5 min poll).

## Home Assistant config (`homeassistant/` in this repo)
- Publishable HA YAML the user pulls into their HA box. `ebusd_templates.yaml` = one
  `template number` per writable datapoint, wrapping the ebusd getter `sensor.…` + setter
  `number.…` into a single entity with sane min/max (ebusd's own min/max is ±16383.5 from SIN).
  Import via HA "packages" (header documents the exact include). Add a new block here whenever a
  new write datapoint is decoded; reference the live name-based ids (see "HA entity-id scheme").
  - **`device_id` is NOT a valid option for YAML state-based `template` entities** (HA rejects it:
    "invalid option for 'template'"). So the combined template numbers can't be bound to the
    "ebusd 22102" device from YAML — assign their **Area** ("Heating") in the UI instead, or build
    them as UI Template helpers. The raw ebusd setters/getters DO live on the device.
  - **Raw ebusd setters moved to the device's Configuration section** via `"entity_category":"config"`
    in `type_part-number` (mqtt-hassio.cfg) — declutters the main device view; the template numbers
    are the primary controls. Read sensors stay default (main).
  - Three write pairs live so far: `Kuehlgrenze` (15–40 °C) and `KuehlRaumTag`/`KuehlRaumNacht`
    (room cooling setpoints, 20–30 °C) — all min/max verified against the cellar-display UI.

## Heat pump (the device behind circuit 22102)
- **Ochsner GMDW 11 HK plus** (Baureihe *Golf Midi Plus*, Best.-Nr. 274600). TEM controller,
  config matches public `ebus.github.io/de/ochsner/15.22102.csv`.
- **Erdreich-Direktverdampfung** (DX ground-source), **monovalent**. Refrigerant **R407C**.
  → No brine/water source circuit ⇒ source-side water sensors don't exist (HpSourceTempIn/Out
  were dummy `unit=0x00` and got removed). The old `HpVolume1`/`HpVolume2` "Volumenstrom"
  rows were **mislabeled guesses** — live capture 2026-06-30 proved `7d87..7d8c` are interleaved
  **energy counters** (Heiz/Kühl/WW × kWh,MWh), not flow; renamed `HpHeatKwh/HpHeatMwh/HpCoolKwh/
  HpCoolMwh/HpHwcKwh/HpHwcMwh` (UIN, kWh ÷10 / MWh ÷1; old `HpHours` at `7d87` was wrong too).
- **Compressor: single-stage FIXED-SPEED Scroll, ~2900 rpm.** No inverter/modulation ⇒ the HP
  runs strictly **on/off**. This validates `HpCycles` = compressor speed in **RPS** (≈0 off /
  ~constant running), and rules out the "modulation %" reading.
- Heating-side nominal flow **2.1 m³/h ≈ 35 l/min**. **Max flow temp (TV) 65 °C**, DHW max
  65 °C → sane upper bound when we build *write* setpoints (don't command above 65 °C).
- **Energy counters** (`7d87..7d8c`, live-verified 2026-06-30): Heiz 149 MWh + 207.0 kWh,
  Kühl 4 MWh + 7.8 kWh, WW 32 MWh + 818.7 kWh. kWh field is the sub-MWh remainder (<1000).
  Still TODO: **Schaltzyklen** (~70165) + **Betriebsstunden** (~17136) — both >16-bit so they
  sit on longer (ULG/4-byte) telegrams that the kWh/MWh capture (all NN=0x0a, 10-byte) missed;
  re-record while on those specific screens.

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
- **TEM read-memory ID layout** = `<2-byte datapoint addr LE><2-byte subsystem selector>`.
  Selector `0040` = main unit (circuit 15); other blocks seen: `0042 004a 0050 0008 000a 0010`
  (heat-circuit / Wärmemanager / WE sub-units). The datapoint addr is **linear in the documented
  TEM "02-0xx" parameter number**: `addr = 0x02b5 + (DP − 53)`, e.g. DP 02-053→`02b5` (HpMode),
  02-070→`02c6`, 02-072→`02c8`. So the `02xx` block we poll IS the controller's datapoint table.
  Source of truth for names/types: `john30/ebusd-configuration` → `archived/en/tem/15.csv` and the
  modern `src/tem/15.tsp`. See `.claude/skills/ebus/reference/decode-findings.md`.
- Temperatures here are mostly `SIN` (2 bytes, little-endian, signed) with divisor `10`
  (raw 230 = 23.0 °C), encoded in the telegram as `e6 00`.

## Useful commands
- `ebus.sh info` — device/signal/scan/addresses.
- `ebus.sh msg <Name>` — definition + current value of a loaded message.
- `ebus.sh snapshot <label>` / `ebus.sh diff <a> <b>` / `ebus.sh scanvalue <n>` — decode loop.
- `ebusctl find -V <name>` / `ebusctl read [-f] <name>` / `ebusctl write -c 22102 <name> <v>`.
