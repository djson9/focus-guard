PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
BUILD_FLAGS = -framework Cocoa -framework Carbon

.PHONY: build install uninstall run clean

build: FocusGuard

FocusGuard: FocusGuard.swift
	swiftc -o FocusGuard FocusGuard.swift $(BUILD_FLAGS)

install: build
	mkdir -p $(INSTALL_DIR)
	cp FocusGuard $(INSTALL_DIR)/FocusGuard
	@echo "Installed to $(INSTALL_DIR)/FocusGuard"

uninstall:
	rm -f $(INSTALL_DIR)/FocusGuard

run: build
	@pkill -x FocusGuard 2>/dev/null; sleep 0.3; rm -f /tmp/focus-guard.pid
	./FocusGuard &

clean:
	rm -f FocusGuard
