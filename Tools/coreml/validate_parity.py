#!/usr/bin/env python3
"""Check the converted model against its PyTorch reference.

    Tools/coreml/.venv/bin/python Tools/coreml/validate_parity.py

This is the gate that decides whether fp16 and the Neural Engine are acceptable,
rather than the choice being assumed safe.

It is also the only thing standing between the project and the three tracing
traps documented in `convert_esm2.py`, every one of which produces a model that
converts, saves and predicts happily while returning wrong numbers:

* **Padding**, checked because the reference sequences are padded and because
  the same sequence is run at two different bucket sizes. If the mask were
  baked out, the 128-token and 384-token runs would disagree: the longer one
  would attend to 250 pad tokens.
* **Rotary tables**, checked by the non-default bucket. The model was traced at
  384; if the cos and sin tables had been frozen at that length, 128 would be
  rotated by a table twice as long as its input.
* **fp16**, checked by the correlation and error thresholds themselves.

The thresholds are on the EMBEDDINGS, not on anything downstream, because a
downstream metric can absorb a large error and still look plausible.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import coremltools as ct
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

# A cosine similarity below this on any residue means the embedding has moved
# somewhere else in the space, which no amount of downstream smoothing fixes.
MINIMUM_COSINE = 0.999
# Relative error, against the reference's own scale rather than an absolute
# tolerance: hidden states are not unit-normalised and an absolute threshold
# would be meaningless across layers.
MAXIMUM_RELATIVE_ERROR = 0.02


def cosine_per_row(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    numerator = (a * b).sum(axis=-1)
    denominator = np.linalg.norm(a, axis=-1) * np.linalg.norm(b, axis=-1)
    with np.errstate(invalid="ignore", divide="ignore"):
        return np.where(denominator > 1e-8, numerator / np.maximum(denominator, 1e-8), 1.0)


def main() -> int:
    model_name = sys.argv[1] if len(sys.argv) > 1 else "esm2_t6_8M_UR50D"
    package = MODELS_DIR / f"{model_name}.mlpackage"
    references = np.load(MODELS_DIR / f"{model_name}.reference.npz")
    # The padding index comes from the exported alphabet, NOT from the data.
    # `tokens.min()` looks like a reasonable way to find it and is not: ESM's
    # cls index is 0 and its padding index is 1, so the minimum is the cls
    # token. Every pad position then counted as a real residue, and the gate
    # cheerfully compared 382 positions of a 76-residue protein.
    tokeniser = json.loads(
        (MODELS_DIR / f"{model_name}.tokeniser.json").read_text())
    padding_index = int(tokeniser["padding_index"])
    cls_index = int(tokeniser["cls_index"])
    eos_index = int(tokeniser["eos_index"])
    print(f"alphabet: cls {cls_index}, pad {padding_index}, eos {eos_index}")

    print(f"loading {package.name} (CPU_AND_NE) ...")
    model = ct.models.MLModel(str(package), compute_units=ct.ComputeUnit.CPU_AND_NE)

    buckets = sorted(
        int(key.split("_")[1]) for key in references.files if key.startswith("tokens_"))
    print(f"buckets under test: {buckets}\n")

    failures = 0
    embeddings_by_bucket = {}

    for bucket in buckets:
        tokens = references[f"tokens_{bucket}"]
        expected = references[f"hidden_{bucket}"][0]
        actual = model.predict({"tokens": tokens.astype(np.int32)})["hidden_states"]
        actual = np.asarray(actual, dtype=np.float32)[0]

        # Compare only the REAL residues. Pad positions are masked out of the
        # attention and their outputs are undefined, so including them would
        # test noise against noise and pass regardless.
        real = (tokens[0] != padding_index) & (tokens[0] != cls_index) & (
            tokens[0] != eos_index)
        residues = np.flatnonzero(real)

        cosines = cosine_per_row(expected[residues], actual[residues])
        scale = np.abs(expected[residues]).mean()
        relative = np.abs(expected[residues] - actual[residues]).mean() / max(scale, 1e-8)

        ok = cosines.min() >= MINIMUM_COSINE and relative <= MAXIMUM_RELATIVE_ERROR
        failures += 0 if ok else 1
        embeddings_by_bucket[bucket] = actual[residues]

        print(f"bucket {bucket:>5}  residues {len(residues):>3}  "
              f"min cosine {cosines.min():.6f}  mean cosine {cosines.mean():.6f}  "
              f"relative error {relative:.5f}  {'PASS' if ok else 'FAIL'}")

    # The cross-bucket check is the one that catches a baked-out padding mask.
    # The same residues, embedded at two different padded lengths, must agree.
    # If padding were being attended to, the 384-token run would see 250 more
    # tokens than the 128-token run and the two would diverge.
    print()
    if len(buckets) >= 2:
        short, long = buckets[0], buckets[-1]
        a = embeddings_by_bucket[short]
        b = embeddings_by_bucket[long][: len(a)]
        cross = cosine_per_row(a, b)
        ok = cross.min() >= MINIMUM_COSINE
        failures += 0 if ok else 1
        print(f"cross-bucket {short} vs {long}: min cosine {cross.min():.6f}  "
              f"mean {cross.mean():.6f}  {'PASS' if ok else 'FAIL'}")
        print("  (this is the padding-mask and rotary-table check: the same")
        print("   residues embedded at two padded lengths must agree)")

    print()
    if failures:
        print(f"{failures} check(s) FAILED. Do not ship this model.")
        return 1
    print("parity OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
