# Changelog

## Phase 2 — Engines — 2026-08-27

The neural flexibility prior and the `JetEngine` sampler, wired into the app.

### Definition of done

| Requirement | Status |
|---|---|
| ESM-2 t6-8M converted to Core ML, fp16, ~16 MB | Met. 15.0 MB, enumerated shapes over six sequence buckets |
| Flexibility prior from inverse pLDDT and an embedding disorder proxy, 70/30 | Met, but the proxy is NOT the one the plan describes: see below |
| ANE dispatch verified, reported truthfully in the HUD | Met with a caveat. 98% of operations are PLANNED on the Neural Engine by `MLComputePlan`. That is a plan, not an Instruments trace of execution, and the HUD says "planned" for that reason |
| All-atom torsional representation, bond lengths and angles fixed | Met. Tested: no bond length moves over a whole run |
| Elastic network scaled down by the prior, soft-sphere sterics, torsion tables | Met. Each term tested against a hand-computed value |
| Metropolis with Gaussian, rotamer-jump and ring-flip moves | Met |
| Deterministic replay from a seed | Met |
| Acceptance ratio between 20 and 60% at the default throttle | Met. 0.395 at 142 residues, 0.378 at 335, calibrated by measurement |
| No runaway across 50,000 sweeps on three test proteins | Met by an opt-in test (`JUMPJET_LONGRUN=1`), because at the measured rates it is several minutes of wall clock |
| **100 sweeps/s for a 300-residue protein** | **NOT met.** 130.8 sweeps/s at 142 residues and 22.3 at 335. See "Performance" |
| Live HUD readouts during a run | Met. Acceptance, sweeps/s, RMSD, energy, and the protein visibly moving |

### The disorder proxy is not the one the plan specified

The build plan asks for "distance to helix/sheet centroid embeddings". Taken
literally that means Euclidean distance, and measured that way it separates
**nothing**: Cohen's d of -0.023 between coil and regular secondary structure,
faintly the wrong sign.

The reason is visible once measured. The helix and sheet centroids sit 1.32
apart against a within-class spread of 4.60, so relative to the noise they are
the same point, and "distance to the nearer of two" asks every residue the same
question: how far are you from the global mean? That mean is itself enormous
(norm 4.83 against a typical embedding norm of 6.9).

Subtracting it and comparing **directions** gives Cohen's d +1.024 and AUC
0.801, and moves the right way against confidence (-0.335 with pLDDT). That is
what ships, and `compute_centroids.py` now gates on both numbers.

Stated plainly: at -0.335 the proxy is partly redundant with the pLDDT term it
is averaged with. The 70/30 blend is not combining two independent measurements.

### Performance

The throughput target is the one thing Phase 2 does not meet, and the gap is
structural rather than sloppy: a backbone rotation moves about a quarter of the
atoms and each needs its neighbourhood re-tested, which is 97% of the cost.

What was tried:

| Change | Result |
|---|---|
| Grid cells 6.06 A to 4.06 A for a 3.06 A cutoff | 167 candidates per query down to 63. Kept |
| Steric term as a difference in one pass | Halved the grid queries. Kept |
| Grid-based total-energy recompute | 118 ms to 0.7 ms. Kept |
| Deterministic `concurrentPerform` across 8 chunks | **Seven times SLOWER**, 19.6 to 3.1 sweeps/s. Reverted |
| Per-cell distance culling | Slower AND wrong: culling at cutoff plus one drift margin misses contacts, because both atoms drift. Reverted |

The remaining lever is the Metal clash grid the build plan's own risk table
names. It has not been attempted.

One methodological note worth more than any of the above: **`swift test` builds
debug, and for this package that is a factor of 36.** An entire optimisation
pass was aimed at debug numbers before it was noticed.

### Licences

Neither the centroids nor the torsion tables use DSSP, the DTU secondary
structure sets, or a Dunbrack rotamer library. All three would be better and
none can be redistributed inside an app bundle with a clear licence. Everything
here is derived from AlphaFold DB models, which are CC BY 4.0 and which JUMPjet
already attributes.

BOFFIN's trained secondary-structure and disorder heads were deliberately not
reused for the same reason, and because the build plan says v1 trains nothing.

### Deliberately deferred

- **Optional overdamped Brownian mode.** The plan lists it as a later toggle and
  it stays later. Monte Carlo is the v1 workhorse because its correctness is
  easy to test.
- **Backbone H-bond term.** The plan makes it a stretch goal conditional on the
  phase being ahead of schedule. It is not.
- **Instruments verification of ANE execution.** `MLComputePlan` answers the
  structural question and the HUD reports it as a plan. An actual trace has not
  been taken.

### Numbers

177 tests across seven packages.

## Phase 1 — Airframe — 2026-08-27

Project, fetch, parse, view. Open the app, type an accession, see the structure.

### Definition of done

| Requirement | Status |
|---|---|
| Cold start to structure on screen, three test accessions | Met. P69905 (142 aa), P04406 (335 aa), P07900 (732 aa), verified on an iPhone 17 Pro simulator from a clean install |
| Parser tests pass on AFDB PDB, AFDB mmCIF and an experimental PDBe file | Met. 25 tests, including cross-format agreement atom for atom on both a prediction and a four-chain crystal structure |
| Offline relaunch loads from cache | Met in tests. Verified live only as far as the cache READ path, which the HUD's CACHED badge shows on a second load; the network-down branch is covered by `StructureServiceTests` rather than by pulling a cable |
| 60 fps on an A16 for 600 residues | **Not measured.** No device to hand, and a simulator frame rate says nothing about a phone. Carry into Phase 2, where the profiling pass happens anyway |

### Shipped

**JumpjetCore.** Structure model as flat atoms with residues and chains indexing
into them, so Phase 2's engine can hand one buffer to the GPU. Element and amino
acid tables, including the side-chain chi definitions that the sampler and the
jump analysis will both read. Geometry: dihedral, Kabsch, RMSD, radius of
gyration. Covalent bond inference by distance.

**JumpjetParse.** PDB by fixed column, mmCIF by a real tokeniser. One
`StructureBuilder` applies every dropping policy for both readers and reports
what it dropped.

**JumpjetFetch.** UniProt, AlphaFold DB and PDBe behind an injectable transport,
an actor model cache, and the service that orchestrates them. Accessions are
validated against the UniProtKB grammar before the first request.

**JumpjetHUD.** The Night Sortie design system: the build plan's six hex values,
monospaced-digit readouts, panels, tape and dial gauges, the amber RUN control.
Every semantic role carries a symbol as well as a colour.

**JumpjetViewer.** SceneKit backbone tube through a Catmull-Rom spline swept with
a parallel-transport frame. Colour modes with the official AlphaFold pLDDT bands.
Side chains merged into one geometry.

**App.** Cockpit layout that splits side-by-side when the window is wider than it
is tall and stacks otherwise. Accession entry with a live validity lamp, sortie
panel, display controls, chain picker.

### Deliberately deferred

- **The residue cap is enforced but untuned.** 1,200 comes from the build plan,
  not from a measurement. Phase 2's profiling is what should set it.
- **Non-polymer residues are dropped entirely.** Waters, ligands, ions and even
  an acetyl cap on a real chain. v1 samples the polymer, and the parser reports
  what it discarded rather than hiding it. Showing a haem alongside a globin is a
  Phase 4 nicety at the earliest.
- **`ColourMode.flexibility` exists and reports itself unavailable.** The prior
  it needs arrives in Phase 2.
- **Ring-flip and rotamer machinery is present in the chemistry tables and
  unused.** `symmetricChiIndices`, `hasFlippableRing` and
  `Geometry.symmetricAngularDifference` are tested and waiting for Phase 3.

### Numbers

139 tests across five packages, about two seconds on the host, no simulator.

| Package | Tests |
|---|---|
| JumpjetCore | 39 |
| JumpjetFetch | 25 |
| JumpjetHUD | 16 |
| JumpjetParse | 25 |
| JumpjetViewer | 34 |

### Bugs found and fixed during the phase

Recorded because each one passes a plausible-looking test suite:

1. Kabsch produced a determinant-zero "rotation" for collinear points; Jacobi
   leaves the left columns of vanishing singular values empty.
2. The dihedral sign convention was inverted, which would have flipped every
   chi1 well from g- to g+.
3. A test asserted that reversing a torsion's atom order negates it. It does not.
4. `"abc".contains("")` is false, so a catch-all transport rule matched nothing.
5. Centring the structure with a node pivot defeated camera fitting.
6. The camera distance ignored the aspect ratio, which was invisible on an
   iPhone and ran the structure off both sides of an iPad pane.
7. `SCNView.pointOfView` left nil meant every reframe silently did nothing.
