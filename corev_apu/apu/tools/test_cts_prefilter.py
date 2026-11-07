#!/usr/bin/env python3
# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Local policy regressions; no CTS executable or remote builder needed."""
import argparse
import json
from pathlib import Path
import tempfile
import unittest

import cts_prefilter as P


class FakeContext:
    def __init__(self):
        self.keep = {}
        self.features = set()
        self.formats = set()
        self.limits = {}
        self.decoded = {}
        self.spvm = 'RowMajor'

    def golden_has(self, pattern):
        return True

    def module_cmds(self, mod):
        return ()


class PrefilterTests(unittest.TestCase):
    def test_immutable_sampler_survives_basic_graphics_coverage(self):
        c = FakeContext()
        for name in (
                'dEQP-VK.binding_model.shader_access.primary_cmd_buf.bind.'
                'sampler_immutable.vertex.multiple_discontiguous_descriptor_sets',
                'dEQP-VK.binding_model.shader_access.secondary_cmd_buf.bind.'
                'combined_image_sampler_immutable.fragment.single_descriptor',
                'dEQP-VK.binding_model.descriptor_copy.misc.'
                'copy_immutable_sampler_1_images'):
            verdict, reasons = P.classify(name, c)
            self.assertEqual(verdict, 'certain-fail')
            self.assertIn('immutable-sampler', [r[1] for r in reasons])

    def test_mutable_sampler_not_conflated_with_immutable(self):
        verdict, _ = P.classify(
            'dEQP-VK.binding_model.shader_access.bind.sampler.vertex.single',
            FakeContext())
        self.assertEqual(verdict, 'predicted-pass')

    def test_staged_handles_remove_only_the_missing_field_rule(self):
        c = FakeContext()
        c.keep['vkCreateDescriptorSetLayout'] = {'pBindings.pImmutableSamplers'}
        self.assertIsNone(P._immutable_sampler(c))

    def wave(self, root, cases, **overrides):
        scan = root / 'scan.json'
        scan.write_text(json.dumps({'cases': cases}))
        a = argparse.Namespace(
            scan=str(scan), results=[], modules='', max=4, control=0.5,
            seed=7, out=str(root / 'wave.txt'))
        for k, v in overrides.items():
            setattr(a, k, v)
        P.cmd_wave(a)
        return (Path(a.out).read_text(),
                json.loads(Path(a.out + '.json').read_text()))

    def test_wave_separates_confirmation_from_all_uncertain_verdicts(self):
        cases = {
            'dEQP-VK.compute.basic.good': {'verdict': 'predicted-pass'},
            'dEQP-VK.memory.good': {'verdict': 'predicted-pass'},
            'dEQP-VK.compute.shader': {'verdict': 'shader-refused'},
            'dEQP-VK.memory.module': {'verdict': 'risk'},
            'dEQP-VK.api.format': {'verdict': 'ns-expected'},
            'dEQP-VK.binding_model.immutable': {'verdict': 'certain-fail'},
            'dEQP-VK.ssbo.unknown': {'verdict': 'untested'},
        }
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            text, meta = self.wave(root, cases, max=20, control=1)
            self.assertEqual(set(meta['confirmation']),
                             {n for n, v in cases.items()
                              if v['verdict'] == 'predicted-pass'})
            self.assertEqual(len(meta['discovery']), 2)
            self.assertEqual(len(set(text.splitlines())), 4)
            self.assertFalse(set(meta['confirmation']) & set(meta['discovery']))
            text2, meta2 = self.wave(root, cases, max=20, control=1)
            self.assertEqual((text, meta), (text2, meta2))

    def test_discovery_still_advances_without_predicted_passes(self):
        cases = {'dEQP-VK.compute.a': {'verdict': 'shader-refused'},
                 'dEQP-VK.memory.b': {'verdict': 'risk'}}
        with tempfile.TemporaryDirectory() as d:
            _, meta = self.wave(Path(d), cases)
            self.assertEqual(meta['confirmation'], [])
            self.assertEqual(len(meta['discovery']), 2)

    def test_discovery_zero_means_zero(self):
        cases = {'dEQP-VK.compute.a': {'verdict': 'predicted-pass'},
                 'dEQP-VK.compute.b': {'verdict': 'certain-fail'}}
        with tempfile.TemporaryDirectory() as d:
            _, meta = self.wave(Path(d), cases, control=0)
            self.assertEqual(meta['discovery'], [])

    def test_done_cases_are_not_reselected(self):
        cases = {'dEQP-VK.compute.a': {'verdict': 'predicted-pass'},
                 'dEQP-VK.memory.b': {'verdict': 'risk'}}
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            results = root / 'results.json'
            results.write_text(json.dumps({'results': [
                {'name': 'dEQP-VK.compute.a', 'status': 'Pass'}]}))
            text, _ = self.wave(root, cases, results=[str(results)])
            self.assertNotIn('dEQP-VK.compute.a', text)

    def test_wave_invalid_budget_is_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            for opts in ({'max': 0}, {'control': -0.1}, {'control': 1.1}):
                with self.assertRaises(ValueError):
                    self.wave(Path(d), {}, **opts)


if __name__ == '__main__':
    unittest.main()
