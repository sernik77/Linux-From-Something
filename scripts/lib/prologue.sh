#!/usr/bin/env bash
# Sourced at the top of every stage: rebuilds the environment (including the
# arrays the driver cannot export) and pulls in the helper library.
set -euo pipefail
: "${LFN_PROJ:?stages must be run through ./lfn}"
: "${LFN_WORK:?stages must be run through ./lfn}"
# shellcheck source=../../lfn.conf
source "$LFN_PROJ/lfn.conf"
# shellcheck source=common.sh
source "$LFN_PROJ/scripts/lib/common.sh"
