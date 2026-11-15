#!/usr/bin/env python3
"""Launch a development-signed AlpineiOS app and attach the existing JIT helper."""
import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def lldb_quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("device", help="Paired iPhone UDID or CoreDevice identifier")
    p.add_argument("bundle_id", nargs="?", default="local.alpineios.app")
    a = p.parse_args()
    output = ROOT / "work" / "iphone-launch.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--start-stopped",
                    "--terminate-existing", "--device", a.device, "--json-output", str(output),
                    a.bundle_id], check=True)
    result = json.loads(output.read_text())["result"]
    pid = int(result["process"]["processIdentifier"])
    device = result.get("device", {}).get("identifier", a.device)
    subprocess.run(["xcrun", "lldb", "-b", "-o", "script lldb.debugger.SetAsync(False)",
                    "-o", "device select " + lldb_quote(device),
                    "-o", f"device process attach -p {pid}",
                    "-o", "command script import " + lldb_quote(ROOT / "scripts" / "_lldb_txm_jit.py"),
                    "-o", "txm_jit_run"], check=True)


if __name__ == "__main__":
    main()
