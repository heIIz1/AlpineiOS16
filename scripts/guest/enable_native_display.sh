#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

apk add seatd seatd-openrc stevia </dev/null
command -v phosh-osk-stevia
rc-update add seatd default
addgroup user video 2>/dev/null || true
addgroup user input 2>/dev/null || true
if grep -q '^seat:' /etc/group; then addgroup user seat 2>/dev/null || true; fi

mkdir -p /usr/local/bin /etc/phosh
cat > /usr/local/bin/phone-phosh-native <<'SESSION'
#!/bin/sh
set -eu
export HOME=/home/user USER=user XDG_RUNTIME_DIR=/tmp/xdg-phone-native
export XDG_CURRENT_DESKTOP=Phosh:GNOME XDG_SESSION_DESKTOP=phosh XDG_SESSION_TYPE=wayland
export WLR_BACKENDS=drm,libinput WLR_RENDERER=pixman LIBSEAT_BACKEND=seatd
export LIBGL_ALWAYS_SOFTWARE=1 GSK_RENDERER=cairo QT_QUICK_BACKEND=software MOZ_ENABLE_WAYLAND=1
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export WLR_DRM_DEVICES="$(readlink -f /dev/dri/by-path/pci-*-card | head -n 1)"
exec dbus-run-session -- phoc -S -C /etc/phosh/phone-native.ini -E /usr/local/bin/phone-phosh-native-clients
SESSION
cat > /usr/local/bin/phone-phosh-native-clients <<'CLIENTS'
#!/bin/sh
set -eu
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
gsettings set mobi.phosh.osk ignore-hw-keyboards true
phosh-osk-stevia &
osk=$!
trap 'kill "$osk" 2>/dev/null || true' EXIT HUP INT TERM
/usr/libexec/phosh --unlocked
CLIENTS
cat > /etc/phosh/phone-native.ini <<'CONFIG'
[core]
xwayland=true
CONFIG
chmod 755 /usr/local/bin/phone-phosh-native /usr/local/bin/phone-phosh-native-clients
cat > /etc/init.d/phone-phosh <<'SERVICE'
#!/sbin/openrc-run
name="Phone Phosh"
supervisor="supervise-daemon"
command="/usr/local/bin/phone-phosh-native"
command_user="user:user"
output_log="/var/log/phone-phosh.log"
error_log="/var/log/phone-phosh.log"
respawn_delay=5
respawn_max=5
respawn_period=60
depend() { need dbus seatd; after networking; }
SERVICE
chmod 755 /etc/init.d/phone-phosh
touch /var/log/phone-phosh.log
chown user:user /var/log/phone-phosh.log
rc-update add phone-phosh default
