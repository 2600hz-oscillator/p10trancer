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

VERSION_STRING = "2.0.0"
BUILD_VERSION = "3"
PLATFORM = "IOS"
WHATS_NEW = """\
Major release — the AFX feature pack lands:

• WAVECEL wavetable instrument + ACIDKICK 4×16 drum sequencer as new pad sources.
• In-app transcoding for .mkv / .webm / .avi imports via ffmpeg-kit, with a per-pad progress overlay.
• Rebuilt chroma keyer using HSV hue distance + spill suppression + native iOS color wheel for picking the key.
• Camera-into-CRT feedback model — additive blend with Reinhard tonemap, wider sweet spot, longer trails, brighter defaults.
• Per-pad volume slider strip and always-on audio routing so the pad mix is the recording mix.
• SAVE / LOAD session buttons; per-pad mute auto-engages on launch and on session load.
• Three LFOs per instrument pad via segmented tab editor.
• Thumbnail-quality knob (HIGH / MEDIUM / LOW) in the Inspector for older devices.
• Master mixer transitions clamp cleanly to pure CH1 at the rails and pure CH2 at the rails.
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


def submit_for_review(asc, version_id):
    print(f"[asc] submitting appStoreVersion {version_id[:8]}… for review")
    try:
        asc.post(
            "/appStoreVersionSubmissions",
            json={
                "data": {
                    "type": "appStoreVersionSubmissions",
                    "relationships": {
                        "appStoreVersion": {
                            "data": {"type": "appStoreVersions", "id": version_id}
                        }
                    },
                }
            },
        )
        print("[asc] submitted for review.")
    except Exception as e:
        # Most common failure: missing screenshots / metadata. Surface
        # the API error verbatim so the user knows what to fix.
        print(f"[asc] submission failed: {e}")
        print("[asc] check ASC web UI → Version 2.0.0 — likely missing screenshots")
        print("[asc]   or other per-version metadata that doesn't auto-derive from 1.1.0.")
        raise


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
    submit_for_review(asc, version_id)


if __name__ == "__main__":
    main()
