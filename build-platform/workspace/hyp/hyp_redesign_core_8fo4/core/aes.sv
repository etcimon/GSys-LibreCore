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
    parameter type fu_data_t = logic,
    // r127 AesStages: 0/1 = current 2-stage (stage-1 regs + comb stage-2 ->
    // result_o). 3 = insert a stage-2 register capturing every result-mux
    // candidate, then a shallow stage-3 opcode mux -> result_o. This is a
    // LATENCY contract change: result_o lands one cycle later, so it must only
    // be enabled together with the matching ex_stage AES-lane delay (the
    // aes_vld_q/aes_tid_q capture window) and the g6lc_hyp_pkg AesStages field.
    // Default 0 is bit- and cycle-identical to the pre-change module.
    parameter bit AesPipe3 = 1'b0
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

  // r127 AesPipe3 stage-2 registers: capture every signal the result mux can
  // select so the stage-3 opcode mux is shallow. Each _s2 mirrors its stage-1
  // (_q passthrough) or stage-2-comb (_gen) source one edge later; under
  // AesPipe3=0 the result mux ignores them and they are synthesized away.
  logic [31:0]           aes32esi_s2, aes32esmi_s2, aes32dsi_s2, aes32dsmi_s2;
  logic [63:0]           aes64es_s2, aes64esm_s2, aes64ds_s2, aes64dsm_s2;
  logic [63:0]           aes64im_s2, aes64ks1i_s2, aes64ks2_s2;
  logic [31:0]           sha256sig0_s2, sha256sig1_s2, sha256sum0_s2, sha256sum1_s2;
  logic [31:0]           sh512sig0h_s2, sh512sig0l_s2, sh512sig1h_s2, sh512sig1l_s2;
  logic [31:0]           sh512sum0r_s2, sh512sum1r_s2;
  logic [63:0]           sha512sig0_s2, sha512sig1_s2, sha512sum0_s2, sha512sum1_s2;
  // The result mux selects on the operation; under AesPipe3 the select must be
  // the stage-2-delayed op or it would read the NEXT issue's opcode.
  fu_op                  op_s2;

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
      // r127: per byte lane, each with its own copy of the round test (one
      // compare no longer drives the 32-bit select in front of the S-boxes).
      // The rotate is ror32 by 8: result byte b = source byte (b + 1) % 4.
      for (genvar bl = 0; bl < 4; bl++) begin : gen_subw_lane
        logic no_rot;
        assign no_rot = (orig_instr_aes[3:0] == 4'hA);
        assign aes_subw_in[8*bl +: 8] = no_rot ? fu_data_i.operand_a[32 + 8*bl +: 8]
                                               : fu_data_i.operand_a[32 + 8*((bl + 1) % 4) +: 8];
      end
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
  // r42-T item 23 classify (A18): the 44.9-FO4 reg->out cone
  // (sbox_*_q/orig_q -> rotate+mixcolumn -> XOR -> result) is a
  // presentation path on a serialized multi-cycle operation — the AES
  // op already occupies the FU for several cycles, so this cone is
  // classified multi-cycle, not a single-cycle rank-0 kernel.
  // svt-pipe: multi-cycle on=aes op occupancy
  logic [31:0] sbox_fwd_rot, sbox_inv_rot, mix_fwd_rot, mix_inv_rot;
  // r127: the rotate amount is 8 * orig_q[5:4], so each rotate is a 4-way
  // select of byte-rotated copies (it was a variable left shift ORed with a
  // variable right shift by 32 - amount), and each MixColumns is formed
  // once instead of once per shift. Same values (rol32 by 0/8/16/24);
  // checked against the shift form by verif/tb/core/tb_g6lc_hyp8_aes_eq.sv.
  function automatic logic [31:0] aes_rol8x(input logic [31:0] x, input logic [1:0] bs);
    unique case (bs)
      2'd0:    return x;
      2'd1:    return {x[23:0], x[31:24]};
      2'd2:    return {x[15:0], x[31:16]};
      default: return {x[7:0],  x[31:8]};
    endcase
  endfunction
  logic [31:0] mix_fwd_w, mix_inv_w;
  assign mix_fwd_w    = aes_mixcolumn_fwd({24'h000000, sbox_fwd_q});
  assign mix_inv_w    = aes_mixcolumn_inv({24'h000000, sbox_inv_q});
  assign sbox_fwd_rot = aes_rol8x({24'b0, sbox_fwd_q}, orig_q[5:4]);
  assign sbox_inv_rot = aes_rol8x({24'b0, sbox_inv_q}, orig_q[5:4]);
  assign mix_fwd_rot  = aes_rol8x(mix_fwd_w, orig_q[5:4]);
  assign mix_inv_rot  = aes_rol8x(mix_inv_w, orig_q[5:4]);

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

  // ---------------------------------------------------------
  // r127 AesPipe3 stage-2 (registered): capture every result-mux candidate
  // one edge after stage-1, so the stage-3 opcode mux below is shallow. Under
  // AesPipe3=0 these flops are dead (mux selects the comb/_q sources) and are
  // removed by synthesis; the module is then bit- and cycle-identical.
  // ---------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : aes_s2_regs
    if (!rst_ni) begin
      aes32esi_s2    <= '0;
      aes32esmi_s2   <= '0;
      aes32dsi_s2    <= '0;
      aes32dsmi_s2   <= '0;
      aes64es_s2     <= '0;
      aes64esm_s2    <= '0;
      aes64ds_s2     <= '0;
      aes64dsm_s2    <= '0;
      aes64im_s2     <= '0;
      aes64ks1i_s2   <= '0;
      aes64ks2_s2    <= '0;
      sha256sig0_s2  <= '0;
      sha256sig1_s2  <= '0;
      sha256sum0_s2  <= '0;
      sha256sum1_s2  <= '0;
      sh512sig0h_s2  <= '0;
      sh512sig0l_s2  <= '0;
      sh512sig1h_s2  <= '0;
      sh512sig1l_s2  <= '0;
      sh512sum0r_s2  <= '0;
      sh512sum1r_s2  <= '0;
      sha512sig0_s2  <= '0;
      sha512sig1_s2  <= '0;
      sha512sum0_s2  <= '0;
      sha512sum1_s2  <= '0;
      op_s2          <= ADD;
    end else begin
      op_s2          <= op_q;
      aes32esi_s2    <= aes32esi_gen;
      aes32esmi_s2   <= aes32esmi_gen;
      aes32dsi_s2    <= aes32dsi_gen;
      aes32dsmi_s2   <= aes32dsmi_gen;
      aes64es_s2     <= aes64es_q;
      aes64esm_s2    <= aes64esm_gen;
      aes64ds_s2     <= aes64ds_q;
      aes64dsm_s2    <= aes64dsm_gen;
      aes64im_s2     <= aes64im_gen;
      aes64ks1i_s2   <= aes64ks1i_gen;
      aes64ks2_s2    <= aes64ks2_gen;
      sha256sig0_s2  <= sha256sig0_q;
      sha256sig1_s2  <= sha256sig1_q;
      sha256sum0_s2  <= sha256sum0_q;
      sha256sum1_s2  <= sha256sum1_q;
      sh512sig0h_s2  <= sh512sig0h_q;
      sh512sig0l_s2  <= sh512sig0l_q;
      sh512sig1h_s2  <= sh512sig1h_q;
      sh512sig1l_s2  <= sh512sig1l_q;
      sh512sum0r_s2  <= sh512sum0r_q;
      sh512sum1r_s2  <= sh512sum1r_q;
      sha512sig0_s2  <= sha512sig0_q;
      sha512sig1_s2  <= sha512sig1_q;
      sha512sum0_s2  <= sha512sum0_q;
      sha512sum1_s2  <= sha512sum1_q;
    end
  end

  // ---------------------------------------------------------
  // Result MUX (stage-3 when AesPipe3, else stage-2 combinational)
  // ---------------------------------------------------------
  // r127 AesPipe3 stage-3 select: each candidate resolves to its registered
  // stage-2 value when enabled, else the original stage-1/comb source, so the
  // default (AesPipe3=0) mux is bit-identical. op_mux likewise delays the
  // opcode select by one stage.
  logic [31:0] m_aes32esi, m_aes32esmi, m_aes32dsi, m_aes32dsmi;
  logic [63:0] m_aes64es, m_aes64esm, m_aes64ds, m_aes64dsm;
  logic [63:0] m_aes64im, m_aes64ks1i, m_aes64ks2;
  logic [31:0] m_sha256sig0, m_sha256sig1, m_sha256sum0, m_sha256sum1;
  logic [31:0] m_sh512sig0h, m_sh512sig0l, m_sh512sig1h, m_sh512sig1l;
  logic [31:0] m_sh512sum0r, m_sh512sum1r;
  logic [63:0] m_sha512sig0, m_sha512sig1, m_sha512sum0, m_sha512sum1;
  fu_op        op_mux;

  assign m_aes32esi   = AesPipe3 ? aes32esi_s2   : aes32esi_gen;
  assign m_aes32esmi  = AesPipe3 ? aes32esmi_s2  : aes32esmi_gen;
  assign m_aes32dsi   = AesPipe3 ? aes32dsi_s2   : aes32dsi_gen;
  assign m_aes32dsmi  = AesPipe3 ? aes32dsmi_s2  : aes32dsmi_gen;
  assign m_aes64es    = AesPipe3 ? aes64es_s2    : aes64es_q;
  assign m_aes64esm   = AesPipe3 ? aes64esm_s2   : aes64esm_gen;
  assign m_aes64ds    = AesPipe3 ? aes64ds_s2    : aes64ds_q;
  assign m_aes64dsm   = AesPipe3 ? aes64dsm_s2   : aes64dsm_gen;
  assign m_aes64im    = AesPipe3 ? aes64im_s2    : aes64im_gen;
  assign m_aes64ks1i  = AesPipe3 ? aes64ks1i_s2  : aes64ks1i_gen;
  assign m_aes64ks2   = AesPipe3 ? aes64ks2_s2   : aes64ks2_gen;
  assign m_sha256sig0 = AesPipe3 ? sha256sig0_s2 : sha256sig0_q;
  assign m_sha256sig1 = AesPipe3 ? sha256sig1_s2 : sha256sig1_q;
  assign m_sha256sum0 = AesPipe3 ? sha256sum0_s2 : sha256sum0_q;
  assign m_sha256sum1 = AesPipe3 ? sha256sum1_s2 : sha256sum1_q;
  assign m_sh512sig0h = AesPipe3 ? sh512sig0h_s2 : sh512sig0h_q;
  assign m_sh512sig0l = AesPipe3 ? sh512sig0l_s2 : sh512sig0l_q;
  assign m_sh512sig1h = AesPipe3 ? sh512sig1h_s2 : sh512sig1h_q;
  assign m_sh512sig1l = AesPipe3 ? sh512sig1l_s2 : sh512sig1l_q;
  assign m_sh512sum0r = AesPipe3 ? sh512sum0r_s2 : sh512sum0r_q;
  assign m_sh512sum1r = AesPipe3 ? sh512sum1r_s2 : sh512sum1r_q;
  assign m_sha512sig0 = AesPipe3 ? sha512sig0_s2 : sha512sig0_q;
  assign m_sha512sig1 = AesPipe3 ? sha512sig1_s2 : sha512sig1_q;
  assign m_sha512sum0 = AesPipe3 ? sha512sum0_s2 : sha512sum0_q;
  assign m_sha512sum1 = AesPipe3 ? sha512sum1_s2 : sha512sum1_q;
  assign op_mux        = AesPipe3 ? op_s2 : op_q;

  always_comb begin
    result_o = '0;
    // AES instructions
    if (G6LCCfg.ZKN && G6LCCfg.RVB) begin
      if (G6LCCfg.IS_XLEN32) begin
        unique case (op_mux)
          AES32ESI: result_o = G6LCCfg.XLEN'(m_aes32esi);
          AES32ESMI: result_o = G6LCCfg.XLEN'(m_aes32esmi);
          AES32DSI: result_o = G6LCCfg.XLEN'(m_aes32dsi);
          AES32DSMI: result_o = G6LCCfg.XLEN'(m_aes32dsmi);
          SHA256SIG0: result_o = G6LCCfg.XLEN'(m_sha256sig0);
          SHA256SIG1: result_o = G6LCCfg.XLEN'(m_sha256sig1);
          SHA256SUM0: result_o = G6LCCfg.XLEN'(m_sha256sum0);
          SHA256SUM1: result_o = G6LCCfg.XLEN'(m_sha256sum1);
          SHA512SIG0H: result_o = G6LCCfg.XLEN'(m_sh512sig0h);
          SHA512SIG0L: result_o = G6LCCfg.XLEN'(m_sh512sig0l);
          SHA512SIG1H: result_o = G6LCCfg.XLEN'(m_sh512sig1h);
          SHA512SIG1L: result_o = G6LCCfg.XLEN'(m_sh512sig1l);
          SHA512SUM0R: result_o = G6LCCfg.XLEN'(m_sh512sum0r);
          SHA512SUM1R: result_o = G6LCCfg.XLEN'(m_sh512sum1r);
          default: ;
        endcase
      end
      if (G6LCCfg.IS_XLEN64) begin
        unique case (op_mux)
          AES64ES: result_o = m_aes64es;
          AES64ESM: result_o = m_aes64esm;
          AES64DS: result_o = m_aes64ds;
          AES64DSM: result_o = m_aes64dsm;
          AES64IM: result_o = m_aes64im;
          AES64KS1I: result_o = m_aes64ks1i;
          AES64KS2: result_o = m_aes64ks2;
          SHA256SIG0: result_o = {{32{m_sha256sig0[31]}}, m_sha256sig0};
          SHA256SIG1: result_o = {{32{m_sha256sig1[31]}}, m_sha256sig1};
          SHA256SUM0: result_o = {{32{m_sha256sum0[31]}}, m_sha256sum0};
          SHA256SUM1: result_o = {{32{m_sha256sum1[31]}}, m_sha256sum1};
          SHA512SIG0: result_o = m_sha512sig0;
          SHA512SIG1: result_o = m_sha512sig1;
          SHA512SUM0: result_o = m_sha512sum0;
          SHA512SUM1: result_o = m_sha512sum1;
          default: ;
        endcase
      end
    end
  end

endmodule
