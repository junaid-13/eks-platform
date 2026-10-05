#!/usr/bin/env bash

set -u

# -----------------------------------------------------------------------------
# Tool Installation Script
# Ubuntu / apt based systems
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# -----------------------------------------------------------------------------
# Error handler
# -----------------------------------------------------------------------------

run_cmd() {
    local description="$1"
    shift

    log_info "$description"

    if "$@"; then
        log_success "$description completed successfully."
    else
        log_error "Failed: $description"
        log_error "Command: $*"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Root check
# -----------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    log_error "This script must be run as root or with sudo."
    echo "Usage: sudo $0"
    exit 1
fi

# -----------------------------------------------------------------------------
# Architecture
# -----------------------------------------------------------------------------

ARCH="$(dpkg --print-architecture)"

case "$ARCH" in
    amd64|arm64)
        ;;
    *)
        log_error "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# Check command
# -----------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Install prerequisites
# -----------------------------------------------------------------------------

log_info "Updating apt package index..."

if ! apt-get update; then
    log_error "apt-get update failed."
    exit 1
fi

PREREQUISITES=(
    curl
    wget
    gnupg
    ca-certificates
    lsb-release
    software-properties-common
    apt-transport-https
)

for package in "${PREREQUISITES[@]}"; do
    if dpkg -s "$package" >/dev/null 2>&1; then
        log_success "$package is already installed."
    else
        run_cmd "Installing prerequisite: $package" \
            apt-get install -y "$package" || exit 1
    fi
done

# -----------------------------------------------------------------------------
# Terraform
# -----------------------------------------------------------------------------

if command_exists terraform; then
    log_success "Terraform is already installed: $(terraform version | head -n 1)"
else
    log_info "Installing Terraform..."

    install -d -m 0755 /etc/apt/keyrings

    curl -fsSL https://apt.releases.hashicorp.com/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/hashicorp-archive-keyring.gpg

    chmod 644 /etc/apt/keyrings/hashicorp-archive-keyring.gpg

    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" \
        > /etc/apt/sources.list.d/hashicorp.list

    if ! apt-get update; then
        log_error "Failed to update apt after adding HashiCorp repository."
        exit 1
    fi

    if ! apt-get install -y terraform; then
        log_error "Terraform installation failed."
        exit 1
    fi

    if command_exists terraform; then
        log_success "Terraform installed successfully."
    else
        log_error "Terraform installation completed but terraform command was not found."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Helm
# -----------------------------------------------------------------------------

if command_exists helm; then
    log_success "Helm is already installed: $(helm version --short 2>/dev/null)"
else
    log_info "Installing Helm..."

    curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/helm.gpg

    chmod 644 /usr/share/keyrings/helm.gpg

    echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" \
        > /etc/apt/sources.list.d/helm-stable-debian.list

    if ! apt-get update; then
        log_error "Failed to update apt after adding Helm repository."
        exit 1
    fi

    if ! apt-get install -y helm; then
        log_error "Helm installation failed."
        exit 1
    fi

    if command_exists helm; then
        log_success "Helm installed successfully."
    else
        log_error "Helm installation completed but helm command was not found."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# kubectl
# -----------------------------------------------------------------------------

if command_exists kubectl; then
    log_success "kubectl is already installed: $(kubectl version --client --output=yaml 2>/dev/null | grep gitVersion | head -n 1)"
else
    log_info "Installing kubectl..."

    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    chmod 644 /etc/apt/keyrings/kubernetes-apt-keyring.gpg

    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' \
        > /etc/apt/sources.list.d/kubernetes.list

    if ! apt-get update; then
        log_error "Failed to update apt after adding Kubernetes repository."
        exit 1
    fi

    if ! apt-get install -y kubectl; then
        log_error "kubectl installation failed."
        exit 1
    fi

    if command_exists kubectl; then
        log_success "kubectl installed successfully."
    else
        log_error "kubectl installation completed but kubectl command was not found."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Kustomize
# -----------------------------------------------------------------------------

if command_exists kustomize; then
    log_success "Kustomize is already installed: $(kustomize version --short 2>/dev/null)"
else
    log_info "Installing Kustomize as a binary..."

    KUSTOMIZE_ARCH="amd64"

    if [[ "$ARCH" == "arm64" ]]; then
        KUSTOMIZE_ARCH="arm64"
    fi

    # Get the latest Kustomize release tag
    KUSTOMIZE_VERSION="$(
        curl -fsSL https://api.github.com/repos/kubernetes-sigs/kustomize/releases/latest \
        | grep '"tag_name":' \
        | head -n 1 \
        | cut -d '"' -f 4
    )"

    if [[ -z "$KUSTOMIZE_VERSION" ]]; then
        log_error "Could not determine the latest Kustomize version."
        exit 1
    fi

    log_info "Latest Kustomize version: $KUSTOMIZE_VERSION"

    # Kustomize release asset format:
    # kustomize_vX.Y.Z_linux_amd64.tar.gz
    #
    # Example:
    # kustomize_v5.7.1_linux_amd64.tar.gz
    KUSTOMIZE_VERSION_NUMBER="${KUSTOMIZE_VERSION#kustomize/}"

    KUSTOMIZE_FILE="kustomize_${KUSTOMIZE_VERSION_NUMBER}_linux_${KUSTOMIZE_ARCH}.tar.gz"

    KUSTOMIZE_URL="https://github.com/kubernetes-sigs/kustomize/releases/download/${KUSTOMIZE_VERSION}/${KUSTOMIZE_FILE}"

    log_info "Downloading Kustomize from:"
    echo "$KUSTOMIZE_URL"

    TMP_DIR="$(mktemp -d)"

    cleanup_kustomize() {
        rm -rf "$TMP_DIR"
    }

    trap cleanup_kustomize EXIT

    if ! curl -fL \
        --retry 3 \
        --retry-delay 2 \
        "$KUSTOMIZE_URL" \
        -o "$TMP_DIR/kustomize.tar.gz"; then

        log_error "Failed to download Kustomize."
        log_error "URL: $KUSTOMIZE_URL"
        exit 1
    fi

    log_info "Extracting Kustomize..."

    if ! tar -xzf "$TMP_DIR/kustomize.tar.gz" -C "$TMP_DIR"; then
        log_error "Failed to extract Kustomize archive."
        exit 1
    fi

    if [[ ! -f "$TMP_DIR/kustomize" ]]; then
        log_error "Kustomize binary was not found inside the downloaded archive."
        exit 1
    fi

    log_info "Installing Kustomize binary to /usr/local/bin..."

    if ! install -m 0755 "$TMP_DIR/kustomize" /usr/local/bin/kustomize; then
        log_error "Failed to install Kustomize binary."
        exit 1
    fi

    if command_exists kustomize; then
        log_success "Kustomize installed successfully."
        log_success "Version: $(kustomize version --short 2>/dev/null)"
        log_success "Binary: $(command -v kustomize)"
    else
        log_error "Kustomize installation completed but kustomize command was not found."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Argo CD CLI
# -----------------------------------------------------------------------------

if command_exists argocd; then
    log_success "Argo CD CLI is already installed: $(argocd version --client --short 2>/dev/null)"
else
    log_info "Installing Argo CD CLI..."

    ARGOCD_VERSION="$(curl -fsSL https://api.github.com/repos/argoproj/argo-cd/releases/latest \
        | grep '"tag_name":' \
        | head -n 1 \
        | cut -d '"' -f 4)"

    if [[ -z "$ARGOCD_VERSION" ]]; then
        log_error "Could not determine the latest Argo CD version."
        exit 1
    fi

    ARGOCD_ARCH="amd64"

    if [[ "$ARCH" == "arm64" ]]; then
        ARGOCD_ARCH="arm64"
    fi

    ARGOCD_URL="https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARGOCD_ARCH}"

    if ! curl -fL "$ARGOCD_URL" -o /usr/local/bin/argocd; then
        log_error "Failed to download Argo CD CLI."
        exit 1
    fi

    if ! chmod +x /usr/local/bin/argocd; then
        log_error "Failed to make Argo CD executable."
        exit 1
    fi

    if command_exists argocd; then
        log_success "Argo CD CLI installed successfully."
    else
        log_error "Argo CD installation completed but command was not found."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Docker
# -----------------------------------------------------------------------------

if command_exists docker; then
    log_success "Docker is already installed: $(docker --version)"
else
    log_info "Installing Docker Engine..."

    # -------------------------------------------------------------------------
    # Detect Ubuntu
    # -------------------------------------------------------------------------

    if [[ ! -f /etc/os-release ]]; then
        log_error "/etc/os-release not found. Cannot determine operating system."
        exit 1
    fi

    . /etc/os-release

    if [[ "${ID}" != "ubuntu" ]]; then
        log_error "This Docker installation section supports Ubuntu only."
        log_error "Detected OS: ${ID}"
        exit 1
    fi

    UBUNTU_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

    if [[ -z "$UBUNTU_CODENAME" ]]; then
        log_error "Could not determine Ubuntu codename."
        exit 1
    fi

    log_info "Ubuntu codename: $UBUNTU_CODENAME"
    log_info "Architecture: $ARCH"

    # -------------------------------------------------------------------------
    # Remove conflicting Docker/container packages
    #
    # Docker officially recommends removing these packages before installing
    # Docker Engine from its own repository.
    # -------------------------------------------------------------------------

    CONFLICTING_PACKAGES=(
        docker.io
        docker-compose
        docker-compose-v2
        docker-doc
        docker-buildx
        podman-docker
        containerd
        runc
    )

    PACKAGES_TO_REMOVE=()

    for package in "${CONFLICTING_PACKAGES[@]}"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null \
            | grep -q "install ok installed"; then

            PACKAGES_TO_REMOVE+=("$package")
        fi
    done

    if [[ "${#PACKAGES_TO_REMOVE[@]}" -gt 0 ]]; then
        log_info "Conflicting Docker/container packages detected:"
        printf '  - %s\n' "${PACKAGES_TO_REMOVE[@]}"

        log_info "Removing conflicting packages..."

        if ! apt-get remove -y "${PACKAGES_TO_REMOVE[@]}"; then
            log_error "Failed to remove conflicting Docker/container packages."
            exit 1
        fi
    else
        log_success "No conflicting Docker/container packages found."
    fi

    # -------------------------------------------------------------------------
    # Install Docker repository prerequisites
    # -------------------------------------------------------------------------

    DOCKER_PREREQUISITES=(
        ca-certificates
        curl
    )

    for package in "${DOCKER_PREREQUISITES[@]}"; do
        if dpkg -s "$package" >/dev/null 2>&1; then
            log_success "$package is already installed."
        else
            log_info "Installing Docker prerequisite: $package"

            if ! apt-get install -y "$package"; then
                log_error "Failed to install Docker prerequisite: $package"
                exit 1
            fi
        fi
    done

    # -------------------------------------------------------------------------
    # Add Docker official GPG key
    # -------------------------------------------------------------------------

    log_info "Configuring Docker GPG key..."

    install -m 0755 -d /etc/apt/keyrings

    if ! curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc; then

        log_error "Failed to download Docker GPG key."
        exit 1
    fi

    chmod a+r /etc/apt/keyrings/docker.asc

    # -------------------------------------------------------------------------
    # Configure Docker official APT repository
    # -------------------------------------------------------------------------

    log_info "Configuring Docker APT repository..."

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    # -------------------------------------------------------------------------
    # Update package index
    # -------------------------------------------------------------------------

    log_info "Updating APT package index..."

    if ! apt-get update; then
        log_error "Failed to update APT package index after adding Docker repository."
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Verify Docker packages are available
    # -------------------------------------------------------------------------

    log_info "Checking Docker packages..."

    DOCKER_PACKAGES=(
        docker-ce
        docker-ce-cli
        containerd.io
        docker-buildx-plugin
        docker-compose-plugin
    )

    for package in "${DOCKER_PACKAGES[@]}"; do
        if ! apt-cache policy "$package" | grep -q "Candidate:"; then
            log_error "Docker package '$package' is not available."
            log_error "Ubuntu: $UBUNTU_CODENAME"
            log_error "Architecture: $ARCH"
            exit 1
        fi
    done

    # -------------------------------------------------------------------------
    # Install Docker Engine
    # -------------------------------------------------------------------------

    log_info "Installing Docker Engine..."

    if ! apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin; then

        log_error "Docker installation failed."
        log_error "Run the following command to inspect the dependency problem:"
        echo
        echo "    apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
        echo
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Enable and start Docker
    # -------------------------------------------------------------------------

    log_info "Enabling Docker service..."

    if ! systemctl enable docker; then
        log_error "Failed to enable Docker service."
        exit 1
    fi

    log_info "Starting Docker service..."

    if ! systemctl start docker; then
        log_error "Failed to start Docker service."
        log_error "Docker service status:"
        systemctl status docker --no-pager || true
        exit 1
    fi

    # -------------------------------------------------------------------------
    # Verify Docker
    # -------------------------------------------------------------------------

    if ! command_exists docker; then
        log_error "Docker was installed but the docker command was not found."
        exit 1
    fi

    if ! docker --version; then
        log_error "Docker command exists but could not be executed."
        exit 1
    fi

    if ! systemctl is-active --quiet docker; then
        log_error "Docker service is not running."
        systemctl status docker --no-pager || true
        exit 1
    fi

    log_success "Docker installed successfully: $(docker --version)"
    log_success "Docker service is running."

    if docker compose version >/dev/null 2>&1; then
        log_success "Docker Compose installed: $(docker compose version)"
    else
        log_error "Docker Compose plugin was not installed correctly."
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
# Final verification
# -----------------------------------------------------------------------------

echo
echo "============================================================"
echo "              Installation Summary"
echo "============================================================"

TOOLS=(
    terraform
    helm
    kubectl
    kustomize
    argocd
    docker
)

FAILED=0

for tool in "${TOOLS[@]}"; do
    if command_exists "$tool"; then
        printf "%-12s : %s\n" "$tool" "Installed"
    else
        printf "%-12s : %s\n" "$tool" "NOT FOUND"
        FAILED=1
    fi
done

echo "============================================================"

if [[ "$FAILED" -eq 0 ]]; then
    log_success "All tools are installed successfully."
else
    log_error "One or more tools are missing."
    exit 1
fi