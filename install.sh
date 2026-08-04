#!/bin/sh
set -eu

APP_NAME="lan-screen-stream"
REPOSITORY="${LAN_SCREEN_STREAM_REPOSITORY:-3d-mast/lan-screen-stream}"
BRANCH="${LAN_SCREEN_STREAM_BRANCH:-main}"
NODE_CHANNEL="${LAN_SCREEN_STREAM_NODE_CHANNEL:-latest-v22.x}"
INSTALL_DIR="${LAN_SCREEN_STREAM_HOME:-$HOME/.local/share/$APP_NAME}"
BIN_DIR="${LAN_SCREEN_STREAM_BIN_DIR:-$HOME/.local/bin}"

say() {
  printf '%s\n' "$*" >&2
}

fail() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "не найдена команда '$1'"
}

node_major() {
  "$1" -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0'
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "для проверки архива нужен sha256sum или shasum"
  fi
}

install_node_with_apk() {
  say "Обнаружена musl-система. Устанавливаю Node.js через apk..."

  if [ "$(id -u)" -eq 0 ]; then
    apk add --no-cache nodejs >&2
  elif command -v doas >/dev/null 2>&1; then
    doas apk add --no-cache nodejs >&2
  elif command -v sudo >/dev/null 2>&1; then
    sudo apk add --no-cache nodejs >&2
  else
    fail "нужны root-права, sudo или doas для установки Node.js через apk"
  fi

  command -v node >/dev/null 2>&1 || fail "apk завершился, но node не найден"
  [ "$(node_major "$(command -v node)")" -ge 20 ] || fail "установлен Node.js ниже версии 20"
  command -v node
}

install_portable_node() {
  os_name="$1"
  cpu_name="$2"
  runtime_dir="$INSTALL_DIR/.runtime"
  sums_url="https://nodejs.org/dist/$NODE_CHANNEL/SHASUMS256.txt"
  sums_file="$TMP_DIR/SHASUMS256.txt"

  case "$cpu_name" in
    x86_64|amd64) node_arch="x64" ;;
    arm64|aarch64) node_arch="arm64" ;;
    armv7l|armv7) node_arch="armv7l" ;;
    *) fail "архитектура '$cpu_name' пока не поддерживается" ;;
  esac

  case "$os_name" in
    Linux) node_platform="linux" ;;
    Darwin) node_platform="darwin" ;;
    *) fail "ОС '$os_name' пока не поддерживается этим установщиком" ;;
  esac

  say "Скачиваю переносимый Node.js 22 для $node_platform-$node_arch..."
  curl -fsSL "$sums_url" -o "$sums_file"

  archive_name="$(awk -v suffix="-$node_platform-$node_arch.tar.gz" '$2 ~ suffix "$" { print $2; exit }' "$sums_file")"
  [ -n "$archive_name" ] || fail "не удалось найти архив Node.js для $node_platform-$node_arch"

  expected_hash="$(awk -v file="$archive_name" '$2 == file { print $1; exit }' "$sums_file")"
  archive_path="$TMP_DIR/$archive_name"
  curl -fL --retry 3 "https://nodejs.org/dist/$NODE_CHANNEL/$archive_name" -o "$archive_path"

  actual_hash="$(sha256_file "$archive_path")"
  [ "$actual_hash" = "$expected_hash" ] || fail "контрольная сумма Node.js не совпала"

  rm -rf "$TMP_DIR/node-extract"
  mkdir -p "$TMP_DIR/node-extract"
  tar -xzf "$archive_path" -C "$TMP_DIR/node-extract"

  extracted_dir="$(find "$TMP_DIR/node-extract" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [ -n "$extracted_dir" ] || fail "архив Node.js пуст"

  rm -rf "$runtime_dir"
  mkdir -p "$INSTALL_DIR"
  mv "$extracted_dir" "$runtime_dir"
  printf '%s\n' "$runtime_dir/bin/node"
}

need curl
need tar
need awk
need find

OS_NAME="$(uname -s)"
CPU_NAME="$(uname -m)"
case "$OS_NAME" in
  Linux|Darwin) ;;
  *) fail "поддерживаются Linux и macOS; для Windows используй install.ps1" ;;
esac

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t lan-screen-stream)"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

say "Установка $APP_NAME из $REPOSITORY@$BRANCH"

SYSTEM_NODE=""
if command -v node >/dev/null 2>&1; then
  CANDIDATE_NODE="$(command -v node)"
  if [ "$(node_major "$CANDIDATE_NODE")" -ge 20 ]; then
    SYSTEM_NODE="$CANDIDATE_NODE"
    say "Использую установленный $($SYSTEM_NODE --version)."
  fi
fi

if [ -n "$SYSTEM_NODE" ]; then
  NODE_BIN="$SYSTEM_NODE"
elif [ "$OS_NAME" = "Linux" ] && command -v ldd >/dev/null 2>&1 && ldd --version 2>&1 | grep -qi musl; then
  NODE_BIN="$(install_node_with_apk)"
else
  NODE_BIN="$(install_portable_node "$OS_NAME" "$CPU_NAME")"
fi

SOURCE_ARCHIVE="$TMP_DIR/source.tar.gz"
SOURCE_DIR="$TMP_DIR/source"
mkdir -p "$SOURCE_DIR"

say "Скачиваю исходники проекта..."
curl -fL --retry 3 \
  "https://github.com/$REPOSITORY/archive/refs/heads/$BRANCH.tar.gz" \
  -o "$SOURCE_ARCHIVE"
tar -xzf "$SOURCE_ARCHIVE" --strip-components=1 -C "$SOURCE_DIR"

[ -f "$SOURCE_DIR/src/server.js" ] || fail "в архиве нет src/server.js"
[ -f "$SOURCE_DIR/public/app.js" ] || fail "в архиве нет public/app.js"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"
rm -rf "$INSTALL_DIR/src" "$INSTALL_DIR/public"
rm -f "$INSTALL_DIR/package.json" "$INSTALL_DIR/README.md" "$INSTALL_DIR/LICENSE" "$INSTALL_DIR/.gitignore"
cp -R "$SOURCE_DIR/src" "$SOURCE_DIR/public" "$INSTALL_DIR/"
cp "$SOURCE_DIR/package.json" "$SOURCE_DIR/README.md" "$SOURCE_DIR/LICENSE" "$SOURCE_DIR/.gitignore" "$INSTALL_DIR/"

LAUNCHER="$BIN_DIR/$APP_NAME"
cat > "$LAUNCHER" <<EOF_LAUNCHER
#!/bin/sh
exec "$NODE_BIN" "$INSTALL_DIR/src/server.js" "\$@"
EOF_LAUNCHER
chmod 755 "$LAUNCHER"

"$NODE_BIN" --check "$INSTALL_DIR/src/server.js" >/dev/null
"$NODE_BIN" --check "$INSTALL_DIR/public/app.js" >/dev/null

say ""
say "Готово."
say "Каталог: $INSTALL_DIR"
say "Команда: $LAUNCHER"
say "Запуск:  $APP_NAME"
say ""

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    say "Каталог $BIN_DIR пока не находится в PATH."
    say "Запусти сейчас: $LAUNCHER"
    say "Или добавь в профиль оболочки: export PATH=\"$BIN_DIR:\$PATH\""
    ;;
esac
