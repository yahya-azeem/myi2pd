.PHONY: test test-quick test-iso shellcheck pre-commit

# Fast, bootless tests: validate config syntax, overlay integrity, and
# GHA parity without building an ISO or booting a VM. Run this on every change.
test:
	./tests/run_tests.sh

# Same as `make test` but never validates the (possibly stale) ISO artifact.
test-quick:
	./tests/run_tests.sh --no-iso

# Validate a freshly built ISO's apkovl without booting it.
test-iso:
	./tests/run_tests.sh -i $(ISO)

# Install the repo pre-commit hook that runs the fast suite automatically.
pre-commit:
	mkdir -p .githooks
	cp scripts/pre-commit.sh .githooks/pre-commit
	chmod +x .githooks/pre-commit
	git config core.hooksPath .githooks
	@echo "pre-commit hook installed (core.hooksPath=.githooks)"
