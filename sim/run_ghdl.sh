#!/usr/bin/env bash
# Regression runner for GHDL.
#
#   ./sim/run_ghdl.sh                 # run full regression
#   ./sim/run_ghdl.sh 8e2             # run only configs whose name matches "8e2"
#   WAVES=1 ./sim/run_ghdl.sh 8n1     # also dump waveforms (sim/build/<name>.ghw)
#   TB_ARGS='-gg_tests=rx_overflow' ./sim/run_ghdl.sh 8n1_115200
#
# Exit code: 0 if all selected configs passed, 1 otherwise.
set -u

SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SIM_DIR/.." && pwd)"
BUILD="$SIM_DIR/build"
RTL_DIR="${RTL_DIR:-$ROOT}"   # root for paths in rtl.f

FILTER="${1:-}"
FLAGS=(--std=08 --workdir="$BUILD")

# name | top | generics
CONFIGS=(
  "fifo_d16_reject | tb_fifo      | -gg_fifo_size=16 -gg_threshold=1  -gg_force_wrap=0"
  "fifo_d16_wrap   | tb_fifo      | -gg_fifo_size=16 -gg_threshold=8  -gg_force_wrap=1 -gg_seed=2"
  "fifo_d1_reject  | tb_fifo      | -gg_fifo_size=1  -gg_threshold=0  -gg_force_wrap=0 -gg_seed=3"
  "fifo_d1_wrap    | tb_fifo      | -gg_fifo_size=1  -gg_threshold=0  -gg_force_wrap=1 -gg_seed=4"
  "fifo_d5_wrap_w3 | tb_fifo      | -gg_fifo_size=5  -gg_threshold=4  -gg_force_wrap=1 -gg_byte_size=3 -gg_seed=5"
  "uart_8n1_115200 | tb_uart      | -gg_baud=115200  -gg_stop_bits=1 -gg_parity_en=0"
  "uart_8e1_115200 | tb_uart      | -gg_baud=115200  -gg_stop_bits=1 -gg_parity_en=1 -gg_parity_odd=0"
  "uart_8o2_115200 | tb_uart      | -gg_baud=115200  -gg_stop_bits=2 -gg_parity_en=1 -gg_parity_odd=1"
  "uart_7e1_115200 | tb_uart      | -gg_baud=115200  -gg_data_bits=7 -gg_parity_en=1 -gg_seed=3"
  "uart_8n1_921600 | tb_uart      | -gg_baud=921600  -gg_fifo_size=4 -gg_seed=5"
  "uart_8e2_2M     | tb_uart      | -gg_baud=2000000 -gg_stop_bits=2 -gg_parity_en=1 -gg_parity_odd=0"
  "main_8e2_2M     | tb_uart_main | "
)

mkdir -p "$BUILD"
rm -f "$BUILD"/*.cf

echo "== Analyze (RTL_DIR=$RTL_DIR)"
while read -r f; do
  [[ -z "$f" || "$f" == \#* ]] && continue
  ghdl -a "${FLAGS[@]}" "$RTL_DIR/$f" || { echo "Analysis failed: $f"; exit 1; }
done < "$SIM_DIR/rtl.f"
while read -r f; do
  [[ -z "$f" || "$f" == \#* ]] && continue
  ghdl -a "${FLAGS[@]}" "$SIM_DIR/$f" || { echo "Analysis failed: $f"; exit 1; }
done < "$SIM_DIR/tb.f"

declare -a RESULTS
fail=0
for entry in "${CONFIGS[@]}"; do
  IFS='|' read -r name top gens <<< "$entry"
  name="$(echo $name)"; top="$(echo $top)"
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue

  log="$BUILD/$name.log"
  wave=()
  [[ "${WAVES:-0}" == "1" ]] && wave=(--wave="$BUILD/$name.ghw")

  echo "== Run $name ($top)"
  start=$(date +%s)
  # shellcheck disable=SC2086
  ghdl -r "${FLAGS[@]}" "$top" $gens ${TB_ARGS:-} \
       --ieee-asserts=disable-at-0 "${wave[@]}" > "$log" 2>&1
  rc=$?
  dur=$(( $(date +%s) - start ))

  if [[ $rc -eq 0 ]] && grep -q "TEST PASSED" "$log"; then
    status="PASS"
  else
    status="FAIL"; fail=1
  fi
  errs=$(grep -c "\[ERROR\]" "$log")
  RESULTS+=("$(printf '%-18s %-13s %-5s %4s errors %4ss' "$name" "$top" "$status" "$errs" "$dur")")
done

echo
echo "================ Regression summary ================"
printf '%s\n' "${RESULTS[@]}"
echo "Logs: $BUILD/<name>.log"
exit $fail
