#!/bin/bash
# vi: set sw=4 ts=4 et tw=110:
# shellcheck disable=SC2016

set -eux
set -o pipefail

# shellcheck source=test/integration/util.sh
. "$(dirname "$0")/../../util.sh"

export ASAN_OPTIONS=strict_string_checks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1:detect_invalid_pointer_pairs=2:handle_ioctl=1:print_cmdline=1:disable_coredump=0:use_madv_dontdump=1
export UBSAN_OPTIONS=print_stacktrace=1:print_summary=1:halt_on_error=1

# shellcheck disable=SC2317
at_exit() {
    set +ex

    # Let's do some cleanup and export logs if necessary

    # Collect potential coredumps
    coredumpctl_collect
    container_destroy
}

trap at_exit EXIT

export BUILD_DIR="$PWD/build-san"

# Make sure the coredump collecting machinery is working
coredumpctl_init

: "=== Prepare dbus-broker's source tree ==="
prepare_source_tree

: "=== Build dbus-broker with sanitizers and run the unit test suite ==="
meson setup "$BUILD_DIR" --wipe -Db_sanitize=address,undefined -Dprefix=/usr
ninja -C "$BUILD_DIR"
meson test -C "$BUILD_DIR" --timeout-multiplier=2 --print-errorlogs

: "=== Run tests against dbus-broker running under sanitizers ==="
# So, this one is a _bit_ convoluted. We want to run dbus-broker under sanitizers, but this bears a couple of
# issues:
#
#   1) We need to restart dbus-broker (and hence the machine we're currently running on)
#   2) If dbus-broker crashes due to ASan/UBSan error, the whole machine is hosed
#
# To make the test a bit more robust without too much effort, let's use systemd-nspawn to run an ephemeral
# container on top of the current rootfs. To get the "sanitized" dbus-broker into that container, we need to
# prepare a special rootfs with just the sanitized dbus-broker (and a couple of other things) which we then
# simply overlay on top of the ephemeral rootfs in the container.
#
# This way, we'll do a full user-space boot with a sanitized dbus-broker without affecting the host machine,
# and without having to build a custom container/VM just for the test.
container_prepare

# Install our custom-built dbus-broker into the container's overlay
DESTDIR="$CONTAINER_OVERLAY" ninja -C "$BUILD_DIR" install
# Pass $ASAN_OPTIONS and $UBSAN_OPTIONS to the dbus-broker service in the container
mkdir -p "$CONTAINER_OVERLAY/etc/systemd/system/dbus-broker.service.d/"
cat >"$CONTAINER_OVERLAY/etc/systemd/system/dbus-broker.service.d/sanitizer-env.conf" <<EOF
[Service]
Environment=ASAN_OPTIONS=$ASAN_OPTIONS
Environment=UBSAN_OPTIONS=$UBSAN_OPTIONS
# Useful for debugging LSan errors, but it's very verbose, hence disabled by default
#Environment=LSAN_OPTIONS=verbosity=1:log_threads=1
EOF
# Do the same for the user unit
mkdir -p "$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/"
cat >"$CONTAINER_OVERLAY/etc/systemd/user/dbus-broker.service.d/sanitizer-env.conf" <<EOF
[Service]
Environment=ASAN_OPTIONS=$ASAN_OPTIONS
Environment=UBSAN_OPTIONS=$UBSAN_OPTIONS
# Useful for debugging LSan errors, but it's very verbose, hence disabled by default
#Environment=LSAN_OPTIONS=verbosity=1:log_threads=1
EOF
# Run both dbus-broker-launch and dbus-broker under root instead of the usual "dbus" user. This is necessary
# to let sanitizers generate stack traces (killing the process on sanitizer error works even without this
# tweak though, but it's very hard to then tell what went wrong without a stack trace).
mkdir -p "$CONTAINER_OVERLAY/etc/dbus-1/"
cat >"$CONTAINER_OVERLAY/etc/dbus-1/system-local.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
    <user>root</user>
</busconfig>
EOF

check_journal_for_sanitizer_errors() {
    if journalctl -q -D "/var/log/journal/${CONTAINER_MACHINE_ID:?}" --grep "SUMMARY:.+Sanitizer"; then
        # Dump all messages recorded for the dbus-broker.service, as that's usually where the stack trace ends
        # up. If that's not the case, the full container journal is exported on test exit anyway, so we'll
        # still have everything we need to debug the fail further.
        journalctl -q -D "/var/log/journal/${CONTAINER_MACHINE_ID:?}" -o short-monotonic --no-hostname -u dbus-broker.service --no-pager
        exit 1
    fi
}

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
    # ... and if it didn't generate any sanitizer errors
    check_journal_for_sanitizer_errors
}

# Start the container and wait until it's fully booted up
container_start
# Check if dbus-broker runs under root, see above for reasoning
container_run bash -xec '[[ $(stat --format=%u /proc/$(systemctl show -P MainPID dbus-broker.service)) -eq 0 ]]'
# Make _extra_ sure we're running the sanitized dbus-broker with the correct environment
container_run bash -xec 'ldd /proc/$(systemctl show -P MainPID dbus-broker.service)/exe | grep -qF libasan.so'
container_run bash -xec 'ldd $(command -v dbus-broker-launch) | grep -qF libasan.so'
container_run bash -xec 'ldd $(command -v dbus-broker) | grep -qF libasan.so'
container_run systemctl show -p Environment dbus-broker.service | grep -q ASAN_OPTIONS
# Do a couple of check for the user instance as well
container_run_user testuser bash -xec 'ldd /proc/$(systemctl show --user -P MainPID dbus-broker.service)/exe | grep -qF libasan.so'
container_run_user testuser systemctl show -p Environment dbus-broker.service | grep -q ASAN_OPTIONS
journalctl -D "/var/log/journal/${CONTAINER_MACHINE_ID:?}" -e -n 10 --no-pager
check_journal_for_sanitizer_errors

# Now we should have a container ready for our shenanigans

# Let's start with something simple and run dfuzzer on the org.freedesktop.DBus bus
run_and_check dfuzzer -v -n org.freedesktop.DBus
# Now run the dfuzzer on the org.freedesktop.systemd1 as well, since it's pretty rich when it comes to
# signature variations.
#
# Since fuzzing the entire systemd bus tree takes way too long (as it spends most of the time fuzzing the
# /org/freedesktop/systemd1/unit/ objects, which is the same stuff over and over again), let's selectively
# pick a couple of interesting objects to speed things up.
#
# First, fuzz the manager object...
run_and_check --unpriv dfuzzer -n org.freedesktop.systemd1 -o /org/freedesktop/systemd1
# ... and then pick first 10 units from the /org/freedesktop/systemd1/unit/ tree.
while read -r object; do
    run_and_check --unpriv dfuzzer -n org.freedesktop.systemd1 -o "$object"
done < <(busctl tree --list --no-legend org.freedesktop.systemd1 | grep /unit/ | head -n10)

# Shut down the container and check for any sanitizer errors, since some of the errors can be detected only
# after we start shutting things down.
#
# Note: machinectl poweroff doesn't wait until the container shuts down completely, stop stop the service
#       behind it instead which does wait
systemctl stop "systemd-nspawn@$CONTAINER_NAME.service"
check_journal_for_sanitizer_errors
# Also, check if dbus-broker didn't fail during the lifetime of the container
(! journalctl -q -D "/var/log/journal/$CONTAINER_MACHINE_ID" _PID=1 --grep "dbus-broker.service.*Failed with result")

exit 0
