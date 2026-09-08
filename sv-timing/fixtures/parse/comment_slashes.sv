// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Banner comments must not lower as DivRem (SyncDpRam-shaped).

module comment_slashes;
  ////////////////////////////
  // signals, localparams
  ////////////////////////////
  logic [7:0] a, b, c;
  assign c = a + b;
  ////////////////////////////
  // optional output regs
  ////////////////////////////
  assign a = 8'h1;
endmodule
