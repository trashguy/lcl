#!/usr/bin/env python3
"""
Build VM images for lcl.

Usage:
    python3 scripts/build-image.py alpine [--env NAME]
    python3 scripts/build-image.py arch [--env NAME]
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import urllib.request
from pathlib import Path

# ── Alpine ────────────────────────────────────────────────────────────

ALPINE_VERSION = "3.21"
ALPINE_RELEASE = "3.21.3"
ALPINE_MIRROR = "https://dl-cdn.alpinelinux.org/alpine"

ALPINE_KERNEL_URL = (
    f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/"
    f"netboot/vmlinuz-lts"
)
ALPINE_INITRD_URL = (
    f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/"
    f"netboot/initramfs-lts"
)
ALPINE_MODLOOP_URL = (
    f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/"
    f"netboot/modloop-lts"
)
ALPINE_ROOTFS_URL = (
    f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/"
    f"alpine-minirootfs-{ALPINE_RELEASE}-aarch64.tar.gz"
)

# ── Arch Linux ARM ────────────────────────────────────────────────────

ARCH_ROOTFS_URL = (
    "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz"
)


def decompress_kernel(src: Path, dest: Path) -> None:
    """Extract raw ARM64 Image from a compressed vmlinuz PE stub.

    VZLinuxBootLoader requires the raw ARM64 kernel Image (with 'ARMd' magic
    at offset 0x38), not the gzip-compressed PE/COFF stub that most distros
    ship as vmlinuz.
    """
    if dest.exists():
        # Check if it already has the ARM64 magic
        with open(dest, "rb") as f:
            f.seek(0x38)
            if f.read(4) == b"ARMd":
                print(f"  vmlinuz: already decompressed, skipping")
                return

    import re
    import zlib

    print(f"  vmlinuz: decompressing PE stub -> raw ARM64 Image...")
    with open(src, "rb") as f:
        data = f.read()

    # Find gzip stream (1f 8b 08) inside the PE stub
    for m in re.finditer(b"\x1f\x8b\x08", data):
        offset = m.start()
        try:
            decompressed = zlib.decompress(data[offset:], 15 + 32)
            # Verify ARM64 magic
            if len(decompressed) > 0x3C and decompressed[0x38:0x3C] == b"ARMd":
                with open(dest, "wb") as f:
                    f.write(decompressed)
                size_mb = len(decompressed) / (1024 * 1024)
                print(f"  vmlinuz: done ({size_mb:.1f} MB raw Image)")
                return
        except Exception:
            continue

    # If no compressed kernel found, the file might already be raw
    print(f"  vmlinuz: WARNING: could not find compressed kernel, using as-is")
    shutil.copy(src, dest)


def config_dir(env_name: str) -> Path:
    """Return ~/.config/lcl/<name>/"""
    return Path.home() / ".config" / "lcl" / env_name


def download(url: str, dest: Path, label: str = "") -> None:
    """Download a file using curl (handles SSL better than urllib on pyenv Python)."""
    if dest.exists():
        print(f"  {label or dest.name}: already exists, skipping")
        return

    print(f"  {label or dest.name}: downloading...")
    dest.parent.mkdir(parents=True, exist_ok=True)

    result = subprocess.run(
        ["curl", "-fL", "--progress-bar", "-o", str(dest), url],
        check=False,
    )
    if result.returncode != 0:
        dest.unlink(missing_ok=True)
        print(f"  {label or dest.name}: download failed (exit {result.returncode})")
        sys.exit(1)

    size_mb = dest.stat().st_size / (1024 * 1024)
    print(f"  {label or dest.name}: done ({size_mb:.1f} MB)")


def build_alpine(env_name: str) -> None:
    """Download Alpine aarch64 kernel + initrd for netboot.

    This boots an Alpine environment entirely from RAM — no disk image needed.
    Great for initial VM testing.
    """
    dest = config_dir(env_name)
    dest.mkdir(parents=True, exist_ok=True)

    print(f"Building Alpine image for '{env_name}'...")

    # Download kernel + initrd (use -virt variant for VM compatibility)
    download(
        f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/netboot/vmlinuz-virt",
        dest / "vmlinuz.compressed",
        "vmlinuz-virt",
    )
    download(
        f"{ALPINE_MIRROR}/v{ALPINE_VERSION}/releases/aarch64/netboot/initramfs-virt",
        dest / "initrd",
        "initramfs-virt",
    )

    # VZLinuxBootLoader needs the raw ARM64 Image, not the compressed PE stub.
    # Extract the gzip payload from inside the PE wrapper.
    decompress_kernel(dest / "vmlinuz.compressed", dest / "vmlinuz")

    # For netboot Alpine, we need a minimal rootfs too.
    # Download the minirootfs and create a disk image.
    cache = Path.home() / ".cache" / "lcl"
    cache.mkdir(parents=True, exist_ok=True)
    rootfs_tar = cache / f"alpine-minirootfs-{ALPINE_RELEASE}-aarch64.tar.gz"
    download(ALPINE_ROOTFS_URL, rootfs_tar, "rootfs tarball")

    rootfs_img = dest / "rootfs.raw"
    if rootfs_img.exists():
        print(f"  rootfs.raw: already exists, skipping")
    else:
        create_ext4_image(rootfs_tar, rootfs_img, size_mb=512)

    # Update lcl.toml with Alpine-appropriate cmdline
    update_cmdline(dest, "console=hvc0 root=/dev/vda rw")

    print(f"\nAlpine image ready at {dest}")
    print(f"Run: lcl start --name {env_name}")


def build_arch(env_name: str) -> None:
    """Download Arch Linux ARM rootfs and build a disk image."""
    dest = config_dir(env_name)
    dest.mkdir(parents=True, exist_ok=True)

    print(f"Building Arch Linux ARM image for '{env_name}'...")

    # Download rootfs tarball
    cache = Path.home() / ".cache" / "lcl"
    cache.mkdir(parents=True, exist_ok=True)
    rootfs_tar = cache / "ArchLinuxARM-aarch64-latest.tar.gz"
    download(ARCH_ROOTFS_URL, rootfs_tar, "rootfs tarball")

    # Extract kernel + initrd from tarball
    print("  Extracting kernel and initrd from tarball...")
    extract_boot_files(rootfs_tar, dest)

    # Create disk image
    rootfs_img = dest / "rootfs.raw"
    if rootfs_img.exists():
        print(f"  rootfs.raw: already exists, skipping")
    else:
        create_ext4_image(rootfs_tar, rootfs_img, size_mb=4096)

    # Update lcl.toml cmdline
    update_cmdline(dest, "console=hvc0 root=/dev/vda rw rdinit=/sbin/init")

    print(f"\nArch Linux ARM image ready at {dest}")
    print(f"Run: lcl start --name {env_name}")


def extract_boot_files(tarball: Path, dest: Path) -> None:
    """Extract vmlinuz and initrd from a Linux rootfs tarball."""
    kernel_found = False
    initrd_found = False

    with tarfile.open(tarball, "r:gz") as tar:
        for member in tar.getmembers():
            name = member.name.lstrip("./")

            # Look for kernel
            if not kernel_found and (
                name.startswith("boot/vmlinuz")
                or name.startswith("boot/Image")
                or name == "boot/Image"
            ):
                print(f"    Found kernel: {name}")
                extract_member(tar, member, dest / "vmlinuz")
                kernel_found = True

            # Look for initrd/initramfs
            if not initrd_found and (
                name.startswith("boot/initramfs")
                or name.startswith("boot/initrd")
            ):
                print(f"    Found initrd: {name}")
                extract_member(tar, member, dest / "initrd")
                initrd_found = True

            if kernel_found and initrd_found:
                break

    if not kernel_found:
        print("  WARNING: No kernel found in tarball.")
        print("  You may need to provide vmlinuz manually.")

    if not initrd_found:
        print("  WARNING: No initrd found in tarball.")
        print("  Boot may still work without initrd.")


def extract_member(tar: tarfile.TarFile, member: tarfile.TarInfo, dest: Path) -> None:
    """Extract a single tar member to a specific path."""
    src = tar.extractfile(member)
    if src is None:
        return
    with open(dest, "wb") as f:
        shutil.copyfileobj(src, f)


def create_ext4_image(rootfs_tar: Path, image_path: Path, size_mb: int = 2048) -> None:
    """Create an ext4 disk image from a rootfs tarball.

    Requires e2fsprogs (brew install e2fsprogs).
    Uses mke2fs -d to create and populate the filesystem in one step.
    """
    mke2fs = find_tool("mke2fs", "brew install e2fsprogs")
    if not mke2fs:
        return

    print(f"  Creating {size_mb}MB ext4 image from tarball...")

    # Create sparse file
    with open(image_path, "wb") as f:
        f.truncate(size_mb * 1024 * 1024)

    # mke2fs -d can take a tarball directly and populate the filesystem
    result = subprocess.run(
        [mke2fs, "-t", "ext4", "-F", "-q", "-d", str(rootfs_tar), str(image_path)],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"  mke2fs -d failed: {result.stderr.strip()}")
        print("  Falling back to extract + populate...")
        # Fall back: extract tarball then use -d with directory
        import tempfile
        with tempfile.TemporaryDirectory(prefix="lcl-rootfs-") as tmpdir:
            print("  Extracting tarball...")
            with tarfile.open(rootfs_tar, "r:gz") as tar:
                tar.extractall(path=tmpdir, filter=None)
            print("  Creating image from directory...")
            subprocess.run(
                [mke2fs, "-t", "ext4", "-F", "-q", "-d", tmpdir, str(image_path)],
                check=True,
                capture_output=True,
            )

    print(f"  rootfs.raw: done ({size_mb}MB)")


def populate_with_fuse2fs(
    fuse2fs: str, rootfs_tar: Path, image_path: Path
) -> None:
    """Mount ext4 image via fuse2fs and extract rootfs into it."""
    import tempfile

    mount_point = Path(tempfile.mkdtemp(prefix="lcl-rootfs-"))

    try:
        print("  Mounting image with fuse2fs...")
        subprocess.run(
            [fuse2fs, "-o", "rw", str(image_path), str(mount_point)],
            check=True,
            capture_output=True,
        )

        print("  Extracting rootfs (this may take a while)...")
        with tarfile.open(rootfs_tar, "r:gz") as tar:
            tar.extractall(path=mount_point, filter=None)

        print("  Unmounting...")
        subprocess.run(["umount", str(mount_point)], check=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        print(f"  fuse2fs failed: {e}")
        print("  Try: brew install macfuse && brew install e2fsprogs")
    finally:
        mount_point.rmdir()


def populate_with_debugfs(
    debugfs: str, rootfs_tar: Path, image_path: Path
) -> None:
    """Use debugfs to write files into the ext4 image (no mount needed)."""
    import tempfile

    print("  Extracting rootfs to temp directory...")
    with tempfile.TemporaryDirectory(prefix="lcl-rootfs-") as tmpdir:
        with tarfile.open(rootfs_tar, "r:gz") as tar:
            tar.extractall(path=tmpdir, filter=None)

        # Build debugfs commands to copy the directory tree
        print("  Writing files to image with debugfs (this is slow)...")
        cmds = build_debugfs_commands(Path(tmpdir))

        proc = subprocess.run(
            [debugfs, "-w", str(image_path)],
            input="\n".join(cmds),
            capture_output=True,
            text=True,
        )
        if proc.returncode != 0:
            print(f"  debugfs warnings (some are normal): {proc.stderr[:200]}")


def build_debugfs_commands(root: Path) -> list[str]:
    """Build debugfs commands to recreate a directory tree."""
    cmds = []
    for path in sorted(root.rglob("*")):
        rel = path.relative_to(root)
        guest_path = f"/{rel}"

        if path.is_dir():
            cmds.append(f"mkdir {guest_path}")
        elif path.is_file() and not path.is_symlink():
            cmds.append(f"write {path} {guest_path}")

    return cmds


def update_cmdline(config_dir: Path, cmdline: str) -> None:
    """Update the cmdline field in lcl.toml if it exists."""
    toml_path = config_dir / "lcl.toml"
    if not toml_path.exists():
        return

    lines = toml_path.read_text().splitlines()
    new_lines = []
    for line in lines:
        if line.strip().startswith("cmdline"):
            new_lines.append(f'cmdline = "{cmdline}"')
        else:
            new_lines.append(line)

    toml_path.write_text("\n".join(new_lines) + "\n")
    print(f"  Updated cmdline in lcl.toml")


def find_tool(name: str, install_hint: str) -> str | None:
    """Find a command-line tool, checking common Homebrew paths."""
    # Check PATH first
    path = shutil.which(name)
    if path:
        return path

    # Check Homebrew paths (e2fsprogs installs to sbin)
    for prefix in ["/opt/homebrew/opt/e2fsprogs/sbin",
                   "/opt/homebrew/opt/e2fsprogs/bin",
                   "/usr/local/opt/e2fsprogs/sbin",
                   "/usr/local/opt/e2fsprogs/bin"]:
        candidate = os.path.join(prefix, name)
        if os.path.isfile(candidate):
            return candidate

    print(f"  ERROR: {name} not found. Install with: {install_hint}")
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Build VM images for lcl")
    parser.add_argument(
        "distro",
        choices=["alpine", "arch"],
        help="Distribution to build",
    )
    parser.add_argument(
        "--env",
        default=None,
        help="Environment name (default: distro name)",
    )
    args = parser.parse_args()

    env_name = args.env or args.distro

    # Ensure lcl config dir exists (run lcl init first, or we create it)
    dest = config_dir(env_name)
    if not (dest / "lcl.toml").exists():
        print(f"No config found for '{env_name}'. Run 'lcl init' first,")
        print(f"or creating a minimal config...")
        dest.mkdir(parents=True, exist_ok=True)
        # Write a minimal config
        (dest / "lcl.toml").write_text(
            f'[environment]\n'
            f'name = "{env_name}"\n'
            f'base = "{args.distro}:latest"\n'
            f'shell = "/bin/sh"\n'
            f'cpu = 4\n'
            f'memory_mb = 4096\n'
            f'kernel = "vmlinuz"\n'
            f'initrd = "initrd"\n'
            f'rootfs = "rootfs.raw"\n'
            f'cmdline = "console=hvc0"\n'
            f'\n[mounts]\nhome = true\n'
            f'\n[bridge]\nkeychain = true\nclipboard = true\nokta = true\nopen = true\n'
            f'\n[setup]\n'
        )

    if args.distro == "alpine":
        build_alpine(env_name)
    elif args.distro == "arch":
        build_arch(env_name)


if __name__ == "__main__":
    main()
