# Copyright 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Promoted (*2) transfer-command vector consistency checks.

Each *2 variant must emit the promoted command name in its command stream
while sharing every data expectation with its base twin. The .exp tapes may
differ only by a uniform address relocation: the larger *2 command payload
shifts the recorded addresses of everything that follows it, so the only
.word differences are a few pointer words moved by one constant delta.
"""
import json
import re
import unittest
from pathlib import Path

VECTORS = Path(__file__).resolve().parent / 'vn_vectors'

# (promoted session, promoted command, base command, base session,
#  promoted count, residual base-command count in the promoted session)
PROMOTED = [
    ('ue_cpos_xfer_copy2_1', 'vkCmdCopyBuffer2', 'vkCmdCopyBuffer',
     'ue_cpos_xfer_copy_1', 2, 0),
    ('ue_cpos_xfer_copymix_1', 'vkCmdCopyBuffer2', 'vkCmdCopyBuffer',
     'ue_cpos_xfer_copy_1', 1, 1),
    ('ue_cneg_xfer_oob2_1', 'vkCmdCopyBuffer2', 'vkCmdCopyBuffer',
     'ue_cneg_xfer_oob_1', 1, 0),
    ('ue_cpos_clear_rgba8_c2_1', 'vkCmdCopyBufferToImage2',
     'vkCmdCopyBufferToImage', 'ue_cpos_clear_rgba8_1', 1, 0),
    ('ue_cpos_clear_rgba8_c2_1', 'vkCmdCopyImageToBuffer2',
     'vkCmdCopyImageToBuffer', 'ue_cpos_clear_rgba8_1', 1, 0),
    ('ue_cpos_i2i_copy2_1', 'vkCmdCopyImage2', 'vkCmdCopyImage',
     'ue_cpos_i2i_copy_1', 1, 0),
    ('ue_cpos_i2i_blit2_1', 'vkCmdBlitImage2', 'vkCmdBlitImage',
     'ue_cpos_i2i_blit_1', 1, 0),
]

# unique (base, promoted) session pairs whose .exp tapes are compared
EXP_PAIRS = [
    ('ue_cpos_xfer_copy_1', 'ue_cpos_xfer_copy2_1'),
    ('ue_cpos_xfer_copy_1', 'ue_cpos_xfer_copymix_1'),
    ('ue_cneg_xfer_oob_1', 'ue_cneg_xfer_oob2_1'),
    ('ue_cpos_clear_rgba8_1', 'ue_cpos_clear_rgba8_c2_1'),
    ('ue_cpos_i2i_copy_1', 'ue_cpos_i2i_copy2_1'),
    ('ue_cpos_i2i_blit_1', 'ue_cpos_i2i_blit2_1'),
]


def command_log(session):
    data = json.loads((VECTORS / (session + '.json')).read_text())
    return ' '.join(str(entry) for entry in data['log'])


def command_count(log, name):
    # \b keeps vkCmdCopyBuffer from matching inside vkCmdCopyBuffer2 and
    # vkCmdCopyImage from matching inside vkCmdCopyImageToBuffer
    return len(re.findall(re.escape(name) + r'\b', log))


def exp_words(session):
    text = (VECTORS / (session + '.exp')).read_text().split()
    return [int(word, 16) for word in text]


class PromotedTransferVectorTests(unittest.TestCase):
    def test_promoted_command_names(self):
        for promoted, prom_cmd, base_cmd, base, prom_n, base_left in PROMOTED:
            with self.subTest(session=promoted, command=prom_cmd):
                base_log = command_log(base)
                prom_log = command_log(promoted)
                self.assertEqual(command_count(base_log, base_cmd),
                                 prom_n + base_left)
                self.assertEqual(command_count(prom_log, prom_cmd), prom_n)
                self.assertEqual(command_count(prom_log, base_cmd), base_left)

    def test_promoted_expectations_match_base(self):
        for base, promoted in EXP_PAIRS:
            with self.subTest(pair=(base, promoted)):
                base_words = exp_words(base)
                prom_words = exp_words(promoted)
                self.assertEqual(len(base_words), len(prom_words))
                diffs = [i for i, (b, p) in enumerate(zip(base_words, prom_words))
                         if b != p]
                # only a few recorded address words may move, all by the same
                # word-aligned positive delta (the *2 payload relocation)
                self.assertLessEqual(len(diffs), 32)
                deltas = {prom_words[i] - base_words[i] for i in diffs}
                self.assertEqual(len(deltas), 1)
                delta = next(iter(deltas))
                self.assertGreater(delta, 0)
                self.assertEqual(delta % 4, 0)


if __name__ == '__main__':
    unittest.main()
