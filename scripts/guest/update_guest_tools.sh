#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu
version=14
bridge=http://10.0.2.4
status="$bridge/.alpineios-tools-status"
report() { curl -fsS --max-time 5 -X PUT --data-binary "$1" "$status" >/dev/null 2>&1 || true; }
log=/var/log/alpineios-guest-tools.log
mkdir -p /var/log
exec > "$log" 2>&1
trap 'report failed' EXIT

apk add curl wl-clipboard </dev/null
report installing
if [ ! -s /usr/local/lib/alpineios-host-cpu.so ]; then
apk add --virtual .alpineios-host-build build-base glib-dev libgtop-dev </dev/null
mkdir -p /usr/local/lib /usr/local/src/alpineios

cat > /usr/local/src/alpineios/host-cpu.c <<'SOURCE'
/* SPDX-License-Identifier: GPL-2.0-or-later */
/* GNOME/libgtop fallback for ARM kernels that omit a model-name cpuinfo field. */
#define _GNU_SOURCE
#include <glibtop/sysinfo.h>
#include <dlfcn.h>
#include <pthread.h>

static pthread_once_t once = PTHREAD_ONCE_INIT;
static const glibtop_sysinfo *result;

static void initialize(void) {
    const glibtop_sysinfo *(*original)(void) = dlsym(RTLD_NEXT, "glibtop_get_sysinfo");
    if (!original) return;
    result = original();
    if (!result) return;
    char *chip = NULL;
    if (!g_file_get_contents("/sys/class/dmi/id/product_version", &chip, NULL, NULL)) return;
    g_strstrip(chip);
    if (!g_str_has_prefix(chip, "Apple ")) { g_free(chip); return; }
    for (guint64 i = 0; i < result->ncpu && i < GLIBTOP_NCPU; i++) {
        GHashTable *values = result->cpuinfo[i].values;
        if (values && !g_hash_table_lookup(values, "model name") &&
            !g_hash_table_lookup(values, "cpu") && !g_hash_table_lookup(values, "Processor"))
            g_hash_table_insert(values, g_strdup("model name"), g_strdup(chip));
    }
    g_free(chip);
}

const glibtop_sysinfo *glibtop_get_sysinfo(void) {
    pthread_once(&once, initialize);
    return result;
}
SOURCE
cc -shared -fPIC -O2 $(pkg-config --cflags libgtop-2.0)     /usr/local/src/alpineios/host-cpu.c -o /usr/local/lib/alpineios-host-cpu.so.new     $(pkg-config --libs glib-2.0) -ldl -pthread
mv /usr/local/lib/alpineios-host-cpu.so.new /usr/local/lib/alpineios-host-cpu.so
apk del .alpineios-host-build
fi

clients=/usr/local/bin/phone-phosh-native-clients
launcher=/usr/local/bin/phone-phosh-native
# The session bus does not pass LD_PRELOAD through to activated apps.
# Override only the Settings service and set the preload in its Exec command.
sed -i '\|^export LD_PRELOAD=/usr/local/lib/alpineios-host-cpu.so$|d' "$clients" "$launcher"
su -s /bin/sh user <<'SETTINGS_SERVICE'
set -eu
services=/home/user/.local/share/dbus-1/services
mkdir -p "$services"
cat > "$services/org.gnome.Settings.service" <<'SERVICE'
[D-BUS Service]
Name=org.gnome.Settings
Exec=/usr/bin/env LD_PRELOAD=/usr/local/lib/alpineios-host-cpu.so /usr/bin/gnome-control-center --gapplication-service
SERVICE
SETTINGS_SERVICE
sed -i '/gsettings set org.gnome.desktop.interface enable-animations /d' "$clients"
sed -i '/^phosh-osk-stevia /i gsettings set org.gnome.desktop.interface enable-animations true' "$clients"
if ! grep -q 'org.gnome.desktop.session idle-delay' "$clients"; then
    sed -i '/^phosh-osk-stevia /i gsettings set org.gnome.desktop.session idle-delay "uint32 0" || true' "$clients"
fi

if [ "$(curl -fsS --max-time 5 "$bridge/.alpineios-graphics" || true)" = virgl ]; then
    curl -fsS --max-time 120 "$bridge/guest-virgl.tar.gz" -o /tmp/guest-virgl.tar.gz
    expected="$(curl -fsS --max-time 10 "$bridge/guest-virgl.sha256")"
    printf '%s  /tmp/guest-virgl.tar.gz\n' "$expected" | sha256sum -c -
    tar -xzf /tmp/guest-virgl.tar.gz -C /
    rm /tmp/guest-virgl.tar.gz
    if ! grep -q 'LD_LIBRARY_PATH=/usr/local/alpineios-mesa/lib' /usr/local/bin/phone-phosh-native; then
        sed -i '/^set -eu/a export LD_LIBRARY_PATH=/usr/local/alpineios-mesa/lib\nexport LIBGL_DRIVERS_PATH=/usr/local/alpineios-mesa/lib/dri' /usr/local/bin/phone-phosh-native
    fi
    # Keep the compositor on the known-good scanout path. Wayland GL clients use VirGL.
    sed -i 's/WLR_RENDERER=gles2/WLR_RENDERER=pixman/; s/LIBGL_ALWAYS_SOFTWARE=1 //; s/GSK_RENDERER=gl/GSK_RENDERER=cairo/; s/QT_QUICK_BACKEND=software/QT_QUICK_BACKEND=opengl/' /usr/local/bin/phone-phosh-native
fi

if ! grep -q 'pulseaudio --start' "$clients"; then
    sed -i '/^phosh-osk-stevia /i pulseaudio --start --exit-idle-time=-1 || true' "$clients"
fi

# Read the device's scale once per Phosh session. Keep the base config as a fallback.
cat > /usr/local/bin/alpineios-phoc-config <<'CONFIG'
#!/bin/sh
base=/etc/phosh/phone-native.ini
config="$XDG_RUNTIME_DIR/alpineios-phoc.ini"
scale="$(curl -fsS --max-time 3 http://10.0.2.4/.alpineios-display-scale 2>/dev/null)" || scale=1
if ! printf '%s\n' "$scale" | grep -Eq '^1([.][0-9]{1,3})?$'; then scale=1; fi
awk -v scale="$scale" '
    /^\[/ { virtual=($0=="[output:Virtual-1]"); found=found||virtual }
    virtual && /^[[:space:]]*scale[[:space:]]*=/ { next }
    { print }
    /^\[output:Virtual-1\]$/ { print "scale=" scale }
    END { if (!found) print "\n[output:Virtual-1]\nscale=" scale }
' "$base" > "$config" && printf '%s\n' "$config"
CONFIG
chmod 755 /usr/local/bin/alpineios-phoc-config
sed -i 's|-C /etc/phosh/phone-native.ini|-C "$(alpineios-phoc-config)"|' "$launcher"

cat > /usr/local/bin/alpineios-desktop-bridge <<'DESKTOP_BRIDGE'
#!/bin/sh
bridge=http://10.0.2.4
last_action="$(curl -fsS --max-time 1 "$bridge/.alpineios-desktop-action" 2>/dev/null || true)"
last_mode=
while sleep 1; do
    mode="$(curl -fsS --max-time 1 "$bridge/.alpineios-display-mode" 2>/dev/null || true)"
    if [ -n "$mode" ] && [ "$mode" != "$last_mode" ]; then
        size=${mode% *}
        scale=${mode##* }
        if printf '%s\n' "$mode" | grep -Eq '^[0-9]{3,4}x[0-9]{3,4} 1[.][0-9]{3}$'; then
            if wlr-randr --output Virtual-1 --custom-mode "$size" --scale "$scale" >/dev/null 2>&1; then
                last_mode=$mode
            elif wlr-randr --output Virtual-1 --scale "$scale" >/dev/null 2>&1; then
                last_mode=$mode
            fi
        fi
    fi
    action="$(curl -fsS --max-time 1 "$bridge/.alpineios-desktop-action" 2>/dev/null || true)"
    [ -n "$action" ] && [ "$action" != "$last_action" ] || continue
    last_action=$action
    case "${action%% *}" in
        paste)
            curl -fsS --max-time 3 "$bridge/.henge/clipboard" | wl-copy --type 'text/plain;charset=utf-8'
            ;;
        copy)
            timeout 3 wl-paste --no-newline | curl -fsS --max-time 3 -X PUT --data-binary @- "$bridge/.henge/clipboard" >/dev/null
            ;;
        restart)
            pid=$(pgrep -o -x phoc)
            [ -z "$pid" ] || kill -TERM "$pid"
            exit
            ;;
    esac
done
DESKTOP_BRIDGE
chmod 755 /usr/local/bin/alpineios-desktop-bridge
if ! grep -q 'alpineios-desktop-bridge' "$clients"; then
    sed -i '/^phosh-osk-stevia /i /usr/local/bin/alpineios-desktop-bridge \&\nbridge_pid=$!' "$clients"
    sed -i 's/kill "\$osk"/kill "$osk" "$bridge_pid"/' "$clients"
fi

mkdir -p /var/lib/alpineios
# Builds that already use the current display profile do not need a live desktop restart.
case "$(cat /var/lib/alpineios/tools-version 2>/dev/null || true)" in
    10|11|12|13)
        # Start the new agent in the existing session, avoiding a compositor restart.
        if [ -S /tmp/xdg-phone-native/wayland-0 ]; then
            pkill -TERM -f '^/bin/sh /usr/local/bin/alpineios-desktop-bridge$' || true
            su -s /bin/sh user -c 'export XDG_RUNTIME_DIR=/tmp/xdg-phone-native WAYLAND_DISPLAY=wayland-0
                /usr/local/bin/alpineios-desktop-bridge </dev/null >/tmp/alpineios-desktop-bridge.log 2>&1 &'
        fi
        ;;
    14) ;;
    *)
        timeout 10 rc-service phone-phosh stop || true
        pkill -TERM -x phosh || true
        pkill -TERM -x phoc || true
        pkill -TERM -x Xwayland || true
        sleep 1
        rc-service phone-phosh start
        ;;
esac
password_file="$(mktemp)"
chmod 600 "$password_file"
if curl -fsS --max-time 5 "$bridge/.alpineios-password-request" -o "$password_file" 2>/dev/null; then
    password="$(cat "$password_file")"
    rm -f "$password_file"
    case "$password" in ''|*:*|*[![:print:]]*) exit 1 ;; esac
    [ "${#password}" -le 64 ] || exit 1
    printf 'user:%s\n' "$password" | busybox chpasswd
    unset password
    curl -fsS --max-time 5 -X PUT --data-binary ok "$bridge/.alpineios-password-applied" >/dev/null
else
    rm -f "$password_file"
fi
printf '%s\n' "$version" > /var/lib/alpineios/tools-version
report "$version"
trap - EXIT
