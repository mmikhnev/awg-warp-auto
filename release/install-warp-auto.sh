#!/bin/sh
# Complete blank-router installation. It installs the base stack without
# creating an interface, then adds the WARP Auto LuCI overlay.
set -eu

BASE_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
sh "$BASE_DIR/install-base.sh"
exec sh "$BASE_DIR/install-overlay.sh"
