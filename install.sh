#!/usr/bin/env bash
set -e

APP_NAME="LabDroid Gateway"
INSTALL_DIR="$HOME/.labdroid"
BIN_NAME="lab"
RAW_BASE="${1:-}"

if [ -z "$RAW_BASE" ]; then
  RAW_BASE="https://raw.githubusercontent.com/USERNAME/labdroid-gateway/main"
fi

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

log() {
  echo -e "${CYAN}[LabDroid]${RESET} $1"
}

ok() {
  echo -e "${GREEN}[OK]${RESET} $1"
}

warn() {
  echo -e "${YELLOW}[WARN]${RESET} $1"
}

fail() {
  echo -e "${RED}[FAIL]${RESET} $1"
}

detect_env() {
  OS="$(uname -s 2>/dev/null || echo unknown)"

  if [ -n "$TERMUX_VERSION" ] || echo "$PREFIX" | grep -qi "com.termux"; then
    ENV_TYPE="termux"
  elif [ -f /etc/alpine-release ]; then
    ENV_TYPE="alpine"
  elif command -v apt >/dev/null 2>&1; then
    ENV_TYPE="debian"
  elif command -v yum >/dev/null 2>&1; then
    ENV_TYPE="rhel"
  elif command -v pacman >/dev/null 2>&1; then
    ENV_TYPE="arch"
  elif command -v apk >/dev/null 2>&1; then
    ENV_TYPE="alpine"
  else
    ENV_TYPE="unknown"
  fi
}

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_termux() {
  log "Phát hiện Termux. Đang kiểm tra addon..."

  pkg update -y

  PACKAGES="bash curl wget android-tools coreutils grep gawk sed iproute2"

  for p in $PACKAGES; do
    if pkg list-installed 2>/dev/null | grep -q "^$p/"; then
      ok "$p đã cài, bỏ qua"
    else
      log "Đang cài $p..."
      pkg install -y "$p" || warn "Không cài được $p"
    fi
  done
}

install_alpine() {
  log "Phát hiện iSH/Alpine. Đang kiểm tra addon..."

  apk update || true

  PACKAGES="bash curl wget android-tools coreutils grep gawk sed iproute2"

  for p in $PACKAGES; do
    if apk info -e "$p" >/dev/null 2>&1; then
      ok "$p đã cài, bỏ qua"
    else
      log "Đang cài $p..."
      apk add "$p" || warn "Không cài được $p"
    fi
  done
}

install_debian() {
  log "Phát hiện Debian/Ubuntu/Linux. Đang kiểm tra addon..."

  sudo apt update -y || apt update -y || true

  PACKAGES="bash curl wget android-tools-adb coreutils grep gawk sed iproute2"

  for p in $PACKAGES; do
    if dpkg -s "$p" >/dev/null 2>&1; then
      ok "$p đã cài, bỏ qua"
    else
      log "Đang cài $p..."
      sudo apt install -y "$p" || apt install -y "$p" || warn "Không cài được $p"
    fi
  done
}

install_arch() {
  log "Phát hiện Arch Linux. Đang kiểm tra addon..."

  PACKAGES="bash curl wget android-tools coreutils grep gawk sed iproute2"

  for p in $PACKAGES; do
    if pacman -Q "$p" >/dev/null 2>&1; then
      ok "$p đã cài, bỏ qua"
    else
      log "Đang cài $p..."
      sudo pacman -S --noconfirm "$p" || warn "Không cài được $p"
    fi
  done
}

install_rhel() {
  log "Phát hiện RHEL/CentOS/Fedora. Đang kiểm tra addon..."

  PACKAGES="bash curl wget android-tools coreutils grep gawk sed iproute"

  for p in $PACKAGES; do
    if rpm -q "$p" >/dev/null 2>&1; then
      ok "$p đã cài, bỏ qua"
    else
      log "Đang cài $p..."
      sudo yum install -y "$p" || warn "Không cài được $p"
    fi
  done
}

install_deps() {
  detect_env

  case "$ENV_TYPE" in
    termux) install_termux ;;
    alpine) install_alpine ;;
    debian) install_debian ;;
    arch) install_arch ;;
    rhel) install_rhel ;;
    *)
      warn "Không nhận diện được môi trường."
      warn "Nếu là ADBify không có pkg/apk thì hãy đảm bảo đã có bash, curl, adb."
      ;;
  esac
}

download_file() {
  local url="$1"
  local out="$2"

  if has_cmd curl; then
    curl -L "$url" -o "$out"
  elif has_cmd wget; then
    wget -O "$out" "$url"
  else
    fail "Thiếu curl/wget nên không tải được file."
    exit 1
  fi
}

install_labdroid() {
  mkdir -p "$INSTALL_DIR"

  log "Tải lab_gateway.sh từ GitHub..."
  download_file "$RAW_BASE/lab_gateway.sh" "$INSTALL_DIR/lab_gateway.sh"

  chmod +x "$INSTALL_DIR/lab_gateway.sh"

  if [ -n "$PREFIX" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
    ln -sf "$INSTALL_DIR/lab_gateway.sh" "$PREFIX/bin/$BIN_NAME"
    ok "Đã tạo lệnh: $BIN_NAME"
  else
    mkdir -p "$HOME/.local/bin"
    ln -sf "$INSTALL_DIR/lab_gateway.sh" "$HOME/.local/bin/$BIN_NAME"

    if ! echo "$PATH" | grep -q "$HOME/.local/bin"; then
      echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
    fi

    ok "Đã tạo lệnh: $BIN_NAME"
  fi
}

main() {
  echo
  echo "======================================="
  echo "        $APP_NAME Installer"
  echo "======================================="
  echo

  install_deps
  install_labdroid

  echo
  ok "Cài xong."
  echo
  echo "Chạy bằng lệnh:"
  echo
  echo "  lab"
  echo
  echo "Hoặc:"
  echo
  echo "  bash ~/.labdroid/lab_gateway.sh"
  echo
}

main
