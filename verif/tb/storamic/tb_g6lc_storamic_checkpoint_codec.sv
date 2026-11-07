// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_codec;
  import g6lc_storamic_checkpoint_pkg::*;
  int checks = 0;
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "CHECKPOINT_CODEC_FAIL %s", label);
  endtask
  function automatic logic [31:0] reference_word(
    input logic [31:0] previous, input logic [63:0] word_i
  );
    logic [31:0] crc;
    crc = previous;
    for (int i = 0; i < 64; i++)
      crc = (crc >> 1) ^ ((crc[0] ^ word_i[i]) ? 32'h82F6_3B78 : 32'd0);
    return crc;
  endfunction
  function automatic logic [31:0] header_crc(input checkpoint_record_t record_i);
    logic [31:0] crc;
    crc = '1;
    for (int i = 0; i < 7; i++) crc = reference_word(crc, record_crc_word(record_i, 3'(i)));
    return ~crc;
  endfunction
  function automatic bit legal_layout(
    input logic [63:0] raw_bytes, image_bytes, extra_bytes, input bit no_block
  );
    checkpoint_layout_t value;
    value = checkpoint_layout(raw_bytes, image_bytes, extra_bytes, no_block);
    return value.legal;
  endfunction
  checkpoint_record_t record_q, decoded;
  checkpoint_layout_t layout;
  logic [31:0] crc, ref_crc;
  logic [63:0] word_q;
  logic [7:0] byte_q;
  string message = "123456789";
  initial begin
    crc = '1;
    for (int i = 0; i < message.len(); i++) begin
      byte_q = message[i];
      for (int j = 0; j < 4; j++) crc = crc2(crc, 2'(byte_q >> (2*j)));
    end
    ok(~crc == 32'hE306_9283, "CRC32C-standard-golden");
    for (int i = 0; i < 128; i++) begin
      crc = 32'h1234_5678 ^ (32'(i) * 32'h9E37_79B9);
      ref_crc = reference_word(crc, 64'h0123_4567_89AB_CDEF ^ 64'(i));
      word_q = 64'h0123_4567_89AB_CDEF ^ 64'(i);
      for (int j = 0; j < 32; j++) crc = crc2(crc, 2'(word_q >> (2*j)));
      ok(crc == ref_crc, "two-bit-step-matches-independent-bit-reference");
    end
    record_q = '0;
    record_q.magic = RecordMagic;
    record_q.module_id = 160'h00112233_44556677_8899AABB_CCDDEEFF_01234567;
    record_q.mapping_generation = 7;
    record_q.generation = 3;
    record_q.image_bytes = 64;
    record_q.image_crc = 32'hDEAD_BEEF;
    record_q.record_crc = header_crc(record_q);
    record_q.marker = commit_marker(record_q);
    ok(record_q.record_crc == 32'hA569_7107, "independent-little-endian-header-golden");
    ok(record_q.marker == 64'hC5E2_F3A2_EC3D_5025, "bound-commit-marker-golden");
    ok(record_word(record_q, 1) == 64'hCCDD_EEFF_0123_4567 &&
       record_word(record_q, 2) == 64'h4455_6677_8899_AABB &&
       record_word(record_q, 3) == 64'h0000_0007_0011_2233, "identity-and-map-word-layout");
    decoded = '0;
    for (int i = 0; i < 8; i++) decoded = decode_word(decoded, 3'(i), record_word(record_q, 3'(i)));
    ok(decoded == record_q && record_header_valid(decoded, 1, header_crc(decoded)),
       "valid-record-round-trip");
    ok(!record_header_valid(decoded, 0, header_crc(decoded)), "wrong-slot-rejected");
    ok(record_matches(decoded, record_q.module_id, 7, 64), "identity-map-size-binding");
    ok(!record_matches(decoded, record_q.module_id ^ 160'd1, 7, 64) &&
       !record_matches(decoded, record_q.module_id, 8, 64) &&
       !record_matches(decoded, record_q.module_id, 7, 128), "foreign-binding-rejected");
    for (int bit_index = 0; bit_index < 512; bit_index++) begin
      decoded = '0;
      for (int i = 0; i < 8; i++) begin
        word_q = record_word(record_q, 3'(i));
        if (i == bit_index / 64) word_q ^= 64'd1 << (bit_index % 64);
        decoded = decode_word(decoded, 3'(i), word_q);
      end
      ok(!record_header_valid(decoded, 1, header_crc(decoded)), "single-bit-record-corruption-rejected");
    end
    decoded = record_q; decoded.generation = 0;
    decoded.record_crc = header_crc(decoded); decoded.marker = commit_marker(decoded);
    ok(!record_header_valid(decoded, 0, header_crc(decoded)), "generation-zero-is-not-committed");
    decoded = record_q;
    decoded.generation = CommitSalt ^ {decoded.image_crc, decoded.record_crc};
    ok(commit_marker(decoded) == 64'hC500_0000_0000_0000,
       "marker-binding-can-never-alias-zero-invalidation");

    layout = checkpoint_layout(1024, 64, 0, 0);
    ok(layout.legal && layout.user_bytes == 512 && layout.reserved_bytes == 512 &&
       layout.record0 == 896 && layout.record1 == 960 &&
       layout.image0 == 512 && layout.image1 == 576, "sector-bounded-reservation");
    layout = checkpoint_layout(1032, 64, 0, 0);
    ok(layout.legal && layout.user_bytes == 512 && layout.reserved_bytes == 520,
       "unadvertised-tail-is-reserved");
    ok(!legal_layout(512, 64, 0, 0), "block-bearing-layout-needs-a-sector");
    layout = checkpoint_layout(512, 64, 0, 1);
    ok(layout.legal && layout.user_bytes == 0, "explicit-no-block-layout");
    ok(!legal_layout(1024, 0, 0, 0) &&
       !legal_layout(1024, 65, 0, 0) &&
       !legal_layout(1025, 64, 0, 0), "invalid-capacity-alignment-rejected");
    ok(!legal_layout(~64'd7, 64'h8000_0000_0000_0000, 0, 0) &&
       !legal_layout(~64'd7, ~64'd7, ~64'd7, 0), "reservation-overflow-rejected");
    layout = checkpoint_layout(2048, 64, 768, 0);
    ok(layout.legal && layout.reserved_bytes == 1024 && layout.user_bytes == 1024,
       "independent-extra-recovery-reservation");
    layout = checkpoint_layout(2048, 256, 0, 0);
    ok(layout.legal && layout.record0 == 1920 && layout.record1 == 1984 &&
       layout.image1 + 256 <= layout.record0, "fixed-record-locations-survive-image-size-change");
    layout = checkpoint_layout(2048, 64, 0, 0);
    ok(layout.record0 == 1920 && layout.record1 == 1984,
       "small-image-discovers-same-record-slots");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("CHECKPOINT_CODEC_PASS checks=%0d", checks);
    $finish;
  end
endmodule
