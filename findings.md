# Findings

Decode findings & investigations for the TEM / Ochsner GMDW 11 HK plus heat pump
(ebusd circuit `15.22102`). Companion to `CLAUDE.md` (system facts) and the `ebus`
skill reference (`.claude/skills/ebus/reference/decode-findings.md`, bus/datatype detail).

---

## 2026-06-30 — Energy counters decoded; Schaltzyklen/Betriebsstunden proven un-capturable

### TL;DR
- **6 energy counters** at `7d87..7d8c` (selector `0002`) decoded and live-verified — see table.
  They had been **mislabeled** in the config (phantom `HpHours`/`HpVolume1`/`HpVolume2`).
- **Schaltzyklen (~70166)** and **Betriebsstunden (~17137)** are **NOT obtainable from our bus
  tap at all** — not a "didn't find it" but a "there is nothing to find". The cellar display
  **computes/stores them itself**; it never asks the controller for them. Proven below.

### Energy counters (live-verified, now in `config/15.22102.csv`)
TEM splits a large quantity into two 2-byte fields: a MWh field (÷1) and a kWh remainder
field (÷10, always < 1000). All are `UIN` LE, answer `NN=0x0a` = 8-byte meta (`IGN:8`) + 2-byte value.

| Name | ID | datatype | divisor | displayed |
|------|-----|----------|---------|-----------|
| HpHeatKwh | `7d870002` | UIN | 10 | 207.0 kWh |
| HpHeatMwh | `7d880002` | UIN | 1  | 149 MWh |
| HpCoolKwh | `7d890002` | UIN | 10 | 7.8 kWh |
| HpCoolMwh | `7d8a0002` | UIN | 1  | 4 MWh |
| HpHwcKwh  | `7d8b0002` | UIN | 10 | 818.7 kWh |
| HpHwcMwh  | `7d8c0002` | UIN | 1  | 32 MWh |

→ Heiz 149 MWh + 207.0 kWh, Kühl 4 MWh + 7.8 kWh, WW 32 MWh + 818.7 kWh. The 6 raw values
matched the cellar-display menu readings exactly and in consecutive ID order — conclusive.

These six IDs previously carried wrong guesses (`HpHours`@7d87, `HpVolume1`@7d88,
`HpVolume2`@7d89, `Wärmemenge`…). On a DX-direct-evaporation monovalent unit there is no
source-water flow, so the "Volumenstrom" rows were never real. Corrected + their stale HA
discovery topics cleared.

### Schaltzyklen / Betriebsstunden — confirmed dead-end

**Goal:** read Schaltzyklen (compressor switch cycles, ~70166) and Betriebsstunden
(operating hours, ~17137) like the energy counters.

**Both are > 16 bit**, so a controller datapoint would need a 4-byte value ⇒ a read-memory
answer of `NN=0x0c` (12 bytes = 8 meta + 4 value).

**Everything we tried (all negative):**
1. Two **menu-navigation** grabs (incl. the WP-Info sub-menu that holds these screens).
2. A full cellar-display **cold boot** grab (display re-reads its datapoints on power-up).
3. **Direct address probing**: `7d8d..7d93` (→ `ff9f…` "not present" marker) and the
   DP-formula candidates `02d0/02d1` (= `0x02b5 + (DP−53)` for DP 02-080/081 from the public
   config) → exist but are only 2-byte values (7, 327, 0, 0), not the counters.
4. **Public TEM config** (john30 `src/tem/15.tsp`) places `Sz_1`/`Bs_1` as `HCD` at
   `7d87/7d88` selector `0002` — but on **our** unit those IDs are the *energy* counters
   (verified). Our unit's stats-block layout diverges from the public config.
5. **Split-half hypothesis**: since big numbers are split into two 2-byte fields, searched the
   boot dump for the halves `70`+`166` and `17`+`137` (and high/low-word splits). **Absent.**

**The decisive evidence — cold-boot read inventory.** The grab has two masters:
`QQ=01` = **the cellar display** (the device being read/manipulated), `QQ=31` = ebusd's own polls.
On boot the **display (`01`)** freshly read ~25 controller datapoints, every one answering
`NN=0x0a` (2-byte value). The set it read:

- temps/status: `0080 0084 0087 0088 00c6 00c7 00e0 0196 01cc 02b5 02c6 02c8 068e` (sel 0040/0042),
  `7d80 7d81 7d82 7d83 7d86` (sel 0002)
- **the energy block `7d87..7d8c`** (all six, values as in the table above)

**Not one** read returns 70166 / 17137 / a split-half / any >16-bit number (only a `32768`
flag). And **across the entire boot, no `NN=0x0c` (4-byte) telegram ever appears** — the
controller serves only 2-byte values on our segment.

**Conclusion.** It is *not* the wiring (ebusd sits cleanly in parallel to the cellar display, so
every display↔controller exchange is visible — and indeed we capture the energy reads). It is
*not* "behind the controller / on the invisible sub-bus" (the energy counters *are*
controller datapoints and get read fine). **The display simply never asks the controller for
Schaltzyklen/Betriebsstunden.** It already polls the compressor status (`7d80` HpStatus,
`7d86` Verdichterdrehzahl) and **maintains the switch-cycle count and runtime hours in its own
memory (NVRAM)**. There is no eBUS telegram for these two values, so no capture/probe can ever
retrieve them from our tap. Energy kWh/MWh are reachable and mapped; cycles/hours are not.

**If ever needed anyway:** the only remaining routes are out of scope for the bus tap —
read the display's own memory, or tap the segment between controller and the heat-generator
(WE) sub-units where a hardware cycle/hour counter might live.
