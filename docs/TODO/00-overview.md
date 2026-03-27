# LCL — Linux Compatibility Layer

A tool that gives macOS users a native Linux environment with full access to macOS system services.

## Stack

- **Ghostty** — terminal emulator (existing, Zig)
- **Apple Container** — Linux VM runtime via Virtualization.framework (existing, Swift)
- **LCL Bridge Daemon** — macOS API proxy over vsock (we build this)
- **LCL CLI** — setup, config, lifecycle management (we build this)

## How it works

```
User types `lcl start`
  → Apple Container boots a Linux VM from user's chosen OCI image
  → VirtioFS mounts macOS filesystem into the guest
  → Bridge daemon starts on host, listens on vsock
  → Guest-side bridge client connects
  → User is dropped into their shell inside Linux
  → CLI tools inside guest can access Keychain, clipboard, Okta, etc. via bridge
```

## Design principles

- Beginner-friendly: `lcl init` → pick a distro → go
- Power-user friendly: full Containerfile access for custom builds
- No GUI required — everything works from the terminal
- macOS system services accessible from inside Linux as native-feeling CLI tools
