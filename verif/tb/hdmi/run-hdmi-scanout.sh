#!/usr/bin/env bash
# Default-off 640x480 r5g6b5 scanout. Not a board PHY, not 3D, not virtio-gpu.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT="${HDMI_OUT:-/tmp/g6lc-hdmi-scanout}"
VERILATOR="${VERILATOR:-verilator}"
if ! command -v "$VERILATOR" >/dev/null 2>&1 && \
   [ -x /opt/testharness/toolchains/verilator-v5.008/bin/verilator ]; then
  VERILATOR=/opt/testharness/toolchains/verilator-v5.008/bin/verilator
fi
mkdir -p "$OUT"
python3 "$ROOT/verif/tb/hdmi/simplefb_model.py" \
  "$ROOT/corev_apu/hdmi/g6lc-simplefb.dtsi" \
  "$ROOT/corev_apu/bootrom"
"$VERILATOR" --binary --timing -Wno-fatal -Wall \
  -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv" \
  "$ROOT/verif/tb/hdmi/tb_g6lc_hdmi_scanout.sv" \
  --top-module tb_g6lc_hdmi_scanout \
  -Mdir "$OUT" -o tb_g6lc_hdmi_scanout
( cd "$OUT" && ./tb_g6lc_hdmi_scanout )
"$VERILATOR" --binary --timing -Wno-fatal -Wall \
  -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_linebuf.sv" \
  "$ROOT/verif/tb/hdmi/tb_g6lc_hdmi_linebuf.sv" \
  --top-module tb_g6lc_hdmi_linebuf \
  -Mdir "$OUT/lb" -o tb_g6lc_hdmi_linebuf
( cd "$OUT/lb" && ./tb_g6lc_hdmi_linebuf )
"$VERILATOR" --binary --timing -Wno-fatal -Wall \
  -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_linebuf.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_tmds.sv" \
  "$ROOT/verif/tb/hdmi/tb_g6lc_hdmi_tmds.sv" \
  --top-module tb_g6lc_hdmi_tmds \
  -Mdir "$OUT/tmds" -o tb_g6lc_hdmi_tmds
( cd "$OUT/tmds" && ./tb_g6lc_hdmi_tmds )
"$VERILATOR" --binary --timing -Wno-fatal -Wall \
  -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-UNUSEDSIGNAL \
  -Wno-PINCONNECTEMPTY \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_linebuf.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_tmds.sv" \
  "$ROOT/corev_apu/hdmi/g6lc_hdmi_ser.sv" \
  "$ROOT/verif/tb/hdmi/tb_g6lc_hdmi_ser.sv" \
  --top-module tb_g6lc_hdmi_ser \
  -Mdir "$OUT/ser" -o tb_g6lc_hdmi_ser
( cd "$OUT/ser" && ./tb_g6lc_hdmi_ser )
if [[ "${HDMI_SYNTH:-1}" == 1 ]]; then
  YOSYS="${YOSYS:-/opt/testharness/toolchains/formal/bin/yosys}"
  for en in 0 1; do
    "$VERILATOR" --lint-only -Wall -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
      -Wno-UNUSEDSIGNAL \
      "$ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv" \
      --top-module g6lc_hdmi_scanout -GHdmiEn="1'b$en"
    "$YOSYS" -Q -T -p "read_slang $ROOT/corev_apu/hdmi/g6lc_hdmi_scanout.sv --top g6lc_hdmi_scanout -GHdmiEn=1'b$en; hierarchy -top g6lc_hdmi_scanout; flatten; proc; opt; check -assert; stat; synth -top g6lc_hdmi_scanout -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
    "$YOSYS" -Q -T -p "read_slang $ROOT/corev_apu/hdmi/g6lc_hdmi_linebuf.sv --top g6lc_hdmi_linebuf -GHdmiEn=1'b$en; hierarchy -top g6lc_hdmi_linebuf; flatten; proc; opt; memory; check -assert; stat; synth -top g6lc_hdmi_linebuf -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
    "$VERILATOR" --lint-only -Wall -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
      -Wno-UNUSEDSIGNAL \
      "$ROOT/corev_apu/hdmi/g6lc_hdmi_tmds.sv" \
      --top-module g6lc_hdmi_tmds -GHdmiEn="1'b$en"
    "$YOSYS" -Q -T -p "read_slang $ROOT/corev_apu/hdmi/g6lc_hdmi_tmds.sv --top g6lc_hdmi_tmds -GHdmiEn=1'b$en; hierarchy -top g6lc_hdmi_tmds; flatten; proc; opt; check -assert; stat; synth -top g6lc_hdmi_tmds -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
    "$VERILATOR" --lint-only -Wall -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
      -Wno-UNUSEDSIGNAL \
      "$ROOT/corev_apu/hdmi/g6lc_hdmi_ser.sv" \
      --top-module g6lc_hdmi_ser -GHdmiEn="1'b$en"
    "$YOSYS" -Q -T -p "read_slang $ROOT/corev_apu/hdmi/g6lc_hdmi_ser.sv --top g6lc_hdmi_ser -GHdmiEn=1'b$en; hierarchy -top g6lc_hdmi_ser; flatten; proc; opt; check -assert; stat; synth -top g6lc_hdmi_ser -noabc; check -assert; stat; select -assert-none t:\$dlatch t:\$_DLATCH_*"
  done
fi
