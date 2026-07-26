#!/usr/bin/env bash

set -euo pipefail
set -o errtrace

# Продвинутый трап ошибок с поддержкой BASH_LINENO
trap 'rc=$?; echo "❌ ERROR: Ошибка (код $rc) в строке ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2; exit $rc' ERR

# ==========================================
# CONFIGURATION
# ==========================================
NEW_USER="pavelgg"
APP_DIR="/opt/nanoclaw"
REPO_URL="https://github.com/nanocoai/nanoclaw.git"
SWAP_SIZE="2G"
TMPFS_TMP_SIZE="25%"

# ==========================================
# 1. OS, ROOT & NETWORK CHECKS
# ==========================================
if [ "$EUID" -ne 0 ]; then
    echo "❌ Ошибка: этот скрипт должен выполняться от имени root." >&2
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo "❌ Ошибка: Не удалось определить операционную систему." >&2
    exit 1
fi

source /etc/os-release
if [ "${ID:-}" != "ubuntu" ]; then
    echo "❌ Ошибка: Этот скрипт предназначен только для Ubuntu! Текущая ОС: ${NAME:-Неизвестно}" >&2
    exit 1
fi

echo "===> 1. Проверка сети и обновление системы..."
if ! curl -fsSL -I --connect-timeout 5 https://github.com > /dev/null 2>&1; then
    echo "❌ Ошибка: Отсутствует доступ к github.com или нет интернет-соединения." >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt update -qq && apt upgrade -y
apt install -y curl wget git ufw fail2ban sysstat htop unzip software-properties-common ca-certificates gnupg dbus-user-session

# ==========================================
# 2. USER CREATION & SSH KEYS SAFETY CHECK
# ==========================================
echo "===> 2. Настройка пользователя ${NEW_USER} и SSH-ключей..."

# Страховка при запуске через pipe (curl | bash): чтение строго с /dev/tty
if [ ! -s /root/.ssh/authorized_keys ]; then
    echo "⚠️ ВНИМАНИЕ: Файл /root/.ssh/authorized_keys пуст или отсутствует."
    echo -n "Пожалуйста, вставьте ваш публичный SSH-ключ (ssh-rsa / ssh-ed25519 ...) и нажмите Enter: "
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    read -r PUB_KEY_INPUT </dev/tty
    echo "$PUB_KEY_INPUT" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# Идемпотентное создание пользователя и установка пароля
if ! id -u "$NEW_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$NEW_USER"
    usermod -aG sudo "$NEW_USER"
    echo "Пользователь ${NEW_USER} успешно создан."
    
    echo "🔑 Задайте пароль для пользователя ${NEW_USER} (будет запрашиваться при выполнении sudo):"
    passwd "$NEW_USER" </dev/tty
else
    echo "Пользователь ${NEW_USER} уже существует. Пропускаем смену пароля."
fi

# Безопасное включение lingering для выполнения systemd-user сервисов
if command -v loginctl >/dev/null 2>&1; then
    loginctl enable-linger "$NEW_USER" || true
fi

# Копирование SSH-ключей пользователю через install
install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "/home/${NEW_USER}/.ssh"
cp /root/.ssh/authorized_keys "/home/${NEW_USER}/.ssh/authorized_keys"
chown "${NEW_USER}:${NEW_USER}" "/home/${NEW_USER}/.ssh/authorized_keys"
chmod 600 "/home/${NEW_USER}/.ssh/authorized_keys"

# Финальная проверка перед отключением входа по паролю
if [ ! -s "/home/${NEW_USER}/.ssh/authorized_keys" ]; then
    echo "❌ КРИТИЧЕСКАЯ ОШИБКА: Не удалось записать SSH-ключ для ${NEW_USER}!" >&2
    echo "   Скрипт остановлен для предотвращения потери доступа к серверу." >&2
    exit 1
fi

# ==========================================
# 3. SWAP & SYSCTL OPTIMIZATION
# ==========================================
echo "===> 3. Настройка SWAP (${SWAP_SIZE}) и оптимизация ядра..."
if [ ! -f /swapfile ]; then
    SWAP_MB=$(numfmt --from=iec "$SWAP_SIZE" | awk '{print int($1/1024/1024)}')
    fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MB" status=progress
    chmod 600 /swapfile
    mkswap /swapfile
fi

if [ -f /swapfile ] && ! swapon --show | grep -q "/swapfile"; then
    swapon /swapfile
fi

if ! grep -q "^/swapfile" /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Оптимизация системных лимитов
cat <<EOF > /etc/sysctl.d/99-vps-optimization.conf
vm.swappiness=10
vm.vfs_cache_pressure=50
fs.file-max=2097152
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=512
EOF

sysctl --system &>/dev/null

# ==========================================
# 4. TMPFS (RAM-DISK FOR /tmp)
# ==========================================
echo "===> 4. Настройка RAM-диска для /tmp..."

if ! grep -q "tmpfs /tmp " /etc/fstab; then
    echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=${TMPFS_TMP_SIZE} 0 0" >> /etc/fstab
fi

mountpoint -q /tmp || mount /tmp
chmod 1777 /tmp

# ==========================================
# 5. NODE.JS 20 & PNPM (COREPACK PINNED)
# ==========================================
echo "===> 5. Установка и проверка Node.js 20 и pnpm..."

PNPM_VERSION="10"
NODE_MAJOR="$(node -v 2>/dev/null | cut -d. -f1 | tr -d 'v' || echo 0)"

if [ "$NODE_MAJOR" -ne 20 ]; then
    echo "📥 Скачивание и установка Node.js 20.x..."
    curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh
    bash /tmp/nodesource_setup.sh
    rm -f /tmp/nodesource_setup.sh

    apt install -y nodejs
else
    echo "ℹ️ Node.js 20 уже установлен ($(node -v)). Пропускаем скачивание."
fi

# Проверка наличия Corepack перед активацией
if ! command -v corepack >/dev/null 2>&1; then
    echo "❌ Ошибка: Corepack отсутствует в текущей сборке Node.js." >&2
    exit 1
fi

# Активируем Corepack с фиксированной мажорной версией pnpm
corepack enable
corepack prepare "pnpm@${PNPM_VERSION}" --activate

# Проверка физической работоспособности бинарников
if ! node -v >/dev/null 2>&1 || ! pnpm -v >/dev/null 2>&1; then
    echo "❌ Ошибка: Бинарники Node.js или pnpm повреждены или не запускаются!" >&2
    exit 1
fi

echo "✔ Node.js $(node -v) и pnpm v$(pnpm -v) успешно протестированы и готовы к работе."


# ==========================================
# 6. DOCKER ENGINE INSTALLATION
# ==========================================
echo "===> 5. Установка и проверка Docker..."
if ! command -v docker &> /dev/null; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt update -qq
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Идемпотентное добавление пользователя в группу docker
id -nG "$NEW_USER" | grep -qw docker || usermod -aG docker "$NEW_USER"

systemctl enable --now docker

# Комплексная проверка готовности Docker API
echo "Проверка работы Docker Daemon..."
timeout 15 docker info >/dev/null 2>&1 && timeout 15 docker version >/dev/null 2>&1 || {
    echo "❌ Ошибка: Служба Docker запущена, но Daemon/API не отвечает!" >&2
    exit 1
}

echo "✔ Docker Engine: $(docker version --format '{{.Client.Version}}')"
echo "✔ Docker Compose: $(docker compose version --short)"

# ==========================================
# 7. HARDENING: SSH, FIREWALL, FAIL2BAN
# ==========================================
echo "===> 6. Настройка безопасности (SSH, UFW, Fail2ban)..."

# Бескомпромиссный drop-in файл настроек SSH
SSHD_CUSTOM_CONFIG="/etc/ssh/sshd_config.d/99-bootstrap.conf"
mkdir -p /etc/ssh/sshd_config.d

cat <<EOF > "$SSHD_CUSTOM_CONFIG"
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF

if /usr/sbin/sshd -t; then
    systemctl reload ssh || systemctl restart ssh
else
    echo "❌ Ошибка в синтаксисе SSH! Изменения не применены." >&2
    exit 1
fi

# Fail2ban с интегрированным banaction = ufw и динамическим увеличением бана
cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
backend = systemd
banaction = ufw
bantime.increment = true

[sshd]
enabled = true
maxretry = 3
findtime = 10m
bantime = 24h
EOF

systemctl restart fail2ban
systemctl enable fail2ban

# ... (Настройка SSH и Fail2ban) ...

echo ""
echo "⚠️ Выберите режим настройки сетевого экрана UFW:"
echo "  1) Сбросить все старые правила и настроить с нуля (ufw reset)"
echo "  2) Настроить поверх текущих правил (по умолчанию)"
echo "  3) Пропустить настройку UFW"
echo -n "Введите номер [1/2/3] (Enter = 2): "
read -r UFW_CHOICE </dev/tty

case "${UFW_CHOICE:-2}" in
    1)
        echo "🔄 Сброс всех правил UFW..."
        ufw --force reset>/dev/null 2>&1
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow OpenSSH
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw logging on
        ufw --force enable
        echo "✔ UFW полностью сброшен и настроен с нуля."
        ;;
    2)
        echo "ℹ️ Добавляем правила UFW поверх текущей конфигурации..."
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow OpenSSH
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw logging on
        ufw --force enable
        echo "✔ Правила UFW успешно обновлены."
        ;;
    3)
        echo "⏭️ Настройка UFW пропущена по выбору пользователя."
        ;;
    *)
        echo "⚠️ Неверный ввод, применяем вариант по умолчанию (2 — поверх текущих)..."
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow OpenSSH
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw logging on
        ufw --force enable
        echo "✔ Правила UFW успешно обновлены."
        ;;
esac

# ==========================================
# 7. NANOCLAW INSTALLATION
# ==========================================
echo "===> 7. Настройка и запуск NanoClaw в ${APP_DIR}..."

if [ -d "${APP_DIR}/.git" ]; then
    echo "ℹ️ Репозиторий NanoClaw уже существует в ${APP_DIR}. Пропускаем клонирование."
elif [ -d "${APP_DIR}" ]; then
    echo "❌ Ошибка: Каталог ${APP_DIR} существует, но не является Git-репозиторием." >&2
    echo "   Удалите или переименуйте папку вручную перед повторным запуском." >&2
    exit 1
else
    echo "📥 Клонирование NanoClaw в ${APP_DIR}..."
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
    chown -R "${NEW_USER}:${NEW_USER}" "${APP_DIR}"
    sudo -u "${NEW_USER}" git config --global --add safe.directory "${APP_DIR}"
fi

cd "${APP_DIR}"

# Идемпотентная гарантированная установка прав на исполнение
if [ -f "nanoclaw.sh" ]; then
    chmod +x "nanoclaw.sh"
else
    echo "❌ Ошибка: Файл nanoclaw.sh не найден в ${APP_DIR}!" >&2
    exit 1
fi

# Вычисляем идентификаторы и подготавливаем переменные окружения
USER_UID=$(id -u "${NEW_USER}")
XDG_RUNTIME_DIR="/run/user/${USER_UID}"
DBUS_SOCKET="${XDG_RUNTIME_DIR}/bus"

# Инициализируем/прогреваем systemd user-manager без блокирующей фатальной проверки
echo "🔄 Инициализация пользовательской systemd-сессии..."
sudo -iu "${NEW_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" systemctl --user daemon-reexec >/dev/null 2>&1 || true

# Запуск интерактивного скрипта установки NanoClaw
echo "🚀 Запуск интерактивного скрипта установки NanoClaw..."
if ! sudo -iu "${NEW_USER}" bash -lc "
    export XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR}'
    export DBUS_SESSION_BUS_ADDRESS='unix:path=${DBUS_SOCKET}'
    cd '${APP_DIR}'
    exec ./nanoclaw.sh
" </dev/tty; then
    echo "❌ Ошибка: Установка NanoClaw завершилась с ошибкой или была отменена." >&2
    exit 1
fi

# ==========================================
# 9. CADDY REVERSE PROXY SETUP
# ==========================================
echo "===> 8. Настройка и запуск Caddy Reverse Proxy..."

# Атомарное создание каталога сразу с правильными правами
install -d -m 755 -o "${NEW_USER}" -g "${NEW_USER}" "${CADDY_DIR}"

# 1. Генерируем docker-compose.yml через /dev/stdin (только если не существует)
if [ ! -f "${CADDY_DIR}/docker-compose.yml" ]; then
    echo "📝 Создание ${CADDY_DIR}/docker-compose.yml..."
    install -m 644 -o "${NEW_USER}" -g "${NEW_USER}" /dev/stdin "${CADDY_DIR}/docker-compose.yml" << 'EOF'
networks:
  app-network:
    driver: bridge

services:
  proxy:
    image: caddy:2-alpine
    init: true
    restart: unless-stopped

    ports:
      - "80:80"
      - "443:443"

    # RAM-диск для временных файлов Caddy
    tmpfs:
      - /tmp:exec,mode=1777,size=128M

    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config

    networks:
      - app-network

    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  caddy_data:
  caddy_config:
EOF
else
    echo "ℹ️ ${CADDY_DIR}/docker-compose.yml уже существует, пропускаем..."
fi

# 2. Генерируем базовый Caddyfile через /dev/stdin (только если не существует)
if [ ! -f "${CADDY_DIR}/Caddyfile" ]; then
    echo "📝 Создание ${CADDY_DIR}/Caddyfile..."
    install -m 644 -o "${NEW_USER}" -g "${NEW_USER}" /dev/stdin "${CADDY_DIR}/Caddyfile" << 'EOF'
# Базовый Caddyfile
#
# example.com {
#     reverse_proxy localhost:3000
# }

:80 {
    respond "Caddy is running!" 200
}
EOF
else
    echo "ℹ️ ${CADDY_DIR}/Caddyfile уже существует, пропускаем..."
fi

# 3. Пулинг свежего образа, запуск Caddy и проверка статуса
echo "🚀 Запуск Caddy через Docker Compose..."
sudo -iu "${NEW_USER}" bash -lc "
    cd '${CADDY_DIR}'
    docker compose pull
    docker compose up -d
    echo '📊 Статус сервисов Caddy:'
    docker compose ps
"

echo "✔ Caddy успешно настроен и запущен!"

# ==========================================
# 10. POST-INSTALLATION HEALTH CHECK & CLEANUP
# ==========================================
echo "===> 8. Проверка статуса сервисов и очистка..."

apt autoremove -y && apt autoclean

echo "Ожидание инициализации сервисов (5 сек)..."
sleep 5

# Динамическая проверка активных systemd-user сервисов пользователя
USER_UID=$(id -u "$NEW_USER")
echo "Проверка состояния systemd-сервисов пользователя ${NEW_USER}..."

RUNNING_SERVICES=$(sudo -u "$NEW_USER" XDG_RUNTIME_DIR="/run/user/$USER_UID" systemctl --user list-units --type=service --state=running 2>/dev/null | grep -i 'nano' || true)

if [ -n "$RUNNING_SERVICES" ]; then
    echo "✔ Запущенные пользовательские сервисы:"
    echo "$RUNNING_SERVICES"
else
    echo "⚠️ Активные пользовательские сервисы NanoClaw не обнаружены в systemd."
fi

# Вывод состояния Docker-контейнеров
echo ""
echo "Статус запущенных Docker-контейнеров окружения:"
if docker ps --format '{{.ID}}' | grep -q .; then
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
else
    echo "⚠️ ВНИМАНИЕ: Запущенные Docker-контейнеры не обнаружены."
    echo "👉 Для диагностики выполните:"
    echo "   cd ${APP_DIR} && docker compose ps"
    echo "   cd ${APP_DIR} && docker compose logs --tail=100"
fi

echo ""
echo "========================================================="
echo "🎉 BOOTSTRAP И УСТАНОВКА NANOCLAW УСПЕШНО ЗАВЕРШЕНЫ!"
echo "----------------------------------------------------------------- "
echo "• Пользователь: ${NEW_USER} (доступ только по SSH-ключу)"
echo "• Директория приложения: ${APP_DIR}"
echo "• SWAP (${SWAP_SIZE}) и tmpfs (/tmp) смонтированы"
echo "• Безопасность: SSH (hardened), UFW (reset + clean rules), Fail2ban"
echo "----------------------------------------------------------------- "
echo "⚠️ ВАЖНО: Не закрывая текущую сессию, проверьте вход в новом терминале:"
echo "   ssh ${NEW_USER}@<IP_СЕРВЕРА>"
echo "========================================================="