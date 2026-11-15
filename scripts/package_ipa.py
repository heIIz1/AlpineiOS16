#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Package an iOS app, optionally using XML plists for signer compatibility."""
import argparse
import os
from pathlib import Path
import plistlib
import stat
import tempfile
import zipfile


def package(app: Path, output: Path, xml_plists: bool = False) -> None:
    app = app.resolve()
    info = app / "Info.plist"
    metadata = plistlib.loads(info.read_bytes())
    executable = metadata.get("CFBundleExecutable", "")
    if app.suffix != ".app" or not executable or not (app / executable).is_file():
        raise ValueError("Expected an iOS .app with Info.plist and its executable")
    # Changing a signed plist would invalidate that bundle's signature.
    if xml_plists and any(app.rglob("_CodeSignature")):
        raise ValueError("XML conversion is only supported for unsigned apps")
    files = sorted(p for p in app.rglob("*") if p.is_file() or p.is_symlink())
    files.remove(info)
    files.insert(0, info)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".ipa-", dir=output.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for source in files:
                relative = source.relative_to(app)
                if any(part.startswith("._") or part == ".DS_Store" for part in relative.parts):
                    continue
                entry = zipfile.ZipInfo.from_file(source, f"Payload/{app.name}/{relative}")
                if source.is_symlink():
                    entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    data = os.readlink(source).encode()
                else:
                    data = source.read_bytes()
                    if xml_plists and source.suffix == ".plist":
                        data = plistlib.dumps(plistlib.loads(data), fmt=plistlib.FMT_XML)
                entry.compress_type = zipfile.ZIP_STORED if source.suffix == ".plist" else zipfile.ZIP_DEFLATED
                archive.writestr(entry, data)
        with zipfile.ZipFile(temporary) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA integrity check failed")
            packaged = plistlib.loads(archive.read(f"Payload/{app.name}/Info.plist"))
            if packaged != metadata:
                raise ValueError("IPA metadata changed unexpectedly")
        os.replace(temporary, output)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--xml-plists", action="store_true")
    args = parser.parse_args()
    package(args.app, args.output, args.xml_plists)
