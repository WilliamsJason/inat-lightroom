#!/bin/sh
#
# install_update.sh
# -----------------
# The macOS half of install_update.ps1: verify a downloaded plugin archive and
# unpack it into the staging folder. Same arguments, same exit codes, so
# UpdateInstall.lua only has to choose a command line, not a workflow.
#
#   install_update.sh <archive> <expected-sha256> <destination>
#
# Nothing here touches the installed plugin; it only writes inside the
# destination, which UpdateInstall.lua applies as Lightroom shuts down.
#
# Exit codes:
#   0  verified and unpacked
#   1  the archive is missing or unreadable
#   2  the archive does not match the expected hash
#   3  unpacking failed
#   4  what came out of the archive is not a Lightroom plugin

set -eu

archive=${1:-}
expected=${2:-}
destination=${3:-}

if [ -z "$archive" ] || [ -z "$expected" ] || [ -z "$destination" ]; then
    echo "usage: install_update.sh <archive> <expected-sha256> <destination>" >&2
    exit 1
fi

[ -f "$archive" ] || { echo "Archive not found: $archive" >&2; exit 1; }

# shasum ships with macOS; sha256sum does not, but may exist from Homebrew.
if command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$archive" | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | awk '{print $1}')
else
    echo "No SHA-256 tool available" >&2
    exit 1
fi

# Lower-case both sides: shasum prints lower, Get-FileHash prints upper, and the
# digest travels through the same Lua on both platforms.
lower_expected=$(printf '%s' "$expected" | tr 'A-Z' 'a-z')
lower_actual=$(printf '%s' "$actual" | tr 'A-Z' 'a-z')

if [ "$lower_actual" != "$lower_expected" ]; then
    echo "Hash mismatch: expected $lower_expected, got $lower_actual" >&2
    exit 2
fi

# Anything left from an interrupted attempt would otherwise merge with this one.
rm -rf "$destination" || { echo "Could not clear staging folder" >&2; exit 3; }
mkdir -p "$destination" || { echo "Could not create staging folder" >&2; exit 3; }

# ditto is the macOS-native unarchiver and preserves resource forks; unzip is the
# fallback for the case where it is not on PATH.
if command -v ditto >/dev/null 2>&1; then
    ditto -x -k "$archive" "$destination" || { echo "Could not unpack" >&2; exit 3; }
elif command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$archive" -d "$destination" || { echo "Could not unpack" >&2; exit 3; }
else
    echo "No unarchiver available" >&2
    exit 3
fi

# The archive is built with one <name>.lrplugin folder at its root. The name is
# discovered rather than hardcoded: this script is the installed copy, one
# release older than the archive it is checking, so a literal name here is a
# name no later release could change without this rejecting it.
count=0
for candidate in "$destination"/*.lrplugin; do
    [ -f "$candidate/Info.lua" ] && count=$((count + 1))
done

if [ "$count" -ne 1 ]; then
    rm -rf "$destination"
    echo "Unpacked archive has $count *.lrplugin folders containing Info.lua; expected one" >&2
    exit 4
fi

exit 0
