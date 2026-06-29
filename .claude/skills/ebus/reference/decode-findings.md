# Decode findings — identified telegrams (not necessarily in our config)

Running log of telegrams we've decoded on this bus, whether or not we added a CSV def.
Keeps us from re-investigating the same "unknown" telegram twice.

## TEM read-memory addressing scheme
ID for a `PBSB=0621` read = `<2-byte datapoint addr, little-endian><2-byte subsystem selector>`.
- Subsystem selector: `0040` = main unit (circuit 15). Others seen: `0042`, `004a`, `0050`,
  `0008`/`000a`/`0010`/`0002` = heat-circuit / Wärmemanager / WE sub-units.
- Datapoint addr is **linear in the documented TEM "02-0xx" parameter number**:
  `addr = 0x02b5 + (DP − 53)`. So the `02xx` block we poll = the controller's datapoint
  table 02-053…02-073.
- The 8-byte `IGN:8` header in each response is the TEM parameter metadata wrapper
  (type/unit/max/min), followed by the actual value field(s).
- Authoritative names/types: `john30/ebusd-configuration` →
  `archived/en/tem/15.csv` (classic) and `src/tem/15.tsp` (modern TypeSpec, German labels).
  Our active public config `ebus.github.io/de/ochsner/15.22102.csv` only defines a subset.

## Identified addresses

| addr (ID) | DP | name | ebusd type | notes | status |
|---|---|---|---|---|---|
| `02b5 0040` | 02-053 | HpMode/Status | status enum | HP operating mode (`cool`/…) | **in our CSV** |
| `02c6 0040` | 02-070 | Datum (system date) | `DAY`/date | stable within a day; raw `79b4` | identified, **not added** |
| `02c8 0040` | 02-072 | Uhrzeit (time of day) | `MIN` (u16 LE, min since midnight) | `fa04`=1274min=21:14, `ff04`=1279min=21:19 — it's the clock ticking, NOT a cooling value | identified, **not added** |
| `02c9 0040` | 02-073 | Wochentag | `BDY` | weekday | identified, **not added** |

### 2026-06-29 — "cooling" investigation result
While the HP was in cooling mode, the two **most-polled** unknown telegrams on the whole bus
were `02c6` and `02c8`, sitting right after `HpMode`. They looked like live cooling values
(one changing upward). Web research against `archived/en/tem/15.csv` proved they are the
controller's **real-time clock** (date + time-of-day) — the "rising" value `fa04→ff04` was just
+5 real minutes. **No hidden cooling signal here.** Decision: documented, deliberately NOT
added to config (RTC is noise, HA already has time).

### Where the real cooling telemetry lives (next leads, unverified)
- `02b3 004a` — HK Status Heizkreisregelung (9=Normal Kühlbetrieb, 11=Spar, 14=Schutz Kühlbetrieb)
- `02b6 0050` — Status Wärmemanager (1=Heizen, **2=Kühlen**)
- Maximale Kühlleistung System (06-002), Frostschutz Passivkühlung (15-090)
- HP sensor cluster `7d80xx` (HpStatus/HpFlowTemp/HpReturnTemp) per upstream
