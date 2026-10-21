// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// ----------------------------
// AXI to SRAM Adapter
// ----------------------------
// Author: Florian Zaruba (zarubaf@iis.ee.ethz.ch)
//
// Description: Manages AXI transactions
//              Supports all burst accesses but only on aligned addresses and with full data width.
//              Assertions should guide you if there is something unsupported happening.
//
module axi2mem #(
    parameter int unsigned AXI_ID_WIDTH      = 10,
    parameter int unsigned AXI_ADDR_WIDTH    = 64,
    parameter int unsigned AXI_DATA_WIDTH    = 64,
    parameter int unsigned AXI_USER_WIDTH    = 10
)(
    input logic                         clk_i,    // Clock
    input logic                         rst_ni,  // Asynchronous reset active low
    AXI_BUS.Slave                       slave,
    output logic                        req_o,
    output logic                        we_o,
    output logic [AXI_ADDR_WIDTH-1:0]   addr_o,
    output logic [AXI_DATA_WIDTH/8-1:0] be_o,
    output logic [AXI_USER_WIDTH-1:0]   user_o,
    output logic [AXI_DATA_WIDTH-1:0]   data_o,
    input  logic [AXI_USER_WIDTH-1:0]   user_i,
    input  logic [AXI_DATA_WIDTH-1:0]   data_i
);

    // AXI has the following rules governing the use of bursts:
    // - for wrapping bursts, the burst length must be 2, 4, 8, or 16
    // - a burst must not cross a 4KB address boundary
    // - early termination of bursts is not supported.
    typedef enum logic [1:0] { FIXED = 2'b00, INCR = 2'b01, WRAP = 2'b10} axi_burst_t;

    localparam LOG_NR_BYTES = $clog2(AXI_DATA_WIDTH/8);

    typedef struct packed {
        logic [AXI_ID_WIDTH-1:0]   id;
        logic [AXI_ADDR_WIDTH-1:0] addr;
        logic [7:0]                len;
        logic [2:0]                size;
        axi_burst_t                burst;
    } ax_req_t;

    // Registers
    enum logic [2:0] { IDLE, READ, WRITE, SEND_B, WAIT_WVALID }  state_d, state_q;
    ax_req_t                   ax_req_d, ax_req_q;
    logic [AXI_ADDR_WIDTH-1:0] req_addr_d, req_addr_q;
    logic [7:0]                cnt_d, cnt_q;

    function automatic logic [AXI_ADDR_WIDTH-1:0] get_wrap_boundary (input logic [AXI_ADDR_WIDTH-1:0] unaligned_address, input logic [7:0] len);
        logic [AXI_ADDR_WIDTH-1:0] warp_address = '0;
        //  for wrapping transfers ax_len can only be of size 1, 3, 7 or 15
        if (len == 4'b1)
            warp_address[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:1+LOG_NR_BYTES];
        else if (len == 4'b11)
            warp_address[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-1:2+LOG_NR_BYTES];
        else if (len == 4'b111)
            warp_address[AXI_ADDR_WIDTH-1:3+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:2+LOG_NR_BYTES];
        else if (len == 4'b1111)
            warp_address[AXI_ADDR_WIDTH-1:4+LOG_NR_BYTES] = unaligned_address[AXI_ADDR_WIDTH-3:4+LOG_NR_BYTES];

        return warp_address;
    endfunction

    logic [AXI_ADDR_WIDTH-1:0] aligned_address;
    // hyp8: wrap bounds are captured with the request (registered at the same
    // edge as ax_req_q) so the len-dependent boundary function and the
    // (len+1)<<LOG add are off the per-beat address path — the legacy
    // reg->reg cone through get_wrap_boundary was ~55 FO4 structural.
    logic [AXI_ADDR_WIDTH-1:0] wrap_boundary, wrap_d, wrap_q;
    logic [AXI_ADDR_WIDTH-1:0] upper_wrap_boundary, upper_wrap_d, upper_wrap_q;
    logic [AXI_ADDR_WIDTH-1:0] cons_addr;

    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=axi2mem  region=5657  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: ax_req_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to ax_req_q
// order expect: cnt_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to cnt_q
// order expect: req_addr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to req_addr_q
// order expect: state_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to state_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     ax_req_q <= …; // sv-timing: cycle 1/1 on clk_i
//     cnt_q <= …; // sv-timing: cycle 1/1 on clk_i
//     req_addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     state_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node20352 c=3.50 slack=0.00 */
//     /* node20353 c=3.50 slack=0.00 */
//     /* node20354 c=3.50 slack=0.00 */
//     /* node20355 c=3.50 slack=0.00 */
//     /* node20356 c=3.50 slack=0.00 */
//     /* node20357 c=3.50 slack=0.00 */
//     /* node20358 c=3.50 slack=0.00 */
//     /* node20359 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_comb begin
        // address generation
        aligned_address = {ax_req_q.addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}};
        // wrap bounds come from the registered capture (see hyp8 note above)
        wrap_boundary       = wrap_q;
        upper_wrap_boundary = upper_wrap_q;
        // default: hold the captured bounds
        wrap_d       = wrap_q;
        upper_wrap_d = upper_wrap_q;
        // calculate consecutive address
        cons_addr = aligned_address + (cnt_q << LOG_NR_BYTES);

        // Transaction attributes
        // default assignments
        state_d    = state_q;
        ax_req_d   = ax_req_q;
        req_addr_d = req_addr_q;
        cnt_d      = cnt_q;
        // Memory default assignments
        data_o = slave.w_data;
        user_o = slave.w_user;
        be_o   = slave.w_strb;
        we_o   = 1'b0;
        req_o  = 1'b0;
        addr_o = '0;
        // AXI assignments
        // request
        slave.aw_ready = 1'b0;
        slave.ar_ready = 1'b0;
        // read response channel
        slave.r_valid  = 1'b0;
        slave.r_data   = data_i;
        slave.r_resp   = '0;
        slave.r_last   = '0;
        slave.r_id     = ax_req_q.id;
        slave.r_user   = user_i;
        // slave write data channel
        slave.w_ready  = 1'b0;
        // write response channel
        slave.b_valid  = 1'b0;
        slave.b_resp   = 1'b0;
        slave.b_id     = 1'b0;
        slave.b_user   = 1'b0;

        case (state_q)

            IDLE: begin
                // Wait for a read or write
                // ------------
                // Read
                // ------------
                if (slave.ar_valid) begin
                    slave.ar_ready = 1'b1;
                    // sample ax
                    ax_req_d       = {slave.ar_id, slave.ar_addr, slave.ar_len, slave.ar_size, slave.ar_burst};
                    state_d        = READ;
                    // capture the wrap bounds with the request (hyp8)
                    wrap_d         = get_wrap_boundary(slave.ar_addr, slave.ar_len);
                    upper_wrap_d   = wrap_d + ((slave.ar_len + 1) << LOG_NR_BYTES);
                    //  we can request the first address, this saves us time
                    req_o          = 1'b1;
                    addr_o         = slave.ar_addr;
                    // save the address
                    req_addr_d     = slave.ar_addr;
                    // save the ar_len
                    cnt_d          = 1;
                // ------------
                // Write
                // ------------
                end else if (slave.aw_valid) begin
                    slave.aw_ready = 1'b1;
                    slave.w_ready  = 1'b1;
                    addr_o         = slave.aw_addr;
                    // sample ax
                    ax_req_d       = {slave.aw_id, slave.aw_addr, slave.aw_len, slave.aw_size, slave.aw_burst};
                    // capture the wrap bounds with the request (hyp8)
                    wrap_d         = get_wrap_boundary(slave.aw_addr, slave.aw_len);
                    upper_wrap_d   = wrap_d + ((slave.aw_len + 1) << LOG_NR_BYTES);
                    // we've got our first w_valid so start the write process
                    if (slave.w_valid) begin
                        req_o          = 1'b1;
                        we_o           = 1'b1;
                        state_d        = (slave.w_last) ? SEND_B : WRITE;
                        cnt_d          = 1;
                    // we still have to wait for the first w_valid to arrive
                    end else
                        state_d = WAIT_WVALID;
                end
            end

            // ~> we are still missing a w_valid
            WAIT_WVALID: begin
                slave.w_ready = 1'b1;
                addr_o = ax_req_q.addr;
                // we can now make our first request
                if (slave.w_valid) begin
                    req_o          = 1'b1;
                    we_o           = 1'b1;
                    state_d        = (slave.w_last) ? SEND_B : WRITE;
                    cnt_d          = 1;
                end
            end

            READ: begin
                // keep request to memory high
                req_o  = 1'b1;
                addr_o = req_addr_q;
                // send the response
                slave.r_valid = 1'b1;
                slave.r_data  = data_i;
                slave.r_user  = user_i;
                slave.r_id    = ax_req_q.id;
                slave.r_last  = (cnt_q == ax_req_q.len + 1);

                // check that the master is ready, the slave must not wait on this
                if (slave.r_ready) begin
                    // ----------------------------
                    // Next address generation
                    // ----------------------------
                    // handle the correct burst type
                    case (ax_req_q.burst)
                        FIXED, INCR: addr_o = cons_addr;
                        WRAP:  begin
                            // check if the address reached warp boundary
                            if (cons_addr == upper_wrap_boundary) begin
                                addr_o = wrap_boundary;
                            // address warped beyond boundary
                            end else if (cons_addr > upper_wrap_boundary) begin
                                addr_o = ax_req_q.addr + ((cnt_q - ax_req_q.len) << LOG_NR_BYTES);
                            // we are still in the incremental regime
                            end else begin
                                addr_o = cons_addr;
                            end
                        end
                    endcase
                    // we need to change the address here for the upcoming request
                    // we sent the last byte -> go back to idle
                    if (slave.r_last) begin
                        state_d = IDLE;
                        // we already got everything
                        req_o = 1'b0;
                    end
                    // save the request address for the next cycle
                    req_addr_d = addr_o;
                    // we can decrease the counter as the master has consumed the read data
                    cnt_d = cnt_q + 1;
                    // TODO: configure correct byte-lane
                end
            end
            // ~> we already wrote the first word here
            WRITE: begin

                slave.w_ready = 1'b1;

                // consume a word here
                if (slave.w_valid) begin
                    req_o         = 1'b1;
                    we_o          = 1'b1;
                    // ----------------------------
                    // Next address generation
                    // ----------------------------
                    // handle the correct burst type
                    case (ax_req_q.burst)

                        FIXED, INCR: addr_o = cons_addr;
                        WRAP:  begin
                            // check if the address reached warp boundary
                            if (cons_addr == upper_wrap_boundary) begin
                                addr_o = wrap_boundary;
                            // address warped beyond boundary
                            end else if (cons_addr > upper_wrap_boundary) begin
                                addr_o = ax_req_q.addr + ((cnt_q - ax_req_q.len) << LOG_NR_BYTES);
                            // we are still in the incremental regime
                            end else begin
                                addr_o = cons_addr;
                            end
                        end
                    endcase
                    // save the request address for the next cycle
                    req_addr_d = addr_o;
                    // we can decrease the counter as the master has consumed the read data
                    cnt_d = cnt_q + 1;

                    if (slave.w_last)
                        state_d = SEND_B;
                end
            end
            // ~> send a write acknowledge back
            SEND_B: begin
                slave.b_valid = 1'b1;
                slave.b_id    = ax_req_q.id;
                if (slave.b_ready)
                    state_d = IDLE;
            end

        endcase
    end

    `ifndef SYNTHESIS
    `ifndef VERILATOR
    // assert that only full data lane transfers allowed
    // assert property (
    //   @(posedge clk_i) slave.aw_valid |-> (slave.aw_size == LOG_NR_BYTES)) else $fatal ("Only full data lane transfers allowed");
    //   assert property (
    //   @(posedge clk_i) slave.ar_valid |-> (slave.ar_size == LOG_NR_BYTES)) else $fatal ("Only full data lane transfers allowed");
    // assert property (
    //   @(posedge clk_i) slave.aw_valid |-> (slave.ar_addr[LOG_NR_BYTES-1:0] == '0)) else $fatal ("Unaligned accesses are not allowed at the moment");
    // assert property (
    //   @(posedge clk_i) slave.ar_valid |-> (slave.aw_addr[LOG_NR_BYTES-1:0] == '0)) else $fatal ("Unaligned accesses are not allowed at the moment");
    `endif
    `endif
    // --------------
    // Registers
    // --------------
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q    <= IDLE;
            ax_req_q  <= '0;
            req_addr_q <= '0;
            cnt_q      <= '0;
            wrap_q       <= '0;
            upper_wrap_q <= '0;
        end else begin
            state_q    <= state_d;
            ax_req_q   <= ax_req_d;
            req_addr_q <= req_addr_d;
            cnt_q      <= cnt_d;
            wrap_q       <= wrap_d;
            upper_wrap_q <= upper_wrap_d;
        end
    end
endmodule


