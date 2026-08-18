#!/usr/bin/env bash
#
# Software Development course -- Linux setup
#
# Installs the Java toolchain: Eclipse Temurin JDK 25 (LTS), IntelliJ IDEA and
# Visual Studio Code.
#
# Git is deliberately NOT installed or configured by this script. Git is the
# bootstrap prerequisite -- you already used it to clone this repo (see README.md,
# Stage 0). The script only checks that Git is present and warns about missing
# settings; you run those commands yourself. That is part of the course.
#
# The script is idempotent: run it as many times as you like. Anything already
# installed is detected and skipped.
#
# Usage:
#   ./install-linux.sh [--skip-vscode] [--jdk-version N] [--dry-run]
#                      [--non-interactive] [--help]

set -euo pipefail

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

SKIP_VSCODE=false
JDK_VERSION=25
DRY_RUN=false
NON_INTERACTIVE=false

REQUIRED_FREE_GB=10
ADOPTIUM_INFO_URL="https://api.adoptium.net/v3/info/available_releases"
JETBRAINS_RELEASES_URL="https://data.services.jetbrains.com/products/releases?code=IIU&latest=true&type=release"
IDEA_PREFIX="/opt/idea"
INOTIFY_TARGET=524288

usage() {
    sed -n '2,22p' "$0" | sed 's/^#\ \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-vscode)      SKIP_VSCODE=true ;;
        --jdk-version)      JDK_VERSION="${2:?--jdk-version needs a number}"; shift ;;
        --dry-run)          DRY_RUN=true ;;
        --non-interactive)  NON_INTERACTIVE=true ;;
        -h|--help)          usage ;;
        *) echo "Unknown option: $1  (try --help)" >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Output helpers
#
# ASCII status markers rather than emoji, so the output stays aligned in a plain
# TTY, over SSH and in the log file.
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_CYAN=$'\033[36m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_GREY=$'\033[90m'; C_MAGENTA=$'\033[35m'
else
    C_RESET=''; C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_GREY=''; C_MAGENTA=''
fi

phase() { printf '\n%s=== %s %s%s\n' "$C_CYAN" "$1" "$(printf '=%.0s' $(seq 1 $((74 - ${#1} > 0 ? 74 - ${#1} : 1))))" "$C_RESET"; }
step()  { printf '  %s...  %s%s\n' "$C_GREY"   "$1" "$C_RESET"; }
ok()    { printf '  %sOK   %s%s\n' "$C_GREEN"  "$1" "$C_RESET"; }
skip()  { printf '  %s--   %s%s\n' "$C_GREY"   "$1" "$C_RESET"; }
warn()  { printf '  %sWARN %s%s\n' "$C_YELLOW" "$1" "$C_RESET"; }
bad()   { printf '  %sFAIL %s%s\n' "$C_RED"    "$1" "$C_RESET"; }

RESULTS=()
add_result() { RESULTS+=("$1|$2|$3"); }

# Stops the script with a message a first-year student can act on.
stop_with_guidance() {
    local problem="$1"; shift
    printf '\n  %sSetup cannot continue.%s\n\n' "$C_RED" "$C_RESET"
    printf '  %sProblem: %s%s\n\n' "$C_RED" "$problem" "$C_RESET"
    printf '  %sHow to fix it:%s\n' "$C_YELLOW" "$C_RESET"
    local line
    for line in "$@"; do printf '    %s%s%s\n' "$C_YELLOW" "$line" "$C_RESET"; done
    printf '\n'
    finish 1
}

# ---------------------------------------------------------------------------
# Root / filesystem helpers
# ---------------------------------------------------------------------------

run_root() {
    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] $*"
        return 0
    fi
    if [[ "$(id -u)" -eq 0 ]]; then "$@"; else sudo "$@"; fi
}

# Writes stdin to a root-owned file. Needed because `sudo cmd > /root/path`
# redirects as the *calling* user and fails; the redirect must happen inside sudo.
write_root_file() {
    local path="$1"
    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] write $path"
        cat > /dev/null
        return 0
    fi
    if [[ "$(id -u)" -eq 0 ]]; then cat > "$path"; else sudo tee "$path" > /dev/null; fi
}

have() { command -v "$1" > /dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Phase 1 -- Preflight
# ---------------------------------------------------------------------------

detect_platform() {
    if [[ ! -r /etc/os-release ]]; then
        stop_with_guidance "Cannot read /etc/os-release, so the Linux distribution is unknown." \
            "This script supports Debian/Ubuntu and Fedora/RHEL families." \
            "Install the JDK, IntelliJ IDEA and VS Code by hand, or ask your instructor."
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"
    DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"
    # Linux Mint and some derivatives set only UBUNTU_CODENAME, so the naive
    # one-liner from the Adoptium docs produces a broken apt source there.
    CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    RELEASEVER="${VERSION_ID:-}"

    case " $DISTRO_ID $DISTRO_LIKE " in
        *debian*|*ubuntu*)            FAMILY=debian ;;
        *fedora*|*rhel*|*centos*)     FAMILY=rhel ;;
        *)                            FAMILY=other ;;
    esac

    case "$(uname -m)" in
        x86_64)         ADOPT_ARCH=x64;      JB_KEY=linux ;;
        aarch64|arm64)  ADOPT_ARCH=aarch64;  JB_KEY=linuxARM64 ;;
        *) stop_with_guidance "Unsupported CPU architecture: $(uname -m)." \
               "This course needs x86_64 or arm64. Contact your instructor." ;;
    esac

    ok "$DISTRO_NAME  (family: $FAMILY, arch: $(uname -m))"
}

check_prerequisites() {
    local missing=()
    for tool in curl tar; do have "$tool" || missing+=("$tool"); done

    if [[ ${#missing[@]} -gt 0 ]]; then
        local installer="sudo apt install ${missing[*]}"
        [[ "$FAMILY" == rhel ]] && installer="sudo dnf install ${missing[*]}"
        stop_with_guidance "Missing required tool(s): ${missing[*]}" \
            "Install them first:" \
            "  $installer" \
            "Then run this script again."
    fi
    ok "Required tools present: curl, tar"
}

check_root_access() {
    if [[ "$(id -u)" -eq 0 ]]; then
        ok "Running as root."
        return
    fi
    if ! have sudo; then
        stop_with_guidance "sudo is not installed and you are not root." \
            "Run this script as root, or install sudo first."
    fi
    if [[ "$DRY_RUN" == true ]]; then
        skip "Skipping the sudo check (--dry-run)."
        return
    fi
    # Prompt once, up front, instead of surprising the student mid-download.
    step "This script needs administrator rights. You may be asked for your password."
    if ! sudo -v; then
        stop_with_guidance "Could not obtain administrator rights via sudo." \
            "Ask whoever owns this machine for an account that can use sudo."
    fi
    ok "Administrator rights confirmed."
}

check_disk_space() {
    local free_kb free_gb
    free_kb=$(df -Pk /usr | awk 'NR==2 {print $4}')
    free_gb=$(( free_kb / 1024 / 1024 ))
    if [[ "$free_gb" -lt "$REQUIRED_FREE_GB" ]]; then
        stop_with_guidance "Only ${free_gb} GB free on the filesystem holding /usr (need ${REQUIRED_FREE_GB} GB)." \
            "Free up disk space and run this script again."
    fi
    ok "Disk space: ${free_gb} GB free"
}

# ---------------------------------------------------------------------------
# The Git gate.
#
# This script never installs and never reconfigures Git. Git is Stage 0 in the
# README, and cloning this repo is Stage 1 -- so if you are reading this from a
# clone, Git is already here. We check, we warn, we do not fix.
# ---------------------------------------------------------------------------

check_git_prerequisite() {
    if ! have git; then
        local installer="sudo apt install git"
        [[ "$FAMILY" == rhel ]] && installer="sudo dnf install git"
        stop_with_guidance "Git is not installed, or is not on your PATH." \
            "Git is a prerequisite for this course -- this script does not install it." \
            "" \
            "Install it with:" \
            "  $installer" \
            "" \
            "Then run this script again."
    fi

    local version; version="$(git --version)"
    ok "$version  ($(command -v git))"
    add_result "Git (prerequisite)" "OK" "$version"

    # Recommended settings. We report them; you set them. See GIT-QUICKSTART.md.
    local missing=() setting
    for setting in user.name user.email; do
        if ! git config --global --get "$setting" > /dev/null 2>&1; then missing+=("$setting"); fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        warn "Git is installed but these global settings are unset: ${missing[*]}"
        warn "Until user.name and user.email are set, Git will refuse to commit."
        warn "Set them yourself -- the exact commands are in GIT-QUICKSTART.md."
        add_result "Git config" "WARN" "Unset: ${missing[*]} -- see GIT-QUICKSTART.md"
    else
        add_result "Git config" "OK" "Identity: $(git config --global --get user.name)"
        ok "Git identity configured ($(git config --global --get user.name))."
    fi
}

check_connectivity() {
    step "Checking internet connectivity..."
    local info
    if ! info="$(curl -fsSL --max-time 20 "$ADOPTIUM_INFO_URL")"; then
        stop_with_guidance "Could not reach the internet." \
            "Check your network connection and try again." \
            "On a school or corporate network, a proxy may be blocking the download." \
            "See TROUBLESHOOTING.md, section \"Corporate proxy / TLS interception\"."
    fi
    ok "Internet connection OK."

    local lts; lts="$(printf '%s' "$info" | grep -o '"most_recent_lts":[0-9]*' | grep -o '[0-9]*$' || true)"
    if [[ -n "$lts" && "$lts" != "$JDK_VERSION" ]]; then
        warn "You are installing JDK $JDK_VERSION; the current LTS is $lts."
        warn "That is fine if your course asked for it. Otherwise drop --jdk-version."
    fi
}

check_display() {
    if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
        warn "No graphical desktop detected (no \$DISPLAY or \$WAYLAND_DISPLAY)."
        warn "Everything will still install, but IntelliJ IDEA will not open here."
        warn "If this is WSL, see TROUBLESHOOTING.md, section \"WSL / headless\"."
        HEADLESS=true
    else
        HEADLESS=false
    fi
}

preflight() {
    phase "Phase 1/7  Preflight checks"
    detect_platform
    check_prerequisites
    check_root_access
    check_disk_space
    check_git_prerequisite
    check_connectivity
    check_display
}

# ---------------------------------------------------------------------------
# Phase 3 -- Install: JDK
# ---------------------------------------------------------------------------

apt_candidate_exists() {
    local pkg="$1" candidate
    candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')"
    [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_jdk_debian_repo() {
    if [[ -z "$CODENAME" ]]; then
        warn "Could not determine the distribution codename; skipping the Adoptium apt repo."
        return 1
    fi

    step "Adding the Adoptium apt repository (codename: $CODENAME)..."
    run_root install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | write_root_file /etc/apt/keyrings/adoptium.asc
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] https://packages.adoptium.net/artifactory/deb ${CODENAME} main" \
        | write_root_file /etc/apt/sources.list.d/adoptium.list

    run_root apt-get update -qq || true

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] apt-get install -y temurin-${JDK_VERSION}-jdk"
        return 0
    fi

    if ! apt_candidate_exists "temurin-${JDK_VERSION}-jdk"; then
        # Leave no broken source behind, or every later apt call inherits the failure.
        warn "temurin-${JDK_VERSION}-jdk is not available for $CODENAME; removing the repo again."
        run_root rm -f /etc/apt/sources.list.d/adoptium.list
        run_root apt-get update -qq || true
        return 1
    fi

    run_root apt-get install -y "temurin-${JDK_VERSION}-jdk"
}

install_jdk_rhel_repo() {
    local base
    case "$DISTRO_ID" in
        fedora) base="https://packages.adoptium.net/artifactory/rpm/fedora/\$releasever/\$basearch" ;;
        *)      base="https://packages.adoptium.net/artifactory/rpm/rhel/\$releasever/\$basearch" ;;
    esac

    step "Adding the Adoptium dnf repository..."
    write_root_file /etc/yum.repos.d/adoptium.repo <<EOF
[Adoptium]
name=Adoptium
baseurl=$base
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] dnf install -y temurin-${JDK_VERSION}-jdk"
        return 0
    fi

    run_root dnf install -y "temurin-${JDK_VERSION}-jdk" || {
        warn "temurin-${JDK_VERSION}-jdk is not available from the Adoptium dnf repo."
        run_root rm -f /etc/yum.repos.d/adoptium.repo
        return 1
    }
}

# Universal fallback: works on any distribution, including ones with no Adoptium
# packages at all. Nothing here depends on the package manager.
install_jdk_tarball() {
    local url="https://api.adoptium.net/v3/binary/latest/${JDK_VERSION}/ga/linux/${ADOPT_ARCH}/jdk/hotspot/normal/eclipse"
    step "Falling back to the Adoptium tarball for JDK ${JDK_VERSION} (${ADOPT_ARCH})..."

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] download $url and extract to /opt/java/temurin-${JDK_VERSION}"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    if ! curl -fL --retry 3 --progress-bar -o "$tmp/jdk.tar.gz" "$url"; then
        bad "Could not download the JDK tarball."
        return 1
    fi

    mkdir -p "$tmp/x"
    tar -xzf "$tmp/jdk.tar.gz" -C "$tmp/x"

    local extracted; extracted="$(find "$tmp/x" -maxdepth 1 -mindepth 1 -type d | head -1)"
    if [[ -z "$extracted" || ! -x "$extracted/bin/javac" ]]; then
        bad "The downloaded archive does not look like a JDK (no bin/javac)."
        return 1
    fi

    local target="/opt/java/temurin-${JDK_VERSION}"
    run_root mkdir -p /opt/java
    run_root rm -rf "$target"
    run_root cp -a "$extracted" "$target"
    run_root ln -sfn "$target" /opt/java/current

    # Make it the system default where the distribution supports alternatives.
    if have update-alternatives; then
        run_root update-alternatives --install /usr/bin/java  java  "$target/bin/java"  2000 || true
        run_root update-alternatives --install /usr/bin/javac javac "$target/bin/javac" 2000 || true
    fi

    ok "JDK installed to $target"
}

install_jdk() {
    if have javac && [[ "$(version_major "$(javac -version 2>&1)")" == "$JDK_VERSION" ]]; then
        skip "JDK $JDK_VERSION is already installed."
        add_result "Temurin JDK $JDK_VERSION" "SKIPPED" "Already installed"
        return 0
    fi

    local installed=false
    case "$FAMILY" in
        debian) install_jdk_debian_repo && installed=true ;;
        rhel)   install_jdk_rhel_repo   && installed=true ;;
        *)      warn "Unrecognised distribution family; going straight to the tarball." ;;
    esac

    if [[ "$installed" != true ]]; then
        install_jdk_tarball && installed=true
    fi

    if [[ "$installed" == true ]]; then
        add_result "Temurin JDK $JDK_VERSION" "OK" "Installed"
    else
        bad "Could not install the JDK by any method."
        add_result "Temurin JDK $JDK_VERSION" "FAIL" "All install methods failed"
    fi
}

# ---------------------------------------------------------------------------
# Phase 3 -- Install: IntelliJ IDEA
#
# JetBrains publish no apt or dnf repository, so we take the official tarball and
# verify its published SHA-256 before unpacking anything. This is preferred over
# snap because it also works on Fedora and Arch, where snap is not installed.
# ---------------------------------------------------------------------------

install_intellij() {
    if [[ -x "$IDEA_PREFIX/bin/idea.sh" ]]; then
        skip "IntelliJ IDEA is already installed at $IDEA_PREFIX."
        add_result "IntelliJ IDEA" "SKIPPED" "Already installed"
        return 0
    fi

    step "Looking up the latest IntelliJ IDEA release..."
    local meta url
    if ! meta="$(curl -fsSL --max-time 30 "$JETBRAINS_RELEASES_URL")"; then
        bad "Could not reach the JetBrains release API."
        add_result "IntelliJ IDEA" "FAIL" "JetBrains release API unreachable"
        return 1
    fi

    # Matches only "linux":{"link":"..."} / "linuxARM64":{"link":"..."}, not the
    # unrelated "linux":"https://.../uninstall/..." entries elsewhere in the JSON.
    url="$(printf '%s' "$meta" \
        | grep -o "\"${JB_KEY}\":{\"link\":\"[^\"]*\"" \
        | head -1 | sed 's/.*"link":"//; s/"$//')"

    if [[ -z "$url" ]]; then
        bad "Could not find a ${JB_KEY} download link in the JetBrains release data."
        add_result "IntelliJ IDEA" "FAIL" "No $JB_KEY download link"
        return 1
    fi

    # Refuse anything that did not come from JetBrains' own download host, in case
    # the JSON shape changes and the pattern above latches onto the wrong field.
    if [[ "$url" != https://download.jetbrains.com/* ]]; then
        bad "Unexpected download URL from the JetBrains API: $url"
        add_result "IntelliJ IDEA" "FAIL" "Refused unexpected download URL"
        return 1
    fi

    local filename version
    filename="$(basename "$url")"                   # idea-2026.2.1.tar.gz
    version="${filename#idea-}"
    version="${version%.tar.gz}"
    version="${version%-aarch64}"                   # keep the arm64 dir name tidy
    ok "Latest IntelliJ IDEA: $version"

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] download $url"
        step "[dry run] verify SHA-256, extract to ${IDEA_PREFIX}-${version}, link $IDEA_PREFIX"
        add_result "IntelliJ IDEA" "SKIPPED" "Dry run ($version)"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN

    step "Downloading IntelliJ IDEA $version (about 1.6 GB)..."
    if ! curl -fL --retry 3 --progress-bar -o "$tmp/$filename" "$url"; then
        bad "Download failed."
        add_result "IntelliJ IDEA" "FAIL" "Download failed"
        return 1
    fi

    step "Verifying the download..."
    local expected actual
    expected="$(curl -fsSL "${url}.sha256" | awk '{print $1}')"
    actual="$(sha256sum "$tmp/$filename" | awk '{print $1}')"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        bad "SHA-256 mismatch -- the download is corrupt or tampered with. Nothing was installed."
        bad "  expected: ${expected:-<none>}"
        bad "  actual:   $actual"
        add_result "IntelliJ IDEA" "FAIL" "SHA-256 mismatch"
        return 1
    fi
    ok "Checksum verified."

    mkdir -p "$tmp/x"
    tar -xzf "$tmp/$filename" -C "$tmp/x"
    local extracted; extracted="$(find "$tmp/x" -maxdepth 1 -mindepth 1 -type d | head -1)"
    if [[ -z "$extracted" || ! -x "$extracted/bin/idea.sh" ]]; then
        bad "The archive does not contain bin/idea.sh."
        add_result "IntelliJ IDEA" "FAIL" "Unexpected archive layout"
        return 1
    fi

    local target="${IDEA_PREFIX}-${version}"
    run_root rm -rf "$target"
    run_root cp -a "$extracted" "$target"
    run_root ln -sfn "$target" "$IDEA_PREFIX"
    run_root ln -sfn "$IDEA_PREFIX/bin/idea.sh" /usr/local/bin/idea

    write_root_file /usr/share/applications/intellij-idea.desktop <<EOF
[Desktop Entry]
Type=Application
Name=IntelliJ IDEA
Comment=Java IDE for the Software Development course
Icon=$IDEA_PREFIX/bin/idea.svg
Exec=$IDEA_PREFIX/bin/idea.sh %f
Terminal=false
Categories=Development;IDE;
StartupWMClass=jetbrains-idea
EOF
    run_root chmod 0644 /usr/share/applications/intellij-idea.desktop

    ok "IntelliJ IDEA $version installed to $target"
    ok "Start it with:  idea"
    add_result "IntelliJ IDEA" "OK" "$version at $target"
}

# ---------------------------------------------------------------------------
# Phase 3 -- Install: Visual Studio Code
# ---------------------------------------------------------------------------

install_vscode() {
    if [[ "$SKIP_VSCODE" == true ]]; then
        skip "Visual Studio Code skipped (--skip-vscode)."
        add_result "Visual Studio Code" "SKIPPED" "Skipped by --skip-vscode"
        return 0
    fi

    if have code; then
        skip "Visual Studio Code is already installed."
        add_result "Visual Studio Code" "SKIPPED" "Already installed"
        return 0
    fi

    case "$FAMILY" in
        debian)
            if ! have gpg; then
                warn "gpg is not installed, so the Microsoft repository key cannot be added."
                warn "Install gpg (sudo apt install gnupg) and re-run to get VS Code."
                add_result "Visual Studio Code" "WARN" "Skipped: gpg not installed"
                return 0
            fi
            step "Adding the Microsoft apt repository..."
            curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
                | gpg --dearmor \
                | write_root_file /usr/share/keyrings/microsoft.gpg
            run_root chmod 0644 /usr/share/keyrings/microsoft.gpg
            echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" \
                | write_root_file /etc/apt/sources.list.d/vscode.list
            run_root apt-get update -qq || true
            run_root apt-get install -y code
            ;;
        rhel)
            step "Adding the Microsoft dnf repository..."
            run_root rpm --import https://packages.microsoft.com/keys/microsoft.asc
            write_root_file /etc/yum.repos.d/vscode.repo <<'EOF'
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
            run_root dnf install -y code
            ;;
        *)
            warn "No VS Code package source for this distribution."
            warn "Install it yourself from https://code.visualstudio.com/download"
            add_result "Visual Studio Code" "WARN" "Unsupported distribution -- install manually"
            return 0
            ;;
    esac

    if [[ "$DRY_RUN" == true ]]; then
        add_result "Visual Studio Code" "SKIPPED" "Dry run"
    else
        ok "Visual Studio Code installed."
        add_result "Visual Studio Code" "OK" "Installed"
    fi
}

install_components() {
    phase "Phase 3/7  Installing components"
    install_jdk      || true
    install_intellij || true
    install_vscode   || true
}

# ---------------------------------------------------------------------------
# Phase 4 -- Configure
# ---------------------------------------------------------------------------

find_java_home() {
    local candidate
    # Prefer an explicit Temurin directory over whatever `javac` happens to resolve
    # to, so a pre-existing JDK on the machine cannot quietly win.
    for candidate in /usr/lib/jvm/temurin-"${JDK_VERSION}"* /opt/java/current /opt/java/temurin-"${JDK_VERSION}"; do
        [[ -x "$candidate/bin/javac" ]] && { printf '%s' "$(readlink -f "$candidate")"; return 0; }
    done
    if have javac; then
        candidate="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
        [[ -x "$candidate/bin/javac" ]] && { printf '%s' "$candidate"; return 0; }
    fi
    return 1
}

configure_environment() {
    phase "Phase 4/7  Configuring the environment"

    local java_home
    if ! java_home="$(find_java_home)"; then
        if [[ "$DRY_RUN" == true ]]; then
            step "[dry run] would write /etc/profile.d/jdk.sh with JAVA_HOME"
        else
            bad "Could not locate the installed JDK, so JAVA_HOME was not set."
            add_result "JAVA_HOME" "FAIL" "JDK directory not found"
        fi
        configure_inotify
        return 0
    fi

    ok "Found JDK: $java_home"

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] would write /etc/profile.d/jdk.sh exporting JAVA_HOME=$java_home"
    else
        write_root_file /etc/profile.d/jdk.sh <<EOF
# Written by the Software Development course setup script.
export JAVA_HOME="$java_home"
export PATH="\$JAVA_HOME/bin:\$PATH"
EOF
        run_root chmod 0644 /etc/profile.d/jdk.sh
        ok "JAVA_HOME set for all users via /etc/profile.d/jdk.sh"
        add_result "JAVA_HOME" "OK" "$java_home"

        # Apply to this process too, so the checks below see it without a re-login.
        export JAVA_HOME="$java_home"
        export PATH="$JAVA_HOME/bin:$PATH"
        ok "Applied to this session so the checks below see the new JDK."
    fi

    configure_inotify
}

# IntelliJ runs out of inotify watches on medium projects and greets the student
# with an alarming warning on first launch. Raise the limit once, quietly.
configure_inotify() {
    local current
    current="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
    if [[ "$current" -ge "$INOTIFY_TARGET" ]]; then
        skip "inotify watch limit is already $current."
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] would raise fs.inotify.max_user_watches from $current to $INOTIFY_TARGET"
        return 0
    fi

    echo "fs.inotify.max_user_watches = $INOTIFY_TARGET" \
        | write_root_file /etc/sysctl.d/99-intellij.conf
    run_root sysctl -q --system > /dev/null 2>&1 || true
    ok "Raised the inotify watch limit to $INOTIFY_TARGET (was $current)."
}

# ---------------------------------------------------------------------------
# Phase 5 -- Verify
#
# Printing version numbers is not verification. A machine with an old Java 8
# earlier on PATH passes a naive `java -version` check and still cannot build
# anything. Every check below asserts something.
# ---------------------------------------------------------------------------

# "openjdk version \"25.0.4\"" -> 25 ;  "javac 25.0.4" -> 25 ;  "1.8.0_402" -> 8
version_major() {
    local text="$1" token first rest
    token="$(printf '%s' "$text" | grep -oE '[0-9]+(\.[0-9]+)*' | head -1 || true)"
    [[ -z "$token" ]] && return 1
    first="${token%%.*}"
    if [[ "$first" == "1" && "$token" == *.* ]]; then
        rest="${token#*.}"
        printf '%s' "${rest%%.*}"
    else
        printf '%s' "$first"
    fi
}

check_java_tool() {
    local exe="$1" label="$2" output major

    if ! have "$exe"; then
        bad "$label is not on your PATH."
        add_result "$label" "FAIL" "Not found on PATH"
        return 1
    fi

    output="$("$exe" -version 2>&1 | head -1)"
    major="$(version_major "$output" || true)"

    if [[ "$major" != "$JDK_VERSION" ]]; then
        bad "$label reports Java ${major:-unknown}, expected $JDK_VERSION."
        bad "  Resolved to: $(command -v "$exe")"
        bad "  Another Java is earlier on your PATH. See TROUBLESHOOTING.md,"
        bad "  section \"An older Java is earlier on PATH\"."
        add_result "$label" "FAIL" "Found Java ${major:-unknown}, expected $JDK_VERSION"
        return 1
    fi

    ok "$label -> $output"
    add_result "$label" "OK" "$output"
}

check_java_home_consistency() {
    if [[ -z "${JAVA_HOME:-}" ]]; then
        bad "JAVA_HOME is not set."
        add_result "JAVA_HOME consistency" "FAIL" "JAVA_HOME not set"
        return 1
    fi
    if [[ ! -x "$JAVA_HOME/bin/java" ]]; then
        bad "JAVA_HOME points at $JAVA_HOME, but there is no runnable java in its bin directory."
        add_result "JAVA_HOME consistency" "FAIL" "Stale JAVA_HOME: $JAVA_HOME"
        return 1
    fi

    local from_home from_path
    from_home="$(readlink -f "$JAVA_HOME/bin/java")"
    from_path="$(readlink -f "$(command -v java)")"

    if [[ "$from_home" != "$from_path" ]]; then
        bad "JAVA_HOME and PATH disagree about which Java to use:"
        bad "  JAVA_HOME -> $from_home"
        bad "  PATH      -> $from_path"
        add_result "JAVA_HOME consistency" "FAIL" "JAVA_HOME=$from_home but PATH=$from_path"
        return 1
    fi

    ok "JAVA_HOME and PATH agree: $from_home"
    add_result "JAVA_HOME consistency" "OK" "$from_home"
}

# The check that actually matters: can this machine compile and run a Java program?
check_compile_and_run() {
    local work expected actual
    work="$(mktemp -d)"
    expected="course-setup-ok"

    cat > "$work/Hello.java" <<EOF
public class Hello {
    public static void main(String[] args) {
        System.out.println("$expected");
    }
}
EOF

    if ! javac -d "$work" "$work/Hello.java" > "$work/compile.log" 2>&1; then
        bad "javac could not compile a hello-world program."
        sed 's/^/       /' "$work/compile.log" || true
        add_result "Compile and run" "FAIL" "javac failed"
        rm -rf "$work"
        return 1
    fi

    actual="$(java -cp "$work" Hello 2>&1 || true)"
    rm -rf "$work"

    if [[ "$actual" != "$expected" ]]; then
        bad "The compiled program printed '$actual' instead of '$expected'."
        add_result "Compile and run" "FAIL" "Unexpected output: $actual"
        return 1
    fi

    ok "Compiled and ran a Java program successfully."
    add_result "Compile and run" "OK" "javac + java round trip"
}

check_intellij_present() {
    if [[ ! -x "$IDEA_PREFIX/bin/idea.sh" ]]; then
        bad "The IntelliJ IDEA launcher is missing from $IDEA_PREFIX/bin/idea.sh."
        add_result "IntelliJ launcher" "FAIL" "Not found"
        return 1
    fi
    ok "IntelliJ IDEA launcher: $IDEA_PREFIX/bin/idea.sh"
    add_result "IntelliJ launcher" "OK" "$(readlink -f "$IDEA_PREFIX")"
}

check_vscode_present() {
    [[ "$SKIP_VSCODE" == true ]] && return 0
    if ! have code; then
        warn "VS Code is installed but 'code' is not on your PATH in this shell."
        warn "Open a new terminal; if it is still missing, see TROUBLESHOOTING.md."
        add_result "VS Code CLI" "WARN" "code not on PATH in this session"
        return 0
    fi
    local version; version="$(code --version 2>/dev/null | head -1)"
    ok "VS Code -> $version"
    add_result "VS Code CLI" "OK" "$version"
}

verify() {
    phase "Phase 5/7  Verifying the installation"

    if [[ "$DRY_RUN" == true ]]; then
        step "[dry run] would check java, javac, JAVA_HOME/PATH agreement,"
        step "[dry run] compile and run a Hello.java, and locate IntelliJ and VS Code."
        return 0
    fi

    check_java_tool java  "java"  || true
    check_java_tool javac "javac" || true
    check_java_home_consistency   || true
    check_compile_and_run         || true
    check_intellij_present        || true
    check_vscode_present          || true
}

# ---------------------------------------------------------------------------
# Phases 6 and 7 -- Summary and exit
# ---------------------------------------------------------------------------

print_summary() {
    phase "Phase 6/7  Summary"
    printf '\n  %-26s %-8s %s\n' "Component" "Status" "Detail"
    printf '  %-26s %-8s %s\n' "--------------------------" "--------" "------"

    local entry component status detail failures=0 warnings=0
    for entry in "${RESULTS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        IFS='|' read -r component status detail <<< "$entry"
        printf '  %-26s %-8s %s\n' "$component" "$status" "$detail"
        [[ "$status" == "FAIL" ]] && failures=$((failures + 1))
        [[ "$status" == "WARN" ]] && warnings=$((warnings + 1))
    done
    printf '\n'

    if [[ "$DRY_RUN" == true ]]; then
        printf '  %sDry run finished. Nothing was installed or changed.%s\n' "$C_MAGENTA" "$C_RESET"
        printf '  %sRe-run without --dry-run to install for real.%s\n' "$C_MAGENTA" "$C_RESET"
        return 0
    fi

    if [[ "$failures" -eq 0 ]]; then
        printf '  %sEverything checks out. You are ready to start the course.%s\n\n' "$C_GREEN" "$C_RESET"
        printf '  %sNext steps:%s\n' "$C_CYAN" "$C_RESET"
        printf '    1. Open a new terminal, so JAVA_HOME and PATH are picked up.\n'
        printf '    2. If Git warned you above, run the commands in GIT-QUICKSTART.md.\n'
        printf '    3. Clone your first assignment repo and open it with:  idea .\n'
        if [[ "$warnings" -gt 0 ]]; then
            printf '\n  %s%d warning(s) above. Nothing is broken, but read them.%s\n' "$C_YELLOW" "$warnings" "$C_RESET"
        fi
        return 0
    fi

    printf '  %s%d check(s) failed:%s\n' "$C_RED" "$failures" "$C_RESET"
    for entry in "${RESULTS[@]:-}"; do
        IFS='|' read -r component status detail <<< "$entry"
        [[ "$status" == "FAIL" ]] && printf '    %s- %s: %s%s\n' "$C_RED" "$component" "$detail" "$C_RESET"
    done
    printf '\n  %sWhat to do:%s\n' "$C_YELLOW" "$C_RESET"
    printf '    1. Look up the failing item in TROUBLESHOOTING.md.\n'
    printf '    2. If that does not help, send your instructor the log file:\n'
    printf '         %s\n' "$LOG_PATH"
    return 1
}

finish() {
    local code="${1:-0}"
    phase "Phase 7/7  Done"
    printf '  Full log: %s\n\n' "$LOG_PATH"
    exit "$code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Phase 2 -- start logging before anything else can fail.
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_PATH="$LOG_DIR/setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG_PATH") 2>&1

printf '\n  Software Development course -- Linux setup\n'
printf '  %sInstalls: Eclipse Temurin JDK, IntelliJ IDEA, Visual Studio Code%s\n' "$C_GREY" "$C_RESET"
printf '  %sDoes not install Git -- that is Stage 0, and you already did it.%s\n' "$C_GREY" "$C_RESET"
[[ "$DRY_RUN" == true ]] && printf '  %sDRY RUN: nothing will be changed.%s\n' "$C_MAGENTA" "$C_RESET"
printf '  %sLogging to: %s%s\n' "$C_GREY" "$LOG_PATH" "$C_RESET"

preflight
install_components
configure_environment
verify

if print_summary; then finish 0; else finish 1; fi
