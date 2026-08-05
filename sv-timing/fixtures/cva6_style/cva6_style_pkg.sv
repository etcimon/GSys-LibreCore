// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// CVA6-style package: localparam + automatic function (mirrors ariane_pkg patterns
// without monorepo dependencies — used by sv-timing lower/emit validation).

package cva6_style_pkg;
  localparam int unsigned PKG_DEPTH = 4;
  localparam int unsigned PKG_WIDTH = 16;

  // Lightweight helper akin to package functions used from load/scoreboard paths.
  function automatic logic [PKG_WIDTH-1:0] pkg_add(
      input logic [PKG_WIDTH-1:0] a,
      input logic [PKG_WIDTH-1:0] b
  );
    return a + b;
  endfunction

  function automatic logic [PKG_WIDTH-1:0] pkg_mux(
      input logic                 sel,
      input logic [PKG_WIDTH-1:0] t,
      input logic [PKG_WIDTH-1:0] f
  );
    return sel ? t : f;
  endfunction
endpackage
