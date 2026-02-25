#!/bin/bash
#
# Compile DylibLoaderNew with LiveContainer headers visible,
# so we can call LCUtils / LCSharedUtils / checkCodeSignature at runtime.
#
# The dylib is loaded INTO a LiveContainer process, so all LC symbols
# are already present — we just need -undefined dynamic_lookup to let
# the linker defer resolution.
#

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" &> /dev/null && pwd -P)
REPO_ROOT="${SCRIPT_DIR}/.."

set -e

export CLANG_EXTRA_INCLUDES="$REPO_ROOT/lib/LiveContainer/LiveContainer $REPO_ROOT/lib/LiveContainer/LiveContainerSwiftUI $REPO_ROOT/lib/LiveContainer/ZSign"
export CLANG_EXTRA_FRAMEWORKS="Security"

# -undefined dynamic_lookup: LC classes + C functions (checkCodeSignature,
#   LCPatchAppBundleFixupARM64eSlice, …) live in the host process;
#   resolve them at load time rather than link time.
EXTRA_FLAGS="-undefined dynamic_lookup -fobjc-arc"

"$REPO_ROOT/scripts/compile.sh" tweaks/DylibLoaderNew $EXTRA_FLAGS "$@"
