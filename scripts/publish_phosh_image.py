#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Stage a downloadable Phosh manifest and its assets for an HTTPS host."""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

ASSETS = ("code.fd", "vars.fd", "alpine.hvsparse")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("machine", type=Path)
    parser.add_argument("output", type=Path, help="New directory to upload or serve")
    args = parser.parse_args()
    if not (args.machine / ".downloadable").is_file():
        parser.error("prepare the image with scripts/prepare_phosh.sh --downloadable")
    for name in ASSETS:
        if not (args.machine / name).is_file():
            parser.error(f"missing {name}")
    args.output.mkdir()
    try:
        assets = {}
        for name in ASSETS:
            dst = args.output / name
            shutil.copyfile(args.machine / name, dst)
            digest = hashlib.sha256()
            with dst.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            assets[name] = {"bytes": dst.stat().st_size, "sha256": digest.hexdigest()}
        (args.output / "phosh.json").write_text(
            json.dumps({"version": 1, "assets": assets}, indent=2) + "\n"
        )
    except BaseException:
        shutil.rmtree(args.output)
        raise
    print(f"Host the contents of {args.output}; point AlpineiOS to phosh.json.")


if __name__ == "__main__":
    main()
