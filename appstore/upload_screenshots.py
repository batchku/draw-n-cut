#!/usr/bin/env python3
"""Replace the App Store screenshot sets with the JPEGs in appstore/screenshots.

    python3 appstore/upload_screenshots.py            # upload both sets
    python3 appstore/upload_screenshots.py --dry-run  # list what would go

One set per display type, files in name order. An existing set of the same
type is deleted first, so App Store Connect ends up holding exactly these.
Upload follows Apple's three steps: reserve the screenshot with its size and
checksum, PUT the bytes to the URLs Apple hands back, then commit it.
"""

from __future__ import annotations

import argparse
import hashlib
import sys
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts" / "lib"))
import asc  # noqa: E402

APP_ID = "6801907664"
LOCALE = "en-US"
SETS = {
    "APP_IPHONE_65": REPO / "appstore" / "screenshots" / "iphone-65",
    "APP_IPAD_PRO_3GEN_129": REPO / "appstore" / "screenshots" / "ipad-13",
}


def upload_one(set_id: str, path: Path) -> None:
    data = path.read_bytes()
    reserved = asc.request("POST", "appScreenshots", {"data": {
        "type": "appScreenshots",
        "attributes": {"fileName": path.name, "fileSize": len(data)},
        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
    for op in reserved["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]: op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"],
                                     headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        with urllib.request.urlopen(req) as response:
            response.read()
    asc.request("PATCH", f"appScreenshots/{reserved['id']}", {"data": {
        "type": "appScreenshots", "id": reserved["id"],
        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
    print(f"  uploaded {path.name} ({len(data) // 1024} KB)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    version = next(v for v in asc.get(f"apps/{APP_ID}/appStoreVersions")["data"]
                   if v["attributes"]["appStoreState"] == "PREPARE_FOR_SUBMISSION")
    loc = next(l for l in asc.get(f"appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
               if l["attributes"]["locale"] == LOCALE)
    existing = {s["attributes"]["screenshotDisplayType"]: s["id"]
                for s in asc.get(f"appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]}

    for display_type, folder in SETS.items():
        files = sorted(folder.glob("*.jpg"))
        if not 3 <= len(files) <= 10:
            raise asc.AscError(f"{folder}: need 3 to 10 JPEGs, found {len(files)}")
        print(f"{display_type}: {[f.name for f in files]}")
        if args.dry_run:
            continue
        if display_type in existing:
            asc.request("DELETE", f"appScreenshotSets/{existing[display_type]}")
            print("  replaced the existing set")
        set_id = asc.request("POST", "appScreenshotSets", {"data": {
            "type": "appScreenshotSets",
            "attributes": {"screenshotDisplayType": display_type},
            "relationships": {"appStoreVersionLocalization": {
                "data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})["data"]["id"]
        for f in files:
            upload_one(set_id, f)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except asc.AscError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
