# LCL — Design Document

## What is LCL?

Linux Compatibility Layer. Gives macOS users a native Linux environment with access to macOS system services (Keychain, Okta, clipboard, etc.). Think WSL for Mac.

## Stack

| Component | Source | Language |
|---|---|---|
| Terminal | Ghostty (existing) | Zig |
| VM Runtime | Virtualization.framework (ObjC API from Zig) | Zig |
| LCL CLI | We build | Zig |
| Host Bridge Daemon | We build | Zig |
| Guest Bridge Client | We build | Zig (cross-compiled to aarch64-linux) |

### Why all Zig?

- **One language** for host CLI, host daemon, and guest client
- Zig has native C interop — calls Security.framework (Keychain) directly
- Zig can call ObjC via `objc_msgSend` — Ghostty proves this works for AppKit
- Cross-compiles to static Linux binaries trivially: `zig build -Dtarget=aarch64-linux`
- Aligns with Ghostty ecosystem
- No Swift, no shell execution — all framework calls via C API or ObjC runtime
- No shell-out attack surface

### macOS API access from Zig

All access is via direct C calls or ObjC runtime (`objc_msgSend`). Zero shell execution.

| API | Approach |
|---|---|
| Virtualization.framework (VM) | objc_msgSend (VZVirtualMachine, VZVirtioSocketDevice, etc.) |
| Security.framework (Keychain) | Direct C calls (SecItemCopyMatching, etc.) |
| NSPasteboard (clipboard) | objc_msgSend |
| NSWorkspace (open URLs/files) | objc_msgSend |
| UserNotifications | objc_msgSend |

Reference: Ghostty (github.com/ghostty-org/ghostty) and Code-Hex/vz (Go) both call these ObjC APIs from non-ObjC languages.

## Architecture

```
┌─────────────┐     ┌──────────────────────────────────────────────┐
│   Ghostty    │     │  lcl CLI                                     │
│   terminal   │────►│  lcl init / start / stop / status / config   │
└─────────────┘     └──────────┬───────────────────────────────────┘
                               │
                    ┌──────────▼───────────────────────────────────┐
                    │  Virtualization.framework (ObjC API from Zig)  │
                    │  ├─ OCI image (archlinux, ubuntu, etc.)      │
                    │  ├─ VirtioFS mounts (macOS FS → guest)       │
                    │  ├─ vmnet networking                          │
                    │  └─ vsock (host ↔ guest channel)             │
                    └──────────┬───────────────────────────────────┘
                               │ vsock
              ┌────────────────┼────────────────┐
              │                │                │
   ┌──────────▼──────┐  ┌─────▼──────────────────────────┐
   │ lcl-bridge-host  │  │  Linux Guest                    │
   │ (Zig daemon)     │  │  ├─ user's shell (zsh/bash/etc) │
   │                  │  │  ├─ lcl-bridge-guest (client)   │
   │ Keychain access  │  │  └─ CLI tools:                  │
   │ Clipboard sync   │  │     macos-keychain              │
   │ Okta tokens      │  │     macos-clipboard             │
   │ Open URLs/files  │  │     macos-open                  │
   │ Notifications    │  │     macos-okta                  │
   └──────────────────┘  │     macos-notify                │
                         └─────────────────────────────────┘
```

## Data flow example: Keychain access

```
1. User in Arch guest runs:  macos-keychain get --service vpn --account adam
2. macos-keychain → lcl-bridge-guest → vsock → lcl-bridge-host
3. Host daemon calls Security.framework SecItemCopyMatching()
4. Result flows back: host → vsock → guest → stdout
```

## File layout (planned)

```
lcl/
├── docs/
│   └── TODO/
│       ├── DESIGN.md              ← you are here
│       ├── 00-overview.md
│       ├── 01-cli.md
│       ├── 02-bridge-daemon.md
│       ├── 03-container-images.md
│       ├── 04-stretch-goals.md
│       └── 05-open-questions.md
├── src/                           ← All Zig
│   ├── cli/                       ← lcl CLI (init, start, stop, etc.)
│   ├── bridge/
│   │   ├── host/                  ← bridge host daemon (macOS APIs)
│   │   ├── guest/                 ← bridge guest client (runs in Linux)
│   │   └── protocol.zig          ← shared message types + wire format
│   ├── macos/                     ← macOS framework bindings
│   │   ├── objc.zig               ← ObjC runtime helpers (objc_msgSend, selectors, etc.)
│   │   ├── virtualization.zig     ← Virtualization.framework (VZVirtualMachine, vsock, VirtioFS)
│   │   ├── security.zig           ← Security.framework (Keychain)
│   │   ├── pasteboard.zig         ← NSPasteboard (clipboard)
│   │   ├── workspace.zig          ← NSWorkspace (open URLs/files)
│   │   └── notifications.zig      ← UserNotifications
│   └── vm/                        ← VM lifecycle management
│       ├── config.zig             ← VM configuration (CPU, memory, devices)
│       ├── lifecycle.zig           ← start, stop, pause, resume
│       └── devices.zig            ← VirtioFS mounts, vsock, network
├── containers/                    ← Containerfile templates
│   ├── arch/Containerfile
│   ├── ubuntu/Containerfile
│   ├── fedora/Containerfile
│   └── alpine/Containerfile
├── build.zig                      ← Zig build system
└── build.zig.zon                  ← Zig package manifest
```

## Key decisions

| Decision | Status | Choice |
|---|---|---|
| Language | Decided | Zig — entire stack (host + guest) |
| Bridge transport | Decided | Custom binary protocol over vsock — pure Zig, no protobuf/gRPC |
| Config format | Decided | TOML (`lcl.toml`) |
| Config location | Decided | `~/.config/lcl/<env-name>/` |
| VM runtime | Decided | Virtualization.framework via ObjC from Zig (no shell execution) |
| Min macOS version | Decided | macOS 26 (Apple Container requirement) |
| Min hardware | Decided | Apple Silicon only |

## Phase order

1. **CLI** — `lcl init`, `lcl start`, `lcl stop` wrapping Apple Container
2. **Bridge daemon** — host + guest, starting with Keychain + clipboard
3. **Container images** — Containerfile templates, tested per distro
4. **Stretch** — GPU, audio, GUI forwarding, SSH agent, multi-env

## Current status

- [x] Project initialized
- [x] Design docs written
- [x] Phase 1: CLI scaffold
- [x] Phase 2: Bridge daemon
- [x] Phase 3: Image builder (lwext4)
- [ ] Phase 4: Stretch goals
