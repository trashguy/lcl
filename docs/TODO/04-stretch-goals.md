# Phase 4: Stretch Goals

Nice-to-haves once the core works.

## GPU passthrough
- Apple's Virtualization.framework supports Virtio GPU
- Could enable GPU-accelerated workloads inside the Linux guest
- Useful for ML, rendering, etc.

## Audio passthrough
- Virtio sound device support
- Play audio from Linux apps through macOS output

## X11/Wayland forwarding
- Run Linux GUI apps, display on macOS
- XQuartz or native Wayland compositor bridge
- Similar to WSLg on Windows

## Multiple environments
- Run multiple named environments simultaneously
- `lcl start arch-dev` / `lcl start ubuntu-ci`
- Each with their own image, config, and bridge instance

## Ghostty integration
- Ghostty custom command: open new split/tab directly into LCL
- Keybind to launch `lcl shell` in a new Ghostty pane
- Could use Ghostty's config to auto-launch LCL on startup

## SSH agent forwarding
- Forward macOS SSH agent into the guest
- `ssh-add` keys on Mac, use them inside Linux seamlessly

## Network proxy
- Transparent proxy so VPN on macOS works inside the guest
- Corporate VPN (Okta/Zscaler/etc.) traffic routed correctly

## File association
- Double-click a file in macOS Finder → opens in Linux app
- `macos-open` in reverse: Linux tools registered as macOS handlers

## Auto-update bridge client
- When host daemon updates, auto-update the guest client
- Version negotiation in the gRPC handshake
