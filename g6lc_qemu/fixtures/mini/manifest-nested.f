// SYNTHETIC FIXTURE. Invented content (see ../README.md).
// SPDX-License-Identifier: MIT
//
// Included by manifest.f, and points back at it. The expander must visit this file
// once and silently ignore the return edge rather than recursing.

${ROOT}/soc/clint.sv
${ROOT}/soc/intc.sv

-f manifest.f      // cycle: must be ignored, not an error
