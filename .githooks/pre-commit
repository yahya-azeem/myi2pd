#!/bin/bash
# .githooks/pre-commit - run the fast bootless test suite before committing.
#
# Installed via: make pre-commit   (or: git config core.hooksPath .githooks)
# The suite is ~2s and never boots a VM or builds an ISO, so it is safe to
# run on every commit. A failing commit usually means you must also fix the
# GHA build (build.yml), since the parity tests compare CI against the local
# build_iso.sh pipeline.
set -u

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "==> pre-commit: running myi2pd static test suite"
if ! "$REPO_ROOT/tests/run_tests.sh" --no-iso; then
    echo "==> pre-commit: FAILED (see above). Fix before committing."
    exit 1
fi
echo "==> pre-commit: OK"
