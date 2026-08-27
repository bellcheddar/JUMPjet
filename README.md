# 🛩️ JUMPjet

> **Vertical take-off conformational sampling: UniProt ID in, conformational movie out. No cluster, no queue, no cloud.**

![swift](https://img.shields.io/badge/swift-6.3-F05138?logo=swift&logoColor=white) ![ios](https://img.shields.io/badge/iOS%20%7C%20iPadOS-17%2B-000000?logo=apple&logoColor=white) ![swiftui](https://img.shields.io/badge/UI-SwiftUI-0071E3?logo=swift&logoColor=white) ![scenekit](https://img.shields.io/badge/3D-SceneKit-1C244B) ![charts](https://img.shields.io/badge/charts-Swift%20Charts-467FF7) ![physics](https://img.shields.io/badge/physics-torsional%20Monte%20Carlo-9b51e0) ![coreml](https://img.shields.io/badge/ML-Core%20ML%20%C2%B7%20ESM--2%20t6--8M-9b51e0) ![xcode](https://img.shields.io/badge/Xcode-26.6-1575F9?logo=xcode&logoColor=white) ![spm](https://img.shields.io/badge/packages-9%20local%20SPM-FA7343) ![tests](https://img.shields.io/badge/XCTest-237%20passing-00d084) ![deps](https://img.shields.io/badge/third--party%20dependencies-none-00897B) ![data](https://img.shields.io/badge/data-AlphaFold%20DB%20%C2%B7%20PDBe%20%C2%B7%20UniProt-467FF7) ![phase](https://img.shields.io/badge/phase-4%20of%204-467FF7) ![licence](https://img.shields.io/badge/licence-MIT-00897B) ![author](https://img.shields.io/badge/author-Marc%20C.%20Deller%2C%20D.Phil.-1C244B)

<table>
<tr>
<td>🌐 <b>Website</b></td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️ <b>Contact</b></td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙 <b>GitHub</b></td><td><a href="https://github.com/bellcheddar/JUMPjet" target="_blank" rel="noopener noreferrer">bellcheddar/JUMPjet</a></td>
</tr>
</table>

---

**J**ust-in-time **U**nified **M**odelling of **P**rotein **J**umps, **E**nsembles and **T**ransitions.

JUMPjet is a native Swift app for iPhone and iPad. Type a UniProt accession, and it pulls the best available structure, runs a crude short-timescale conformational simulation entirely on the device, and renders the trajectory as an interactive 3D playback plus an exportable movie. The scientific focus is discrete conformational events: rotamer jumps, aromatic ring flips, basin hopping and jump-diffusion statistics. That focus is what separates it from a generic structure viewer.

**Why it matters:** almost every tool that tells you how a protein moves needs a queue, a GPU node, or a subscription, and the answer arrives long after the question was interesting. A phone in your pocket has a capable GPU, a neural engine and no scheduler, and a torsion-space sampler is cheap enough to run there in seconds. The trade is honest and stated everywhere in the interface: this is crude sampling in pseudo-time, not femtosecond integration. It is useful for: building intuition about which loops and side chains are mobile before committing cluster hours, sanity-checking a predicted model's floppy regions against its own confidence, teaching conformational dynamics without a computing allocation, and producing a shareable movie of a protein breathing in under two minutes.

## 🧭 Context

JUMPjet is one of three related apps, and they deliberately do not overlap.

| App | Lane | Look |
|---|---|---|
| **BOFFIN** | Static analysis suite: variants, constructs, embeddings, viewing | Native light iOS |
| **FlexAppeal** | Heavyweight MD pipeline, OpenMM on a server GPU | marcdeller.com blue, web |
| **JUMPjet** | Fast crude dynamics on device, jump and transition analytics | Dark cockpit HUD |

Anything static-analysis flavoured belongs in BOFFIN's backlog, not here.

## ✨ Features

Phase 1 is complete and shipping the airframe.

| Feature | State |
|---|---|
| UniProt accession entry with live validity checking | ✅ Built |
| AlphaFold DB structures with per-residue pLDDT | ✅ Built |
| PDBe experimental structures as a fallback | ✅ Built |
| On-disk model cache keyed by accession, source and version | ✅ Built |
| PDB and mmCIF readers with a full CIF tokeniser | ✅ Built |
| SceneKit backbone tube, side-chain sticks, five colour modes | ✅ Built |
| Multi-chain handling with a chain picker | ✅ Built |
| Night Sortie HUD design system | ✅ Built |
| `JetEngine` torsional Monte Carlo sampler | ✅ Built |
| ESM-2 flexibility prior on the Neural Engine | ✅ Built |
| Live run instruments and a protein you can watch move | ✅ Built |
| Rotamer jumps, ring flips, basins, dwell times | ✅ Built |
| Validation panel: RMSF against the neural prior | ✅ Built |
| Tap-through from any analysis element to the 3D view | ✅ Built |
| Trajectory playback with a scrubber, ghost trail and event ticks | ✅ Built |
| H.264 movie export with HUD burn-in and a slow orbit | ✅ Built |
| Sortie report card, exportable as PNG | ✅ Built |

## 🧱 Stack

Pure Apple platform. No third-party dependency manager, nothing vendored, nothing to `pod install`.

| Layer | Technology |
|---|---|
| Interface | SwiftUI, Observation framework, async/await |
| 3D | SceneKit, per-vertex colour geometry built from raw buffers |
| Physics | Swift, written from scratch as `JetEngine`. Metal is the named next lever, not yet used |
| Machine learning | Core ML, ESM-2 t6-8M, 98% of operations planned on the Apple Neural Engine |
| Charts | Swift Charts, HUD-styled, with the raster and terrain map drawn in a `Canvas` |
| Movie | `SCNRenderer.snapshot` offscreen into `AVAssetWriter`, H.264 |
| Language | Swift 6 language mode, complete strict concurrency |

### Module graph

Nine local Swift packages, acyclic and shallow. The dependency rule is enforced by what each `Package.swift` is allowed to name.

```
JumpjetCore     (nothing)      structure model, chemistry, geometry, bonds
JumpjetHUD      (nothing)      Night Sortie design system
JumpjetParse    Core           PDB and mmCIF readers
JumpjetFetch    Core, Parse    UniProt, AlphaFold DB, PDBe, model cache
JumpjetViewer   Core, HUD      SceneKit renderer
JumpjetNeural   Core           ESM-2 on Core ML, the flexibility prior
JumpjetEngine   Core           JetEngine: torsional Monte Carlo
JumpjetAnalysis Core           the flight recorder
JumpjetMovie    Core, Viewer   offscreen renderer into AVAssetWriter
```

`JumpjetViewer` names `JumpjetParse` in its **test** target only, so the renderer never learns how a file was read while the tests still render real structures rather than hand-built toys.

Each package declares a macOS platform purely so `swift test` runs on the host without booting a simulator. That turns the inner loop from tens of seconds into about two.

## 📋 Requirements

| Requirement | Version |
|---|---|
| Xcode | 26.6 or later |
| Swift toolchain | 6.3 (packages build in Swift 6 language mode) |
| Deployment target | iOS / iPadOS 17.0 |
| Ruby `xcodeproj` gem | Only to inspect the project bootstrap, never to re-run it |

## 🚀 Usage

```bash
git clone https://github.com/bellcheddar/JUMPjet.git
cd jumpjet

# Every package's tests, on the host, no simulator, about two seconds
Tools/test-all.sh

# Build the app
xcodebuild -project JUMPjet.xcodeproj -scheme JUMPjet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

Open `JUMPjet.xcodeproj` in Xcode and run. Type an accession (`P69905`, `P04406`, `P07900` are the three test flights offered on the standby screen) and press LAUNCH.

### Loading an accession without touching the keyboard

`JUMPJET_AUTOLOAD` loads a structure on launch, which is how a screenshot or an interface test reaches a loaded structure without driving the keyboard (the flakiest part of any iOS UI test). Under `simctl` the variable needs the child prefix:

```bash
SIMCTL_CHILD_JUMPJET_AUTOLOAD=P69905 xcrun simctl launch <udid> com.mdeller.jumpjet
```

## 🎨 Design system: "Night Sortie"

Deliberately differentiated from its siblings: a dark cockpit rather than a light native app or a blue web dashboard.

| Token | Hex | Use |
|---|---|---|
| Background | `#0A0E14` | Near-black night flight |
| Panel | `#111826` | Instrument face, `#1E293B` 1 px border |
| Primary | `#00E676` | Phosphor green: live data, traces, running state |
| Accent | `#FFB300` | Afterburner amber: jump events, warnings, the RUN control |
| Text | `#E6EDF3` | Muted `#8B99A9` |

Numeric readouts use monospaced digits, because instruments do not use proportional figures: a value that jitters sideways as it counts is a value nobody can read at a glance. Gauges are thin-line dials and tape gauges (RMSD as an altimeter tape, acceptance ratio as engine RPM, temperature as a throttle lever), restrained rather than arcade.

Semantics never rely on colour alone. Every status role carries a distinct SF Symbol as well as a distinct colour, and that is a test rather than an intention.

## 🔬 Honesty about timescales

This is the ground rule the whole project is shaped around, and it is worth stating in the README rather than only in the code.

`JetEngine` is a torsion-space Monte Carlo and Brownian hybrid. **Frames are pseudo-time, not femtosecond integration.** The interface labels the axis "MC sweeps" or "effective time (arb.)", never picoseconds, and dwell times and jump rates are reported in sweeps. The About screen says "crude on-device sampler" in those words.

The same principle runs through Phase 1. The parser reports everything it discarded (waters, ligands, alternate locations, extra models) instead of quietly showing two thirds of a file. The confidence colour scale is offered only for predicted structures, because putting a 1.5 Å crystal structure's B-factors on a prediction's certainty axis is a category error. And every structure carries its provenance in the sortie panel: JUMPjet never shows a model without saying which one it is and where it came from.

## 📊 Data sources

| Source | Used for | Licence |
|---|---|---|
| [AlphaFold DB](https://alphafold.ebi.ac.uk) | Predicted structures, per-residue pLDDT | CC BY 4.0 |
| [PDBe](https://www.ebi.ac.uk/pdbe/) | Best-structure mappings, experimental mmCIF | CC0 for entries |
| [UniProtKB](https://www.uniprot.org) | Protein name, organism, sequence | CC BY 4.0 |

The model version is read from the AlphaFold API on every fetch and never hard-coded: the build plan was written when v4 was current and the database was serving v6 by the time the fixtures were recorded. Full attribution in [`Docs/ATTRIBUTIONS.md`](Docs/ATTRIBUTIONS.md).

## 🧪 Tests

237 tests across nine packages, host-side, no simulator, plus five interface
tests that need a simulator.

They run in **release**. `swift test` builds debug by default, and for the physics
package that is a factor of thirty-six, which makes the suite unusable and any
benchmark meaningless.

| Package | Tests | Covers |
|---|---|---|
| JumpjetCore | 39 | Dihedrals, Kabsch, RMSD, chemistry tables, bond inference |
| JumpjetFetch | 25 | Client decoding, fallback chain, cache, offline, version busting |
| JumpjetHUD | 16 | Gauge scales, tick generation, formatting, accessibility roles |
| JumpjetParse | 25 | Both readers, real files and hand-built edge cases |
| JumpjetViewer | 34 | Spline, tube sweep, colour scales, scene graph, camera fitting |
| JumpjetNeural | 13 | Tokeniser, Core ML parity against PyTorch, stride handling, the prior |
| JumpjetEngine | 36 | Topology, each energy term against hand-computed values, the sampler |
| JumpjetAnalysis | 40 | Jump and flip detection against planted transitions, PCA, basins |
| JumpjetMovie | 8 | Presets, and a written file read back with AVFoundation |

The strongest tests parse the PDB **and** the mmCIF of the same entry and compare them atom for atom, on both an AlphaFold prediction and a four-chain crystal structure. They check one reader against the other rather than against a number somebody wrote down, so a mistake in either surfaces without anyone having to predict it.

The fetch suite runs with no network at all: a recorded transport answers from fixtures, so the suite passes in a tunnel, and a test that depended on what EBI was serving this morning would tell you about EBI rather than about JUMPjet.

## ✅ To Do

Roadmap for JUMPjet, in dependency order (a phased build reads better that way). Full specification in [`Docs/JUMPJET_BUILD_PLAN.md`](Docs/JUMPJET_BUILD_PLAN.md).

### Phase 1: Airframe (complete)

- [x] **Project scaffold as local Swift packages.** Five modules with an acyclic dependency graph enforced by the manifests, and a macOS platform on each so `swift test` runs on the host with no simulator. `JUMPjet.xcodeproj` is committed and is the source of truth; `Tools/bootstrap-xcodeproj.rb` records its origin and must never be re-run to regenerate it
- [x] **Night Sortie HUD design system.** The build plan's six hex values, monospaced-digit readouts, tape and dial gauges, the amber RUN control. The gauge maths lives in plain values rather than in the view, because a gauge that mislabels its ticks lies quietly and no screenshot catches it
- [x] **Fetch module: UniProt, AlphaFold DB, PDBe.** Behind an injectable transport, with an actor-backed disk cache keyed by accession, source **and** version. Keying on the accession alone would serve a superseded prediction for as long as the app stays installed, and say nothing about it
- [x] **Accession validation before the first request.** Against the UniProtKB grammar, so a typo costs no network. Isoform suffixes are split off and kept rather than rejected
- [x] **PDB and mmCIF readers.** PDB by fixed column, mmCIF by a real tokeniser handling quoting, semicolon text fields, comments and nulls. One builder applies every dropping policy for both and reports what it dropped
- [x] **SceneKit viewer.** Catmull-Rom backbone tube swept with a parallel-transport frame, side chains merged into a single geometry, five colour modes including the official AlphaFold pLDDT bands
- [x] **Cockpit layout for iPhone and iPad.** Splits side-by-side when the window is wider than it is tall and stacks otherwise. Size class was the wrong signal: an iPad is `.regular` in both orientations, and a portrait split leaves the viewer a pane twice as tall as it is wide
- [ ] **Measure 60 fps on an A16 at 600 residues.** The build plan's frame-rate target is the one part of Phase 1's definition of done that is **not** met: there was no device to hand, and a simulator frame rate says nothing about a phone

### Phase 2: Engines

- [x] **Converted ESM-2 t6-8M to Core ML.** 15.0 MB against a ~16 MB target, fp16, enumerated shapes over six sequence buckets. Three tracing traps were inherited from the sibling BOFFIN project rather than rediscovered, and each produces a model that converts, saves and predicts while returning wrong numbers: a padding branch baked out by tracing on an unpadded example, rotary tables frozen at the traced length, and `EnumeratedShapes` over a batch dimension
- [x] **Flexibility prior, trained on nothing.** Normalised inverse pLDDT and an embedding disorder proxy, 70/30. **The proxy is not the one the plan specified**: Euclidean distance to the nearer centroid separates nothing (Cohen's d −0.023), because the two centroids are 1.32 apart against a within-class spread of 4.60 and the measurement is swamped by a global mean every residue shares. Removing that mean and comparing directions gives d +1.024 and AUC 0.801
- [x] **ANE dispatch checked and reported truthfully.** 382 of 391 operations planned on the Neural Engine, none on the GPU. The HUD says "ANE 98% planned", because `MLComputePlan` answers "can these run there" and not "how fast". In the simulator it correctly reads "GPU/CPU fallback": a simulator has no Neural Engine
- [x] **`JetEngine`: all-atom, torsional degrees of freedom only.** Topology derived by splitting the bond graph, which gets proline's ring-locked φ and disulfide-bonded cysteines right for free. The smaller side of each torsion rotates, which is free because every energy term is a function of internal coordinates
- [x] **Energy terms, each tested against a hand-computed value.** Elastic network softened by the prior, soft-sphere sterics on a spatial hash grid, and Ramachandran and χ tables derived from 55 AlphaFold models rather than hand-placed. Property tests do not catch a wrong constant
- [x] **Metropolis with a mixed move set.** Gaussian perturbations, discrete well-to-well χ1 jumps and 180° ring flips. Without the discrete moves the app's own subject matter is unreachable: a Gaussian small enough to be accepted essentially never crosses a 120° barrier
- [x] **Live HUD readouts, and the protein visibly moving.** Acceptance as an RPM dial, sweeps per second, RMSD as an altimeter tape, energy, and the viewer following the trajectory as it is generated
- [x] **Deterministic replay from a seed**, acceptance calibrated to 0.39 inside the required 20–60% band, and a 50,000-sweep stability check on three proteins behind `JUMPJET_LONGRUN=1`
- [x] **Hit 100 sweeps/s at 300 residues.** Met: **506 sweeps/s at 142 residues and 124 at 335**, up from 131 and 22. Not by writing the Metal kernel the plan names, which would not have helped (a Metropolis move needs its energy delta before the next can be proposed, so every dispatch is a synchronous round trip: 7,400 a second against tens of microseconds each). It was the move mix. A backbone pivot costs ~100x a side-chain move, and 22% of proposals were going there; it is now 3%. Measured at equal wall clock, that buys 5.5x the side-chain moves for a quarter fewer backbone ones and 7 points of mid-chain coverage
- [x] **An optimisation written, measured and switched off.** Cost-weighted backbone selection is legitimate (a rotation is its own reverse, so fixed weights preserve detailed balance) and 2x faster, and it starves the chain: mid-chain coverage 55% down to 36%. It is left in, defaulted off. It looked fine at first because mean displacement barely moved — a mid-chain pivot shifts hundreds of atoms whenever it lands, so a starved torsion and a well-sampled one measure the same. Counting accepted moves is what showed it
- [ ] **Backbone H-bond term.** A stretch goal in the plan, conditional on the phase running ahead. It did not
- [ ] **Overdamped Brownian mode.** A later toggle, still later

### Phase 3: Flight recorder

- [x] **Per-trajectory basics.** RMSD against frame 0 by Kabsch superposition, radius of gyration, per-residue RMSF. Every frame is superposed first, because the sampler rotates whichever side of a torsion is smaller and the molecule therefore tumbles in the lab frame
- [x] **Validation panel with Spearman ρ.** Rank correlation, not Pearson: RMSF is in angstroms and the prior is on 0 to 1, and there is no reason they should be linearly related. It reports whatever it finds (0.19 on one run, 0.38 on another), because the build plan asked for a disagreement to be visible
- [x] **Rotamer jump detection with a raster.** χ1 into g−/g+/t with 30° tolerance bands. A frame in no-man's-land **inherits the previous state**, without which a side chain rattling in the gap reports hundreds of jumps having never changed rotamer. There is a test that does exactly that rattling and expects zero
- [x] **Symmetry-aware ring flips.** Phe and Tyr only. The same 180° that IS a flip is NOT a rotamer jump, and both facts come from one symmetry, so one module owns both
- [x] **Basins, dihedral PCA, terrain map, dwell times, jump matrix.** PCA on sin and cos of φ and ψ, because a residue oscillating about 180° gives values near +180 and near −180 and a linear method calls that the largest motion in the protein (4° circular against 150° linear on the same data). k by silhouette, capped at 5. Everything deterministic
- [x] **Tap-through to the residue or frame** in the 3D viewer, with the tapped residue drawn in the HUD's amber
- [x] **All six panels in 0.02 s** for 335 residues and 201 frames, against a five-second budget
- [ ] **Interpret the jump rate honestly in the docs as well as the app.** 5,000 sweeps of a 335-residue protein gives 15,889 jumps, which is the sampler proposing rotamer moves 22% of the time rather than thermal barrier hopping. The panel says so; a future round should decide whether a jump statistic is worth reporting at all when the move set proposes the jumps

### Phase 4: Airshow

- [x] **Trajectory playback.** Scrubber, transport, 0.5–4× speed, loop and a ghost trail drawn as a thin Cα trace (four full tubes at 30 fps buries the structure it is a trail of)
- [x] **Event ticks on the scrub bar, but not as specified.** Ticking every frame with a rotamer jump gives a *solid amber band*, because a 5,000-sweep run has a jump in essentially every stored frame. It now marks every ring flip (67 against 15,889 jumps) and the busiest tenth of jump frames, which leaves marks worth pressing "next event" to reach
- [x] **Movie export.** Offscreen `SCNRenderer.snapshot` into `AVAssetWriter`, H.264, 1080p and square 720 at 30 fps, optional HUD burn-in and slow orbit, share sheet. Verified by reading the written file back with AVFoundation: a video track, the right dimensions, the right duration
- [x] **Sortie report card** at a fixed 1000×1400, so a card made on a phone and one made on an iPad are the same picture
- [x] **Haptics on the event ticks**, fired on the crossing rather than on every touch move: a continuous buzz through a drag is noise
- [x] **Accessibility labels on every custom-drawn view.** The raster, terrain map, transition matrix and scrubber are `Canvas` and `Grid` and have no text of their own
- [x] **TestFlight archive checklist** in [`Docs/TESTFLIGHT.md`](Docs/TESTFLIGHT.md), including what is still blocked
- [x] **A real app icon**, drawn by [`Tools/make-app-icon.py`](Tools/make-app-icon.py): a backbone helix passing behind itself with one segment amber, which is the jump. Stamped discs rather than a wide polyline, because PIL's `joint="curve"` fans spikes out of every joint that read as a hatching artefact at icon size. Asserted RGB, since the App Store rejects an alpha channel
- [x] **A verified App Store archive.** 16 MB bundle, 15.2 MB IPA, signed `Apple Distribution` against the `JUMPjet App Store` profile. [`Tools/appstore/verify-archive.sh`](Tools/appstore/verify-archive.sh) opens the archive and checks the models, both icon variants, the signing authority and the embedded profile: `ARCHIVE SUCCEEDED` says nothing about the contents, and a sibling project's first successful archive was validly signed and contained no models at all
- [ ] **Verify the two-minute end-to-end demo on a device.** Measured in the simulator after the throughput work: a 335-residue protein, 5,000 sweeps, loaded, sampled and fully analysed with the export panel ready **inside 50 seconds**. A simulator has the Mac's CPU and no Neural Engine, so that figure is optimistic on sampling and pessimistic on the embedding. The number that matters still needs hardware

### Outstanding decisions

- [x] **Licence chosen: MIT.** Based on what is actually redistributed: ESM-2's weights are MIT and every build-time dependency is MIT or BSD-3-Clause, so nothing in the chain is copyleft. Bundled data keeps its own terms (AlphaFold-derived files CC BY 4.0, PDB 1BAB CC0) and the licence file says so, because CC BY permits any licence on derivatives only while attribution survives
- [x] **Pushed to GitHub** at [bellcheddar/JUMPjet](https://github.com/bellcheddar/JUMPjet)
- [x] **Apple Developer team**, taken from `$APPLE_TEAM_ID` and written to a gitignored `Config/Signing.xcconfig` so no account identifier sits in this public repo, with Release signing manually against `Apple Distribution` and the `JUMPjet App Store` profile, and Debug left automatic so a device build from Xcode still just works. Reapplied idempotently by [`Tools/configure-signing.rb`](Tools/configure-signing.rb)
- [x] **The App Store Connect app record and the whole listing.** The record itself was the one step the API cannot do (`POST /v1/apps` returns 403, "the resource 'apps' does not allow 'CREATE'"); everything after it is scripted in [`Tools/appstore/`](Tools/appstore): copy, categories, age rating, free pricing in 175 territories, the licence agreement, the review contact, 15 screenshots and the build upload
- [x] **Privacy policy and support pages** on GitHub Pages, live before being handed to Apple, which rejects a privacy URL that does not resolve. Two traps: `Docs` and `docs` are one directory on a case-insensitive Mac and two on GitHub, and Jekyll silently refuses to publish any path starting with an underscore
- [x] **Shipped as 1.0, not 0.1.0.** App Store Connect groups builds by their short version string, so a 0.1.0 build landed in a 0.1.0 train and was not selectable for the 1.0 version record at all
- [ ] **App Privacy**, the last step before review and the second thing Apple does not expose over the API: no privacy relationship on `/apps`, and the documented `appDataUsages` resources 404. One answer in the App Store Connect UI, since JUMPjet collects nothing

## 📝 Changes

Per-phase detail, including what was deliberately deferred and the bugs found along the way, is in [`Docs/CHANGELOG.md`](Docs/CHANGELOG.md).

Findings worth not rediscovering (the dihedral sign convention, Kabsch on rank-deficient point sets, why `"abc".contains("")` is false, and four separate camera bugs that were invisible until the app was on a real screen) are recorded in [`CLAUDE.md`](CLAUDE.md).

## 📄 Licence

**MIT**, in [`LICENSE`](LICENSE), with the bundled models and data itemised in
[`NOTICE`](NOTICE). Chosen to match what the repository actually
redistributes rather than by habit: the only third-party artefact shipped here is
a Core ML conversion of ESM-2, which is itself MIT, and every build-time
dependency (fair-esm, PyTorch, coremltools, NumPy) is MIT or BSD-3-Clause.
Nothing in the chain is copyleft or share-alike.

The bundled DATA is not code and keeps its own terms, which the licence file
spells out: the AlphaFold-derived torsion tables, flexibility centroids and
fixture structures are CC BY 4.0, so attribution has to travel with them, and
PDB entry 1BAB is CC0. CC BY 4.0 permits derivative works under any licence
provided that attribution is preserved, which is what makes MIT on the code and
CC BY on the data a coherent pair rather than a conflict.

---

## 👤 Author

**Marc C. Deller, D.Phil.**  
Structural biologist & drug discovery scientist  

<table>
<tr>
<td>🌐</td><td><a href="https://marcdeller.com" target="_blank" rel="noopener noreferrer">marcdeller.com</a></td>
<td>✉️</td><td><a href="mailto:marc@marcdeller.com">marc@marcdeller.com</a></td>
<td>🐙</td><td><a href="https://github.com/bellcheddar/JUMPjet" target="_blank" rel="noopener noreferrer">github.com/bellcheddar/JUMPjet</a></td>
</tr>
</table>
