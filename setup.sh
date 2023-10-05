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
    echo -e "\t -r                 optional\t Remove enclave from this system"
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
    if grep -qi  "fedora" /etc/os-release;  then
        # Use the built in RPM macro to determine current fedora version if the version isn't good enough we fall back to a manual install
        # These macros are the same ones used when making an RPM package so can be relied upon
        FEDVER=$(rpm -E %{fedora})

        # Check that the Fedver value is a number before doing a greater than or equals on it
        re="^[0-9]+$"
        # Fedora 34 is chosen here as we know it's got a new enough version of RPM to work with enclave
        if [[  "$FEDVER" =~ $re && $FEDVER -ge 34 ]]
        then  
            echo "rhel"
            return
        fi
    fi

    if  grep -qi "amzn" /etc/os-release; then
        echo "rhel-legacy"
        return
    fi

    if grep -qi "rhel" /etc/os-release; then
        # Use the built in RPM macro to determine current rhel version if the version isn't good enough we fall back to a manual install
        # These macros are the same ones used when making an RPM package so can be relied upon
        RHELVER=$(rpm -E %{rhel})
        if [[ $RHELVER -ge 8 ]]
        then  
            echo "rhel"
            return
        elif [[ $RHELVER -le 7 ]]
        then
            echo "rhel-legacy"
            return
        fi
    fi

    if grep -qi "suse" /etc/os-release; then 
        echo "suse"
        return
    fi

    if grep -qi "raspbian" /etc/os-release; then
        echo "raspbian"
        return
    fi

    if grep -qi "debian" /etc/os-release || grep -qi "ubuntu" /etc/os-release; then
        echo "debian"
        return
    fi

    if grep -qi "arch" /etc/os-release; then
        echo "arch"
        return
    fi
}

install_apt_package() {
    # Install the pre-requisites for an apt install
    info "Updating package index."
    sudo apt update -qq
    deps=(apt-transport-https curl)
    sudo apt install -yq "${deps[@]}"

    # Add and trust the Enclave package repository
    info "Adding Enclave GPG package signing key."
    curl -fsSL https://packages.enclave.io/apt/enclave.stable.gpg | sudo gpg --dearmor -o /usr/share/keyrings/enclave.gpg

    info "Adding the Enclave package repository."
    # shellcheck disable=SC2024
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/enclave.gpg] https://packages.enclave.io/apt stable main" | sudo tee /etc/apt/sources.list.d/enclave.stable.list

    info "Updating package index"
    sudo apt update -qq

    # Export the enrolment key variable if set so it gets picked up
    # by the postinst script in the deb
    if [[ -z "${ENCLAVE_ENROLMENT_KEY:-}" ]]; then
        export ENCLAVE_ENROLMENT_KEY
    fi

    # Check if the user specified an Enclave version to install
    if [[ -n "${ENCLAVE_VERSION:-}" ]]; then
        # Install specified Enclave version
        info "Installing Enclave package (${ENCLAVE_VERSION})."
        sudo apt install -yq "enclave=${ENCLAVE_VERSION}"
    else
        # Install latest Enclave
        info "Installing Enclave package (latest)."
        sudo apt install -yq enclave
    fi
}


install_yum_package() {
    # Install the pre-requisites for a yum install
    info "Installing Prerequisites."
    sudo dnf -y install dnf-plugins-core

    # Add and trust the Enclave package repository
    info "Adding enclave yum Repo."
    sudo dnf config-manager --add-repo https://packages.enclave.io/rpm/enclave.repo   

    # Check if the user specified an Enclave version to install
    if [[ -n "${ENCLAVE_VERSION:-}" ]]; then
        # Install specified Enclave version
        info "Installing Enclave package (${ENCLAVE_VERSION})."
        sudo dnf install enclave-${ENCLAVE_VERSION} -y --refresh
    else
        # Install latest Enclave
        info "Installing Enclave package (latest)."
        sudo dnf install enclave -y --refresh
    fi
}


install_zypper_package() {
    # Add and trust the Enclave package repository
    info "Adding enclave yum Repo."
    sudo zypper -n addrepo https://packages.enclave.io/rpm/enclave.repo
    
    info "Importing GPG keys."
    sudo zypper --gpg-auto-import-keys refresh

    # Check if the user specified an Enclave version to install
    if [[ -n "${ENCLAVE_VERSION:-}" ]]; then
        # Install specified Enclave version
        info "Installing Enclave package (${ENCLAVE_VERSION})."
        sudo zypper -n install enclave-${ENCLAVE_VERSION}
    else
        # Install latest Enclave
        info "Installing Enclave package (latest)."
        sudo zypper -n install enclave
    fi
}

preinstall() {
    info "Checking/installing dependencies."
    deps=(tar wget)

    case $(get_distro_family) in
        "debian")
            info "Debian-based distro detected. Installing via package manager."
            install_apt_package
            false
            return
            ;;
        "raspbian")
            sudo apt update -qq
            # Different versions of Raspbian ship different versions of libicu
            deps+=("$(apt-cache search -n "^libicu[0-9]+$" | cut -d" " -f1)" "libsodium-dev" "iptables")
            # Install dependencies
            sudo apt install -yq "${deps[@]}"
            ;;
        "rhel-legacy")
            # This is primarly for RHEL 7 and older as they don't support our new RPM version
            # Install deps for rhel/fedora/centos
            deps+=(libicu iptables)
            sudo yum install -y "${deps[@]}"
            ;;
        "rhel")
            info "Red hat based distro detected. Installing via package manager."
            install_yum_package
            false
            return
            ;;
        "suse")
            info "Suse based distro detected. Installing via package manager."
            install_zypper_package
            false
            return
            ;;
        "arch")
            # Install arch linux deps
            deps+=(icu libsodium iptables)
            sudo pacman -Syq --noconfirm --needed "${deps[@]}"
            ;;
        *)
            warning "Unsupported distro detected. Some dependencies may not be present."
            ;;
        esac

    true
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

remove_enclave() {
    # Stop supervisor service before remove (don't care if this fails)
    if sudo systemctl disable --now enclave >/dev/null 2>&1; then
        info "Enclave service stopped."
    fi

    # Stop enclave auth daemon before remove (don't care if this fails)
    if systemctl --user disable --now enclave-auth.service >/dev/null 2>&1; then
        info "Enclave auth service stopped."
    fi

    case $(get_distro_family) in
        "debian")
            sudo apt remove -y enclave
            ;;
        "raspbian")
            sudo apt remove -y enclave
            ;;
        "rhel")
            sudo dnf remove -y enclave
            ;;
        "suse")
            sudo zypper rm -n enclave
            ;;
        *) # Default Case
            # Files
            sudo rm -rf /usr/bin/enclave
            sudo rm -rf /usr/lib/systemd/system/enclave.service
            sudo rm -rf /usr/lib/systemd/user/enclave-auth.service
            # Directories 
            sudo rm -rfd /etc/enclave/
            sudo rm -rfd /usr/share/doc/enclave/
            sudo rm -rfd /root/.net/enclave/
            ;;
    esac

    exit 0
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
Environment="DOTNET_BUNDLE_EXTRACT_BASE_DIR=%h/.net/enclave"
ExecStart=/usr/bin/enclave supervisor-service

[Install]
WantedBy=multi-user.target
EOF
    # Ensure correct permissions on systemd unit
    sudo chmod 664 /usr/lib/systemd/system/enclave.service
    
    # Create systemd service for enclave auth daemon
    sudo mkdir -p /usr/lib/systemd/user/
    cat <<-EOF | sudo tee /usr/lib/systemd/user/enclave-auth.service >/dev/null
[Unit]
Description=EnclaveAuth
After=enclave.service

[Service]
Environment="DOTNET_BUNDLE_EXTRACT_BASE_DIR=%h/.net/enclave"
ExecStart=/usr/bin/enclave auth -d

[Install]
WantedBy=default.target
EOF
    # Ensure correct permissions on systemd unit
    sudo chmod 664 /usr/lib/systemd/user/enclave-auth.service
}

enrol_system() {
    if sudo test -f /etc/enclave/profiles/Universe.profile; then
        info "Existing identity /etc/enclave/profiles/Universe.profile detected."
        info "Starting enclave systemctl service"
        sudo systemctl start enclave
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

while getopts "a:v:l:hur" options
do
    case "${options}" in
        a) ENCLAVE_ARCH="${OPTARG}" ;;
        v) ENCLAVE_VERSION="${OPTARG}" ;;
        e) ENCLAVE_ENROLMENT_KEY="${OPTARG}" ;;
        u) ENCLAVE_PKG_LIST="enclave.unstable.list" ;;
        r) remove_enclave ;;
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
# check if preinstall returns true this means that a manual install is required
if preinstall; then
    # Install manually (no repo available)
    install_enclave
fi
enrol_system
start_fabric
