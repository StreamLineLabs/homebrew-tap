.PHONY: lint audit test-install clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

lint: ## Validate formula syntax
	ruby -c streamline.rb

audit: lint ## Run Homebrew strict audit
	@echo "==> Setting up temporary tap..."
	@brew tap-new streamlinelabs/test --no-git 2>/dev/null || true
	@cp streamline.rb "$$(brew --repository streamlinelabs/test)/Formula/streamline.rb"
	brew audit --strict --formula streamlinelabs/test/streamline
	brew style streamlinelabs/test/streamline || true

test: lint ## Run formula validation (alias for lint)

test-install: audit ## Full install + test cycle
	brew install streamlinelabs/test/streamline
	brew test streamlinelabs/test/streamline
	@echo "==> All tests passed!"

update: ## Update formula for a new version (usage: make update VERSION=0.3.0)
	@test -n "$(VERSION)" || (echo "Usage: make update VERSION=x.y.z" && exit 1)
	./scripts/update-formula.sh $(VERSION)

update-pr: ## Update formula and create PR (usage: make update-pr VERSION=0.3.0)
	@test -n "$(VERSION)" || (echo "Usage: make update-pr VERSION=x.y.z" && exit 1)
	./scripts/update-formula.sh $(VERSION) --create-pr

clean: ## Remove temporary tap
	@brew untap streamlinelabs/test 2>/dev/null || true
	@echo "Cleaned up."
