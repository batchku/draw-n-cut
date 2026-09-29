#!/usr/bin/env python3
"""Push appstore/listing.json to App Store Connect.

Writes the draft listing for the version in PREPARE_FOR_SUBMISSION: the
version's text, the app-level subtitle and privacy URL, the categories, the
content-rights answer, the full age-rating questionnaire (4+: every answer
none/false), and the review contact and notes. Never submits, never touches
pricing or App Privacy.

    python3 appstore/upload_listing.py            # write everything
    python3 appstore/upload_listing.py --dry-run  # show the payloads only

The review contact's phone is not kept in the repo: it is copied from the
Story listing's review detail (app 6812611687) at upload time.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import asc  # noqa: E402

STORY_APP_ID = "6812611687"

# 4+: every questionnaire item answered, all at its "none" value.
AGE_RATING_4_PLUS = {
    "advertising": False,
    "alcoholTobaccoOrDrugUseOrReferences": "NONE",
    "contests": "NONE",
    "gambling": False,
    "gamblingSimulated": "NONE",
    "gunsOrOtherWeapons": "NONE",
    "healthOrWellnessTopics": False,
    "kidsAgeBand": None,
    "lootBox": False,
    "medicalOrTreatmentInformation": "NONE",
    "messagingAndChat": False,
    "parentalControls": False,
    "profanityOrCrudeHumor": "NONE",
    "ageAssurance": False,
    "sexualContentGraphicAndNudity": "NONE",
    "sexualContentOrNudity": "NONE",
    "socialMedia": False,
    "socialMediaAgeRestricted": False,
    "horrorOrFearThemes": "NONE",
    "matureOrSuggestiveThemes": "NONE",
    "unrestrictedWebAccess": False,
    "userGeneratedContent": False,
    "violenceCartoonOrFantasy": "NONE",
    "violenceRealisticProlongedGraphicOrSadistic": "NONE",
    "violenceRealistic": "NONE",
    "ageRatingOverride": "NONE",
    "koreaAgeRatingOverride": "NONE",
}


def patch(dry: bool, path: str, body: dict) -> None:
    if dry:
        print(f"PATCH {path}\n{json.dumps(body, indent=1)}\n")
        return
    asc.request("PATCH", path, body)
    print(f"patched {path}")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    dry = args.dry_run

    listing = json.loads((REPO / "appstore" / "listing.json").read_text(encoding="utf-8"))
    app_id = listing["app_id"]
    locale = listing["locale"]

    versions = [v for v in asc.get(f"apps/{app_id}/appStoreVersions")["data"]
                if v["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION"]
    if len(versions) != 1:
        raise asc.AscError(f"expected one editable version, found {len(versions)}")
    version = versions[0]
    print(f"version {version['attributes']['versionString']} ({version['id']})")

    # -- version text ------------------------------------------------------
    loc = next(l for l in asc.get(f"appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
               if l["attributes"]["locale"] == locale)
    patch(dry, f"appStoreVersionLocalizations/{loc['id']}", {"data": {
        "type": "appStoreVersionLocalizations", "id": loc["id"],
        "attributes": {
            "description": listing["description"],
            "keywords": listing["keywords"],
            "supportUrl": listing["support_url"],
            "promotionalText": listing["promotional_text"],
        }}})

    # -- app-level text, categories, content rights --------------------------
    info = next(i for i in asc.get(f"apps/{app_id}/appInfos")["data"]
                if i["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION")
    info_loc = next(l for l in asc.get(f"appInfos/{info['id']}/appInfoLocalizations")["data"]
                    if l["attributes"]["locale"] == locale)
    patch(dry, f"appInfoLocalizations/{info_loc['id']}", {"data": {
        "type": "appInfoLocalizations", "id": info_loc["id"],
        "attributes": {
            "subtitle": listing["subtitle"],
            "privacyPolicyUrl": listing["privacy_policy_url"],
        }}})
    relationships = {
        "primaryCategory": {"data": {"type": "appCategories", "id": listing["primary_category"]}},
    }
    if listing.get("secondary_category"):
        relationships["secondaryCategory"] = {"data": {"type": "appCategories", "id": listing["secondary_category"]}}
    patch(dry, f"appInfos/{info['id']}", {"data": {
        "type": "appInfos", "id": info["id"],
        "attributes": {"contentRightsDeclaration": listing["content_rights"]},
        "relationships": relationships}})

    # -- age rating ----------------------------------------------------------
    decl = asc.get(f"appInfos/{info['id']}/ageRatingDeclaration")["data"]
    patch(dry, f"ageRatingDeclarations/{decl['id']}", {"data": {
        "type": "ageRatingDeclarations", "id": decl["id"],
        "attributes": AGE_RATING_4_PLUS}})

    # -- review detail -------------------------------------------------------
    story_version = asc.get(f"apps/{STORY_APP_ID}/appStoreVersions?limit=1")["data"][0]
    story_review = asc.get(f"appStoreVersions/{story_version['id']}/appStoreReviewDetail").get("data")
    phone = (story_review or {}).get("attributes", {}).get("contactPhone")
    if not phone:
        raise asc.AscError("no review contact phone on the Story listing to copy")
    contact = listing["review_contact"]
    attributes = {
        "contactFirstName": contact["first_name"],
        "contactLastName": contact["last_name"],
        "contactEmail": contact["email"],
        "contactPhone": phone,
        "demoAccountRequired": False,
        "notes": listing["review_notes"],
    }
    existing = asc.get(f"appStoreVersions/{version['id']}/appStoreReviewDetail").get("data")
    if existing:
        shown = dict(attributes, contactPhone="<copied from Story>")
        if dry:
            print(f"PATCH appStoreReviewDetails/{existing['id']}\n{json.dumps(shown, indent=1)}\n")
        else:
            asc.request("PATCH", f"appStoreReviewDetails/{existing['id']}", {"data": {
                "type": "appStoreReviewDetails", "id": existing["id"], "attributes": attributes}})
            print("patched review detail")
    else:
        if dry:
            print("POST appStoreReviewDetails (contact + notes, phone copied from Story)\n")
        else:
            asc.request("POST", "appStoreReviewDetails", {"data": {
                "type": "appStoreReviewDetails", "attributes": attributes,
                "relationships": {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": version["id"]}}}}})
            print("created review detail")

    if not dry:
        # Read back what App Store Connect now holds, as the record of the run.
        loc = asc.get(f"appStoreVersionLocalizations/{loc['id']}")["data"]["attributes"]
        info_full = asc.get(f"appInfos/{info['id']}?include=primaryCategory,secondaryCategory")
        print("now: subtitle set:", bool(asc.get(f"appInfoLocalizations/{info_loc['id']}")["data"]["attributes"].get("subtitle")),
              "| description chars:", len(loc.get("description") or ""),
              "| keywords chars:", len(loc.get("keywords") or ""),
              "| support:", loc.get("supportUrl"),
              "| categories:", [c["id"] for c in info_full.get("included", [])],
              "| rights:", info_full["data"]["attributes"].get("contentRightsDeclaration"),
              "| age:", info_full["data"]["attributes"].get("appStoreAgeRating"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except asc.AscError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
