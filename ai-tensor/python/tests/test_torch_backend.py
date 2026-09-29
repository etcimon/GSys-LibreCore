# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""Module-level PyTorch offload (`ai_tensor.torch_backend`) against the virtual backends.

Everything here is virtual-execution evidence of the descriptor contract; nothing is an
RTL or silicon result.
"""

import pytest

torch = pytest.importorskip("torch")
from torch import nn  # noqa: E402

from ai_tensor.device import Caps, Device  # noqa: E402
from ai_tensor import torch_backend as tb  # noqa: E402


def _fp32_device(**caps):
    return Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, **caps) if caps else None)


def test_fp32_linear_matches_torch_and_is_offloaded():
    torch.manual_seed(0)
    lin = nn.Linear(6, 5)
    x = torch.randn(3, 4, 6)
    layer = tb.AiTensorLinear(lin, _fp32_device(), allow_fallback=False)
    y = layer(x)
    assert y.shape == (3, 4, 5)
    assert torch.allclose(y, lin(x), atol=1e-5, rtol=1e-5)
    assert layer.stats.offloaded_calls == 1 and layer.stats.fallback_calls == 0
    assert layer.stats.offloaded_blocks == 1


def test_offload_actually_executes_the_prepacked_weight():
    # Corruption control: mutate the prepacked bytes, not the torch parameter. If the
    # output changes, the island path ran; if torch had answered, it could not change.
    torch.manual_seed(1)
    lin = nn.Linear(4, 3, bias=False)
    layer = tb.AiTensorLinear(lin, _fp32_device(), allow_fallback=False)
    x = torch.randn(2, 4)
    before = layer(x)
    packed = bytearray(layer._w_bytes)
    packed[0] ^= 0x40
    layer._w_bytes = bytes(packed)
    after = layer(x)
    assert not torch.equal(before, after)
    assert torch.allclose(before, lin(x), atol=1e-5)


def test_int8_dynamic_is_exact_against_integer_reference_and_splits_k():
    torch.manual_seed(2)
    lin = nn.Linear(10, 3, bias=True)
    # AccTile k=4 forces three K blocks; integer accumulation must stay exact.
    dev = Device("sim", caps=Caps(acc_tile_m=8, acc_tile_n=2, acc_tile_k=4, dtype_mask=1))
    layer = tb.AiTensorLinear(lin, dev, quant="int8-dynamic", allow_fallback=False, group_k=4)
    x = torch.randn(5, 10)
    y = layer(x)
    # Independent reference with the same per-(row, K-group) quantizers.
    w = lin.weight.detach()
    ref = torch.zeros(5, 3)
    for t0 in range(0, 10, 4):
        wb, xb = w[:, t0:t0 + 4], x[:, t0:t0 + 4]
        ws = wb.abs().amax(dim=1) / 127.0
        xs = xb.abs().amax(dim=1) / 127.0
        wq = torch.round(wb / ws[:, None]).clamp(-127, 127).to(torch.int32)
        xq = torch.round(xb / xs[:, None]).clamp(-127, 127).to(torch.int32)
        ref += (xq @ wq.T).to(torch.float32) * xs[:, None] * ws[None, :]
    ref += lin.bias.detach()
    assert torch.allclose(y, ref, atol=1e-6)
    # 1 M block x 2 N blocks x 3 K blocks
    assert layer.stats.offloaded_blocks == 6
    # Quantization error is real and bounded, not hidden.
    assert (y - lin(x)).abs().max() < 0.2


def test_float_k_split_chains_through_accumulate_bit_exactly():
    # K=8 over AccTile K=4 on a device that grants accmode 01: two chained blocks must equal
    # the single ordered reduction of the full row, bit for bit.
    torch.manual_seed(7)
    lin = nn.Linear(8, 3, bias=False)
    x = torch.randn(4, 8)
    full = tb.AiTensorLinear(lin, _fp32_device(), allow_fallback=False)(x)
    split_dev = Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, accumulate=True, acc_tile_k=4))
    layer = tb.AiTensorLinear(lin, split_dev, allow_fallback=False)
    y = layer(x)
    assert torch.equal(y, full)
    assert layer.stats.offloaded_blocks == 2 and layer.stats.fallback_calls == 0
    # A device without the grant must refuse rather than re-sum in the host.
    with pytest.raises(ValueError, match="not granted"):
        Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, accumulate=False)).gemm_native(
            bytes(16), bytes(16), 1, 1, 4, 7, c_init=bytes(4))


def test_float_k_split_is_refused_and_falls_back_explicitly():
    lin = nn.Linear(8, 2)
    dev = Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, accumulate=False, acc_tile_k=4))
    layer = tb.AiTensorLinear(lin, dev)
    x = torch.randn(3, 8)
    y = layer(x)
    assert torch.allclose(y, lin(x))
    assert layer.stats.fallback_calls == 1 and layer.stats.offloaded_calls == 0
    assert "accumulate grant" in next(iter(layer.stats.fallback_reasons))
    strict = tb.AiTensorLinear(lin, dev, allow_fallback=False)
    with pytest.raises(RuntimeError, match="island refused"):
        strict(x)


def test_ungranted_format_falls_back_with_reason():
    lin = nn.Linear(4, 4)  # fp32 against an INT-only grant
    layer = tb.AiTensorLinear(lin, Device("sim", caps=Caps(dtype_mask=1)))
    layer(torch.randn(2, 4))
    assert layer.stats.fallback_calls == 1
    assert "not granted" in next(iter(layer.stats.fallback_reasons))


def test_replace_linear_swaps_a_model_and_reports():
    torch.manual_seed(3)
    model = nn.Sequential(nn.Linear(6, 8), nn.ReLU(), nn.Linear(8, 4), nn.Linear(4, 2))
    x = torch.randn(3, 6)
    ref = model(x)
    report = tb.replace_linear(model, _fp32_device(), skip=("2",))
    assert report.replaced == ["0", "2"] or report.replaced == ["0", "3"]
    assert isinstance(model[0], tb.AiTensorLinear) and isinstance(model[2], nn.Linear)
    assert "2" in report.skipped
    y = model(x)
    assert torch.allclose(y, ref, atol=1e-5)
    assert report.stats.offloaded_calls == 2 and report.stats.fallback_calls == 0


def test_transformers_bert_layer_runs_through_island_linears():
    transformers = pytest.importorskip("transformers")
    from transformers import BertConfig, BertModel

    torch.manual_seed(4)
    cfg = BertConfig(hidden_size=16, num_attention_heads=2, intermediate_size=32,
                     num_hidden_layers=1, vocab_size=64, max_position_embeddings=8)
    model = BertModel(cfg).eval()
    ids = torch.randint(0, 64, (1, 5))
    with torch.no_grad():
        ref = model(input_ids=ids).last_hidden_state
    report = tb.replace_linear(model, _fp32_device())
    # q/k/v/attention-output/intermediate/output/pooler
    assert len(report.replaced) >= 7
    with torch.no_grad():
        out = model(input_ids=ids).last_hidden_state
    assert torch.allclose(out, ref, atol=1e-4, rtol=1e-4)
    assert report.stats.fallback_calls == 0
    assert report.stats.offloaded_calls >= 6


def test_conv2d_im2col_matches_torch_and_grouped_falls_back():
    torch.manual_seed(5)
    conv = nn.Conv2d(3, 4, kernel_size=3, stride=2, padding=1)
    x = torch.randn(2, 3, 7, 6)
    layer = tb.AiTensorConv2d(conv, _fp32_device(), allow_fallback=False)
    y = layer(x)
    assert y.shape == conv(x).shape == (2, 4, 4, 3)
    assert torch.allclose(y, conv(x), atol=1e-5, rtol=1e-5)
    assert layer.stats.offloaded_calls == 1
    grouped = tb.AiTensorConv2d(nn.Conv2d(4, 4, 3, groups=2), _fp32_device())
    grouped(torch.randn(1, 4, 5, 5))
    assert grouped.stats.fallback_calls == 1
    # A tiny UNet-ish block: conv -> linear timestep projection, swapped as a whole.
    model = nn.Sequential(nn.Conv2d(2, 3, 3, padding=1), nn.SiLU(), nn.Conv2d(3, 2, 1))
    xin = torch.randn(1, 2, 4, 4)
    ref = model(xin)
    report = tb.replace_linear(model, _fp32_device(), conv2d=True)
    assert report.replaced == ["0", "2"]
    assert torch.allclose(model(xin), ref, atol=1e-5)


def test_transformers_gpt2_greedy_decode_runs_through_island_projections():
    """An autoregressive decode loop (KV cache, M=1 per step) with every GPT-2 Conv1D
    projection folded onto the island. Random weights: this qualifies the integration
    path, not model quality."""
    pytest.importorskip("transformers")
    from transformers import GPT2Config, GPT2LMHeadModel

    torch.manual_seed(6)
    cfg = GPT2Config(n_embd=16, n_head=2, n_layer=2, n_positions=16, vocab_size=50)
    model = GPT2LMHeadModel(cfg).eval()
    ids = torch.randint(0, 50, (1, 3))
    with torch.no_grad():
        ref = model.generate(ids, max_new_tokens=4, do_sample=False, pad_token_id=0)
    report = tb.replace_linear(model, _fp32_device())
    # c_attn/c_proj per block (attention) + c_fc/c_proj (mlp) = 4 per layer, 2 layers.
    conv1d = [n for n in report.replaced if "c_attn" in n or "c_proj" in n or "c_fc" in n]
    assert len(conv1d) == 8, report.replaced
    with torch.no_grad():
        out = model.generate(ids, max_new_tokens=4, do_sample=False, pad_token_id=0)
    assert torch.equal(out, ref)
    assert report.stats.fallback_calls == 0
    # prefill (3 tokens) + 3 cached single-token steps, every step through the island
    assert report.stats.offloaded_calls >= 8 * 4


def test_custom_op_registration_is_optional_and_correct():
    if not tb.register_custom_op(_fp32_device()):
        pytest.skip("torch.library.custom_op unavailable")
    a = torch.randn(3, 4)
    b = torch.randn(2, 4)
    y = torch.ops.ai_tensor.gemm(a, b)
    assert torch.allclose(y, a @ b.T, atol=1e-5)


@pytest.mark.parametrize("quant,fmt", [("fp8-e4m3", 3), ("fp8-e5m2", 4)])
def test_fp8_grouped_linear_matches_dequantized_reference(quant, fmt):
    from ai_tensor.numfmt import decode_bits
    torch.manual_seed(3)
    lin = nn.Linear(12, 4, bias=True)
    dev = Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, accumulate=True, acc_tile_k=4))
    layer = tb.AiTensorLinear(lin, dev, quant=quant, allow_fallback=False, group_k=4)
    assert layer.numfmt == fmt and layer.weight_bytes() == 12 * 4
    x = torch.randn(3, 12) * 4
    y = layer(x)
    # Reference: decode the layer's own weight codes, quantize x with the same rule, sum groups.
    codes, w_scale = layer._w_i8, layer.w_scale
    a_codes, a_scale = layer._quantize_groups(x)
    ref = torch.zeros(3, 4)
    for g, t0 in enumerate(range(0, 12, 4)):
        wq = torch.tensor([[decode_bits(int(c), fmt) for c in row] for row in codes[:, t0:t0 + 4].tolist()])
        aq = torch.tensor([[decode_bits(int(c), fmt) for c in row] for row in a_codes[:, t0:t0 + 4].tolist()])
        ref += (aq.double() @ wq.double().T).float() * a_scale[:, g][:, None] * w_scale[:, g][None, :]
    ref += lin.bias.detach()
    assert torch.allclose(y, ref, rtol=1e-5, atol=1e-5)
    # The quantized layer tracks the float layer at FP8 precision, not exactly.
    assert (y - lin(x)).abs().max() < 0.6 * lin(x).abs().max()
    assert layer.stats.offloaded_blocks == 3 and layer.stats.fallback_calls == 0  # 1 M x 1 N x 3 K groups


def test_bf16_cast_recipe_uses_the_bf16_datapath_with_k_chaining():
    torch.manual_seed(5)
    lin = nn.Linear(8, 3, bias=False)
    dev = Device("software-reference-v2", caps=Caps(dtype_mask=0xFB, accumulate=True, acc_tile_k=4))
    layer = tb.AiTensorLinear(lin, dev, quant="bf16", allow_fallback=False)
    assert layer.numfmt == 6 and layer.weight_bytes() == 8 * 3 * 2
    x = torch.randn(4, 8)
    y = layer(x)
    ref = (x.to(torch.bfloat16).double() @ lin.weight.detach().to(torch.bfloat16).double().T).float()
    # bf16 products accumulated in ordered f32: within f32 rounding of the exact bf16 dot.
    assert torch.allclose(y, ref, rtol=1e-5, atol=1e-6)
    assert layer.stats.offloaded_blocks == 2 and layer.stats.fallback_calls == 0
    assert y.dtype == torch.float32


def test_flat_panel_caps_take_the_whole_k_in_one_job():
    """A part that publishes operand bank bytes boxes K by panel bytes: a 256 x 1024
    INT8 weight (same 256 KiB as a 512 x 512 panel) is ONE job, one resident key."""
    caps_flat = Caps(dtype_mask=0xFB, accumulate=True, acc_tile_m=1024, acc_tile_n=512, acc_tile_k=512,
                     macs_per_cycle=512, bank_a_bytes=1024 * 512, bank_b_bytes=512 * 512)
    assert caps_flat.fits(1, 256, 1024) and not caps_flat.fits(1, 512, 1024)
    # Decode (m = 1) is bound by the B bank; a full 1024-row A panel is bound by the A bank.
    assert caps_flat.max_k(1, 256, 1) == 1024 and caps_flat.max_k(1, 512, 1) == 512
    assert caps_flat.max_k(1024, 256, 1) == 512
    # Pitch is a power of two of lane words: k = 768 rounds to a 1024-byte pitch.
    assert caps_flat.pitch_bytes(768) == 1024 and caps_flat.fits(1, 256, 768) and not caps_flat.fits(1, 257, 768)
    legacy = Caps(dtype_mask=0xFB, accumulate=True)
    assert not legacy.fits(1, 256, 1024) and legacy.max_k(1, 256, 1) == 512
    torch.manual_seed(7)
    lin = nn.Linear(1024, 8, bias=False)
    x = torch.randn(2, 1024)
    layer = tb.AiTensorLinear(lin, Device("software-reference-v2", caps=caps_flat), allow_fallback=False)
    y = layer(x)
    assert layer.stats.offloaded_blocks == 1            # FP32 K = 1024 in one job (8 x 4 KiB fits the B bank)
    legacy_layer = tb.AiTensorLinear(lin, Device("software-reference-v2", caps=legacy), allow_fallback=False)
    y_legacy = legacy_layer(x)
    assert legacy_layer.stats.offloaded_blocks == 2      # the accumulate K-chain the flat panel removes
    assert torch.equal(y, y_legacy)                      # same ordered reduction, bit for bit
    assert torch.allclose(y, lin(x), atol=1e-4)
