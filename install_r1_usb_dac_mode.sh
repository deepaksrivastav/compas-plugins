#!/bin/sh
# Copyright (C) 2026 Deepak Srivastav
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu

usage() {
    echo "Usage: $0 OUTPUT_DIRECTORY" >&2
    echo "Example: $0 /run/media/$USER/COMPAS_SD" >&2
    exit 2
}

[ "$#" -eq 1 ] && [ -n "$1" ] || usage

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
OUTPUT_DIR=$1
PLUGIN_DIR=$OUTPUT_DIR/.plugins

mkdir -p "$PLUGIN_DIR"
cp "$SCRIPT_DIR/plugins/R1UsbDacMode/R1UsbDacMode.lua" "$PLUGIN_DIR/R1UsbDacMode.lua"

echo "R1 USB DAC Mode installed. Refresh plugins or restart the player."
