# Phase 3: Container Images & Containerfile Templates

Pre-built templates and base images so users can get started fast.

## Template Containerfiles

Each distro gets a template Containerfile that `lcl init` generates from.

### Arch Linux (Containerfile.arch)

```dockerfile
FROM archlinux:latest

# Update and install base packages
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm base-devel git {{packages}}

# Install shell
RUN pacman -S --noconfirm {{shell}}

# Install LCL bridge guest client
COPY lcl-bridge-guest /usr/local/bin/
COPY macos-keychain macos-clipboard macos-open macos-okta macos-notify /usr/local/bin/

# Optional: clone dotfiles
{{#if dotfiles}}
RUN git clone {{dotfiles}} /home/{{user}}/.dotfiles && \
    cd /home/{{user}}/.dotfiles && ./install.sh
{{/if}}

# Set default shell
ENV SHELL={{shell}}
CMD ["{{shell}}"]
```

### Other distros

Similar templates for:
- **Ubuntu/Debian** — apt-based
- **Fedora** — dnf-based
- **Alpine** — apk-based, minimal
- **NixOS** — nix-based

### Custom

For power users: `lcl init --custom` just gives you a blank Containerfile with
the bridge client COPY lines and a comment explaining what to do.

## Pre-built images (stretch goal)

Publish pre-built OCI images to a registry so `lcl start` doesn't require a build step:

```
ghcr.io/trashguy/lcl-arch:latest
ghcr.io/trashguy/lcl-ubuntu:latest
ghcr.io/trashguy/lcl-fedora:latest
```

These would have the bridge client pre-installed and common dev tools ready.

## Documentation

Each template should include:
- Inline comments explaining what each section does
- A link to Containerfile/Dockerfile reference docs
- Examples of common customizations (adding languages, tools, services)

## Tasks

- [ ] Write Arch Containerfile template
- [ ] Write Ubuntu/Debian Containerfile template
- [ ] Write Fedora Containerfile template
- [ ] Write Alpine Containerfile template
- [ ] Implement template rendering from lcl.toml
- [ ] Test all templates with `container build` + `container run`
- [ ] Set up CI to build and push pre-built images (stretch)
