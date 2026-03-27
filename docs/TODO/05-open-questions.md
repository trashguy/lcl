# Open Questions

Decisions to make before/during implementation.

## Language for the CLI
- **Swift** — native Containerization package integration, but less portable
- **Rust** — great CLI tooling (clap, tokio), cross-compile guest client too
- **Zig** — keeps the stack aligned with Ghostty, but less ecosystem for gRPC/protobuf
- Recommendation: Swift for host daemon + CLI (tight Apple API integration), Rust for guest client

## Bridge transport
- **gRPC over vsock** — well-defined, code generation, but heavier dependency
- **Custom protocol over vsock** — lighter, but more work
- **Unix socket over VirtioFS** — simpler, but slower and less clean
- Apple Container already uses gRPC over vsock for vminitd — can we extend that or do we run a second service?

## Okta integration specifics
- Where does the Okta client store tokens on macOS? Need to investigate
- Is it a browser cookie, a keychain entry, or a file?
- May vary by Okta client version / organization config

## Apple Container as dependency
- Apple Container requires macOS 26+ and Apple Silicon
- Is that acceptable or do we need a Lima/QEMU fallback for Intel Macs?
- Current Apple Container is still pre-1.0

## Distribution
- Homebrew tap? (`brew install lcl`)
- Standalone binary + install script?
- Both?
