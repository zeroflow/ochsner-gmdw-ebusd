#!/usr/bin/env bash
# ebus.sh — deterministic helper for the ebusd decode/config workflow.
# Used by the orchestrator and by decoder/modifier subagents so their
# context stays small and their actions are reproducible.
#
# Config via env (defaults shown):
#   EBUSCTL   = ebusctl
#   EBUS_HOST = (local socket; ebusctl default)   set to talk to remote
#   CONFIG_DIR = /etc/ebusd  (git repo root: tracks config/*.csv + the .cfg files)
#   REC_DIR    = /home/thomas/claude/recordings
set -euo pipefail

EBUSCTL="${EBUSCTL:-ebusctl}"
CONFIG_DIR="${CONFIG_DIR:-/etc/ebusd}"
REC_DIR="${REC_DIR:-/home/thomas/claude/recordings}"

ctl() { $EBUSCTL "$@"; }

usage() {
  cat <<'EOF'
ebus.sh <command> [args]

Recording / decoding (read-only, safe):
  snapshot [label]        Save 'grab result all' (+decode) to recordings/<ts>-<label>.grab
                          Prints the file path. Take one BEFORE and one AFTER a change.
  diff <before> <after>   Show telegrams that are NEW or whose data CHANGED between two snapshots.
  scanvalue <decimal>     Print candidate raw byte patterns for a value across common datatypes,
                          so you can grep them in a diff/snapshot to locate the field+encoding.
  grabreset               Restart grabbing (clears accumulated grab buffer) then re-enables grab.
  decode <DATATYPE> <hex> Decode raw data bytes with a datatype (wraps 'ebusctl decode').
  info                    ebusctl info (device, signal, scan, addresses).
  msg <name>              Show loaded definition + current value for a message (find -V + read -f).

Config (mutating — orchestrator must confirm with user first):
  reload                  ebusctl reload; prints any CSV parse errors.
  verify <name>           Confirm a message is loaded; show its definition.
  commit <message>        git add -A && commit in CONFIG_DIR (config history).
  diffcfg                 git diff in CONFIG_DIR (uncommitted config changes).

Env: EBUSCTL=$EBUSCTL  CONFIG_DIR=$CONFIG_DIR  REC_DIR=$REC_DIR
EOF
}

cmd="${1:-}"; shift || true
case "$cmd" in
  snapshot)
    label="${1:-snap}"
    # timestamp from the daemon-independent clock; date is fine here (not in a workflow script)
    ts="$(date +%Y%m%d-%H%M%S)"
    f="$REC_DIR/${ts}-${label}.grab"
    {
      echo "# ebus snapshot $ts label=$label"
      echo "## grab result all"
      ctl grab result all
      echo "## grab result decode"
      ctl grab result decode
    } > "$f"
    echo "$f"
    ;;

  diff)
    [ $# -eq 2 ] || { echo "usage: ebus.sh diff <before> <after>" >&2; exit 2; }
    before="$1"; after="$2"
    # A value change produces a telegram with NEW data bytes -> a new grab key.
    # The trailing '= <count>' is just how often that exact telegram was seen
    # (polling noise), so we compare only the telegram hex (left of '=').
    # keep only the telegram byte-pattern (left of ' = '); drop count + decode label.
    extract() { sed -n '/## grab result all/,/## grab result decode/p' "$1" | grep -E '^[0-9a-f]' | sed 's/ = .*//' | sort -u || true; }
    echo "=== NEW telegram byte-patterns (in AFTER, not in BEFORE) ==="
    echo "    These are the decode candidates. Format: QQZZ PB SB NN <master-data> / NN <slave-data>"
    comm -13 <(extract "$before") <(extract "$after")
    echo
    echo "=== telegram byte-patterns that DISAPPEARED (in BEFORE, not in AFTER) ==="
    echo "    Usually the OLD value of the same message — pairs with a NEW one above."
    comm -23 <(extract "$before") <(extract "$after")
    ;;

  scanvalue)
    [ $# -ge 1 ] || { echo "usage: ebus.sh scanvalue <decimal>" >&2; exit 2; }
    v="$1"
    echo "Candidate raw byte patterns for value $v (grep these in a snapshot/diff):"
    awk -v v="$v" 'BEGIN{
      # 1-byte
      b1=v % 256; if(b1<0)b1+=256;
      printf "  UCH/SCH/U1L (1B, x1)        : %02x\n", b1;
      # D1C divisor 2
      r=v*2; lo=int(r)%256; printf "  D1C (1B, /2)                : %02x\n", lo;
      # 2-byte little-endian for several divisors
      split("1:1 10:10 16:16(D2C) 256:256(D2B) 1000:1000(FLT)", arr, " ");
      n=split("1 10 16 256 1000", divs, " ");
      split("x1 /10 /16=D2C /256=D2B /1000=FLT", labs, " ");
      for(i=1;i<=n;i++){
        raw=int(v*divs[i]+ (v>=0?0.5:-0.5));
        u=raw; if(u<0)u+=65536;
        loB=u%256; hiB=int(u/256)%256;
        printf "  2B LE %-8s            : %02x %02x   (also as %02x%02x)\n", labs[i], loB, hiB, loB, hiB;
      }
    }'
    echo "Note: ebusd shows grabbed data as a contiguous hex string; search both 'lo hi' and 'lohi' forms."
    ;;

  grabreset)
    ctl grab stop >/dev/null 2>&1 || true
    ctl grab >/dev/null 2>&1 || true
    echo "grab restarted (buffer cleared, grabbing enabled)"
    ;;

  decode)
    [ $# -ge 2 ] || { echo "usage: ebus.sh decode <DATATYPE> <hexbytes>" >&2; exit 2; }
    dt="$1"; shift
    ctl decode "$dt" "$@"
    ;;

  info) ctl info ;;

  msg)
    [ $# -ge 1 ] || { echo "usage: ebus.sh msg <name>" >&2; exit 2; }
    echo "=== definition ==="; ctl find -V "$1" || true
    echo "=== current value ==="; ctl read -f "$1" || true
    ;;

  reload)
    out="$(ctl reload 2>&1)"; echo "$out"
    if echo "$out" | grep -qiE 'error|invalid|cannot'; then
      echo ">>> reload reported problems — check the CSV." >&2; exit 1
    fi
    echo ">>> reload OK"
    ;;

  verify)
    [ $# -ge 1 ] || { echo "usage: ebus.sh verify <name>" >&2; exit 2; }
    if ctl find "$1" >/dev/null 2>&1 && [ -n "$(ctl find "$1" 2>/dev/null)" ]; then
      echo ">>> '$1' is loaded:"; ctl find -V "$1"
    else
      echo ">>> '$1' NOT found among loaded messages." >&2; exit 1
    fi
    ;;

  commit)
    [ $# -ge 1 ] || { echo "usage: ebus.sh commit <message>" >&2; exit 2; }
    git -C "$CONFIG_DIR" add -A
    git -C "$CONFIG_DIR" commit -m "$*" && echo ">>> committed in $CONFIG_DIR"
    ;;

  diffcfg) git -C "$CONFIG_DIR" --no-pager diff ;;

  ""|-h|--help|help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage; exit 2 ;;
esac
