#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Build the missing ARM64 Mesa VirGL guest driver in a disposable Alpine VM."""
import hashlib
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import threading

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / 'work' / 'GuestGraphics'
OUTPUT = ROOT / 'ios' / 'deps' / 'Resources' / 'guest-virgl.tar.gz'

def stage(archive, require_driver=True):
    with tarfile.open(archive) as files:
        names = files.getnames()
        if require_driver and not any(name.endswith('/virtio_gpu_dri.so') for name in names):
            raise SystemExit('Mesa build did not produce virtio_gpu_dri.so')
        if any(name.startswith('/') or '..' in Path(name).parts for name in names):
            raise SystemExit('Unsafe guest graphics archive path')
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    if archive.resolve() != OUTPUT.resolve():
        shutil.copyfile(archive, OUTPUT)
    OUTPUT.with_name('guest-virgl.sha256').write_text(hashlib.sha256(OUTPUT.read_bytes()).hexdigest() + '\n')
    if require_driver:
        print('Staged ARM64 Mesa VirGL guest driver')
    else:
        print('Skipped ARM64 Mesa VirGL guest driver build (ALPINE_SKIP_GUEST_GRAPHICS=1)')

def main():
    skip = os.environ.get('ALPINE_SKIP_GUEST_GRAPHICS') == '1'
    if len(sys.argv) == 3 and sys.argv[1] == '--stage':
        stage(Path(sys.argv[2])); return
    if OUTPUT.is_file():
        try:
            stage(OUTPUT)
            return
        except SystemExit:
            if not skip:
                raise
    if skip:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        if not OUTPUT.is_file():
            with tarfile.open(OUTPUT, 'w:gz'):
                pass
        stage(OUTPUT, require_driver=False)
        return
    WORK.mkdir(parents=True, exist_ok=True)
    archive = WORK / 'mesa-virgl.tar.gz'
    class Upload(BaseHTTPRequestHandler):
        def do_PUT(self):
            if self.path not in ('/status.log', '/mesa-virgl.tar.gz'):
                self.send_error(404); return
            length = int(self.headers.get('Content-Length', 0))
            if not 0 < length <= 100 * 1024 * 1024:
                self.send_error(413); return
            (WORK / self.path[1:]).write_bytes(self.rfile.read(length))
            self.send_response(204); self.end_headers()
        def log_message(self, *args): pass
    server = HTTPServer(('127.0.0.1', 9007), Upload)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    vm = WORK / 'vm'
    try:
        subprocess.run([sys.executable, str(ROOT / 'scripts/provision_alpine.py'),
                        '--guest-setup', str(ROOT / 'scripts/guest/build_virgl.sh'),
                        '--poweroff', '--output', str(vm)], check=True)
        command = ['qemu-system-aarch64', '-machine', 'virt,gic-version=3', '-accel', 'hvf',
                   '-cpu', 'host', '-smp', '4', '-m', '4096', '-display', 'none', '-monitor', 'none',
                   '-serial', 'stdio', '-drive', f'if=pflash,format=raw,readonly=on,file={vm}/code.fd',
                   '-drive', f'if=pflash,format=raw,file={vm}/vars.fd', '-drive',
                   f'if=none,format=raw,file={vm}/alpine.img,id=os', '-device', 'nvme,drive=os,serial=MESA',
                   '-drive', f'if=none,format=raw,readonly=on,file={vm}/seed.img,id=seed',
                   '-device', 'nvme,drive=seed,serial=SEED', '-netdev', 'user,id=net',
                   '-device', 'virtio-net-pci,netdev=net']
        print('Building Mesa VirGL; this takes several minutes. Progress: ' + str(WORK / 'status.log'), flush=True)
        with (WORK / 'qemu.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=1800, check=True)
        if not archive.is_file() or 'MESA_VIRGL_BUILD_OK' not in (WORK / 'status.log').read_text():
            raise SystemExit('Mesa build failed; inspect work/GuestGraphics/status.log')
        stage(archive)
    finally:
        server.shutdown(); server.server_close()

if __name__ == '__main__': main()
