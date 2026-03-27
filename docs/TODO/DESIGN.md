# LCL — Design Document

## What is LCL?

Linux Compatibility Layer. A native Linux VM environment for macOS with access to macOS system services (Keychain, clipboard, notifications, open URLs). Think WSL for Mac.

## Stack

All Zig. No Swift, no shell execution.

| Component | Language | Notes |
|---|---|---|
| LCL CLI (`lcl`) | Zig | init, build, start, stop, status, config, shell, destroy |
| LCL Terminal (`lcl-app`) | Zig | Standalone macOS GUI with custom VT100 parser |
| Bridge Host | Zig | Runs inside `lcl` process, vsock port 5000 |
| Bridge Guest (`lcl-bridge-guest`) | Zig | Static aarch64-linux ELF, cross-compiled |
| Shell Service | Zig | Guest-side PTY daemon, vsock port 5001 |
| Image Builder | Zig + lwext4 (C) | Pure-Zig ext4 creation, no mke2fs |
| VM Runtime | Zig → ObjC | Virtualization.framework via objc_msgSend |

## Architecture

```
┌──────────────────────┐              ┌──────────────────────────────┐
│  LCL.app (macOS)     │              │  Linux Guest (Arch ARM)       │
│  ┌────────────────┐  │   vsock      │                               │
│  │ Terminal View   │  │ ◄── :5001 ──│  lcl-bridge-guest             │
│  │ VT100 parser    │  │             │    shell-service (PTY daemon) │
│  │ CoreText render │  │             │                               │
│  └────────────────┘  │   vsock      │  CLI tools:                   │
│                      │ ◄── :5000 ──│    macos-keychain              │
│  Bridge handler:     │             │    macos-clipboard             │
│    Keychain          │             │    macos-open                  │
│    Clipboard         │             │    macos-notify                │
│    Open URLs/files   │             │                               │
│    Notifications     │              └──────────────────────────────┘
└──────────────────────┘
```

## Key Decisions

| Decision | Choice |
|---|---|
| Language | Zig — entire stack (host CLI, GUI app, guest binary, framework bindings) |
| VM runtime | Virtualization.framework via ObjC runtime (objc_msgSend) |
| Bridge transport | Custom binary TLV protocol over vsock (port 5000) |
| Shell transport | Framed byte stream over vsock (port 5001) |
| Terminal emulation | Custom VT100 parser (Paul Williams state machine) |
| Rendering | CoreText + CoreGraphics via objc_msgSend |
| ext4 creation | lwext4 C library (vendored, BSD-licensed subset) |
| Config format | TOML (`~/.config/lcl/<env-name>/lcl.toml`) |
| macOS API access | Direct C calls (Security.framework) or objc_msgSend (AppKit) |
| Min platform | macOS 26, Apple Silicon only |

## Binaries

| Binary | Target | Description |
|---|---|---|
| `lcl` | macOS arm64 | CLI tool (codesigned with virtualization entitlement) |
| `lcl-app` | macOS arm64 | GUI terminal app (codesigned) |
| `lcl-bridge-host` | macOS arm64 | Standalone bridge (test harness) |
| `lcl-bridge-guest` | Linux aarch64 | Static ELF, multi-call (busybox-style) |

## Protocols

### Bridge RPC (port 5000)
Request/response. 4-byte header: `type(u8) + request_id(u8) + payload_len(u16)`. Payload is TLV fields: `tag(u8) + len(u16) + value`.

Message types: keychain get/set/delete, clipboard get/set, open, notify, okta_get_token.

### Shell Stream (port 5001)
Continuous bidirectional byte stream. 3-byte frame header: `type(u8) + len(u16)`. Frame types: data (0x01), resize (0x02), close (0x03).

## Current Status

- [x] CLI (init, build, start, stop, status, config, shell, destroy)
- [x] Virtualization.framework bindings (VM lifecycle, vsock, VirtioFS, serial)
- [x] Bridge daemon (Keychain, clipboard, open URLs, notifications)
- [x] Image builder (lwext4, HTTP downloads, tar-to-ext4 pipeline, kernel extraction)
- [x] Terminal app (VT100 parser, CoreText rendering, NSWindow tabs, splits)
- [x] Shell service (guest PTY daemon, auto-started by systemd)
- [x] End-to-end: lcl-app boots Arch ARM VM, connects shell, renders terminal

## TODO

- [ ] Alpine support (needs custom initramfs with ext4 modules)
- [ ] Window resize → shell resize propagation in GUI app
- [ ] Multiple environments (currently hardcoded to "dev")
- [ ] Clipboard integration in GUI (Cmd+C/V → bridge)
- [ ] VM lifecycle controls in GUI (start/stop/build from menu)
- [ ] Clean shutdown (stop VM gracefully on app quit)
- [ ] Memory leak cleanup in buildVmConfig
- [ ] GPU passthrough (Virtio GPU)
- [ ] Audio passthrough
- [ ] SSH agent forwarding
- [ ] VPN/network proxy transparency
