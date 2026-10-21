// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
/*
 *  Copyright 2023 CEA*
 *  *Commissariat a l'Energie Atomique et aux Energies Alternatives (CEA)
 *  Copyright 2025 Inria, Universite Grenoble-Alpes, TIMA
 *
 *  SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
 *
 *  Licensed under the Solderpad Hardware License v 2.1 (the “License”); you
 *  may not use this file except in compliance with the License, or, at your
 *  option, the Apache License version 2.0. You may obtain a copy of the
 *  License at
 *
 *  https://solderpad.org/licenses/SHL-2.1/
 *
 *  Unless required by applicable law or agreed to in writing, any work
 *  distributed under the License is distributed on an “AS IS” BASIS, WITHOUT
 *  WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 *  License for the specific language governing permissions and limitations
 *  under the License.
 */
/*
 *  Authors       : Cesar Fuguet
 *  Creation Date : May, 2021
 *  Description   : HPDcache AMO computing unit
 *  Modified by   : Etienne Cimon
 *  History       :
 */
module hpdcache_amo
import hpdcache_pkg::*;
//  Ports
//  {{{
(
    input  logic [63:0]           ld_data_i,
    input  logic [63:0]           st_data_i,
    input  hpdcache_uc_op_t       op_i,
    output logic [63:0]           result_o
);
//  }}}

    logic signed [63:0] ld_data;
    logic signed [63:0] st_data;
    logic signed [63:0] sum;
    logic               ugt, sgt;

    logic [31:0] cas_cmp_w, cas_swap_w;
    logic [63:0] cas_result;

    assign ld_data = ld_data_i,
           st_data = st_data_i;

    assign ugt = (ld_data_i > st_data_i),
           sgt = (ld_data   > st_data),
           sum =  ld_data   + st_data;

    // Zacas AMOCAS.W pack from g6lc_hpdcache_if_adapter / hpdcache_uncached:
    //   st_data = {cmp[31:0], swap[31:0]}
    // Word path prepares ld into [31:0] (see prepare_amo_data_operand); BE
    // selects the addressed half on store. Dword CAS uses adapter CASD FSM
    // (expected in operand_c) — not this unit's pure-swap heuristic.
    // This compare is a second copy of `assign cas_match` in
    // hpdcache_uncached; both must agree. This one only produces result_o.
    assign cas_cmp_w  = st_data_i[63:32];
    assign cas_swap_w = st_data_i[31:0];
    always_comb begin
        // Word: compare prepared low half to cmp.
        // On match, replicate swap into both halves; the downstream BE
        // (cas_word_be) selects the addressed lane, so the lane that is
        // written gets swap and we avoid another address decode here.
        if (ld_data_i[31:0] == cas_cmp_w)
            cas_result = {cas_swap_w, cas_swap_w};
        else
            // Mismatch: AMOCAS returns the old memory value.
            cas_result = ld_data_i;
    end

    always_comb
    begin : amo_compute_comb
        unique case (1'b1)
            op_i.is_amo_lr   : result_o = ld_data_i;
            op_i.is_amo_sc   : result_o = st_data_i;
            op_i.is_amo_swap : result_o = st_data_i;
            op_i.is_amo_add  : result_o = sum;
            op_i.is_amo_and  : result_o = ld_data_i & st_data_i;
            op_i.is_amo_or   : result_o = ld_data_i | st_data_i;
            op_i.is_amo_xor  : result_o = ld_data_i ^ st_data_i;
            op_i.is_amo_max  : result_o = sgt ? ld_data_i : st_data_i;
            op_i.is_amo_maxu : result_o = ugt ? ld_data_i : st_data_i;
            op_i.is_amo_min  : result_o = sgt ? st_data_i : ld_data_i;
            op_i.is_amo_minu : result_o = ugt ? st_data_i : ld_data_i;
            // AMOCAS.W (pack). cas_match in hpdcache_uncached is the only
            // signal that may trigger the phase-1 store; result_o only feeds
            // the store data path and does not itself allow the store.
            op_i.is_amo_cas  : result_o = cas_result;
            default          : result_o = '0;
        endcase
    end
endmodule
