#!/usr/bin/env python3
"""
Fill in the App Store Connect listing for JUMPjet.

Everything here is metadata: names, descriptions, categories, pricing and
screenshots. It never submits for review, and it never touches a build.

    set -a; source ~/.claude/skills/marcs-vibe-coding/credentials.env; set +a
    .venv/bin/python Tools/store_metadata.py all
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from asc_api import call, token

BUNDLE_ID = "com.mdeller.jumpjet"
LOCALE = "en-US"

# Both must resolve before Apple will accept them. Served by GitHub Pages from
# this repo's root: the folder is `Docs` with a capital D, which is the same
# directory as `docs` on a case-insensitive Mac but not on GitHub, so Pages
# cannot be pointed at /docs here.
PRIVACY_POLICY_URL = "https://bellcheddar.github.io/JUMPjet/Docs/privacy.html"
SUPPORT_URL = "https://bellcheddar.github.io/JUMPjet/Docs/"
MARKETING_URL = "https://marcdeller.com"

# Required before review. Year and holder, no (c) symbol: Apple adds it.
COPYRIGHT = "2026 Marc C. Deller"

PRIMARY_CATEGORY = "EDUCATION"
SECONDARY_CATEGORY = "REFERENCE"

# 30 characters.
SUBTITLE = "Watch proteins move, offline"

# 100 characters, comma separated. Spaces count, so there are none after commas.
KEYWORDS = ("protein,structure,alphafold,uniprot,molecular,biophysics,pdb,"
            "simulation,3d,biology,science")

# 170 characters. Changeable without a new build.
PROMOTIONAL_TEXT = (
    "Type a UniProt accession, watch the protein move. Conformational sampling "
    "on your device, an animation you can scrub, and a movie you can export."
)

DESCRIPTION = """\
JUMPjet turns a protein structure into something you can watch move. Type a UniProt accession, and the app fetches the structure, samples its flexibility on your device, and gives you an animation you can scrub, per-residue analytics, and a movie you can export and share.

Everything after the download runs locally. There is no server, no queue, no account and no sign-in.

HOW IT WORKS

A torsional Monte Carlo sampler explores the protein's conformations by rotating about its rotatable bonds, keeping bond lengths and angles fixed. Side chains wiggle, rotamers jump between wells, aromatic rings flip, and the backbone pivots. An elastic network holds the fold together, softened per residue by a neural flexibility prior: a small ESM-2 protein language model that runs on the Apple Neural Engine and tells the sampler which parts of this particular sequence are expected to be mobile.

THE FLIGHT RECORDER

Sampling is only half of it. The flight recorder shows you what happened:

Per-residue mobility, so you can see at a glance which loops move and which core is rigid.

Rotamer jumps and ring flips, ranked, so the residues doing the interesting things surface without hunting for them.

A conformational landscape from a principal component analysis of the torsion angles, showing whether the protein explored one basin or hopped between several.

A transition matrix between basins, and a scrub bar marked where the notable events happened.

EXPORT

Any run exports as an H.264 movie at up to 1080p, rendered on device, ready for a talk, a paper figure or a lab meeting. Report cards export too.

HONEST ABOUT WHAT IT IS

This matters, so the app says it in the interface and not only here. JUMPjet is a crude conformational sampler, not a molecular dynamics engine. Frames are Monte Carlo sweeps, not femtoseconds: there is no timestep and no trajectory in real time. Jump rates reflect the sampler's move set as much as the protein's energy landscape, so rank residues within a run rather than comparing rates between runs.

It is built for intuition about which parts of a structure are mobile. It is not for computing kinetics or thermodynamics, and it never pretends to be.

BUILT FOR

Structural biologists sizing up a construct, students meeting protein flexibility for the first time, anyone who has stared at a static ribbon diagram and wanted to see it breathe, and teachers who want a molecule that moves on a screen they can spin.

Structures from the AlphaFold Protein Structure Database and UniProtKB, with experimental structures from PDBe. Open source under the MIT licence.

PRIVACY

JUMPjet collects nothing. No accounts, no analytics, no advertising, no tracking. The only network requests it ever makes are for the structure you asked for, and they carry nothing that identifies you.
"""

WHATS_NEW = """\
First release.
"""


def app_id(auth: str) -> str:
    for a in call("GET", "/apps?limit=200", auth=auth)["data"]:
        if a["attributes"].get("bundleId") == BUNDLE_ID:
            return a["id"]
    sys.exit(f"No app record for {BUNDLE_ID}. Create it in App Store Connect first.")


def set_categories(auth: str, app: str) -> None:
    info = call("GET", f"/apps/{app}/appInfos", auth=auth)["data"][0]
    call("PATCH", f"/appInfos/{info['id']}", {
        "data": {
            "type": "appInfos",
            "id": info["id"],
            "relationships": {
                "primaryCategory": {
                    "data": {"type": "appCategories", "id": PRIMARY_CATEGORY}
                },
                "secondaryCategory": {
                    "data": {"type": "appCategories", "id": SECONDARY_CATEGORY}
                },
            },
        }
    }, auth=auth)
    print(f"  categories: {PRIMARY_CATEGORY} / {SECONDARY_CATEGORY}")


def set_app_info_localisation(auth: str, app: str) -> None:
    info = call("GET", f"/apps/{app}/appInfos", auth=auth)["data"][0]
    locs = call("GET", f"/appInfos/{info['id']}/appInfoLocalizations", auth=auth)["data"]
    target = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
    body = {
        "subtitle": SUBTITLE,
        "privacyPolicyUrl": PRIVACY_POLICY_URL,
    }
    if target:
        call("PATCH", f"/appInfoLocalizations/{target['id']}", {
            "data": {"type": "appInfoLocalizations", "id": target["id"],
                     "attributes": body}
        }, auth=auth)
        print(f"  subtitle + privacy policy set ({LOCALE})")
    else:
        call("POST", "/appInfoLocalizations", {
            "data": {"type": "appInfoLocalizations",
                     "attributes": {"locale": LOCALE, **body},
                     "relationships": {"appInfo": {
                         "data": {"type": "appInfos", "id": info["id"]}}}}
        }, auth=auth)
        print(f"  created localisation ({LOCALE})")


def versions(auth: str, app: str) -> list[dict]:
    return call("GET", f"/apps/{app}/appStoreVersions?limit=10", auth=auth)["data"]


def set_copyright(auth: str, app: str) -> None:
    """Copyright sits on the version, so a multiplatform record needs it thrice."""
    for version in versions(auth, app):
        call("PATCH", f"/appStoreVersions/{version['id']}", {
            "data": {"type": "appStoreVersions", "id": version["id"],
                     "attributes": {"copyright": COPYRIGHT}}
        }, auth=auth)
        print(f"  {version['attributes']['platform']}: copyright set")


def set_version_localisations(auth: str, app: str) -> None:
    for version in versions(auth, app):
        platform = version["attributes"].get("platform")
        locs = call("GET",
                    f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                    auth=auth)["data"]
        target = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
        body = {
            "description": DESCRIPTION,
            "keywords": KEYWORDS,
            "promotionalText": PROMOTIONAL_TEXT,
            "supportUrl": SUPPORT_URL,
            "marketingUrl": MARKETING_URL,
        }
        # "What's New" cannot be set on a first release: there is nothing to be
        # new against, and Apple rejects the attribute outright rather than
        # ignoring it. WHATS_NEW is kept for version 1.1 onwards.
        if (version["attributes"].get("versionString") or "1.0") != "1.0":
            body["whatsNew"] = WHATS_NEW
        if target:
            call("PATCH", f"/appStoreVersionLocalizations/{target['id']}", {
                "data": {"type": "appStoreVersionLocalizations",
                         "id": target["id"], "attributes": body}
            }, auth=auth)
            print(f"  {platform}: description, keywords and URLs set")
        else:
            call("POST", "/appStoreVersionLocalizations", {
                "data": {"type": "appStoreVersionLocalizations",
                         "attributes": {"locale": LOCALE, **body},
                         "relationships": {"appStoreVersion": {
                             "data": {"type": "appStoreVersions",
                                      "id": version["id"]}}}}
            }, auth=auth)
            print(f"  {platform}: created localisation")


def set_free(auth: str, app: str) -> None:
    """
    Free in every territory.

    The price schedule wants a base territory and a price point on the free
    tier, which is the one whose customerPrice is 0.0.
    """
    points = call("GET",
                  f"/apps/{app}/appPricePoints?filter[territory]=USA&limit=200",
                  auth=auth)["data"]
    free = next((p for p in points
                 if float(p["attributes"]["customerPrice"]) == 0.0), None)
    if not free:
        sys.exit("no free price point offered for this app")

    call("POST", "/appPriceSchedules", {
        "data": {
            "type": "appPriceSchedules",
            "relationships": {
                "app": {"data": {"type": "apps", "id": app}},
                "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                "manualPrices": {"data": [{"type": "appPrices", "id": "${price}"}]},
            },
        },
        "included": [{
            "type": "appPrices",
            "id": "${price}",
            "relationships": {
                "appPricePoint": {"data": {"type": "appPricePoints",
                                           "id": free["id"]}}
            },
        }],
    }, auth=auth)
    print("  pricing: free in all territories")


def set_age_rating(auth: str, app: str) -> None:
    """
    A scientific reference tool with no objectionable content of any kind.
    Every field is declared explicitly rather than left to a default.
    """
    info = call("GET", f"/apps/{app}/appInfos", auth=auth)["data"][0]
    declaration = call("GET", f"/appInfos/{info['id']}/ageRatingDeclaration",
                       auth=auth)["data"]
    attributes = {
        "alcoholTobaccoOrDrugUseOrReferences": "NONE",
        "contests": "NONE",
        "gamblingSimulated": "NONE",
        "horrorOrFearThemes": "NONE",
        "matureOrSuggestiveThemes": "NONE",
        "medicalOrTreatmentInformation": "NONE",
        "profanityOrCrudeHumor": "NONE",
        "sexualContentGraphicAndNudity": "NONE",
        "sexualContentOrNudity": "NONE",
        "violenceCartoonOrFantasy": "NONE",
        "violenceRealistic": "NONE",
        "violenceRealisticProlongedGraphicOrSadistic": "NONE",
        "gambling": False,
        # The structure viewer is a bundled Mol* build reading a cached file,
        # not a browser, so this is genuinely false.
        "unrestrictedWebAccess": False,
        "kidsAgeBand": None,
        # Everything below was discovered by asking: the API rejects the
        # request naming one missing attribute at a time, so the full set is
        # only visible by iterating. Types are not guessable either, and are
        # not consistent: ageAssurance is a BOOLEAN despite reading like an
        # enum, while gunsOrOtherWeapons is an enum despite sitting among the
        # booleans. Both were found by sending the wrong type and reading the
        # complaint.
        "ageAssurance": False,
        "messagingAndChat": False,
        "advertising": False,
        "healthOrWellnessTopics": False,
        "userGeneratedContent": False,
        "parentalControls": False,
        "lootBox": False,
        "gunsOrOtherWeapons": "NONE",
    }
    call("PATCH", f"/ageRatingDeclarations/{declaration['id']}", {
        "data": {"type": "ageRatingDeclarations", "id": declaration["id"],
                 "attributes": attributes}
    }, auth=auth)
    print("  age rating: no objectionable content declared")


# Which folder of captures goes to which display type, per platform version.
# APP_IPHONE_67 accepts the 6.9 inch 1320x2868 captures, and
# APP_IPAD_PRO_3GEN_129 accepts the 13 inch 2064x2752 ones: Apple did not add
# new display types for those sizes, which is not obvious from the names.
SCREENSHOT_PLAN = {
    # Both iPhone slots are filled. App Store Connect derives one size from the
    # other and renders the derived slot dimmed and unclickable, while the API
    # reports every asset COMPLETE with empty errors: supplying only 6.9 inch
    # left PfamIE's whole iPhone section read-only. APP_IPHONE_65 at 1242x2688
    # is the pairing an already-accepted app in this account uses.
    #
    # JUMPjet is iPhone and iPad only, so there is no watch, macOS or visionOS
    # entry here. The sampler was tuned for a phone's thermal envelope and the
    # others were never measured.
    "IOS": [
        ("APP_IPHONE_67", "screenshots/iphone69"),
        ("APP_IPHONE_65", "screenshots/iphone65"),
        ("APP_IPAD_PRO_3GEN_129", "screenshots/ipad13"),
    ],
}


def upload_screenshots(auth: str, app: str) -> None:
    import hashlib
    import urllib.request

    # This script lives in Tools/appstore/, so the repository root is three
    # levels up, not two. PfamIE kept it in Tools/ and the inherited path
    # silently resolved to Tools/assets, which exists nowhere: every set
    # reported "no captures" and the run still exited 0.
    root = Path(__file__).resolve().parent.parent.parent / "assets"
    if not root.is_dir():
        raise SystemExit(f"no capture root at {root}")

    for version in versions(auth, app):
        platform = version["attributes"].get("platform")
        plan = list(SCREENSHOT_PLAN.get(platform) or [])
        if platform == "IOS":
            plan += SCREENSHOT_PLAN.get("IOS_WATCH") or []
        if not plan:
            continue

        locs = call("GET",
                    f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                    auth=auth)["data"]
        loc = next((l for l in locs if l["attributes"]["locale"] == LOCALE), None)
        if not loc:
            print(f"  {platform}: no {LOCALE} localisation")
            continue

        existing = call("GET",
                        f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
                        auth=auth)["data"]
        by_type = {e["attributes"]["screenshotDisplayType"]: e["id"] for e in existing}

        for display_type, folder in plan:
            directory = root / folder
            images = sorted(directory.glob("*.png")) if directory.exists() else []
            if not images:
                print(f"  {platform} {display_type}: no captures in {folder}")
                continue

            set_id = by_type.get(display_type)
            if not set_id:
                created = call("POST", "/appScreenshotSets", {
                    "data": {
                        "type": "appScreenshotSets",
                        "attributes": {"screenshotDisplayType": display_type},
                        "relationships": {"appStoreVersionLocalization": {
                            "data": {"type": "appStoreVersionLocalizations",
                                     "id": loc["id"]}}},
                    }
                }, auth=auth)
                set_id = created["data"]["id"]

            have = call("GET", f"/appScreenshotSets/{set_id}/appScreenshots",
                        auth=auth)["data"]
            have_names = {h["attributes"].get("fileName") for h in have}

            for image in images:
                if image.name in have_names:
                    print(f"  {platform} {display_type}: {image.name} already there")
                    continue
                data = image.read_bytes()

                # Phase 1: reserve, and Apple replies with where to PUT it.
                reserved = call("POST", "/appScreenshots", {
                    "data": {
                        "type": "appScreenshots",
                        "attributes": {"fileSize": len(data), "fileName": image.name},
                        "relationships": {"appScreenshotSet": {
                            "data": {"type": "appScreenshotSets", "id": set_id}}},
                    }
                }, auth=auth)["data"]

                # Phase 2: run every upload operation. Large files come back as
                # several ranged PUTs, so this is a loop rather than one call.
                for op in reserved["attributes"]["uploadOperations"]:
                    chunk = data[op["offset"]:op["offset"] + op["length"]]
                    request = urllib.request.Request(
                        op["url"], method=op["method"], data=chunk)
                    for header in op.get("requestHeaders", []):
                        request.add_header(header["name"], header["value"])
                    urllib.request.urlopen(request, timeout=180).read()

                # Phase 3: commit with the checksum, or it stays in limbo and
                # never appears in the listing.
                call("PATCH", f"/appScreenshots/{reserved['id']}", {
                    "data": {
                        "type": "appScreenshots", "id": reserved["id"],
                        "attributes": {"uploaded": True,
                                       "sourceFileChecksum": hashlib.md5(data).hexdigest()},
                    }
                }, auth=auth)
                print(f"  {platform} {display_type}: uploaded {image.name}")

            order_screenshots(auth, set_id)


def submit_for_review(auth: str, app: str) -> None:
    """
    Put the current version into Apple's review queue.

    Deliberately NOT part of `all`: submitting is outward-facing and it is not
    something a metadata refresh should ever do as a side effect.

    Three calls, and the third is the one that matters. Creating a
    reviewSubmission and adding an item to it leaves everything in
    READY_FOR_REVIEW, which looks submitted and is not: nothing reaches Apple
    until the PATCH sets submitted=true.
    """
    existing = call("GET", f"/apps/{app}/reviewSubmissions?limit=10", auth=auth)["data"]
    open_subs = [s for s in existing
                 if s["attributes"].get("state") in ("READY_FOR_REVIEW",)]
    if open_subs:
        submission = open_subs[0]
        print(f"  reusing open submission {submission['id']}")
    else:
        submission = call("POST", "/reviewSubmissions", {
            "data": {"type": "reviewSubmissions",
                     "attributes": {"platform": "IOS"},
                     "relationships": {"app": {
                         "data": {"type": "apps", "id": app}}}}
        }, auth=auth)["data"]
        print(f"  created submission {submission['id']}")

    items = call("GET", f"/reviewSubmissions/{submission['id']}/items", auth=auth)["data"]
    if items:
        print(f"  {len(items)} item(s) already attached")
    else:
        for version in versions(auth, app):
            call("POST", "/reviewSubmissionItems", {
                "data": {"type": "reviewSubmissionItems",
                         "relationships": {
                             "reviewSubmission": {"data": {
                                 "type": "reviewSubmissions", "id": submission["id"]}},
                             "appStoreVersion": {"data": {
                                 "type": "appStoreVersions", "id": version["id"]}}}}
            }, auth=auth)
            print(f"  attached version {version['attributes'].get('versionString')} "
                  f"[{version['attributes'].get('platform')}]")

    call("PATCH", f"/reviewSubmissions/{submission['id']}", {
        "data": {"type": "reviewSubmissions", "id": submission["id"],
                 "attributes": {"submitted": True}}
    }, auth=auth)
    state = call("GET", f"/reviewSubmissions/{submission['id']}",
                 auth=auth)["data"]["attributes"].get("state")
    print(f"  submitted. state={state}")


def clear_screenshots(auth: str, app: str) -> None:
    """
    Delete every uploaded screenshot, so a re-capture actually replaces them.

    `upload_screenshots` skips any file whose name it already sees, which makes
    re-running it after a re-shoot a no-op that prints "already there" and
    leaves the old image in the listing. That is the right default (uploads are
    slow and mostly idempotent) but it means replacing a capture needs this
    first.
    """
    removed = 0
    for version in versions(auth, app):
        platform = version["attributes"].get("platform")
        for loc in call("GET",
                        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                        auth=auth)["data"]:
            for st in call("GET",
                           f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
                           auth=auth)["data"]:
                shots = call("GET", f"/appScreenshotSets/{st['id']}/appScreenshots",
                             auth=auth)["data"]
                for shot in shots:
                    call("DELETE", f"/appScreenshots/{shot['id']}", auth=auth)
                    removed += 1
                print(f"  {platform} {st['attributes']['screenshotDisplayType']}: "
                      f"deleted {len(shots)}")
    print(f"  {removed} screenshots removed")


def order_screenshots(auth: str, set_id: str) -> None:
    """
    Tell the set what order its screenshots go in.

    Uploading is not enough. Until the set's `appScreenshots` relationship is
    PATCHed with an explicit ordering, App Store Connect renders the images
    greyed out and refuses to let you click them, even though the API reports
    every asset as COMPLETE with no errors and no warnings. Nothing in the
    upload response hints at this.
    """
    shots = call("GET", f"/appScreenshotSets/{set_id}/appScreenshots", auth=auth)["data"]
    if not shots:
        return
    ordered = sorted(shots, key=lambda s: s["attributes"].get("fileName") or "")
    call("PATCH", f"/appScreenshotSets/{set_id}/relationships/appScreenshots", {
        "data": [{"type": "appScreenshots", "id": s["id"]} for s in ordered]
    }, auth=auth)
    print(f"    ordered {len(ordered)} screenshots")


EULA_TEXT = """\
PfamIE is free and open-source software, licensed under the MIT Licence.

Copyright (c) 2026 Marc C. Deller

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

Source code: https://github.com/bellcheddar/PfamIE

BUNDLED THIRD-PARTY COMPONENTS

This app includes the ESM-2 protein language model (MIT, Meta Platforms), the all-MiniLM-L6-v2 sentence embedding model (Apache Licence 2.0, modified for Core ML), the Mol* structure viewer (MIT), and data derived from Pfam 38.2 (CC0 1.0 public domain dedication) and InterPro at EMBL-EBI. Full attribution is at https://github.com/bellcheddar/PfamIE/blob/main/THIRD-PARTY-NOTICES.md

SCIENTIFIC USE

PfamIE produces predictions, not assignments. Measured on 2,500 real UniProt proteins, its top answer is correct about 49% of the time, and every result states the measured accuracy of its confidence band. It is not a medical device and is not intended for diagnostic use.
"""


def set_eula(auth: str, app: str) -> None:
    """
    A custom licence agreement.

    Apple's standard EULA is the default and would be perfectly adequate, but
    this app is MIT-licensed open source that bundles four third-party
    components under three different licences, and the store listing is where
    a user is most likely to look for that.
    """
    territories = [t["id"] for t in
                   call("GET", "/territories?limit=200", auth=auth)["data"]]

    existing = call("GET", f"/apps/{app}/endUserLicenseAgreement", auth=auth).get("data")
    body_attributes = {"agreementText": EULA_TEXT}
    relationships = {
        "app": {"data": {"type": "apps", "id": app}},
        "territories": {"data": [{"type": "territories", "id": t}
                                 for t in territories]},
    }
    if existing:
        call("PATCH", f"/endUserLicenseAgreements/{existing['id']}", {
            "data": {"type": "endUserLicenseAgreements", "id": existing["id"],
                     "attributes": body_attributes,
                     "relationships": {"territories": relationships["territories"]}}
        }, auth=auth)
        print(f"  licence agreement updated ({len(territories)} territories)")
    else:
        call("POST", "/endUserLicenseAgreements", {
            "data": {"type": "endUserLicenseAgreements",
                     "attributes": body_attributes,
                     "relationships": relationships}
        }, auth=auth)
        print(f"  licence agreement set ({len(territories)} territories)")


def attach_builds(auth: str, app: str) -> None:
    """
    Attach each processed build to its platform's version.

    A build cannot be attached while Apple is still processing it: the PATCH
    returns 409. Processing takes ten to thirty minutes, so this is a separate,
    re-runnable step rather than part of the upload.
    """
    by_platform = {}
    for build in call("GET", f"/apps/{app}/builds?limit=20", auth=auth)["data"]:
        if build["attributes"].get("processingState") != "VALID":
            continue
        pre = call("GET", f"/builds/{build['id']}/preReleaseVersion",
                   auth=auth).get("data") or {}
        platform = (pre.get("attributes") or {}).get("platform")
        if platform:
            by_platform.setdefault(platform, build["id"])

    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        current = call("GET", f"/appStoreVersions/{version['id']}/build",
                       auth=auth).get("data")
        if current:
            print(f"  {platform}: already attached")
            continue
        build_id = by_platform.get(platform)
        if not build_id:
            print(f"  {platform}: no processed build yet")
            continue
        call("PATCH", f"/appStoreVersions/{version['id']}", {
            "data": {"type": "appStoreVersions", "id": version["id"],
                     "relationships": {"build": {"data": {"type": "builds",
                                                          "id": build_id}}}}
        }, auth=auth)
        print(f"  {platform}: attached")


def reorder_all_screenshots(auth: str, app: str) -> None:
    """Re-apply the display order to every existing set."""
    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        for loc in call("GET",
                        f"/appStoreVersions/{version['id']}/appStoreVersionLocalizations",
                        auth=auth)["data"]:
            for st in call("GET",
                           f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets",
                           auth=auth)["data"]:
                print(f"  {platform} {st['attributes']['screenshotDisplayType']}:")
                order_screenshots(auth, st["id"])


# App Review contact. Reused across every platform version.
REVIEW_CONTACT = {
    "contactFirstName": "Marc",
    "contactLastName": "Deller",
    "contactPhone": "13023586093",
    "contactEmail": "marc@marcdeller.com",
    "demoAccountRequired": False,
}

REVIEW_NOTES = """\
JUMPjet fetches a protein structure and samples its flexibility on the device, then shows the motion as an animation with per-residue analytics. There is no account, no sign-in and no paid content. Everything except the initial structure download runs locally.

TO TRY IT
1. On the launch screen, type this UniProt accession into the field: P69905
   (That is human haemoglobin alpha, 142 residues. P00698, hen lysozyme, also works well.)
2. Tap Run. The structure downloads from the AlphaFold database, then sampling starts.
3. When it finishes, the molecule animates. Drag the scrub bar under the viewer to move through the run, and drag on the molecule itself to rotate it.
4. Open the Flight Recorder for per-residue mobility, the ranked list of rotamer jumps and ring flips, and the conformational landscape.
5. Export Movie renders an H.264 file and offers the standard share sheet.

TIMING, SO IT DOES NOT LOOK LIKE A HANG
Sampling is the slow step and its cost grows with the size of the protein. On a recent iPhone, 5,000 sweeps of a 142-residue protein takes roughly ten seconds and a 335-residue protein roughly forty. A progress readout updates throughout. Movie export then takes about ten seconds. Nothing here is a hang; if you want it faster, lower the sweep count on the launch screen.

NETWORK
The only network requests JUMPjet makes are to fetch the structure you asked for: the AlphaFold Protein Structure Database and UniProtKB, falling back to PDBe for an experimental structure when no predicted model exists. They send only the accession that was typed in. Once a structure is loaded, everything else works in Airplane Mode.

PERMISSIONS
The only permission requested is add-only access to the photo library, and only if you choose to save an exported movie there. Declining it leaves every other feature working, and the share sheet still works.

PRIVACY
The app collects nothing. No accounts, no analytics, no advertising, no tracking, no third-party SDKs.

RESEARCH AND TEACHING USE
JUMPjet is a research and teaching tool. It runs a deliberately crude torsional Monte Carlo sampler: frames are Monte Carlo sweeps, not units of time, and the app states this in its own interface rather than implying a real trajectory. It is not a medical device and nothing it reports is intended for diagnostic use.
"""


def set_review_details(auth: str, app: str) -> None:
    """
    App Review contact information, per platform version.

    Required before submission and easy to miss, because App Store Connect
    lists it under the version rather than the app: a multiplatform app needs
    it filled in separately for each of iOS, macOS and visionOS.
    """
    for version in versions(auth, app):
        platform = version["attributes"]["platform"]
        existing = call("GET", f"/appStoreVersions/{version['id']}/appStoreReviewDetail",
                        auth=auth).get("data")
        attributes = {**REVIEW_CONTACT, "notes": REVIEW_NOTES}
        if existing:
            call("PATCH", f"/appStoreReviewDetails/{existing['id']}", {
                "data": {"type": "appStoreReviewDetails", "id": existing["id"],
                         "attributes": attributes}
            }, auth=auth)
            print(f"  {platform}: review contact updated")
        else:
            call("POST", "/appStoreReviewDetails", {
                "data": {"type": "appStoreReviewDetails", "attributes": attributes,
                         "relationships": {"appStoreVersion": {
                             "data": {"type": "appStoreVersions", "id": version["id"]}}}}
            }, auth=auth)
            print(f"  {platform}: review contact created")


def set_content_rights(auth: str, app: str) -> None:
    call("PATCH", f"/apps/{app}", {
        "data": {"type": "apps", "id": app,
                 "attributes": {
                     "contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}
    }, auth=auth)
    print("  content rights: no third-party content requiring rights")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else "all"
    auth = token()
    app = app_id(auth)
    print(f"app {app} ({BUNDLE_ID})")

    steps = {
        "categories": set_categories,
        "appinfo": set_app_info_localisation,
        "versions": set_version_localisations,
        "copyright": set_copyright,
        "pricing": set_free,
        "agerating": set_age_rating,
        "rights": set_content_rights,
        "screenshots": upload_screenshots,
        "clear-screenshots": clear_screenshots,
        "submit": submit_for_review,
        "eula": set_eula,
        "attach-builds": attach_builds,
        "review": set_review_details,
        "reorder": reorder_all_screenshots,
    }
    if command == "all":
        # Not attach-builds: a build still processing returns 409, and that is
        # a normal state rather than a failure worth printing on every run.
        #
        # And emphatically not clear-screenshots, which is destructive: it runs
        # only when asked by name. Inside "all" it would delete every uploaded
        # screenshot on each run, and since the order here is the dict's, it
        # could just as easily run AFTER the upload and leave the listing with
        # no images at all.
        skip = {"attach-builds", "clear-screenshots", "submit"}
        chosen = {k: v for k, v in steps.items() if k not in skip}
    else:
        chosen = {command: steps[command]}
    for name, fn in chosen.items():
        try:
            fn(auth, app)
        except Exception as error:
            print(f"  FAILED {name}: {str(error)[:400]}")
