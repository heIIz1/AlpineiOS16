#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Stage the ARM64 iOS VirGL/ANGLE frameworks from UTM's pinned public release."""
import hashlib
import shutil
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = "v5.0.8"
CHECKSUM = "4875a1ec869278fb173b37467388ea627bfa6d95f1d64501bc41bb86dd7d53b2"
NAMES = ("vulkan.1", "epoxy.0", "GLESv2", "EGL", "virglrenderer.1")


def main():
    archive = ROOT / "work" / "downloads" / f"UTM-{VERSION}.ipa"
    archive.parent.mkdir(parents=True, exist_ok=True)
    if not archive.exists():
        temporary = archive.with_suffix(".download")
        try:
            with urllib.request.urlopen(
                f"https://github.com/utmapp/UTM/releases/download/{VERSION}/UTM.ipa", timeout=90
            ) as source, temporary.open("wb") as target:
                shutil.copyfileobj(source, target)
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != CHECKSUM:
        raise SystemExit(f"Checksum mismatch for {archive}")
    destination = ROOT / "ios" / "deps" / "Frameworks"
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as files:
        for name in NAMES:
            prefix = f"Payload/UTM.app/Frameworks/{name}.framework/"
            framework = destination / f"{name}.framework"
            if framework.exists():
                shutil.rmtree(framework)
            framework.mkdir()
            for entry in files.infolist():
                if not entry.filename.startswith(prefix) or entry.is_dir():
                    continue
                relative = Path(entry.filename[len(prefix):])
                if ".." in relative.parts or "_CodeSignature" in relative.parts:
                    continue
                target = framework / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                with files.open(entry) as source, target.open("wb") as output:
                    shutil.copyfileobj(source, output)
    print(f"Staged VirGL and ANGLE from UTM {VERSION}")


if __name__ == "__main__":
    main()
