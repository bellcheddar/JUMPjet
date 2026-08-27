# Changelog

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
