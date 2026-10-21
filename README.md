# Development Environment

An automated, idempotent bootstrap script for provisioning a developer workstation and AI agent harness on Debian, Ubuntu, and Debian-based Linux distributions.

Designed for modern Linux environments running **Debian, Ubuntu, or derivatives**, including **ChromeOS (Crostini)** and **Android pKVM (Android Virtualization Framework)**.

Supports both **`amd64` (x86_64)** and **`arm64` (aarch64)** architectures.

---

## Quick Start

```bash
git clone <repo-url>
cd dev-env
chmod +x setup.sh
./setup.sh
```

> **Note**: The script requires root privileges to configure APT packages and system symlinks. If executed as a standard user, it will automatically prompt for `sudo`. User-space runtimes and caches are cleanly installed under the target user's home directory (`$HOME`).

---

## What's Included

| Component | Description | Installation Source |
|---|---|---|
| **Android SDK & CLI** | Android CLI, Platform-Tools (`adb`, `fastboot`), Build-Tools (`aapt`), Latest Platform, Android Emulator (no system images or virtual devices; `android emulator create <profile>` downloads the image it needs) | Google Android CLI installer |
| **Antigravity CLI** | Google Antigravity CLI (`agy`) | Official Google installer |
| **Base Build & System Tools** | `acl` (`setfacl`, for immediate `/dev/kvm` and `/dev/dri` access), `android-sdk-platform-tools-common` (udev device rules for non-root `adb`/`fastboot`), `build-essential`, `ca-certificates`, `curl`, `gpg`, `mesa-utils` (`eglinfo`, to check GPU acceleration), `unzip`, `zip` | APT repository |
| **Claude Code** | Anthropic's agentic coding CLI (`claude`) | Official Anthropic installer |
| **Firefox web-ext** | Mozilla WebExtension CLI | Global npm package |
| **Git** | Distributed version control system | APT repository |
| **Go** | Latest stable Go compiler & tooling (`go`, `gofmt`) | Official precompiled binary (`go.dev/dl`) with SHA-256 verification |
| **Node.js & npm** | Latest Node.js runtime & npm package manager | Official precompiled tarball (`nodejs.org/dist`) with SHA-256 verification |
| **OpenJDK** | Latest GA Java Development Kit (`javac`, `java`) | Official OpenJDK precompiled binary (`jdk.java.net`) with SHA-256 verification |
| **Playwright** | End-to-end testing framework with Chromium, Firefox & WebKit browser engines | Global npm package (`@playwright/test`) |

---

## Features & Architecture

- **100% Idempotent**: Safe to run repeatedly. It skips existing components that match the latest version, updates tools that have newer releases available, and maintains existing user settings.
- **Multi-Architecture**: Automatically detects CPU architecture (`amd64` vs `arm64`) and selects architecture-specific binaries for Go, OpenJDK, and Android SDK.
- **Privilege Separation**: System-level packages and `/usr/local/bin` symlinks are configured with root privileges, while user configs, Android SDK, and agent environments are installed directly under the invoking user (`$TARGET_HOME`) with proper ownership (`chown`).
- **Modern Environment Integration**:
  - Sets up systemd user environment generators in `~/.config/environment.d/` (`android.conf`, `java.conf`, `local-bin.conf`, `node.conf`).
  - Loads environment configurations dynamically across login and interactive shells (`~/.profile`, `~/.bashrc`, and `~/.zshenv` for Zsh users) guarded by idempotent delimiters and reload guards.
  - Prioritizes security and privilege separation: system-wide toolchains (`go`, `gofmt`, `java`, `javac`) are linked into `/usr/local/bin`, while user-space binaries (`android`, `adb`, `fastboot`, `agy`, `claude`) remain securely scoped to the user's home and PATH without exposing user-owned binaries to root.
- **System Cleanup**: Removes `vim` if installed, then runs `apt-get autoremove -y` to clear its leftover dependencies (e.g. `vim-runtime`, `libsodium23`). Note that `autoremove` also removes any other packages APT considers no longer needed.
- **GPU Device Access**: Adds the target user to the `render` and `video` groups (when they exist) so GPU-accelerated tools can open `/dev/dri` in sessions without a logind seat, such as ChromeOS Linux, SSH or CI. The current session gets access right away via ACLs; new groups take effect after logging out or fully shutting down the Linux VM.
- **KVM for the Android Emulator**: When hardware virtualization and `/dev/kvm` are available (including nested KVM on ChromeOS Linux), adds the target user to the `kvm` group, grants the current session access via an ACL, and verifies that `/dev/kvm` opens read/write. KVM is used only for Android emulator acceleration, so when it is missing or cannot be opened (e.g. VMs or platforms without nested virtualization) setup continues with a warning and the emulator runs without acceleration.
- **Integrity Verification**: Downloads prebuilt release assets with SHA-256 checksum verification (`sha256sum --check`).
- **Comprehensive Verification Suite**: Runs end-to-end execution checks on all installed compilers, SDKs, and CLI tools at the conclusion of the setup.

---

## System Requirements

- **Operating System**: Debian, Ubuntu, or any compatible Debian-based distribution (including ChromeOS Crostini `penguin` and Android pKVM Linux Terminal).
- **Architecture**: `amd64` (x86_64) or `arm64` (aarch64).
- **Disk Space**: Minimum **8 GB** available on `/` (required for Android SDK components, the Android Emulator, JDK, and toolchains). Emulator system images and virtual devices are not installed by the script; budget roughly 4 GB per system image and 3–9 GB per virtual device on top.
- **Privileges**: Root access or `sudo` capability.
- **GPU Acceleration on ChromeOS** (optional, used by the Android Emulator): enable `chrome://flags/#crostini-gpu-support`, then fully restart Linux (right-click Terminal → *Shut down Linux*, or restart the Chromebook). On containerless Linux (Baguette), if `/dev/dri` is still missing, start the VM with the GPU from crosh (`Ctrl+Alt+T`): `vmc list`, `vmc stop <vm-name>`, then `vmc start --enable-gpu --vm-type BAGUETTE <vm-name>`. Check with `eglinfo -B -p surfaceless`; an `llvmpipe` renderer means software rendering.

---

## Verification

The script automatically validates all installations before completing. You can also manually verify key components:

```bash
adb version && fastboot --version
agy --version
android --version
~/Android/Sdk/emulator/emulator -version && ~/Android/Sdk/emulator/emulator -accel-check
claude --version
eglinfo -B -p surfaceless | grep 'OpenGL core profile renderer'   # llvmpipe = no GPU acceleration
git --version
go version
java -version && javac -version
node --version && npm --version
playwright --version
web-ext --version
```

---

## License

This project is licensed under the [MIT License](LICENSE).
