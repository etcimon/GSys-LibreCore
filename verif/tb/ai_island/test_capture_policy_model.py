import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import capture_policy_model as capture


class OperatorWalkTests(unittest.TestCase):
    def test_order_and_matrix_link(self):
        walk = []
        capture.append_walk_event(walk, "aten.add.Tensor", "layer", max_events=2)
        capture.append_walk_event(walk, "aten.mm.default", "layer.proj", matrix_index=0, max_events=2)
        self.assertEqual(walk, [
            {"index": 0, "operator": "aten.add.Tensor", "module": "layer", "kind": "other"},
            {"index": 1, "operator": "aten.mm.default", "module": "layer.proj", "kind": "matrix", "matrix_index": 0},
        ])
        with self.assertRaises(ValueError):
            capture.append_walk_event(walk, "aten.mul.Tensor", "layer", max_events=2)
        self.assertEqual(len(walk), 2)

    def test_invalid_matrix_link(self):
        for index in (-1, True, "0"):
            with self.assertRaises(ValueError):
                capture.append_walk_event([], "aten.mm.default", "layer", matrix_index=index)


class GeometryTests(unittest.TestCase):
    def geometry(self, **overrides):
        arguments = {"operator": "aten.mm.default", "a_shape": [3, 8], "b_shape": [8, 5],
                     "a_stride": [8, 1], "b_stride": [5, 1],
                     "a_dtype": "torch.float32", "b_dtype": "torch.float32"}
        arguments.update(overrides)
        return capture.matrix_geometry(**arguments)

    def test_mm(self):
        self.assertEqual(self.geometry(), {"m": 3, "n": 5, "k": 8, "batch": 1, "numfmt": 7})

    def test_transposed_operands_preserve_logical_dimensions(self):
        self.assertEqual(self.geometry(a_stride=[1, 3], b_stride=[1, 8]), self.geometry())

    def test_addmm_geometry_does_not_include_bias(self):
        self.assertEqual(self.geometry(operator="aten.addmm.default"), self.geometry())

    def test_bmm_does_not_flatten_batch_into_m(self):
        self.assertEqual(self.geometry(operator="aten.bmm.default", a_shape=[4, 3, 8],
                                       b_shape=[4, 8, 5], a_stride=[24, 8, 1], b_stride=[40, 1, 8]),
                         {"m": 3, "n": 5, "k": 8, "batch": 4, "numfmt": 7})

    def test_matmul_rank_two_transposed(self):
        self.assertEqual(self.geometry(operator="aten.matmul.default", a_stride=[1, 3], b_stride=[1, 8]),
                         self.geometry())

    def test_matmul_shared_weight_flattens_only_a(self):
        result = self.geometry(operator="aten.matmul.default", a_shape=[2, 4, 3, 8],
                               a_stride=[96, 24, 8, 1], b_stride=[1, 8])
        self.assertEqual(result, {"m": 24, "n": 5, "k": 8, "batch": 1, "numfmt": 7})

    def test_matmul_matching_batches_and_bmm_equivalence(self):
        arguments = {"a_shape": [4, 3, 8], "b_shape": [4, 8, 5],
                     "a_stride": [24, 8, 1], "b_stride": [40, 1, 8]}
        self.assertEqual(self.geometry(operator="aten.matmul.default", **arguments),
                         self.geometry(operator="aten.bmm.default", **arguments))
        self.assertEqual(self.geometry(operator="aten.matmul.default", a_shape=[2, 4, 3, 8],
                                       b_shape=[2, 4, 8, 5], a_stride=[96, 24, 8, 1], b_stride=[160, 40, 1, 8]),
                         {"m": 3, "n": 5, "k": 8, "batch": 8, "numfmt": 7})

    def test_matmul_implicit_broadcast_and_vectors_rejected(self):
        cases = [([3, 8], [2, 8, 5], [8, 1], [40, 5, 1]),
                 ([2, 3, 8], [1, 8, 5], [24, 8, 1], [40, 5, 1]),
                 ([2, 4, 3, 8], [4, 8, 5], [96, 24, 8, 1], [40, 5, 1]),
                 ([2, 1, 3, 8], [1, 2, 8, 5], [24, 24, 8, 1], [80, 40, 5, 1]),
                 ([8], [8, 5], [1], [5, 1]),
                 ([3, 8], [8], [8, 1], [1]),
                 ([2, 3, 8], [2, 8, 5], [0, 8, 1], [40, 5, 1]),
                 ([1] * 17, [1, 5], [1] * 17, [5, 1])]
        for a, b, sa, sb in cases:
            with self.subTest(a=a, b=b), self.assertRaises(ValueError):
                self.geometry(operator="aten.matmul.default", a_shape=a, b_shape=b, a_stride=sa, b_stride=sb)

    def test_observed_linear_preserves_transposed_weight_geometry(self):
        self.assertEqual(self.geometry(operator="aten.linear.default", a_shape=[2, 3, 8],
                                       b_shape=[5, 8], a_stride=[24, 8, 1], b_stride=[8, 1]),
                         {"m": 6, "n": 5, "k": 8, "batch": 1, "numfmt": 7})
        with self.assertRaises(ValueError):
            self.geometry(operator="aten.linear.default", b_shape=[5, 7], b_stride=[7, 1])

    def test_observed_baddbmm_and_batch_bias(self):
        arguments = {"a_shape": [4, 3, 8], "b_shape": [4, 8, 5],
                     "a_stride": [24, 8, 1], "b_stride": [40, 5, 1]}
        self.assertEqual(self.geometry(operator="aten.baddbmm.default", **arguments),
                         self.geometry(operator="aten.bmm.default", **arguments))
        for shape in ([], [5], [3, 5], [1, 3, 5], [4, 3, 5]):
            capture.validate_bias(shape, "torch.float32", "torch.float32", 3, 5, batch=4)
        with self.assertRaises(ValueError):
            capture.validate_bias([2, 3, 5], "torch.float32", "torch.float32", 3, 5, batch=4)

    def test_bf16(self):
        self.assertEqual(self.geometry(a_dtype="torch.bfloat16", b_dtype="torch.bfloat16")["numfmt"], 6)

    def test_invalid_geometry_fails_closed(self):
        cases = [
            {"operator": "aten._scaled_mm.default"},
            {"a_shape": [3, 7]},
            {"b_shape": [7, 5]},
            {"a_shape": [0, 8]},
            {"a_shape": [-1, 8]},
            {"a_shape": [True, 8]},
            {"a_shape": [3.0, 8]},
            {"a_shape": [2**31, 8]},
            {"a_shape": [24], "a_stride": [1]},
            {"a_shape": [1, 3, 8], "a_stride": [24, 8, 1]},
            {"a_stride": [8]},
            {"a_stride": [-8, 1]},
            {"a_stride": [8.0, 1]},
            {"a_stride": [0, 1]},
            {"b_stride": [5, 0]},
            {"a_dtype": "torch.bfloat16"},
            {"a_dtype": None, "b_dtype": None},
            {"a_dtype": [], "b_dtype": []},
            {"a_dtype": "torch.float16", "b_dtype": "torch.float16"},
            {"a_dtype": "torch.int8", "b_dtype": "torch.int8"},
        ]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.geometry(**case)

    def test_batch_mismatch_and_broadcast_fail(self):
        for b_shape, a_stride in [([1, 8, 5], [24, 8, 1]), ([4, 8, 5], [0, 8, 1])]:
            with self.subTest(b_shape=b_shape, a_stride=a_stride), self.assertRaises(ValueError):
                self.geometry(operator="aten.bmm.default", a_shape=[4, 3, 8], b_shape=b_shape,
                              a_stride=a_stride, b_stride=[40, 5, 1])

    def test_singleton_zero_stride_is_not_broadcast(self):
        self.assertEqual(self.geometry(a_shape=[1, 8], a_stride=[0, 1])["m"], 1)

    def test_bias_broadcast_is_explicitly_validated(self):
        for shape in ([], [1], [5], [1, 5], [3, 1], [3, 5]):
            with self.subTest(shape=shape):
                capture.validate_bias(shape, "torch.float32", "torch.float32", 3, 5)
        for shape in ([3], [2, 5], [1, 3, 5], [0], [True]):
            with self.subTest(shape=shape), self.assertRaises(ValueError):
                capture.validate_bias(shape, "torch.float32", "torch.float32", 3, 5)
        with self.assertRaisesRegex(ValueError, "mixed"):
            capture.validate_bias([5], "torch.bfloat16", "torch.float32", 3, 5)


class RecordTests(unittest.TestCase):
    def record(self, **overrides):
        arguments = {"index": 0, "phase": "prefill", "operator": "aten.mm.default",
                     "module": "transformer.h.0.attn.c_attn", "a_shape": [3, 8], "b_shape": [8, 5],
                     "a_stride": [8, 1], "b_stride": [1, 8], "a_dtype": "torch.float32",
                     "b_dtype": "torch.float32", "native_sample_hex": "00" * 32,
                     "attention_paths": {"transformer.h.0.attn"}}
        arguments.update(overrides)
        return capture.matrix_record(**arguments)

    def test_record_basics_and_no_exact_zero_claim(self):
        record = self.record()
        self.assertEqual(record["opcode_class"], 0)
        self.assertIs(record["exact_zero"], False)
        self.assertIs(record["sample_valid"], True)
        self.assertEqual(record["b_stride"], [1, 8])
        self.assertEqual(record["a_dtype"], "torch.float32")
        self.assertEqual(len(record["native_sample_hex"]), 64)
        self.assertEqual(json.loads(json.dumps(record)), record)

    def test_bmm_attention_requires_known_parent_path(self):
        arguments = {"operator": "aten.bmm.default", "a_shape": [2, 3, 8], "b_shape": [2, 8, 5],
                     "a_stride": [24, 8, 1], "b_stride": [40, 5, 1], "phase": "decode"}
        self.assertEqual(self.record(**arguments)["opcode_class"], 1)
        biased = self.record(**{**arguments, "operator": "aten.baddbmm.default"})
        self.assertEqual(biased["opcode_class"], 1)
        self.assertEqual(biased["batch"], 2)
        self.assertEqual(biased["output_shape"], [2, 3, 5])
        self.assertEqual(self.record(**arguments, module="transformer.h.0.attn")["opcode_class"], 1)
        self.assertEqual(self.record(**arguments, module="transformer.h.0.attn_fake")["opcode_class"], 0)
        self.assertEqual(self.record(**arguments, attention_paths=())["opcode_class"], 0)
        self.assertEqual(self.record(operator="aten.addmm.default")["opcode_class"], 0)

    def test_matmul_retains_original_shapes_and_classifies_only_batched_attention(self):
        dense = self.record(operator="aten.matmul.default", a_shape=[2, 4, 3, 8],
                            a_stride=[96, 24, 8, 1])
        self.assertEqual(dense["m"], 24)
        self.assertEqual(dense["batch"], 1)
        self.assertEqual(dense["a_shape"], [2, 4, 3, 8])
        self.assertEqual(dense["output_shape"], [2, 4, 3, 5])
        self.assertEqual(dense["operator"], "aten.matmul.default")
        self.assertEqual(dense["opcode_class"], 0)
        attention = self.record(operator="aten.matmul.default", a_shape=[2, 4, 3, 8],
                                b_shape=[2, 4, 8, 5], a_stride=[96, 24, 8, 1], b_stride=[160, 40, 1, 8])
        self.assertEqual(attention["opcode_class"], 1)
        self.assertEqual(attention["batch"], 8)
        self.assertEqual(attention["output_shape"], [2, 4, 3, 5])
        self.assertEqual(attention["b_stride"], [160, 40, 1, 8])
        self.assertEqual(self.record(operator="aten.matmul.default")["opcode_class"], 0)

    def test_linear_record_keeps_native_weight_shape_and_dense_opcode(self):
        record = self.record(operator="aten.linear.default", a_shape=[2, 3, 8], b_shape=[5, 8],
                             a_stride=[24, 8, 1], b_stride=[8, 1])
        self.assertEqual(record["b_shape"], [5, 8])
        self.assertEqual(record["b_matrix_orientation"], "transposed")
        self.assertEqual(record["output_shape"], [2, 3, 5])
        self.assertEqual(record["opcode_class"], 0)
        self.assertEqual(record["operator"], "aten.linear.default")

    def test_flattened_matmul_sample_uses_logical_m(self):
        record = self.record(operator="aten.matmul.default", a_shape=[4, 1, 2], b_shape=[2, 5],
                             a_stride=[2, 2, 1], b_stride=[5, 1])
        self.assertTrue(record["sample_valid"])
        self.assertEqual(record["m"] * record["k"], 8)

    def test_small_matrix_has_no_sample_even_with_large_batch(self):
        record = self.record(operator="aten.bmm.default", a_shape=[16, 1, 4], b_shape=[16, 4, 5],
                             a_stride=[4, 4, 1], b_stride=[20, 5, 1], native_sample_hex="")
        self.assertIs(record["sample_valid"], False)
        self.assertEqual(record["native_sample_hex"], "")
        self.assertEqual(record["batch"], 16)
        self.assertEqual(record["m"], 1)

    def test_bf16_native_sample_length(self):
        record = self.record(a_dtype="torch.bfloat16", b_dtype="torch.bfloat16", native_sample_hex="ab" * 16)
        self.assertEqual(record["numfmt"], 6)
        self.assertEqual(len(record["native_sample_hex"]), 32)

    def test_bad_records_fail(self):
        for case in ({"index": -1}, {"index": True}, {"index": 100000}, {"phase": "warmup"},
                     {"module": ""}, {"native_sample_hex": ""}, {"native_sample_hex": "gg" * 32},
                     {"native_sample_hex": "00" * 16}):
            with self.subTest(case=case), self.assertRaises(ValueError):
                self.record(**case)

    def test_capture_schema_basics(self):
        source = {"model_id": "example/model", "revision": "a" * 40, "weights": "pretrained",
                  "framework": "pytorch", "framework_version": "test", "transformers_version": "test",
                  "script_sha256": "b" * 64, "weight_sha256": {"model.safetensors": "c" * 64},
                  "config_sha256": "d" * 64}
        execution = {"device": "cpu", "dtype": "fp32", "input_kind": "development-prompt",
                     "prompt_sha256": "e" * 64, "prefill_tokens": 3, "decode_steps": 1, "finite_logits": True}
        artifact = capture.make_artifact(source, execution, [self.record()], {"aten.relu.default": 2})
        self.assertEqual(set(artifact), {"schema", "source", "execution", "records", "other_operators"})
        self.assertEqual(artifact["schema"], "g6lc.policy-capture.v1")
        self.assertEqual(json.loads(json.dumps(artifact)), artifact)
        for broken in ({**source, "weights": "random"}, {**source, "revision": "main"},
                       {**source, "weight_sha256": {}}, {**source, "config_sha256": "bad"}):
            with self.subTest(source=broken), self.assertRaises(ValueError):
                capture.make_artifact(broken, execution, [self.record()], {})
        for records in ([], [self.record(index=1)], [{**self.record(), "exact_zero": True}]):
            with self.subTest(records=records), self.assertRaises(ValueError):
                capture.make_artifact(source, execution, records, {})
        with self.assertRaises(ValueError):
            capture.make_artifact(source, {**execution, "finite_logits": False}, [self.record()], {})


class OfflineAndArgumentsTests(unittest.TestCase):
    def test_import_without_torch_or_transformers(self):
        code = (
            "import sys\n"
            "class NoML:\n"
            "    def find_spec(self, fullname, path=None, target=None):\n"
            "        if fullname.split('.')[0] in ('torch', 'transformers', 'numpy'):\n"
            "            raise ImportError('ML imports forbidden in pure helpers')\n"
            "sys.meta_path.insert(0, NoML())\n"
            "import capture_policy_model\n"
            "assert capture_policy_model.NUMFMTS['torch.float32'] == 7\n"
        )
        result = subprocess.run([sys.executable, "-B", "-c", code], cwd=Path(__file__).parent,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_revision_and_numeric_limits(self):
        self.assertEqual(capture.revision_arg("A" * 40), "a" * 40)
        for value in ("main", "v1.0", "a" * 39, "g" * 40, "a" * 41):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                capture.revision_arg(value)
        parse = capture.bounded_int(1, 32)
        self.assertEqual(parse("32"), 32)
        for value in ("0", "33", "-1", "1.5", "garbage"):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                parse(value)

    def test_explicit_cli_and_defaults(self):
        args = capture.parser().parse_args(["--model-id", "example/model", "--revision", "a" * 40,
                                           "--cache-dir", "cache", "--out", "capture.json"])
        self.assertEqual(args.dtype, "fp32")
        self.assertEqual(args.prefill_tokens, 32)
        self.assertEqual(args.decode_steps, 4)
        self.assertIsNone(args.prompt)
        self.assertEqual(args.max_records, 20000)

    def test_snapshot_resolution_and_hashes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            snapshot = root / "models--example--model" / "snapshots" / ("a" * 40)
            snapshot.mkdir(parents=True)
            (snapshot / "config.json").write_text("{}", encoding="utf-8")
            weight = snapshot / "model.safetensors"
            weight.write_bytes(b"fixture bytes only; not a model")
            resolved, config, weights = capture.snapshot_files(root, "example/model", "a" * 40)
            self.assertEqual(resolved, snapshot)
            self.assertEqual(config, snapshot / "config.json")
            self.assertEqual(weights, [weight])
            self.assertEqual(capture.sha256_file(weight), hashlib.sha256(weight.read_bytes()).hexdigest())
            weight.unlink()
            with self.assertRaisesRegex(ValueError, "safetensors"):
                capture.snapshot_files(root, "example/model", "a" * 40)
            shard = snapshot / "model-00001-of-00001.safetensors"
            shard.write_bytes(b"fixture shard")
            index = snapshot / "model.safetensors.index.json"
            index.write_text(json.dumps({"weight_map": {"a": shard.name, "b": shard.name}}), encoding="utf-8")
            self.assertEqual(capture.snapshot_files(root, "example/model", "a" * 40)[2], [shard])
            index.write_text(json.dumps({"weight_map": {"a": "../other.safetensors"}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "unsafe"):
                capture.snapshot_files(root, "example/model", "a" * 40)
            index.write_text(json.dumps({"weight_map": {"a": "missing.safetensors"}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "missing"):
                capture.snapshot_files(root, "example/model", "a" * 40)
            index.write_text("[]", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "index object"):
                capture.snapshot_files(root, "example/model", "a" * 40)
            (snapshot / "adapter_config.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "adapter"):
                capture.snapshot_files(root, "example/model", "a" * 40)

    def test_snapshot_cannot_fall_back_to_another_revision_or_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            for model_id, revision in (("example/model", "a" * 40), ("../model", "a" * 40),
                                       ("example/model", "main"), ("x/y/z", "a" * 40)):
                with self.subTest(model_id=model_id, revision=revision), self.assertRaises(ValueError):
                    capture.snapshot_files(temporary, model_id, revision)

    def test_token_digest_is_stable_without_recording_tokens(self):
        self.assertEqual(capture.digest_tokens([1, 2, 3]), hashlib.sha256(b"[1,2,3]").hexdigest())
        self.assertNotEqual(capture.digest_tokens([1, 2, 3]), capture.digest_tokens([1, 2, 4]))


if __name__ == "__main__":
    unittest.main()
