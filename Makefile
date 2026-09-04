.PHONY: lint metadata audit test test-options test-install-head test-install-head-moonshot test-install-stable update update-pr clean help

FORMULA := streamline.rb
MODE ?= pre-artifact

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

lint: ## Validate formula syntax
	ruby -c $(FORMULA)

metadata: ## Check stable release metadata (MODE=pre-artifact|release)
	./scripts/check-formula-metadata.sh --mode $(MODE)

audit: lint ## brew style + offline brew audit via an ephemeral tap (MODE=pre-artifact|release)
	./scripts/validate-formula.sh --mode $(MODE)

test: lint test-options ## Run hermetic formula updater tests (no network, no install)
	./scripts/test-update-formula.sh

test-options: ## Source-level HEAD build option contract tests (no brew, no network)
	ruby scripts/test-formula-options.rb $(FORMULA)

# Both install targets go through the ephemeral tap in validate-formula.sh, so
# Homebrew resolves the formula exactly as a user would. While the formula
# carries its fail-closed `disable!` stanza, ALL of these targets are expected
# to fail: that is the point of the blocker, and it is not worked around here.
# They document the real post-artifact commands, including the tap's public
# `--with-moonshot` source-build option.
test-install-head: ## Build-from-source install + test (blocked while the formula is disabled)
	./scripts/validate-formula.sh --mode $(MODE) --install-head

test-install-head-moonshot: ## HEAD install + test with --with-moonshot (blocked while disabled)
	./scripts/validate-formula.sh --mode $(MODE) --install-head --with-moonshot

test-install-stable: ## Stable install + test; requires published release artifacts
	./scripts/validate-formula.sh --mode release --install-stable

update: ## Regenerate the stable stanza (usage: make update VERSION=0.3.0)
	@test -n "$(VERSION)" || (echo "Usage: make update VERSION=x.y.z" && exit 1)
	./scripts/update-formula.sh $(VERSION)

update-pr: ## Regenerate the stable stanza and open a PR (usage: make update-pr VERSION=0.3.0)
	@test -n "$(VERSION)" || (echo "Usage: make update-pr VERSION=x.y.z" && exit 1)
	./scripts/update-formula.sh $(VERSION) --create-pr

clean: ## Remove build leftovers
	@rm -f $(FORMULA).bak .$(FORMULA).staged.*
	@echo "Cleaned up."
