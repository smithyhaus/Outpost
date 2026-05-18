# =============================================================================
# Outpost / Makefile
# -----------------------------------------------------------------------------
# Tiny shim for the `outpost` CLI install/uninstall flow. Most of Outpost is
# driven by `bash bootstrap.sh` / `bash scripts/outpost <cmd>`; this Makefile
# just removes the manual `ln -s` step in the README.
#
# Variables (overridable from the command line):
#   PREFIX   install location for the `outpost` symlink (default /usr/local/bin)
#   DESTDIR  optional stage root for packagers (default empty)
#
# Examples:
#   make install                       # ln -s $PWD/scripts/outpost → /usr/local/bin/outpost
#   make install PREFIX=$HOME/.local/bin
#   sudo make install                  # if /usr/local/bin needs sudo on your system
#   make uninstall
#
# All targets are .PHONY. Bats coverage in tests/bats/makefile.bats.
# =============================================================================

PREFIX     ?= /usr/local/bin
DESTDIR    ?=
SCRIPT     := $(abspath scripts/outpost)
INSTALL_AT := $(DESTDIR)$(PREFIX)/outpost

.PHONY: help install uninstall version

help: ## Show this help and exit.
	@echo "Outpost CLI install targets:"
	@echo ""
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / { printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
	@echo "  PREFIX   = $(PREFIX)"
	@echo "  DESTDIR  = $(DESTDIR)"
	@echo "  SCRIPT   = $(SCRIPT)"

install: ## Symlink scripts/outpost into PREFIX (default /usr/local/bin).
	@set -e; \
	if [ ! -x "$(SCRIPT)" ]; then \
	  echo "ERROR: $(SCRIPT) not executable — run from the outpost repo root" >&2; \
	  exit 1; \
	fi; \
	mkdir -p "$(dir $(INSTALL_AT))"; \
	if [ -L "$(INSTALL_AT)" ]; then \
	  cur=$$(readlink "$(INSTALL_AT)"); \
	  if [ "$$cur" = "$(SCRIPT)" ]; then \
	    echo "✓ $(INSTALL_AT) already points to $(SCRIPT) (no-op)"; \
	    exit 0; \
	  else \
	    echo "WARN: $(INSTALL_AT) points to $$cur — replacing with $(SCRIPT)"; \
	    rm -f "$(INSTALL_AT)"; \
	  fi; \
	elif [ -e "$(INSTALL_AT)" ]; then \
	  echo "ERROR: $(INSTALL_AT) exists and is not a symlink — refusing to clobber" >&2; \
	  echo "       Remove it manually or set PREFIX to a different dir." >&2; \
	  exit 1; \
	fi; \
	ln -s "$(SCRIPT)" "$(INSTALL_AT)"; \
	echo "✓ installed: $(INSTALL_AT) -> $(SCRIPT)"; \
	case ":$$PATH:" in \
	  *":$(PREFIX):"*) : ;; \
	  *) echo "" >&2; \
	     echo "NOTE: $(PREFIX) is not on your PATH. Add it to your shell rc:" >&2; \
	     echo "      export PATH=\"$(PREFIX):\$$PATH\"" >&2 ;; \
	esac; \
	echo ""; \
	echo "Try: outpost version"

uninstall: ## Remove the outpost symlink installed by `make install` (only if it points at this repo).
	@set -e; \
	if [ ! -L "$(INSTALL_AT)" ]; then \
	  echo "✓ $(INSTALL_AT) is not a symlink — nothing to do"; \
	  exit 0; \
	fi; \
	cur=$$(readlink "$(INSTALL_AT)"); \
	if [ "$$cur" = "$(SCRIPT)" ]; then \
	  rm -f "$(INSTALL_AT)"; \
	  echo "✓ removed $(INSTALL_AT)"; \
	else \
	  echo "ERROR: $(INSTALL_AT) points to $$cur (not $(SCRIPT)) — refusing to remove" >&2; \
	  echo "       Remove it manually if you really want to." >&2; \
	  exit 1; \
	fi

version: ## Print outpost CLI version (reads VERSION + git SHA).
	@bash "$(SCRIPT)" version
