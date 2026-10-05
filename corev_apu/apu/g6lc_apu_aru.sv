// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// One GenHandle table: vkAllocateCommandBuffers ALLOCs CMDBUF,
// vkCreateShaderModule commits SPIR-V under MODULE, vkCmdDispatch
// looks up that CMDBUF and kicks SpirvSubset. Dispatch before create
// or allocate, MODULE-as-cmdbuf, and vkCreateInstance fault. Enable=0
// elaborates no datapath. Not wired into g6lc_apu_sys. FeatureVirgl
// stays illegal.

// AllocRun (aru): ALLOC CMDBUF, CREATE MODULE, then DISPATCH SpirvSubset on one table. Default-off. FeatureVirgl stays illegal.
// Interplay: AllocRun (aru) --> VenusEncode (vnenc) --> GenHandle (gnh) --> VenusDispatch (vnd) --> SpirvSubset (spirv) --? HandleAlloc (hal) --? ApuSys. See AGENTS-impl-interplays.md.
module g6lc_apu_aru
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_aru_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_aru_cpl_t cpl_o,
  output apu_aru_t aru_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  if (!Enable) begin : gen_off
    assign cs_rdata_o = '0;
    assign req_ready_o = 1'b0;
    assign cpl_valid_o = 1'b0;
    assign cpl_o = '0;
    assign aru_o = '0;
    assign irq_o = 1'b0;
    assign result_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | cs_we_i | req_valid_i | cpl_ready_i |
                    (|cs_idx_i) | (|cs_wdata_i) | (|req_i) | (|in_a_i) |
                    (|in_b_i);
  end else begin : gen_on
    typedef enum logic [3:0] {
      Idle, FireEnc, WaitEnc, FireVnd, WaitVnd, FireGnh, WaitGnh,
      Load, Commit, Kick, WaitEx, Done
    } state_e;
    state_e state_q;
    logic [31:0] cs_q [APU_VAC_WORDS];
    apu_aru_cpl_t cpl_q;
    apu_aru_t rec_q;
    logic alloc_q, create_q, disp_q, look_q, loaded_q;
    logic [7:0] load_q, n_q, enc_idx;
    logic [31:0] in_a_q, in_b_q, result_q, enc_rdata, vnd_rdata;
    logic [31:0] cmd, flags, stype, level, count;
    logic [63:0] pinfo, pnext, pool, asz, guest;
    logic decode_ok, want_reply;
    logic enc_req, enc_rdy, enc_cpl, enc_ack, enc_we;
    logic vnd_req, vnd_rdy, vnd_cpl, vnd_ack, vnd_we;
    logic gnh_req_v, gnh_rdy, gnh_cpl, gnh_ack;
    logic [3:0] vnd_idx;
    logic spv_we, spv_commit, spv_start, spv_idle, spv_busy, spv_done;
    logic spv_fault, spv_irq;
    logic [6:0] spv_idx;
    logic [31:0] spv_wdata, spv_res;
    logic [7:0] spv_len;
    apu_gnh_req_t gnh_req_q;
    apu_vnenc_cpl_t enc_c;
    apu_vnenc_t enc_rec;
    apu_vnd_cpl_t vnd_c;
    apu_vnd_t vnd_rec;
    apu_gnh_cpl_t gnh_c;
    apu_gnh_t gnh_rec;

    assign req_ready_o = state_q == Idle && rst_ni;
    assign cpl_valid_o = state_q == Done;
    assign cpl_o = cpl_valid_o ? cpl_q : apu_aru_cpl_t'('0);
    assign aru_o = rec_q;
    assign irq_o = state_q == Done && rec_q.valid && rec_q.dispatch;
    assign result_o = result_q;
    assign cs_rdata_o = (cs_idx_i < 8'(APU_VAC_WORDS)) ? cs_q[cs_idx_i[4:0]]
                                                       : enc_rdata;
    assign enc_we = cs_we_i && (state_q == Idle);
    assign enc_idx = (state_q == Load) ? (8'(APU_VNENC_CODE0) + load_q) : cs_idx_i;
    assign vnd_we = enc_we && (cs_idx_i[7:4] == 4'd0);
    assign vnd_idx = cs_idx_i[3:0];
    assign enc_req = state_q == FireEnc;
    assign enc_ack = state_q == WaitEnc;
    assign vnd_req = state_q == FireVnd;
    assign vnd_ack = state_q == WaitVnd;
    assign gnh_req_v = state_q == FireGnh;
    assign gnh_ack = state_q == WaitGnh;
    assign spv_we = state_q == Load;
    assign spv_idx = load_q[6:0];
    assign spv_wdata = enc_rdata;
    assign spv_len = n_q;
    assign spv_commit = state_q == Commit;
    assign spv_start = state_q == Kick;
    assign cmd = cs_q[0];
    assign flags = cs_q[1];
    assign pinfo = {cs_q[5], cs_q[4]};
    assign stype = cs_q[6];
    assign pnext = {cs_q[8], cs_q[7]};
    assign pool = {cs_q[10], cs_q[9]};
    assign level = cs_q[11];
    assign count = cs_q[12];
    assign asz = {cs_q[14], cs_q[13]};
    assign guest = {cs_q[16], cs_q[15]};
    assign want_reply = flags == APU_VAC_GENERATE_REPLY;
    assign decode_ok = (cmd == APU_VAC_CMD_ALLOC) &&
                       ((flags == 32'd0) || (flags == APU_VAC_GENERATE_REPLY)) &&
                       (pinfo != 64'd0) &&
                       (stype == APU_VAC_STYPE_ALLOC) &&
                       (pnext == 64'd0) &&
                       (pool != 64'd0) &&
                       (level == APU_VAC_LEVEL_PRIMARY) &&
                       (count == 32'd1) &&
                       (asz == 64'd1) &&
                       (guest[63:32] == 32'd0) &&
                       (guest[31:0] != 32'd0);

    g6lc_apu_vnenc #(.Enable(1'b1)) i_enc (
      .clk_i, .rst_ni, .cs_we_i(enc_we), .cs_idx_i(enc_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(enc_rdata),
      .req_valid_i(enc_req), .req_ready_o(enc_rdy),
      .cpl_valid_o(enc_cpl), .cpl_ready_i(enc_ack), .cpl_o(enc_c),
      .vnenc_o(enc_rec)
    );
    g6lc_apu_vnd #(.Enable(1'b1)) i_vnd (
      .clk_i, .rst_ni, .cs_we_i(vnd_we), .cs_idx_i(vnd_idx),
      .cs_wdata_i(cs_wdata_i), .cs_rdata_o(vnd_rdata),
      .req_valid_i(vnd_req), .req_ready_o(vnd_rdy),
      .cpl_valid_o(vnd_cpl), .cpl_ready_i(vnd_ack), .cpl_o(vnd_c),
      .vnd_o(vnd_rec)
    );
    g6lc_apu_gnh #(.Enable(1'b1)) i_gnh (
      .clk_i, .rst_ni,
      .req_valid_i(gnh_req_v), .req_ready_o(gnh_rdy), .req_i(gnh_req_q),
      .cpl_valid_o(gnh_cpl), .cpl_ready_i(gnh_ack), .cpl_o(gnh_c), .gnh_o(gnh_rec)
    );
    g6lc_apu_spirv #(.Enable(1'b1)) i_spv (
      .clk_i, .rst_ni, .prog_we_i(spv_we), .prog_idx_i(spv_idx),
      .prog_wdata_i(spv_wdata), .prog_len_i(spv_len), .commit_i(spv_commit),
      .start_i(spv_start), .in_a_i(in_a_q), .in_b_i(in_b_q),
      .idle_o(spv_idle), .busy_o(spv_busy), .done_o(spv_done),
      .fault_o(spv_fault), .irq_o(spv_irq), .result_o(spv_res)
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= Idle;
        cs_q <= '{default: '0};
        cpl_q <= '0;
        rec_q <= '0;
        alloc_q <= 1'b0;
        create_q <= 1'b0;
        disp_q <= 1'b0;
        look_q <= 1'b0;
        loaded_q <= 1'b0;
        load_q <= '0;
        n_q <= '0;
        in_a_q <= '0;
        in_b_q <= '0;
        result_q <= '0;
        gnh_req_q <= '0;
      end else unique case (state_q)
        Idle: begin
          if (cs_we_i && (cs_idx_i < 8'(APU_VAC_WORDS)))
            cs_q[cs_idx_i[4:0]] <= cs_wdata_i;
          else if (req_valid_i && req_ready_o) begin
            rec_q <= '0;
            alloc_q <= req_i.op == APU_ARU_ALLOC;
            create_q <= req_i.op == APU_ARU_CREATE;
            disp_q <= req_i.op == APU_ARU_DISPATCH;
            look_q <= 1'b0;
            in_a_q <= in_a_i;
            in_b_q <= in_b_i;
            unique case (req_i.op)
              APU_ARU_GNH: begin
                gnh_req_q <= req_i.gnh;
                state_q <= FireGnh;
              end
              APU_ARU_CREATE: state_q <= FireEnc;
              APU_ARU_DISPATCH: begin
                if (!loaded_q) begin
                  cpl_q <= '{status: APU_ARU_FAULT};
                  state_q <= Done;
                end else state_q <= FireVnd;
              end
              APU_ARU_ALLOC: begin
                if (!decode_ok) begin
                  cpl_q <= '{status: APU_ARU_FAULT};
                  state_q <= Done;
                end else begin
                  rec_q <= '{
                    valid:      1'b0,
                    alloc:      1'b1,
                    create:     1'b0,
                    dispatch:   1'b0,
                    loaded:     loaded_q,
                    reply:      want_reply,
                    slot:       '0,
                    gen:        '0,
                    kind:       APU_GNH_CMDBUF,
                    object_id:  guest[31:0],
                    handle:     '0,
                    code_words: '0,
                    group_x:    '0,
                    group_y:    '0,
                    group_z:    '0,
                    result:     '0
                  };
                  gnh_req_q <= '{
                    op: APU_GNH_ALLOC,
                    kind: APU_GNH_CMDBUF,
                    object_id: guest[31:0],
                    handle: '0
                  };
                  state_q <= FireGnh;
                end
              end
              default: begin
                cpl_q <= '{status: APU_ARU_FAULT};
                state_q <= Done;
              end
            endcase
          end
        end
        FireEnc: if (enc_rdy) state_q <= WaitEnc;
        WaitEnc: if (enc_cpl) begin
          if (enc_c.status != APU_VNENC_OK || !enc_rec.valid ||
              enc_rec.first_word != APU_SPIRV_MAGIC ||
              enc_rec.module_id[63:32] != 32'd0 ||
              enc_rec.module_id[31:0] == 32'd0 ||
              enc_rec.code_words == 32'd0 ||
              enc_rec.code_words > 32'(APU_VNENC_MAX_WORDS)) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_ARU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:      1'b0,
              alloc:      1'b0,
              create:     1'b1,
              dispatch:   1'b0,
              loaded:     1'b0,
              reply:      1'b0,
              slot:       '0,
              gen:        '0,
              kind:       APU_GNH_MODULE,
              object_id:  enc_rec.module_id[31:0],
              handle:     '0,
              code_words: enc_rec.code_words,
              group_x:    '0,
              group_y:    '0,
              group_z:    '0,
              result:     '0
            };
            n_q <= enc_rec.code_words[7:0];
            load_q <= '0;
            gnh_req_q <= '{
              op: APU_GNH_ALLOC,
              kind: APU_GNH_MODULE,
              object_id: enc_rec.module_id[31:0],
              handle: '0
            };
            state_q <= FireGnh;
          end
        end
        FireVnd: if (vnd_rdy) state_q <= WaitVnd;
        WaitVnd: if (vnd_cpl) begin
          if (vnd_c.status != APU_VND_OK || !vnd_rec.valid ||
              vnd_rec.command_buffer[63:32] != 32'd0) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_ARU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:      1'b0,
              alloc:      1'b0,
              create:     1'b0,
              dispatch:   1'b1,
              loaded:     loaded_q,
              reply:      1'b0,
              slot:       '0,
              gen:        '0,
              kind:       APU_GNH_CMDBUF,
              object_id:  '0,
              handle:     vnd_rec.command_buffer[31:0],
              code_words: rec_q.code_words,
              group_x:    vnd_rec.group_x,
              group_y:    vnd_rec.group_y,
              group_z:    vnd_rec.group_z,
              result:     '0
            };
            gnh_req_q <= '{
              op: APU_GNH_LOOKUP,
              kind: APU_GNH_CMDBUF,
              object_id: '0,
              handle: vnd_rec.command_buffer[31:0]
            };
            look_q <= 1'b1;
            state_q <= FireGnh;
          end
        end
        FireGnh: if (gnh_rdy) state_q <= WaitGnh;
        WaitGnh: if (gnh_cpl) begin
          if (gnh_c.status != APU_GNH_OK ||
              (look_q && gnh_rec.kind != APU_GNH_CMDBUF)) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_ARU_FAULT};
            state_q <= Done;
          end else begin
            rec_q <= '{
              valid:      gnh_rec.valid,
              alloc:      alloc_q,
              create:     create_q,
              dispatch:   disp_q,
              loaded:     loaded_q,
              reply:      rec_q.reply,
              slot:       gnh_rec.slot,
              gen:        gnh_rec.gen,
              kind:       gnh_rec.kind,
              object_id:  gnh_rec.object_id,
              handle:     gnh_rec.handle,
              code_words: rec_q.code_words,
              group_x:    rec_q.group_x,
              group_y:    rec_q.group_y,
              group_z:    rec_q.group_z,
              result:     rec_q.result
            };
            if (alloc_q && rec_q.reply) begin
              cs_q[5'(APU_VAC_REPLY)] <= APU_VAC_CMD_ALLOC;
              cs_q[5'(APU_VAC_REPLY) + 5'd1] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd2] <= 32'd1;
              cs_q[5'(APU_VAC_REPLY) + 5'd3] <= 32'd0;
              cs_q[5'(APU_VAC_REPLY) + 5'd4] <= gnh_rec.handle;
              cs_q[5'(APU_VAC_REPLY) + 5'd5] <= 32'd0;
            end
            if (disp_q) state_q <= Kick;
            else if (create_q) state_q <= Load;
            else begin
              cpl_q <= '{status: APU_ARU_OK};
              state_q <= Done;
            end
          end
        end
        Load: begin
          if (load_q + 8'd1 == n_q) state_q <= Commit;
          else load_q <= load_q + 8'd1;
        end
        Commit: begin
          loaded_q <= 1'b1;
          rec_q <= '{
            valid:      rec_q.valid,
            alloc:      1'b0,
            create:     1'b1,
            dispatch:   1'b0,
            loaded:     1'b1,
            reply:      1'b0,
            slot:       rec_q.slot,
            gen:        rec_q.gen,
            kind:       rec_q.kind,
            object_id:  rec_q.object_id,
            handle:     rec_q.handle,
            code_words: rec_q.code_words,
            group_x:    rec_q.group_x,
            group_y:    rec_q.group_y,
            group_z:    rec_q.group_z,
            result:     rec_q.result
          };
          cpl_q <= '{status: APU_ARU_OK};
          state_q <= Done;
        end
        Kick: state_q <= WaitEx;
        WaitEx: begin
          if (spv_fault) begin
            rec_q <= '0;
            cpl_q <= '{status: APU_ARU_FAULT};
            state_q <= Done;
          end else if (spv_irq) begin
            result_q <= spv_res;
            rec_q <= '{
              valid:      rec_q.valid,
              alloc:      1'b0,
              create:     1'b0,
              dispatch:   1'b1,
              loaded:     1'b1,
              reply:      1'b0,
              slot:       rec_q.slot,
              gen:        rec_q.gen,
              kind:       rec_q.kind,
              object_id:  rec_q.object_id,
              handle:     rec_q.handle,
              code_words: rec_q.code_words,
              group_x:    rec_q.group_x,
              group_y:    rec_q.group_y,
              group_z:    rec_q.group_z,
              result:     spv_res
            };
            cpl_q <= '{status: APU_ARU_OK};
            state_q <= Done;
          end
        end
        Done: if (cpl_ready_i) state_q <= Idle;
        default: state_q <= Idle;
      endcase
    end

    `ifndef SYNTHESIS
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o && !cpl_ready_i |=> cpl_valid_o && $stable(cpl_o));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      cpl_valid_o |-> !req_ready_o);
    `endif
  end
endmodule

// AllocRun (aru) enable-0 fixture: ALLOC CMDBUF, CREATE MODULE, DISPATCH SpirvSubset.
module g6lc_apu_aru_fixture
  import g6lc_apu_pkg::*;
#(
  parameter bit Enable = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic cs_we_i,
  input  logic [7:0] cs_idx_i,
  input  logic [31:0] cs_wdata_i,
  output logic [31:0] cs_rdata_o,
  input  logic req_valid_i,
  output logic req_ready_o,
  input  apu_aru_req_t req_i,
  input  logic [31:0] in_a_i,
  input  logic [31:0] in_b_i,
  output logic cpl_valid_o,
  input  logic cpl_ready_i,
  output apu_aru_cpl_t cpl_o,
  output apu_aru_t aru_o,
  output logic irq_o,
  output logic [31:0] result_o
);
  g6lc_apu_aru #(.Enable(Enable)) i_dut (.*);
endmodule
