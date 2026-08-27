#!/usr/bin/env python3
"""Export the PyTorch reference in a form the Swift tests can read.

    Tools/coreml/.venv/bin/python Tools/coreml/export_swift_reference.py

Writes Fixtures/neural/ubiquitin_reference.json and .bin.

Why the Swift side needs its own gate
-------------------------------------

`validate_parity.py` proves that Core ML reproduces PyTorch. It says nothing
about whether SWIFT drives Core ML correctly, and there are two ways to get
that wrong that produce no error at all:

* **A tokeniser that drifts.** Swift builds the token ids itself. Off by one on
  the cls offset, or a residue mapped to the unknown token, and the embeddings
  are confident and wrong.
* **Reading MLMultiArray by `position * dimension`.** Core ML pads rows, so the
  flat buffer is not simply row-major packed. Position 0 reads correctly either
  way, and everything after it is silently shifted.

Running the whole Swift path against these tensors catches both at once.

Float32 in a raw `.bin` rather than JSON numbers: 76 x 320 values round-trip
exactly, the file is 97 kB instead of a megabyte of decimal text, and nobody is
tempted to "tidy" the numbers by rounding them.
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import torch

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR = ROOT / "Fixtures" / "neural"

UBIQUITIN = "MQIFVKTLTGKTITLEVEPSDTIENVKAKIQDKEGIPPDQQRLIFAGKQLEDGRTLSDYNIQKESTLHLVLRLRGG"


def main() -> int:
    import esm

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    model_name = "esm2_t6_8M_UR50D"
    model, alphabet = getattr(esm.pretrained, model_name)()
    model.eval()

    tokens = torch.tensor(
        [[alphabet.cls_idx]
         + [alphabet.get_idx(c) for c in UBIQUITIN]
         + [alphabet.eos_idx]])
    with torch.no_grad():
        out = model(tokens, repr_layers=[model.num_layers], return_contacts=False)
    embeddings = out["representations"][model.num_layers][0, 1:-1].numpy().astype(np.float32)

    assert embeddings.shape == (len(UBIQUITIN), model.embed_dim), embeddings.shape
    (OUT_DIR / "ubiquitin_reference.bin").write_bytes(embeddings.tobytes(order="C"))

    # The disorder proxy, computed here from the SAME centroids the app ships,
    # so the Swift implementation of the cosine is checked too and not only the
    # embeddings feeding it.
    centroids = json.loads((ROOT / "Models" / "flexibility_centroids.json").read_text())
    mean = np.array(centroids["global_mean"], dtype=np.float64)
    helix = np.array(centroids["helix_direction"], dtype=np.float64)
    sheet = np.array(centroids["sheet_direction"], dtype=np.float64)
    residual = embeddings.astype(np.float64) - mean
    norms = np.linalg.norm(residual, axis=1, keepdims=True)
    directions = residual / np.maximum(norms, 1e-8)
    raw = 1.0 - np.maximum(directions @ helix, directions @ sheet)

    header = {
        "model": model_name,
        "sequence": UBIQUITIN,
        "residues": len(UBIQUITIN),
        "dimension": int(model.embed_dim),
        "embeddings_file": "ubiquitin_reference.bin",
        "embeddings_layout": "row-major float32, residues x dimension, little-endian",
        "token_ids": [int(t) for t in tokens[0].tolist()],
        "raw_proxy": [float(v) for v in raw],
        "note": (
            "PyTorch reference for the Swift path. Embeddings come from the "
            "PyTorch model, so a Swift comparison against them tests the "
            "tokeniser, the Core ML call and the MLMultiArray stride handling "
            "together, at whatever tolerance fp16 conversion justifies."),
    }
    (OUT_DIR / "ubiquitin_reference.json").write_text(json.dumps(header, indent=2) + "\n")

    print(f"wrote {len(UBIQUITIN)} residues x {model.embed_dim} to "
          f"{(OUT_DIR / 'ubiquitin_reference.bin').relative_to(ROOT)}")
    print(f"raw proxy range {raw.min():.4f} to {raw.max():.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
