#!/usr/bin/env python3
"""
Submit the latest VALID build for App Store review (not TestFlight).

Idempotent — finds or creates the App Store version, attaches the
matching build, writes the "What's New" localization, and posts the
review submission. Bails (prints what's wrong) if the version still
lacks required metadata that the API can't auto-derive from the
previous version (mainly screenshots).

Run with `flox activate -- python3 scripts/asc_appstore_submit.py`.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from asc_testflight import ASC, BUNDLE_ID  # noqa: E402

VERSION_STRING = "2.0.2"
BUILD_VERSION = "2"
PLATFORM = "IOS"
WHATS_NEW = """\
This update is mostly bug fixes and improvements, plus a few new toys.

Improvements:

• Reworked output: choose 4:3 or 16:9 with per-aspect resolution options, and scale each pad with zoom-to-fill or letterbox. Cameras now use the full sensor frame.
• Color grade and the analog look are now a single, simpler set of output FX.
• New instruments: an ACIDBASS bass synth (with kick-to-bass sidechain ducking) and a 14-engine MULTIPLATES macro synth, plus a bigger 46-wave bank for WAVETABLE.
• Play instruments live over MIDI, and tweak the feedback wet/dry mix.

Fixes:

• Recordings now fill the whole frame at every output size.
• Fixed instrument tempo drifting under load and instrument knobs that wouldn't drag.
• Instrument patches and patterns now save and reload with your sessions.
"""


def find_or_create_app_store_version(asc, app_id):
    """Return the appStoreVersion row for VERSION_STRING, creating one if missing."""
    # `/appStoreVersions` doesn't allow GET_COLLECTION; go through the
    # app relationship endpoint instead.
    existing = asc.get(
        f"/apps/{app_id}/appStoreVersions",
        params={"filter[versionString]": VERSION_STRING},
    )["data"]
    if existing:
        v = existing[0]
        print(f"[asc] found existing app store version {VERSION_STRING} (id={v['id']})")
        return v
    print(f"[asc] creating app store version {VERSION_STRING}")
    body = {
        "data": {
            "type": "appStoreVersions",
            "attributes": {
                "versionString": VERSION_STRING,
                "platform": PLATFORM,
                "releaseType": "MANUAL",  # let the user choose when to flip the switch
            },
            "relationships": {
                "app": {"data": {"type": "apps", "id": app_id}},
            },
        }
    }
    return asc.post("/appStoreVersions", json=body)["data"]


def find_build(asc, app_id, build_version, marketing_version):
    """Find the build by CFBundleVersion AND marketing version.

    CFBundleVersion is NOT unique across marketing versions (e.g. both
    2.0.0 build 2 and 2.0.2 build 2 look like version=2 to the /builds
    filter), so we must disambiguate via the preReleaseVersion include or
    we risk attaching the wrong binary to the App Store version.
    """
    data = asc.get(
        "/builds",
        params={
            "filter[app]": app_id,
            "filter[version]": build_version,
            "sort": "-uploadedDate",
            "limit": 10,
            "include": "preReleaseVersion",
        },
    )
    included = {x["id"]: x for x in data.get("included", [])}
    for b in data["data"]:
        pvid = b.get("relationships", {}).get("preReleaseVersion", {}).get("data", {})
        pv = included.get(pvid.get("id"), {}).get("attributes", {}).get("version", "") if pvid else ""
        if pv == marketing_version:
            return b
    raise SystemExit(f"build {marketing_version}({build_version}) not found among version={build_version} builds")


def attach_build(asc, version_id, build_id):
    print(f"[asc] attaching build {build_id[:8]}… to appStoreVersion {version_id[:8]}…")
    asc.patch(
        f"/appStoreVersions/{version_id}",
        json={
            "data": {
                "type": "appStoreVersions",
                "id": version_id,
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}},
                },
            }
        },
    )


def set_whats_new(asc, version_id):
    """Find the en-US localization and patch the whatsNew field."""
    locs = asc.get(f"/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    target = None
    for loc in locs:
        if loc["attributes"].get("locale") == "en-US":
            target = loc
            break
    if not target:
        print("[asc] no en-US localization found; skipping whatsNew")
        return
    print(f"[asc] writing whatsNew for en-US localization {target['id'][:8]}…")
    asc.patch(
        f"/appStoreVersionLocalizations/{target['id']}",
        json={
            "data": {
                "type": "appStoreVersionLocalizations",
                "id": target["id"],
                "attributes": {"whatsNew": WHATS_NEW},
            }
        },
    )


def submit_for_review(asc, app_id, version_id):
    # Modern API: create a reviewSubmission, attach the version as an
    # item, then PATCH submitted=true. The older
    # /appStoreVersionSubmissions endpoint now only allows DELETE.
    print(f"[asc] creating reviewSubmission for appStoreVersion {version_id[:8]}…")
    sub = asc.post(
        "/reviewSubmissions",
        json={
            "data": {
                "type": "reviewSubmissions",
                "attributes": {"platform": "IOS"},
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                },
            }
        },
    )["data"]
    sid = sub["id"]
    print(f"[asc] reviewSubmission id = {sid[:8]}…")
    asc.post(
        "/reviewSubmissionItems",
        json={
            "data": {
                "type": "reviewSubmissionItems",
                "relationships": {
                    "reviewSubmission": {
                        "data": {"type": "reviewSubmissions", "id": sid}
                    },
                    "appStoreVersion": {
                        "data": {"type": "appStoreVersions", "id": version_id}
                    },
                },
            }
        },
    )
    asc.patch(
        f"/reviewSubmissions/{sid}",
        json={
            "data": {
                "type": "reviewSubmissions",
                "id": sid,
                "attributes": {"submitted": True},
            }
        },
    )
    state = asc.get(f"/reviewSubmissions/{sid}")["data"]["attributes"].get("state")
    print(f"[asc] submitted for review. reviewSubmission state = {state}")


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--no-submit", action="store_true",
                    help="Create/attach/set whatsNew but do NOT post the review submission (for verifying readiness first).")
    args = ap.parse_args()

    asc = ASC()
    app_id = asc.app_id_for_bundle(BUNDLE_ID)
    print(f"[asc] app id = {app_id}")

    build = find_build(asc, app_id, BUILD_VERSION, VERSION_STRING)
    print(f"[asc] build {build['id']} {VERSION_STRING}({BUILD_VERSION}) processingState={build['attributes'].get('processingState')}")

    version = find_or_create_app_store_version(asc, app_id)
    version_id = version["id"]

    attach_build(asc, version_id, build["id"])
    set_whats_new(asc, version_id)
    if args.no_submit:
        print("[asc] --no-submit set; prepared draft but did NOT submit for review.")
        return
    submit_for_review(asc, app_id, version_id)


if __name__ == "__main__":
    main()
