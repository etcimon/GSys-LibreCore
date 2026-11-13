// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Boot recovery agent (native-composition.md, C6b). After reset the checkpoint
// endpoint initializes locked when a valid checkpoint exists, and a locked
// endpoint only accepts RESTORE while every producer is already paused. The
// hart therefore cannot issue it. This platform-owned agent does, once per
// reset, on the endpoint's ordinary control port:
//   wait initialized -> (locked && checkpoint) ? hold pause : done
//   all producers paused && service usable -> write RESTORE(cookie)
//   poll STATUS for RESULT -> read code -> CONSUME(cookie) -> done
// Any refusal or non-OK result is terminal: failed_o stays set and the pause
// is held, so no producer ever runs on RAM that was not restored. A lock taken
// later at run time is not recovered here (that would roll back live state).
// own_o selects this agent as the control-port master; it is asserted only
// while pause is held, when the hart and debug gates are closed and drained.
// Timing: small FSM, registered outputs except the req struct decode.
module g6lc_storamic_boot_recovery #(
  parameter bit Enable = 1'b1,
  parameter logic [31:0] Cookie = 32'h5245_4356,   // "RECV"
  parameter type req_t = g6lc_storamic_pkg::axil_req_t,
  parameter type resp_t = g6lc_storamic_pkg::axil_resp_t
) (
  input logic clk_i, rst_ni,
  input logic initialized_i, recovery_locked_i, checkpoint_valid_i,
  input logic producers_paused_i,   // every producer paused and drained
  input logic service_usable_i,     // control enabled and command admitted
  output logic pause_hold_o,
  output logic own_o,
  output req_t req_o,
  input resp_t resp_i,
  output logic active_o, done_o, failed_o
);
  typedef enum logic [3:0] {
    RWait, RPause, RCmd, RCmdB, RStat, RStatR, RCode, RCodeR, RAck, RAckB, RDone, RFail
  } state_e;
  state_e state_q;
  logic aw_q, w_q;
  localparam logic [1:0] RespOkay = 2'b00;

  assign done_o = state_q == RDone;
  assign failed_o = state_q == RFail;
  assign active_o = !(state_q inside {RWait, RDone, RFail});
  assign pause_hold_o = Enable && state_q != RDone;
  assign own_o = Enable && !(state_q inside {RWait, RPause, RDone, RFail});

  always_comb begin
    req_o = '0;
    unique case (state_q)
      RCmd: begin
        req_o.aw.addr = 64'h04; req_o.aw_valid = !aw_q;
        req_o.w.data = Cookie; req_o.w.strb = '1; req_o.w_valid = !w_q;
      end
      RAck: begin
        req_o.aw.addr = 64'h08; req_o.aw_valid = !aw_q;
        req_o.w.data = Cookie; req_o.w.strb = '1; req_o.w_valid = !w_q;
      end
      RCmdB, RAckB: req_o.b_ready = 1'b1;
      RStat: begin req_o.ar.addr = 64'h10; req_o.ar_valid = 1'b1; end
      RCode: begin req_o.ar.addr = 64'h18; req_o.ar_valid = 1'b1; end
      RStatR, RCodeR: req_o.r_ready = 1'b1;
      default: ;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q <= Enable ? RWait : RDone;
      aw_q <= 1'b0;
      w_q <= 1'b0;
    end else begin
      unique case (state_q)
        RWait: if (initialized_i)
          state_q <= (recovery_locked_i && checkpoint_valid_i) ? RPause : RDone;
        RPause: if (producers_paused_i && service_usable_i) begin
          state_q <= RCmd; aw_q <= 1'b0; w_q <= 1'b0;
        end
        RCmd, RAck: begin
          if (req_o.aw_valid && resp_i.aw_ready) aw_q <= 1'b1;
          if (req_o.w_valid && resp_i.w_ready) w_q <= 1'b1;
          if ((aw_q || (req_o.aw_valid && resp_i.aw_ready)) &&
              (w_q || (req_o.w_valid && resp_i.w_ready)))
            state_q <= state_q == RCmd ? RCmdB : RAckB;
        end
        RCmdB: if (resp_i.b_valid)
          state_q <= resp_i.b.resp == RespOkay ? RStat : RFail;
        RStat: if (resp_i.ar_ready) state_q <= RStatR;
        RStatR: if (resp_i.r_valid) begin
          if (resp_i.r.resp != RespOkay) state_q <= RFail;
          else state_q <= resp_i.r.data[1] ? RCode : RStat;   // RESULT bit
        end
        RCode: if (resp_i.ar_ready) state_q <= RCodeR;
        RCodeR: if (resp_i.r_valid) begin
          if (resp_i.r.resp != RespOkay || resp_i.r.data != '0) state_q <= RFail;
          else begin state_q <= RAck; aw_q <= 1'b0; w_q <= 1'b0; end
        end
        RAckB: if (resp_i.b_valid)
          state_q <= resp_i.b.resp == RespOkay ? RDone : RFail;
        default: ;
      endcase
    end
  end
endmodule
