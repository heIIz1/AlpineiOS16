#!/usr/bin/env python3
"""Prepare an official Alpine ARM64 UEFI cloud image and NoCloud seed on macOS."""
import argparse
import hashlib
import json
import secrets
import shutil
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_URL = ("https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/cloud/"
               "alpine-3.23.8-aarch64-uefi-cloudinit-r0.qcow2")


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def download(url, dest):
    tmp = dest.with_suffix(dest.suffix + ".download")
    try:
        with urllib.request.urlopen(url, timeout=60) as src, tmp.open("wb") as out:
            shutil.copyfileobj(src, out)
        tmp.replace(dest)
    finally:
        tmp.unlink(missing_ok=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--image-url", default=DEFAULT_URL)
    p.add_argument("--guest-setup", type=Path, help="Root setup script run inside the guest on first boot")
    p.add_argument("--poweroff", action="store_true", help="Power off after first-boot setup (for Mac image preparation)")
    p.add_argument("--output", type=Path, default=ROOT / "work" / "Alpine")
    p.add_argument("--firmware-dir", type=Path, default=Path("/opt/homebrew/share/qemu"))
    args = p.parse_args()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    for name in ("alpine.img", "seed.img", "vars.fd", "login.txt"):
        if (out / name).exists():
            p.error(f"{out / name} already exists; choose a new --output to protect guest data")
    for tool in ("qemu-img", "hdiutil"):
        if not shutil.which(tool):
            p.error(f"Missing {tool}; install QEMU with brew install qemu")
    code = args.firmware_dir / "edk2-aarch64-code.fd"
    variables = args.firmware_dir / "edk2-arm-vars.fd"
    if not code.is_file() or not variables.is_file():
        p.error("QEMU EDK2 firmware not found; specify --firmware-dir")
    cache = ROOT / "work" / "downloads"
    cache.mkdir(parents=True, exist_ok=True)
    image = cache / Path(args.image_url).name
    checksum = image.with_suffix(image.suffix + ".sha512")
    print("Downloading official image and SHA512 manifest...", flush=True)
    download(args.image_url + ".sha512", checksum)
    expected = checksum.read_text().split()[0].lower()
    if len(expected) != 128 or any(c not in "0123456789abcdef" for c in expected):
        raise SystemExit("Invalid SHA512 manifest")
    if not image.exists():
        download(args.image_url, image)
    with image.open("rb") as f:
        digest = hashlib.sha512()
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
        actual = digest.hexdigest()
    if actual != expected:
        raise SystemExit(f"SHA512 mismatch: remove {image} and retry")
    info = json.loads(subprocess.check_output(["qemu-img", "info", "--output=json", str(image)]))
    if info.get("format") != "qcow2" or info.get("backing-filename"):
        raise SystemExit("Expected a standalone QCOW2 image")
    run("qemu-img", "convert", "-f", "qcow2", "-O", "raw", image, out / "alpine.img")
    run("qemu-img", "resize", "-f", "raw", out / "alpine.img", "8G")
    shutil.copyfile(code, out / "code.fd")
    shutil.copyfile(variables, out / "vars.fd")
    seed = out / "seed-data"
    seed.mkdir()
    password = secrets.token_hex(8)
    (seed / "meta-data").write_text("instance-id: alpineios-" + secrets.token_hex(8) + "\nlocal-hostname: alpine-iphone\n")
    # Keep SSH password auth off. The generated password is for the local console.
    (seed / "user-data").write_text(f"""#cloud-config
hostname: alpine-iphone
ssh_pwauth: false
chpasswd:
  expire: false
  users:
    - name: alpine
      password: "{password}"
      type: text
write_files:
  - path: /etc/local.d/alpineios.start
    permissions: '0755'
    content: |
      #!/bin/sh
      # Expose a login on the UEFI framebuffer as well as the serial console.
      grep -q '^tty1:' /etc/inittab || echo 'tty1::respawn:/sbin/getty 38400 tty1' >> /etc/inittab
      kill -HUP 1
runcmd:
  - [rc-update, add, local, default]
  - [sh, /etc/local.d/alpineios.start]
  - [sh, -c, 'echo ALPINEIOS_READY > /dev/ttyAMA0']
""")
    if args.guest_setup:
        script = args.guest_setup.read_text()
        cloud = (seed / "user-data").read_text()
        entry = "  - path: /root/guest-setup.sh\n    permissions: '0700'\n    content: |\n"
        entry += "".join("      " + line + "\n" for line in script.splitlines())
        cloud = cloud.replace("runcmd:\n", entry + "runcmd:\n")
        cloud += "  - [sh, /root/guest-setup.sh]\n"
        (seed / "user-data").write_text(cloud)
    if args.poweroff:
        cloud = (seed / "user-data").read_text()
        cloud += "power_state:\n  mode: poweroff\n  delay: now\n  timeout: 180\n"
        (seed / "user-data").write_text(cloud)
    run("hdiutil", "makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
        "-o", out / "seed.iso", seed)
    (out / "seed.iso").rename(out / "seed.img")
    (out / "login.txt").write_text(f"Local console login: alpine\nPassword: {password}\nUse: doas -s\n")
    (out / "login.txt").chmod(0o600)
    (seed / "user-data").chmod(0o600)
    (out / "image-source.json").write_text(json.dumps({"url": args.image_url, "sha512": actual}, indent=2) + "\n")
    print(f"Prepared VM files in {out}. Console credentials are in login.txt.")


if __name__ == "__main__":
    main()
