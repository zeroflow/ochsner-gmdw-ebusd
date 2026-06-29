# ebusd CSV + datatype reference (concise)

Source: ebusd wiki "Message definition" (4.1) and "Builtin data types" (4.3). Kept short
on purpose — load this only when writing/decoding a field definition.

## CSV message-definition columns (in order)

```
type, circuit, level, name, comment, QQ, ZZ, PBSB, ID, <field1...>, <field2...>, ...
```

| col | meaning |
|-----|---------|
| `type` | `r`=active read, `r1..r9`=polled read (priority), `w`=active write, `u`/other=passive update (listen). Multiple separated by `;`. |
| `circuit` | circuit name (here: `22102`). May append `#level` for access level. |
| `level` | access level (usually empty). |
| `name` | message name (what you `read`/`write`). |
| `comment` | description. |
| `QQ` | source master addr (hex) or empty = any. ebusd's own addr here is `31`. |
| `ZZ` | destination addr (hex). Slaves here: `15` (=circuit 22102), `08`, `18`, `06`. |
| `PBSB` | primary+secondary command byte (hex, 2 bytes). e.g. `0621`. |
| `ID` | further ID bytes after PBSB (hex). For TEM here it's a 4-byte memory address e.g. `7982000e`. |

### Field columns (repeated, one group per field)
```
name, part, type, divisor/values, unit, comment
```
- `part`: `m`=master data, `s`=slave data. Default: `r`→slave, `w`→master.
- `type`: a builtin datatype (below) or a template name.
- `divisor/values`: numeric divisor (raw/divisor = value), OR `key=label;...` value map.
  A leading factor uses negative divisor convention only inside templates — for plain
  fields use the divisor (e.g. SIN with `10` → raw 230 means 23.0).
- `unit`, `comment`: cosmetic.

A field of type `IGN` with a byte count skips bytes. Constant prefix bytes in the
master payload are often modelled as the `ID` column instead of a field.

## Builtin datatypes (the ones we actually meet on this bus)

| type | bytes | range | encoding | null/replacement |
|------|-------|-------|----------|------------------|
| `UCH` | 1 | 0–254 | unsigned | 0xFF |
| `SCH` | 1 | -127–127 | signed | 0x80 |
| `D1B` | 1 | -127–127 | signed | 0x80 |
| `D1C` | 1 | 0–100.0 | raw/2 (divisor 2) | 0xFF |
| `UIN` | 2 | 0–65534 | unsigned, **low byte first** | 0xFFFF |
| `SIN` | 2 | signed | signed, **low byte first** | 0x8000 |
| `UIR`/`SIR` | 2 | — | high byte first variants | — |
| `D2B` | 2 | -127.99–127.99 | raw/256, low byte first | 0x8000 |
| `D2C` | 2 | -2047.9–2047.9 | raw/16, low byte first | 0x8000 |
| `FLT` | 2 | ±32.767 | raw/1000, low byte first | 0x8000 |
| `BCD`/`HCD` | 1–4 | — | BCD digits | — |
| `BI0:n` | bits | — | bit slice starting at bit 0, n bits | — |
| `HEX` | n | — | raw hex passthrough | — |
| `IGN` | n | — | ignored | — |

**Divisor with integer types**: a plain `SIN`/`UIN`/`UCH` can carry a divisor in the
divisor column to add decimals — e.g. `temp,,SIN,10,°C` → raw 230 = 23.0 °C. This is
the dominant temperature pattern in *this* config (see `15.22102.csv`).

**Byte order reminder**: SIN/UIN/D2x/FLT are **little-endian** (low byte first). So
23.0 with `SIN`+div10 (=230=0x00E6) appears in the telegram as `e6 00`.

## Read vs Write definition

A `w` row sends master data to the slave. To turn an observed setpoint telegram into a
write command:
1. Copy `QQ ZZ PBSB ID` from the grabbed telegram.
2. Put the value field with `part=m` (master) and the right datatype/divisor.
3. Constant payload bytes that are not the value → fold into `ID`, or model as `IGN`/`HEX`
   fields so the byte layout matches exactly.
4. `reload`, then `write -c <circuit> <name> <value>` and verify against a `read`/MQTT.

## TEM-specific pattern on this bus (observed)
- Reads use `PBSB=0621` + 4-byte memory address as `ID`, slave returns the value.
  This is a generic "read memory" service; the address selects the datapoint.
- Writes will likely use a **different** PBSB (a "write memory"/setpoint service). The
  grab/diff during a setpoint change reveals the real write PBSB+ID+payload — do not
  assume it is `0621`.
