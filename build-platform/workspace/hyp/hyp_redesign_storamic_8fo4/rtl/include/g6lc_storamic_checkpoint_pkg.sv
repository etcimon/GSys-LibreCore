// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// Model record codec/layout only; no physical-media or software ABI claim.
package g6lc_storamic_checkpoint_pkg;
  localparam logic [63:0] RecordMagic = 64'h4736_4C43_504D_3031;
  localparam logic [63:0] CommitSalt = 64'h434F_4D4D_4954_2121;
  localparam logic [63:0] RecordBytes = 64;
  typedef struct packed {
    logic [63:0] magic;
    logic [159:0] module_id;
    logic [31:0] mapping_generation;
    logic [63:0] generation, image_bytes;
    logic [31:0] image_crc, record_crc;
    logic [63:0] marker;
  } checkpoint_record_t;
  typedef struct packed {
    logic legal;
    logic [63:0] user_bytes, reserved_bytes;
    logic [63:0] record0, record1, image0, image1;
  } checkpoint_layout_t;

  // Reflected CRC32C, low two bits first; the polynomial's bit zero is zero,
  // so these two feedback terms are independent. Seed/final XOR are all ones.
  function automatic logic [31:0] crc2(input logic [31:0] crc, input logic [1:0] bits_i);
    logic [1:0] feedback;
    feedback = crc[1:0] ^ bits_i;
    return (crc >> 2) ^ (feedback[0] ? 32'h417B_1DBC : 32'd0) ^
                       (feedback[1] ? 32'h82F6_3B78 : 32'd0);
  endfunction

  function automatic logic [63:0] commit_marker(input checkpoint_record_t record_i);
    logic [63:0] binding;
    binding = CommitSalt ^ record_i.generation ^ {record_i.image_crc, record_i.record_crc};
    // Zero is the invalidation word; it must never encode a committed record.
    return {8'hC5, binding[55:0]};
  endfunction

  function automatic logic [63:0] record_word(
    input checkpoint_record_t record_i, input logic [2:0] index_i
  );
    case (index_i)
      0: return record_i.magic;
      1: return record_i.module_id[63:0];
      2: return record_i.module_id[127:64];
      3: return {record_i.mapping_generation, record_i.module_id[159:128]};
      4: return record_i.generation;
      5: return record_i.image_bytes;
      6: return {record_i.image_crc, record_i.record_crc};
      7: return record_i.marker;
    endcase
    return '0;
  endfunction

  function automatic checkpoint_record_t decode_word(
    input checkpoint_record_t previous_i, input logic [2:0] index_i,
    input logic [63:0] word_i
  );
    checkpoint_record_t record_d;
    record_d = previous_i;
    case (index_i)
      0: record_d.magic = word_i;
      1: record_d.module_id[63:0] = word_i;
      2: record_d.module_id[127:64] = word_i;
      3: begin record_d.mapping_generation = word_i[63:32];
               record_d.module_id[159:128] = word_i[31:0]; end
      4: record_d.generation = word_i;
      5: record_d.image_bytes = word_i;
      6: begin record_d.image_crc = word_i[63:32]; record_d.record_crc = word_i[31:0]; end
      7: record_d.marker = word_i;
    endcase
    return record_d;
  endfunction

  function automatic logic [63:0] record_crc_word(
    input checkpoint_record_t record_i, input logic [2:0] index_i
  );
    return index_i == 6 ? {32'd0, record_i.image_crc} : record_word(record_i, index_i);
  endfunction

  function automatic logic record_header_valid(
    input checkpoint_record_t record_i, input logic slot_i,
    input logic [31:0] calculated_crc_i
  );
    return record_i.magic == RecordMagic && record_i.generation != 0 &&
        record_i.generation[0] == slot_i && record_i.image_bytes >= 8 &&
        record_i.image_bytes[2:0] == 0 &&
        record_i.record_crc == calculated_crc_i && record_i.marker == commit_marker(record_i);
  endfunction

  function automatic logic record_matches(
    input checkpoint_record_t record_i, input logic [159:0] module_id_i,
    input logic [31:0] mapping_generation_i, input logic [63:0] image_bytes_i
  );
    return record_i.module_id == module_id_i &&
        record_i.mapping_generation == mapping_generation_i &&
        record_i.image_bytes == image_bytes_i;
  endfunction

  function automatic checkpoint_layout_t checkpoint_layout(
    input logic [63:0] raw_bytes_i, image_bytes_i, extra_reserved_bytes_i,
    input logic allow_no_block_i
  );
    checkpoint_layout_t layout;
    logic [65:0] needed, rounded;
    logic [63:0] user_bytes;
    layout = '0;
    needed = ({2'b0, image_bytes_i} << 1) + 66'd128 + {2'b0, extra_reserved_bytes_i};
    rounded = (needed + 66'd511) & ~66'd511;
    if (raw_bytes_i[2:0] == 0 && image_bytes_i >= 8 && image_bytes_i[2:0] == 0 &&
        rounded[65:64] == 0 && {2'b0, raw_bytes_i} >= rounded) begin
      user_bytes = (raw_bytes_i - rounded[63:0]) & ~64'd511;
      if (allow_no_block_i || user_bytes >= 512) begin
        layout.legal = 1'b1;
        layout.user_bytes = user_bytes;
        layout.reserved_bytes = raw_bytes_i - user_bytes;
        // Fixed slot locations let a changed image/map configuration discover
        // and reject old records instead of mistaking a moved slot for blank.
        layout.record0 = raw_bytes_i - 2 * RecordBytes;
        layout.record1 = raw_bytes_i - RecordBytes;
        layout.image0 = user_bytes;
        layout.image1 = layout.image0 + image_bytes_i;
      end
    end
    return layout;
  endfunction
endpackage
