#!/usr/bin/env bash
#
# deploy-ghost-hetzner.sh
#
# One-click deploy Ghost blog on Hetzner VPS with Tailscale-only SSH.
# No public SSH port — all management goes through Tailscale mesh VPN.
#
# Usage:
#   ./deploy-ghost-hetzner.sh
#   ./deploy-ghost-hetzner.sh --dry-run
#   ./deploy-ghost-hetzner.sh --teardown
#
# All configuration is read from the .env file next to this script.
# Copy .env.example to .env and fill in the required values, then run.
#
# Requirements on the local machine (auto-installed if missing):
#   curl, jq, ssh, ssh-keygen, openssl
#
# What it does:
#   1. Provisions a Hetzner Cloud VPS via API
#   2. Installs Docker, Docker Compose, Tailscale on the VPS
#   3. Deploys Ghost + MySQL + Caddy via Docker Compose
#   4. Configures firewall: only 80/443 public, SSH via Tailscale only
#   5. Outputs connection info and DNS setup instructions
#
set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Constants
# ──────────────────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.0.0"
readonly HETZNER_API="https://api.hetzner.cloud/v1"
readonly DEFAULT_SERVER_TYPE="cx22"
readonly DEFAULT_SERVER_LOCATION="fsn1"
readonly DEFAULT_IMAGE="ubuntu-24.04"
readonly DEFAULT_GHOST_VERSION="5.113.2"
readonly DEFAULT_MYSQL_VERSION="8.0"
readonly DEFAULT_CADDY_VERSION="2-alpine"
readonly TAILSCALE_CIDR="100.64.0.0/10"
readonly DEPLOY_USER="ghost"
readonly GHOST_DIR="/opt/ghost"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env.example"

# ──────────────────────────────────────────────────────────────────────────────
# Load .env file (next to this script) into the environment
# ──────────────────────────────────────────────────────────────────────────────
load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        error "Configuration file not found: ${ENV_FILE}"
        error "Create it from the template:"
        error "  cp ${SCRIPT_DIR}/.env.example ${ENV_FILE}"
        error "Then fill in the required values."
        fatal "Missing configuration file"
    fi

    set +u
    # Only export variables that are not already set in the real environment
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blank lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        # Skip lines without an equals sign
        [[ "$line" != *"="* ]] && continue
        local key="${line%%=*}"
        local val="${line#*=}"
        # Trim whitespace
        key="${key//[[:space:]]/}"
        # Strip surrounding quotes from value if present
        val="${val%\"*}"
        val="${val#\"}"
        val="${val%\'*}"
        val="${val#\'}"
        # Export only if not already defined in the environment
        if [[ -z "${!key:-}" ]]; then
            export "$key=$val"
        fi
    done < "$ENV_FILE"
    set -u
    info "Loaded environment from ${ENV_FILE}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Colors & helpers
# ──────────────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
success() { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
fatal()   { error "$*"; exit 1; }
step()    { printf "\n${CYAN}${BOLD}▶ %s${NC}\n" "$*"; }

# ──────────────────────────────────────────────────────────────────────────────
# Cleanup on failure
# ──────────────────────────────────────────────────────────────────────────────
SERVER_ID=""
DRY_RUN=false
TEARDOWN=false

cleanup() {
    local exit_code=$?
    if [[ $exit_code -ne 0 && -n "$SERVER_ID" && "$DRY_RUN" == "false" ]]; then
        warn "Script failed. Cleaning up Hetzner server ${SERVER_ID}..."
        hetzner_api DELETE "/servers/${SERVER_ID}" >/dev/null 2>&1 || true
        info "Server ${SERVER_ID} deleted."
    fi
}
trap cleanup EXIT

# ──────────────────────────────────────────────────────────────────────────────
# Hetzner API helper
# ──────────────────────────────────────────────────────────────────────────────
hetzner_api() {
    local method="$1" endpoint="$2"
    shift 2
    curl -s -X "${method}" \
        -H "Authorization: Bearer ${HCLOUD_TOKEN}" \
        -H "Content-Type: application/json" \
        "${HETZNER_API}${endpoint}" "$@"
}

# ──────────────────────────────────────────────────────────────────────────────
# Prerequisite checks & auto-install
# ──────────────────────────────────────────────────────────────────────────────
REQUIRED_CMDS=(curl jq ssh ssh-keygen openssl)

detect_pkg_manager() {
    local os
    os=$(uname -s)
    case "$os" in
        Darwin)
            PKG_MANAGER="brew"
            ;;
        Linux)
            if command -v apt-get &>/dev/null; then
                PKG_MANAGER="apt"
            elif command -v dnf &>/dev/null; then
                PKG_MANAGER="dnf"
                
            elif command -v yum &>/dev/null; then
                PKG_MANAGER="yum"
            elif command -v apk &>/dev/null; then
                PKG_MANAGER="apk"
            else
                PKG_MANAGER="unknown"
            fi
            ;;
        *)
            PKG_MANAGER="unknown"
            ;;
    esac
}

cmd_map() {
    # Map a required command name to its package name for the detected manager
    local cmd="$1"
    case "$PKG_MANAGER" in
        brew)
            case "$cmd" in
                curl)       echo "curl" ;;
                jq)         echo "jq" ;;
                ssh|ssh-keygen) echo "openssh" ;;
                openssl)    echo "openssl" ;;
            esac
            ;;
        apt)
            case "$cmd" in
                curl)       echo "curl" ;;
                jq)         echo "jq" ;;
                ssh|ssh-keygen) echo "openssh-client" ;;
                openssl)    echo "openssl" ;;
            esac
            ;;
        dnf|yum)
            case "$cmd" in
                curl)       echo "curl" ;;
                jq)         echo "jq" ;;
                ssh|ssh-keygen) echo "openssh-clients" ;;
                openssl)    echo "openssl" ;;
            esac
            ;;
        apk)
            case "$cmd" in
                curl)       echo "curl" ;;
                jq)         echo "jq" ;;
                ssh|ssh-keygen) echo "openssh-client" ;;
                openssl)    echo "openssl" ;;
            esac
            ;;
    esac
}

# Ensure we can gain root privileges (sudo or already root)
ensure_privileges() {
    if [[ "$(id -u)" -eq 0 ]]; then
        SUDO=""
        return 0
    fi
    if command -v sudo &>/dev/null; then
        SUDO="sudo"
        return 0
    fi
    return 1
}

run_pkg_install() {
    local pkgs=("$@")
    case "$PKG_MANAGER" in
        brew)
            "$SUDO" brew install "${pkgs[@]}"
            ;;
        apt)
            "$SUDO" apt-get update -y
            "$SUDO" apt-get install -y "${pkgs[@]}"
            ;;
        dnf)
            "$SUDO" dnf install -y "${pkgs[@]}"
            ;;
        yum)
            "$SUDO" yum install -y "${pkgs[@]}"
            ;;
        apk)
            "$SUDO" apk add --no-cache "${pkgs[@]}"
            ;;
        *)
            return 1
            ;;
    esac
}

install_missing_deps() {
    local missing=()
    local install_pkgs=()
    local os
    os=$(uname -s)

    detect_pkg_manager

    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "All local dependencies found"
        return 0
    fi

    warn "Missing required commands: ${missing[*]}"

    # No known package manager and no install path → manual instructions
    local has_brew=false
    if command -v brew &>/dev/null; then
        has_brew=true
    fi
    if [[ "$PKG_MANAGER" == "unknown" || ( "$os" == "Darwin" && "$has_brew" == "false" ) ]]; then
        error "Cannot auto-install on this system (no supported package manager detected)."
        error "Please install the following manually, then re-run this script:"
        for cmd in "${missing[@]}"; do
            error "  - ${cmd}"
        done
        case "$os" in
            Darwin)
                error "macOS: install Homebrew first: /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                ;;
            Linux)
                error "Linux: use your distribution's package manager (apt/dnf/yum/apk)."
                ;;
        esac
        fatal "Missing dependencies could not be installed"
    fi

    if [[ "$PKG_MANAGER" == "brew" && "$os" == "Linux" ]]; then
        # brew on Linux (Linuxbrew) — treat as unknown for install purposes
        error "Homebrew detected, but commands are missing. Please run: brew install ${missing[*]}"
        fatal "Missing dependencies could not be installed"
    fi

    # Map commands to packages
    for cmd in "${missing[@]}"; do
        local pkg
        pkg=$(cmd_map "$cmd")
        # Avoid duplicate packages (e.g. ssh and ssh-keygen → same pkg)
        if [[ -n "$pkg" ]] && ! printf '%s\n' "${install_pkgs[@]}" | grep -qx "$pkg"; then
            install_pkgs+=("$pkg")
        fi
    done

    if [[ ${#install_pkgs[@]} -eq 0 ]]; then
        error "Could not map missing commands to packages."
        error "Please install manually: ${missing[*]}"
        fatal "Missing dependencies could not be installed"
    fi

    if ! ensure_privileges; then
        error "Root/sudo access is required to install packages on this system."
        error "Please install manually, or re-run this script as root (or with sudo)."
        fatal "Missing dependencies could not be installed"
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would install packages: ${install_pkgs[*]} (via ${PKG_MANAGER})"
        return 0
    fi

    info "Installing ${install_pkgs[*]} via ${PKG_MANAGER}..."
    if ! run_pkg_install "${install_pkgs[@]}"; then
        fatal "Package install failed. Please install manually: ${missing[*]}"
    fi

    # Re-verify after install
    local still_missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            still_missing+=("$cmd")
        fi
    done

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        fatal "Still missing after install: ${still_missing[*]}"
    fi

    success "Installed missing dependencies"
}

check_local_deps() {
    step "Checking local dependencies"
    install_missing_deps
}

# ──────────────────────────────────────────────────────────────────────────────
# Read configuration from .env (loaded into env vars)
# ──────────────────────────────────────────────────────────────────────────────
collect_config() {
    step "Configuration"

    local missing_req=()

    # Required variables — must come from .env
    [[ -z "${HCLOUD_TOKEN:-}" ]] && missing_req+=("HCLOUD_TOKEN")
    [[ -z "${TAILSCALE_AUTH_KEY:-}" ]] && missing_req+=("TAILSCALE_AUTH_KEY")
    [[ -z "${DOMAIN:-}" ]] && missing_req+=("DOMAIN")

    if [[ ${#missing_req[@]} -gt 0 ]]; then
        error "Missing required variable(s) in ${ENV_FILE}: ${missing_req[*]}"
        error "Copy ${SCRIPT_DIR}/.env.example to ${ENV_FILE} and fill in the values."
        fatal "Configuration incomplete"
    fi

    # Optional variables — apply defaults if not set
    SERVER_NAME="${SERVER_NAME:-ghost-blog}"
    SERVER_TYPE="${SERVER_TYPE:-$DEFAULT_SERVER_TYPE}"
    SERVER_LOCATION="${SERVER_LOCATION:-$DEFAULT_SERVER_LOCATION}"
    GHOST_VERSION="${GHOST_VERSION:-$DEFAULT_GHOST_VERSION}"
    MYSQL_VERSION="${MYSQL_VERSION:-$DEFAULT_MYSQL_VERSION}"
    CADDY_VERSION="${CADDY_VERSION:-$DEFAULT_CADDY_VERSION}"

    # SSH key
    SSH_PUB_KEY=""
    if [[ -n "${SSH_KEY_PATH:-}" ]] && [[ -f "$SSH_KEY_PATH" ]]; then
        SSH_PUB_KEY=$(cat "$SSH_KEY_PATH")
    else
        for keyfile in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
            if [[ -f "$keyfile" ]]; then
                SSH_PUB_KEY=$(cat "$keyfile")
                SSH_KEY_PATH="$keyfile"
                break
            fi
        done
    fi
    if [[ -z "$SSH_PUB_KEY" ]]; then
        fatal "No SSH public key found. Set SSH_KEY_PATH in ${ENV_FILE} or create ~/.ssh/id_ed25519.pub"
    fi
    success "Using SSH key: ${SSH_KEY_PATH}"

    # Confirm
    echo ""
    info "Deployment summary:"
    info "  Server:       ${SERVER_NAME} (${SERVER_TYPE} @ ${SERVER_LOCATION})"
    info "  Domain:       ${DOMAIN}"
    info "  Ghost:        v${GHOST_VERSION}"
    info "  Image:        ${DEFAULT_IMAGE}"
    info "  SSH access:   Tailscale only (no public SSH)"
    echo ""
    read -rp "  Proceed? [y/N]: " confirm
    case "${confirm}" in
        [yY]|[yY][eE][sS]) ;;  # continue
        *) fatal "Aborted by user" ;;
    esac
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 1: Validate Hetzner token
# ──────────────────────────────────────────────────────────────────────────────
validate_hetzner() {
    step "Validating Hetzner API token"
    local resp
    resp=$(hetzner_api GET "/servers" 2>&1) || true
    if echo "$resp" | jq -e '.error' &>/dev/null; then
        local msg
        msg=$(echo "$resp" | jq -r '.error.message // .error')
        fatal "Hetzner API error: ${msg}"
    fi
    success "Hetzner API token valid"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 2: Provision Hetzner server
# ──────────────────────────────────────────────────────────────────────────────
provision_server() {
    step "Provisioning Hetzner server"

    # Upload SSH key if not already present
    local key_name="ghost-deploy-$(echo "$SSH_PUB_KEY" | awk '{print $NF}')" 
    local existing_keys
    existing_keys=$(hetzner_api GET "/ssh_keys" 2>/dev/null || echo '{"ssh_keys":[]}')
    local key_id
    key_id=$(echo "$existing_keys" | jq -r --arg name "$key_name" '.ssh_keys[] | select(.name == $name) | .name' 2>/dev/null || true)

    if [[ -z "$key_id" ]]; then
        info "Uploading SSH key '${key_name}'..."
        if [[ "$DRY_RUN" == "false" ]]; then
            hetzner_api POST "/ssh_keys" -d "{
                \"name\": \"${key_name}\",
                \"public_key\": \"${SSH_PUB_KEY}\"
            }" >/dev/null
        fi
        success "SSH key uploaded"
    else
        success "SSH key already exists"
    fi

    # Create cloud-init user data
    local user_data
    user_data=$(cat <<CLOUDINIT
#cloud-config
package_update: true
package_upgrade: true
packages:
  - curl
  - jq
  - ufw
  - fail2ban
runcmd:
  - curl -fsSL https://get.docker.com | sh
  - systemctl enable docker
  - curl -fsSL https://tailscale.com/install.sh | sh
  - tailscale up --ssh --hostname=${SERVER_NAME} --authkey=${TAILSCALE_AUTH_KEY}
  - adduser --disabled-password --gecos "" ${DEPLOY_USER}
  - usermod -aG sudo,docker ${DEPLOY_USER}
  - echo "${DEPLOY_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${DEPLOY_USER}
  - chmod 0440 /etc/sudoers.d/${DEPLOY_USER}
  - mkdir -p /home/${DEPLOY_USER}/.ssh
  - cp /root/.ssh/authorized_keys /home/${DEPLOY_USER}/.ssh/
  - chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh
  - chmod 0700 /home/${DEPLOY_USER}/.ssh
  - chmod 0600 /home/${DEPLOY_USER}/.ssh/authorized_keys
  - sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
  - sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
  - systemctl restart sshd
  - ufw default deny incoming
  - ufw default allow outgoing
  - ufw allow 80/tcp
  - ufw allow 443/tcp
  - ufw allow from ${TAILSCALE_CIDR} to any port 22 proto tcp
  - ufw --force enable
CLOUDINIT
    )

    local payload
    payload=$(jq -n \
        --arg name "$SERVER_NAME" \
        --arg type "$SERVER_TYPE" \
        --arg image "$DEFAULT_IMAGE" \
        --arg location "$SERVER_LOCATION" \
        --arg keyname "$key_name" \
        --arg userdata "$user_data" \
        '{
            name: $name,
            server_type: $type,
            image: $image,
            location: $location,
            ssh_keys: [$keyname],
            start_after_create: true,
            user_data: $userdata
        }')

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would create server with payload:"
        echo "$payload" | jq .
        SERVER_ID="dry-run-000"
        SERVER_IP="198.51.100.1"
        return
    fi

    local resp
    resp=$(hetzner_api POST "/servers" -d "$payload")

    if echo "$resp" | jq -e '.error' &>/dev/null; then
        local msg
        msg=$(echo "$resp" | jq -r '.error.message // .error')
        fatal "Failed to create server: ${msg}"
    fi

    SERVER_ID=$(echo "$resp" | jq -r '.server.id')
    SERVER_IP=$(echo "$resp" | jq -r '.server.public_net.ipv4.ip')

    info "Server created (ID: ${SERVER_ID}, IP: ${SERVER_IP})"
    info "Waiting for server to become ready..."

    # Poll until server is running
    local max_wait=180
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local status
        status=$(hetzner_api GET "/servers/${SERVER_ID}" | jq -r '.server.status')
        if [[ "$status" == "running" ]]; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "."
    done
    echo ""

    if [[ "$elapsed" -ge "$max_wait" ]]; then
        fatal "Server did not start within ${max_wait}s"
    fi

    # Wait a bit more for cloud-init to finish package installs
    info "Waiting 30s for cloud-init to finish initial setup..."
    sleep 30

    success "Server is running at ${SERVER_IP}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 3: Verify SSH via Tailscale & deploy
# ──────────────────────────────────────────────────────────────────────────────
wait_for_ssh() {
    step "Waiting for SSH access via public IP (for initial deploy)"

    local max_wait=120
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
            -o BatchMode=yes root@"${SERVER_IP}" "echo ok" &>/dev/null; then
            success "SSH connection established"
            return
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "."
    done
    echo ""
    fatal "Could not SSH into server within ${max_wait}s"
}

remote_exec() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute on server: $*"
        return
    fi
    ssh -o StrictHostKeyChecking=no root@"${SERVER_IP}" "$@"
}

remote_exec_as_deploy() {
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would execute as ${DEPLOY_USER}: $*"
        return
    fi
    ssh -o StrictHostKeyChecking=no root@"${SERVER_IP}" \
        "su - ${DEPLOY_USER} -c '$*'"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 4: Deploy Ghost stack
# ──────────────────────────────────────────────────────────────────────────────
deploy_ghost() {
    step "Deploying Ghost blog on server"

    # Generate secrets
    MYSQL_ROOT_PASSWORD=$(openssl rand -hex 32)
    MYSQL_PASSWORD=$(openssl rand -hex 16)

    remote_exec bash -c "
        mkdir -p ${GHOST_DIR}
        cd ${GHOST_DIR}

        cat > .env <<'ENVEOF'
DOMAIN=${DOMAIN}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MYSQL_USER=ghost
MYSQL_DATABASE=ghost
ENVEOF

        cat > docker-compose.yml <<'COMPOSEEOF'
services:
  ghost:
    image: ghost:${GHOST_VERSION}
    container_name: ghost-app
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      NODE_ENV: production
      url: https://\${DOMAIN}
      database__client: mysql
      database__connection__host: db
      database__connection__port: 3306
      database__connection__user: \${MYSQL_USER}
      database__connection__password: \${MYSQL_PASSWORD}
      database__connection__database: \${MYSQL_DATABASE}
    volumes:
      - ghost-content:/var/lib/ghost/content
    networks:
      - ghost-net

  db:
    image: mysql:${MYSQL_VERSION}
    container_name: ghost-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - ghost-db-data:/var/lib/mysql
    healthcheck:
      test: [\"CMD\", \"mysqladmin\", \"ping\", \"-h\", \"localhost\"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    networks:
      - ghost-net

  caddy:
    image: caddy:${CADDY_VERSION}
    container_name: ghost-caddy
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy-data:/data
      - caddy-config:/config
    depends_on:
      - ghost
    networks:
      - ghost-net

volumes:
  ghost-content:
  ghost-db-data:
  caddy-data:
  caddy-config:

networks:
  ghost-net:
    driver: bridge
COMPOSEEOF

        cat > Caddyfile <<'CADDYEOF'
${DOMAIN} {
    reverse_proxy ghost:2368

    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy strict-origin-when-cross-origin
        Strict-Transport-Security max-age=31536000; includeSubDomains; preload
    }

    encode gzip

    log {
        output stdout
    }
}

www.${DOMAIN} {
    redir https://${DOMAIN}{uri}
}
CADDYEOF

        chown -R ${DEPLOY_USER}:${DEPLOY_USER} ${GHOST_DIR}
    "

    success "Configuration files created"

    info "Pulling Docker images..."
    remote_exec_as_deploy "cd ${GHOST_DIR} && docker compose pull"

    info "Starting Ghost stack..."
    remote_exec_as_deploy "cd ${GHOST_DIR} && docker compose up -d"

    # Wait for Ghost to be healthy
    info "Waiting for Ghost to start..."
    local max_wait=60
    local elapsed=0
    while [[ $elapsed -lt $max_wait ]]; do
        local health
        health=$(remote_exec_as_deploy "cd ${GHOST_DIR} && docker compose ps ghost --format json 2>/dev/null" | jq -r '.State // empty' 2>/dev/null || true)
        if [[ "$health" == "running" ]]; then
            break
        fi
        sleep 5
        elapsed=$((elapsed + 5))
        printf "."
    done
    echo ""

    success "Ghost blog is running"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 5: Hetzner Cloud Firewall (block public SSH at cloud level)
# ──────────────────────────────────────────────────────────────────────────────
configure_hetzner_firewall() {
    step "Configuring Hetzner Cloud Firewall"

    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would create firewall blocking public SSH"
        return
    fi

    local firewall_payload
    firewall_payload=$(jq -n '{
        name: "ghost-ssh-restricted",
        rules: [
            {
                direction: "in",
                protocol: "tcp",
                port: "80",
                source_ips: ["0.0.0.0/0", "::/0"],
                description: "HTTP"
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "443",
                source_ips: ["0.0.0.0/0", "::/0"],
                description: "HTTPS"
            },
            {
                direction: "in",
                protocol: "tcp",
                port: "22",
                source_ips: ["100.64.0.0/10", "::/0"],
                description: "SSH via Tailscale only"
            }
        ]
    }')

    local resp
    resp=$(hetzner_api POST "/firewalls" -d "$firewall_payload" 2>&1)

    if echo "$resp" | jq -e '.error' &>/dev/null; then
        warn "Could not create Hetzner firewall: $(echo "$resp" | jq -r '.error.message')"
        warn "UFW on the server is already blocking public SSH. Continuing..."
        return
    fi

    local fw_id
    fw_id=$(echo "$resp" | jq -r '.firewall.id')
    info "Firewall created (ID: ${fw_id})"

    # Apply firewall to server
    hetzner_api POST "/firewalls/${fw_id}/actions/apply_to_resources" -d "{
        \"apply_to\": [{
            \"type\": \"server\",
            \"server\": { \"id\": ${SERVER_ID} }
        }]
    }" >/dev/null

    success "Firewall applied — public SSH is now blocked"
}

# ──────────────────────────────────────────────────────────────────────────────
# Phase 6: Output instructions
# ──────────────────────────────────────────────────────────────────────────────
print_results() {
    step "Deployment Complete"
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  Ghost Blog Deployed Successfully${NC}"
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Ghost URL:${NC}      https://${DOMAIN}"
    echo -e "  ${CYAN}Ghost Admin:${NC}    https://${DOMAIN}/ghost"
    echo -e "  ${CYAN}Server IP:${NC}      ${SERVER_IP} (not SSH-accessible)"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  DNS Setup Required${NC}"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  Add these DNS records at your domain registrar or DNS provider:"
    echo ""
    echo "    Type  Name   Value           TTL"
    echo "    ────  ────   ─────           ───"
    echo "    A     blog   ${SERVER_IP}     Auto"
    echo ""
    echo "  Also set up a reverse DNS (PTR) record for ${SERVER_IP}"
    echo "  pointing to ${DOMAIN} (in Hetzner Cloud console → Networking)."
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  SSH Access (Tailscale Only)${NC}"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1. Install Tailscale on your local machine:"
    echo "     macOS:   brew install tailscale && sudo tailscale up"
    echo "     Linux:   curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"
    echo "     Windows: https://tailscale.com/download"
    echo ""
    echo "  2. Make sure Tailscale is connected on both machines:"
    echo "     tailscale status"
    echo ""
    echo "  3. SSH to the server:"
    echo "     ssh ${DEPLOY_USER}@${SERVER_NAME}"
    echo ""
    echo "  Or add to ~/.ssh/config:"
    echo ""
    echo "    Host ${SERVER_NAME}"
    echo "        HostName ${SERVER_NAME}"
    echo "        User ${DEPLOY_USER}"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  Credentials (save these!)${NC}"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  MySQL Root Password: ${MYSQL_ROOT_PASSWORD}"
    echo "  MySQL Ghost Password: ${MYSQL_PASSWORD}"
    echo "  Ghost config dir:    ${GHOST_DIR}"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  Next Steps${NC}"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  1. Wait for DNS to propagate (usually 5-15 minutes)"
    echo "  2. Open https://${DOMAIN}/ghost in your browser"
    echo "  3. Create your Ghost admin account (first visit only)"
    echo "  4. Configure your blog title, theme, and settings"
    echo ""
    echo "  Management commands (via Tailscale SSH):"
    echo "    cd ${GHOST_DIR} && docker compose logs -f        # View logs"
    echo "    cd ${GHOST_DIR} && docker compose restart        # Restart"
    echo "    cd ${GHOST_DIR} && docker compose pull && docker compose up -d  # Update"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD}  Teardown${NC}"
    echo -e "${BOLD}──────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo "  To destroy everything:"
    echo "    ./$(basename "$0") --teardown --server-id ${SERVER_ID}"
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════════════════════════${NC}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Teardown
# ──────────────────────────────────────────────────────────────────────────────
do_teardown() {
    step "Tearing down resources"

    if [[ -z "${SERVER_ID:-}" ]]; then
        read -rp "  Hetzner Server ID or name: " SERVER_ID
    fi

    # If name given, look up ID
    if [[ ! "$SERVER_ID" =~ ^[0-9]+$ ]]; then
        local resp
        resp=$(hetzner_api GET "/servers" 2>/dev/null)
        SERVER_ID=$(echo "$resp" | jq -r --arg name "$SERVER_ID" '.servers[] | select(.name == $name) | .id' | head -1)
        if [[ -z "$SERVER_ID" || "$SERVER_ID" == "null" ]]; then
            fatal "Server not found"
        fi
    fi

    info "Deleting server ${SERVER_ID}..."
    hetzner_api DELETE "/servers/${SERVER_ID}" >/dev/null 2>&1
    success "Server deleted"

    # Optionally clean up firewall
    local firewalls
    firewalls=$(hetzner_api GET "/firewalls" 2>/dev/null || echo '{"firewalls":[]}')
    local fw_id
    fw_id=$(echo "$firewalls" | jq -r '.firewalls[] | select(.name == "ghost-ssh-restricted") | .id' | head -1)
    if [[ -n "$fw_id" && "$fw_id" != "null" ]]; then
        info "Deleting firewall ${fw_id}..."
        hetzner_api DELETE "/firewalls/${fw_id}" >/dev/null 2>&1
        success "Firewall deleted"
    fi

    echo ""
    success "All resources destroyed. No further charges."
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────
main() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  Ghost Blog — Hetzner + Tailscale Deployer  v${SCRIPT_VERSION}         ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Parse flags
    local i
    for (( i=1; i <= $#; i++ )); do
        arg="${!i}"
        case "$arg" in
            --dry-run)   DRY_RUN=true ;;
            --teardown)  TEARDOWN=true ;;
            --server-id)
                if [[ $((i+1)) -gt $# ]]; then
                    fatal "--server-id requires a value"
                fi
                i=$((i+1))
                SERVER_ID="${!i}"
                ;;
            -h|--help)
                echo "Usage: $0 [--dry-run] [--teardown [--server-id ID]]"
                echo ""
                echo "  --dry-run     Preview changes without creating anything"
                echo "  --teardown    Destroy the deployed server and firewall"
                echo "  --server-id   Server ID for teardown (interactive if omitted)"
                echo ""
                echo "Configuration is read from ${ENV_FILE}. Copy ${SCRIPT_DIR}/.env.example"
                echo "to ${ENV_FILE} and fill in the required values."
                exit 0
                ;;
        esac
    done

    # Load environment variables from .env (required)
    load_env

    if [[ "$TEARDOWN" == "true" ]]; then
        collect_config 2>/dev/null || true
        validate_hetzner
        do_teardown
        exit 0
    fi

    check_local_deps
    collect_config
    validate_hetzner
    provision_server
    wait_for_ssh
    deploy_ghost
    configure_hetzner_firewall
    print_results
}

main "$@"
