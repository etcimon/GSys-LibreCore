// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_lu_result — the load unit's L4 result formation (r81 caller-purpose
// segment): byte realign of the published word by its offset, big-endian
// byte reversal (mbe), sign/zero extension per load operation. Extracted
// verbatim from load_unit.sv so the cone is measured as its own module and
// so a registered publish record (LoadPubStages==2) can feed it from a
// register without touching load_unit's L5 select. Pure combinational.

module g6lc_lu_result
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    input  logic [G6LCCfg.XLEN-1:0]              load_rdata,
    input  logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0]  load_addr_offset,
    input  fu_op                                 load_operation,
    input  logic                                 mbe_i,
    output logic [G6LCCfg.XLEN-1:0]              result_o
);
  logic [G6LCCfg.XLEN-1:0] shifted_data;

  // realign as needed
  // address_offset is just the last three bits of the load address which select the byte address within the word
  assign shifted_data = load_rdata >> {load_addr_offset, 3'b000};

  // The code here is legacy - from the days before G6LC was Big Endian Capable :)
  /*// result mux (leaner code, but more logic stages.
    // can be used instead of the code below (in between //result mux fast) if timing is not so critical)
    always_comb begin
        unique case (ldbuf_rdata.operation)
            LWU:        result_o = shifted_data[31:0];
            LHU:        result_o = shifted_data[15:0];
            LBU:        result_o = shifted_data[7:0];
            LW:         result_o = 64'(signed'(shifted_data[31:0]));
            LH:         result_o = 64'(signed'(shifted_data[15:0]));
            LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
            default:    result_o = shifted_data;
        endcase
    end  */

  /*
  // BIG ENDIAN CAPABLE result mux
  // Can be used instead of the code below (in between "BIG ENDIAN CAPABLE result mux fast" and "end BIG ENDIAN CAPABLE result mux fast") if timing is not so critical.
  // This code has been tested and is functionally identical to "BIG ENDIAN CAPABLE result mux fast", and while commented out it still aids in the readability of load_unit.sv.
  always_comb begin
      unique case (ldbuf_rdata.operation)
          LWU:        result_o = 64'(unsigned'(mbe_i ? {<<8{shifted_data[31:0]}} : shifted_data[31:0]));
          LHU:        result_o = 64'(unsigned'(mbe_i ? {<<8{shifted_data[15:0]}} : shifted_data[15:0]));
          LBU:        result_o = 64'(unsigned'(shifted_data[7:0]));
          LW:         result_o = 64'(signed'(mbe_i ? {<<8{shifted_data[31:0]}} : shifted_data[31:0]));
          LH:         result_o = 64'(signed'(mbe_i ? {<<8{shifted_data[15:0]}} : shifted_data[15:0]));
          LB:         result_o = 64'(signed'(shifted_data[ 7:0]));
          default:    result_o = mbe_i ? {<<8{shifted_data}} : shifted_data;
      endcase
  end
  */

  // BIG ENDIAN CAPABLE result mux fast
  logic [G6LCCfg.XLEN-1:0] endian_data;

  // Reversing the order of the Bytes in the data loaded from memory if mbe=1 -> which comes from the CSRregfile meaning the processor is in Big Endian Mode.
  // If mbe=1 then the processor should treat Data memory as Big Endian. The internals of G6LC are Little endian, so we achieve this by Reversing the Byte Order to Little Endian when it enters the processor through a Load.
  always_comb begin
    endian_data = shifted_data;
    if (mbe_i) begin
      case (load_operation)
        LB, LBU, HLV_B, HLV_BU, FLB: begin
          // If we are just loading a byte, then this needs not be touched
          endian_data[7:0] = {shifted_data[7:0]};
        end
        LH, LHU, HLV_H, HLV_HU, HLVX_HU, FLH: begin
          endian_data[15:0] = {<<8{shifted_data[15:0]}};
        end
        LW, LWU, HLV_W, HLV_WU, HLVX_WU, FLW, AMO_LRW, AMO_SCW, AMO_SWAPW, AMO_ADDW,
        AMO_ANDW, AMO_ORW, AMO_XORW, AMO_MAXW, AMO_MAXWU, AMO_MINW, AMO_MINWU: begin
          endian_data[31:0] = {<<8{shifted_data[31:0]}};
        end
        default: begin
          endian_data[G6LCCfg.XLEN-1:0] = {<<8{shifted_data[G6LCCfg.XLEN-1:0]}};
        end
      endcase
    end
  end

  // result mux fast
  logic [        (G6LCCfg.XLEN/8)-1:0] rdata_sign_bits;
  logic [G6LCCfg.XLEN_ALIGN_BYTES-1:0] rdata_offset;
  logic rdata_sign_bit, rdata_is_signed, rdata_is_fp_signed;


  // prepare these signals for faster selection in the next cycle
  assign rdata_is_signed    =   load_operation inside {g6lc_core_pkg::LW,  g6lc_core_pkg::LH,  g6lc_core_pkg::LB, g6lc_core_pkg::HLV_W, g6lc_core_pkg::HLV_H, g6lc_core_pkg::HLV_B};
  assign rdata_is_fp_signed =   load_operation inside {g6lc_core_pkg::FLW, g6lc_core_pkg::FLH, g6lc_core_pkg::FLB};
  // If we are in Big Endian Mode, we don't need to add anything to the address offset to find the byte that contains the sign bit, as it is always the lowest addressed byte that has the sign bit.
  assign rdata_offset       = ((load_operation inside {g6lc_core_pkg::LW,  g6lc_core_pkg::FLW, g6lc_core_pkg::HLV_W}) && G6LCCfg.IS_XLEN64 && (~mbe_i)) ? load_addr_offset + 3 :
                                ( load_operation inside {g6lc_core_pkg::LH,  g6lc_core_pkg::FLH, g6lc_core_pkg::HLV_H} && (~mbe_i))                     ? load_addr_offset + 1 :
                                                                                                                         load_addr_offset;

  for (genvar i = 0; i < (G6LCCfg.XLEN / 8); i++) begin : gen_sign_bits
    assign rdata_sign_bits[i] = load_rdata[(i+1)*8-1];
  end


  // select correct sign bit in parallel to result shifter above
  // pull to 0 if unsigned
  assign rdata_sign_bit = (rdata_is_signed && rdata_sign_bits[rdata_offset]) || (G6LCCfg.FpPresent && rdata_is_fp_signed);

  // result mux
  always_comb begin
    unique case (load_operation)
      g6lc_core_pkg::LW, g6lc_core_pkg::LWU, g6lc_core_pkg::HLV_W, g6lc_core_pkg::HLV_WU, g6lc_core_pkg::HLVX_WU:
      result_o = {{G6LCCfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
      g6lc_core_pkg::LH, g6lc_core_pkg::LHU, g6lc_core_pkg::HLV_H, g6lc_core_pkg::HLV_HU, g6lc_core_pkg::HLVX_HU:
      result_o = {{G6LCCfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
      g6lc_core_pkg::LB, g6lc_core_pkg::LBU, g6lc_core_pkg::HLV_B, g6lc_core_pkg::HLV_BU:
      result_o = {{G6LCCfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
      default: begin
        // FLW, FLH and FLB have been defined here in default case to improve Code Coverage
        if (G6LCCfg.FpPresent) begin
          unique case (load_operation)
            g6lc_core_pkg::FLW: begin
              result_o = {{G6LCCfg.XLEN - 32{rdata_sign_bit}}, endian_data[31:0]};
            end
            g6lc_core_pkg::FLH: begin
              result_o = {{G6LCCfg.XLEN - 32 + 16{rdata_sign_bit}}, endian_data[15:0]};
            end
            g6lc_core_pkg::FLB: begin
              result_o = {{G6LCCfg.XLEN - 32 + 24{rdata_sign_bit}}, endian_data[7:0]};
            end
            default: begin
              result_o = endian_data[G6LCCfg.XLEN-1:0];
            end
          endcase
        end else begin
          result_o = endian_data[G6LCCfg.XLEN-1:0];
        end
      end
    endcase
  end
  // end BIG ENDIAN CAPABLE result mux fast

  ///////////////////////////////////////////////////////
  // assertions

endmodule
