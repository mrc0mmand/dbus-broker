#!/bin/bash
# vi: set sw=4 ts=4 et tw=110:
# shellcheck disable=SC2016

set -eux
set -o pipefail

# shellcheck source=test/integration/util.sh
. "$(dirname "$0")/../../util.sh"

# shellcheck disable=SC2317
at_exit() {
    set +ex

    # Let's do some cleanup and export logs if necessary

    # Collect potential coredumps
    coredumpctl_collect
    container_destroy
}

trap at_exit EXIT

# Make sure the coredump collecting machinery is working
coredumpctl_init

# Run the Valgrind-fied dbus-broker in a ligthweight container, so we don't risk damage to the underlying test
# machine (see fuzz/sanitizers/test.sh for more detailed reasoning).
#
# Some Valgrind-specific notes:
#   - Valgrind on Arch _requires_ working debuginfod servers, since it doesn't ship debuginfod packages, so
#     the container needs to be booted up with --network-veth, and the system dbus-broker service now needs to
#     depend on the network-online.target
#   - also, for the debuginfod stuff to work correctly, the respective .cache directories in user homes (which
#     need to exist) need to be writable
container_prepare

# Build & install a custom dbus-broker revision into the overlay if $DBUS_BROKER_TREE is set (for a quick
# local debugging):
#
#   # TMT_TEST_DATA=$PWD/logs DBUS_BROKER_TREE=$PWD test/integration/fuzz/valgrind/test.sh
#
if [[ -n "${DBUS_BROKER_TREE:-}" ]]; then
    pushd "$DBUS_BROKER_TREE"
    meson setup build-valgrind --wipe --prefix=/usr
    DESTDIR="$CONTAINER_OVERLAY" ninja -C build-valgrind install
    rm -rf build-valgrind
    popd
fi

# TODO: Use --exit-on-first-error=yes? Without it either dbus-broker or Valgrind doesn't propagate exit code
#       (set via --error-exitcode=) from the child back to the parent process, so even if dbus-broker itself
#       exits with 66 due to Valgrind errors, the parent process (dbus-broker-launch) still returns 0.
VALGRIND_CMD=(
    valgrind
    --tool=memcheck
    --leak-check=full
    --track-origins=yes
    --trace-children=yes
    --track-fds=yes
    --error-exitcode=66
)
# Verify the Valgrind cmdline (and Valgrind itself)
"${VALGRIND_CMD[@]}" true
# Override the dbus-broker service so it starts dbus-broker under Valgrind
mkdir -p "$CONTAINER_OVERLAY/etc/systemd/system/dbus-broker.service.d/"
cat >"$CONTAINER_OVERLAY/etc/systemd/system/dbus-broker.service.d/valgrind.conf" <<EOF
[Service]
Environment=DEBUGINFOD_URLS="${DEBUGINFOD_URLS:-}"
ExecStart=
ExecStart=${VALGRIND_CMD[*]} /usr/bin/dbus-broker-launch --scope system --audit
EOF
if grep -qE "^ID=arch$" /etc/os-release; then
    # As mentioned in the comment above, debuginfod is required on Arch for Valgrind to work properly, so we
    # need working network when starting dbus-broker. However, this doesn't work with NetworkManager, since it
    # has a dependency on dbus, which means we get a circular dependency. This is not an issue on Arch, which
    # uses systemd-networkd by default, but might be an issue on distros that use NM by default (like Fedora),
    # so let's limit the scope of this part of the workaround to just Arch (at least for now).
    cat >"$CONTAINER_OVERLAY/etc/systemd/system/dbus-broker.service.d/debuginfod.conf" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF
fi
# Do the same for the user unit
mkdir -p "$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/"
cat >"$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/valgrind.conf" <<EOF
[Service]
Environment=DEBUGINFOD_URLS="${DEBUGINFOD_URLS:-}"
ExecStart=
ExecStart=${VALGRIND_CMD[*]} /usr/bin/dbus-broker-launch --scope user
EOF
# We need to run the system dbus-broker under root (i.e. without dropping privileges to the dbus user), since
# that breaks intercepting syscalls (and other stuff).
mkdir -p "$CONTAINER_OVERLAY/etc/dbus-1/"
cat >"$CONTAINER_OVERLAY/etc/dbus-1/system-local.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
    <user>root</user>
</busconfig>
EOF

run_and_check() {
    local run=(container_run)
    local unpriv=0

    if [[ "$1" == "--unpriv" ]]; then
        run=(container_run_user testuser)
        unpriv=1
        shift
    fi

    # Run the passed command in the container
    "${run[@]}" "$@"
    # Check if dbus-broker is still running...
    "${run[@]}" systemctl status --full --no-pager dbus-broker.service
    if [[ $unpriv -ne 0 ]]; then
        # (check the user instance too, if applicable)
        "${run[@]}" systemctl status --user --full --no-pager dbus-broker.service
    fi
}

# Start the container and wait until it's fully booted up
container_start
# Make sure we're running dbus-broker under Valgrind
container_run bash -xec '[[ $(readlink -f /proc/$(systemctl show -P MainPID dbus-broker.service)/exe) =~ valgrind ]]'
container_run_user testuser bash -xec '[[ $(readlink -f /proc/$(systemctl show --user -P MainPID dbus-broker.service)/exe) =~ valgrind ]]'
journalctl -D "/var/log/journal/${CONTAINER_MACHINE_ID:?}" -e -n 10 --no-pager

# Now we should have a container ready for our shenanigans

# Let's start with something simple and run dfuzzer on the org.freedesktop.DBus bus
run_and_check dfuzzer -v -n org.freedesktop.DBus
# TODO: fuzz systemd too (as we do in the sanitizers test)

# Shut down the container and check for any errors, since some of the errors can be detected only after we
# start shutting things down.
container_stop
# Check if dbus-broker didn't fail during the lifetime of the container
(! journalctl -q -D "/var/log/journal/$CONTAINER_MACHINE_ID" _PID=1 --grep "dbus-broker.service.*Failed with result")
# Check error count in Valgrind messages
while read -r line; do
    # TODO: potentially replace this with something less horrifying
    if ! [[ "$line" =~ \==\ ERROR\ SUMMARY:\ 0\ errors ]]; then
        journalctl -q -D "/var/log/journal/$CONTAINER_MACHINE_ID" -o short-monotonic --no-hostname -u dbus-broker --no-pager
        exit 1
    fi
done < <(journalctl -q -D "/var/log/journal/$CONTAINER_MACHINE_ID" -o short-monotonic --no-hostname --grep "== ERROR SUMMARY:")

exit 0
