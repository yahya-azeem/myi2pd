#!/bin/bash
# tests/run_tests.sh - myi2pd static test suite runner.
#
# Runs fast, bootless tests against the source tree / configs / built ISO so you
# can verify changes without a VM test drive. Returns non-zero on any failure.
#
# Usage:
#   tests/run_tests.sh                 # run all tests (no ISO = skips iso test)
#   tests/run_tests.sh -v              # verbose per-test output
#   tests/run_tests.sh -i <iso>        # also validate a built ISO artifact
#   tests/run_tests.sh --no-iso        # never run the iso test, even if ISOs exist
#   tests/run_tests.sh --only overlay  # run one test file by name
#
# Suggested in CI / pre-commit:
#   tests/run_tests.sh

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." &>/dev/null && pwd)"
ISO_ARG=""
ONLY=""
VERBOSE=0
NO_ISO=0

while [ $# -gt 0 ]; do
    case "$1" in
        -v|--verbose) VERBOSE=1 ;;
        -i|--iso) shift; ISO_ARG="${1:-}" ;;
        --no-iso) NO_ISO=1 ;;
        --only) shift; ONLY="${1:-}" ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

export VERBOSE

run_test() {
    local file="$1"
    if [ -n "$ONLY" ] && [[ "$(basename "$file")" != *"$ONLY"* ]]; then
        return 0
    fi
    if [ -f "$file" ]; then
        echo ">>> Running: $(basename "$file")"
        if bash "$file" "$ISO_ARG"; then
            echo "    [ok] $(basename "$file")"
        else
            echo "    [FAILED] $(basename "$file")"
            TEST_FAILED=1
        fi
        echo ""
    fi
}

cd "$SCRIPT_DIR"
TEST_FAILED=0

# Ensure test files are executable
chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null

run_test "$SCRIPT_DIR/test_overlay.sh"
run_test "$SCRIPT_DIR/test_gha_parity.sh"
run_test "$SCRIPT_DIR/test_configs.sh"

if [ "$NO_ISO" -eq 1 ]; then
    : # iso test explicitly skipped
elif [ -n "$ISO_ARG" ]; then
    run_test "$SCRIPT_DIR/test_iso.sh"
elif [ -f "$REPO_ROOT/myi2pd-amnesiac.iso" ] || [ -f "$REPO_ROOT/myi2pd-vps.iso" ]; then
    echo ">>> Found ISO(s) in repo root, running ISO smoke test."
    run_test "$SCRIPT_DIR/test_iso.sh"
fi

# clean up temp overlay dirs the tests created
rm -rf "$SCRIPT_DIR/.tmp-overlay-client" "$SCRIPT_DIR/.tmp-overlay-vps" \
       "$SCRIPT_DIR/.tmp-iso"

if [ "$TEST_FAILED" -ne 0 ]; then
    echo "RUNNER: one or more test files FAILED"
    exit 1
fi

echo "RUNNER: all test files completed successfully"
exit 0
