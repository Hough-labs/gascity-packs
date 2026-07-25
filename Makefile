# ── Fork integration baseline ────────────────────────────────────────────────
# The `integration` branch carries fork-local patches on top of a pinned
# upstream gascity-packs commit. BASELINE is the exact commit those patches
# replay onto, so a fork build of the pack set is reproducible. To move to a
# newer upstream commit, bump BASELINE (here and in the standalone default in
# scripts/upgrade-integration.sh), then run `make upgrade`.
# Full workflow: docs/fork-patches.md
BASELINE ?= f69ec02b39e04b1febc3ced4c47fd4972f706e91

# git does not honour in-repo hooks on clone, so the pre-push staleness guard
# below would sit inert in a fresh checkout until somebody remembered a setup
# step — and the one thing it guards (a stale patches/ export) is exactly what
# a newcomer to the fork is most likely to push. Arm it at parse time instead:
# any make invocation in this repo makes the guard real. Idempotent and
# local-only, and it never overrides a core.hooksPath already set by the user
# or a global hooks manager — run `make hooks` to force it in that case.
_ARM_HOOKS := $(shell cur=$$(git config --get core.hooksPath 2>/dev/null || true); \
	if [ -z "$$cur" ]; then git config core.hooksPath .githooks 2>/dev/null; fi)

GC ?= gc
PYTHON ?= python3
REGISTRY ?= registry.toml
REGISTRY_REF ?= main
REGISTRY_COMMIT ?= HEAD
REGISTRY_SOURCE_BASE ?= https://github.com/gastownhall/gascity-packs/tree/main

PACK_PATH ?= $(PACK)
SOURCE ?= .
CATALOG_SOURCE ?= $(REGISTRY_SOURCE_BASE)/$(PACK_PATH)

STAMP_PACK_DESCRIPTION :=
ifneq ($(strip $(PACK_DESCRIPTION)),)
STAMP_PACK_DESCRIPTION := --pack-description "$(PACK_DESCRIPTION)"
endif

.PHONY: registry-help registry-format-validate registry-validate registry-validate-all registry-publish registry-withdraw

registry-help:
	@printf '%s\n' 'Registry targets:'
	@printf '%s\n' '  make registry-format-validate'
	@printf '%s\n' '  make registry-validate GC=/path/to/gc'
	@printf '%s\n' '  make registry-validate-all GC=/path/to/gc'
	@printf '%s\n' '  make registry-publish GC=/path/to/gc PACK=<name> VERSION=<semver> DESCRIPTION="..." [PACK_PATH=<path>] [PACK_DESCRIPTION="..."]'
	@printf '%s\n' '  make registry-withdraw PACK=<name> VERSION=<semver> REASON="..."'
	@printf '%s\n' ''
	@printf '%s\n' 'Fork patch targets (integration branch):'
	@printf '%s\n' '  make patches'
	@printf '%s\n' '  make check-patches'
	@printf '%s\n' '  make upgrade'
	@printf '%s\n' '  make hooks            (auto-armed by any make run)'

registry-format-validate:
	$(PYTHON) validate_registry.py $(REGISTRY)

registry-validate:
	$(GC) pack release validate $(REGISTRY)

registry-validate-all:
	$(GC) pack release validate $(REGISTRY) --include-withdrawn

registry-publish:
	@test -n "$(PACK)" || { echo "PACK is required"; exit 2; }
	@test -n "$(PACK_PATH)" || { echo "PACK_PATH is required"; exit 2; }
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@test -n "$(DESCRIPTION)" || { echo "DESCRIPTION is required"; exit 2; }
	$(GC) pack release stamp $(REGISTRY) "$(PACK)" \
		--version "$(VERSION)" \
		--ref "$(REGISTRY_REF)" \
		--commit "$(REGISTRY_COMMIT)" \
		--description "$(DESCRIPTION)" \
		--source "$(SOURCE)" \
		--path "$(PACK_PATH)" \
		$(STAMP_PACK_DESCRIPTION)
	$(PYTHON) scripts/registry_release.py set-source \
		--registry "$(REGISTRY)" \
		--pack "$(PACK)" \
		--source "$(CATALOG_SOURCE)"

registry-withdraw:
	@test -n "$(PACK)" || { echo "PACK is required"; exit 2; }
	@test -n "$(VERSION)" || { echo "VERSION is required"; exit 2; }
	@test -n "$(REASON)" || { echo "REASON is required"; exit 2; }
	$(PYTHON) scripts/registry_release.py withdraw \
		--registry "$(REGISTRY)" \
		--pack "$(PACK)" \
		--version "$(VERSION)" \
		--reason "$(REASON)"

# ── Fork patch management (integration branch) ───────────────────────────────
# patches/ is a DERIVED artifact: the `git format-patch BASELINE..HEAD` export
# of the fork's divergence, EXCLUDING patches/ itself (so it can't recursively
# include its own exports). Regenerate with `make patches` after adding or
# editing a fork commit. See docs/fork-patches.md.
.PHONY: patches upgrade check-patches hooks

hooks:
	@git config core.hooksPath .githooks
	@echo "core.hooksPath = $$(git config --get core.hooksPath)"

patches:
	@echo "Exporting patches from $(BASELINE) -> HEAD divergence..."
	@rm -f patches/*.patch
	@git format-patch --zero-commit $(BASELINE)..HEAD --output-directory patches/ -- . ':!patches/'
	@echo "Patches written to patches/:"
	@ls patches/*.patch 2>/dev/null | sed 's|patches/||' || echo "  (none)"

upgrade:
	@BASELINE=$(BASELINE) bash scripts/upgrade-integration.sh

check-patches:
	@tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; \
		git format-patch --zero-commit $(BASELINE)..HEAD --output-directory "$$tmp" -- . ':!patches/' >/dev/null 2>&1; \
		expected=$$(ls "$$tmp"/*.patch 2>/dev/null | wc -l | tr -d ' '); \
		actual=$$(ls patches/*.patch 2>/dev/null | wc -l | tr -d ' '); \
		if [ "$$expected" != "$$actual" ]; then \
			echo "patches/ is stale: $$actual present, $$expected expected."; \
			echo "  Run: make patches && git add patches && git commit"; \
			exit 1; \
		fi; \
		for f in "$$tmp"/*.patch; do \
			[ -e "$$f" ] || continue; \
			b=$$(basename "$$f"); \
			if [ ! -f "patches/$$b" ]; then \
				echo "patches/ is stale: missing $$b."; \
				echo "  Run: make patches && git add patches && git commit"; \
				exit 1; \
			fi; \
			tail -n +2 "patches/$$b" > "$$tmp/.committed"; \
			tail -n +2 "$$f"          > "$$tmp/.regen"; \
			if ! cmp -s "$$tmp/.committed" "$$tmp/.regen"; then \
				echo "patches/ is stale: content drift in $$b."; \
				echo "  Run: make patches && git add patches && git commit"; \
				exit 1; \
			fi; \
		done; \
		echo "patches/ up to date ($$actual patches)"
