---
name: ebus
description: Decode eBUS/ebusd telegrams from a live recording and turn them into config read/write definitions. Use when the user wants to record the bus while changing a value on the heating controller, identify which telegram carries it, decode the field, and add it to the ebusd CSV config. Triggers — "fang ein recording an", "decode this message", "welche nachricht ist das", "bau das als write befehl ein", anything about ebusd grab/decode/config.
---

# ebus — record, decode, configure

You orchestrate; subagents do the heavy reading/editing so this context stays clean.
The deterministic tool everyone uses is `scripts/ebus.sh` (run `ebus.sh help`).
Datatype + CSV details: `reference/datatypes-and-csv.md` (load only when building a field).

System facts live in the project `CLAUDE.md` (device, circuit 22102, addresses, safety rules).

## Safety contract (this project)
- reads / grab / decode / scanvalue → run freely, no confirmation.
- config edits (CSV), `reload`, and **live `write` to the bus** → show the user the exact
  change/command and get explicit OK first. It's a running heat pump.
- every applied config change is git-committed in `/etc/ebusd/config` with a clear message.

## Workflow: decode a value change → write definition

### 1. Record (orchestrator, inline — cheap)
- `ebus.sh grabreset` to clear the grab buffer, then tell the user to make the change.
- Wait until the user confirms they changed it (e.g. "Kühlen-Soll 25°→23°"). Let normal
  bus traffic flow a few seconds before and after.
- `ebus.sh snapshot before` *before* the change is ideal; always `ebus.sh snapshot after`
  once done. (If grab was reset right before, a single `after` snapshot already isolates
  everything new — but two snapshots + `diff` is the robust path.)

### 2. Decode (dispatch a **decoder subagent**, read-only)
Spawn an Explore/general-purpose agent so the raw 70+-telegram dump never enters your
context. Give it: the snapshot file paths, the old & new value, and these instructions:
- run `ebus.sh diff <before> <after>` → candidate telegrams (NEW byte-patterns).
- run `ebus.sh scanvalue 25` and `ebus.sh scanvalue 23` → the raw byte patterns to grep.
- find the telegram whose payload contains the OLD pattern in `before` and the NEW pattern
  in `after`; that pins QQ, ZZ, PBSB, ID, the byte offset, and the datatype/divisor.
- confirm with `ebus.sh decode <DATATYPE> <bytes>`.
- **return only**: QQ, ZZ, PBSB, ID, field offset, datatype, divisor, decoded old/new
  value, and a proposed CSV `w` line. Not the dumps.

### 3. Confirm (orchestrator ↔ user)
Show the user the proposed `w` line and the `write` command it enables. Get OK.

### 4. Apply (dispatch a **modifier subagent**, or do inline if trivial)
Give it the confirmed `w` line + target file `/etc/ebusd/config/15.22102.csv`:
- back up / rely on git; append the `w` row (match byte layout exactly — see reference).
- `ebus.sh reload` (fails loudly on CSV errors), `ebus.sh verify <name>`.
- `ebus.sh commit "<what changed and why>"`.
- return the git diff + verify output.

### 5. Test the write (orchestrator ↔ user — live bus!)
With explicit OK: `ebusctl write -c 22102 <Name> 23`, then `ebus.sh msg <Name>` and/or
check MQTT/Home Assistant. Commit any follow-up tweak.

## Notes
- Periodic broadcasts (`10fe100a...`) change every cycle — that's why `scanvalue` grepping
  beats eyeballing the diff. The target telegram is the one matching BOTH old→new patterns.
- The write PBSB is usually **not** `0621` (that's the read-memory service). Trust the grab.
- Snapshots go to `/home/thomas/claude/recordings/` (gitignored).
