# Attributions

JUMPjet fetches and displays third-party data. Everything it touches is
attributed here whether or not the licence requires it.

## Data sources, live

| Source | What JUMPjet uses | Licence | Attribution shown in app |
|---|---|---|---|
| **AlphaFold Protein Structure Database** (EMBL-EBI and Google DeepMind) | Predicted structures and per-residue pLDDT | CC BY 4.0 | Yes: "AlphaFold DB v6" in the sortie panel, with the model version |
| **PDBe** (EMBL-EBI) | Best-structure mappings and experimental mmCIF | CC0 for the entries; the API is EMBL-EBI's | Yes: "PDBe 1BAB chain A, X-ray 1.50 A" |
| **UniProtKB** | Protein name, organism, sequence, length | CC BY 4.0 | Yes: the protein name and organism are the sortie panel's headline |

CC BY 4.0 requires attribution, and the sortie panel gives it on every structure
rather than burying it in an About screen. JUMPjet never shows a structure
without saying which one it is and where it came from.

## Data committed to this repository

See `Fixtures/MANIFEST.md` for the per-file table. In summary: two AlphaFold DB
models of P69905 (CC BY 4.0) and PDB entry 1BAB in both formats (CC0), recorded
2026-08-27, used as test fixtures.

## Scientific references for values in the code

| Value | Source |
|---|---|
| van der Waals radii | Bondi, *J. Phys. Chem.* 68, 441 (1964) |
| Covalent radii | Cordero et al., *Dalton Trans.* 2832 (2008) |
| pLDDT confidence bands (90 / 70 / 50) | AlphaFold DB's own display convention, reproduced so a JUMPjet screenshot and an AlphaFold DB page agree about which loop is uncertain |
| Chi torsion atom quadruples | IUPAC-IUB nomenclature for amino acid side chains |

## Not used

No third-party Swift packages. No dependency manager. Nothing is vendored.

OpenMM is named in the build plan as an INSPIRATION for the Phase 2 engine and
is not used, linked, ported or derived from: it has no iOS platform, and
`JetEngine` is written from scratch in Swift and Metal.
