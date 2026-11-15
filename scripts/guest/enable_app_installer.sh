#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

cat > /usr/local/bin/alpineios-install-apps <<'GUEST'
#!/bin/sh
set -eu

state=/var/lib/alpineios
bridge=http://10.0.2.4
mkdir -p -m 700 "$state"
umask 077
request="$state/request"
response="$bridge/.alpineios-install-status"

report() {
    curl -fsS --max-time 5 -X PUT --data-binary "$1" "$response" >/dev/null 2>&1 || true
}

if [ -f "$state/installed" ]; then
    report ready
    exit 0
fi

while :; do
    if ! curl -fsS --max-time 10 "$bridge/.alpineios-install-request" -o "$request"; then
        sleep 5
        continue
    fi
    {
        IFS= read -r password
        IFS= read -r choices
    } < "$request" || { rm -f "$request"; sleep 5; continue; }
    rm -f "$request"
    case "$password" in
        ''|*[!a-f0-9]*) sleep 5; continue ;;
    esac
    [ "${#password}" -eq 32 ] || { sleep 5; continue; }

    set --
    telegram=false
    for choice in $choices; do
        case "$choice" in
            firefox) set -- "$@" firefox ;;
            nautilus) set -- "$@" nautilus ;;
            console) set -- "$@" gnome-console ;;
            editor) set -- "$@" mousepad ;;
            monitor) set -- "$@" htop ;;
            telegram) telegram=true; set -- "$@" telegram-desktop ;;
        esac
    done

    printf 'user:%s\n' "$password" | busybox chpasswd
    unset password
    report installing
    if $telegram; then
        # postmarketOS v26.06 Telegram needs the signed Alpine v3.23 ADA ABI package.
        ada=ada-libs-3.3.0-r0.apk
        if ! curl -fsS --max-time 60 "https://dl-cdn.alpinelinux.org/alpine/v3.23/main/aarch64/$ada" -o "$state/$ada"; then
            report retrying
            sleep 20
            continue
        fi
        set -- "$state/$ada" "$@"
    fi

    if [ "$#" -eq 0 ] || apk add --update-cache "$@" </dev/null; then
        touch "$state/installed"
        rm -f "$state/"*.apk
        report ready
        exit 0
    fi
    report retrying
    sleep 20
done
GUEST
chmod 755 /usr/local/bin/alpineios-install-apps

cat > /etc/init.d/alpineios-install-apps <<'OPENRC'
#!/sbin/openrc-run
description="Install the applications selected on the iPhone"
command="/usr/local/bin/alpineios-install-apps"
command_background=true
pidfile="/run/alpineios-install-apps.pid"
output_log="/var/log/alpineios-install-apps.log"
error_log="/var/log/alpineios-install-apps.log"
depend() { after networking; }
OPENRC
chmod 755 /etc/init.d/alpineios-install-apps
rc-update add alpineios-install-apps default
rc-update del sshd default
# The downloadable disk boots without NoCloud media.
find /etc/runlevels -type l -name 'cloud-*' -exec rm -f {} +
# Let the running cloud-init finish provisioning and poweroff, then discard its build seed.
cat > /etc/local.d/alpineios-release.stop <<'CLEANUP'
#!/bin/sh
rm -rf /var/lib/cloud/instances /var/lib/cloud/instance /var/lib/cloud/seed
rm -f /var/log/cloud-init*.log /root/guest-setup.sh /etc/shadow- /etc/ssh/ssh_host_*
rm -f /etc/local.d/alpineios-release.stop
CLEANUP
chmod 755 /etc/local.d/alpineios-release.stop
rc-service local start
