# Phase 1: LCL CLI

The main user-facing tool. Wraps Apple Container and manages environments.

## Commands

```
lcl init              Interactive setup — pick distro, shell, mounts, dev tools
lcl start             Boot the container, attach bridge, drop into shell
lcl stop              Stop the running container
lcl status            Show running environments
lcl config            Edit lcl.toml / Containerfile
lcl build             Rebuild the container image from Containerfile
lcl shell             Attach to an already-running environment
lcl destroy           Remove the environment and image
```

## Config file: lcl.toml

```toml
[environment]
name = "arch-dev"
base = "archlinux:latest"
shell = "/bin/zsh"

[mounts]
home = true                          # mount ~/
# custom = ["/path/on/mac:/path/in/guest"]

[bridge]
keychain = true
clipboard = true
okta = true
open = true

[setup]
packages = ["git", "base-devel", "neovim", "zsh"]
dotfiles = "https://github.com/trashguy/dotfiles.git"
# post_install = "./setup.sh"
```

## `lcl init` flow

1. "Pick a base image:" → Arch, Ubuntu, Fedora, Alpine, Debian, NixOS, Custom
2. "Pick a shell:" → zsh, bash, fish
3. "Mount home directory?" → Y/n
4. "Install common dev tools?" → Y/n
5. "Dotfiles repo (optional):" → URL or skip
6. Generates `lcl.toml` + `Containerfile` in `~/.config/lcl/<name>/`
7. For power users: "Your Containerfile is at ~/.config/lcl/arch-dev/Containerfile — edit it however you want"

## Implementation

- Language: Swift or Rust (TBD — Swift has native Apple Container/Containerization integration)
- Calls `container` CLI or links against `Containerization` Swift package directly
- Config stored in `~/.config/lcl/`

## Tasks

- [ ] Scaffold CLI with argument parsing
- [ ] Implement `lcl init` with interactive prompts
- [ ] Generate Containerfile from config
- [ ] Implement `lcl start` wrapping `container run`
- [ ] Implement `lcl stop`, `lcl status`, `lcl destroy`
- [ ] Implement `lcl build` for image rebuilds
- [ ] Implement `lcl shell` for reattaching
