# TestFlight archive checklist

Everything that has to be true before an archive goes to App Store Connect, and
what is NOT true yet.

## Blocked

- [ ] **The App Store Connect app record.** Everything else on the Apple side is
      done and verified; this one step cannot be automated, and it needs a
      decision only Marc can make (see below).

Apple does not expose app-record creation over the API. Asked directly:

```
POST /v1/apps -> HTTP 403 FORBIDDEN_ERROR
"The resource 'apps' does not allow 'CREATE'.
 Allowed operations are: GET_COLLECTION, GET_INSTANCE, UPDATE"
```

So the record is made once, by hand, at
<https://appstoreconnect.apple.com/apps> -> **+** -> **New App**:

| Field | Value |
|---|---|
| Platform | iOS |
| Name | the App Store name, which must be globally unique. `JUMPjet` may be taken |
| Primary language | English (UK) |
| Bundle ID | `com.mdeller.jumpjet` (already registered, id `48SYPC36UH`) |
| SKU | any private string, e.g. `JUMPJET2026` |
| User access | Full Access |

Until it exists, upload fails with a message that names the bundle ID rather
than the missing record, which is worth recognising:

```
ERROR: Cannot determine the Apple ID from Bundle ID 'com.mdeller.jumpjet'
       and platform 'IOS'. (19)
```

Once the record exists, the whole remaining sequence is one command:
`Tools/appstore/upload.sh`.

## Ready

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
