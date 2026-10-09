#!/bin/bash

# Use Bash and exit on errors, unset variables, or failed pipeline commands
set -euo pipefail

error() {
    echo >&2
    echo "ERROR: $*" >&2
    echo >&2
    exit 1
}

TMP_CLEANUP_PATHS=()
cleanup() {
    if (( ${#TMP_CLEANUP_PATHS[@]} > 0 )); then
        rm -rf "${TMP_CLEANUP_PATHS[@]}"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------
# Ensure root privileges
# ------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    if [[ ! -f "$0" || "$0" =~ ^-?(ba|da|z)?sh$ ]]; then
        error "Root privileges required. When running via pipe (curl | bash), please execute with sudo: curl -fsSL <url> | sudo bash"
    fi

    if command -v sudo >/dev/null 2>&1; then
        echo "Root privileges required. Re-running with sudo..."
        SCRIPT_PATH="$(realpath "$0" 2>/dev/null || readlink -f "$0" 2>/dev/null || echo "$0")"
        exec sudo -- bash "$SCRIPT_PATH" "$@"
    else
        error "This script requires root privileges. Please execute using sudo."
    fi
fi

# ------------------------------------------------------------
# Check supported operating system
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]] || ! command -v apt-get >/dev/null 2>&1; then
    error "Unsupported operating system. This script requires Debian or a Debian-based Linux distribution."
fi

# shellcheck disable=SC1091
. /etc/os-release

OS_ID="${ID:-unknown}"
OS_ID_LIKE="${ID_LIKE:-}"

if [[ "$OS_ID" != "debian" && "$OS_ID" != "ubuntu" && "$OS_ID_LIKE" != *"debian"* && "$OS_ID_LIKE" != *"ubuntu"* ]]; then
    error "Unsupported operating system: ${OS_ID:-unknown}. This script requires Debian, Ubuntu, or a compatible derivative."
fi

echo "✓ Supported OS detected: ${PRETTY_NAME:-$OS_ID}"

# ------------------------------------------------------------
# Check minimum available disk space
# ------------------------------------------------------------

REQUIRED_DISK_GB=6

echo "Checking for sufficient disk space..."

AVAILABLE_GB=$(df --output=avail / | tail -n 1)
AVAILABLE_GB=$((AVAILABLE_GB / 1024 / 1024))

if (( AVAILABLE_GB < REQUIRED_DISK_GB )); then
    error "Insufficient disk space. Requires ~${REQUIRED_DISK_GB}GB, but only ${AVAILABLE_GB}GB is available."
fi

echo "✓ Available disk space: ${AVAILABLE_GB}GB. Proceeding..."

# ------------------------------------------------------------
# Detect target user
# ------------------------------------------------------------

TARGET_USER="${SUDO_USER:-$(id -un)}"

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || TARGET_HOME="$HOME"

TARGET_GROUP="$(id -gn "$TARGET_USER")"
TARGET_SHELL="$(getent passwd "$TARGET_USER" | cut -d: -f7)"

run_as_target() {
    if [[ "$TARGET_USER" == "root" ]]; then
        env HOME="$TARGET_HOME" "$@"
    elif command -v runuser >/dev/null 2>&1; then
        runuser -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    else
        sudo -u "$TARGET_USER" -- env HOME="$TARGET_HOME" "$@"
    fi
}

echo "✓ Target user: $TARGET_USER"
echo "✓ Target home: $TARGET_HOME"

# ------------------------------------------------------------
# Basics
# ------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

# Update and upgrade package lists
env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get update
env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get upgrade -y -o Dpkg::Options::="--force-confold"

# Set timezone
if [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null 2>&1; then
    timedatectl set-timezone Asia/Kolkata
else
    env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get install -y --no-install-recommends tzdata
    ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
    echo "Asia/Kolkata" > /etc/timezone
fi

# Verify timezone
if [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null 2>&1; then
    timedatectl show --property=Timezone --value | grep -qx 'Asia/Kolkata'
else
    [[ -e /etc/localtime ]] && {
        [[ "$(cat /etc/timezone 2>/dev/null)" == "Asia/Kolkata" ]] || \
        readlink /etc/localtime | grep -q 'Asia/Kolkata'
    } || error "Failed to set timezone."
fi
echo "✓ Timezone: Asia/Kolkata"

# Ensure Ubuntu universe repository is enabled for android-sdk-platform-tools-common if needed
if [[ "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"ubuntu"* ]]; then
    if ! apt-cache show android-sdk-platform-tools-common >/dev/null 2>&1; then
        echo "Enabling Ubuntu universe repository..."
        env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get install -y --no-install-recommends software-properties-common
        add-apt-repository -y universe
        env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get update
    fi
fi

# Required packages
PACKAGES=(
    android-sdk-platform-tools-common
    build-essential
    ca-certificates
    curl
    git
    gpg
    unzip
    zip
)

# Install required packages
env DEBIAN_FRONTEND="$DEBIAN_FRONTEND" apt-get install -y "${PACKAGES[@]}"

# Verify required packages
for package in "${PACKAGES[@]}"; do
    dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null \
        | grep -q "install ok installed" ||
        error "Package '$package' is not installed."
done

echo "✓ Required packages installed"

# Cleanup
VIM_WAS_INSTALLED=0
if dpkg-query -W -f='${Status}\n' vim 2>/dev/null | grep -q "install ok installed"; then
    VIM_WAS_INSTALLED=1
    apt-get remove -y vim
    apt-get autoremove -y
    apt-get clean
fi

# Verify vim is removed
if dpkg-query -W -f='${Status}\n' vim 2>/dev/null | grep -q "install ok installed"; then
    echo "✗ vim is still installed" >&2
    exit 1
fi

if (( VIM_WAS_INSTALLED )); then
    echo "✓ vim removed"
    echo "✓ APT cleanup complete"
fi

# ------------------------------------------------------------
# Install OpenJDK
# ------------------------------------------------------------

JAVA_VERSION="$(
    curl -fsSL https://jdk.java.net/ 2>/dev/null |
        awk -F 'href="\\./' '/GA Releases/ {for(i=2;i<=NF;i++){if($i~/^[0-9]+\//){sub(/\/.*$/,"",$i);print $i;exit}}}' || true
)"
[[ -n "$JAVA_VERSION" ]] ||
    JAVA_VERSION="$(
        curl -fsSL https://jdk.java.net/ 2>/dev/null |
            grep -o 'GA Releases</div><div class="link"><a href="\./[0-9]\+/' |
            grep -o '[0-9]\+' |
            head -n 1 || true
    )"

[[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] ||
    error "Could not determine the latest OpenJDK GA version from https://jdk.java.net/."

case "$(dpkg --print-architecture)" in
    amd64)
        JAVA_ARCH="x64"
        ;;
    arm64)
        JAVA_ARCH="aarch64"
        ;;
    *)
        error "Unsupported architecture for OpenJDK: $(dpkg --print-architecture)"
        ;;
esac

JAVA_URL="$(
    curl -fsSL "https://jdk.java.net/${JAVA_VERSION}/" 2>/dev/null |
        grep -o "https://download.java.net/java/GA/jdk${JAVA_VERSION}/[^\"]*linux-${JAVA_ARCH}_bin\.tar\.gz" |
        head -n 1 || true
)"

[[ -n "$JAVA_URL" ]] ||
    error "Could not determine OpenJDK ${JAVA_VERSION} download URL from https://jdk.java.net/${JAVA_VERSION}/."

echo "Installing OpenJDK ${JAVA_VERSION}..."

JDK_DIR="/usr/local/jdk-${JAVA_VERSION}"

if [[ -d "$JDK_DIR" && -f "$JDK_DIR/.installed-from" && "$(<"$JDK_DIR/.installed-from")" == "$JAVA_URL" && -x "$JDK_DIR/bin/java" && -x "$JDK_DIR/bin/javac" ]]; then
    echo "✓ OpenJDK ${JAVA_VERSION} (latest build) already installed. Skipping download."
else
    if [[ -d "$JDK_DIR" ]]; then
        echo "Updating OpenJDK ${JAVA_VERSION} to latest build..."
    else
        echo "Downloading OpenJDK ${JAVA_VERSION}..."
    fi

    JAVA_SHA256_URL="${JAVA_URL}.sha256"

    JAVA_TMP_DIR="$(mktemp -d /tmp/java-install.XXXXXX)"
    TMP_CLEANUP_PATHS+=("$JAVA_TMP_DIR")
    JAVA_ARCHIVE="openjdk-${JAVA_VERSION}_linux-${JAVA_ARCH}_bin.tar.gz"

    curl -fSL \
        -o "$JAVA_TMP_DIR/$JAVA_ARCHIVE" \
        "$JAVA_URL"

    test -s "$JAVA_TMP_DIR/$JAVA_ARCHIVE" ||
        error "OpenJDK download failed."

    EXPECTED_SHA256="$(curl -fsSL "$JAVA_SHA256_URL" 2>/dev/null | awk '{print $1}' || true)"
    [[ -n "$EXPECTED_SHA256" ]] ||
        error "Failed to download OpenJDK ${JAVA_VERSION} SHA256 checksum."

    (
        cd "$JAVA_TMP_DIR"
        echo "$EXPECTED_SHA256  $JAVA_ARCHIVE" | sha256sum --check - >/dev/null 2>&1
    ) || error "OpenJDK ${JAVA_VERSION} SHA256 checksum verification failed."
    echo "✓ OpenJDK ${JAVA_VERSION} release checksum verified"

    # Extract to temp dir to dynamically detect top-level folder name
    JAVA_EXTRACT_DIR="$(mktemp -d /tmp/jdk-extract.XXXXXX)"
    TMP_CLEANUP_PATHS+=("$JAVA_EXTRACT_DIR")
    tar -C "$JAVA_EXTRACT_DIR" -xzf "$JAVA_TMP_DIR/$JAVA_ARCHIVE"
    EXTRACTED_JDK_DIR="$(find "$JAVA_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
    [[ -n "$EXTRACTED_JDK_DIR" && -d "$EXTRACTED_JDK_DIR" ]] ||
        error "Failed to detect extracted OpenJDK directory from archive."

    rm -rf "$JDK_DIR"
    mv "$EXTRACTED_JDK_DIR" "$JDK_DIR"
    rm -rf "$JAVA_EXTRACT_DIR" "$JAVA_TMP_DIR"

    test -x "$JDK_DIR/bin/java" ||
        error "OpenJDK java binary not found."

    test -x "$JDK_DIR/bin/javac" ||
        error "OpenJDK javac binary not found."

    echo "$JAVA_URL" > "$JDK_DIR/.installed-from"

    echo "✓ OpenJDK ${JAVA_VERSION} installed"
fi

# Remove older OpenJDK installation directories under /usr/local
for old_jdk in /usr/local/jdk-*; do
    [[ -d "$old_jdk" ]] || continue

    old_version="${old_jdk##*/jdk-}"

    if [[ "$old_version" != "$JAVA_VERSION" ]]; then
        echo "Removing old OpenJDK ${old_version}..."
        rm -rf "$old_jdk"
    fi
done

# Purge residual configuration files from removed OpenJDK packages
RESIDUAL_JDK_PACKAGES=()
while IFS= read -r pkg; do
    [[ -n "$pkg" ]] && RESIDUAL_JDK_PACKAGES+=("$pkg")
done < <(dpkg-query -W -f='${Package} ${Status}\n' 'openjdk-*' 2>/dev/null | awk '/deinstall ok config-files/ {print $1}')

if (( ${#RESIDUAL_JDK_PACKAGES[@]} > 0 )); then
    echo "Purging residual OpenJDK packages: ${RESIDUAL_JDK_PACKAGES[*]}..."
    dpkg --purge "${RESIDUAL_JDK_PACKAGES[@]}"
fi

for bin in "/usr/local/jdk-${JAVA_VERSION}/bin/"*; do
    [[ -x "$bin" ]] || continue
    ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"
done

# Remove dangling JDK symlinks in /usr/local/bin
find /usr/local/bin -xtype l -lname '/usr/local/jdk-*' -delete

test -x /usr/local/bin/java ||
    error "OpenJDK java system symlink not found."

test -x /usr/local/bin/javac ||
    error "OpenJDK javac system symlink not found."

export JAVA_HOME="/usr/local/jdk-${JAVA_VERSION}"

run_as_target bash -c "
    mkdir -p \"\$HOME/.config/environment.d\"

    cat > \"\$HOME/.config/environment.d/java.conf\" <<EOF
JAVA_HOME=$JAVA_HOME
EOF
"

echo "✓ OpenJDK JAVA_HOME configured"

# ------------------------------------------------------------
# Install Android CLI
# ------------------------------------------------------------

ANDROID_HOME="$TARGET_HOME/Android/Sdk"
ANDROID_CLI="$TARGET_HOME/.local/bin/android"

echo "Installing Android CLI for user '$TARGET_USER'..."

# Android CLI installer architecture
case "$(dpkg --print-architecture)" in
    amd64)
        ANDROID_CLI_ARCH="linux_x86_64"
        ;;
    arm64)
        ANDROID_CLI_ARCH="linux_arm64"
        ;;
    *)
        error "Unsupported architecture for Android CLI: $(dpkg --print-architecture)"
        ;;
esac

ANDROID_CLI_URL="https://dl.google.com/android/cli/latest/${ANDROID_CLI_ARCH}/install.sh"

# Ensure Android SDK and local binary directories exist
run_as_target mkdir -p "$ANDROID_HOME"
run_as_target mkdir -p "$TARGET_HOME/.local/bin"

# Install or update Android CLI
if [[ -x "$ANDROID_CLI" ]]; then
    echo "Checking for Android CLI updates..."
    run_as_target env ANDROID_HOME="$ANDROID_HOME" "$ANDROID_CLI" update ||
        echo "⚠ Android CLI update failed; keeping the existing version." >&2
else
    echo "Downloading Android CLI..."

    CLI_INSTALLER_TMP="$(mktemp /tmp/android-cli-install.XXXXXX)"
    TMP_CLEANUP_PATHS+=("$CLI_INSTALLER_TMP")
    curl -fsSL -o "$CLI_INSTALLER_TMP" "$ANDROID_CLI_URL" ||
        error "Failed to download Android CLI installer from $ANDROID_CLI_URL."

    chmod 755 "$CLI_INSTALLER_TMP"
    run_as_target bash "$CLI_INSTALLER_TMP" ||
        error "Android CLI installer script failed."

    rm -f "$CLI_INSTALLER_TMP"
fi

test -x "$ANDROID_CLI" ||
    error "Android CLI installation verification failed."

run_as_target "$ANDROID_CLI" --version >/dev/null ||
    error "Android CLI execution verification failed."

echo "✓ Android CLI installed or updated"

# Configure Android SDK location
run_as_target bash -c "
    cat > \"\$HOME/.androidrc\" <<EOF
--sdk=$ANDROID_HOME
EOF
"

export ANDROID_HOME="$ANDROID_HOME"

echo "✓ Android SDK location configured: $ANDROID_HOME"

# Resolve the latest stable numeric platform and build-tools packages.
ANDROID_PLATFORM_PACKAGE="$(
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk list --all 'platforms/android-*' 2>/dev/null |
        awk '/^  platforms\/android-[0-9]+(\.[0-9]+)?[[:space:]]/ {print $1}' |
        sort -Vu |
        tail -n 1 || true
)"

ANDROID_BUILD_TOOLS_PACKAGE="$(
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk list --all 'build-tools/*' 2>/dev/null |
        awk '/^  build-tools\/[0-9]+\.[0-9]+\.[0-9]+[[:space:]]/ {print $1}' |
        sort -Vu |
        tail -n 1 || true
)"

[[ -n "$ANDROID_PLATFORM_PACKAGE" ]] ||
    error "Could not determine the latest stable Android platform package."

[[ -n "$ANDROID_BUILD_TOOLS_PACKAGE" ]] ||
    error "Could not determine the latest stable Android build-tools package."

ANDROID_PLATFORM_VERSION="${ANDROID_PLATFORM_PACKAGE#platforms/}"
ANDROID_BUILD_TOOLS_VERSION="${ANDROID_BUILD_TOOLS_PACKAGE#build-tools/}"

# Install or update Android SDK platform-tools
INSTALLED_PLATFORM_TOOLS_VERSION="$(
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk list 'platform-tools' 2>/dev/null |
        awk '/^[[:space:]]*platform-tools[[:space:]]+/ {print $2; exit}' || true
)"

LATEST_PLATFORM_TOOLS_VERSION="$(
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk list --all 'platform-tools' 2>/dev/null |
        awk '/^[[:space:]]*platform-tools[[:space:]]+/ {ver=$2} END {print ver}' || true
)"

if [[ -n "$INSTALLED_PLATFORM_TOOLS_VERSION" && -n "$LATEST_PLATFORM_TOOLS_VERSION" && "$INSTALLED_PLATFORM_TOOLS_VERSION" == "$LATEST_PLATFORM_TOOLS_VERSION" && -x "$ANDROID_HOME/platform-tools/adb" ]]; then
    echo "✓ Android SDK platform-tools ($INSTALLED_PLATFORM_TOOLS_VERSION) already installed. Skipping."
else
    echo "Installing or updating Android SDK platform-tools..."

    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk install platform-tools
fi

if [[ -d "$ANDROID_HOME/platforms/$ANDROID_PLATFORM_VERSION" ]]; then
    echo "✓ Android SDK platform $ANDROID_PLATFORM_VERSION already installed. Skipping."
else
    echo "Installing Android SDK platform $ANDROID_PLATFORM_VERSION..."

    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk install "$ANDROID_PLATFORM_PACKAGE"
fi

# Remove older stable platform packages after the latest platform is installed.
while IFS= read -r installed_platform; do
    [[ "$installed_platform" == "$ANDROID_PLATFORM_VERSION" ]] && continue

    echo "Removing older Android SDK platform $installed_platform..."
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk remove "platforms/$installed_platform" < /dev/null
done < <(
    find "$ANDROID_HOME/platforms" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -printf '%f\n' |
        awk '/^android-[0-9]+(\.[0-9]+)?$/ {print}'
)

if [[ -d "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION" ]]; then
    echo "✓ Android SDK build-tools $ANDROID_BUILD_TOOLS_VERSION already installed. Skipping."
else
    echo "Installing Android SDK build-tools $ANDROID_BUILD_TOOLS_VERSION..."

    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" sdk install "$ANDROID_BUILD_TOOLS_PACKAGE"
fi

# Remove older build-tools packages after the latest build-tools is installed.
if [[ -d "$ANDROID_HOME/build-tools" ]]; then
    while IFS= read -r installed_build_tools; do
        [[ "$installed_build_tools" == "$ANDROID_BUILD_TOOLS_VERSION" ]] && continue

        echo "Removing older Android SDK build-tools $installed_build_tools..."
        run_as_target env \
            ANDROID_HOME="$ANDROID_HOME" \
            "$ANDROID_CLI" sdk remove "build-tools/$installed_build_tools" < /dev/null
    done < <(
        find "$ANDROID_HOME/build-tools" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            -printf '%f\n' |
            awk '/^[0-9]+(\.[0-9]+)*$/ {print}'
    )
fi

chown -R "$TARGET_USER:$TARGET_GROUP" "$ANDROID_HOME"

echo "✓ Android SDK platform-tools installed"
echo "✓ Android SDK platform $ANDROID_PLATFORM_VERSION installed"
echo "✓ Android SDK build-tools $ANDROID_BUILD_TOOLS_VERSION installed"

# Configure Android SDK environment and platform-tools PATH
run_as_target bash -c '
    mkdir -p "$HOME/.config/environment.d"
    rm -f "$HOME/.config/environment.d/android-cli.conf" "$HOME/.config/environment.d/android-platform-tools.conf"

    cat > "$HOME/.config/environment.d/android.conf" <<EOF
ANDROID_HOME=\$HOME/Android/Sdk
PATH=\$HOME/Android/Sdk/platform-tools:\$PATH
EOF
'

echo "✓ Android platform-tools and SDK environment configured"

# Verify Android CLI
android_version="$(
    run_as_target env \
        ANDROID_HOME="$ANDROID_HOME" \
        "$ANDROID_CLI" --version
)"

echo "Android CLI:"
echo "$android_version"

# Verify ADB
test -x "$ANDROID_HOME/platform-tools/adb" ||
    error "ADB installation verification failed."

# Verify fastboot
test -x "$ANDROID_HOME/platform-tools/fastboot" ||
    error "fastboot installation verification failed."

echo "✓ Android CLI verified"
echo "✓ ADB verified"
echo "✓ fastboot verified"

# ------------------------------------------------------------
# Install Antigravity CLI
# ------------------------------------------------------------

ANTIGRAVITY_CLI="$TARGET_HOME/.local/bin/agy"

echo "Installing Antigravity CLI for user '$TARGET_USER'..."

# Re-run the installer only when the CLI binary is missing; otherwise the
# existing installation is kept and merely verified below.
if [[ -x "$ANTIGRAVITY_CLI" ]]; then
    echo "✓ Antigravity CLI already installed. Skipping download."
else
    run_as_target bash -c \
        'curl -fsSL https://antigravity.google/cli/install.sh | bash'
fi

test -x "$ANTIGRAVITY_CLI" ||
    error "Antigravity CLI installation verification failed."

antigravity_version="$(
    run_as_target "$ANTIGRAVITY_CLI" --version
)"

echo "✓ Antigravity CLI verified: $antigravity_version"

# ------------------------------------------------------------
# Install Claude Code
# ------------------------------------------------------------

CLAUDE_CLI="$TARGET_HOME/.local/bin/claude"

echo "Installing Claude Code for user '$TARGET_USER'..."

# Re-run the installer only when the CLI binary is missing; otherwise the
# existing installation is kept and merely verified below.
if [[ -x "$CLAUDE_CLI" ]]; then
    echo "✓ Claude Code already installed. Skipping download."
else
    run_as_target env CLAUDE_INSTALL_ALLOW_SUDO=1 bash -c \
        'curl -fsSL https://claude.ai/install.sh | bash'
fi

test -x "$CLAUDE_CLI" ||
    error "Claude Code installation verification failed."

claude_version="$(
    run_as_target "$CLAUDE_CLI" --version
)"

echo "✓ Claude Code verified: $claude_version"

# Configure user local binary PATH
run_as_target bash -c '
    mkdir -p "$HOME/.config/environment.d"
    cat > "$HOME/.config/environment.d/local-bin.conf" <<EOF
PATH=\$HOME/.local/bin:\$PATH
EOF
'

echo "✓ User local bin PATH configured"

# ------------------------------------------------------------
# Install Go
# ------------------------------------------------------------

GO_VERSION="$(
    curl -fsSL 'https://go.dev/VERSION?m=text' 2>/dev/null |
        sed -n '1p' || true
)"

[[ "$GO_VERSION" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] ||
    error "Could not determine the latest Go version."

GO_VERSION="${GO_VERSION#go}"
case "$(dpkg --print-architecture)" in
    amd64)
        GO_ARCH="amd64"
        ;;
    arm64)
        GO_ARCH="arm64"
        ;;
    *)
        error "Unsupported architecture: $(dpkg --print-architecture)"
        ;;
esac
GO_ARCHIVE="go${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
GO_URL="https://go.dev/dl/${GO_ARCHIVE}"

echo "Installing Go ${GO_VERSION}..."

INSTALLED_GO_VERSION=""

if [[ -x /usr/local/go/bin/go ]]; then
    INSTALLED_GO_VERSION="$(
        /usr/local/go/bin/go version 2>&1 |
            awk '{print $3}' || true
    )"
fi

if [[ "$INSTALLED_GO_VERSION" == "go${GO_VERSION}" ]]; then
    echo "✓ Go ${GO_VERSION} already installed. Skipping download."
else
    if [[ -n "$INSTALLED_GO_VERSION" ]]; then
        echo "Updating Go ${INSTALLED_GO_VERSION} → go${GO_VERSION}..."
    else
        echo "Downloading Go ${GO_VERSION}..."
    fi

    GO_TMP_DIR="$(mktemp -d /tmp/go-install.XXXXXX)"
    TMP_CLEANUP_PATHS+=("$GO_TMP_DIR")
    GO_TMP="$GO_TMP_DIR/$GO_ARCHIVE"

    curl -fSL \
        -o "$GO_TMP" \
        "$GO_URL"

    test -s "$GO_TMP" ||
        error "Go download failed."

    if command -v python3 >/dev/null 2>&1; then
        GO_SHA256="$(
            curl -fsSL 'https://go.dev/dl/?mode=json' 2>/dev/null |
                python3 -c "import json, sys; data = json.load(sys.stdin); print(next((f.get('sha256', '') for rel in data for f in rel.get('files', []) if f.get('filename') == sys.argv[1]), ''))" "$GO_ARCHIVE" || true
        )"
    else
        GO_SHA256="$(
            curl -fsSL 'https://go.dev/dl/?mode=json' 2>/dev/null |
                awk -v file="$GO_ARCHIVE" '$0 ~ file {found=1} found && /"sha256":/ {gsub(/[",]/, "", $2); print $2; exit}' || true
        )"
    fi
    [[ -n "$GO_SHA256" ]] ||
        error "Could not determine SHA256 checksum for Go release $GO_ARCHIVE."

    echo "$GO_SHA256  $GO_TMP" | sha256sum --check - >/dev/null 2>&1 ||
        error "Go SHA256 checksum verification failed."

    echo "✓ Go release checksum verified"

    rm -rf /usr/local/go
    tar -C /usr/local -xzf "$GO_TMP"
    rm -rf "$GO_TMP_DIR"

    test -x /usr/local/go/bin/go ||
        error "Go installation verification failed."

    echo "✓ Go ${GO_VERSION} installed"
fi

ln -sf /usr/local/go/bin/go /usr/local/bin/go
ln -sf /usr/local/go/bin/gofmt /usr/local/bin/gofmt

# ------------------------------------------------------------
# Install Node.js + npm
# ------------------------------------------------------------

echo "Installing Node.js..."

case "$(dpkg --print-architecture)" in
    amd64)
        NODE_ARCH="x64"
        ;;
    arm64)
        NODE_ARCH="arm64"
        ;;
    *)
        error "Unsupported architecture for Node.js: $(dpkg --print-architecture)"
        ;;
esac

# Official release checksums double as the source of the latest version.
NODE_DIST_URL="https://nodejs.org/dist/latest"
NODE_SHASUMS="$(curl -fsSL "$NODE_DIST_URL/SHASUMS256.txt" 2>/dev/null || true)"

NODE_SHASUM_LINE="$(
    grep -E "  node-v[0-9]+\.[0-9]+\.[0-9]+-linux-${NODE_ARCH}\.tar\.gz$" <<< "$NODE_SHASUMS" |
        head -n 1 || true
)"

NODE_SHA256="${NODE_SHASUM_LINE%%  *}"
NODE_ARCHIVE="${NODE_SHASUM_LINE##*  }"
NODE_VERSION="$(sed -n 's/^node-\(v[0-9.]*\)-linux-.*/\1/p' <<< "$NODE_ARCHIVE")"

[[ "$NODE_SHA256" =~ ^[0-9a-f]{64}$ && "$NODE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    error "Could not determine the latest Node.js release from $NODE_DIST_URL/SHASUMS256.txt."

INSTALLED_NODE_VERSION=""
if [[ -x /usr/local/bin/node ]]; then
    INSTALLED_NODE_VERSION="$(/usr/local/bin/node --version 2>/dev/null || true)"
fi

if [[ "$INSTALLED_NODE_VERSION" == "$NODE_VERSION" ]]; then
    echo "✓ Node.js ${NODE_VERSION} already installed. Skipping download."
else
    if [[ -n "$INSTALLED_NODE_VERSION" ]]; then
        echo "Updating Node.js ${INSTALLED_NODE_VERSION} → ${NODE_VERSION}..."
    else
        echo "Downloading Node.js ${NODE_VERSION}..."
    fi

    NODE_TMP_DIR="$(mktemp -d /tmp/node-install.XXXXXX)"
    TMP_CLEANUP_PATHS+=("$NODE_TMP_DIR")
    NODE_TMP="$NODE_TMP_DIR/$NODE_ARCHIVE"

    curl -fSL \
        -o "$NODE_TMP" \
        "$NODE_DIST_URL/$NODE_ARCHIVE"

    test -s "$NODE_TMP" ||
        error "Node.js download failed."

    echo "$NODE_SHA256  $NODE_TMP" | sha256sum --check - >/dev/null 2>&1 ||
        error "Node.js ${NODE_VERSION} SHA256 checksum verification failed."

    echo "✓ Node.js release checksum verified"

    # Drop the previously bundled npm/corepack so stale files don't mix with the new release.
    rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack

    # Official layout: bin/, include/, lib/, share/ merged into /usr/local.
    tar -C /usr/local --strip-components=1 --no-same-owner \
        --exclude="${NODE_ARCHIVE%.tar.gz}/CHANGELOG.md" \
        --exclude="${NODE_ARCHIVE%.tar.gz}/LICENSE" \
        --exclude="${NODE_ARCHIVE%.tar.gz}/README.md" \
        -xzf "$NODE_TMP"
    rm -rf "$NODE_TMP_DIR"
    hash -r

    [[ "$(/usr/local/bin/node --version 2>/dev/null || true)" == "$NODE_VERSION" ]] ||
        error "Node.js installation verification failed."

    echo "✓ Node.js ${NODE_VERSION} extracted to /usr/local"
fi

node_version="$(node --version)"
npm_version="$(npm --version)"

echo "✓ Node.js $node_version installed"
echo "✓ npm $npm_version installed"

# ------------------------------------------------------------
# Update npm to the latest version
# ------------------------------------------------------------

LATEST_NPM_VERSION="$(npm view npm version 2>/dev/null || true)"

[[ "$LATEST_NPM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    error "Could not determine the latest npm version."

if [[ "$npm_version" == "$LATEST_NPM_VERSION" ]]; then
    echo "✓ npm $npm_version is already the latest version. Skipping update."
else
    echo "Updating npm $npm_version → $LATEST_NPM_VERSION..."

    npm install --global "npm@$LATEST_NPM_VERSION"

    updated_npm_version="$(npm --version)"

    [[ "$updated_npm_version" == "$LATEST_NPM_VERSION" ]] ||
        error "npm update verification failed: expected $LATEST_NPM_VERSION, got $updated_npm_version."

    echo "✓ npm $LATEST_NPM_VERSION installed"
fi
# Configure global Node.js module resolution
GLOBAL_NODE_MODULES="$(npm root -g)"
export NODE_PATH="$GLOBAL_NODE_MODULES${NODE_PATH:+:$NODE_PATH}"

run_as_target bash -c "
    mkdir -p \"\$HOME/.config/environment.d\"

    cat > \"\$HOME/.config/environment.d/node.conf\" <<EOF
NODE_PATH=$GLOBAL_NODE_MODULES
EOF
"

# ------------------------------------------------------------
# Install Firefox web-ext
# ------------------------------------------------------------

echo "Installing Firefox web-ext globally..."

LATEST_WEB_EXT_VERSION="$(npm view web-ext version 2>/dev/null || true)"
INSTALLED_WEB_EXT_VERSION=""
if command -v web-ext >/dev/null 2>&1; then
    INSTALLED_WEB_EXT_VERSION="$(web-ext --version 2>/dev/null || true)"
fi

if [[ -n "$INSTALLED_WEB_EXT_VERSION" && -n "$LATEST_WEB_EXT_VERSION" && "$INSTALLED_WEB_EXT_VERSION" == "$LATEST_WEB_EXT_VERSION" ]]; then
    echo "✓ Firefox web-ext $INSTALLED_WEB_EXT_VERSION is up to date. Skipping update."
else
    if [[ -n "$INSTALLED_WEB_EXT_VERSION" ]]; then
        echo "Updating Firefox web-ext $INSTALLED_WEB_EXT_VERSION → ${LATEST_WEB_EXT_VERSION:-latest}..."
    fi

    if [[ -n "$LATEST_WEB_EXT_VERSION" ]]; then
        npm install --global "web-ext@$LATEST_WEB_EXT_VERSION"
    else
        npm install --global web-ext
    fi

    command -v web-ext >/dev/null ||
        error "Firefox web-ext installation verification failed."

    web_ext_version="$(web-ext --version)"
    echo "✓ Firefox web-ext $web_ext_version installed globally"
fi

# ------------------------------------------------------------
# Install Playwright
# ------------------------------------------------------------

echo "Installing Playwright globally..."

LATEST_PLAYWRIGHT_VERSION="$(npm view @playwright/test version 2>/dev/null || true)"
INSTALLED_PLAYWRIGHT_VERSION=""
if command -v playwright >/dev/null 2>&1; then
    INSTALLED_PLAYWRIGHT_VERSION="$(playwright --version 2>/dev/null | awk '{print $2}' || true)"
fi

PLAYWRIGHT_UPDATED=0
if [[ -n "$INSTALLED_PLAYWRIGHT_VERSION" && -n "$LATEST_PLAYWRIGHT_VERSION" && "$INSTALLED_PLAYWRIGHT_VERSION" == "$LATEST_PLAYWRIGHT_VERSION" ]]; then
    echo "✓ Playwright $INSTALLED_PLAYWRIGHT_VERSION is up to date. Skipping update."
else
    if [[ -n "$INSTALLED_PLAYWRIGHT_VERSION" ]]; then
        echo "Updating Playwright $INSTALLED_PLAYWRIGHT_VERSION → ${LATEST_PLAYWRIGHT_VERSION:-latest}..."
    fi

    if [[ -n "$LATEST_PLAYWRIGHT_VERSION" ]]; then
        npm install --global "@playwright/test@$LATEST_PLAYWRIGHT_VERSION"
    else
        npm install --global @playwright/test
    fi

    command -v playwright >/dev/null ||
        error "Playwright installation verification failed."

    PLAYWRIGHT_UPDATED=1
    playwright_version="$(playwright --version)"
    echo "✓ Playwright $playwright_version installed globally"
fi

echo "Installing Playwright system dependencies..."
playwright install-deps

PLAYWRIGHT_LOCATIONS_COUNT=0
PLAYWRIGHT_BROWSERS_MISSING=0
while IFS= read -r browser_dir; do
    [[ -z "$browser_dir" ]] && continue
    ((PLAYWRIGHT_LOCATIONS_COUNT++)) || true
    if [[ ! -d "$browser_dir" ]]; then
        PLAYWRIGHT_BROWSERS_MISSING=1
        break
    fi
done < <(run_as_target playwright install --dry-run 2>/dev/null | awk '/Install location:/ {print $3}')

if (( PLAYWRIGHT_LOCATIONS_COUNT > 0 && PLAYWRIGHT_UPDATED == 0 && PLAYWRIGHT_BROWSERS_MISSING == 0 )); then
    echo "✓ Playwright browser binaries already installed for user '$TARGET_USER'. Skipping."
else
    echo "Installing Playwright browser binaries for user '$TARGET_USER'..."
    run_as_target playwright install
    chown -R "$TARGET_USER:$TARGET_GROUP" "$TARGET_HOME/.cache/ms-playwright" 2>/dev/null || true
fi

# ------------------------------------------------------------
# Configure permanent environment variables for the target user
# ------------------------------------------------------------

run_as_target TARGET_SHELL="$TARGET_SHELL" bash -c '
    TARGET_FILES=("$HOME/.profile" "$HOME/.bashrc")
    [[ -f "$HOME/.bash_profile" ]] && TARGET_FILES+=("$HOME/.bash_profile")
    [[ -f "$HOME/.bash_login" ]] && TARGET_FILES+=("$HOME/.bash_login")
    if [[ "$TARGET_SHELL" == *"zsh"* || -f "$HOME/.zshenv" ]]; then
        TARGET_FILES+=("$HOME/.zshenv")
    fi

    for startup_file in "${TARGET_FILES[@]}"; do
        touch "$startup_file"
        sed -i "/^# >>> dev-env >>>\$/,/^# <<< dev-env <<<\$/d" "$startup_file"
        cat >> "$startup_file" <<'\''EOF'\''
# >>> dev-env >>>
# Load environment configurations from ~/.config/environment.d
if [ -z "${DEV_ENV_LOADED:-}" ] && [ -d "$HOME/.config/environment.d" ]; then
    set -a
    for env_file in "$HOME/.config/environment.d"/*.conf; do
        [ -r "$env_file" ] && . "$env_file"
    done
    set +a
    unset env_file
    export DEV_ENV_LOADED=1
fi
# <<< dev-env <<<
EOF
    done
'

echo "✓ Permanent environment variables configured"

# Final verification
echo
echo "================================"
echo "Verifying installations..."
echo "================================"

echo
echo "Timezone:"
if [[ -d /run/systemd/system ]] && command -v timedatectl >/dev/null 2>&1; then
    timedatectl show --property=Timezone --value
else
    cat /etc/timezone 2>/dev/null || readlink /etc/localtime
fi

echo
echo "Android SDK:"

test -d "$ANDROID_HOME" ||
    error "Android SDK directory not found."

test -x "$ANDROID_HOME/platform-tools/adb" ||
    error "ADB not found."

test -x "$ANDROID_HOME/platform-tools/fastboot" ||
    error "fastboot not found."

test -d "$ANDROID_HOME/platforms/$ANDROID_PLATFORM_VERSION" ||
    error "Android SDK platform $ANDROID_PLATFORM_VERSION not found."

test -x "$ANDROID_HOME/build-tools/$ANDROID_BUILD_TOOLS_VERSION/aapt" ||
    error "Android SDK build-tools $ANDROID_BUILD_TOOLS_VERSION not found."

test -x "$ANDROID_CLI" ||
    error "Android CLI binary not found."

android_version="$(
    run_as_target bash -c \
        "'$ANDROID_CLI' --version"
)"

adb_version="$(
    run_as_target bash -c \
        "'$ANDROID_HOME/platform-tools/adb' version"
)"

fastboot_version="$(
    run_as_target bash -c \
        "'$ANDROID_HOME/platform-tools/fastboot' --version"
)"

echo "Android CLI: $android_version"
echo "$adb_version"
echo "$fastboot_version"

echo "✓ Android CLI verified"
echo "✓ Android platform-tools verified"
echo "✓ ADB verified"
echo "✓ fastboot verified"
echo "✓ Android SDK platform $ANDROID_PLATFORM_VERSION verified"
echo "✓ Android SDK build-tools $ANDROID_BUILD_TOOLS_VERSION verified"

echo
echo "Antigravity CLI:"
test -x "$ANTIGRAVITY_CLI" ||
    error "Antigravity CLI binary not found."

antigravity_ver="$(
    run_as_target "$ANTIGRAVITY_CLI" --version
)"

echo "$antigravity_ver"
echo "✓ Antigravity CLI verified"

echo
echo "Claude Code:"
test -x "$CLAUDE_CLI" ||
    error "Claude Code binary not found."

claude_ver="$(
    run_as_target "$CLAUDE_CLI" --version
)"

echo "$claude_ver"
echo "✓ Claude Code verified"

echo
echo "Firefox web-ext:"
command -v web-ext >/dev/null ||
    error "Firefox web-ext is not available."
web-ext --version
echo "✓ Firefox web-ext verified globally"

echo
echo "Git:"
command -v git >/dev/null 2>&1 ||
    error "Git is not available."

git_version="$(git --version)"
echo "$git_version"
echo "✓ Git verified"

echo
echo "Go:"
command -v go >/dev/null 2>&1 ||
    error "Go binary not found."
command -v gofmt >/dev/null 2>&1 ||
    error "gofmt binary not found."

go_version="$(go version 2>&1)"
echo "$go_version"
echo "gofmt: verified"
echo "✓ Go verified"

echo
echo "Node.js:"
node --version
npm --version
echo "✓ Node.js verified"
echo "✓ npm verified"

echo
echo "OpenJDK:"
test -n "${JAVA_HOME:-}" && test -d "$JAVA_HOME" ||
    error "OpenJDK installation directory not found."

test -x "$JAVA_HOME/bin/java" ||
    error "OpenJDK java binary not found."

test -x "$JAVA_HOME/bin/javac" ||
    error "OpenJDK javac binary not found."

test -x /usr/local/bin/java ||
    error "OpenJDK java system symlink not found."

test -x /usr/local/bin/javac ||
    error "OpenJDK javac system symlink not found."

java -version >/dev/null 2>&1 ||
    error "OpenJDK installation verification failed."

javac -version >/dev/null 2>&1 ||
    error "OpenJDK compiler verification failed."

java_version="$(java -version 2>&1 | head -n 1)"
javac_version="$(javac -version 2>&1)"

echo "$java_version"
echo "$javac_version"
echo "✓ OpenJDK verified"

echo
echo "Playwright:"
command -v playwright >/dev/null ||
    error "Playwright is not available."
playwright --version
echo "✓ Playwright verified globally"

echo
echo "=========================================="
echo "✓ All installations verified successfully"
echo "=========================================="
