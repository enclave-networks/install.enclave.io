#!/bin/bash
# This script installs enclave on Ubuntu, Debian, CentOS, Amazon Linux 2 (x64), Arch Linux and Raspbian 10 (arm).

set -euo pipefail
# Output green message prefixed with [+]
info() { echo -e "\e[92m[+] ${1:-}\e[0m"; }
# Output orange message prefixed with [-]
warning() { echo -e "\e[33m[-] ${1:-}\e[0m"; }
# Output red message prefixed with [!] and exit
error() { echo -e >&2 "\e[31m[!] ${1:-}\e[0m"; exit 1; }

# Do not run this script as root
[[ "${EUID}" -eq  0 ]] && warning "Script running as root, you should run this as an unprivileged user."

usage() {
    echo "Usage: $0 "
    echo -e "\t -a ARCH            optional\t Specify architecture (x64/arm/arm64)"
    echo -e "\t -e ENROLMENT_KEY   optional\t Specify an enrolment key for install"
    echo -e "\t -v VERSION         optional\t Specify version to install"
    echo -e "\t -u                 optional\t Use unstable channel for package repositories"
    echo -e "\t -h                 optional\t Display this message"
    [[ "${1:-}" == "error" ]] && exit 1
    exit 0
}

quick_start() {
    info "Installation complete."
    echo -e "\n\e[1mLearn how to use Enclave at https://enclave.io/docs/\e[0m"
    echo -e "Quick start:"
    echo -e "    \e[1menclave add [PEER_NAME] -d [DESCRIPTION]\e[0m to authorise a connection to another system running enclave."
    echo -e "    \e[1menclave status\e[0m for status.\n"
}

get_distro_family() {
    if grep -qi "rhel" /etc/os-release; then
        echo "rhel"
    elif grep -qi "raspbian" /etc/os-release; then
        echo "raspbian"
    elif grep -qi "debian" /etc/os-release || grep -qi "ubuntu" /etc/os-release; then
        echo "debian"
    elif grep -qi "arch" /etc/os-release; then
        echo "arch"
    fi
}

install_apt_package() {
    # Install the pre-requisites for an apt install
    info "Updating package index."
    sudo apt-get update -qq
    deps=(apt-transport-https wget)
    sudo apt-get install -yq "${deps[@]}"

    # Add and trust the Enclave package repository
    info "Adding Enclave GPG package signing key."
    wget -qO- https://packages.enclave.io/apt/enclave.stable.gpg | sudo apt-key add - >/dev/null 2>&1
    info "Adding the Enclave package repository."
    # shellcheck disable=SC2024
    wget -qO- "https://packages.enclave.io/apt/${ENCLAVE_PKG_LIST}" | sudo tee "/etc/apt/sources.list.d/${ENCLAVE_PKG_LIST}" >/dev/null

    info "Updating package index"
    sudo apt-get update -qq

    # Export the enrolment key variable if set so it gets picked up
    # by the postinst script in the deb
    if [[ -z "${ENCLAVE_ENROLMENT_KEY:-}" ]]; then
        export ENCLAVE_ENROLMENT_KEY
    fi

    # Check if the user specified an Enclave version to install
    if [[ -n "${ENCLAVE_VERSION:-}" ]]; then
        # Install specified Enclave version
        info "Installing Enclave package (${ENCLAVE_VERSION})."
        sudo apt-get install -yq "enclave=${ENCLAVE_VERSION}"
    else
        # Install latest Enclave
        info "Installing Enclave package (latest)."
        sudo apt-get install -yq enclave
    fi

    # Do not continue with rest of setup as deb handles all of it
    exit 0
}

preinstall() {
    info "Checking/installing dependencies."
    deps=(tar wget)

    case $(get_distro_family) in
        "debian")
            info "Debian-based distro detected. Installing via package manager."
            install_apt_package
            ;;
        "raspbian")
            sudo apt-get update -qq
            # Different versions of Raspbian ship different versions of libicu
            deps+=("$(apt-cache search -n "^libicu[0-9]+$" | cut -d" " -f1)" "libsodium-dev")
            # Install dependencies
            sudo apt-get install -yq "${deps[@]}"
            ;;
        "rhel")
            # Install deps for rhel/fedora/centos
            deps+=(libicu)
            sudo yum install -y "${deps[@]}"
            ;;
        "arch")
            # Install arch linux deps
            deps+=(icu libsodium)
            sudo pacman -Syq --noconfirm --needed "${deps[@]}"
            ;;
        *)
            warning "Unsupported distro detected. Some dependencies may not be present."
            ;;
        esac
}

get_version() {
    latest=$(wget -qO- https://install.enclave.io/latest/version)
    if [[ -n "${latest}" ]]; then
        echo "${latest}"
    else
        error "Unable to fetch latest version."
    fi
}

get_arch() {
    case "$(uname -m)" in
        "x86_64") echo "x64" ;;
        "armv7l"|"arm8") echo "arm" ;;
        "arm64"|"aarch64") echo "arm64" ;;
        *) error "Unsupported architecture: $(uname -m). Aborting." ;;
    esac
}

install_enclave() {
    # Stop supervisor service before install / upgrade (don't care if this fails)
    if sudo systemctl stop enclave >/dev/null 2>&1; then
        info "Enclave service stopped."
    fi

    # Get correct version and build url
    ENCLAVE_VERSION="${ENCLAVE_VERSION:-$(get_version)}"
    BINARY_URL="https://release.enclave.io/enclave_linux-${ENCLAVE_ARCH}-stable-${ENCLAVE_VERSION}.tar.gz"

    # Download archive to /tmp and extract enclave to /usr/bin
    info "Installing enclave-${ENCLAVE_VERSION}."
    wget -qO "/tmp/enclave_linux-${ENCLAVE_ARCH}-stable-$ENCLAVE_VERSION.tar.gz" "${BINARY_URL}"
    sudo tar xvzf "/tmp/enclave_linux-${ENCLAVE_ARCH}-stable-$ENCLAVE_VERSION.tar.gz" -C /usr/bin/ > /dev/null 2>&1
    rm "/tmp/enclave_linux-${ENCLAVE_ARCH}-stable-${ENCLAVE_VERSION}.tar.gz"
    sudo chown root: /usr/bin/enclave
    sudo chmod 755 /usr/bin/enclave

    # Create systemd service
    sudo mkdir -p /usr/lib/systemd/system/
    cat <<-EOF | sudo tee /usr/lib/systemd/system/enclave.service >/dev/null
[Unit]
Description=Enclave
After=network.target

[Service]
Environment="DOTNET_BUNDLE_EXTRACT_BASE_DIR=/var/tmp/.net/enclave"
ExecStart=/usr/bin/enclave supervisor-service

[Install]
WantedBy=multi-user.target
EOF
    # Ensure correct permissions on systemd unit
    sudo chmod 664 /usr/lib/systemd/system/enclave.service
    # Start and enable the Enclave service
    info "Starting Enclave service."
    sudo systemctl daemon-reload >/dev/null 2>&1
    sudo systemctl enable enclave >/dev/null 2>&1
    sudo systemctl start enclave >/dev/null 2>&1
    # Give the background service a couple of seconds to start
    sleep 2
}

enrol_system() {
    if sudo test -f /etc/enclave/profiles/Universe.profile; then
        info "Existing identity /etc/enclave/profiles/Universe.profile detected."
    else
        if [[ -z "${ENCLAVE_ENROLMENT_KEY:-}" ]]; then
            warning "No enrolment key supplied."
            warning "Enclave requires an enrolment key in order to request a certificate and enrol this system into your account."
        fi
        # Check Enclave enrols successfully
        if ! sudo enclave enrol "${ENCLAVE_ENROLMENT_KEY:-}"; then
            error "Failed to enrol system."
        fi
    fi
}

start_fabric() {
    info "Starting Enclave Fabric."
    if sudo enclave start -w; then
        quick_start
    else
        error "Failed to start Enclave fabric."
    fi
}

while getopts "a:v:l:hu" options
do
    case "${options}" in
        a) ENCLAVE_ARCH="${OPTARG}" ;;
        v) ENCLAVE_VERSION="${OPTARG}" ;;
        e) ENCLAVE_ENROLMENT_KEY="${OPTARG}" ;;
        u) ENCLAVE_PKG_LIST="enclave.unstable.list" ;;
        h) usage ;;
        :) usage error ;;
        *) usage error ;;
    esac
done
shift $((OPTIND -1))

ENCLAVE_ARCH="${ENCLAVE_ARCH:-$(get_arch)}"
ENCLAVE_PKG_LIST="${ENCLAVE_PKG_LIST:-enclave.stable.list}"

# Check if a package is available and install,
# if no package, install dependencies
preinstall
# Install manually (no package available)
install_enclave
enrol_system
start_fabric
