# Phase 2: Bridge Daemon

The core novel piece — proxies macOS system APIs into the Linux guest over vsock.

## Architecture

```
macOS (host)                              Linux (guest)
┌─────────────────────┐                  ┌─────────────────────┐
│  lcl-bridge-host    │  vsock           │  lcl-bridge-guest   │
│  (Swift daemon)     │◄────────────────►│  (Rust/Go binary)   │
│                     │  gRPC/protobuf   │                     │
│  Security.framework │                  │  CLI wrappers:      │
│  NSPasteboard       │                  │   macos-keychain    │
│  NSWorkspace        │                  │   macos-clipboard   │
│  Okta token cache   │                  │   macos-open        │
└─────────────────────┘                  │   macos-okta        │
                                         └─────────────────────┘
```

## Protocol (gRPC over vsock)

```protobuf
service MacOSBridge {
  // Keychain
  rpc KeychainGet(KeychainRequest) returns (KeychainResponse);
  rpc KeychainSet(KeychainSetRequest) returns (Empty);
  rpc KeychainDelete(KeychainDeleteRequest) returns (Empty);

  // Clipboard
  rpc ClipboardGet(Empty) returns (ClipboardResponse);
  rpc ClipboardSet(ClipboardSetRequest) returns (Empty);

  // Open (URLs, files in macOS apps)
  rpc Open(OpenRequest) returns (Empty);

  // Okta
  rpc OktaGetToken(OktaRequest) returns (OktaResponse);

  // Notifications
  rpc Notify(NotifyRequest) returns (Empty);
}
```

## Host daemon (Swift)

- Runs as a launchd service or started by `lcl start`
- Listens on a vsock port (e.g., port 5000)
- Uses Apple frameworks:
  - `Security.framework` — SecItemCopyMatching, SecItemAdd, SecItemDelete
  - `AppKit.NSPasteboard` — generalPasteboard read/write
  - `AppKit.NSWorkspace` — open URLs and files
  - `UserNotifications` — post native macOS notifications
- For Okta: reads tokens from the Okta client's cookie jar / token cache location

## Guest client (Rust or Go)

- Single binary installed in the container image
- Connects to host over vsock on startup
- Exposes subcommands or individual CLI tools:

```bash
# Keychain
macos-keychain get --service "company-vpn" --account "adam"
macos-keychain set --service "my-app" --account "adam" --password "..."

# Clipboard
echo "hello" | macos-clipboard copy
macos-clipboard paste

# Open URLs/files on Mac
macos-open https://github.com
macos-open ~/Documents/report.pdf   # opens in macOS Preview

# Okta
eval $(macos-okta env)               # exports OKTA_TOKEN etc.

# Notifications
macos-notify "Build finished" --title "LCL"
```

## Security considerations

- vsock is VM-local only — not exposed to network
- Host daemon should authenticate the guest (shared secret at boot?)
- Keychain access scoped — don't expose everything, let user allowlist services
- Config in lcl.toml controls which bridge features are enabled

## Tasks

- [ ] Define protobuf schema
- [ ] Scaffold host daemon in Swift
- [ ] Implement Keychain get/set via Security.framework
- [ ] Implement clipboard proxy via NSPasteboard
- [ ] Implement open proxy via NSWorkspace
- [ ] Scaffold guest client in Rust or Go
- [ ] Implement guest CLI tools (keychain, clipboard, open, okta)
- [ ] Add authentication between host and guest
- [ ] Package guest client for installation in container images
