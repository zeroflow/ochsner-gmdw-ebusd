# ebusd config & decode workflow — Ochsner / TEM heat pump

Reverse-engineering a **TEM**-controlled heat pump (an **Ochsner GMDW 11 HK plus**,
ground-source DX) on its **eBUS** and turning the observed telegrams into working
[ebusd](https://github.com/john30/ebusd) read/write message definitions — so the pump's
sensors and setpoints show up in Home Assistant.

The decoding is driven as an agent workflow (Claude Code), but the **outputs are plain
files** anyone can reuse: a working ebusd CSV, a Home-Assistant MQTT mapping, and notes
on how TEM's memory-addressing scheme was decoded.

> **Disclaimer — this is my concrete setup shown as a template, not a generic distribution.**
> It documents one specific installation (my hardware, my LAN IPs, my Proxmox/HA layout, my
> way of working). It is not meant to be a turnkey, plug-and-play config. Hardcoded IPs,
> the agent workflow, paths and conventions reflect *my* environment — read it as a worked
> example to adapt, not a product to install as-is. No warranty; you are responsible for
> anything you send to your own heat pump.

## Setup (this installation)

- **eBUS adapter: [eBUS Adapter Shield v5 "C6"](https://adapter.ebusd.eu/v5-c6/).** A
  networked (WiFi/Ethernet) adapter that bridges the heat pump's eBUS onto TCP — no USB or
  serial on the host. ebusd reaches it over the LAN: in `--device=ens:192.168.5.36:9999`,
  `ens` selects the *enhanced, high-speed* protocol the C6 speaks and `:9999` is the port it
  exposes. (`192.168.5.36` is the adapter's address on my network — yours will differ.)
- **ebusd host: a Proxmox LXC container.** ebusd 25.1 runs as a systemd service inside an
  unprivileged **Proxmox VE LXC** (Debian); options live in `/etc/default/ebusd`. Because the
  C6 is network-attached, the container needs **no device passthrough** — only network access
  to the adapter's IP. ebusd's `--mqttint` then bridges the messages to a separate Home
  Assistant instance over MQTT.

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
