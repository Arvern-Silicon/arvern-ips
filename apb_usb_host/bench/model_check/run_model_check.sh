#!/usr/bin/env bash
#----------------------------------------------------------------------------
# aRVern System IPs - apb_usb_host
# SPDX-License-Identifier: BSD-3-Clause
#----------------------------------------------------------------------------
# Validates the usb_ls_dev device model against the nand2mario usb_hid_host
# core (Icarus Verilog). One simulation per scenario; the core's sources are
# referenced in place, never copied.
#
#   ./run_model_check.sh              all scenarios
#   ./run_model_check.sh kbd pad      the named scenarios
#   ./run_model_check.sh -dump kbd    also write tb_model_check.vcd
#   PLUSARGS="+VERB=2 +SEED=3" ./run_model_check.sh kbd   extra plusargs
#
# Scenarios: kbd mouse pad fast slow delay. Logs and the build go to
# $OUT_DIR (default ./build). Exit status 0 when every scenario passes.
#----------------------------------------------------------------------------
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BENCH=$HERE/../verilog
CORE=$HERE/../../../../arvern-soc/fpga/sipeed_tang_console_138k/rtl/verilog/usb_hid_host
OUT=${OUT_DIR:-$HERE/build}
ALL="kbd mouse pad fast slow delay"

DUMP=""
SCENS=""
for a in "$@"; do
  case "$a" in
    -dump) DUMP="+DUMP" ;;
    *)     SCENS="$SCENS $a" ;;
  esac
done
[ -z "$SCENS" ] && SCENS=$ALL

for f in "$CORE/usb_hid_host.v" "$CORE/usb_hid_host_rom.v"; do
  if [ ! -f "$f" ]; then echo "missing $f"; exit 2; fi
done

mkdir -p "$OUT"
echo "== compile"
iverilog -g2005 -I"$BENCH" -s tb_model_check -o "$OUT/tb_model_check.vvp" \
  "$BENCH/timescale.v" \
  "$HERE/tb_model_check.v" \
  "$BENCH/usb_ls_dev.v" \
  "$CORE/usb_hid_host.v" \
  "$CORE/usb_hid_host_rom.v" || { echo "compile failed"; exit 2; }

fail=0
for s in $SCENS; do
  log="$OUT/$s.log"
  echo "== $s"
  ( cd "$OUT" && vvp -n tb_model_check.vvp +SCEN="$s" $DUMP ${PLUSARGS:-} ) > "$log" 2>&1
  line=$(grep "^MODEL_CHECK" "$log" | tail -1)
  if [ -z "$line" ]; then
    echo "MODEL_CHECK $s: FAIL (no verdict, see $log)"
    fail=1
  else
    echo "$line"
    case "$line" in *": PASS"*) ;; *) fail=1 ;; esac
  fi
  # checker counts of the model
  sed -n '/checker     enabled  count/,/total (enabled checkers)/p' "$log" | sed 's/^/    /'
done

if [ $fail -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; fi
exit $fail
