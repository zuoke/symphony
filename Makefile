.PHONY: help setup deps build fmt fmt-check lint test coverage dialyzer e2e ci all demo

ELIXIR_DIR := elixir

help:
	@echo "Targets: setup, deps, build, fmt, fmt-check, lint, test, coverage, dialyzer, e2e, ci, all, demo"

setup deps build fmt fmt-check lint test coverage dialyzer e2e ci all demo:
	$(MAKE) -C $(ELIXIR_DIR) $@
