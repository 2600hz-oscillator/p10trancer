#!/usr/bin/env python3
"""
End-to-end TestFlight setup driver against the App Store Connect API.

Picks up the latest build under the configured app, sets `whatToTest`,
ensures internal + external (public-link) beta groups exist, adds the
owner Apple ID as an internal tester, attaches the build to both
groups, and submits the external group for Beta App Review.

No Apple ID password / 2FA needed — uses the .p8 key + issuer ID.

Run with `flox activate -- python3 scripts/asc_testflight.py`.
"""

import argparse
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import jwt
import requests

API = "https://api.appstoreconnect.apple.com/v1"
KEY_ID = "K8C68YU93D"
ISSUER_ID = "812570cd-5307-40bf-aca8-a6793544676c"
KEY_PATH = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{KEY_ID}.p8"
BUNDLE_ID = "com.p10entrancer.app"


def make_token() -> str:
    """ES256-signed JWT for App Store Connect."""
    private_key = KEY_PATH.read_text()
    now = datetime.now(timezone.utc)
    payload = {
        "iss": ISSUER_ID,
        "iat": int(now.timestamp()),
        "exp": int((now + timedelta(minutes=15)).timestamp()),
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": KEY_ID, "typ": "JWT"}
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


class ASC:
    def __init__(self):
        self.token = make_token()
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {self.token}"

    def _request(self, method: str, path: str, allow_403: bool = False, **kwargs):
        url = path if path.startswith("http") else API + path
        r = self.session.request(method, url, **kwargs)
        if r.status_code == 403 and allow_403:
            return {"_forbidden": True}
        if not r.ok:
            sys.stderr.write(f"\n[asc] {method} {url} → {r.status_code}\n{r.text}\n")
            r.raise_for_status()
        return r.json() if r.text else {}

    def get(self, path: str, **kw): return self._request("GET", path, **kw)
    def post(self, path: str, **kw): return self._request("POST", path, **kw)
    def patch(self, path: str, **kw): return self._request("PATCH", path, **kw)
    def delete(self, path: str, **kw): return self._request("DELETE", path, **kw)

    def app_id_for_bundle(self, bundle_id: str) -> str:
        data = self.get("/apps", params={"filter[bundleId]": bundle_id})["data"]
        if not data:
            raise SystemExit(f"App {bundle_id} not found")
        return data[0]["id"]

    def latest_build(self, app_id: str) -> dict:
        data = self.get("/builds", params={
            "filter[app]": app_id,
            "sort": "-uploadedDate",
            "limit": 1,
        })["data"]
        if not data:
            raise SystemExit("No builds yet for this app")
        return data[0]

    def wait_for_processing(self, app_id: str, timeout_s: int = 30 * 60) -> dict:
        start = time.time()
        last_state = None
        while time.time() - start < timeout_s:
            build = self.latest_build(app_id)
            attrs = build["attributes"]
            state = attrs.get("processingState")
            if state != last_state:
                v = attrs.get("version")
                sv = attrs.get("preReleaseVersion") or {}
                print(f"[asc] build {attrs.get('uploadedDate')} v={v} processingState={state}")
                last_state = state
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise SystemExit(f"Build processing failed: {attrs}")
            time.sleep(20)
        raise SystemExit("Timed out waiting for build processing")

    def set_what_to_test(self, build_id: str, what_to_test: str):
        existing = self.get(f"/builds/{build_id}/betaBuildLocalizations")["data"]
        if existing:
            loc_id = existing[0]["id"]
            self.patch(f"/betaBuildLocalizations/{loc_id}", json={
                "data": {
                    "type": "betaBuildLocalizations",
                    "id": loc_id,
                    "attributes": {"whatsNew": what_to_test},
                }
            })
        else:
            self.post("/betaBuildLocalizations", json={
                "data": {
                    "type": "betaBuildLocalizations",
                    "attributes": {"locale": "en-US", "whatToTest": what_to_test},
                    "relationships": {
                        "build": {"data": {"type": "builds", "id": build_id}},
                    },
                }
            })

    def ensure_beta_review_details(self, app_id: str, contact_first: str,
                                    contact_last: str, contact_email: str,
                                    contact_phone: str, demo_user: str = "",
                                    demo_password: str = "",
                                    notes: str = ""):
        """Beta App Review requires contact info on the app once."""
        details = self.get("/betaAppReviewDetails", params={
            "filter[app]": app_id, "limit": 1,
        })["data"]
        if not details:
            self.post("/betaAppReviewDetails", json={
                "data": {
                    "type": "betaAppReviewDetails",
                    "attributes": {
                        "contactFirstName": contact_first,
                        "contactLastName": contact_last,
                        "contactEmail": contact_email,
                        "contactPhone": contact_phone,
                        "demoAccountName": demo_user,
                        "demoAccountPassword": demo_password,
                        "demoAccountRequired": False,
                        "notes": notes,
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                    },
                }
            })
        else:
            d = details[0]
            self.patch(f"/betaAppReviewDetails/{d['id']}", json={
                "data": {
                    "type": "betaAppReviewDetails",
                    "id": d["id"],
                    "attributes": {
                        "contactFirstName": contact_first,
                        "contactLastName": contact_last,
                        "contactEmail": contact_email,
                        "contactPhone": contact_phone,
                        "demoAccountName": demo_user,
                        "demoAccountPassword": demo_password,
                        "demoAccountRequired": False,
                        "notes": notes,
                    },
                }
            })

    def ensure_beta_app_localization(self, app_id: str, description: str,
                                      feedback_email: str, marketing_url: str = "",
                                      privacy_url: str = "https://p10trancer.com/privacy",
                                      tos_url: str = ""):
        """Public-link beta groups require an app-level beta description."""
        locs = self.get(f"/apps/{app_id}/betaAppLocalizations")["data"]
        loc = next((l for l in locs if l["attributes"]["locale"] == "en-US"), None)
        if loc:
            self.patch(f"/betaAppLocalizations/{loc['id']}", json={
                "data": {
                    "type": "betaAppLocalizations",
                    "id": loc["id"],
                    "attributes": {
                        "description": description,
                        "feedbackEmail": feedback_email,
                        "marketingUrl": marketing_url,
                        "privacyPolicyUrl": privacy_url,
                        "tvOsPrivacyPolicy": "",
                    },
                }
            })
        else:
            self.post("/betaAppLocalizations", json={
                "data": {
                    "type": "betaAppLocalizations",
                    "attributes": {
                        "locale": "en-US",
                        "description": description,
                        "feedbackEmail": feedback_email,
                        "marketingUrl": marketing_url,
                        "privacyPolicyUrl": privacy_url,
                    },
                    "relationships": {
                        "app": {"data": {"type": "apps", "id": app_id}},
                    },
                }
            })

    def find_or_create_beta_group(self, app_id: str, name: str,
                                   public: bool = False) -> dict:
        groups = self.get("/betaGroups", params={"filter[app]": app_id})["data"]
        for g in groups:
            if g["attributes"]["name"] == name:
                return g
        attrs = {"name": name}
        if public:
            attrs["publicLinkEnabled"] = True
            attrs["publicLinkLimitEnabled"] = False
        return self.post("/betaGroups", json={
            "data": {
                "type": "betaGroups",
                "attributes": attrs,
                "relationships": {
                    "app": {"data": {"type": "apps", "id": app_id}},
                },
            }
        })["data"]

    def attach_build_to_group(self, group_id: str, build_id: str):
        self.post(f"/betaGroups/{group_id}/relationships/builds", json={
            "data": [{"type": "builds", "id": build_id}],
        })

    def add_internal_tester(self, group_id: str, email: str,
                             first: str = "Tester", last: str = "Tester"):
        # Try POST first; if it 409s the tester already exists somewhere in
        # this developer account (filter[email] doesn't always match if
        # they were added without an explicit beta-tester record).
        try:
            tester_id = self.post("/betaTesters", json={
                "data": {
                    "type": "betaTesters",
                    "attributes": {"email": email, "firstName": first, "lastName": last},
                    "relationships": {
                        "betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]},
                    },
                }
            })["data"]["id"]
            return  # POST included the group relationship — done.
        except requests.HTTPError as e:
            if e.response.status_code != 409:
                raise
        # 409: fetch existing and add to group separately.
        existing = self.get("/betaTesters", params={"filter[email]": email})["data"]
        if not existing:
            raise SystemExit(f"Conflict on POST /betaTesters but couldn't find {email} via filter")
        tester_id = existing[0]["id"]
        try:
            self.post(f"/betaGroups/{group_id}/relationships/betaTesters", json={
                "data": [{"type": "betaTesters", "id": tester_id}],
            })
        except requests.HTTPError as e:
            if e.response.status_code != 409:
                raise

    def submit_for_beta_review(self, build_id: str) -> dict:
        return self.post("/betaAppReviewSubmissions", json={
            "data": {
                "type": "betaAppReviewSubmissions",
                "relationships": {
                    "build": {"data": {"type": "builds", "id": build_id}},
                },
            }
        })["data"]

    def public_link(self, group_id: str) -> str | None:
        g = self.get(f"/betaGroups/{group_id}")["data"]
        return g["attributes"].get("publicLink")


WHAT_TO_TEST = """\
v1.1.0 — first beta of the new layout.

Try:
- 4×3 unified grid (9 source pads + 3 output pads: KEYER 1, KEYER 2, FEEDBACK)
- Tap a pad to route to the active channel; long-press to load video, set camera, etc.
- Output pads' gear icon (lower left) opens setup with a source picker —
  KEYER 1 can use KEYER 2 / FEEDBACK as input, etc.
- Per-pad play/stop + per-pad mute icons (lower right of each source pad)
- Cameras as pads: turn up the per-camera volume in the mixer to record mic
- Master mixer's chroma transition is now independent of the keyers

Known issues:
- Some screen real estate is wasted in portrait while we tune layout
- Recording cuts video PTS at first frame (intentional) — the first ~16ms isn't visible
"""

BETA_DESCRIPTION = """\
p10trancer is an iPad video sampler / mixer / glitch processor. Load 9 video
sources, route them to two channels, mix with crossfade or chroma-key
transitions, and run live through a simulated NTSC pipeline. Designed for
live VJing and experimental video work.
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner-email", default="tmayshark@gmail.com")
    ap.add_argument("--feedback-email", default="tmayshark@gmail.com")
    ap.add_argument("--contact-first", default="Tristan")
    ap.add_argument("--contact-last", default="Mayshark")
    ap.add_argument("--contact-email", default="tmayshark@gmail.com")
    ap.add_argument("--contact-phone", default="+15555555555",
                    help="Phone for Beta App Review contact (override)")
    ap.add_argument("--skip-wait", action="store_true",
                    help="Skip waiting for processing")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    asc = ASC()
    print(f"[asc] resolving app {BUNDLE_ID}")
    app_id = asc.app_id_for_bundle(BUNDLE_ID)
    print(f"[asc] app id = {app_id}")

    if args.skip_wait:
        build = asc.latest_build(app_id)
    else:
        print("[asc] waiting for latest build to finish processing…")
        build = asc.wait_for_processing(app_id)
    build_id = build["id"]
    build_v = build["attributes"].get("version")
    print(f"[asc] build {build_id} v{build_v} processingState=VALID")

    if args.dry_run:
        return

    print("[asc] setting whatToTest")
    asc.set_what_to_test(build_id, WHAT_TO_TEST)

    print("[asc] ensuring beta app localization (description, feedback email)")
    asc.ensure_beta_app_localization(
        app_id,
        description=BETA_DESCRIPTION,
        feedback_email=args.feedback_email,
    )

    print("[asc] ensuring beta app review details (contact info)")
    asc.ensure_beta_review_details(
        app_id,
        contact_first=args.contact_first,
        contact_last=args.contact_last,
        contact_email=args.contact_email,
        contact_phone=args.contact_phone,
    )

    print("[asc] internal group: 'Internal'")
    internal = asc.find_or_create_beta_group(app_id, "Internal", public=False)
    asc.attach_build_to_group(internal["id"], build_id)
    print(f"[asc] adding {args.owner_email} as internal tester")
    asc.add_internal_tester(internal["id"], args.owner_email,
                            first=args.contact_first, last=args.contact_last)

    print("[asc] external group: 'Public Beta' (public link enabled)")
    public = asc.find_or_create_beta_group(app_id, "Public Beta", public=True)
    asc.attach_build_to_group(public["id"], build_id)

    print("[asc] submitting build for Beta App Review")
    try:
        asc.submit_for_beta_review(build_id)
    except requests.HTTPError as e:
        if e.response.status_code == 409:
            print("[asc] already submitted (409) — that's fine")
        else:
            raise

    link = asc.public_link(public["id"])
    print()
    print("=" * 60)
    print(f"Build:               v{build_v} ({build_id})")
    print(f"Internal group:      {internal['id']}")
    print(f"Public group:        {public['id']}")
    print(f"Public link:         {link or '(pending Beta Review approval)'}")
    print("=" * 60)


if __name__ == "__main__":
    main()
