.PHONY: build test clean image image-alpine image-arch install run ssh-setup ssh-unsetup help

# ── Build ────────────────────────────────────────────────────────────

build:
	zig build
	codesign --sign - --force --entitlements lcl.entitlements zig-out/bin/lcl

test:
	zig build test

clean:
	rm -rf zig-out .zig-cache

install: build
	cp zig-out/bin/lcl /usr/local/bin/lcl

## Launch lcl-app detached from this shell (no kernel-log spam).
run:
	open -a "$(PWD)/zig-out/bin/lcl-app"

# ── SSH agent setup ─────────────────────────────────────────────────

## Install a LaunchAgent that auto-loads Keychain-stored SSH keys at login.
## Per-key prerequisite: `ssh-add --apple-use-keychain ~/.ssh/<key>` once,
## so the passphrase is in Keychain. Then this loader picks it up at every
## login and keeps the host ssh-agent populated for guest forwarding.
ssh-setup:
	@mkdir -p ~/Library/LaunchAgents
	@cp scripts/dev.lcl.ssh-load.plist ~/Library/LaunchAgents/dev.lcl.ssh-load.plist
	@launchctl bootout "gui/$$(id -u)/dev.lcl.ssh-load" 2>/dev/null || true
	@launchctl bootstrap "gui/$$(id -u)" ~/Library/LaunchAgents/dev.lcl.ssh-load.plist
	@launchctl kickstart -k "gui/$$(id -u)/dev.lcl.ssh-load"
	@echo ""
	@echo "✓ LCL SSH key loader installed."
	@echo ""
	@echo "  Per key, add the passphrase to Keychain once:"
	@echo "    ssh-add --apple-use-keychain ~/.ssh/<your-key>"
	@echo ""
	@echo "  Logs: tail /tmp/lcl-ssh-load.log"

## Remove the LaunchAgent installed by ssh-setup.
ssh-unsetup:
	@launchctl bootout "gui/$$(id -u)/dev.lcl.ssh-load" 2>/dev/null || true
	@rm -f ~/Library/LaunchAgents/dev.lcl.ssh-load.plist
	@echo "✓ LCL SSH key loader removed."

# ── VM Images ────────────────────────────────────────────────────────

## Download Alpine aarch64 kernel + initrd for initial VM testing.
## No disk image needed — boots entirely from initrd.
image-alpine:
	python3 scripts/build-image.py alpine

## Build an Arch Linux ARM rootfs disk image.
## Requires: brew install e2fsprogs
image-arch:
	python3 scripts/build-image.py arch

## Default image target
image: image-alpine

# ── Help ─────────────────────────────────────────────────────────────

help:
	@echo "lcl build targets:"
	@echo ""
	@echo "  build         Compile lcl, lcl-bridge-host, lcl-bridge-guest"
	@echo "  test          Run all tests"
	@echo "  clean         Remove build artifacts"
	@echo "  install       Build and install lcl to /usr/local/bin"
	@echo "  run           Launch lcl-app detached from this terminal"
	@echo "  ssh-setup     Install LaunchAgent that auto-loads Keychain SSH keys at login"
	@echo "  ssh-unsetup   Remove the LCL SSH LaunchAgent"
	@echo ""
	@echo "  image-alpine  Download Alpine aarch64 kernel + initrd (fast, for testing)"
	@echo "  image-arch    Build Arch Linux ARM rootfs image"
	@echo "  image         Alias for image-alpine"
