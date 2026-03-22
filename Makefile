PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
BUILD_FLAGS = -framework Cocoa -framework Carbon

.PHONY: build install uninstall run clean setup

build: FocusGuard

FocusGuard: FocusGuard.swift
	swiftc -o FocusGuard FocusGuard.swift $(BUILD_FLAGS)

install: build
	mkdir -p $(INSTALL_DIR)
	cp FocusGuard $(INSTALL_DIR)/FocusGuard
	@echo ""
	@echo "Installed to $(INSTALL_DIR)/FocusGuard"
	@echo ""
	@echo "Quick setup — add to your shell profile (~/.zshrc):"
	@echo '  export PATH="$(INSTALL_DIR):$$PATH"'
	@echo '  focus-guard() { $(INSTALL_DIR)/FocusGuard "$$@"; }'
	@echo ""
	@echo "Then: focus-guard          # start daemon"
	@echo "      focus-guard --help   # see all commands"

uninstall:
	rm -f $(INSTALL_DIR)/FocusGuard
	@echo "Removed from $(INSTALL_DIR)"

run: build
	@pkill -x FocusGuard 2>/dev/null; sleep 0.3; rm -f /tmp/focus-guard.pid
	./FocusGuard &

clean:
	rm -f FocusGuard

setup: install
	@echo ""
	@echo "Granting Accessibility permission (you may see a system prompt)..."
	@echo "If FocusGuard doesn't work, go to:"
	@echo "  System Settings > Privacy & Security > Accessibility"
	@echo "  and add FocusGuard."
