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

VERSION_STRING = "2.0.1"
BUILD_VERSION = "1"
PLATFORM = "IOS"
WHATS_NEW = """\
Bug fixes and refinements:

• Per-pad mute, volume, and VU now work on instrument pads (previously stuck even though audio was audible).
• 'End Session?' alert no longer pops up on cold launch.
• FX pad thumbnails (keyer / feedback) render smoothly — no more jitter or first-frame slash artifact on launch.

New and improved:

• X/Y joystick macro — a two-axis assignable control mapped to any pair of LFO targets.
• Per-pad letterbox / fill toggle so each source fits the pad the way you want.
• HD output post-processing with new side-strip FX panels.
• Per-pad VU meter and volume slider; mini VU on camera and mic pads.
• Per-pad gear menu + a global settings sheet (thumbnail quality, NTSC, MIDI).
• In-app share for live clips; Documents / UserVideos exposed via the Files app.
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


def find_build(asc, app_id, build_version):
    builds = asc.get(
        "/builds",
        params={
            "filter[app]": app_id,
            "filter[version]": build_version,
            "limit": 1,
        },
    )["data"]
    if not builds:
        raise SystemExit(f"build {build_version} not found")
    return builds[0]


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
    asc = ASC()
    app_id = asc.app_id_for_bundle(BUNDLE_ID)
    print(f"[asc] app id = {app_id}")

    build = find_build(asc, app_id, BUILD_VERSION)
    print(f"[asc] build {build['id'][:8]}… version={BUILD_VERSION} processingState={build['attributes'].get('processingState')}")

    version = find_or_create_app_store_version(asc, app_id)
    version_id = version["id"]

    attach_build(asc, version_id, build["id"])
    set_whats_new(asc, version_id)
    submit_for_review(asc, app_id, version_id)


if __name__ == "__main__":
    main()
