# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
import math
import struct
import unittest

from ai_tensor import numfmt
from ai_tensor.c_abi import pack_desc64
from ai_tensor.device import Caps, Device, pack_gemm_desc


class NativeReferenceTests(unittest.TestCase):
    def test_cosim_command_preserves_paths(self):
        import importlib.util
        import shlex
        from pathlib import Path
        from unittest.mock import patch
        path = Path(__file__).resolve().parents[2] / 'tools' / 'ait.py'
        spec = importlib.util.spec_from_file_location('ait_command_test', path)
        cli = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cli)
        with patch.object(cli.sys, 'executable', 'C:/Program Files/Python/python.exe'), \
             patch.object(cli, 'HARNESS', Path('C:/tensor workspace/cosim_harness.py')):
            self.assertEqual(shlex.split(cli.default_cosim_cmd()),
                             ['C:/Program Files/Python/python.exe',
                              'C:/tensor workspace/cosim_harness.py'])

    def test_v2_default_strides(self):
        for pack in (pack_desc64, pack_gemm_desc):
            blob = pack(2, 3, 5)
            self.assertEqual(struct.unpack_from('<H', blob)[0], 2)
            self.assertEqual(struct.unpack_from('<I', blob, 20)[0], 5 | (5 << 16))

    def test_all_scalar_formats(self):
        for fmt, one in ((0, b'\x01'), (1, b'\x01'), (3, b'\x38'),
                         (4, b'\x3c'), (5, b'\x00\x3c'),
                         (6, b'\x80\x3f'), (7, b'\x00\x00\x80\x3f')):
            with self.subTest(fmt=fmt):
                out = numfmt.gemm_native(one, one, 1, 1, 1, fmt)
                self.assertEqual(out, struct.pack('<I', 1 if fmt < 2 else 0x3f800000))

    def test_int4_odd_rows_and_negative(self):
        a = bytes([0x21, 0xf3, 0xfe, 0x08])
        b = bytes([0x21, 0x03, 0xff, 0x0f, 0x11, 0x01])
        out = numfmt.gemm_native(a, b, 2, 3, 3, 1)
        self.assertEqual(struct.unpack('<6i', out), (14, -6, 6, -28, 11, -11))

    def test_native_b_and_padded_strides(self):
        a = bytes([1, 2, 3, 99, 4, 5, 6, 99])
        b = bytes([1, 2, 3, 99, 4, 5, 6, 99])
        out = numfmt.gemm_native(a, b, 2, 2, 3, 0, lda=4, ldb=4)
        self.assertEqual(struct.unpack('<4i', out), (14, 32, 32, 77))

    def test_fp8_specials(self):
        self.assertEqual(numfmt.decode_bits(0x78, 3), 256.0)
        self.assertEqual(numfmt.decode_bits(0x7e, 3), 448.0)
        self.assertTrue(math.isnan(numfmt.decode_bits(0x7f, 3)))
        self.assertTrue(math.isinf(numfmt.decode_bits(0x7c, 4)))
        self.assertEqual(numfmt.decode_bits(1, 3), 2.0 ** -9)
        self.assertEqual(numfmt.decode_bits(1, 4), 2.0 ** -16)
        for fmt in (3, 4):
            self.assertEqual(math.copysign(1.0, numfmt.decode_bits(0x80, fmt)), -1.0)

    def test_ordered_f32_not_f64_or_fused(self):
        a = struct.pack('<3f', 2.0 ** 24, 1.0, -(2.0 ** 24))
        b = struct.pack('<3f', 1.0, 1.0, 1.0)
        self.assertEqual(numfmt.gemm_native(a, b, 1, 1, 3, 7), struct.pack('<f', 0.0))
        a = struct.pack('<2I', 0xbf800000, 0x3f800001)
        b = struct.pack('<2I', 0x3f800000, 0x3f7fffff)
        self.assertEqual(numfmt.gemm_native(a, b, 1, 1, 2, 7), struct.pack('<f', 0.0))

    def test_nan_and_overflow(self):
        out = numfmt.gemm_native(struct.pack('<f', math.inf), bytes(4), 1, 1, 1, 7)
        self.assertEqual(out, struct.pack('<I', 0x7fc00000))
        out = numfmt.gemm_native(struct.pack('<I', 0x7f7fffff), struct.pack('<f', 2), 1, 1, 1, 7)
        self.assertEqual(out, struct.pack('<f', math.inf))

    def test_refusals(self):
        for args in ((b'\x01', b'\x01', 1, 1, 1, 2),
                     (b'', b'\x01', 1, 1, 1, 0),
                     (b'\x01', b'\x01', 0, 1, 1, 0)):
            with self.assertRaises(ValueError):
                numfmt.gemm_native(*args, dtype_mask=0xff)
        with self.assertRaises(ValueError):
            numfmt.gemm_native(bytes(4), bytes(4), 1, 1, 1, 7, dtype_mask=1)
        with self.assertRaises(ValueError):
            numfmt.gemm_native(bytes(4), bytes(4), 1, 1, 2, 0, ldb=1)

    def test_fp16_bf16_exact_widen(self):
        for bits in (0, 0x8000, 1, 0x3ff, 0x400, 0x3c00, 0x7bff, 0x7c00, 0xfc00):
            want = struct.unpack('<e', struct.pack('<H', bits))[0]
            got = numfmt.decode_bits(bits, 5)
            self.assertEqual(struct.pack('<f', got), struct.pack('<f', want))
        for bits in (0, 0x8000, 1, 0x7f, 0x80, 0x3f80, 0x7f7f, 0x7f80, 0xff80):
            self.assertEqual(struct.pack('<f', numfmt.decode_bits(bits, 6)), struct.pack('<I', bits << 16))
        for fmt, nan in ((3, b'\x7f'), (4, b'\x7d'), (5, b'\x01\x7c'), (6, b'\x81\x7f'), (7, b'\x01\x00\x80\x7f')):
            self.assertEqual(numfmt.gemm_native(nan, nan, 1, 1, 1, fmt), struct.pack('<I', 0x7fc00000))

    def test_pack_bits_padding(self):
        self.assertEqual(numfmt.pack_bits([[1, 2, 3], [15, 14, 8]], 1), bytes([0x21, 3, 0xef, 8]))
        self.assertEqual(numfmt.pack_bits([[0x3c00], [0x4000]], 5, ld=2), bytes([0, 0x3c, 0, 0, 0, 0x40, 0, 0]))

    def test_software_profile_and_v1_refusal(self):
        from pathlib import Path
        from ai_tensor.profile import Profile
        profile = Path(__file__).resolve().parents[2] / 'profiles/software-reference-v2.toml'
        dev = Device.from_profile(str(profile))
        self.assertEqual(dev.backend, 'software-reference-v2')
        self.assertEqual(dev.caps().dtype_mask, 0xfb)
        self.assertEqual(dev.gemm_native(bytes([0x38]), bytes([0x38]), 1, 1, 1, 3), struct.pack('<f', 1))
        for text in ('contract_version=1', 'features=["t2_desc_v1"]'):
            with self.assertRaises(ValueError):
                Profile.parse(text)

    def test_numpy_generic_preserves_dtype(self):
        try:
            import numpy as np
            from ai_tensor.numpy_ops import gemm
        except ImportError:
            self.skipTest('NumPy not installed')
        a = np.asarray([[1.5, -2.0]], dtype=np.float32)
        b = np.asarray([[2.0], [3.0]], dtype=np.float32)
        c, meta = gemm(a, b, backend='software-reference-v2')
        self.assertEqual(c.dtype, np.float32)
        self.assertEqual(c.tolist(), [[-3.0]])
        self.assertEqual(meta['numfmt'], 7)
        with self.assertRaises(ValueError):
            gemm(a.astype(np.float64), b.astype(np.float64), backend='software-reference-v2')

    def test_torch_generic_preserves_dtype(self):
        try:
            import torch
            from ai_tensor.torch_ops import gemm
        except ImportError:
            self.skipTest('PyTorch not installed')
        dtypes = [torch.float16, torch.bfloat16, torch.float32]
        dtypes.extend(getattr(torch, name) for name in ('float8_e4m3fn', 'float8_e5m2') if hasattr(torch, name))
        for dtype in dtypes:
            a = torch.tensor([[1.5, -2.0]], dtype=dtype)
            b = torch.tensor([[2.0], [3.0]], dtype=dtype)
            c, _ = gemm(a, b, backend='software-reference-v2')
            self.assertEqual(c.dtype, torch.float32)
            self.assertEqual(c.tolist(), [[-3.0]])
        with self.assertRaises(ValueError):
            gemm(a.double(), b.double(), backend='software-reference-v2')

    def test_integer_wrapping(self):
        k = 65535
        a = bytes([128]) * k
        b = bytes([128]) * k
        self.assertEqual(struct.unpack('<i', numfmt.gemm_native(a, b, 1, 1, k, 0))[0], k * 16384)

    def test_device_native_and_s8(self):
        from unittest.mock import patch
        with patch('ai_tensor.device._try_native', return_value=None):
            dev = Device('sim', caps=Caps(dtype_mask=0xfb))
            out = dev.gemm_native(struct.pack('<f', 2), struct.pack('<f', 3), 1, 1, 1, 7)
            self.assertEqual(out, struct.pack('<f', 6))
            c, _, status, _ = dev.gemm_s8(2, 2, 3, [1, 2, 3, 4, 5, 6], [1, 4, 2, 5, 3, 6])
            self.assertEqual((c, status), ([14, 32, 32, 77], 0))


if __name__ == '__main__':
    unittest.main()
