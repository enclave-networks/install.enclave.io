#!/bin/bash
# This script installs enclave on Ubuntu, Debian, CentOS, Amazon Linux 2 (x64), Arch Linux and Raspbian 10 (arm).
#
# Pass a version number arugment to install a specific version.
# $ ./install.sh -v 2020.4.19.0
#
# Pass a license key for an unattended installation.
# $ ./install.sh -l XXXXX-XXXXX-XXXXX-XXXXX-XXXXX

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
    echo "Usage: $0 [-a ARCH] [-l LICENSE_KEY] [-v VERSION]"
    [[ "${1:-}" == "error" ]] && exit 1
    exit 0
}

quick_start() {
    info "Installation complete."
    echo -e "\n\e[1mLearn how to use Enclave at https://enclave.io/docs/\e[0m"
    echo "Quick start:"
    echo -e "    \e[1menclave add [PEER_NAME] -d [DESCRIPTION]\e[0m to authorise a connection to another system running enclave."
    echo -e "    \e[1menclave status\e[0m for status.\n"
}

install_dependencies() {
    info "Checking/installing dependencies."
    deps=(tar wget)
    # Install common and distro specific deps
    if grep -qi "rhel" /etc/os-release; then
        deps+=(libicu)
        sudo yum install -y "${deps[@]}"
    elif grep -qi "debian" /etc/os-release; then
        info "Updating package index."
        sudo apt-get update -qq
        # Different versions of Debian/Ubuntu ship different versions of libicu
        deps+=("$(apt-cache search -n "^libicu[0-9]+$" | cut -d" " -f1)")
        # RaspberryPi OS/Raspbian needs libsodium-dev
        if grep -qi "raspbian" /etc/os-release; then 
            deps+=("libsodium-dev")
        fi 
        sudo apt-get install -yq "${deps[@]}"
    elif grep -qi "arch" /etc/os-release; then
        deps+=(icu libsodium)
        sudo pacman -Syq --noconfirm --needed "${deps[@]}"
    fi
}

get_version() {
    latest=$(wget -qO- https://install.enclave.io/latest/version)
    if [[ -n "${latest}" ]]; then
        echo "${latest}"
    else
        error "Unsupported architecture: $(uname -m). Aborting."
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
    BINARY_URL="https://release.enclave.io/enclave_linux-${ENCLAVE_ARCH}-${ENCLAVE_VERSION}.tar.gz"
    
    # Download archive to /tmp and extract enclave to /usr/bin
    info "Installing enclave-${ENCLAVE_VERSION}."
    wget -qO "/tmp/enclave_linux-${ENCLAVE_ARCH}-$ENCLAVE_VERSION.tar.gz" "${BINARY_URL}"
    sudo tar xvzf "/tmp/enclave_linux-${ENCLAVE_ARCH}-$ENCLAVE_VERSION.tar.gz" -C /usr/bin/ > /dev/null 2>&1
    rm "/tmp/enclave_linux-${ENCLAVE_ARCH}-${ENCLAVE_VERSION}.tar.gz"
    sudo chown root: /usr/bin/enclave
    sudo chmod 755 /usr/bin/enclave
    
    # Create systemd service
    sudo mkdir -p /usr/lib/systemd/system/
    cat <<-EOF | sudo tee /usr/lib/systemd/system/enclave.service >/dev/null
[Unit]
Description=Enclave
After=network.target

[Service]
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

license_enclave() {
    if sudo test -f /etc/enclave/profiles/Universe.profile; then
        info "Existing identity /etc/enclave/profiles/Universe.profile detected."
    else
        if [[ -z "${ENCLAVE_LICENSE:-}" ]]; then 
            warning "No license key supplied."
            warning "Enclave requires a licence key in order to request a certificate and enroll this system into your account."
        fi
        # Check Enclave licenses successfully
        if ! sudo enclave license "${ENCLAVE_LICENSE:-}"; then
            error "Failed to license Enclave."
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

while getopts "a:v:l:h" options
do
    case "${options}" in
        a) ENCLAVE_ARCH="${OPTARG}" ;;
        v) ENCLAVE_VERSION="${OPTARG}" ;;
        l) ENCLAVE_LICENSE="${OPTARG}" ;;
        h) usage ;;
        :) usage error ;;
        *) usage error ;;
    esac
done
shift $((OPTIND -1))

ENCLAVE_ARCH="${ENCLAVE_ARCH:-$(get_arch)}"

install_dependencies
install_enclave
license_enclave
start_fabric