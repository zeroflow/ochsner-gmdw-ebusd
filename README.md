# ebusd config & decode workflow — Ochsner / TEM heat pump

Reverse-engineering a **TEM**-controlled heat pump (an **Ochsner GMDW 11 HK plus**,
ground-source DX) on its **eBUS** and turning the observed telegrams into working
[ebusd](https://github.com/john30/ebusd) read/write message definitions — so the pump's
sensors and setpoints show up in Home Assistant.

The decoding is driven as an agent workflow (Claude Code), but the **outputs are plain
files** anyone can reuse: a working ebusd CSV, a Home-Assistant MQTT mapping, and notes
on how TEM's memory-addressing scheme was decoded.

## What's here

```
ebusd-config/
  config/15.22102.csv     Working ebusd message defs for circuit 22102 (TEM controller,
                          slave 15). 30 polled reads + write setpoints. The useful artifact
                          for other Ochsner/TEM owners.
  mqtt-hassio.cfg         ebusd --mqttint mapping that exposes the messages as Home Assistant
                          entities (incl. settable `number` entities for write messages).

.claude/skills/ebus/      The decode workflow itself:
  SKILL.md                How a telegram is isolated, decoded and turned into a CSV row.
  reference/              datatypes-and-csv.md, decode-findings.md (TEM addressing scheme,
                          the read-memory / write-memory services, worked examples).
  scripts/ebus.sh         Deterministic helper around ebusctl (grab/diff/decode/commit).
  scripts/mqtt_*.py       Tiny dependency-free MQTT dump/clear helpers.

CLAUDE.md                 Agent-facing project notes (the "lab notebook" — all verified facts).
```

## Using the config

ebusd loads the CSV via `--configpath` and the HA mapping via `--mqttint`. On the author's
machine the two live files in `ebusd-config/` are **symlinked** into `/etc/ebusd` so this
repo is the single source of truth:

```
/etc/ebusd/config/15.22102.csv  ->  ebusd-config/config/15.22102.csv
/etc/ebusd/mqtt-hassio.cfg       ->  ebusd-config/mqtt-hassio.cfg
```

To reuse on your own system, either copy those two files into your ebusd config dir or
make the same symlinks. The MQTT broker in the helper scripts defaults to the author's LAN
and can be overridden with `EBUSD_MQTT_HOST` / `EBUSD_MQTT_PORT`. The example IPs in the
notes are private LAN addresses — adjust to your network.

> ⚠️ These definitions command a **real, running heat pump**. Reads are safe; review every
> write before sending it. Upper bounds for this unit: flow/DHW max 65 °C.

## Credit / upstream

Names and datatypes were cross-checked against
[john30/ebusd-configuration](https://github.com/john30/ebusd-configuration)
(`tem/15`). This repo adds a *working, polled* subset for one specific unit plus the HA
integration and the decode notes.
