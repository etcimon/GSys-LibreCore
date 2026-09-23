// SPDX-License-Identifier: MIT
// A function return range must not include argument or local ranges.
package width_pkg;
  function automatic logic [63:0] line_base(
      input logic [55:0] line_addr,
      input int unsigned sh
  );
    logic [63:0] base;
    base = {8'b0, line_addr};
    return base << sh;
  endfunction
endpackage

module inv_adapter (
    input  logic [55:0] line_addr,
    input  int unsigned sh,
    output logic [63:0] addr
);
  assign addr = line_base(line_addr, sh);
endmodule
