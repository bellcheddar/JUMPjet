#!/usr/bin/env python3
"""Convert ESM-2 t6-8M to a Core ML package for the Apple Neural Engine.

    Tools/coreml/.venv/bin/python Tools/coreml/convert_esm2.py

Writes:
    Models/esm2_t6_8M_UR50D.mlpackage        the converted backbone
    Models/esm2_t6_8M_UR50D.tokeniser.json   the alphabet, so Swift tokenises identically
    Models/esm2_t6_8M_UR50D.reference.npz    PyTorch tensors for the parity gate

Why the Neural Engine at all
----------------------------

Build plan ground rule 2: the ANE only executes Core ML graphs, so the physics
inner loop cannot run there. The ANE's genuine job in JUMPjet is this model.
`JetEngine` runs on GPU and CPU; the flexibility prior that parameterises it
runs here.

Three traps, all of which produce a model that CONVERTS, SAVES and PREDICTS
while returning quietly wrong numbers
-------------------------------------------------------------------------------

Every one of these was found the expensive way in BOFFIN, which is a sibling
project with a working ESM-2 conversion. They are reproduced here rather than
rediscovered, and the pinned environment in `requirements.txt` comes from the
same place.

**1. The padding branch is baked in at trace time.** fair-esm computes
`padding_mask = tokens.eq(padding_idx)` and then does
`if not padding_mask.any(): padding_mask = None`. Under `torch.jit.trace` that
`.any()` collapses to a Python bool, and the branch taken while tracing is the
only branch that survives. Tracing with an unpadded example produces a model
that ignores padding for every real input: it attends to pad tokens and returns
subtly wrong embeddings for every sequence shorter than its bucket. The example
below is deliberately padded so the MASKED path is what gets captured.

**2. Rotary embeddings cache their tables by sequence length.** See
`TraceableRotaryEmbedding`. Left alone, a 1,216-token input is rotated by tables
built for 384 positions.

**3. `EnumeratedShapes` over a BATCH dimension crashes predict with SIGTRAP.**
Not relevant here, because JUMPjet only ever needs batch 1: it embeds one
sequence per structure and does no masked-marginal scanning. Recorded so nobody
adds a batch later and loses a day to it.

What JUMPjet does NOT take from the sibling project
---------------------------------------------------

BOFFIN has trained secondary-structure and disorder heads. They are not used
here. The build plan is explicit that v1 trains nothing, and those heads carry
an unresolved licence position on their training data. The flexibility prior is
built from pLDDT and from centroids computed by `compute_centroids.py` out of
structures whose licences are clear.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

# Must stay in lockstep with `ShapeBucket` in JumpjetNeural. A bucket in one and
# not the other fails at prediction time, on device.
#
# Token count is residues + 2 (cls and eos), so the top bucket of 1,216 covers
# JUMPjet's 1,200-residue cap with room to spare. Six buckets rather than a
# single fixed 1,216: a 142-residue globin would otherwise pay for 1,200
# positions of attention it does not use.
BUCKETS = [128, 256, 384, 512, 768, 1216]
DEFAULT_BUCKET = 384

# Ubiquitin, used as the parity reference sequence. Short, entirely standard,
# and its fold is the one everybody can eyeball.
UBIQUITIN = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"


class TraceableRotaryEmbedding(nn.Module):
    """A rotary position embedding that survives tracing.

    fair-esm's `RotaryEmbedding` caches its cos and sin tables in Python
    attributes keyed on sequence length:

        if seq_len != self._seq_len_cached or ...:
            self._seq_len_cached = seq_len
            ... recompute ...

    Under `torch.jit.trace` that `if` runs exactly once, so the tables become
    graph CONSTANTS sized for whichever length happened to be traced. With
    `EnumeratedShapes` that is fatal and silent: a 1,216-token input would be
    rotated by tables built for 384 positions, and `apply_rotary_pos_emb`
    slices with `cos[:, : x.shape[-2], :]`, which on a too-short table simply
    returns what is there. The failure surfaces as a broadcast error at best
    and as quietly wrong embeddings at worst.

    This version precomputes the tables once at the maximum bucket length and
    slices per call. No Python branch, no cache, nothing to freeze at the wrong
    size.
    """

    def __init__(self, dim: int, max_sequence_length: int):
        super().__init__()
        inv_freq = 1.0 / (10000 ** (torch.arange(0, dim, 2).float() / dim))
        positions = torch.arange(max_sequence_length).type_as(inv_freq)
        frequencies = torch.einsum("i,j->ij", positions, inv_freq)
        embedding = torch.cat((frequencies, frequencies), dim=-1)
        self.register_buffer("cos_table", embedding.cos()[None, :, :], persistent=False)
        self.register_buffer("sin_table", embedding.sin()[None, :, :], persistent=False)

    def forward(self, q: torch.Tensor, k: torch.Tensor):
        from esm.rotary_embedding import apply_rotary_pos_emb

        length = k.shape[-2]
        cos = self.cos_table[:, :length, :]
        sin = self.sin_table[:, :length, :]
        return apply_rotary_pos_emb(q, cos, sin), apply_rotary_pos_emb(k, cos, sin)


def make_traceable(model: nn.Module, max_sequence_length: int) -> int:
    """Replace every cached rotary embedding with the traceable one.

    Returns how many were replaced, which the caller asserts on: silently
    replacing zero would leave the original bug in place while the conversion
    appeared to succeed.
    """
    from esm.rotary_embedding import RotaryEmbedding

    replaced = 0
    for module in model.modules():
        for name, child in list(module.named_children()):
            if isinstance(child, RotaryEmbedding):
                dim = child.inv_freq.shape[0] * 2
                setattr(module, name, TraceableRotaryEmbedding(dim, max_sequence_length))
                replaced += 1
    return replaced


class ESMEmbedder(nn.Module):
    """Per-residue hidden states, and nothing else.

    BOFFIN's equivalent also returns vocabulary logits, because it scores
    variants. JUMPjet does not: it needs one embedding per residue to measure
    against the secondary-structure centroids, and returning logits as well
    would put a vocab-sized tensor per position through the ANE for nothing.
    """

    def __init__(self, model: nn.Module, repr_layer: int):
        super().__init__()
        self.model = model
        self.repr_layer = repr_layer

    def forward(self, tokens: torch.Tensor) -> torch.Tensor:
        out = self.model(tokens, repr_layers=[self.repr_layer], return_contacts=False)
        return out["representations"][self.repr_layer]


def load_model(name: str):
    import esm

    loader = getattr(esm.pretrained, name)
    model, alphabet = loader()
    model.eval()
    for parameter in model.parameters():
        parameter.requires_grad_(False)
    return model, alphabet


def export_tokeniser(alphabet, path: Path) -> dict:
    """Write the alphabet so the Swift tokeniser cannot drift from it.

    A tokeniser mismatch does not crash: it produces confident, wrong
    embeddings, which is the worst failure mode available.
    """
    payload = {
        "tokens": list(alphabet.all_toks),
        "token_to_index": {token: index for index, token in enumerate(alphabet.all_toks)},
        "padding_index": alphabet.padding_idx,
        "cls_index": alphabet.cls_idx,
        "eos_index": alphabet.eos_idx,
        "mask_index": alphabet.mask_idx,
        "unknown_index": alphabet.unk_idx,
        "prepend_bos": alphabet.prepend_bos,
        "append_eos": alphabet.append_eos,
        "buckets": BUCKETS,
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def padded_tokens(alphabet, sequence: str, bucket: int) -> torch.Tensor:
    """One padded, cls-and-eos-wrapped row, exactly as the Swift side builds it."""
    tokens = torch.full((1, bucket), alphabet.padding_idx, dtype=torch.int64)
    tokens[0, 0] = alphabet.cls_idx
    residues = [alphabet.get_idx(c) for c in sequence[: bucket - 2]]
    tokens[0, 1 : 1 + len(residues)] = torch.tensor(residues)
    tokens[0, 1 + len(residues)] = alphabet.eos_idx
    return tokens


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", default="esm2_t6_8M_UR50D")
    parser.add_argument(
        "--precision", default="fp16", choices=["fp16", "fp32"],
        help="fp16 is the shipping configuration; fp32 is for diagnosing parity failures.")
    parser.add_argument("--suffix", default="")
    args = parser.parse_args()

    MODELS_DIR.mkdir(parents=True, exist_ok=True)

    print(f"loading {args.model} ...")
    model, alphabet = load_model(args.model)
    repr_layer = model.num_layers
    print(f"  layers {model.num_layers}, embed dim {model.embed_dim}, "
          f"vocab {len(alphabet.all_toks)}")

    tokeniser = export_tokeniser(alphabet, MODELS_DIR / f"{args.model}.tokeniser.json")
    print(f"  wrote tokeniser ({len(tokeniser['tokens'])} tokens)")

    replaced = make_traceable(model, max(BUCKETS))
    print(f"  replaced {replaced} cached rotary embeddings with traceable ones")
    if replaced == 0:
        raise SystemExit(
            "No RotaryEmbedding modules were found. fair-esm's internals have changed: "
            "verify that position embeddings are still traceable before trusting the "
            "converted model.")

    wrapper = ESMEmbedder(model, repr_layer).eval()

    # A DELIBERATELY PADDED example. See trap 1 in the module docstring.
    example = padded_tokens(alphabet, UBIQUITIN[:33], DEFAULT_BUCKET)
    assert example.eq(alphabet.padding_idx).any(), "example must contain padding"

    print("tracing ...")
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example, strict=False)

    print("converting ...")
    shape = ct.EnumeratedShapes(
        shapes=[[1, bucket] for bucket in BUCKETS], default=[1, DEFAULT_BUCKET])

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="hidden_states", dtype=np.float16)],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16
        if args.precision == "fp16"
        else ct.precision.FLOAT32,
        # Excluding the GPU deliberately. If an operation cannot run on the
        # Neural Engine it falls back to the CPU and the benchmark shows it,
        # rather than quietly landing on the GPU and looking fast while
        # defeating the point of measuring ANE residency at all.
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        # iOS 17, matching the app's deployment target. Converting at iOS18
        # produces a model that will not load on the oldest device JUMPjet
        # claims to support, and nothing in the build would catch it.
        minimum_deployment_target=ct.target.iOS17,
    )

    mlmodel.short_description = (
        f"ESM-2 {args.model}. Per-residue hidden states from one forward pass, "
        f"used to place each residue against helix and sheet centroids.")
    mlmodel.input_description["tokens"] = (
        f"Padded token ids, (1, S) where S is one of {BUCKETS}, "
        f"padding id {alphabet.padding_idx}.")
    mlmodel.output_description["hidden_states"] = (
        f"Per-residue hidden states, (1, S, {model.embed_dim}).")

    package = MODELS_DIR / f"{args.model}{args.suffix}.mlpackage"
    mlmodel.save(str(package))
    print(f"wrote {package.relative_to(ROOT)}")

    # Reference tensors for the parity gate, computed from the PYTORCH model
    # before any comparison, so they are genuinely the reference answer rather
    # than a re-derivation of whatever Core ML produced.
    print("computing reference tensors ...")
    references = {}
    with torch.no_grad():
        for bucket in (128, DEFAULT_BUCKET):
            tokens = padded_tokens(alphabet, UBIQUITIN, bucket)
            hidden = wrapper(tokens)
            references[f"tokens_{bucket}"] = tokens.numpy().astype(np.int32)
            references[f"hidden_{bucket}"] = hidden.numpy().astype(np.float32)

    reference_path = MODELS_DIR / f"{args.model}.reference.npz"
    np.savez_compressed(reference_path, **references)
    print(f"wrote {reference_path.relative_to(ROOT)}")

    size_mb = sum(f.stat().st_size for f in package.rglob("*") if f.is_file()) / 1e6
    print(f"\npackage size: {size_mb:.1f} MB")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
