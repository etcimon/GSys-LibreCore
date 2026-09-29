# Copyright (c) 2026 Etienne Cimon
# SPDX-License-Identifier: MIT
"""One Hugging Face BERT layer against the exact GEMM path.

The model is a randomly initialised ``BertModel`` built from a local
``BertConfig``. Nothing is downloaded and nothing is a trained checkpoint.
A finite forward and a zero-ppm native GEMM show that the exact path
matches PyTorch on that layer. They do not set the promotion gate for
accuracy beyond the one-tile proxy, and they do not write ``VaTurboEn``.
"""

import pytest

from ai_tensor import va_turbo as vt
from ai_tensor.policy import OperandReuse

transformers = pytest.importorskip("transformers")
torch = pytest.importorskip("torch")

from transformers import BertConfig, BertModel  # noqa: E402


def _tiny_bert():
    torch.manual_seed(0)
    config = BertConfig(
        hidden_size=32,
        num_hidden_layers=1,
        num_attention_heads=4,
        intermediate_size=64,
        vocab_size=128,
        max_position_embeddings=32,
    )
    model = BertModel(config)
    model.eval()
    return model


def test_a_huggingface_bert_layer_stays_exact_and_does_not_promote():
    model = _tiny_bert()
    tokens = torch.randint(0, 128, (2, 8))
    with torch.no_grad():
        hidden = model(tokens).last_hidden_state
    assert tuple(hidden.shape) == (2, 8, 32)
    assert bool(torch.isfinite(hidden).all())

    query = model.encoder.layer[0].attention.self.query
    assert isinstance(query, torch.nn.Linear)
    activation = torch.randn(8, 32)
    scored = vt.quality(activation, query.weight.detach().T.contiguous(), "native-fp32")
    assert scored.ok
    assert scored.ppm == 0.0
    assert scored.budget_level == 0

    assert vt.PromotionGates().ready() is False
    assert vt.ppm_satisfies_promotion(vt.DOC_INT8_PPM) is False
    assert vt.LIVE_VA_TURBO_EN is False
    live = vt.configured_rate(
        vt.PortSetting.live(),
        vt.TrackFeatures.live(),
        vt.LIVE_CLOCK_KHZ,
        0,
    )
    balance = vt.port_balance(live)
    assert balance["fed"] is True
    assert vt.dram_covers(balance, 0, 1) is True
    assert vt.ddr4_channels_to_cover(balance["demand_gbps"]) == 1


def test_a_narrowed_bert_projection_does_not_promote():
    model = _tiny_bert()
    query = model.encoder.layer[0].attention.self.query
    activation = torch.randn(8, 32)
    scored = vt.quality(activation, query.weight.detach().T.contiguous(), "convert-fp16")
    assert scored.ok
    assert vt.ppm_satisfies_promotion(vt.DOC_INT8_PPM) is False
    assert vt.PromotionGates(beyond_tile_proxy=False).ready() is False
    assert vt.LIVE_VA_TURBO_EN is False


def test_bert_weight_reuse_matches_and_the_live_bit_stays_off():
    model = _tiny_bert()
    query = model.encoder.layer[0].attention.self.query
    activation = torch.randn(8, 32)
    weight = query.weight.detach().T.contiguous()
    key = (1, weight.shape[0], weight.shape[1], weight.shape[1], 0)
    reuse = OperandReuse()
    reuse.set_enabled(True)
    read_weight, image = reuse.bind("b", False, key, weight)
    assert read_weight is True
    with torch.no_grad():
        first = activation @ image
    reuse.finish(True)
    mutated = weight + 1
    read_again, resident = reuse.bind("b", True, key, mutated)
    assert read_again is False
    with torch.no_grad():
        second = activation @ resident
        changed = activation @ mutated
    assert torch.equal(first, second)
    assert not torch.equal(first, changed)
    gates = vt.PromotionGates()
    refused_lanes = vt.accept_witness(
        vt.GateWitness("concurrency_measured", "passed", "lane-groups")
    )
    assert refused_lanes.status == "failed"
    refused_layer = vt.accept_witness(
        vt.GateWitness("beyond_tile_proxy", "passed", "huggingface-bert-random")
    )
    assert refused_layer.status == "absent"
    decision = vt.va_turbo_from_witnesses(
        vt.GateWitness("exact_reuse", "passed", "huggingface-bert-query-weight"),
        vt.known_promotion_witnesses(),
    )
    assert decision.exact_reuse_ok is True
    assert decision.allowed is False
    assert decision.missing == (
        "concurrency_measured:failed",
        "held_out_pair:absent",
        "gain_threshold_recorded:absent",
        "beyond_tile_proxy:absent",
    )
    assert vt.va_turbo_en_allowed(True, gates) is False
    ready = vt.PromotionGates(True, True, True, True)
    assert vt.va_turbo_en_allowed(True, ready) is False
    assert vt.LIVE_VA_TURBO_EN is False
