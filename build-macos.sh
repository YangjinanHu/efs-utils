#!/usr/bin/env bash
#
# build-macos.sh: Build and assemble efs-utils for macOS.
# For internal use only.
#
# Usage:
#   ./build-macos.sh [--install | --uninstall]
#
# Prerequisites:
#   - Rust (via rustup): curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
#   - Xcode CLI tools: xcode-select --install
#   - Go: brew install go (required by FIPS crypto library aws-lc-fips-sys)
#   - CMake: brew install cmake (required by FIPS crypto library aws-lc-fips-sys)
#
# Output:
#   build/macos/ — assembled efs-utils directory ready for installation

set -euo pipefail

# --- Config ---

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${BASE_DIR}/build/macos"
PROXY_DIR="$BASE_DIR/src/proxy"
INSTALL_ROOT="/usr/local"

ARCH=$(uname -m | sed 's/arm64/aarch64/')
case "$ARCH" in
    aarch64) RUST_TARGET="aarch64-apple-darwin" ;;
    x86_64)  RUST_TARGET="x86_64-apple-darwin" ;;
    *)       echo "Error: unsupported architecture: $ARCH"; exit 1 ;;
esac

# --- Functions ---

# Exit with error if a required command is not in PATH.
require_cmd() {
    command -v "$1" &>/dev/null || { echo "Error: $1 not found."; exit 1; }
}

# Print usage information.
show_help() {
    echo "Usage: ./build-macos.sh [--install | --uninstall]"
    echo ""
    echo "Build and assemble efs-utils for macOS."
    echo ""
    echo "Options:"
    echo "  --install    Build then install to $INSTALL_ROOT"
    echo "  --uninstall  Remove efs-utils from the system"
    echo "  -h, --help   Show this help message"
}

# Build efs-proxy from source and copy binary + FIPS dylibs into BUILD_ROOT.
build_efs_proxy() {
    require_cmd cargo
    require_cmd go
    require_cmd cmake
    require_cmd rustup

    rustup target add "$RUST_TARGET" 2>/dev/null || true

    # Configure Go environment for aws-lc-fips-sys crate build
    local goroot gocache
    goroot="$(go env GOROOT)"
    gocache="$(go env GOCACHE)"

    echo "Building efs-proxy for $RUST_TARGET"
    cargo build --release \
        --manifest-path "$PROXY_DIR/Cargo.toml" \
        --target "$RUST_TARGET" \
        --config "env.GOROOT=\"${goroot}\"" \
        --config "env.GOCACHE=\"${gocache}\"" \
        --config 'env.GOPROXY="https://proxy.golang.org,direct"'

    local binary="$PROXY_DIR/target/$RUST_TARGET/release/efs-proxy"
    test -f "$binary" || { echo "Error: build did not produce $binary"; exit 1; }

    cp "$binary" "$BUILD_ROOT/bin/efs-proxy"
    chmod 755 "$BUILD_ROOT/bin/efs-proxy"

    # Copy FIPS shared libraries (.dylib) that the binary needs at runtime
    cp "$PROXY_DIR/target/$RUST_TARGET/release/build/"aws-lc-fips-sys-*/out/build/artifacts/libaws_lc_fips_*.dylib "$BUILD_ROOT/lib/" \
        || { echo "Error: no FIPS dylibs found"; exit 1; }
    chmod 644 "$BUILD_ROOT/lib/"*.dylib

    # Fix rpath so the binary finds its dylibs in ../lib/ relative to bin/
    install_name_tool -add_rpath @executable_path/../lib "$BUILD_ROOT/bin/efs-proxy"
}

# Install build artifacts from BUILD_ROOT to INSTALL_ROOT and system directories.
do_install() {
    echo "Installing efs-utils to $INSTALL_ROOT"

    sudo mkdir -p "$INSTALL_ROOT/bin"
    sudo mkdir -p "$INSTALL_ROOT/lib"
    sudo mkdir -p "$INSTALL_ROOT/share/man/man8"
    sudo mkdir -p /etc/amazon/efs
    sudo mkdir -p /var/log/amazon/efs
    sudo mkdir -p /Library/Filesystems/efs.fs/Contents/Resources
    sudo mkdir -p /Library/Filesystems/s3files.fs/Contents/Resources

    sudo install -m 755 "$BUILD_ROOT/bin/efs-proxy"                     "$INSTALL_ROOT/bin/"
    sudo install -m 755 "$BUILD_ROOT/bin/mount.efs"                     "$INSTALL_ROOT/bin/"
    sudo install -m 755 "$BUILD_ROOT/bin/mount.s3files"                 "$INSTALL_ROOT/bin/"
    sudo install -m 755 "$BUILD_ROOT/bin/amazon-efs-mount-watchdog"     "$INSTALL_ROOT/bin/"
    sudo install -m 644 "$BUILD_ROOT/lib/"*.dylib                       "$INSTALL_ROOT/lib/"
    sudo install -m 644 "$BUILD_ROOT/etc/amazon/efs/efs-utils.conf"     /etc/amazon/efs/
    sudo install -m 644 "$BUILD_ROOT/etc/amazon/efs/s3files-utils.conf" /etc/amazon/efs/
    sudo install -m 444 "$BUILD_ROOT/etc/amazon/efs/efs-utils.crt"      /etc/amazon/efs/
    sudo install -m 644 "$BUILD_ROOT/share/man/man8/mount.efs.8"        "$INSTALL_ROOT/share/man/man8/"
    sudo install -m 644 "$BUILD_ROOT/share/man/man8/mount.s3files.8"    "$INSTALL_ROOT/share/man/man8/"
    sudo install -m 644 "$BUILD_ROOT/amazon-efs-mount-watchdog.plist"   /Library/LaunchDaemons/

    sudo rm -rf "$INSTALL_ROOT/bin/efs_utils_common" "$INSTALL_ROOT/bin/mount_efs" "$INSTALL_ROOT/bin/mount_s3files"
    sudo cp -r          "$BUILD_ROOT/bin/efs_utils_common"              "$INSTALL_ROOT/bin/"
    sudo cp -r          "$BUILD_ROOT/bin/mount_efs"                     "$INSTALL_ROOT/bin/"
    sudo cp -r          "$BUILD_ROOT/bin/mount_s3files"                 "$INSTALL_ROOT/bin/"

    sudo ln -sf "$INSTALL_ROOT/bin/mount.efs"     /Library/Filesystems/efs.fs/Contents/Resources/mount_efs
    sudo ln -sf "$INSTALL_ROOT/bin/mount.s3files" /Library/Filesystems/s3files.fs/Contents/Resources/mount_s3files

    sudo launchctl unload /Library/LaunchDaemons/amazon-efs-mount-watchdog.plist 2>/dev/null || true
    sudo launchctl load /Library/LaunchDaemons/amazon-efs-mount-watchdog.plist

    echo "Installation complete."
}

# Remove all installed efs-utils files from the system.
do_uninstall() {
    echo "Uninstalling efs-utils"
    sudo launchctl unload /Library/LaunchDaemons/amazon-efs-mount-watchdog.plist 2>/dev/null || true
    sudo rm -f  /Library/LaunchDaemons/amazon-efs-mount-watchdog.plist
    sudo rm -f  "$INSTALL_ROOT/bin"/{efs-proxy,mount.efs,mount.s3files,amazon-efs-mount-watchdog}
    sudo rm -rf "$INSTALL_ROOT/bin"/{efs_utils_common,mount_efs,mount_s3files}
    sudo rm -f  "$INSTALL_ROOT/lib"/libaws_lc_fips_*.dylib
    sudo rm -rf /etc/amazon/efs
    sudo rm -f  "$INSTALL_ROOT/share/man/man8"/mount.efs.8 "$INSTALL_ROOT/share/man/man8"/mount.s3files.8
    sudo rm -rf /Library/Filesystems/efs.fs /Library/Filesystems/s3files.fs
    echo "Uninstall complete."
}

# --- Arg parsing ---

if [ "$#" -gt 1 ]; then
    echo "Error: only one option allowed"
    show_help
    exit 1
fi

DO_INSTALL=false
DO_UNINSTALL=false
case "${1:-}" in
    -h|--help)   show_help; exit 0 ;;
    --install)   DO_INSTALL=true ;;
    --uninstall) DO_UNINSTALL=true ;;
    "")          ;;
    *)           echo "Unknown option: $1"; show_help; exit 1 ;;
esac

# --- Main ---

if [ "$DO_UNINSTALL" = true ]; then
    do_uninstall
    exit 0
fi

echo 'Cleaning build directory'
rm -rf "$BUILD_ROOT"

echo 'Creating application directories'
mkdir -p "$BUILD_ROOT/bin"
mkdir -p "$BUILD_ROOT/bin/efs_utils_common"
mkdir -p "$BUILD_ROOT/bin/mount_s3files"
mkdir -p "$BUILD_ROOT/bin/mount_efs"
mkdir -p "$BUILD_ROOT/lib"
mkdir -p "$BUILD_ROOT/etc/amazon/efs"
mkdir -p "$BUILD_ROOT/share/man/man8"

build_efs_proxy

echo 'Copying application files'
cp "$BASE_DIR/src/mount_efs/__init__.py"            "$BUILD_ROOT/bin/mount.efs"
cp "$BASE_DIR/src/mount_s3files/__init__.py"        "$BUILD_ROOT/bin/mount.s3files"
cp "$BASE_DIR/src/efs_utils_common/"*.py            "$BUILD_ROOT/bin/efs_utils_common/"
cp "$BASE_DIR/src/mount_s3files/"*.py               "$BUILD_ROOT/bin/mount_s3files/"
cp "$BASE_DIR/src/mount_efs/"*.py                   "$BUILD_ROOT/bin/mount_efs/"
cp "$BASE_DIR/src/watchdog/__init__.py"             "$BUILD_ROOT/bin/amazon-efs-mount-watchdog"
cp "$BASE_DIR/dist/efs-utils.conf"                  "$BUILD_ROOT/etc/amazon/efs/"
cp "$BASE_DIR/dist/s3files-utils.conf"              "$BUILD_ROOT/etc/amazon/efs/"
cp "$BASE_DIR/dist/efs-utils.crt"                   "$BUILD_ROOT/etc/amazon/efs/"
cp "$BASE_DIR/dist/amazon-efs-mount-watchdog.plist" "$BUILD_ROOT/"
chmod 755 "$BUILD_ROOT/bin/mount.efs" "$BUILD_ROOT/bin/mount.s3files" "$BUILD_ROOT/bin/amazon-efs-mount-watchdog"

echo 'Copying manpages'
cp "$BASE_DIR/man/mount.efs.8"                      "$BUILD_ROOT/share/man/man8/"
cp "$BASE_DIR/man/mount.s3files.8"                  "$BUILD_ROOT/share/man/man8/"

echo "efs-utils build complete: $BUILD_ROOT/"

if [ "$DO_INSTALL" = true ]; then
    do_install
fi
