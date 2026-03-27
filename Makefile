.PHONY: build test clean image image-alpine image-arch install help

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
	@echo ""
	@echo "  image-alpine  Download Alpine aarch64 kernel + initrd (fast, for testing)"
	@echo "  image-arch    Build Arch Linux ARM rootfs image"
	@echo "  image         Alias for image-alpine"
