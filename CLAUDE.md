# CLAUDE.md

Working agreement for the JUMPjet repository. Read this at the start of every session.

**JUMPjet** = Just-in-time Unified Modelling of Protein Jumps, Ensembles and Transitions.
A SwiftUI app for iOS and iPadOS: UniProt accession in, on-device conformational
movie out. Crude short-timescale sampling and jump analytics, no cluster, no queue,
no cloud.

Full specification: `Docs/JUMPJET_BUILD_PLAN.md`. That document is authoritative.
This file is the short version plus current state.

---

## Current state

- **Phase:** all four complete. See `Docs/CHANGELOG.md` for what each one did
  and did not meet.
- **Last completed:** Phase 4, 2026-08-27
- **Shipped:** MIT licence (`LICENSE` + `NOTICE`), public repo at
  `bellcheddar/JUMPjet`, distribution signing, app icon, privacy and support
  pages on GitHub Pages, and the App Store Connect listing in full: app record
  `JUMPjet ANE` (id `6806044657`), copy, categories, age rating, free pricing,
  15 screenshots across three sizes, and build 2 of 1.0 attached to the
  version.
- **Blocked on:** **App Privacy**, which Apple does not expose over the API and
  which needs one answer from Marc in the App Store Connect UI. Everything else
  is done. See `Docs/TESTFLIGHT.md`.
- **Tests:** 237 across nine packages, `Tools/test-all.sh`, host-side, plus five
  interface tests that need a simulator.
- **Open against the plan:** nothing measurable on this machine. Throughput is
  met (124 sweeps/s at 335 residues against a target of 100 at 300). What is
  unverified needs a DEVICE: the two-minute end-to-end demo and 60 fps at 600
  residues.

---

## Ground rules from the build plan

These are not negotiable and they are the reason several things are shaped
oddly. Re-read section 2 of the build plan before arguing with any of them.

1. **OpenMM has no iOS port.** Do not attempt to cross-compile it. The Phase 2
   engine is a purpose-built Swift and Metal sampler called `JetEngine`.
2. **The ANE only executes Core ML graphs.** The physics runs on GPU and CPU.
   The ANE's real job is the ESM-2 embedding and the flexibility head. Verify
   ANE dispatch in Instruments; do not claim it.
3. **Pseudo-time, never picoseconds.** Frames are MC sweeps. The axis says so.
4. Swift and iOS best practice: SwiftUI, Observation, async/await, no third-party
   dependency managers. Unit tests for the physics core and the parsers.
5. **British English in all UI copy and comments. No em dashes.**

---

## Module graph

Local Swift packages under `Packages/`. The dependency rule is enforced by what
each `Package.swift` is allowed to name, and it is acyclic and shallow.

```
JumpjetCore     (nothing)          structure model, chemistry, geometry, bonds
JumpjetHUD      (nothing)          Night Sortie design system
JumpjetParse    Core               PDB and mmCIF readers
JumpjetFetch    Core, Parse        UniProt, AlphaFold DB, PDBe, model cache
JumpjetViewer   Core, HUD          SceneKit renderer
                (+ Parse in TESTS ONLY, so the renderer never learns about files)
```

All nine packages exist. Add any new one to `PACKAGES` in `Tools/bootstrap-xcodeproj.rb` for the
record, and to the app target in Xcode.

`JUMPjet.xcodeproj` is committed and is the source of truth. `Tools/bootstrap-xcodeproj.rb`
records its ORIGIN and must not be re-run to "regenerate" it: doing so discards
every change made in Xcode since.

---

## Running things

```bash
Tools/test-all.sh                 # every package, on the host, about two seconds
cd Packages/JumpjetCore && swift test
xcodebuild -project JUMPjet.xcodeproj -scheme JUMPjet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

`JUMPJET_AUTOLOAD=P69905` in the app's environment loads that accession on
launch, which is how a screenshot or a test reaches a loaded structure without
driving the keyboard. Under `simctl` the variable needs the child prefix:

```bash
SIMCTL_CHILD_JUMPJET_AUTOLOAD=P69905 xcrun simctl launch <udid> com.mdeller.jumpjet
```

---

## Findings worth not rediscovering

### Geometry

- **The cross-product order in a dihedral IS the sign convention.** `b2 x n1`
  gives the IUPAC sign; `n1 x b2` gives every torsion in the app the wrong sign,
  and a self-consistent test suite passes either way. The test constructs four
  atoms whose torsion is known by construction rather than by running the
  function and writing down the answer.
- **A torsion is INVARIANT under reversing the atom order**, not negated. The
  intuitive guess fails against a correct implementation.
- **Kabsch on rank-deficient point sets.** One-sided Jacobi leaves the left
  columns for vanishing singular values EMPTY, and substituting fixed basis
  vectors destroys orthonormality: the result is a "rotation" with determinant
  zero that maps the points nowhere near each other. Complete the basis instead,
  and sort the singular values first, because the reflection fix needs the
  smallest one and Jacobi does not sort.

### Parsing

- **PDB is column-oriented; mmCIF is not.** Slicing the first six characters of
  an mmCIF line drops every `ATOM` (five characters, so the slice reads into the
  next field) while `HETATM` survives by being exactly six long. The result is a
  structure containing only its ligands, which looks like an empty protein
  rather than like a bug.
- **The atom-name column alignment is what separates an alpha carbon from a
  calcium ion** when the element column is missing, which truncated files do.
- **Prefer `auth_*` over `label_*`.** `label_seq_id` is a one-based internal
  index, and falling back to it silently renumbers the whole protein.
- **Alternate locations: highest occupancy wins.** The minor conformer routinely
  appears FIRST, so first-seen and last-seen policies both put the side chain in
  the wrong place with no error.
- The strongest tests in the suite parse the PDB and the mmCIF of the same entry
  and compare them atom for atom. They check one reader against the other rather
  than against a number anyone wrote down.

### Fetch

- **`"abc".contains("")` is FALSE in Swift.** A catch-all match rule written as
  the empty string matches nothing at all.
- **AlphaFold DB's model version moves.** The build plan was written at v4; v6
  was current when the fixtures were recorded. Read it from the API, key the
  cache on it, and never hard-code a file URL.
- **PDBe answers a query for a secondary accession under the PRIMARY one**, so
  looking up the key you asked for returns nothing.

### Rendering

- **Parallel transport, not a fixed up-vector.** A cross-section frame rebuilt
  from a fixed up-vector corkscrews wherever the path turns towards that vector,
  which on a helix is a visible twist that is not in the protein.
- **Centre the geometry, not the node's pivot.** A pivot centres the structure on
  screen and leaves the node's BOUNDING BOX where the file put it, which defeats
  every camera-fitting routine: they fit a volume tens of angstroms from anything
  visible.
- **SceneKit applies `fieldOfView` to ONE dimension** (`.automatic` picks the
  larger). A distance derived as though 45 degrees covered both looks perfectly
  framed on a squarish iPhone panel and runs the structure off both sides of a
  tall iPad pane. Set `projectionDirection` explicitly and fit the tighter of
  the two angles.
- **`radius / sin(halfAngle)`, not `tan`.** The near face of a sphere is closer
  than its centre.
- **SwiftUI does not call `updateUIView` when only the BOUNDS change.** A
  representable that frames its camera there frames it against whatever size it
  was first measured at and never corrects. Drive it from `layoutSubviews`.
- **`SCNView.pointOfView` left nil means the camera is resolved at RENDER time**,
  so `defaultCameraController` has nothing to act on and every reframe silently
  does nothing.
- **Merge the sticks into one geometry.** A node per bond is a few thousand draw
  calls, which is how 60 fps becomes a slideshow.
- **Split on window shape, not size class.** An iPad is `.regular` in both
  orientations, and a portrait side-by-side split leaves the viewer a pane twice
  as tall as it is wide.

### Physics and performance

- **`swift test` builds DEBUG.** For `JumpjetEngine` that is a factor of THIRTY-SIX:
  twenty sweeps take 4.9 s debug and 0.14 s release. An entire optimisation pass
  was aimed at debug numbers before this was noticed. `Tools/test-all.sh` runs
  `-c release` for exactly this reason.
- **Benchmark the shipping configuration.** The first benchmark used
  `TorsionTables.flat()`, which made the sampler look 40% faster and put
  acceptance at 65% instead of 37%. It was flattering itself on both counts.
- **Where the time goes, and what fixed it.** A backbone rotation moves about a
  quarter of the atoms and each needs its neighbourhood re-tested, which was 97%
  of the cost. The fix was not a faster kernel, it was proposing fewer of them:
  the mix went from 22% backbone to 3%, and 335 residues went from 22 to 124
  sweeps per second. 11% is strictly better than 22% on every axis measured, so
  the original number was simply too high rather than a considered trade.
- **Metal is unlikely to be the answer, and the reason is latency not
  throughput.** The build plan's risk table names a Metal clash grid, but a
  Metropolis move needs its energy delta BEFORE the next move can be proposed,
  so every dispatch is a synchronous round trip. At 335 residues there are 74
  backbone moves per sweep; 100 sweeps a second is 7,400 round trips a second,
  and Apple-silicon dispatch-and-wait is tens to hundreds of microseconds. The
  arithmetic does not close even if the kernel itself were free. What WOULD
  close it is an algorithmic change (local concerted-rotation backbone moves,
  which touch six to eight residues instead of a quarter of the protein), or
  batching genuinely independent moves. Measure before writing any of it.
- **Parallelism made it SEVEN TIMES SLOWER.** A deterministic
  `concurrentPerform` split (disjoint stamp buffers, fixed-order reduction,
  bit-identical acceptance) took 335 residues from 19.6 sweeps/s to 3.1. The
  dispatch waits on worker threads that a loaded machine does not have. It was
  removed rather than kept behind a flag, because the target is a phone: two
  performance cores and a thermal budget.
- **Per-cell distance culling was slower AND wrong.** Candidates fell 63 to 52
  and throughput fell with them, and the acceptance ratio moved, which for a
  fixed seed means the energies moved. Culling at cutoff plus one drift margin
  looks right and is not: BOTH atoms drift between rebuilds, so the safe reach
  is cutoff plus two margins, which is wider than a cell.
- **A column of zeros is not a measurement.** Stopping a run early through the
  progress callback left only frame 0 stored (the snapshot stride was larger
  than the run), so "the last frame" was the STARTING structure and every
  displacement read exactly 0.000. It looked like a metric. If a whole column is
  identical, especially identically zero, check the plumbing before the physics.
- **Displacement hides starvation; COVERAGE does not.** A mid-chain pivot moves
  hundreds of atoms when it lands, so a torsion that is almost never accepted
  and one that is well sampled produce the same mean displacement. Biasing
  backbone selection towards cheap torsions kept the displacement ratio at a
  healthy 0.79 while mid-chain torsion COVERAGE fell from 84.7% to 12.1%. If a
  metric can be satisfied by a few large events, count the events too.
- **Compare sampler configurations at equal WALL CLOCK, not equal sweeps.** A
  user waits ten seconds, not four hundred sweeps. Per-sweep comparison flatters
  the slow configuration twice: once by giving it as many expensive moves as the
  cheap one gets cheap ones, and again by hiding that it took seven times longer.
- **One seed is not a measurement of a displacement.** Throughput is stable
  across seeds; RMSD and per-region RMSF are not. A single-seed sweep of the
  backbone cost bias showed outer-third motion RISING from bias 0 to 0.5 and
  falling again, which is not a mechanism, it is one run. Average the
  displacements over several seeds before concluding anything from them, and
  treat a non-monotonic trend in a noisy column as noise until it survives that.
- **The acceptance ratio is a calibration, not a constant.** `CalibrationTests`
  sweeps the amplitudes and is skipped unless `JUMPJET_CALIBRATE` is set. Re-run
  it whenever the force field changes.
- **Rotate the smaller side of a torsion.** Free, because every energy term is a
  function of internal coordinates, so the two choices differ only by a
  rigid-body transform. Frames are superposed onto frame 0 before display, which
  is where that difference goes.

### Analysis

- **A detector validated on its own engine's output agrees with itself.**
  `JumpjetAnalysis` depends on Core only, so every detector is tested against
  synthetic tracks with planted transitions and the expected answer is known
  exactly.
- **No-man's-land must inherit the previous state.** Otherwise a side chain
  rattling in the gap between two wells reports hundreds of jumps having never
  changed rotamer.
- **A ring flip is not a rotamer jump**, and both come from one symmetry. His
  and Trp rings only LOOK symmetric.
- **Circular data needs circular methods.** A residue oscillating about 180
  degrees has a linear standard deviation of 150 and a circular one of 4.
- **Determinism is a feature.** Random k-means starts give different labels, a
  different k, and a transition matrix whose rows mean something else, from a
  trajectory that has not changed.
- **The jump COUNT is not a kinetic observable** when the sampler proposes
  rotamer changes directly. 15,889 jumps in 5,000 sweeps is the move set
  talking. Rank residues within a run; do not compare rates between runs.

### Distribution

- **Open the archive before uploading it.** `ARCHIVE SUCCEEDED` says nothing
  about the contents. BOFFIN's first successful archive was 7.6 MB, validly
  signed, and contained not one model. `Tools/appstore/verify-archive.sh`
  checks the resources, both icon variants, the signing authority and the
  embedded profile, and is negative-tested: strip a model and the bundle drops
  from 16 MB to 1.6 MB, which is the tell.
- **Apple does not expose app-record creation.** `POST /v1/apps` returns 403
  `FORBIDDEN_ERROR`, "does not allow CREATE". Worse, the missing record surfaces
  from `altool` as `Cannot determine the Apple ID from Bundle ID '...'`, which
  reads like a bundle-ID problem and is not one.
- **`altool` will not find the signing key.** It looks only in `./private_keys`,
  `~/private_keys`, `~/.private_keys` and `~/.appstoreconnect/private_keys`.
  Set `API_PRIVATE_KEYS_DIR` rather than copying the key somewhere.
- **A `LICENSE` with anything appended to it stops being a licence.** GitHub
  detects one by matching the file against a template, so `LICENSE` with a
  third-party section after the MIT text made the API report
  `licenseInfo: null`. Split: pure template in `LICENSE`, everything else in
  `NOTICE`.
- **Under `set -o pipefail`, `awk '{...; exit}'` on a pipe is a failure.** The
  early exit SIGPIPEs the writer and the script dies with 141, which looks
  exactly like a failed check rather than a broken one.
- PIL's `line(..., joint="curve")` fans spikes out of every joint. At icon size
  that reads as a hatching artefact over the whole mark. Stamp overlapping
  discs along the path instead. And assert the icon is `RGB`: the App Store
  rejects an alpha channel.

### Building and capturing inside an iCloud folder

- **DerivedData must not live inside this repository.** `~/Documents` is
  iCloud-synced, and `fileproviderd` stamps `com.apple.FinderInfo` on the
  directories it manages. codesign then fails the whole build with *"resource
  fork, Finder information, or similar detritus not allowed"*, naming the .app
  rather than the attribute or the cause. `xattr -cr` does not fix it: the
  attributes come straight back. `Tools/appstore/archive.sh` puts DerivedData
  in `$TMPDIR`. The default Xcode location is already outside iCloud, which is
  why the first archive of the day worked and an explicit
  `-derivedDataPath build/dd` broke it.
- **iCloud also writes conflict copies into output directories.** A capture run
  left `1-standby 2.png` beside `1-standby.png`, which would have uploaded as a
  duplicate screenshot. Sweep `find ... -name "* [0-9].png"` before uploading
  anything captured under `Documents`.
- **Capture screenshots from a RELEASE build.** The same 36x factor as
  `swift test`: a Debug simulator build reached sweep 391 of 5,000 in the time
  a Release build finished the run, so every "sortie" screenshot showed a
  half-finished progress panel and an amber GPU/CPU FALLBACK badge instead of
  the flight recorder. `CODE_SIGNING_ALLOWED=NO` lets Release build for a
  simulator. The environment seams are not behind `#if DEBUG`, so they still
  work.
- **Check what the app SAYS in a screenshot, not just that it rendered.** The
  standby screen still advertised the sampler as arriving "in Phase 2", and
  described the app as "molecular dynamics", which is the one claim this
  project exists not to make. Both were about to become App Store screenshots.

### GitHub Pages for the privacy policy

- **`Docs` is not `docs`.** They are the same directory on a case-insensitive
  Mac and different ones on GitHub, so Pages cannot be pointed at `/docs` here.
  This repo serves Pages from the root instead.
- **Jekyll silently refuses to publish any path beginning with an underscore**,
  so a stylesheet called `_style.css` 404s while the page around it works.
  `.nojekyll` at the root turns the whole pipeline off.

### Toolchain

- The type checker gives up on a one-line Catmull-Rom: every literal and operator
  is overloaded across `SIMD3` and its scalar. Write the basis terms out.
- `simd` matrices subscript by column (`m[i]`); `.columns` is a tuple and cannot
  take a variable index.
- There is no double-to-float matrix conversion in `simd`; narrow column by column.
- `Character` is not `Codable`.
- `NSLock` is unavailable from an async context. Use an actor.
- `str.replace` with a missing anchor is a SILENT no-op. An earlier edit had
  already deleted the function a later edit anchored on, so a method was never
  inserted and the failure surfaced as an unrelated `@Bindable` error. Assert the
  anchor exists before replacing.
- **`textCase(.uppercase)` is a DISPLAY transform.** A control captioned "EXPORT
  MOVIE" is still called "Export movie" in the accessibility tree, so a test
  querying the visible text finds nothing. Set an explicit label and identifier.
- Interface tests build DEBUG, because that is where `@testable` works. A sweep
  count chosen for release makes a two-minute UI test into an hour-long one.
- Piping a long run through `grep` block-buffers it: the log stays empty until
  the process exits, so a monitor sees nothing. Redirect to a file instead.
- The iPad Pro 13-inch (M5) simulator kept shutting down under `simctl`; the iPad
  Air 11-inch (M4) was stable. Never `killall CoreSimulatorService`: it unmounts
  the runtime cryptex and only a reboot restores it.
