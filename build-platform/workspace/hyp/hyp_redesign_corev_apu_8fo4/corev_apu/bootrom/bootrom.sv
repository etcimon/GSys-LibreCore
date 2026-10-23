// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
/* Copyright 2018 ETH Zurich and University of Bologna.
 * Copyright and related rights are licensed under the Solderpad Hardware
 * License, Version 0.51 (the "License"); you may not use this file except in
 * compliance with the License.  You may obtain a copy of the License at
 * http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
 * or agreed to in writing, software, hardware and materials distributed under
 * this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
 * CONDITIONS OF ANY KIND, either express or implied. See the License for the
 * specific language governing permissions and limitations under the License.
 *
 * File: $filename.v
 *
 * Description: Auto-generated bootrom
 */

// Auto-generated code
module bootrom (
   input  logic         clk_i,
   input  logic         req_i,
   input  logic [63:0]  addr_i,
   output logic [63:0]  rdata_o
);
    localparam int RomSize = 221;

    const logic [RomSize-1:0][63:0] mem = {
        64'h00007365_6d616e2d,
        64'h67657200_68746469,
        64'h772d6f69_2d676572,
        64'h00746669_68732d67,
        64'h65720073_74707572,
        64'h7265746e_69006465,
        64'h6570732d_746e6572,
        64'h72756300_6465646e,
        64'h65747865_2d737470,
        64'h75727265_746e6900,
        64'h7365676e_61720074,
        64'h6e657665_6d70686d,
        64'h2d6f742d_746e6576,
        64'h652c7663_73697200,
        64'h656c646e_61687000,
        64'h72656c6c_6f72746e,
        64'h6f632d74_70757272,
        64'h65746e69_00736c6c,
        64'h65632d74_70757272,
        64'h65746e69_23007469,
        64'h6c70732d_626c7400,
        64'h65707974_2d756d6d,
        64'h00736e6f_69736e65,
        64'h7478652d_6173692c,
        64'h76637369_72006573,
        64'h61622d61_73692c76,
        64'h63736972_00617369,
        64'h2c766373_69720073,
        64'h75746174_73006765,
        64'h72006570_79745f65,
        64'h63697665_64007963,
        64'h6e657571_6572662d,
        64'h6b636f6c_63007963,
        64'h6e657571_6572662d,
        64'h65736162_656d6974,
        64'h006c6564_6f6d0065,
        64'h6c626974_61706d6f,
        64'h6300736c_6c65632d,
        64'h657a6973_2300736c,
        64'h6c65632d_73736572,
        64'h64646123_09000000,
        64'h02000000_02000000,
        64'h02000000_006c6f72,
        64'h746e6f63_39010000,
        64'h08000000_03000000,
        64'h00100000_00000000,
        64'h00000018_00000000,
        64'h5b000000_10000000,
        64'h03000000_07000000,
        64'h06000000_05000000,
        64'h04000000_17010000,
        64'h10000000_03000000,
        64'h00007265_6d69745f,
        64'h6270612c_706c7570,
        64'h1b000000_0f000000,
        64'h03000000_00003030,
        64'h30303030_38314072,
        64'h656d6974_01000000,
        64'h02000000_04000000,
        64'h2c010000_04000000,
        64'h03000000_02000000,
        64'h22010000_04000000,
        64'h03000000_01000000,
        64'h17010000_04000000,
        64'h03000000_00c20100,
        64'h09010000_04000000,
        64'h03000000_80f0fa02,
        64'h3f000000_04000000,
        64'h03000000_00100000,
        64'h00000000_00000010,
        64'h00000000_5b000000,
        64'h10000000_03000000,
        64'h00000000_61303535,
        64'h3631736e_1b000000,
        64'h09000000_03000000,
        64'h00000030_30303030,
        64'h30303140_74726175,
        64'h01000000_02000000,
        64'h00000c00_00000000,
        64'h00000002_00000000,
        64'h5b000000_10000000,
        64'h03000000_07000000,
        64'h01000000_03000000,
        64'h01000000_f5000000,
        64'h10000000_03000000,
        64'h00003074_6e696c63,
        64'h2c766373_69720030,
        64'h746e696c_632c6576,
        64'h69666973_1b000000,
        64'h1b000000_03000000,
        64'h00000030_30303030,
        64'h30324074_6e696c63,
        64'h01000000_ee000000,
        64'h00000000_03000000,
        64'h00007375_622d656c,
        64'h706d6973_00636f73,
        64'h2d657261_622d656e,
        64'h61697261_2c687465,
        64'h1b000000_1f000000,
        64'h03000000_02000000,
        64'h0f000000_04000000,
        64'h03000000_02000000,
        64'h00000000_04000000,
        64'h03000000_00636f73,
        64'h01000000_02000000,
        64'h00000010_00000000,
        64'h00000080_00000000,
        64'h5b000000_10000000,
        64'h03000000_00007972,
        64'h6f6d656d_4f000000,
        64'h07000000_03000000,
        64'h00303030_30303030,
        64'h38407972_6f6d656d,
        64'h01000000_02000000,
        64'h02000000_02000000,
        64'h0a000000_00000000,
        64'h0a000000_09000000,
        64'h00000000_09000000,
        64'h06000000_00000000,
        64'h06000000_05000000,
        64'h00000000_05000000,
        64'h04000000_00000000,
        64'h04000000_03000000,
        64'h00000000_03000000,
        64'h02000000_00000000,
        64'h02000000_01000000,
        64'h00000000_01000000,
        64'hd5000000_60000000,
        64'h03000000_00000075,
        64'h6d702c76_63736972,
        64'h1b000000_0a000000,
        64'h03000000_00756d70,
        64'h01000000_02000000,
        64'h01000000_cd000000,
        64'h04000000_03000000,
        64'h00006374_6e692d75,
        64'h70632c76_63736972,
        64'h1b000000_0f000000,
        64'h03000000_b8000000,
        64'h00000000_03000000,
        64'h01000000_a7000000,
        64'h04000000_03000000,
        64'h00000000_72656c6c,
        64'h6f72746e_6f632d74,
        64'h70757272_65746e69,
        64'h01000000_9d000000,
        64'h00000000_03000000,
        64'h00003933_76732c76,
        64'h63736972_94000000,
        64'h0b000000_03000000,
        64'h00000065_73756170,
        64'h746e6968_697a0066,
        64'h6d70666f_63737300,
        64'h63747373_006d7068,
        64'h697a0069_65636e65,
        64'h66697a00_72736369,
        64'h7a007274_6e63697a,
        64'h00630064_00660061,
        64'h006d0069_7f000000,
        64'h42000000_03000000,
        64'h00000069_34367672,
        64'h70000000_06000000,
        64'h03000000_00006364,
        64'h66616d69_34367672,
        64'h66000000_0b000000,
        64'h03000000_00000076,
        64'h63736972_1b000000,
        64'h06000000_03000000,
        64'h00000000_79616b6f,
        64'h5f000000_05000000,
        64'h03000000_00000000,
        64'h5b000000_04000000,
        64'h03000000_00757063,
        64'h4f000000_04000000,
        64'h03000000_80f0fa02,
        64'h3f000000_04000000,
        64'h03000000_00000030,
        64'h40757063_01000000,
        64'h00800000_2c000000,
        64'h04000000_03000000,
        64'h00000000_0f000000,
        64'h04000000_03000000,
        64'h01000000_00000000,
        64'h04000000_03000000,
        64'h00000000_73757063,
        64'h01000000_00657261,
        64'h622d656e_61697261,
        64'h2c687465_26000000,
        64'h10000000_03000000,
        64'h00766564_2d657261,
        64'h622d656e_61697261,
        64'h2c687465_1b000000,
        64'h14000000_03000000,
        64'h02000000_0f000000,
        64'h04000000_03000000,
        64'h02000000_00000000,
        64'h04000000_03000000,
        64'h00000000_01000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'hec040000_43010000,
        64'h00000000_10000000,
        64'h11000000_28000000,
        64'h24050000_38000000,
        64'h67060000_edfe0dd0,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_ffdff06f,
        64'h10500073_03c58593,
        64'h00000597_f1402573,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00000000_00000000,
        64'h00040067_07458593,
        64'h00000597_f1402573,
        64'h01f41413_00100413
    };

    logic [$clog2(RomSize)-1:0] addr_q;



  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=bootrom  region=5519  makespan=2.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: addr_q  ready_cycle=1  ready_fo4=2.500  OpenSTA: report_timing -from clk_i -to addr_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i) begin
//     addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node19367 c=2.50 slack=0.00 */
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_ff @(posedge clk_i) begin
        if (req_i) begin
            addr_q <= addr_i[$clog2(RomSize)-1+3:3];
        end
    end

    // hyp8: banked second read stage — the single 221:1 row mux (~30 FO4
    // structural) is split into eight registered 32:1 bank reads plus a
    // registered bank select; the residual 8:1 select stays combinational.
    // Adds one read cycle on top of the emit's addr_q stage (the consumer,
    // g6lc_axi2mem_reg, samples rdata_i three edges after its request beat:
    // req pulse at edge0, addr_q at edge1, this bank stage at edge2, and
    // RD_LAT=3 counts the capture edge from edge0).
    localparam int unsigned BankSelW = ($clog2(RomSize) > 5)
                                     ? $clog2(RomSize) - 5 : 1;
    logic [7:0][63:0] bank_rdata_q;
    logic [BankSelW-1:0] bank_sel_q;

    always_ff @(posedge clk_i) begin
        for (int unsigned b = 0; b < 8; b++) begin
            if ((32 * b + addr_q[4:0]) < RomSize) begin
                bank_rdata_q[b] <= mem[32 * b + addr_q[4:0]];
            end else begin
                bank_rdata_q[b] <= '0;
            end
        end
        bank_sel_q <= (addr_q < RomSize) ? addr_q[$clog2(RomSize)-1:5]
                                         : '0;
    end

    // this prevents spurious Xes from propagating into
    // the speculative fetch stage of the core
    assign rdata_o = bank_rdata_q[bank_sel_q];
endmodule
