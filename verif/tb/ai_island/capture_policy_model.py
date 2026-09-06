import argparse
from collections import Counter
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sys


SCHEMA = "g6lc.policy-capture.v1"
DETAIL_SCHEMA = "g6lc.policy-capture.details.v1"
BUILTIN_PROMPT = (
    "This is a synthetic development prompt for measuring matrix execution. "
    "Describe how a small computer reads instructions and adds two numbers."
)
NUMFMTS = {"torch.float32": 7, "torch.bfloat16": 6}
MATRIX_OPS = {"aten.mm.default", "aten.addmm.default", "aten.bmm.default", "aten.matmul.default",
              "aten.linear.default", "aten.baddbmm.default"}
ATTENTION_CLASSES = frozenset({
    "GPT2Attention", "GPTNeoSelfAttention", "GPTNeoXAttention", "OPTAttention",
    "BloomAttention", "LlamaAttention", "MistralAttention", "MixtralAttention",
    "Qwen2Attention", "GemmaAttention", "Gemma2Attention", "PhiAttention",
    "Phi3Attention", "FalconAttention", "BartAttention", "GPTBigCodeAttention",
    "OlmoAttention", "StableLmAttention",
})


def require(condition, message):
    if not condition:
        raise ValueError(message)


def append_walk_event(walk, operator, module, matrix_index=None, max_events=250000):
    require(type(max_events) is int and 1 <= max_events <= 1000000, "invalid operator walk limit")
    require(len(walk) < max_events, "operator walk limit reached; capture aborted, not truncated")
    require(isinstance(operator, str) and operator and isinstance(module, str) and module,
            "invalid operator walk identity")
    event = {"index": len(walk), "operator": operator, "module": module,
             "kind": "other" if matrix_index is None else "matrix"}
    if matrix_index is not None:
        require(type(matrix_index) is int and 0 <= matrix_index < 100000, "invalid matrix record link")
        event["matrix_index"] = matrix_index
    walk.append(event)


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def digest_tokens(tokens):
    return hashlib.sha256(json.dumps(tokens, separators=(",", ":")).encode("ascii")).hexdigest()


def revision_arg(value):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", value):
        raise argparse.ArgumentTypeError("revision must be an immutable 40-hex commit SHA")
    return value.lower()


def bounded_int(low, high):
    def parse(value):
        try:
            result = int(value)
        except ValueError as exc:
            raise argparse.ArgumentTypeError("expected an integer") from exc
        if not low <= result <= high:
            raise argparse.ArgumentTypeError(f"expected integer in {low}..{high}")
        return result
    return parse


def parser():
    result = argparse.ArgumentParser(description="Capture actual offline pretrained CPU matrix execution; no downloads or installs.")
    result.add_argument("--model-id", required=True)
    result.add_argument("--revision", required=True, type=revision_arg)
    result.add_argument("--cache-dir", required=True, type=Path)
    result.add_argument("--out", required=True, type=Path)
    result.add_argument("--prompt", default=None)
    result.add_argument("--prefill-tokens", type=bounded_int(1, 256), default=32)
    result.add_argument("--decode-steps", type=bounded_int(1, 32), default=4)
    result.add_argument("--dtype", choices=("fp32", "bf16"), default="fp32")
    result.add_argument("--max-records", type=bounded_int(1, 100000), default=20000)
    result.add_argument("--max-events", type=bounded_int(1, 1000000), default=250000)
    result.add_argument("--threads", type=bounded_int(1, 32), default=1)
    return result


def tensor_geometry(shape, stride, name):
    require(isinstance(shape, (tuple, list)) and isinstance(stride, (tuple, list)),
            f"{name}: shape and stride must be sequences")
    require(len(shape) == len(stride), f"{name}: shape/stride rank mismatch")
    require(all(type(d) is int and 0 < d <= 2**31 - 1 for d in shape),
            f"{name}: dimensions must be positive bounded integers")
    require(all(type(s) is int and s >= 0 for s in stride), f"{name}: invalid stride")
    require(all(d == 1 or s != 0 for d, s in zip(shape, stride)),
            f"{name}: broadcast/zero-stride matrix operands unsupported")


def matrix_geometry(operator, a_shape, b_shape, a_stride, b_stride, a_dtype, b_dtype):
    require(operator in MATRIX_OPS, f"unsupported matrix operator: {operator}")
    tensor_geometry(a_shape, a_stride, "A")
    tensor_geometry(b_shape, b_stride, "B")
    require(isinstance(a_dtype, str) and isinstance(b_dtype, str), "matrix dtypes must be explicit strings")
    require(a_dtype == b_dtype, f"unsupported mixed matrix dtypes: {a_dtype}, {b_dtype}")
    require(a_dtype in NUMFMTS, f"unsupported matrix dtype: {a_dtype}")
    require(2 <= len(a_shape) <= 16 and 2 <= len(b_shape) <= 16, "matrix ranks must be 2..16; vectors unsupported")
    if operator == "aten.linear.default":
        require(len(b_shape) == 2 and a_shape[-1] == b_shape[-1], "linear requires a matching rank-two [n,k] weight")
        return {"m": math.prod(a_shape[:-1]), "n": b_shape[0], "k": a_shape[-1],
                "batch": 1, "numfmt": NUMFMTS[a_dtype]}
    if operator != "aten.matmul.default":
        rank = 3 if operator in ("aten.bmm.default", "aten.baddbmm.default") else 2
        require(len(a_shape) == len(b_shape) == rank, f"{operator}: expected rank {rank}, no implicit broadcasting")
    require(a_shape[-1] == b_shape[-2], "matrix contraction dimensions differ")
    batch = 1
    m = a_shape[-2]
    if len(b_shape) == 2:
        m = math.prod(a_shape[:-1])
    else:
        require(len(a_shape) >= 3 and tuple(a_shape[:-2]) == tuple(b_shape[:-2]),
                "matrix batch broadcast unsupported; leading batch dimensions must match exactly")
        batch = math.prod(a_shape[:-2])
    return {"m": m, "n": b_shape[-1], "k": a_shape[-1],
            "batch": batch, "numfmt": NUMFMTS[a_dtype]}


def validate_bias(shape, dtype, matrix_dtype, m, n, batch=None):
    require(dtype == matrix_dtype, "unsupported mixed matrix bias dtype")
    output = (m, n) if batch is None else (batch, m, n)
    require(isinstance(shape, (tuple, list)) and len(shape) <= len(output),
            "unsupported matrix bias rank/broadcast")
    require(all(type(d) is int and d > 0 for d in shape), "invalid matrix bias dimensions")
    target = output[len(output) - len(shape):]
    require(all(d == 1 or d == t for d, t in zip(shape, target)),
            "unsupported addmm bias broadcast")


def matrix_record(index, phase, operator, module, a_shape, b_shape, a_stride, b_stride,
                  a_dtype, b_dtype, native_sample_hex, attention_paths=()):
    require(type(index) is int and 0 <= index < 100000, "invalid record index")
    require(phase in ("prefill", "decode"), "invalid execution phase")
    require(isinstance(module, str) and 0 < len(module) <= 1024, "invalid parent module path")
    geometry = matrix_geometry(operator, a_shape, b_shape, a_stride, b_stride, a_dtype, b_dtype)
    require(isinstance(native_sample_hex, str), "invalid native sample")
    valid = geometry["m"] * geometry["k"] >= 8
    sample_bytes = 32 if geometry["numfmt"] == 7 else 16
    require((valid and re.fullmatch(r"[0-9a-f]{" + str(2 * sample_bytes) + r"}", native_sample_hex))
            or (not valid and native_sample_hex == ""), "native sample length/geometry mismatch")
    batched_attention = operator in ("aten.bmm.default", "aten.baddbmm.default") or (
        operator == "aten.matmul.default" and len(a_shape) >= 3 and len(b_shape) >= 3)
    attention = batched_attention and any(
        module == path or module.startswith(path + ".") for path in attention_paths)
    return {"index": index, "phase": phase, "operator": operator, "module": module,
            **geometry, "opcode_class": int(attention), "a_shape": list(a_shape),
            "b_shape": list(b_shape), "a_stride": list(a_stride), "b_stride": list(b_stride),
            "a_dtype": a_dtype, "b_dtype": b_dtype, "output_shape": list(a_shape[:-1]) + [geometry["n"]],
            "b_matrix_orientation": "transposed" if operator == "aten.linear.default" else "normal",
            "native_sample_hex": native_sample_hex,
            "sample_valid": valid, "exact_zero": False}


def snapshot_files(cache_dir, model_id, revision):
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,95}(?:/[A-Za-z0-9][A-Za-z0-9_.-]{0,95})?", model_id)
            and ".." not in model_id, "model-id must be a bounded Hugging Face repository ID, not a path")
    require(re.fullmatch(r"[0-9a-f]{40}", revision), "revision must be a lowercase immutable commit SHA")
    snapshot = Path(cache_dir).absolute() / ("models--" + model_id.replace("/", "--")) / "snapshots" / revision
    require(snapshot.is_dir(), "pinned snapshot is not cached; provision it separately (capture never downloads)")
    require(not (snapshot / "adapter_config.json").exists(), "adapter snapshots unsupported; require complete pretrained weights")
    config = snapshot / "config.json"
    require(config.is_file(), "cached config.json missing")
    single = snapshot / "model.safetensors"
    index = snapshot / "model.safetensors.index.json"
    if single.is_file():
        weights = [single]
    else:
        require(index.is_file(), "cached pretrained safetensors weights missing")
        with index.open(encoding="utf-8") as stream:
            data = json.load(stream)
        require(isinstance(data, dict), "invalid safetensors weight index object")
        mapping = data.get("weight_map")
        require(isinstance(mapping, dict) and mapping, "invalid safetensors weight index")
        names = list(mapping.values())
        require(all(isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+\.safetensors", name)
                    and ".." not in name for name in names), "unsafe safetensors shard name")
        weights = [snapshot / name for name in sorted(set(names))]
        require(all(path.is_file() for path in weights), "cached safetensors shard missing")
    return snapshot, config, weights


def make_artifact(source, execution, records, other_operators):
    require(records, "no matrix execution captured")
    require(execution.get("finite_logits") is True, "nonfinite or unchecked logits")
    require(source.get("weights") == "pretrained" and source.get("framework") == "pytorch",
            "capture requires pretrained PyTorch provenance")
    require(re.fullmatch(r"[0-9a-f]{40}", source.get("revision", "")), "invalid source revision")
    for key in ("script_sha256", "config_sha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", source.get(key, "")), f"invalid {key}")
    hashes = source.get("weight_sha256", {})
    require(isinstance(hashes, dict) and hashes and all(
        isinstance(name, str) and name.endswith(".safetensors") and re.fullmatch(r"[0-9a-f]{64}", digest)
        for name, digest in hashes.items()), "invalid pretrained weight hashes")
    require(all(record.get("index") == i and record.get("exact_zero") is False
                for i, record in enumerate(records)), "invalid record order or exact-zero claim")
    require(all(isinstance(key, str) and type(value) is int and value > 0
                for key, value in other_operators.items()), "invalid other operator counts")
    return {"schema": SCHEMA, "source": source, "execution": execution,
            "records": records, "other_operators": dict(sorted(other_operators.items()))}


def capture(args):
    prompt = BUILTIN_PROMPT if args.prompt is None else args.prompt
    require(isinstance(prompt, str) and 0 < len(prompt.encode("utf-8")) <= 16384,
            "prompt must contain 1..16384 UTF-8 bytes")
    require(args.out.parent.is_dir(), "output parent directory must already exist")
    require(not args.out.exists(), "output already exists; choose a new output file")
    snapshot, config_path, weight_paths = snapshot_files(args.cache_dir, args.model_id, args.revision)
    for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY", "DO_NOT_TRACK"):
        os.environ[key] = "1"
    os.environ["HF_HOME"] = str(args.cache_dir.absolute().parent)
    os.environ["HF_HUB_CACHE"] = str(args.cache_dir.absolute())
    os.environ["HF_TOKEN_PATH"] = str(args.cache_dir.absolute().parent / "token")
    os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
    os.environ["TOKENIZERS_PARALLELISM"] = "false"
    try:
        import torch
        import transformers
        from torch.utils._python_dispatch import TorchDispatchMode
        from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer
    except ImportError as exc:
        raise RuntimeError("capture requires a separately provisioned torch/transformers/safetensors environment; nothing was installed") from exc

    torch.set_num_threads(args.threads)
    torch.manual_seed(0)
    torch.use_deterministic_algorithms(True)
    dtype = {"fp32": torch.float32, "bf16": torch.bfloat16}[args.dtype]
    config_hash = sha256_file(config_path)
    weight_hashes = {path.name: sha256_file(path) for path in weight_paths}
    common = {"local_files_only": True, "trust_remote_code": False, "revision": args.revision,
              "token": False, "cache_dir": str(args.cache_dir.absolute())}
    config = AutoConfig.from_pretrained(str(snapshot), **common)
    require(not getattr(config, "is_encoder_decoder", False), "only decoder-only causal LMs are supported")
    require(not getattr(config, "quantization_config", None), "quantized model configurations unsupported")
    tokenizer = AutoTokenizer.from_pretrained(str(snapshot), **common)
    model, loading = AutoModelForCausalLM.from_pretrained(
        str(snapshot), config=config, torch_dtype=dtype, use_safetensors=True,
        attn_implementation="eager", output_loading_info=True, **common)
    require(not any(loading.get(key) for key in ("missing_keys", "mismatched_keys", "error_msgs")),
            "pretrained load incomplete; refusing randomly initialized or mismatched parameters")
    model = model.to(device="cpu").eval()
    require(all(p.device.type == "cpu" and (not p.is_floating_point() or p.dtype == dtype)
                for p in model.parameters()), "loaded model device/dtype mismatch")
    require(getattr(model.config, "_attn_implementation", None) == "eager", "model did not enable eager attention")
    encoded = tokenizer(prompt, return_tensors="pt", truncation=True, max_length=args.prefill_tokens,
                        return_attention_mask=True)
    input_ids = encoded["input_ids"]
    mask = encoded["attention_mask"]
    require(input_ids.ndim == 2 and input_ids.shape[0] == 1 and 0 < input_ids.shape[1] <= args.prefill_tokens,
            "tokenizer produced unsupported input geometry")
    prefill_tokens = int(input_ids.shape[1])
    context_limit = getattr(config, "max_position_embeddings", getattr(config, "n_positions", None))
    if isinstance(context_limit, int):
        require(prefill_tokens + args.decode_steps <= context_limit, "prefill plus decode exceeds model context limit")
    stack = []
    handles = []
    attention_paths = set()
    records = []
    operator_walk = []
    others = Counter()
    phase = "prefill"

    def enter(path):
        def hook(module, inputs):
            stack.append(path)
        return hook

    def leave(path):
        def hook(module, inputs, output):
            require(stack and stack[-1] == path, "module hook stack mismatch")
            stack.pop()
        return hook

    def sample_a(a, geometry):
        if geometry["m"] * geometry["k"] < 8:
            return ""
        if a.is_contiguous():
            first = a.view(-1)[:8]
        else:
            values = []
            for offset in range(8):
                indices = [0] * a.ndim
                for axis in range(a.ndim - 1, -1, -1):
                    indices[axis] = offset % a.shape[axis]
                    offset //= a.shape[axis]
                values.append(a[tuple(indices)])
            first = torch.stack(values)
        return bytes(first.contiguous().view(torch.uint8).tolist()).hex()

    class MatrixCapture(TorchDispatchMode):
        def __torch_dispatch__(self, func, types, positional=(), kwargs=None):
            kwargs = {} if kwargs is None else kwargs
            operator = str(func)
            if operator not in MATRIX_OPS:
                name = func._schema.name.split("::")[-1]
                require(name not in {"mm", "addmm", "bmm", "baddbmm", "addbmm", "mv", "addmv", "dot", "vdot"}
                        and not name.endswith(("_mm", "_addmm", "_bmm"))
                        and not any(part in name for part in ("scaled_mm", "sparse", "attention", "convolution", "matmul", "linear")),
                        f"unsupported matrix/fused operator: {operator}; eager mm/addmm/bmm/baddbmm/matmul/linear required")
                result = func(*positional, **kwargs)
                others[operator] += 1
                append_walk_event(operator_walk, operator, stack[-1] if stack else "<unattributed>",
                                  max_events=args.max_events)
                return result
            require(len(records) < args.max_records, "matrix record limit reached; capture aborted, not truncated")
            require(stack, "matrix execution has no parent module provenance")
            names = ("self", "mat1", "mat2") if operator == "aten.addmm.default" else (
                "self", "other" if operator == "aten.matmul.default" else "mat2")
            if operator == "aten.baddbmm.default":
                names = ("self", "batch1", "batch2")
            if operator == "aten.linear.default":
                names = ("input", "weight")
            operands = [positional[i] if i < len(positional) else kwargs.get(name) for i, name in enumerate(names)]
            a, b = operands[-2:]
            require(isinstance(a, torch.Tensor) and isinstance(b, torch.Tensor), "missing matrix tensor operands")
            require(a.device.type == b.device.type == "cpu" and a.layout == b.layout == torch.strided,
                    "only CPU strided matrices supported")
            geometry = matrix_geometry(operator, list(a.shape), list(b.shape), list(a.stride()),
                                       list(b.stride()), str(a.dtype), str(b.dtype))
            extra = {}
            bias = None
            if operator in ("aten.addmm.default", "aten.baddbmm.default"):
                bias = operands[0]
                require(isinstance(bias, torch.Tensor), "missing matrix bias")
            elif operator == "aten.linear.default":
                bias = positional[2] if len(positional) > 2 else kwargs.get("bias")
                require(bias is None or (isinstance(bias, torch.Tensor) and list(bias.shape) == [geometry["n"]]),
                        "unsupported linear bias geometry")
            if bias is not None:
                require(bias.device.type == "cpu" and bias.layout == torch.strided, "unsupported bias device/layout")
                validate_bias(list(bias.shape), str(bias.dtype), str(a.dtype), geometry["m"], geometry["n"],
                              batch=geometry["batch"] if operator == "aten.baddbmm.default" else None)
                alpha, beta = kwargs.get("alpha", 1), kwargs.get("beta", 1)
                require(all(type(x) in (int, float) and math.isfinite(x) for x in (alpha, beta)),
                        "unsupported matrix scaling")
                outputs = geometry["batch"] * geometry["m"] * geometry["n"]
                extra = {"bias_shape": list(bias.shape), "bias_stride": list(bias.stride()),
                         "bias_dtype": str(bias.dtype), "alpha": alpha, "beta": beta,
                         "bias_in_matrix_macs": False, "bias_output_additions": outputs if beta != 0 else 0,
                         "alpha_output_multiplications": outputs if alpha not in (0, 1) else 0,
                         "beta_output_multiplications": outputs if beta not in (0, 1) else 0}
            record = matrix_record(len(records), phase, operator, stack[-1], list(a.shape), list(b.shape),
                                   list(a.stride()), list(b.stride()), str(a.dtype), str(b.dtype),
                                   sample_a(a, geometry), attention_paths)
            result = func(*positional, **kwargs)
            require(list(result.shape) == record["output_shape"] and result.dtype == a.dtype,
                    "unexpected matrix output geometry/dtype")
            records.append({**record, **extra, "output_shape": list(result.shape),
                            "output_stride": list(result.stride()), "output_dtype": str(result.dtype)})
            append_walk_event(operator_walk, operator, stack[-1], matrix_index=record["index"],
                              max_events=args.max_events)
            return result

    generated = []

    def next_token(output):
        require(torch.isfinite(output.logits).all().item(), "model produced nonfinite logits")
        require(output.past_key_values is not None, "model did not return a decode cache")
        token = output.logits[:, -1, :].argmax(dim=-1, keepdim=True)
        generated.append(int(token.item()))
        return token

    try:
        for name, module in model.named_modules():
            path = name or "<root>"
            if type(module).__module__.startswith("transformers.models.") and type(module).__name__ in ATTENTION_CLASSES:
                attention_paths.add(path)
            handles.append(module.register_forward_pre_hook(enter(path)))
            handles.append(module.register_forward_hook(leave(path), always_call=True))
        with torch.inference_mode():
            with MatrixCapture():
                output = model(input_ids=input_ids, attention_mask=mask, use_cache=True, return_dict=True)
            token = next_token(output)
            phase = "decode"
            for step in range(args.decode_steps):
                mask = torch.cat((mask, mask.new_ones((1, 1))), dim=1)
                with MatrixCapture():
                    output = model(input_ids=token, attention_mask=mask, past_key_values=output.past_key_values,
                                   use_cache=True, return_dict=True)
                token = next_token(output)
    finally:
        for handle in handles:
            handle.remove()
    require(not stack, "unbalanced module provenance hooks")
    require(any(r["phase"] == "prefill" for r in records) and any(r["phase"] == "decode" for r in records),
            "both prefill and cache decode matrix execution required")
    require(config_hash == sha256_file(config_path) and weight_hashes == {path.name: sha256_file(path) for path in weight_paths},
            "cached pretrained files changed during capture")
    source = {"model_id": args.model_id, "revision": args.revision, "weights": "pretrained",
              "framework": "pytorch", "framework_version": torch.__version__,
              "transformers_version": transformers.__version__, "script_sha256": sha256_file(__file__),
              "weight_sha256": weight_hashes, "config_sha256": config_hash,
              "details_schema": DETAIL_SCHEMA, "revision_source": "cached-snapshot-commit-sha",
              "architectures": getattr(config, "architectures", None), "model_type": config.model_type,
              "model_dtype": str(dtype), "attention_module_paths": sorted(attention_paths)}
    execution = {"device": "cpu", "dtype": args.dtype, "input_kind": "development-prompt",
                 "prompt_sha256": hashlib.sha256(prompt.encode("utf-8")).hexdigest(),
                 "prefill_tokens": prefill_tokens, "decode_steps": args.decode_steps, "finite_logits": True,
                 "details_schema": DETAIL_SCHEMA, "inputsyntheticdevelopmentprompt": args.prompt is None,
                 "prefill_token_limit": args.prefill_tokens, "input_token_ids_sha256": digest_tokens(input_ids.tolist()),
                 "output_token_ids_sha256": digest_tokens(generated), "output_token_count": len(generated),
                 "decode_semantics": "decode_steps cached single-token forwards after prefill; output includes each forward's greedy prediction",
                 "attention_backend": "eager", "sample_order": "first-eight-logical-row-major-A-elements",
                 "sample_byteorder": sys.byteorder, "threads": args.threads, "seed": 0,
                 "deterministic_algorithms": True, "other_operator_scope": "model-forward-only; excludes sampling and driver",
                 "matrix_mac_formula": "batch*m*n*k; excludes addmm/baddbmm/linear bias and alpha/beta scaling",
                 "bias_cost_convention": "semantic per-output additions/scales, not measured kernel instructions",
                 "linear_weight_convention": "native B shape [n,k], transposed for contraction; original aten.linear dispatched once",
                 "max_records": args.max_records}
    artifact = make_artifact(source, execution, records, others)
    artifact["operator_walk"] = operator_walk
    execution["operator_walk_scope"] = "ordered dispatched operators; matrix links exact, no measured service times"
    execution["max_events"] = args.max_events
    return artifact


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        artifact = capture(args)
        with args.out.open("x", encoding="utf-8", newline="\n") as stream:
            json.dump(artifact, stream, indent=2, sort_keys=True, allow_nan=False)
            stream.write("\n")
    except (ValueError, RuntimeError, OSError) as exc:
        print(f"capture failed: {exc}", file=sys.stderr)
        return 1
    print(f"captured {len(artifact['records'])} matrix operations to {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
