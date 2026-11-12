#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Emit ONLY the imgarr sh corpus vector (image descriptor array).

Mirrors main()'s per-name flow for a single vector: scanner self-check,
then per seed gen_inputs -> emit -> lavapipe oracle (vk_compute_oracle)
with oracle_image() folding the model image in on Gate-2 overflow or
oracle failure.  sampler2D texs[4] exercises the dsc_idx_q descriptor-
array index path for COMBINED image samplers (CTS
combined_image_sampler_array analogue).

Run from the tools/shader dir:  python3 gen_imgarr.py
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.chdir(HERE)

import shader_vectors as sv  # noqa: E402

NAMES = ('imgarr',)


def main():
    oracle_ok = sv.build_oracle()
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
            if oracle_ok:
                out_bin = base + '.out.bin'
                r = sv.run_oracle(spv, base + '.desc.json', out_bin)
                if r.returncode != 0:
                    print('%s_%d: oracle failed: %s — ORACLE section '
                          'carries model words' %
                          (name, seed, r.stderr.strip()))
                    sv.emit(name, seed, words, desc, inputs,
                            oracle_out=sv.oracle_image(mc[1], mc, desc),
                            model_cache=mc)
                    continue
                data = open(out_bin, 'rb').read()
                owords = list(struct.unpack(
                    '<%dI' % (len(data) // 4), data))
                o2 = sv.oracle_image(owords, mc, desc)
                if o2 != owords:
                    print('%s_%d: oracle beyond Gate-2 tolerance — '
                          'ORACLE section carries model words'
                          % (name, seed))
                sv.emit(name, seed, words, desc, inputs,
                        oracle_out=o2, model_cache=mc)
            else:
                sv.emit(name, seed, words, desc, inputs,
                        oracle_out=sv.oracle_image(mc[1], mc, desc),
                        model_cache=mc)
            print('wrote %s_%d' % (name, seed))
    print('done ->', sv.OUT)


if __name__ == '__main__':
    main()
