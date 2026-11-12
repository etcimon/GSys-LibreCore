#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Emit ONLY the texel-buffer (Dim=Buffer) sh corpus vectors.

The lavapipe oracle (vk_compute_oracle) models image descriptors
(imgw/imgh), not VkBufferView texel buffers, so these vectors fold the
spirv_model.py Gate-1 image in as the oracle section — the same path
main() takes when run_oracle fails.  spirv_model.py synthesizes the
degenerate Wx1 meta for kinds 4/5 mirroring shwave f_bufview_rec.

Run from the tools/shader dir:  python3 gen_texbuf.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.chdir(HERE)

import shader_vectors as sv  # noqa: E402

NAMES = ('texbuf', 'texbuf_img', 'texbuf_wr', 'texbuf_atom')

for name in NAMES:
    desc = sv.DESC[name]
    spv = os.path.join(sv.CORPUS, name + '.spv')
    words = sv.read_spv(spv)
    sc = sv.spirv_scan.Scanner(words)
    sc.scan()
    sc.emit_tab(os.path.join(sv.OUT, name + '.tab'))
    for seed in sv.SEEDS:
        inputs = sv.gen_inputs(desc, seed)
        base, mc = sv.emit(name, seed, words, desc, inputs)
        sv.emit(name, seed, words, desc, inputs,
                oracle_out=sv.oracle_image(mc[1], mc, desc),
                model_cache=mc)
        print('wrote %s_%d' % (name, seed))
print('done ->', sv.OUT)
