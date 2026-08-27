// SYNTHETIC FIXTURE. Invented content (see ../README.md).
// SPDX-License-Identifier: MIT
//
// Top-level manifest. Exercises: variable expansion, +incdir+, +define+,
// a nested include, a full-line comment and a trailing comment.
//
// Note what is NOT here: no vector unit source. The configuration package enables
// HasVector, so membership must report a stub and conformance must refuse it under
// --conform strict. That disagreement is the point of this fixture pair.

+incdir+${ROOT}/include
+define+SUPPLY_B

${ROOT}/core/pkg_mini.sv
${ROOT}/core/decode.sv
${ROOT}/core/stub_vector_decoder.sv

-f manifest-nested.f

# a full-line comment
${ROOT}/soc/uart.sv        // trailing comment
