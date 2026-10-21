#!/usr/bin/env python3
# MIT — build-platform tooling
# Generate hyp perf_counters.sv: emit base + T3 adaptation
# (registered event select, low/high carry split, 4 hyp_* event inputs).
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
# upstream identity tokens built from fragments — see rename.py
from rename import L as _L, U as _U, AL as _AL  # noqa: E402

_WS = Path(os.environ.get("HYP_WS") or Path(__file__).resolve().parents[3])
SRC = _WS / "build/sv-timing/hyp8-src/emit/core-8fo4/corrected/core/perf_counters__svt.sv"
DST = _WS / "hyp/hyp_redesign_core_8fo4/core/perf_counters.sv"

text = SRC.read_text(encoding="utf-8")

text = text.replace(_AL + "_pkg::", "g6lc_core_pkg::")
text = text.replace("import " + _AL + "_pkg::*", "import g6lc_core_pkg::*")
text = text.replace("config_pkg::" + _L + "_cfg_t", "config_pkg::g6lc_cfg_t")
text = text.replace("config_pkg::" + _L + "_cfg_empty",
                    "config_pkg::g6lc_cfg_empty")
text = re.sub(r"\b" + _U + "Cfg\b", "G6LCCfg", text)

# ---- new event input ports (before mcountinhibit_b_i, the last port) ----
text = text.replace(
    "    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][31:0] mcountinhibit_b_i\n);",
    "    input logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][31:0] mcountinhibit_b_i,\n"
    "    // Group 6: Hyp8 microarchitecture events (tie 0 where the source is\n"
    "    // not yet exposed; see decisions.md group-10 T3)\n"
    "    input logic hyp_iq_replay_i,        // IQ re-arm pulse from the LSQ replay seam\n"
    "    input logic hyp_fe_override1_i,     // frontend override distance-1 taken\n"
    "    input logic hyp_fe_override2_i,     // frontend override distance-2 taken\n"
    "    input logic hyp_wb_reserve_stall_i  // WB-lane reservation stall\n);",
)

# ---- registered event select + carry decls ----
text = text.replace(
    "  // internal signal to detect event on multiple commit ports\n",
    "  // hyp8: the per-counter event select and the low-half wrap carry are\n"
    "  // registered (T3): the OR-tree/attribution fan-in is cut at the counter\n"
    "  // input; an event counts +1 cycle late -- PMU readout only.\n"
    "  logic [NH-1:0] events_q[MHPMCounterNum:1];\n"
    "  logic carry_d[NH][MHPMCounterNum:1], carry_q[NH][MHPMCounterNum:1];\n"
    "  // internal signal to detect event on multiple commit ports\n",
)

# ---- group 6 rows (after the group-5 block, before the reserved note) ----
text = text.replace(
    "      // Groups 6..7 reserved.\n",
    "      // Group 6: Hyp8 microarchitecture events (mhpmevent[7:5]==6).\n"
    "      event_group[h][3'd6][5'd0] = hyp_iq_replay_i && act;        // IQ re-arm\n"
    "      event_group[h][3'd6][5'd1] = hyp_fe_override1_i && act;     // FE override d1\n"
    "      event_group[h][3'd6][5'd2] = hyp_fe_override2_i && act;     // FE override d2\n"
    "      event_group[h][3'd6][5'd3] = hyp_wb_reserve_stall_i && act; // WB reserve stall\n"
    "\n"
    "      // Group 7 reserved.\n",
)

# ---- counter increment: low/high split with registered carry ----
old_inc = """    for (int unsigned h = 0; h < NH; h++) begin
      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        if ((!debug_mode_i) && !(we_i && csr_hart_i == HID_W'(h)) && !event_inhibited[i][h]) begin
          if ((events[i][h]) == 1 && (!mcountinhibit_b_i[h][i+2])) begin
            if (G6LCCfg.SscofpmfEn && (&generic_counter_q[h][i])) begin
              of_d[h][i] = 1'b1;
            end
            generic_counter_d[h][i] = generic_counter_q[h][i] + 1'b1;
          end
        end
      end
    end"""
new_inc = """    for (int unsigned h = 0; h < NH; h++) begin
      for (int unsigned i = 1; i <= MHPMCounterNum; i++) begin
        carry_d[h][i] = 1'b0;
        // hyp8: registered event + carry split (value path, rank 4). The
        // pending low-half carry always applies to the high word (it was
        // qualified when captured); a CSR write below overrides both halves
        // and discards a pending carry -- same precedence as the reference's
        // write-over-increment.
        generic_counter_d[h][i][63:32] = generic_counter_q[h][i][63:32] + {31'b0, carry_q[h][i]};
        if ((!debug_mode_i) && !(we_i && csr_hart_i == HID_W'(h)) && !event_inhibited[i][h]) begin
          if ((events_q[i][h]) == 1 && (!mcountinhibit_b_i[h][i+2])) begin
            if (G6LCCfg.SscofpmfEn && (&generic_counter_q[h][i])) begin
              of_d[h][i] = 1'b1;
            end
            generic_counter_d[h][i][31:0] = generic_counter_q[h][i][31:0] + 1'b1;
            carry_d[h][i] = &generic_counter_q[h][i][31:0];
          end
        end
      end
    end"""
assert old_inc in text
text = text.replace(old_inc, new_inc)

# ---- registers: add events_q / carry_q ----
old_seq = """    end else begin
      generic_counter_q <= generic_counter_d;
      mhpmevent_q       <= mhpmevent_d;"""
new_seq = """    end else begin
      generic_counter_q <= generic_counter_d;
      mhpmevent_q       <= mhpmevent_d;
      events_q          <= events;
      carry_q           <= carry_d;"""
assert old_seq in text
text = text.replace(old_seq, new_seq)

# reset for the new registers
old_rst = """          uinh_q[h][i]            <= 1'b0;
        end
      end
    end else begin"""
new_rst = """          uinh_q[h][i]            <= 1'b0;
          carry_q[h][i]           <= 1'b0;
          events_q[i][h]          <= 1'b0;
        end
      end
    end else begin"""
assert old_rst in text
text = text.replace(old_rst, new_rst)

# ---- hyp8 note under the description ----
text = text.replace(
    "// Description: Performance counters\n",
    "// Description: Performance counters\n"
    "// hyp8 (group-10 T3): the per-counter event select is registered\n"
    "// (events_q -- the OR-tree/attribution fan-in cone is cut there, events\n"
    "// count +1 cycle late) and the 64-bit increment is a low-half add plus\n"
    "// a registered wrap carry into the high half (rank-4 value path).\n"
    "// New group-6 events: hyp_iq_replay, hyp_fe_override{1,2},\n"
    "// hyp_wb_reserve_stall (sources wired in g6lc_core; tied 0 until the\n"
    "// seams exist).\n",
)

DST.write_text(text, encoding="utf-8")
print(f"wrote {DST} ({text.count(chr(10))} lines)")
for pat in [r"\bevents\b\[", r"\b" + _U + "Cfg\b", _AL, _L]:
    hits = [i + 1 for i, l in enumerate(text.splitlines()) if re.search(pat, l)]
    print(pat, "->", hits[:15])


# keep tools/ free of compiled bytecode (the identity grep covers every
# file type — *.pyc embeds the original source tokens)
def _cleanup_pycache():
    import pathlib as _pl
    import shutil as _sh
    _d = _pl.Path(__file__).resolve().parent
    _sh.rmtree(_d / "__pycache__", ignore_errors=True)
    for _f in _d.glob("*.pyc"):
        try:
            _f.unlink()
        except OSError:
            pass


_cleanup_pycache()
