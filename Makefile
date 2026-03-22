PREFIX ?= /usr/local
INSTALL_DIR = $(PREFIX)/bin
PLIST = com.focusguard.app.plist
LAUNCH_DIR = $(HOME)/Library/LaunchAgents
BUILD_FLAGS = -framework Cocoa -framework Carbon

.PHONY: build install uninstall run clean setup start stop

build: FocusGuard

FocusGuard: FocusGuard.swift
	swiftc -o FocusGuard FocusGuard.swift $(BUILD_FLAGS)

install: build
	mkdir -p $(INSTALL_DIR)
	cp FocusGuard $(INSTALL_DIR)/FocusGuard

run: build
	@pkill -x FocusGuard 2>/dev/null; sleep 0.3; rm -f /tmp/focus-guard.pid
	./FocusGuard &

setup: install
	@mkdir -p $(LAUNCH_DIR)
	@cp $(PLIST) $(LAUNCH_DIR)/$(PLIST)
	@launchctl bootout gui/$$(id -u) $(LAUNCH_DIR)/$(PLIST) 2>/dev/null || true
	@launchctl bootstrap gui/$$(id -u) $(LAUNCH_DIR)/$(PLIST)
	@echo ""
	@echo "  FocusGuard installed and running."
	@echo ""
	@echo "  It will auto-start on login."
	@echo "  Use: FocusGuard --help   for commands."
	@echo ""
	@echo "  If focus pinning doesn't work, grant Accessibility permission:"
	@echo "    System Settings > Privacy & Security > Accessibility > add FocusGuard"
	@echo ""

start:
	@launchctl kickstart -k gui/$$(id -u)/com.focusguard.app 2>/dev/null || $(INSTALL_DIR)/FocusGuard &

stop:
	@$(INSTALL_DIR)/FocusGuard --stop 2>/dev/null; pkill -x FocusGuard 2>/dev/null || true

uninstall: stop
	@launchctl bootout gui/$$(id -u) $(LAUNCH_DIR)/$(PLIST) 2>/dev/null || true
	@rm -f $(LAUNCH_DIR)/$(PLIST)
	@rm -f $(INSTALL_DIR)/FocusGuard
	@rm -f /tmp/focus-guard.pid
	@echo "FocusGuard uninstalled."

clean:
	rm -f FocusGuard
