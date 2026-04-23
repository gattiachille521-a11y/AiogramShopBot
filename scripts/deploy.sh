#!/bin/sh
set -eu

REPO_URL="https://github.com/ilyarolf/AiogramShopBot.git"
PROJECT_DIR="AiogramShopBot"
SUPPORTED_CURRENCIES="USD EUR GBP JPY CHF AUD CAD CNY HKD SGD SEK NOK DKK PLN CZK HUF TRY INR KRW THB IDR MYR PHP VND AED SAR ZAR NGN KES GHS BRL MXN ARS CLP COP PEN RUB UAH ILS PKR BDT LKR TWD BHD KWD RON NZD"

say() {
  printf '%s\n' "$*"
}

say_err() {
  printf '%s\n' "$*" >&2
}

say "🚀 Starting deployment..."

# -------------------------
# Helpers
# -------------------------

generate_secret() {
  openssl rand -hex 16
}

validate_currency() {
  case " $SUPPORTED_CURRENCIES " in
    *" $1 "*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_admin_ids() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+(,[0-9]+)*$'
}

validate_support_link() {
  printf '%s\n' "$1" | grep -Eq '^https://'
}

validate_btc() {
  printf '%s\n' "$1" | grep -Eq '^bc1[a-zA-HJ-NP-Z0-9]{25,39}$'
}

validate_ltc() {
  printf '%s\n' "$1" | grep -Eq '^ltc1[a-zA-HJ-NP-Z0-9]{26,}$'
}

validate_eth() {
  printf '%s\n' "$1" | grep -Eq '^0x[a-fA-F0-9]{40}$'
}

validate_bnb() {
  printf '%s\n' "$1" | grep -Eq '^0x[a-fA-F0-9]{40}$'
}

validate_sol() {
  printf '%s\n' "$1" | grep -Eq '^[1-9A-HJ-NP-Za-km-z]{32,44}$'
}

validate_doge() {
  printf '%s\n' "$1" | grep -Eq '^(D|A|9)[a-km-zA-HJ-NP-Z1-9]{25,34}$'
}

read_crypto_address() {
  COIN="$1"
  VALIDATOR="$2"

  while :; do
    printf "%s forwarding address: " "$COIN" >&2
    IFS= read -r ADDR
    if "$VALIDATOR" "$ADDR"; then
      printf '%s\n' "$ADDR"
      return
    fi
    say_err "❌ Invalid $COIN address"
  done
}

validate_telegram_token() {
  curl -fs "https://api.telegram.org/bot$1/getMe"
}

# -------------------------
# Docker install/check
# -------------------------

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

run_as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    say_err "❌ Root privileges are required. Re-run as root or install sudo."
    return 1
  fi
}

detect_os() {
  if [ ! -r /etc/os-release ]; then
    say_err "❌ /etc/os-release not found; cannot detect Linux distribution."
    return 1
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"

  say "🐧 Detected OS: $OS_NAME"
}

install_docker_apt() {
  command_exists apt-get || return 1

  say "🐳 Installing Docker with apt..."
  run_as_root apt-get update &&
    run_as_root apt-get install -y ca-certificates curl gnupg docker.io docker-compose-plugin
}

install_docker_rhel() {
  if command_exists dnf; then
    PM="dnf"
  elif command_exists yum; then
    PM="yum"
  else
    return 1
  fi

  say "🐳 Installing Docker with $PM..."

  # First try packages commonly available in distribution repositories.
  if run_as_root "$PM" install -y docker docker-compose-plugin; then
    return 0
  fi

  if run_as_root "$PM" install -y moby-engine docker-compose-plugin; then
    return 0
  fi

  # Then try the official Docker repository through the native package manager.
  if [ "$PM" = "dnf" ]; then
    run_as_root dnf install -y dnf-plugins-core || true
    if command_exists dnf-3; then
      run_as_root dnf-3 config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    else
      run_as_root dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    fi
  else
    run_as_root yum install -y yum-utils || true
    run_as_root yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
  fi

  run_as_root "$PM" install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_arch() {
  command_exists pacman || return 1

  say "🐳 Installing Docker with pacman..."
  run_as_root pacman -Sy --noconfirm docker docker-compose
}

install_docker_alpine() {
  command_exists apk || return 1

  say "🐳 Installing Docker with apk..."
  run_as_root apk update &&
    (run_as_root apk add docker docker-cli-compose ||
      run_as_root apk add docker docker-compose)
}

install_docker_native() {
  detect_os || return 1

  case "$OS_ID $OS_ID_LIKE" in
    *debian*|*ubuntu*)
      install_docker_apt
      ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*amzn*)
      install_docker_rhel
      ;;
    *arch*|*manjaro*)
      install_docker_arch
      ;;
    *alpine*)
      install_docker_alpine
      ;;
    *)
      say_err "⚠️ No native Docker installer mapped for: $OS_NAME"
      return 1
      ;;
  esac
}

install_docker_fallback() {
  if ! command_exists curl; then
    say_err "❌ curl is required for Docker fallback installer."
    return 1
  fi

  say "⚠️ Native Docker installation failed; falling back to get.docker.com..."

  if command_exists mktemp; then
    TMP_SCRIPT=$(mktemp "${TMPDIR:-/tmp}/get-docker.XXXXXX") || return 1
  else
    TMP_SCRIPT="${TMPDIR:-/tmp}/get-docker.$$"
    (set -C; : > "$TMP_SCRIPT") || {
      say_err "❌ Could not create temporary file: $TMP_SCRIPT"
      return 1
    }
  fi

  if curl -fsSL https://get.docker.com -o "$TMP_SCRIPT"; then
    if run_as_root sh "$TMP_SCRIPT"; then
      STATUS=0
    else
      STATUS=$?
    fi
  else
    STATUS=$?
  fi

  rm -f "$TMP_SCRIPT"
  return "$STATUS"
}

start_docker_service() {
  if command_exists systemctl; then
    say "🐳 Enabling and starting Docker service with systemctl..."
    run_as_root systemctl enable docker &&
      run_as_root systemctl start docker
  elif command_exists service; then
    say "🐳 Starting Docker service with service..."
    run_as_root service docker start || true
  elif command_exists rc-service; then
    say "🐳 Starting Docker service with OpenRC..."
    run_as_root rc-update add docker default || true
    run_as_root rc-service docker start
  else
    say_err "⚠️ No known service manager found; assuming Docker can be started by the environment."
  fi
}

ensure_docker_compose() {
  if docker compose version >/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
    say "🐳 Docker Compose plugin is available"
    return 0
  fi

  if command_exists docker-compose; then
    DOCKER_COMPOSE="docker-compose"
    say "🐳 docker-compose binary is available"
    return 0
  fi

  say_err "❌ Docker Compose is not available. Install the Docker Compose plugin or docker-compose."
  return 1
}

install_docker_compose_native() {
  detect_os || return 1

  say "🐳 Attempting to install Docker Compose via native package manager..."

  case "$OS_ID $OS_ID_LIKE" in
    *debian*|*ubuntu*)
      command_exists apt-get || return 1
      run_as_root apt-get update &&
        (run_as_root apt-get install -y docker-compose-plugin ||
          run_as_root apt-get install -y docker-compose)
      ;;
    *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*amzn*)
      if command_exists dnf; then
        PM="dnf"
      elif command_exists yum; then
        PM="yum"
      else
        return 1
      fi
      run_as_root "$PM" install -y docker-compose-plugin ||
        run_as_root "$PM" install -y docker-compose
      ;;
    *arch*|*manjaro*)
      command_exists pacman || return 1
      run_as_root pacman -Sy --noconfirm docker-compose
      ;;
    *alpine*)
      command_exists apk || return 1
      run_as_root apk update &&
        (run_as_root apk add docker-cli-compose ||
          run_as_root apk add docker-compose)
      ;;
    *)
      say_err "⚠️ No native Docker Compose installer mapped for: $OS_NAME"
      return 1
      ;;
  esac
}

install_docker() {
  if command_exists docker; then
    say "🐳 Docker is already installed"
  else
    say "🐳 Docker not found, installing..."
    if install_docker_native; then
      say "🐳 Docker installed via native package manager"
    elif install_docker_fallback; then
      say "🐳 Docker installed via fallback installer"
    else
      say_err "❌ Docker installation failed. Install Docker for your distribution and re-run this script."
      exit 1
    fi
  fi

  start_docker_service || {
    say_err "❌ Docker is installed, but the service could not be started."
    exit 1
  }

  if ! docker version >/dev/null 2>&1; then
    say_err "❌ Docker command is available, but the daemon is not responding."
    exit 1
  fi

  if ! ensure_docker_compose; then
    if install_docker_compose_native || install_docker_fallback; then
      ensure_docker_compose || {
        say_err "❌ Docker Compose installation completed, but Compose is still unavailable."
        exit 1
      }
    else
      say_err "❌ Docker Compose installation failed."
      exit 1
    fi
  fi

  say "🐳 Docker is ready"
}

install_docker

# -------------------------
# Clone repository
# -------------------------

if [ ! -d "$PROJECT_DIR" ]; then
  git clone "$REPO_URL"
fi

cd "$PROJECT_DIR"

# -------------------------
# Detect SERVER IP
# -------------------------

say "🌍 Detecting server IP..."
SERVER_IP=$(curl -fs https://api.ipify.org)

if [ -z "$SERVER_IP" ]; then
  say_err "❌ Could not determine SERVER_IP"
  exit 1
fi

say "🌍 Server IP: $SERVER_IP"

# -------------------------
# Generate Caddyfile
# -------------------------

sed "s/{SERVER_IP_ADDRESS}/${SERVER_IP}/g" \
  Caddyfile.template > Caddyfile

say "✅ Caddyfile generated"

# -------------------------
# Telegram bot validation
# -------------------------

while :; do
  printf "Telegram BOT TOKEN: "
  IFS= read -r TOKEN

  BOT_INFO=$(validate_telegram_token "$TOKEN" || true)

  printf '%s\n' "$BOT_INFO" | grep -q '"is_bot":true' && break
  say "❌ Invalid Telegram bot token"
done

BOT_USERNAME=$(printf '%s\n' "$BOT_INFO" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p')

if [ -n "$BOT_USERNAME" ]; then
  say "🤖 Bot username: @$BOT_USERNAME"
else
  say "⚠️ Bot username not found"
fi

# -------------------------
# User input
# -------------------------

while :; do
  printf "ADMIN_ID_LIST (comma separated ints): "
  IFS= read -r ADMIN_ID_LIST
  validate_admin_ids "$ADMIN_ID_LIST" && break
  say "❌ Invalid ADMIN_ID_LIST"
done

while :; do
  printf "SUPPORT_LINK (https://...): "
  IFS= read -r SUPPORT_LINK
  validate_support_link "$SUPPORT_LINK" && break
  say "❌ SUPPORT_LINK must start with https://"
done

while :; do
  printf "Currency (%s): " "$SUPPORTED_CURRENCIES"
  IFS= read -r CURRENCY
  validate_currency "$CURRENCY" && break
  say "❌ Invalid currency"
done

say "🔑 KRYPTO_EXPRESS_API_KEY can be obtained here:"
say "👉 https://kryptoexpress.pro/profile"
printf "KRYPTO_EXPRESS_API_KEY: "
IFS= read -r KRYPTO_EXPRESS_API_KEY

printf "TELEGRAM_PROXY_URL (optional, e.g. socks5://host:port): "
IFS= read -r TELEGRAM_PROXY_URL

printf "Enable CRYPTO_FORWARDING_MODE? (true/false): "
IFS= read -r CRYPTO_MODE

if [ "$CRYPTO_MODE" = "true" ]; then
  BTC_ADDR=$(read_crypto_address BTC validate_btc)
  LTC_ADDR=$(read_crypto_address LTC validate_ltc)
  ETH_ADDR=$(read_crypto_address ETH validate_eth)
  SOL_ADDR=$(read_crypto_address SOL validate_sol)
  BNB_ADDR=$(read_crypto_address BNB validate_bnb)
  DOGE_ADDR=$(read_crypto_address DOGE validate_doge)
else
  BTC_ADDR=""
  LTC_ADDR=""
  ETH_ADDR=""
  SOL_ADDR=""
  BNB_ADDR=""
  DOGE_ADDR=""
fi

# -------------------------
# Generate secrets
# -------------------------

POSTGRES_PASSWORD=$(generate_secret)
WEBHOOK_SECRET_TOKEN=$(generate_secret)
KRYPTO_EXPRESS_API_SECRET=$(generate_secret)
REDIS_PASSWORD=$(generate_secret)
SQLADMIN_RAW_PASSWORD=$(generate_secret)
JWT_SECRET_KEY=$(generate_secret)

# -------------------------
# Write .env
# -------------------------

cat > .env <<EOF
WEBHOOK_PATH="/"
WEBAPP_HOST="0.0.0.0"
WEBAPP_PORT="5000"
TOKEN="$TOKEN"
ADMIN_ID_LIST=$ADMIN_ID_LIST
SUPPORT_LINK="$SUPPORT_LINK"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="$POSTGRES_PASSWORD"
DB_PORT="5432"
DB_HOST="postgres"
POSTGRES_DB="aiogram-shop-bot"
NGROK_TOKEN=""
PAGE_ENTRIES="8"
MULTIBOT="false"
CURRENCY="$CURRENCY"
RUNTIME_ENVIRONMENT="PROD"
WEBHOOK_SECRET_TOKEN="$WEBHOOK_SECRET_TOKEN"
KRYPTO_EXPRESS_API_KEY="$KRYPTO_EXPRESS_API_KEY"
KRYPTO_EXPRESS_API_URL="https://kryptoexpress.pro/api"
KRYPTO_EXPRESS_API_SECRET="$KRYPTO_EXPRESS_API_SECRET"
REDIS_PASSWORD="$REDIS_PASSWORD"
REDIS_HOST="redis"
TELEGRAM_PROXY_URL="$TELEGRAM_PROXY_URL"
CRYPTO_FORWARDING_MODE="$CRYPTO_MODE"
BTC_FORWARDING_ADDRESS="$BTC_ADDR"
LTC_FORWARDING_ADDRESS="$LTC_ADDR"
ETH_FORWARDING_ADDRESS="$ETH_ADDR"
SOL_FORWARDING_ADDRESS="$SOL_ADDR"
BNB_FORWARDING_ADDRESS="$BNB_ADDR"
DOGE_FORWARDING_ADDRESS="$DOGE_ADDR"
MIN_REFERRER_TOTAL_DEPOSIT="500"
REFERRAL_BONUS_PERCENT="5"
REFERRAL_BONUS_DEPOSIT_LIMIT="3"
REFERRER_BONUS_PERCENT="3"
REFERRER_BONUS_DEPOSIT_LIMIT="5"
REFERRAL_BONUS_CAP_PERCENT="7"
REFERRER_BONUS_CAP_PERCENT="7"
TOTAL_BONUS_CAP_PERCENT="12"
SQLADMIN_RAW_PASSWORD="$SQLADMIN_RAW_PASSWORD"
JWT_EXPIRE_MINUTES="30"
JWT_ALGORITHM="HS256"
JWT_SECRET_KEY="$JWT_SECRET_KEY"
EOF

say "✅ .env generated"

# -------------------------
# Start containers
# -------------------------

say "🐳 Starting Docker containers..."
$DOCKER_COMPOSE up -d

# -------------------------
# Output info
# -------------------------

printf '\n'
say "🔐 SQL Admin password:"
say "$SQLADMIN_RAW_PASSWORD"
printf '\n'
say "🌐 Admin panel is available at:"
say "https://${SERVER_IP}.sslip.io/admin"
printf '\n'
say "🎉 Deployment completed successfully"
