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

: "=== Run tests against dbus-broker running under Valgrind ==="
# Run the Valgrind-fied dbus-broker in a ligthweight container, so we don't risk damage to the underlying test
# machine (see fuzz/sanitizers/test.sh for more detailed reasoning).
#
# Some Valgrind-specific notes:
#   - Valgrind on Arch _requires_ working debuginfod servers, since it doesn't ship debuginfod packages, so
#     the container needs to be booted up with --network-veth
#   - also, for the debuginfod stuff to work correctly, the respective .cache directories in user homes need
#     to be writable
container_prepare

# XXX: --trace-childen?
VALGRIND_CMD=(valgrind --leak-check=full --track-fds=yes --error-exitcode=77 --exit-on-first-error=yes)
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
# Do the same for the user unit
mkdir -p "$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/"
cat >"$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/valgrind.conf" <<EOF
[Service]
Environment=DEBUGINFOD_URLS="${DEBUGINFOD_URLS:-}"
ExecStart=
ExecStart=${VALGRIND_CMD[*]} /usr/bin/dbus-broker-launch --scope user
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
# Now run the dfuzzer on the org.freedesktop.systemd1 as well, since it's pretty rich when it comes to
# signature variations
#run_and_check --unpriv dfuzzer -n org.freedesktop.systemd1

# Shut down the container and check for any sanitizer errors, since some of the errors can be detected only
# after we start shutting things down.
#
# Note: machinectl poweroff doesn't wait until the container shuts down completely, stop stop the service
#       behind it instead which does wait
systemctl stop "systemd-nspawn@$CONTAINER_NAME.service"
# Also, check if dbus-broker didn't fail during the lifetime of the container
(! journalctl -q -D "/var/log/journal/$CONTAINER_MACHINE_ID" _PID=1 --grep "dbus-broker.service.*Failed with result")

exit 0
