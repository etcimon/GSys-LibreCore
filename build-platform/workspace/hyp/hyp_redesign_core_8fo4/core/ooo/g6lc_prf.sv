// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 physical register file. Multi-port FF bank; phys 0 hardwired zero.
//
// hyp8 (group 4/5, cut_minimization.md rank 2): the read is now a 2-step
// registered pipeline -- step 1 captures the read address plus a snapshot of
// the in-flight write record, step 2 does the final array mux plus a bypass
// compare against the pending write. This is the operand read that now sits
// in the cycle after the IQ bank grant (the IQ's registered candidate): the
// dispatch presents raddr_i in the presentation cycle and consumes rdata_o
// one cycle later, which is the position the old IRO operand latch held --
// +0 added cycles on issue->execute relative to that boundary.
// Writes are registered the same way (write record -> array one cycle
// later); the step-2 bypass keeps same-address read-after-write correct
// across the pending window: a read of a register whose write is pending
// sees the write data, never the stale array entry.

module g6lc_prf #(
    parameter int unsigned DATA_WIDTH  = 64,
    parameter int unsigned PRF_ENTRIES = 48,
    parameter int unsigned NR_READ     = 4,
    parameter int unsigned NR_WRITE    = 2,
    parameter int unsigned PRF_W       = 6,
    parameter bit ZERO_REG_ZERO = 1'b1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [NR_READ-1:0][PRF_W-1:0]      raddr_i,
    input  logic [NR_READ-1:0]                 read_enable_i,
    output logic [NR_READ-1:0][DATA_WIDTH-1:0] rdata_o,
    input  logic [NR_WRITE-1:0][PRF_W-1:0]     waddr_i,
    input  logic [NR_WRITE-1:0][DATA_WIDTH-1:0] wdata_i,
    input  logic [NR_WRITE-1:0]                we_i
);

  logic [PRF_ENTRIES-1:0][DATA_WIDTH-1:0] mem_q;

  // Step 1 registers: read address + pending write record.
  logic [NR_READ-1:0][PRF_W-1:0]       raddr_q;
  logic [NR_WRITE-1:0][PRF_W-1:0]      waddr_q;
  logic [NR_WRITE-1:0][DATA_WIDTH-1:0] wdata_q;
  logic [NR_WRITE-1:0]                 we_q;

  // Step 2: final mux + bypass compare on the pending write record
  // (highest write port wins on clash, as upstream's write-through).
  always_comb begin
    for (int unsigned r = 0; r < NR_READ; r++) begin
      if (ZERO_REG_ZERO && raddr_q[r] == '0) begin
        rdata_o[r] = '0;
      end else begin
        rdata_o[r] = mem_q[raddr_q[r]];
        for (int unsigned w = 0; w < NR_WRITE; w++) begin
          if (we_q[w] && waddr_q[w] == raddr_q[r] &&
              (!ZERO_REG_ZERO || waddr_q[w] != '0))
            rdata_o[r] = wdata_q[w];
        end
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      raddr_q <= '0;
      we_q    <= '0;
      waddr_q <= '0;
      wdata_q <= '0;
    end else begin
      // A read port keeps its launched address while the owning lane's
      // staged record waits for issue_ack; only an accepted take replaces
      // it, so the step-2 mux still answers the staged operation's operands.
      for (int unsigned r = 0; r < NR_READ; r++)
        if (read_enable_i[r]) raddr_q[r] <= raddr_i[r];
      // pending write record: applied to the array at this edge and held
      // for the step-2 bypass compare of the read launched this cycle
      we_q    <= we_i;
      waddr_q <= waddr_i;
      wdata_q <= wdata_i;
    end
  end

  // Constant-index write. mem_q[waddr] is a variable index of the whole
  // bank (the 30 FO4 field). The highest matching port wins, same as the
  // ascending loop. Phys 0 stays zero when ZERO_REG_ZERO.
  for (genvar e = 0; e < PRF_ENTRIES; e++) begin : gen_wr
    logic [NR_WRITE-1:0]   whit;
    logic                  do_wr;
    logic [DATA_WIDTH-1:0] selected_data;
    for (genvar w = 0; w < NR_WRITE; w++) begin : gen_whit
      assign whit[w] = we_i[w] && (waddr_i[w] == PRF_W'(e)) &&
                       ((e != 0) || !ZERO_REG_ZERO);
    end
    always_comb begin
      do_wr         = 1'b0;
      selected_data = '0;
      for (int unsigned w = 0; w < NR_WRITE; w++) begin
        if (whit[w]) begin
          do_wr         = 1'b1;
          selected_data = wdata_i[w];
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) mem_q[e] <= '0;
      else if (do_wr) mem_q[e] <= selected_data;
    end
  end

endmodule
