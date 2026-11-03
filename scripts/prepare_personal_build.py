"""Prepare a personal build without the upstream author's git-crypt key.

Run from any directory: python3 scripts/prepare_personal_build.py
Only missing/encrypted optional config files are replaced. Existing plaintext
configuration is preserved. This does not supply signing credentials.
"""

from pathlib import Path
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]


def prepare(relative_path, contents):
    target = ROOT / relative_path
    if target.exists() and not target.read_bytes().startswith(b"\x00GITCRYPT"):
        print(f"Preserved {relative_path}")
        return
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(contents)
    print(f"Prepared {relative_path}")


def main():
    prepare(
        "lib/config/config.dart",
        (ROOT / "lib/config/config.dart.sample").read_bytes(),
    )
    # Firebase is disabled in Global.enableFirebase and is not a dependency of
    # this app. Xcode still copies the plist resource, which must be valid XML.
    prepare("ios/Runner/GoogleService-Info.plist", plistlib.dumps({}))
    prepare("ios/firebase_app_id_file.json", json.dumps({}).encode("utf-8"))


if __name__ == "__main__":
    main()
