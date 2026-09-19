#!/usr/bin/env bash
# Pre-publish checks for a built image. `make verify` and CI both run this,
# so the two can't drift apart.
#
#   verify.sh IMAGE_REF MAJOR VARIANT [ARCH]
#
#   IMAGE_REF  the image to check, e.g. localhost/rocky-bootc:10-minimal
#   MAJOR      Rocky major version it must be, e.g. 10
#   VARIANT    variant it must be, e.g. minimal
#   ARCH       optional: amd64 or arm64; asserts the kernel package's arch
#
# PODMAN in the environment overrides the podman invocation (e.g. "sudo podman").
set -euo pipefail

ref=${1:?usage: verify.sh IMAGE_REF MAJOR VARIANT [ARCH]}
major=${2:?usage: verify.sh IMAGE_REF MAJOR VARIANT [ARCH]}
variant=${3:?usage: verify.sh IMAGE_REF MAJOR VARIANT [ARCH]}
arch=${4:-}
PODMAN=${PODMAN:-podman}

run() { $PODMAN run --rm "$ref" "$@"; }

echo "--- it is Rocky, at the major version we claim ---"
run sh -c '
    . /etc/os-release
    test "$ID" = rocky
    test "${VERSION_ID%%.*}" = '"$major"'
    echo "$PRETTY_NAME"'

echo "--- and it is the variant we asked for ---"
got="$($PODMAN inspect -f '{{ index .Config.Labels "io.github.schmidtw.rocky-bootc.variant" }}' "$ref")"
test "$got" = "$variant" || { echo "ERROR: image is variant '$got', expected '$variant'" >&2; exit 1; }
echo "$variant"

if [ -n "$arch" ]; then
    echo "--- and it is the arch we think ---"
    case "$arch" in
        amd64) want=x86_64 ;;
        arm64) want=aarch64 ;;
        *) echo "ERROR: unknown arch '$arch'" >&2; exit 1 ;;
    esac
    got="$(run rpm -q --qf '%{ARCH}\n' kernel | tail -n1)"
    test "$got" = "$want" || { echo "ERROR: kernel is $got, expected $want" >&2; exit 1; }
    echo "$got"
fi

# Warnings are fatal: the image passes clean today, so any warning is a
# regression, and a warning nobody reads is how one ships.
echo "--- bootc is happy with it ---"
run bootc container lint --fatal-warnings

echo "--- it runs systemd by default and stops it the way systemd expects ---"
got="$($PODMAN inspect -f '{{ join .Config.Cmd " " }}' "$ref")"
test "$got" = /sbin/init || { echo "ERROR: default command is '$got', expected /sbin/init" >&2; exit 1; }
got="$($PODMAN inspect -f '{{ .Config.StopSignal }}' "$ref")"
test "$got" = SIGRTMIN+3 || { echo "ERROR: stop signal is '$got', expected SIGRTMIN+3" >&2; exit 1; }
echo "CMD /sbin/init, STOPSIGNAL SIGRTMIN+3"

# bootc-image-builder needs bootupd (bootloader install) and bubblewrap
# (bootc sandboxes bootupd in bwrap) from this image; without either, every
# disk build fails. Nothing else exercises these until someone tries to make a
# qcow2 and it breaks for them.
echo "--- disk builds will work ---"
run sh -c 'command -v bootupctl && command -v bwrap'
run rpm -q bootupd bubblewrap
run test -f /usr/lib/bootc/install/20-rocky.toml

# Both fix silent first-boot failures, so their absence would be silent too.
echo "--- first boot will grow / (once growpart is layered) and keep its logs ---"
run test -x /usr/libexec/bootc-generic-growpart
run test -L /usr/lib/systemd/system/local-fs.target.wants/bootc-generic-growpart.service
run grep -qr '^Storage=persistent' /usr/lib/systemd/journald.conf.d/

echo "==> All checks passed for $ref"
