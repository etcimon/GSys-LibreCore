// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Reduced hpdcache_memctrl generate data mux: `gen_j / Cfg` and `gen_j % Cfg`
// are elaboration index arithmetic (delay-v14), not a 120 FO4 SRT divider.

module hpdcache_idx_mux;
  typedef struct packed {
    int unsigned dataWaysPerRamWord;
    int unsigned reqWords;
  } cfg_u_t;
  typedef struct packed { cfg_u_t u; } cfg_t;
  localparam cfg_t HPDcacheCfg = '{u: '{dataWaysPerRamWord: 2, reqWords: 2}};
  logic [7:0] data_rentry[2][4][2];
  logic [7:0] data_read_words[2][4][2];
  for (genvar gen_i = 0; gen_i < 2; gen_i++) begin : gen_i
    for (genvar gen_j = 0; gen_j < 4; gen_j++) begin : gen_j
      for (genvar gen_k = 0; gen_k < 2; gen_k++) begin : gen_k
        assign data_read_words[gen_i][gen_j][gen_k] =
                data_rentry[(gen_j / HPDcacheCfg.u.dataWaysPerRamWord)]
                           [(gen_i * HPDcacheCfg.u.reqWords) + gen_k]
                           [(gen_j % HPDcacheCfg.u.dataWaysPerRamWord)];
      end
    end
  end
endmodule
