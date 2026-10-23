// hyp8 provenance: ADAPTED (sv-timing emit base, AES round split)
// Copyright 2026 Etienne Cimon
// Outbound-License: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Licensed under the Solderpad Hardware Licence, Version 2.1 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Author: Munail Waqar, 10xEngineers
// Date: 03.05.2025
// Description: The Zkn extension including its subsets accelerates cryptographic workloads by introducing dedicated
// scalar instructions compliant with the RISC-V Scalar Cryptography specification. The subsets include:
// Zknd (AES Decryption and related instructions), Zkne (AES Encryption support, including AES rounds and key expansion steps),
// Zknh (SHA-256 and SHA-512 hash functions for secure hashing operations).
//
// hyp8 (group 7): the round is split over one register boundary.
//   Stage 1 (registered): byte select, ShiftRows wiring, all SubBytes /
//     subword S-box lookups, and the SHA sigma/sum XOR transforms (they read
//     only the operand fields). Carried with operand_a/operand_b, the
//     operation and orig_instr_aes.
//   Stage 2 (combinational -> result_o): MixColumns, the rotate/XOR
//     AddRoundKey-equivalent merges, ks1i's rcon xor, ks2, and the result
//     class select.
// result_o arrives one cycle after fu_data_i (+1, rank 4); the ex_stage
// lane record carries the operation's trans_id across the same boundary.
// No port changes; the module has no valid line (ex_stage owns lifetime).

module aes
  import g6lc_core_pkg::*;
  import aes_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                        clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                        rst_ni,
    // FU data needed to execute instruction - ISSUE_STAGE
    input  fu_data_t                    fu_data_i,
    // Original instruction bits for aes
    input  logic     [             5:0] orig_instr_aes,
    // AES result - ISSUE_STAGE
    output logic     [G6LCCfg.XLEN-1:0] result_o
);

  logic [63:0] sr;
  logic [ 7:0] sbox_in;
  logic [63:0] aes64es_gen;
  logic [63:0] aes64ds_gen;
  logic [63:0] sr_inv;
  logic [31:0] aes_subw_in;
  logic [31:0] aes_subw_gen;

  logic [31:0] sha256sig0_gen;
  logic [31:0] sha256sig1_gen;
  logic [31:0] sha256sum0_gen;
  logic [31:0] sha256sum1_gen;

  logic [31:0] sha512sig0h_gen;
  logic [31:0] sha512sig0l_gen;
  logic [31:0] sha512sig1h_gen;
  logic [31:0] sha512sig1l_gen;
  logic [31:0] sha512sum0r_gen;
  logic [31:0] sha512sum1r_gen;

  logic [63:0] sha512sig0_gen;
  logic [63:0] sha512sig1_gen;
  logic [63:0] sha512sum0_gen;
  logic [63:0] sha512sum1_gen;

  // ---------------------------------------------------------
  // Stage 1 (registered): byte select, ShiftRows, all S-boxes,
  // and the SHA XOR transforms.
  // ---------------------------------------------------------
  logic [G6LCCfg.XLEN-1:0] a_q, b_q;
  fu_op                  op_q;
  logic [5:0]            orig_q;
  logic [7:0]            sbox_fwd_q, sbox_inv_q;
  logic [63:0]           aes64es_q, aes64ds_q;
  logic [31:0]           aes_subw_q;
  logic [31:0]           sha256sig0_q, sha256sig1_q, sha256sum0_q, sha256sum1_q;
  logic [31:0]           sh512sig0h_q, sh512sig0l_q, sh512sig1h_q, sh512sig1l_q;
  logic [31:0]           sh512sum0r_q, sh512sum1r_q;
  logic [63:0]           sha512sig0_q, sha512sig1_q, sha512sum0_q, sha512sum1_q;

  if (G6LCCfg.ZKN && G6LCCfg.RVB) begin : aes_gen_block
    // SHA256 sigma0 transformation function by rotating, shifting and XORing rs1
    assign sha256sig0_gen = (fu_data_i.operand_a[31:0] >> 7 | fu_data_i.operand_a[31:0] << 25) ^ (fu_data_i.operand_a[31:0] >> 18 | fu_data_i.operand_a[31:0] << 14) ^ (fu_data_i.operand_a[31:0] >> 3);
    // SHA256 sigma1 transformation function by rotating, shifting and XORing rs1
    assign sha256sig1_gen = (fu_data_i.operand_a[31:0] >> 17 | fu_data_i.operand_a[31:0] << 15) ^ (fu_data_i.operand_a[31:0] >> 19 | fu_data_i.operand_a[31:0] << 13) ^ (fu_data_i.operand_a[31:0] >> 10);
    // SHA256 sum0 transformation function by rotating, shifting and XORing rs1
    assign sha256sum0_gen = (fu_data_i.operand_a[31:0] >> 2 | fu_data_i.operand_a[31:0] << 30) ^ (fu_data_i.operand_a[31:0] >> 13 | fu_data_i.operand_a[31:0] << 19) ^ (fu_data_i.operand_a[31:0] >> 22 | fu_data_i.operand_a[31:0] << 10);
    // SHA256 sum1 transformation function by rotating, shifting and XORing rs1
    assign sha256sum1_gen = (fu_data_i.operand_a[31:0] >> 6 | fu_data_i.operand_a[31:0] << 26) ^ (fu_data_i.operand_a[31:0] >> 11 | fu_data_i.operand_a[31:0] << 21) ^ (fu_data_i.operand_a[31:0] >> 25 | fu_data_i.operand_a[31:0] << 7);
    if (G6LCCfg.IS_XLEN32) begin
      assign sbox_in = fu_data_i.operand_b >> {orig_instr_aes[5:4], 3'b000};
      // SHA512 32-bit shifting and XORing rs1 and rs2
      assign sha512sig0h_gen = (fu_data_i.operand_a >> 1) ^ (fu_data_i.operand_a >> 7) ^ (fu_data_i.operand_a >> 8) ^ (fu_data_i.operand_b << 31) ^ (fu_data_i.operand_b << 24);
      assign sha512sig0l_gen = (fu_data_i.operand_a >> 1) ^ (fu_data_i.operand_a >> 7) ^ (fu_data_i.operand_a >> 8) ^ (fu_data_i.operand_b << 31) ^ (fu_data_i.operand_b << 25) ^ (fu_data_i.operand_b << 24);
      assign sha512sig1h_gen = (fu_data_i.operand_a << 3) ^ (fu_data_i.operand_a >> 6) ^ (fu_data_i.operand_a >> 19) ^ (fu_data_i.operand_b >> 29) ^ (fu_data_i.operand_b << 13);
      assign sha512sig1l_gen = (fu_data_i.operand_a << 3) ^ (fu_data_i.operand_a >> 6) ^ (fu_data_i.operand_a >> 19) ^ (fu_data_i.operand_b >> 29) ^ (fu_data_i.operand_b << 26) ^ (fu_data_i.operand_b << 13);
      assign sha512sum0r_gen = (fu_data_i.operand_a << 25) ^ (fu_data_i.operand_a << 30) ^ (fu_data_i.operand_a >> 28) ^ (fu_data_i.operand_a >> 7) ^ (fu_data_i.operand_b >> 2) ^ (fu_data_i.operand_b << 4);
      assign sha512sum1r_gen = (fu_data_i.operand_a << 23) ^ (fu_data_i.operand_a >> 14) ^ (fu_data_i.operand_a >> 18) ^ (fu_data_i.operand_b >> 9) ^ (fu_data_i.operand_b << 18) ^ (fu_data_i.operand_b << 14);
      assign sr      = '0;
      assign sr_inv  = '0;
      assign aes_subw_in = '0;
      assign aes64es_gen = '0;
      assign aes64ds_gen = '0;
    end else if (G6LCCfg.IS_XLEN64) begin
      assign sbox_in = '0;
      // AES Shift rows forward and inverse step
      assign sr = {
        fu_data_i.operand_a[31:24],
        fu_data_i.operand_b[55:48],
        fu_data_i.operand_b[15:8],
        fu_data_i.operand_a[39:32],
        fu_data_i.operand_b[63:56],
        fu_data_i.operand_b[23:16],
        fu_data_i.operand_a[47:40],
        fu_data_i.operand_a[7:0]
      };
      assign sr_inv = {
        fu_data_i.operand_b[31:24],
        fu_data_i.operand_b[55:48],
        fu_data_i.operand_a[15:8],
        fu_data_i.operand_a[39:32],
        fu_data_i.operand_a[63:56],
        fu_data_i.operand_b[23:16],
        fu_data_i.operand_b[47:40],
        fu_data_i.operand_a[7:0]
      };
      // AES 64-bit final round encryption by applying forward shift-rows and the forward sbox to each byte
      assign aes64es_gen = {
        aes_sbox_fwd(sr[63:56]),
        aes_sbox_fwd(sr[55:48]),
        aes_sbox_fwd(sr[47:40]),
        aes_sbox_fwd(sr[39:32]),
        aes_sbox_fwd(sr[31:24]),
        aes_sbox_fwd(sr[23:16]),
        aes_sbox_fwd(sr[15:8]),
        aes_sbox_fwd(sr[7:0])
      };
      // AES 64-bit final round decryption by applying inverse shift-rows and the inverse sbox to each byte
      assign aes64ds_gen = {
        aes_sbox_inv(sr_inv[63:56]),
        aes_sbox_inv(sr_inv[55:48]),
        aes_sbox_inv(sr_inv[47:40]),
        aes_sbox_inv(sr_inv[39:32]),
        aes_sbox_inv(sr_inv[31:24]),
        aes_sbox_inv(sr_inv[23:16]),
        aes_sbox_inv(sr_inv[15:8]),
        aes_sbox_inv(sr_inv[7:0])
      };
      // AES Key Schedule subword input: rotate of rs1[63:32] unless the
      // round constant is 0xA (exactly the original select).
      assign aes_subw_in = (orig_instr_aes[3:0] == 4'hA) ? fu_data_i.operand_a[63:32]
                                                       : ((fu_data_i.operand_a[63:32] >> 8) | (fu_data_i.operand_a[63:32] << 24));
      assign sha512sig0h_gen = '0;
      assign sha512sig0l_gen = '0;
      assign sha512sig1h_gen = '0;
      assign sha512sig1l_gen = '0;
      assign sha512sum0r_gen = '0;
      assign sha512sum1r_gen = '0;
      // SHA512 64bit rotating, shifting and XORing rs1
      assign sha512sig0_gen = (fu_data_i.operand_a >> 1 | fu_data_i.operand_a << 63) ^ (fu_data_i.operand_a >> 8 | fu_data_i.operand_a << 56) ^ (fu_data_i.operand_a >> 7);
      assign sha512sig1_gen = (fu_data_i.operand_a >> 19 | fu_data_i.operand_a << 45) ^ (fu_data_i.operand_a >> 61 | fu_data_i.operand_a << 3) ^ (fu_data_i.operand_a >> 6);
      assign sha512sum0_gen = (fu_data_i.operand_a >> 28 | fu_data_i.operand_a << 36) ^ (fu_data_i.operand_a >> 34 | fu_data_i.operand_a << 30) ^ (fu_data_i.operand_a >> 39 | fu_data_i.operand_a << 25);
      assign sha512sum1_gen = (fu_data_i.operand_a >> 14 | fu_data_i.operand_a << 50) ^ (fu_data_i.operand_a >> 18 | fu_data_i.operand_a << 46) ^ (fu_data_i.operand_a >> 41 | fu_data_i.operand_a << 23);
    end
  end else begin : aes_no_gen
    assign sr = '0;
    assign sr_inv = '0;
    assign sbox_in = '0;
    assign aes64es_gen = '0;
    assign aes64ds_gen = '0;
    assign aes_subw_in = '0;
    assign sha256sig0_gen = '0;
    assign sha256sig1_gen = '0;
    assign sha256sum0_gen = '0;
    assign sha256sum1_gen = '0;
    assign sha512sig0h_gen = '0;
    assign sha512sig0l_gen = '0;
    assign sha512sig1h_gen = '0;
    assign sha512sig1l_gen = '0;
    assign sha512sum0r_gen = '0;
    assign sha512sum1r_gen = '0;
    assign sha512sig0_gen = '0;
    assign sha512sig1_gen = '0;
    assign sha512sum0_gen = '0;
    assign sha512sum1_gen = '0;
  end

  assign aes_subw_gen = aes_subword_fwd(aes_subw_in);

  always_ff @(posedge clk_i or negedge rst_ni) begin : aes_s1_regs
    if (!rst_ni) begin
      a_q          <= '0;
      b_q          <= '0;
      op_q         <= ADD;
      orig_q       <= '0;
      sbox_fwd_q   <= '0;
      sbox_inv_q   <= '0;
      aes64es_q    <= '0;
      aes64ds_q    <= '0;
      aes_subw_q   <= '0;
      sha256sig0_q <= '0;
      sha256sig1_q <= '0;
      sha256sum0_q <= '0;
      sha256sum1_q <= '0;
      sh512sig0h_q <= '0;
      sh512sig0l_q <= '0;
      sh512sig1h_q <= '0;
      sh512sig1l_q <= '0;
      sh512sum0r_q <= '0;
      sh512sum1r_q <= '0;
      sha512sig0_q <= '0;
      sha512sig1_q <= '0;
      sha512sum0_q <= '0;
      sha512sum1_q <= '0;
    end else begin
      a_q          <= fu_data_i.operand_a;
      b_q          <= fu_data_i.operand_b;
      op_q         <= fu_data_i.operation;
      orig_q       <= orig_instr_aes;
      sbox_fwd_q   <= aes_sbox_fwd(sbox_in);
      sbox_inv_q   <= aes_sbox_inv(sbox_in);
      aes64es_q    <= aes64es_gen;
      aes64ds_q    <= aes64ds_gen;
      aes_subw_q   <= aes_subw_gen;
      sha256sig0_q <= sha256sig0_gen;
      sha256sig1_q <= sha256sig1_gen;
      sha256sum0_q <= sha256sum0_gen;
      sha256sum1_q <= sha256sum1_gen;
      sh512sig0h_q <= sha512sig0h_gen;
      sh512sig0l_q <= sha512sig0l_gen;
      sh512sig1h_q <= sha512sig1h_gen;
      sh512sig1l_q <= sha512sig1l_gen;
      sh512sum0r_q <= sha512sum0r_gen;
      sh512sum1r_q <= sha512sum1r_gen;
      sha512sig0_q <= sha512sig0_gen;
      sha512sig1_q <= sha512sig1_gen;
      sha512sum0_q <= sha512sum0_gen;
      sha512sum1_q <= sha512sum1_gen;
    end
  end

  // ---------------------------------------------------------
  // Stage 2 (combinational): MixColumns, merges, class select.
  // ---------------------------------------------------------
  logic [31:0] aes32esi_gen;
  logic [31:0] aes32esmi_gen;
  logic [31:0] aes32dsi_gen;
  logic [31:0] aes32dsmi_gen;
  logic [63:0] aes64esm_gen;
  logic [63:0] aes64dsm_gen;
  logic [63:0] aes64im_gen;
  logic [63:0] aes64ks1i_gen;
  logic [63:0] aes64ks2_gen;

  // AES 32-bit final round: rotate the registered sbox output by the
  // instruction byte index and XOR with rs1 (exactly the original).
  logic [31:0] sbox_fwd_rot, sbox_inv_rot, mix_fwd_rot, mix_inv_rot;
  assign sbox_fwd_rot = ({24'b0, sbox_fwd_q} << {orig_q[5:4], 3'b000}) |
                        ({24'b0, sbox_fwd_q} >> (32 - {orig_q[5:4], 3'b000}));
  assign sbox_inv_rot = ({24'b0, sbox_inv_q} << {orig_q[5:4], 3'b000}) |
                        ({24'b0, sbox_inv_q} >> (32 - {orig_q[5:4], 3'b000}));
  assign mix_fwd_rot  = (aes_mixcolumn_fwd({24'h000000, sbox_fwd_q}) << {orig_q[5:4], 3'b000}) |
                        (aes_mixcolumn_fwd({24'h000000, sbox_fwd_q}) >> (32 - {orig_q[5:4], 3'b000}));
  assign mix_inv_rot  = (aes_mixcolumn_inv({24'h000000, sbox_inv_q}) << {orig_q[5:4], 3'b000}) |
                        (aes_mixcolumn_inv({24'h000000, sbox_inv_q}) >> (32 - {orig_q[5:4], 3'b000}));

  assign aes32esi_gen  = a_q ^ sbox_fwd_rot;
  assign aes32esmi_gen = a_q ^ mix_fwd_rot;
  assign aes32dsi_gen  = a_q ^ sbox_inv_rot;
  assign aes32dsmi_gen = a_q ^ mix_inv_rot;

  // 64-bit middle rounds: MixColumns over the registered sbox outputs.
  assign aes64esm_gen = {aes_mixcolumn_fwd(aes64es_q[63:32]), aes_mixcolumn_fwd(aes64es_q[31:0])};
  assign aes64dsm_gen = {aes_mixcolumn_inv(aes64ds_q[63:32]), aes_mixcolumn_inv(aes64ds_q[31:0])};
  // inverse MixColumns over rs1 (key-schedule decrypt step)
  assign aes64im_gen  = {aes_mixcolumn_inv(a_q[63:32]), aes_mixcolumn_inv(a_q[31:0])};
  // ks1i: the registered subword result XORed with the decoded round
  // constant, gated by the round field exactly as the original.
  assign aes64ks1i_gen = (orig_q[3:0] <= 4'hA) ? {(aes_subw_q ^ aes_decode_rcon(orig_q[3:0])),
                                                  (aes_subw_q ^ aes_decode_rcon(orig_q[3:0]))}
                                               : 64'h0;
  assign aes64ks2_gen  = {(a_q[63:32] ^ b_q[31:0] ^ b_q[63:32]),
                          (a_q[63:32] ^ b_q[31:0])};

  // -----------
  // Result MUX
  // -----------
  always_comb begin
    result_o = '0;
    // AES instructions
    if (G6LCCfg.ZKN && G6LCCfg.RVB) begin
      if (G6LCCfg.IS_XLEN32) begin
        unique case (op_q)
          AES32ESI: result_o = G6LCCfg.XLEN'(aes32esi_gen);
          AES32ESMI: result_o = G6LCCfg.XLEN'(aes32esmi_gen);
          AES32DSI: result_o = G6LCCfg.XLEN'(aes32dsi_gen);
          AES32DSMI: result_o = G6LCCfg.XLEN'(aes32dsmi_gen);
          SHA256SIG0: result_o = G6LCCfg.XLEN'(sha256sig0_q);
          SHA256SIG1: result_o = G6LCCfg.XLEN'(sha256sig1_q);
          SHA256SUM0: result_o = G6LCCfg.XLEN'(sha256sum0_q);
          SHA256SUM1: result_o = G6LCCfg.XLEN'(sha256sum1_q);
          SHA512SIG0H: result_o = G6LCCfg.XLEN'(sh512sig0h_q);
          SHA512SIG0L: result_o = G6LCCfg.XLEN'(sh512sig0l_q);
          SHA512SIG1H: result_o = G6LCCfg.XLEN'(sh512sig1h_q);
          SHA512SIG1L: result_o = G6LCCfg.XLEN'(sh512sig1l_q);
          SHA512SUM0R: result_o = G6LCCfg.XLEN'(sh512sum0r_q);
          SHA512SUM1R: result_o = G6LCCfg.XLEN'(sh512sum1r_q);
          default: ;
        endcase
      end
      if (G6LCCfg.IS_XLEN64) begin
        unique case (op_q)
          AES64ES: result_o = aes64es_q;
          AES64ESM: result_o = aes64esm_gen;
          AES64DS: result_o = aes64ds_q;
          AES64DSM: result_o = aes64dsm_gen;
          AES64IM: result_o = aes64im_gen;
          AES64KS1I: result_o = aes64ks1i_gen;
          AES64KS2: result_o = aes64ks2_gen;
          SHA256SIG0: result_o = {{32{sha256sig0_q[31]}}, sha256sig0_q};
          SHA256SIG1: result_o = {{32{sha256sig1_q[31]}}, sha256sig1_q};
          SHA256SUM0: result_o = {{32{sha256sum0_q[31]}}, sha256sum0_q};
          SHA256SUM1: result_o = {{32{sha256sum1_q[31]}}, sha256sum1_q};
          SHA512SIG0: result_o = sha512sig0_q;
          SHA512SIG1: result_o = sha512sig1_q;
          SHA512SUM0: result_o = sha512sum0_q;
          SHA512SUM1: result_o = sha512sum1_q;
          default: ;
        endcase
      end
    end
  end

endmodule
