// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_storamic_checkpoint_codec #(
  parameter bit OracleNegative = 1'b0
) (
  input logic [31:0] crc_i,
  input logic [1:0] bits_i,
  input logic [63:0] raw_bytes_i, image_bytes_i, extra_bytes_i,
  input logic allow_no_block_i,
  input g6lc_storamic_checkpoint_pkg::checkpoint_record_t record_i
);
  import g6lc_storamic_checkpoint_pkg::*;
  logic [31:0] reference_crc;
  logic [63:0] marker;
  checkpoint_record_t decoded;
  checkpoint_layout_t layout;
  always_comb begin
    reference_crc = crc_i;
    for (int i = 0; i < 2; i++)
      reference_crc = (reference_crc >> 1) ^
          ((reference_crc[0] ^ bits_i[i]) ? 32'h82F6_3B78 : 32'd0);
    assert (crc2(crc_i, bits_i) == reference_crc);
    marker = commit_marker(record_i);
    assert (marker[63:56] == 8'hC5 && marker != 0 && marker != '1);
    decoded = '0;
    for (int i = 0; i < 8; i++)
      decoded = decode_word(decoded, 3'(i), record_word(record_i, 3'(i)));
    assert (decoded == record_i);
    layout = checkpoint_layout(raw_bytes_i, image_bytes_i, extra_bytes_i, allow_no_block_i);
    if (layout.legal) begin
      assert (layout.user_bytes[8:0] == 0 && image_bytes_i >= 8 && image_bytes_i[2:0] == 0);
      assert (allow_no_block_i || layout.user_bytes >= 512);
      assert ({1'b0, layout.user_bytes} + {1'b0, layout.reserved_bytes} == {1'b0, raw_bytes_i});
      assert ({1'b0, layout.record0} + 65'd128 == {1'b0, raw_bytes_i});
      assert ({1'b0, layout.record1} + 65'd64 == {1'b0, raw_bytes_i});
      assert (layout.image0 == layout.user_bytes);
      assert ({1'b0, layout.image1} == {1'b0, layout.image0} + {1'b0, image_bytes_i});
      assert ({2'b0, layout.image1} + {2'b0, image_bytes_i} + {2'b0, extra_bytes_i}
              <= {2'b0, layout.record0});
    end else assert (layout == '0);
    if (OracleNegative) assert (marker == 0);
  end
endmodule
