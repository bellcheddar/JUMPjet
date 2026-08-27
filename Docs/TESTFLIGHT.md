# TestFlight archive checklist

Everything that has to be true before an archive goes to App Store Connect, and
what is NOT true yet.

## Blocked

- [ ] **A licence.** No `LICENSE` file exists and none is claimed anywhere in
      the repository. This is Marc's call and nothing should assume one.
- [ ] **An Apple Developer team.** `CODE_SIGN_STYLE` is `Automatic` and no team
      is set, so `xcodebuild archive` cannot sign. Needs an account only Marc
      holds.
- [ ] **A real app icon.** `Assets.xcassets/AppIcon.appiconset` has the 1024
      slot declared and no image in it. The build plan says the final icon comes
      from the `marcs-vibe-icon` skill.

## Ready

- [x] **Bundle identifier** `com.marcdeller.jumpjet`, set in the project rather
      than generated.
- [x] **Deployment target** iOS 17.0, and the Core ML model is converted at
      iOS17 to match. Converting the model at iOS18 would produce a bundle that
      builds and then fails to load the model on the oldest device the app
      claims to support, which nothing in the build would catch.
- [x] **`ITSAppUsesNonExemptEncryption` is false.** JUMPjet uses HTTPS for
      fetching and nothing else; there is no bespoke cryptography to declare.
- [x] **`NSPhotoLibraryAddUsageDescription`** is present, because the share
      sheet offers Save to Photos for exported movies and cards.
- [x] **Dark appearance only.** `UIUserInterfaceStyle` is `Dark` and the app
      also sets `preferredColorScheme(.dark)`. The design system is a night
      cockpit and has no light variant: letting the system flip it would produce
      phosphor green on white.
- [x] **iPhone and iPad**, `TARGETED_DEVICE_FAMILY` 1,2. No Mac Catalyst and no
      visionOS: the sampler is tuned for a phone's thermal envelope and neither
      has been measured.
- [x] **No third-party dependencies**, so there is no licence surface beyond the
      data sources in `Docs/ATTRIBUTIONS.md`.
- [x] **Accessibility labels** on every custom-drawn view. The raster, terrain
      map, transition matrix and scrubber are `Canvas` and `Grid`, which have no
      text of their own, so a label is the only way anything can describe them.

## The two-minute demo

The build plan's Phase 4 definition of done is an end-to-end demo in under two
minutes on device: accession in, 5,000 sweeps, review the analytics, export the
movie, share it.

**Not verified on a device.** What is measured, on a release build:

| Step | 142 residues | 335 residues |
|---|---|---|
| Fetch and parse (cached) | under 1 s | under 1 s |
| 5,000 sweeps | 9.9 s | 40.3 s |
| Flight recorder | 0.005 s | 0.02 s |
| Movie export, 1080p, 201 frames | about 10 s | about 10 s |

Observed end to end in the simulator: a 335-residue protein, 5,000 sweeps, was
loaded, sampled and fully analysed with the export panel ready **inside 50
seconds**, leaving seventy seconds of the budget for the export and the share.

A simulator is not a phone. It has the Mac's CPU and no thermal ceiling, so the
sampling figure is optimistic; it has no Neural Engine, so the embedding figure
is pessimistic. The number that matters is still unmeasured, and this is the
closest thing to it that exists without hardware.

## Before every archive

1. `Tools/test-all.sh` — 237 tests, release build, no simulator.
2. `xcodebuild test -only-testing:JUMPjetUITests` — the interface tests, which
   build DEBUG and are the only thing that catches an actor-isolation crash the
   package suites structurally cannot.
3. Check `Models/` is current: `Tools/coreml/validate_parity.py` gates the
   converted model against its PyTorch reference, and
   `Tools/coreml/compute_centroids.py` gates the flexibility prior on its own
   effect size.
4. Bump `MARKETING_VERSION` in the app target.

## What to say in the release notes

The honest version, because the app says it everywhere else:

> JUMPjet runs a crude torsional Monte Carlo sampler on your device. Frames are
> Monte Carlo sweeps, not femtoseconds, and jump rates reflect the sampler's
> move set as well as the protein. It is for building intuition about which
> parts of a structure are mobile, not for computing kinetics.
