#!/bin/sh
set -eu
exec > /root/mesa-build.log 2>&1
upload() { curl -fsS --max-time 8 -T /root/mesa-build.log http://10.0.2.2:9007/status.log >/dev/null 2>&1 || true; }
trap upload EXIT
cat > /etc/apk/repositories <<'REPOS'
https://dl-cdn.alpinelinux.org/alpine/v3.24/main
https://dl-cdn.alpinelinux.org/alpine/v3.24/community
REPOS
apk update
apk upgrade --available
apk add build-base meson ninja python3 py3-mako py3-yaml py3-packaging bison flex libdrm-dev expat-dev zlib-dev zstd-dev linux-headers eudev-dev libx11-dev libxcb-dev libxext-dev libxfixes-dev libxdamage-dev libxrandr-dev libxshmfence-dev xorgproto wayland-dev wayland-protocols libxxf86vm-dev curl xz
(while sleep 10; do upload; done) &
mkdir -p /root/mesa
cd /root/mesa
curl -fL --retry 3 https://mesa.freedesktop.org/archive/mesa-26.1.6.tar.xz -o mesa-26.1.6.tar.xz
printf '%s  mesa-26.1.6.tar.xz\n' '6746b73f5b87e8ff3723eee586b4b5f033dbe6d13cd0309d743b7fa484c350268859ec8ff21aadcbca7a04070cdaa7828146dd28dde4b1935bb879891d687f0b' | sha512sum -c -
tar -xf mesa-26.1.6.tar.xz
cd mesa-26.1.6
meson setup build --prefix=/usr/local/alpineios-mesa --libdir=lib --buildtype=release -Dgallium-drivers=virgl -Dvulkan-drivers=[] -Dllvm=disabled -Dplatforms=x11,wayland -Dglvnd=disabled -Degl=enabled -Dglx=dri -Dgbm=enabled -Dgles1=disabled -Dgles2=enabled -Dopengl=true -Dgallium-rusticl=false -Dgallium-va=disabled -Dvideo-codecs=[] -Dbuild-tests=false -Dtools=[]
ninja -C build -j4
DESTDIR=/root/mesa/install ninja -C build install
mkdir -p /root/mesa/install/usr/local/alpineios-mesa/share/licenses
cp docs/license.rst /root/mesa/install/usr/local/alpineios-mesa/share/licenses/Mesa.txt
find /root/mesa/install/usr/local/alpineios-mesa/lib -type f -name '*.so*' -exec strip --strip-unneeded {} \;
tar -C /root/mesa/install -czf /root/mesa/mesa-virgl.tar.gz usr/local/alpineios-mesa/lib usr/local/alpineios-mesa/share
curl -fsS --max-time 120 -T /root/mesa/mesa-virgl.tar.gz http://10.0.2.2:9007/mesa-virgl.tar.gz
printf '\nMESA_VIRGL_BUILD_OK\n'
