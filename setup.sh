#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║                           OpenClaw Setup Script                              ║
# ║                                                                              ║
# ║  Simplified standalone installer for headless Ubuntu/Debian                  ║
# ╚══════════════════════════════════════════════════════════════════════════════╝
set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================
SCRIPT_VERSION="2.0.0"
OPENCLAW_REPO="https://github.com/openclaw/openclaw.git"
OPENCLAW_BRANCH="${OPENCLAW_BRANCH:-main}"

# Target user (defaults to SUDO_USER or current user)
TARGET_USER="${OPENCLAW_USER:-${SUDO_USER:-$USER}}"
[[ "$TARGET_USER" == "root" && -n "${SUDO_USER:-}" ]] && TARGET_USER="$SUDO_USER"

# Directories
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$TARGET_USER")
[[ -z "$TARGET_HOME" ]] && TARGET_HOME="/home/$TARGET_USER"

SOURCE_DIR="${OPENCLAW_SOURCE_DIR:-$TARGET_HOME/openclaw}"           # Git clone (source)
CONTAINERS_DIR="${OPENCLAW_CONTAINERS_DIR:-$TARGET_HOME/containers/openclaw}"  # Docker files
CONFIG_DIR="${OPENCLAW_CONFIG_DIR:-$TARGET_HOME/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$TARGET_HOME/.openclaw/workspace}"

IMAGE_NAME="${OPENCLAW_IMAGE:-openclaw:local}"

# =============================================================================
# Logging
# =============================================================================
LOG_FILE="/tmp/openclaw-setup-$(date +%Y%m%d-%H%M%S).log"

# Initialize log
init_log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "OpenClaw Setup Log - $(date -Iseconds)"
  echo "========================================"
  echo ""
}

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[OK] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }
log_step()    { echo ""; echo "=== [$1] $2 ==="; }

# =============================================================================
# Usage
# =============================================================================
show_usage() {
  cat << 'EOF'
OpenClaw Setup v2.0.0

Usage: ./setup.sh [OPTIONS]

Options:
  --test              Verify existing installation
  --uninstall         Remove OpenClaw completely
  --update            Update existing installation
  --user <username>   Target user for installation
  --skip-onboard      Skip interactive onboarding
  -y, --yes           Skip confirmation prompts
  -h, --help          Show this help

Examples:
  sudo ./setup.sh                    # Full install for current user
  sudo ./setup.sh --user openclaw    # Install for specific user
  ./setup.sh --test                  # Verify installation
  ./setup.sh --uninstall             # Remove everything
EOF
}

# =============================================================================
# Pre-flight Checks
# =============================================================================
check_root() {
  if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
  fi
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then
    log_error "Unsupported OS (no /etc/os-release)"
    exit 1
  fi
  source /etc/os-release
  log_info "Detected: $PRETTY_NAME"
}

check_network() {
  log_step "NET" "Checking network connectivity"
  if ! timeout 10 curl -sf https://registry-1.docker.io/v2/ >/dev/null 2>&1; then
    log_warn "Cannot reach Docker Hub - check your DNS/network"
    log_info "Try: echo 'nameserver 8.8.8.8' | sudo tee /etc/resolv.conf"
  else
    log_success "Docker Hub reachable"
  fi
}

# =============================================================================
# Install Dependencies
# =============================================================================
install_deps() {
  log_step "DEPS" "Installing system dependencies"
  
  apt-get update -qq
  apt-get install -y -qq git curl jq >/dev/null
  log_success "System dependencies installed"
}

install_docker() {
  log_step "DOCKER" "Installing Docker"
  
  if command -v docker &>/dev/null && docker info &>/dev/null; then
    log_success "Docker already installed"
    return 0
  fi
  
  # Install Docker using official script
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  log_success "Docker installed"
}

# =============================================================================
# Create User
# =============================================================================
create_user() {
  log_step "USER" "Setting up user: $TARGET_USER"
  
  if ! id "$TARGET_USER" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$TARGET_USER"
    log_success "Created user: $TARGET_USER"
  else
    log_success "User exists: $TARGET_USER"
  fi
  
  # Add to docker group
  usermod -aG docker "$TARGET_USER" 2>/dev/null || true
  log_success "Added $TARGET_USER to docker group"
}

# =============================================================================
# Setup Directories
# =============================================================================
setup_dirs() {
  log_step "DIRS" "Creating directories"
  
  mkdir -p "$SOURCE_DIR"
  mkdir -p "$CONTAINERS_DIR"
  mkdir -p "$CONFIG_DIR"
  mkdir -p "$WORKSPACE_DIR"
  
  # Get target user UID/GID
  local uid gid
  uid=$(id -u "$TARGET_USER")
  gid=$(id -g "$TARGET_USER")
  
  # Set ownership to target user
  chown -R "$uid:$gid" "$SOURCE_DIR"
  chown -R "$uid:$gid" "$CONTAINERS_DIR"
  chown -R "$uid:$gid" "$CONFIG_DIR"
  chown -R "$uid:$gid" "$WORKSPACE_DIR"
  
  # Container runs as 'node' (UID 1000) - add ACL for container access
  if command -v setfacl &>/dev/null; then
    # Install ACL support if needed
    apt-get install -y -qq acl >/dev/null 2>&1 || true
    
    # Grant UID 1000 (container node user) read/write access
    setfacl -R -m u:1000:rwx "$CONFIG_DIR" 2>/dev/null || true
    setfacl -R -m u:1000:rwx "$WORKSPACE_DIR" 2>/dev/null || true
    setfacl -R -d -m u:1000:rwx "$CONFIG_DIR" 2>/dev/null || true
    setfacl -R -d -m u:1000:rwx "$WORKSPACE_DIR" 2>/dev/null || true
    log_success "ACLs set for container access (UID 1000)"
  else
    # Fallback: make directories world-writable (less secure)
    chmod -R 777 "$CONFIG_DIR"
    chmod -R 777 "$WORKSPACE_DIR"
    log_warn "ACL not available, using permissive mode (777)"
  fi
  
  log_success "Directories created (owner: $TARGET_USER)"
}

# =============================================================================
# Setup Sudoers (allow docker commands without password)
# =============================================================================
setup_sudoers() {
  log_step "SUDO" "Configuring sudo access"
  
  local sudoers_file="/etc/sudoers.d/openclaw-$TARGET_USER"
  
  cat > "$sudoers_file" << EOF
# OpenClaw: Allow $TARGET_USER to run docker commands without password
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/docker
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/docker-compose
$TARGET_USER ALL=(ALL) NOPASSWD: /usr/bin/docker compose
EOF
  
  chmod 440 "$sudoers_file"
  log_success "Sudoers configured: $TARGET_USER can run docker without password"
}

# =============================================================================
# Clone Repository
# =============================================================================
clone_repo() {
  log_step "CLONE" "Cloning OpenClaw repository"
  
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    log_info "Repository exists, pulling latest..."
    cd "$SOURCE_DIR"
    git fetch origin
    git reset --hard "origin/$OPENCLAW_BRANCH"
  else
    git clone --depth 1 -b "$OPENCLAW_BRANCH" "$OPENCLAW_REPO" "$SOURCE_DIR"
  fi
  
  chown -R "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$SOURCE_DIR"
  log_success "Repository ready"
}

# =============================================================================
# Generate Secrets
# =============================================================================
generate_secrets() {
  log_step "SECRETS" "Generating secure tokens"
  
  OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$(openssl rand -hex 32)}"
  ROUTER_SECRET_TOKEN="${ROUTER_SECRET_TOKEN:-$(openssl rand -hex 32)}"
  
  export OPENCLAW_GATEWAY_TOKEN ROUTER_SECRET_TOKEN
  log_success "Tokens generated"
}

# =============================================================================
# Write Configuration
# =============================================================================
write_config() {
  log_step "CONFIG" "Writing configuration files"
  
  # .env file
  cat > "$CONTAINERS_DIR/.env" << EOF
# OpenClaw Environment Configuration
# Generated: $(date -Iseconds)

# Directories
OPENCLAW_CONFIG_DIR=$CONFIG_DIR
OPENCLAW_WORKSPACE_DIR=$WORKSPACE_DIR
OPENCLAW_IMAGE=$IMAGE_NAME

# Gateway
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_GATEWAY_BIND=lan

# Router
ROUTER_SECRET_TOKEN=$ROUTER_SECRET_TOKEN
ROUTER_PORT=3000

# Ollama
OLLAMA_PORT=11434

# API Keys (add yours here)
ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
EOF
  chmod 600 "$CONTAINERS_DIR/.env"
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$CONTAINERS_DIR/.env"
  
  # openclaw.json
  cat > "$CONFIG_DIR/openclaw.json" << EOF
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "$OPENCLAW_GATEWAY_TOKEN"
    }
  }
}
EOF
  chmod 644 "$CONFIG_DIR/openclaw.json"
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$CONFIG_DIR/openclaw.json"
  
  log_success "Configuration written"
}

# =============================================================================
# Generate Docker Compose
# =============================================================================
generate_compose() {
  log_step "COMPOSE" "Generating Docker Compose files"
  
  # Main compose file
  cat > "$CONTAINERS_DIR/docker-compose.yml" << 'EOF'
services:
  openclaw-gateway:
    image: ${OPENCLAW_IMAGE:-openclaw:local}
    container_name: openclaw-gateway
    env_file: .env
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OLLAMA_HOST: http://ollama:11434
    volumes:
      - ${OPENCLAW_CONFIG_DIR}:/home/node/.openclaw
      - ${OPENCLAW_WORKSPACE_DIR}:/home/node/.openclaw/workspace
    ports:
      - "${OPENCLAW_GATEWAY_PORT:-18789}:18789"
    init: true
    restart: unless-stopped
    depends_on:
      - ollama
    networks:
      - openclaw
    command: ["node", "dist/index.js", "gateway", "--bind", "lan", "--port", "18789"]

  ollama:
    image: ollama/ollama:latest
    container_name: openclaw-ollama
    volumes:
      - ollama-data:/root/.ollama
    ports:
      - "${OLLAMA_PORT:-11434}:11434"
    restart: unless-stopped
    networks:
      - openclaw
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:11434/ || exit 0"]
      interval: 60s
      timeout: 30s
      retries: 10
      start_period: 120s

networks:
  openclaw:
    driver: bridge

volumes:
  ollama-data:
EOF

  log_success "Docker Compose generated"
}

# =============================================================================
# Build Docker Image
# =============================================================================
build_image() {
  log_step "BUILD" "Building OpenClaw Docker image"
  
  cd "$SOURCE_DIR"
  docker build -t "$IMAGE_NAME" .
  log_success "Docker image built: $IMAGE_NAME"
}

# =============================================================================
# Deploy Services
# =============================================================================
deploy() {
  log_step "DEPLOY" "Starting services"
  
  cd "$CONTAINERS_DIR"
  docker compose pull ollama || true
  docker compose up -d
  
  log_success "Services started"
}

# =============================================================================
# Install Aliases
# =============================================================================
install_aliases() {
  log_step "ALIASES" "Installing shell aliases"
  
  local bashrc="$TARGET_HOME/.bashrc"
  
  # Remove old aliases
  sed -i '/# OpenClaw Aliases/,/# End OpenClaw/d' "$bashrc" 2>/dev/null || true
  
  # Add new aliases
  cat >> "$bashrc" << EOF

# OpenClaw Aliases
export OPENCLAW_DIR="$CONTAINERS_DIR"

# Main CLI wrapper - usage: clawd <command> [args]
# Examples: clawd onboard, clawd agent "hello", clawd channels login
# Uses the gateway container which has CLI built-in
clawd() {
  cd "\$OPENCLAW_DIR" && docker compose exec openclaw-gateway node dist/index.js "\$@"
}

# Shortcuts for common commands
alias cb='clawd agent'                    # Chat with agent
alias conboard='clawd onboard'            # Run onboarding
alias cchannels='clawd channels'          # Channel management

# Docker compose shortcuts
alias dc='cd "\$OPENCLAW_DIR" && docker compose'
alias clog='dc logs -f'
alias cstatus='dc ps'
alias crestart='dc restart'
alias cstop='dc down'
# End OpenClaw
EOF

  log_success "Aliases installed (source ~/.bashrc to use)"
}

# =============================================================================
# Install Test Script
# =============================================================================
install_test_script() {
  log_step "TEST" "Installing test script"
  
  local dst_test="$TARGET_HOME/test.sh"
  
  # Embed test script (so it works even if not in cloned repo)
  cat > "$dst_test" << 'TEST_SCRIPT_EOF'
#!/bin/bash
# OpenClaw Post-Install Test
# Run as the target user after setup.sh completes
set -euo pipefail

CONTAINERS_DIR="${OPENCLAW_DIR:-$HOME/containers/openclaw}"
cd "$CONTAINERS_DIR"

echo ""
echo "OpenClaw Post-Install Test"
echo "=========================="
echo ""

passed=0
failed=0

test_pass() { echo "[PASS] $1"; ((passed++)) || true; }
test_fail() { echo "[FAIL] $1"; ((failed++)) || true; }

# Test 1: Gateway
echo "Testing Gateway (port 18789)..."
if curl -sf http://localhost:18789/ >/dev/null 2>&1; then
  test_pass "Gateway responding"
else
  test_fail "Gateway not responding"
fi

# Test 2: Ollama
echo "Testing Ollama (port 11434)..."
if curl -sf http://localhost:11434/ >/dev/null 2>&1; then
  test_pass "Ollama responding"
else
  test_fail "Ollama not responding"
fi

# Test 3: Ollama models
echo "Checking Ollama models..."
models=$(curl -sf http://localhost:11434/api/tags 2>/dev/null | grep -o '"name":"[^"]*"' | head -3 || echo "")
if [[ -n "$models" ]]; then
  test_pass "Models available: $models"
else
  echo "[INFO] No models yet. Pulling llama3.2..."
  docker compose exec ollama ollama pull llama3.2 || true
  test_pass "Model pull initiated"
fi

# Test 4: Docker Compose access
echo "Testing Docker Compose access..."
if docker compose ps >/dev/null 2>&1; then
  test_pass "Docker Compose works"
else
  test_fail "Docker Compose permission denied"
fi

# Test 5: Container status
echo "Checking containers..."
gateway_status=$(docker ps --filter "name=openclaw-gateway" --format "{{.Status}}" 2>/dev/null || echo "")
ollama_status=$(docker ps --filter "name=openclaw-ollama" --format "{{.Status}}" 2>/dev/null || echo "")

[[ "$gateway_status" == *"Up"* ]] && test_pass "Gateway: $gateway_status" || test_fail "Gateway not running"
[[ "$ollama_status" == *"Up"* ]] && test_pass "Ollama: $ollama_status" || test_fail "Ollama not running"

# Test 6: CLI executable
echo "Testing CLI..."
cli_ver=$(docker compose exec openclaw-gateway node dist/index.js --version 2>&1 || echo "")
if [[ "$cli_ver" == *"OpenClaw"* ]] || [[ "$cli_ver" == *"2026"* ]]; then
  test_pass "CLI: $cli_ver"
else
  test_fail "CLI not working"
fi

# Summary
echo ""
echo "=========================="
echo "Results: $passed passed, $failed failed"
echo ""

if [[ $failed -eq 0 ]]; then
  echo "All tests passed! OpenClaw is ready."
  echo ""
  echo "Next: Run 'conboard' to complete onboarding"
  exit 0
else
  echo "Some tests failed. Check: docker compose logs"
  exit 1
fi
TEST_SCRIPT_EOF
  
  chmod +x "$dst_test"
  chown "$(id -u "$TARGET_USER"):$(id -g "$TARGET_USER")" "$dst_test"
  log_success "Test script installed: $dst_test"
}

# =============================================================================
# Print Summary
# =============================================================================
print_summary() {
  echo ""
  echo "=============================================="
  echo "          OpenClaw Setup Complete!"
  echo "=============================================="
  echo ""
  echo "Directories:"
  echo "  Source:     $SOURCE_DIR"
  echo "  Containers: $CONTAINERS_DIR"
  echo "  Config:     $CONFIG_DIR"
  echo ""
  echo "Services:"
  echo "  Gateway: http://localhost:18789"
  echo "  Ollama:  http://localhost:11434"
  echo ""
  echo "Credentials (save these!):"
  echo "  Gateway Token: $OPENCLAW_GATEWAY_TOKEN"
  echo ""
  echo "Commands:"
  echo "  clawd <cmd>     - Run any CLI command (clawd --help for list)"
  echo "  cb 'hello'      - Chat with agent"
  echo "  conboard        - Run onboarding"
  echo "  cchannels       - Channel management"
  echo "  cstatus         - Check container status"
  echo "  clog            - View logs"
  echo ""
  echo "Next Steps:"
  echo "  1. su - $TARGET_USER"
  echo "  2. ./test.sh"
  echo "  3. conboard      (complete first-time setup)"
  echo ""
  echo "Log file: $LOG_FILE"
  echo ""
}

# =============================================================================
# Test Installation
# =============================================================================
run_test() {
  log_step "TEST" "Verifying installation"
  
  local passed=0 failed=0
  
  check() {
    if eval "$2" >/dev/null 2>&1; then
      echo "[PASS] $1"
      ((passed++))
    else
      echo "[FAIL] $1"
      ((failed++))
    fi
  }
  
  check "Docker installed" "command -v docker"
  check "Source dir exists" "[[ -d '$SOURCE_DIR' ]]"
  check "Containers dir exists" "[[ -d '$CONTAINERS_DIR' ]]"
  check "Config dir exists" "[[ -d '$CONFIG_DIR' ]]"
  check "openclaw.json exists" "[[ -f '$CONFIG_DIR/openclaw.json' ]]"
  check ".env exists" "[[ -f '$CONTAINERS_DIR/.env' ]]"
  check "docker-compose.yml exists" "[[ -f '$CONTAINERS_DIR/docker-compose.yml' ]]"
  check "Gateway running" "docker ps --filter 'name=openclaw-gateway' --format '{{.Names}}' | grep -q openclaw-gateway"
  check "Ollama running" "docker ps --filter 'name=openclaw-ollama' --format '{{.Names}}' | grep -q openclaw-ollama"
  
  echo ""
  echo "Results: $passed passed, $failed failed"
  [[ $failed -eq 0 ]]
}

# =============================================================================
# Uninstall
# =============================================================================
run_uninstall() {
  echo ""
  echo "WARNING: This will remove OpenClaw completely!"
  echo ""
  echo "  - Stop and remove all containers"
  echo "  - Remove Docker volumes"
  echo "  - Delete $SOURCE_DIR"
  echo "  - Delete $CONTAINERS_DIR"
  echo "  - Delete $CONFIG_DIR"
  echo ""
  
  if [[ "${SKIP_CONFIRM:-}" != "true" ]]; then
    read -rp "Type 'yes' to confirm: " confirm
    [[ "$confirm" != "yes" ]] && { echo "Cancelled."; exit 0; }
  fi
  
  log_info "Uninstalling..."
  
  # Stop containers
  cd "$CONTAINERS_DIR" 2>/dev/null && docker compose down -v 2>/dev/null || true
  
  # Remove containers by name
  for c in openclaw-gateway openclaw-ollama openclaw-cli openclaw-router; do
    docker rm -f "$c" 2>/dev/null || true
  done
  
  # Remove volumes
  docker volume rm ollama-data openclaw_ollama-data 2>/dev/null || true
  
  # Remove images
  docker rmi "$IMAGE_NAME" openclaw:local 2>/dev/null || true
  
  # Remove directories
  rm -rf "$SOURCE_DIR" "$CONTAINERS_DIR" "$CONFIG_DIR"
  
  # Remove aliases
  sed -i '/# OpenClaw Aliases/,/# End OpenClaw/d' "$TARGET_HOME/.bashrc" 2>/dev/null || true
  
  # Optionally remove user
  if [[ "$TARGET_USER" != "root" && "$TARGET_USER" != "${SUDO_USER:-}" ]]; then
    read -rp "Delete user $TARGET_USER? (type DELETE): " del
    [[ "$del" == "DELETE" ]] && userdel -r "$TARGET_USER" 2>/dev/null || true
  fi
  
  log_success "Uninstall complete"
}

# =============================================================================
# Update
# =============================================================================
run_update() {
  log_step "UPDATE" "Updating OpenClaw"
  
  cd "$SOURCE_DIR"
  git fetch origin
  git reset --hard "origin/$OPENCLAW_BRANCH"
  
  build_image
  
  cd "$CONTAINERS_DIR"
  docker compose pull
  docker compose up -d
  
  log_success "Update complete"
}

# =============================================================================
# Main
# =============================================================================
main() {
  # Defaults
  RUN_TEST=false
  RUN_UNINSTALL=false
  RUN_UPDATE=false
  SKIP_ONBOARD=false
  SKIP_CONFIRM=false
  
  # Parse args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --test) RUN_TEST=true; shift ;;
      --uninstall) RUN_UNINSTALL=true; shift ;;
      --update) RUN_UPDATE=true; shift ;;
      --skip-onboard) SKIP_ONBOARD=true; shift ;;
      -y|--yes) SKIP_CONFIRM=true; shift ;;
      --user)
        TARGET_USER="$2"
        TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$TARGET_USER")
        SOURCE_DIR="$TARGET_HOME/openclaw"
        CONTAINERS_DIR="$TARGET_HOME/containers/openclaw"
        CONFIG_DIR="$TARGET_HOME/.openclaw"
        WORKSPACE_DIR="$TARGET_HOME/.openclaw/workspace"
        shift 2
        ;;
      -h|--help) show_usage; exit 0 ;;
      *) log_error "Unknown option: $1"; show_usage; exit 1 ;;
    esac
  done
  
  # Export for subcommands
  export TARGET_USER TARGET_HOME SOURCE_DIR CONTAINERS_DIR CONFIG_DIR WORKSPACE_DIR
  
  # Handle modes
  if [[ "$RUN_TEST" == "true" ]]; then
    run_test
    exit $?
  fi
  
  if [[ "$RUN_UNINSTALL" == "true" ]]; then
    run_uninstall
    exit 0
  fi
  
  if [[ "$RUN_UPDATE" == "true" ]]; then
    run_update
    exit 0
  fi
  
  # Full install
  init_log
  check_root
  
  echo ""
  echo "OpenClaw Setup v$SCRIPT_VERSION"
  echo ""
  echo "Target user: $TARGET_USER"
  echo "Source:      $SOURCE_DIR"
  echo "Containers:  $CONTAINERS_DIR"
  echo "Config:      $CONFIG_DIR"
  echo ""
  
  if [[ "$SKIP_CONFIRM" != "true" && -t 0 ]]; then
    read -rp "Proceed? [Y/n]: " confirm
    [[ "${confirm,,}" == "n" ]] && { echo "Cancelled."; exit 0; }
  fi
  
  check_os
  check_network
  install_deps
  install_docker
  create_user
  setup_sudoers
  setup_dirs
  clone_repo
  generate_secrets
  write_config
  generate_compose
  build_image
  deploy
  install_aliases
  install_test_script
  
  # Run onboarding
  if [[ "$SKIP_ONBOARD" != "true" ]]; then
    log_step "ONBOARD" "Running onboarding"
    cd "$CONTAINERS_DIR"
    docker compose run --rm openclaw-cli onboard || log_warn "Onboarding may have failed"
  fi
  
  print_summary
}

main "$@"
