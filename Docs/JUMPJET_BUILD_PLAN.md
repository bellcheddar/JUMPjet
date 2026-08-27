# JUMPjet — 4-Phase Build Plan for Claude Code

> **J**ust-in-time **U**nified **M**odelling of **P**rotein **J**umps, **E**nsembles and **T**ransitions
>
> Vertical take-off molecular dynamics: UniProt ID in, conformational movie out. No cluster, no queue, no cloud.

**Author:** Marc C. Deller, D.Phil. · marcdeller.com · marc@marcdeller.com
**Target:** iPhone and iPad, SwiftUI, iOS 17+, Swift 5.10+
**Version:** v1 plan, August 2026

---

## 1. What JUMPjet is

A native Swift app that takes a UniProt accession, pulls the best available structure, runs a crude short-timescale conformational simulation entirely on device, and renders the trajectory as an interactive 3D playback plus an exportable movie. The scientific focus is discrete conformational events: rotamer jumps, aromatic ring flips, basin hopping and jump-diffusion statistics, which is what distinguishes it from a generic viewer.

**Sibling apps and their lanes (do not overlap):**

| App | Lane | Style |
|---|---|---|
| BOFFIN | Static analysis suite: variants, constructs, embeddings, viewing | Native light iOS |
| FlexAppeal | Heavyweight MD pipeline, OpenMM on server GPU | marcdeller.com blue web brand |
| **JUMPjet** | **Fast crude dynamics on device, jump/transition analytics** | **Dark cockpit HUD (see §5)** |

---

## 2. Engineering ground rules (read before writing any code)

1. **OpenMM has no iOS port.** It is C++/CUDA/OpenCL with no Metal platform. Do NOT attempt to cross-compile it. JUMPjet ships a purpose-built, OpenMM-*inspired* engine written in Swift + Metal (spec in Phase 2). Name it `JetEngine` internally.
2. **The ANE only executes Core ML graphs.** The physics inner loop therefore runs on GPU (Metal) and CPU (Accelerate/SIMD). The ANE's genuine job is the ML layer: an ESM-2 (t6, 8M) Core ML conversion producing per-residue embeddings and a small MLP head that outputs per-residue flexibility priors. These priors parameterise the force field (restraint strengths, move amplitudes). Verify ANE dispatch with the Core ML Instruments template; do not just claim it.
3. **Honesty about timescales.** The engine is a torsion-space Monte Carlo / Brownian hybrid. Frames are pseudo-time, not femtosecond integration. The UI must label the axis "MC sweeps" or "effective time (arb.)", never picoseconds. Dwell times and jump rates are reported in sweeps.
4. Swift/iOS best practice throughout: SwiftUI + Observation framework, async/await, no third-party dependency managers unless unavoidable. Unit tests for the physics core and parsers from Phase 1 onward.
5. British English in all UI copy and comments. No em dashes.

---

## 3. Architecture (module map)

```
JUMPjet/
├── App/                  # SwiftUI app entry, navigation, HUD design system
├── Fetch/                # UniProt + AlphaFold DB + PDBe clients, model cache
├── Parse/                # PDB/mmCIF parser → Structure model (all-atom)
├── JetEngine/            # Physics core: energy terms, Metal clash grid, MC/BD sampler
├── Neural/               # Core ML: ESM-2 t6-8M, flexibility head, ANE verification
├── Viewer3D/             # SceneKit renderer: backbone tube + sticks, trajectory playback
├── Analysis/             # RMSD/RMSF/Rg, χ1 jumps, ring flips, dPCA, basins, dwell times
├── Movie/                # Offscreen SCNRenderer → AVAssetWriter H.264 export
└── Tests/                # XCTest: parsers, Kabsch, energy terms, jump detection
```

---

## Phase 1 — Airframe (project, fetch, parse, view)

**Goal:** open the app, type `P0DTD1` or `P69905`, see the structure in 3D within seconds.

Tasks:

1. Xcode project scaffold, SwiftUI, iPhone + iPad size classes, dark-only appearance.
2. HUD design system as a small token library (colours, gauge components, monospaced digit styles; spec in §5).
3. `Fetch` module:
   - UniProt metadata: `GET https://rest.uniprot.org/uniprotkb/{accession}.json` (name, organism, length, sequence).
   - Structure: AlphaFold DB first, `GET https://alphafold.ebi.ac.uk/api/prediction/{accession}`, download the PDB/mmCIF URL returned for the latest model version. Keep the per-residue pLDDT (B-factor column) — it feeds the flexibility prior in Phase 2.
   - Fallback: PDBe best structures, `GET https://www.ebi.ac.uk/pdbe/api/mappings/best_structures/{accession}`, take the top entry.
   - On-disk cache keyed by accession + source + model version. Sensible errors for bad accessions and offline mode.
4. `Parse`: minimal, robust PDB and mmCIF reader → `Structure` (chains, residues, atoms, elements, coordinates, per-residue pLDDT if present). Handle multi-chain by defaulting to the longest chain with a picker for the rest. Cap at ~1,200 residues for v1 with a clear message beyond that.
5. `Viewer3D`: SceneKit scene with (a) Cα tube/ribbon approximation, (b) stick side chains toggle, (c) colour modes: chainbow, pLDDT, flexibility prior (Phase 2). Orbit/pinch/pan. 60 fps on an A16 or better for ≤600 residues.

**Definition of done:** cold start → structure on screen for three test accessions (small ~100 aa, medium ~300 aa, large ~800 aa); parser unit tests pass on AFDB PDB, AFDB mmCIF and one experimental PDBe file; offline relaunch loads from cache.

---

## Phase 2 — Engines (JetEngine physics + Neural priors on ANE)

**Goal:** press RUN and watch the protein breathe, with the ANE demonstrably doing the ML work.

### Neural (build first, it parameterises the physics)

1. Convert ESM-2 t6-8M (facebook/esm2_t6_8M_UR50D) to Core ML via coremltools, fp16, fixed max length 1,200 with attention masking. Ship the `.mlpackage` in the bundle (~16 MB fp16 target).
2. Small MLP head on mean-pooled + per-token embeddings → per-residue flexibility score in [0, 1]. For v1, train nothing: combine (a) normalised inverse pLDDT, (b) an embedding-derived disorder proxy (distance to helix/sheet centroid embeddings computed offline), weighted 70/30. Document this as a heuristic so a learned head can replace it later.
3. Verify ANE execution with `MLComputeUnits.all` and the Core ML Instruments trace; surface a small "ANE ✓" indicator in the HUD when the compiled plan maps to the Neural Engine, "GPU/CPU fallback" otherwise. No silent lying.

### JetEngine

Representation: all-atom, torsional degrees of freedom only (φ, ψ, χ₁…χₙ; bond lengths and angles fixed). This keeps rotamers and ring flips first-class citizens, which a Cα-only model cannot do.

Energy terms:

| Term | Form | Notes |
|---|---|---|
| Fold restraint | Cα elastic network, harmonic pairs within 11 Å cutoff | Spring constant scaled DOWN by per-residue flexibility prior: floppy loops move, cores hold |
| Sterics | Soft-sphere repulsion, element vdW radii × 0.85 | Metal compute: spatial hash grid rebuilt every N sweeps, neighbour lists on GPU |
| Torsion statistics | Simplified backbone-dependent rotamer potential | Bundle a compact binned table (Dunbrack-style wells at χ₁ ≈ −60°/60°/180°); backbone φψ Ramachandran bias |
| H-bond (stretch goal) | Distance + angle scored backbone donors/acceptors | Only if Phase 2 is ahead of schedule |

Sampler: Metropolis Monte Carlo with a mixed move set, kT tunable ("throttle"):

- Small Gaussian torsion perturbations, amplitude ∝ flexibility prior (lever-arm damage absorbed by the elastic network).
- Discrete rotamer jump proposals: pick a residue, propose a well-to-well χ₁ change.
- Ring-flip proposals: 180° χ₂ flips for Phe/Tyr.
- Optional overdamped Brownian mode (torsional Langevin) as a later toggle; MC is the v1 workhorse because correctness is easy to test.

Controls: sweeps (default 5,000), temperature/throttle, snapshot stride, seed. Live HUD readouts during the run: acceptance ratio, energy, RMSD from start, sweeps/s. Target ≥100 sweeps/s for a 300-residue protein on an A17/M-series device; degrade gracefully with a residue-count warning.

**Definition of done:** deterministic replay from a seed; energy conservation sanity (no runaway explosions across 50k sweeps on three test proteins); acceptance ratio between 20 and 60% at default throttle; unit tests for each energy term against hand-computed values; ANE indicator verified in Instruments.

---

## Phase 3 — Flight Recorder (jump analytics)

**Goal:** the analysis that earns the backronym. All charts in Swift Charts, HUD-styled.

1. **Per-trajectory basics:** RMSD vs sweep (Kabsch superposition onto frame 0), radius of gyration vs sweep, per-residue RMSF.
2. **Validation panel:** RMSF vs the ANE flexibility prior, plotted per residue with Spearman ρ displayed. If the engine and the prior disagree wildly, Marc wants to see it, not have it hidden.
3. **Rotamer jumps:** χ₁ state assignment per frame into g−/g+/t wells (±60°, 180°, with 30° tolerance bands; frames in no-man's-land inherit the previous state). Output: transition counts per residue, a jump raster (residue × sweep), top-10 most jump-happy residues.
4. **Ring flips:** Phe/Tyr χ₂ flip detection (symmetry-aware, so 180° apart = flipped), flip counts and locations highlighted in the 3D viewer.
5. **Basins and jump diffusion:** dihedral PCA on sin/cos(φ, ψ) of flexible residues → project trajectory onto PC1/PC2 → 2D occupancy landscape rendered as −ln(density) contours ("terrain map") → k-means (k chosen by silhouette, capped at 5) basin assignment → dwell-time histograms per basin and a basin-to-basin jump matrix. All rates reported in sweeps, per ground rule 3.
6. Tap any analysis element → the 3D viewer jumps to that residue/frame.

**Definition of done:** all six panels populate for a 5,000-sweep run of a 300-residue protein in under 5 s of post-processing; jump detection unit-tested against a synthetic trajectory with known planted transitions; symmetry-aware ring-flip test passes.

---

## Phase 4 — Airshow (playback, movie export, polish)

**Goal:** the shareable payoff.

1. Trajectory playback: scrubber, play/pause, 0.5–4× speed, loop, ghost-trail toggle (previous N frames at low opacity), jump events flagged on the scrub bar as tick marks.
2. Movie export: offscreen `SCNRenderer` → `CVPixelBuffer` → `AVAssetWriter`, H.264 .mp4, 1080p and square 720p presets, 30 fps, optional HUD burn-in (accession, sweep counter, RMSD gauge) and optional slow orbit during playback. Share sheet + save to Photos.
3. Sortie report: one summary card (accession, source model, sweeps, jumps detected, flips, basin count, headline RMSF hotspots) exportable as PNG alongside the movie.
4. Polish: haptics on jump-event scrub ticks, empty/error states, iPad two-pane layout (viewer left, instruments right), accessibility labels, App Store-ready icon placeholder (final icon via marcs-vibe-icon skill), TestFlight archive checklist.

**Definition of done:** end-to-end demo in under two minutes on device: enter accession → run 5,000 sweeps → review analytics → export movie → AirDrop it. No crashes across the three test accessions; movie plays in Photos and QuickTime.

---

## 5. Design system: "Night Sortie" HUD

Deliberately differentiated: BOFFIN is light native iOS, FlexAppeal is marcdeller-blue web. JUMPjet is a dark cockpit.

- **Background:** near-black night flight `#0A0E14`; panels `#111826` with 1 px `#1E293B` borders.
- **Primary HUD:** phosphor green `#00E676` for live data, traces and the running state.
- **Alert/accent:** afterburner amber `#FFB300` for jump events, warnings and the RUN control.
- **Text:** `#E6EDF3`; muted `#8B99A9`. Numeric readouts in monospaced digits (SF Mono / `.monospacedDigit()`), because instruments do not use proportional figures.
- **Gauge language:** thin-line dials and tape gauges. RMSD as an altimeter tape, Rg as an airspeed dial, acceptance ratio as engine RPM, temperature as throttle lever. Restrained: instruments, not arcade.
- **Wordmark:** JUMPjet in Baloo 2 on the launch/about screen only; in-app chrome stays instrument-clean.
- Semantics as accessible tokens: never colour alone; jump ticks also get shape/haptic.

---

## 6. Risks and pre-agreed answers

| Risk | Answer |
|---|---|
| ESM-2 layers fall off the ANE (unsupported ops) | fp16, fixed shapes, no dynamic control flow; accept partial ANE mapping but report it truthfully in the HUD |
| Torsion MC too slow on big proteins | Residue cap + Metal clash grid + move-set locality; profile in Phase 2 before adding terms |
| Lever-arm blow-ups from backbone moves | Elastic network absorbs them; amplitude scaled by flexibility prior; reject on clash energy spike |
| Anyone mistaking this for real MD | Ground rule 3: pseudo-time labelling everywhere, "crude on-device sampler" wording in the About screen |
| Scope creep toward BOFFIN | Anything static-analysis flavoured gets parked in the BOFFIN backlog, not built here |

---

## 7. How to run this plan in Claude Code

Work one phase per session. Start each session with: "Read jumpjet_build_plan_v1.md. We are in Phase N. Review the Definition of done for the previous phase, verify it, then proceed." Do not advance phases with failing tests. Commit at each Definition of done with tag `phase-N-complete`.
