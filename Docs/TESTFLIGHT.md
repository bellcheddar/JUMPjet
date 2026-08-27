# TestFlight archive checklist

Everything that has to be true before an archive goes to App Store Connect, and
what is NOT true yet.

## Blocked

- [ ] **App Privacy.** The one remaining step, and the API cannot do it: there
      is no privacy relationship on `/apps`, and the documented `appDataUsages`
      resources 404. Not a permissions problem, since the same key can read
      `/users`, which only an Admin key can. App Store Connect -> JUMPjet ->
      App Privacy -> "No, we do not collect data from this app" -> Publish.
      JUMPjet genuinely collects nothing, so it is one answer.

Until it is answered, App Store Connect refuses to start review with *"An Admin
must provide information about the app's privacy practices"*.

## Ready

- [x] **The App Store Connect app record.** `JUMPjet ANE`, app id
      `6806044657`, bundle `com.mdeller.jumpjet`. Created by hand, because
      `POST /v1/apps` returns 403 FORBIDDEN_ERROR, "the resource 'apps' does
      not allow 'CREATE'". Recognise the symptom when it is missing: `altool`
      reports `Cannot determine the Apple ID from Bundle ID`, which reads like
      a bundle-ID problem and is not one.
- [x] **The listing.** Categories, subtitle, description, keywords, promotional
      text, support and marketing URLs, privacy policy URL, copyright, age
      rating, free pricing in 175 territories, the licence agreement and the
      App Review contact. All scripted in
      `Tools/appstore/store_metadata.py`.
- [x] **Privacy policy and support pages**, on GitHub Pages and returning 200
      before being handed to Apple, which rejects a URL that does not resolve.
- [x] **Fifteen screenshots**, five each at 1320x2868 (`APP_IPHONE_67`),
      1242x2688 (`APP_IPHONE_65`) and 2064x2752 (`APP_IPAD_PRO_3GEN_129`), all
      `COMPLETE` with no errors. Both iPhone sizes deliberately: App Store
      Connect derives one from the other and renders the derived slot dimmed
      and unclickable, while the API still reports every asset fine.
- [x] **The build uploaded**, 15.2 MB, verified before upload.
- [x] **A licence.** MIT, in `LICENSE`, with the bundled model and data terms
      itemised separately in `NOTICE`. They are separate files on purpose:
      GitHub detects a licence by matching the file against a template, so
      appending a third-party section to `LICENSE` made the repository report
      no licence at all.
- [x] **An Apple Developer team**, read from `$APPLE_TEAM_ID` rather than
      written down here. Release builds sign manually
      against `Apple Distribution` and the `JUMPjet App Store` profile
      (uuid `933394db-0265-4eaf-b85c-e8e00ba44a92`, expires 2027-08-26);
      Debug stays automatic so a device build from Xcode still just works.
      `Tools/configure-signing.rb` reapplies all of it idempotently.
- [x] **A real app icon.** `Tools/make-app-icon.py` draws it: a backbone helix
      passing behind itself with one segment amber, which is the jump. Drawn as
      stamped discs rather than a wide polyline, because PIL's `joint="curve"`
      fans spikes out of every joint that read as a hatching artefact at icon
      size. Asserted RGB: the App Store rejects an icon with an alpha channel.
- [x] **Bundle identifier** `com.mdeller.jumpjet`, set in the project rather
      than generated. Registered with Apple as id `48SYPC36UH`. It was
      `com.marcdeller.jumpjet`, which matched nothing else in the account:
      BOFFIN ships as `com.mdeller.boffin`.
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

## Archiving, and what to check in the archive

```bash
xcodebuild archive -project JUMPjet.xcodeproj -scheme JUMPjet \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/JUMPjet.xcarchive
xcodebuild -exportArchive -archivePath build/JUMPjet.xcarchive \
  -exportOptionsPlist Tools/appstore/ExportOptions.plist -exportPath build/export
```

**Open the archive before uploading it.** BOFFIN's first successful archive was
7.6 MB and contained not one model: the build succeeded, the signature was
valid, and the app was useless. `Tools/appstore/verify-archive.sh` checks the
four things that were silently absent there:

| Check | Expected |
|---|---|
| `esm2_t6_8M_UR50D.mlmodelc` | present, about 14 MB |
| `esm2_t6_8M_UR50D.tokeniser.json` | present |
| `flexibility_centroids.json`, `torsion_tables.json` | present |
| `AppIcon60x60@2x.png` and the iPad variant | present at the bundle root |
| `codesign -dv` authority | `Apple Distribution` for the configured team |
| `embedded.mobileprovision` name | `JUMPjet App Store` |

Measured for 0.1.0: app bundle 16 MB, exported IPA 15.2 MB.

## Uploading

`altool` looks for the signing key by name in a fixed set of directories, none
of which is where the key lives, so the directory is passed explicitly:

```bash
set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
export API_PRIVATE_KEYS_DIR="$(dirname "$ASC_KEY_PATH")"
xcrun altool --upload-app -f build/export/JUMPjet.ipa -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

Nothing here writes a credential into the repository, and nothing should.

## What to say in the release notes

The honest version, because the app says it everywhere else:

> JUMPjet runs a crude torsional Monte Carlo sampler on your device. Frames are
> Monte Carlo sweeps, not femtoseconds, and jump rates reflect the sampler's
> move set as well as the protein. It is for building intuition about which
> parts of a structure are mobile, not for computing kinetics.
