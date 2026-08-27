#!/usr/bin/env python3
"""Derive the backbone and side-chain torsion statistics JetEngine samples against.

    Tools/coreml/.venv/bin/python Tools/coreml/compute_torsion_tables.py

Writes Models/torsion_tables.json.

Why derived rather than hand-placed
-----------------------------------

The build plan asks for "a compact binned table (Dunbrack-style wells at chi1
around -60/60/180); backbone phi-psi Ramachandran bias". Hand-placing those
wells would be quicker and is the wrong trade: a backbone bias that is subtly
wrong does not fail loudly, it generates conformations no protein adopts, and
every downstream jump statistic inherits the error.

Real libraries exist and are better than this. They are not used for the same
reason the flexibility centroids do not use DSSP: an unresolved licence on a
table JUMPjet must redistribute inside an app bundle. These are computed from
AlphaFold DB models, which are CC BY 4.0 and which JUMPjet already ships an
attribution for.

What is stored is ENERGY, in kT, as -ln(p) with a floor, so the Swift side adds
it straight into a Metropolis criterion without doing any statistics of its own.
"""

from __future__ import annotations

import json
import math
import sys
import urllib.error
import urllib.request
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compute_centroids import (  # noqa: E402
    CACHE_DIR, THREE_TO_ONE, dihedral, fetch, read_backbone,
)

ROOT = Path(__file__).resolve().parents[2]
MODELS_DIR = ROOT / "Models"

# 15 degree bins: 24 x 24 over the Ramachandran plane. Finer would be better
# statistics per structure and worse statistics per bin, and at roughly twenty
# thousand residues 576 bins leaves about thirty-five each before smoothing.
BACKBONE_BINS = 24
CHI_BINS = 36  # 10 degrees, which resolves the three chi1 wells comfortably

# The energy floor. Without it an empty bin is infinitely unfavourable and the
# sampler can never cross it, which turns a sparsely sampled region into a wall
# rather than into a hill.
MAXIMUM_ENERGY = 6.0

# Fifty proteins spanning the fold classes and both kingdoms, chosen so no
# single architecture dominates the backbone statistics.
ACCESSIONS = [
    "P69905", "P68871", "P0DP23", "P02766", "P61769", "P62937", "P04406",
    "P00918", "P01112", "P60174", "P00558", "P07900", "P00698", "P02768",
    "P68871", "P01308", "P02144", "P00441", "P04637", "P38398", "P42574",
    "P06400", "P10275", "P11021", "P0DMV8", "P07437", "P68363", "P63261",
    "P60709", "P02545", "P08670", "P05787", "Q9Y6K9", "P31749", "P27361",
    "P28482", "Q16539", "P45983", "P17612", "P24941", "P06493", "P11802",
    "P00533", "P04049", "P15056", "P01116", "P01111", "Q05397", "P29320",
    "P43405", "P08581", "P07949", "P36888", "P10721", "P16234", "P09619",
]

ROTATABLE = {
    "ARG": ["CG", "CD"], "ASN": ["OD1"], "ASP": ["OD1"], "CYS": ["SG"],
    "GLN": ["CD"], "GLU": ["CD"], "HIS": ["ND1"], "ILE": ["CG1"],
    "LEU": ["CD1"], "LYS": ["CD"], "MET": ["SD"], "PHE": ["CD1"],
    "PRO": ["CG"], "SER": ["OG"], "THR": ["OG1"], "TRP": ["CD1"],
    "TYR": ["CD1"], "VAL": ["CG1"],
}
CHI1_TERMINAL = {
    "ARG": "CG", "ASN": "CG", "ASP": "CG", "CYS": "SG", "GLN": "CG",
    "GLU": "CG", "HIS": "CG", "ILE": "CG1", "LEU": "CG", "LYS": "CG",
    "MET": "CG", "PHE": "CG", "PRO": "CG", "SER": "OG", "THR": "OG1",
    "TRP": "CG", "TYR": "CG", "VAL": "CG1",
}


def read_all_atoms(path: Path):
    """Every heavy atom per residue, keyed by name, in file order."""
    residues: dict[tuple[int, str], dict] = {}
    order: list[tuple[int, str]] = []
    for line in path.read_text().splitlines():
        if not line.startswith("ATOM"):
            continue
        element = line[76:78].strip()
        if element == "H":
            continue
        key = (int(line[22:26]), line[26].strip())
        if key not in residues:
            residues[key] = {"name": line[17:20].strip(), "plddt": float(line[60:66]),
                             "atoms": {}}
            order.append(key)
        residues[key]["atoms"][line[12:16].strip()] = np.array(
            [float(line[30:38]), float(line[38:46]), float(line[46:54])])
    return [residues[key] for key in order]


def bin_index(angle: float, bins: int) -> int:
    """Wrap an angle in degrees into [0, bins). -180 and +180 are the same bin."""
    return int(((angle + 180.0) % 360.0) / (360.0 / bins)) % bins


def circular_smooth(counts: np.ndarray, passes: int = 1) -> np.ndarray:
    """Smooth wrapping around the edges, because torsions are circular.

    Smoothing with a flat boundary would put a seam at 180 degrees, which is in
    the middle of the extended backbone region rather than somewhere harmless.
    """
    smoothed = counts.astype(np.float64)
    for _ in range(passes):
        if smoothed.ndim == 1:
            smoothed = (np.roll(smoothed, 1) + 2 * smoothed + np.roll(smoothed, -1)) / 4
        else:
            smoothed = (
                np.roll(smoothed, 1, 0) + np.roll(smoothed, -1, 0)
                + np.roll(smoothed, 1, 1) + np.roll(smoothed, -1, 1)
                + 4 * smoothed) / 8
    return smoothed


def to_energy(counts: np.ndarray) -> np.ndarray:
    """-ln(p) in kT, floored, with the minimum shifted to zero."""
    smoothed = circular_smooth(counts, passes=2)
    total = smoothed.sum()
    if total <= 0:
        return np.zeros_like(smoothed)
    probability = smoothed / total
    # A pseudocount worth one part in ten thousand of the whole table, so an
    # unvisited bin is expensive rather than impossible.
    floor = 1e-4 / probability.size
    energy = -np.log(np.maximum(probability, floor))
    energy -= energy.min()
    return np.minimum(energy, MAXIMUM_ENERGY)


def main() -> int:
    backbone = {
        "general": np.zeros((BACKBONE_BINS, BACKBONE_BINS)),
        "glycine": np.zeros((BACKBONE_BINS, BACKBONE_BINS)),
        "proline": np.zeros((BACKBONE_BINS, BACKBONE_BINS)),
    }
    chi1 = {name: np.zeros(CHI_BINS) for name in CHI1_TERMINAL}
    chi2 = {name: np.zeros(CHI_BINS) for name in ROTATABLE}

    used, skipped = [], []
    for accession in dict.fromkeys(ACCESSIONS):
        try:
            path = fetch(accession)
        except (urllib.error.URLError, urllib.error.HTTPError, KeyError, IndexError) as error:
            skipped.append((accession, str(error)[:60]))
            continue
        residues = read_all_atoms(path)
        used.append((accession, len(residues)))

        for index, residue in enumerate(residues):
            atoms = residue["atoms"]
            # Only well-determined regions define what a favourable torsion is.
            # A disordered loop's phi and psi are the model's guess, and folding
            # those into the reference would flatten the very wells the sampler
            # needs.
            if residue["plddt"] < 70:
                continue
            name = residue["name"]

            if index > 0 and index + 1 < len(residues):
                previous, following = residues[index - 1]["atoms"], residues[index + 1]["atoms"]
                if all(k in atoms for k in ("N", "CA", "C")) and "C" in previous and "N" in following:
                    phi = dihedral(previous["C"], atoms["N"], atoms["CA"], atoms["C"])
                    psi = dihedral(atoms["N"], atoms["CA"], atoms["C"], following["N"])
                    category = ("glycine" if name == "GLY"
                                else "proline" if name == "PRO" else "general")
                    backbone[category][bin_index(phi, BACKBONE_BINS),
                                       bin_index(psi, BACKBONE_BINS)] += 1

            terminal = CHI1_TERMINAL.get(name)
            if terminal and all(k in atoms for k in ("N", "CA", "CB", terminal)):
                angle = dihedral(atoms["N"], atoms["CA"], atoms["CB"], atoms[terminal])
                chi1[name][bin_index(angle, CHI_BINS)] += 1

            second = ROTATABLE.get(name, [None])[0]
            gamma = CHI1_TERMINAL.get(name)
            if second and gamma and all(k in atoms for k in ("CA", "CB", gamma, second)):
                if second != gamma:
                    angle = dihedral(atoms["CA"], atoms["CB"], atoms[gamma], atoms[second])
                    chi2[name][bin_index(angle, CHI_BINS)] += 1

    print(f"{len(used)} structures, {sum(n for _, n in used)} residues")
    for accession, reason in skipped:
        print(f"  skipped {accession}: {reason}")

    for category, counts in backbone.items():
        print(f"  backbone {category:<9} {int(counts.sum()):>7} residues")
    if backbone["general"].sum() < 5000:
        raise SystemExit(
            "too few general-case residues for a usable Ramachandran table. Add "
            "structures rather than lowering the pLDDT cut: a table built from "
            "disordered loops has no wells in it.")

    # A check with teeth. The alpha region must be the most populated bin of the
    # general table, and it must be a WELL: if the table came out flat, every
    # backbone move would be accepted and the sampler would generate nonsense.
    general_energy = to_energy(backbone["general"])
    alpha = general_energy[bin_index(-63, BACKBONE_BINS), bin_index(-43, BACKBONE_BINS)]
    beta = general_energy[bin_index(-135, BACKBONE_BINS), bin_index(135, BACKBONE_BINS)]
    forbidden = general_energy[bin_index(60, BACKBONE_BINS), bin_index(-120, BACKBONE_BINS)]
    print(f"\n  alpha region      {alpha:.2f} kT")
    print(f"  beta region       {beta:.2f} kT")
    print(f"  forbidden region  {forbidden:.2f} kT")
    if not (alpha < 1.0 and beta < 2.0 and forbidden > 3.0):
        raise SystemExit(
            "the Ramachandran table has no wells: alpha and beta should be near "
            "zero and the left-handed-bridge region expensive. A flat table "
            "accepts every backbone move and generates conformations no protein "
            "adopts.")

    # Chi1 must be staggered. Stated as the physical claim rather than as a
    # comparison of individual bins: the FRACTION of observations falling within
    # 30 degrees of a staggered value.
    #
    # The first version of this gate compared the worst staggered bin against
    # the best eclipsed one and failed on correct data, for two reasons worth
    # keeping. Leucine's g+ rotamer is genuinely rare (about 1% here, 4.99 kT),
    # so "the worst well" is not a well at all; and -120 degrees sits only 60
    # from the g- well, so after smoothing it carries that well's shoulder
    # rather than an eclipsed population. Neither is a defect in the table.
    def staggered_fraction(counts: np.ndarray) -> float:
        total = counts.sum()
        if total <= 0:
            return 0.0
        width = 360.0 / CHI_BINS
        inside = 0.0
        for index, count in enumerate(counts):
            angle = -180.0 + (index + 0.5) * width
            nearest = min(abs((angle - well + 180) % 360 - 180) for well in (-60, 60, 180))
            if nearest <= 30.0:
                inside += count
        return float(inside / total)

    print()
    fractions = {}
    for name, counts in sorted(chi1.items()):
        if counts.sum() < 50:
            continue
        fractions[name] = staggered_fraction(counts)
    for name in ("LEU", "VAL", "SER", "PHE"):
        if name in fractions:
            print(f"  {name} chi1 within 30 deg of staggered: {fractions[name]:.3f}")

    # Proline is excluded: its chi1 is locked by the ring near -30 and +30, so it
    # is not staggered and is not supposed to be.
    testable = {k: v for k, v in fractions.items() if k != "PRO"}
    worst = min(testable, key=testable.get)
    print(f"  weakest (excluding proline): {worst} at {testable[worst]:.3f}")
    if testable[worst] < 0.80:
        raise SystemExit(
            f"{worst} puts only {testable[worst]:.1%} of its chi1 within 30 degrees of "
            "a staggered value. Either the dihedral atoms are wrong for that residue "
            "or the table is too sparse to sample against.")

    payload = {
        "backbone_bins": BACKBONE_BINS,
        "chi_bins": CHI_BINS,
        "maximum_energy": MAXIMUM_ENERGY,
        "units": "kT, as -ln(p) with the minimum shifted to zero",
        "backbone": {
            category: to_energy(counts).round(4).tolist()
            for category, counts in backbone.items()
        },
        "chi1": {
            name: to_energy(counts).round(4).tolist()
            for name, counts in chi1.items() if counts.sum() >= 50
        },
        "chi2": {
            name: to_energy(counts).round(4).tolist()
            for name, counts in chi2.items() if counts.sum() >= 50
        },
        "provenance": {
            "method": (
                "Binned torsion counts from AlphaFold DB models, restricted to "
                "residues with pLDDT at or above 70, smoothed circularly and "
                "converted to -ln(p) in kT with a floor of "
                f"{MAXIMUM_ENERGY:g}."),
            "structures": [{"accession": a, "residues": n} for a, n in used],
            "residues": sum(n for _, n in used),
            "backbone_counts": {k: int(v.sum()) for k, v in backbone.items()},
            "licence": "AlphaFold DB models, CC BY 4.0. No third-party libraries used.",
            "caveat": (
                "Coarser and less accurate than a real rotamer library, and "
                "deliberately so: this one can be redistributed inside an app "
                "bundle. It is a bias for a crude sampler, not a validation "
                "reference."),
        },
    }

    output = MODELS_DIR / "torsion_tables.json"
    output.write_text(json.dumps(payload) + "\n")
    print(f"\nwrote {output.relative_to(ROOT)} ({output.stat().st_size / 1024:.0f} kB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
