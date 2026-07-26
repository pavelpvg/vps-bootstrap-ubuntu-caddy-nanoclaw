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
CADDY_DIR="${APP_DIR}/caddy"

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
echo "===> 2. Настройка пользователя и SSH-ключей..."

# 1. Интерактивный запрос имени пользователя (с приглашением на новой строке)
DEFAULT_USER="user"
echo "👤 Введите имя нового пользователя [по умолчанию: ${DEFAULT_USER}]:"
read -r INPUT_USER </dev/tty
NEW_USER="${INPUT_USER:-$DEFAULT_USER}"

# Валидация синтаксиса имени пользователя (стандарт POSIX/Linux)
if ! [[ "${NEW_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "❌ Ошибка: Имя пользователя '${NEW_USER}' содержит недопустимые символы!" >&2
    echo "   Имя должно начинаться со строчной буквы или '_' и содержать только [a-z0-9_-]." >&2
    exit 1
fi

# Динамическая проверка порога системных UID из /etc/login.defs (по умолчанию 1000)
SYS_UID_MIN=$(awk '/^UID_MIN/ {print $2}' /etc/login.defs 2>/dev/null || echo "1000")

if getent passwd "${NEW_USER}" >/dev/null 2>&1; then
    EXISTING_UID=$(id -u "${NEW_USER}")
    if [ "${EXISTING_UID}" -lt "${SYS_UID_MIN}" ]; then
        echo "❌ Ошибка: Пользователь '${NEW_USER}' является системным аккаунтом (UID=${EXISTING_UID} < ${SYS_UID_MIN})!" >&2
        exit 1
    fi
    echo "ℹ️ Пользователь ${NEW_USER} уже существует (UID=${EXISTING_UID}). Обновляем настройки..."
fi

echo "✔ Использовано имя пользователя: ${NEW_USER}"

# 2. Страховка SSH-ключа для root (при запуске через curl | bash)
if [ ! -s /root/.ssh/authorized_keys ]; then
    echo "⚠️ ВНИМАНИЕ: Файл /root/.ssh/authorized_keys пуст или отсутствует."
    install -d -m 700 /root/.ssh
    read -r -p "Пожалуйста, вставьте ваш публичный SSH-ключ (ssh-rsa / ssh-ed25519 ...): " PUB_KEY_INPUT </dev/tty
    
    # Проверка на пустой ввод
    if [ -z "${PUB_KEY_INPUT}" ]; then
        echo "❌ Ошибка: Публичный SSH-ключ не может быть пустым!" >&2
        exit 1
    fi

    # Валидация формата публичного SSH-ключа: проверяем префикс и минимум 2 поля (тип + ключ)
    KEY_FIELDS_COUNT=$(printf '%s\n' "${PUB_KEY_INPUT}" | awk '{print NF}')
    if [ "${KEY_FIELDS_COUNT}" -lt 2 ]; then
        echo "❌ Ошибка: Некорректный формат SSH-ключа (слишком мало элементов)!" >&2
        exit 1
    fi

    case "${PUB_KEY_INPUT}" in
        ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *|sk-ecdsa-sha2-*\ *)
            ;;
        *)
            echo "❌ Ошибка: Неподдерживаемый тип публичного SSH-ключа!" >&2
            echo "   Ключ должен начинаться с 'ssh-ed25519', 'ssh-rsa' или 'ecdsa-sha2-*'." >&2
            exit 1
            ;;
    esac

    echo "$PUB_KEY_INPUT" > /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys
fi

# 3. Создание пользователя или пропуск создания
if ! id -u "${NEW_USER}" >/dev/null 2>&1; then
    echo "👤 Создание учетной записи ${NEW_USER}..."
    adduser --disabled-password --gecos "" "${NEW_USER}"
    
    echo "🔑 Задайте пароль для пользователя ${NEW_USER}:"
    passwd "${NEW_USER}" </dev/tty
fi

# Добавляем в группу sudo и проверяем членство
usermod -aG sudo "${NEW_USER}"
if ! id -nG "${NEW_USER}" | grep -qw sudo; then
    echo "❌ Ошибка: Не удалось добавить пользователя ${NEW_USER} в группу sudo!" >&2
    exit 1
fi

# 4. Безопасное копирование SSH-ключей и двухфакторная проверка прав чтения
if [ -s /root/.ssh/authorized_keys ]; then
    USER_SSH_DIR="/home/${NEW_USER}/.ssh"
    USER_AUTH_KEYS="${USER_SSH_DIR}/authorized_keys"

    install -d -m 700 -o "${NEW_USER}" -g "${NEW_USER}" "${USER_SSH_DIR}"
    install -m 600 -o "${NEW_USER}" -g "${NEW_USER}" /root/.ssh/authorized_keys "${USER_AUTH_KEYS}"
    
    # ПРОВЕРКА 1: Файл физически скопирован и не пуст
    if [ ! -s "${USER_AUTH_KEYS}" ]; then
        echo "❌ Ошибка: SSH-ключ не был скопирован в ${USER_AUTH_KEYS}!" >&2
        exit 1
    fi

    # ПРОВЕРКА 2: Новый пользователь гарантированно может прочитать свой SSH-ключ
    if ! sudo -u "${NEW_USER}" test -r "${USER_AUTH_KEYS}"; then
        echo "❌ Ошибка: Пользователь ${NEW_USER} не имеет прав на чтение ${USER_AUTH_KEYS}!" >&2
        exit 1
    fi
fi

# 5. Включение linger для systemd-сервисов
if command -v loginctl >/dev/null 2>&1; then
    if ! loginctl enable-linger "${NEW_USER}"; then
        echo "⚠️ Предупреждение: Не удалось включить systemd linger для ${NEW_USER}." >&2
    fi
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
echo "===> 6. Установка и проверка Docker..."
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
echo "===> 7. Настройка безопасности (SSH, UFW, Fail2ban)..."

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
# 8. NANOCLAW INSTALLATION
# ==========================================
echo "===> 8. Настройка и запуск NanoClaw в ${APP_DIR}..."

if [ -d "${APP_DIR}/.git" ]; then
    echo "ℹ️ Репозиторий NanoClaw уже существует в ${APP_DIR}. Пропускаем клонирование."
elif [ -d "${APP_DIR}" ]; then
    echo "❌ Ошибка: Каталог ${APP_DIR} существует, но не является Git-репозиторием." >&2
    echo "   Удалите или переименуйте папку вручную перед повторным запуском." >&2
    exit 1
else
    echo "📥 Клонирование NanoClaw в ${APP_DIR}..."
    git clone "${REPO_URL}" "${APP_DIR}"
    chown -R "${NEW_USER}:${NEW_USER}" "${APP_DIR}"
fi

# Строгая проверка владельца директории приложения
if [ "$(stat -c '%U' "${APP_DIR}")" != "${NEW_USER}" ]; then
    echo "❌ Ошибка: каталог ${APP_DIR} принадлежит не пользователю ${NEW_USER}." >&2
    exit 1
fi

# Идемпотентное добавление safe.directory с безопасным подавлением stderr для неинициализированного конфига
if ! sudo -u "${NEW_USER}" git config --global --get-all safe.directory 2>/dev/null | grep -Fxq "${APP_DIR}"; then
    sudo -u "${NEW_USER}" git config --global --add safe.directory "${APP_DIR}"
fi

# Проверка существования и установка прав на исполнение по абсолютному пути
if [ ! -f "${APP_DIR}/nanoclaw.sh" ]; then
    echo "❌ Ошибка: Файл ${APP_DIR}/nanoclaw.sh не найден!" >&2
    exit 1
fi
chmod +x "${APP_DIR}/nanoclaw.sh"

# Гарантируем наличие пакета acl для корректной выдачи прав на docker.sock через setfacl
if ! dpkg -l | grep -qw acl; then
    echo "📦 Установка пакета acl для управления правами Docker-сокета..."
    apt update && apt install -y acl
fi

# Вычисляем идентификаторы и подготавливаем переменные окружения
USER_UID=$(id -u "${NEW_USER}")
XDG_RUNTIME_DIR="/run/user/${USER_UID}"
DBUS_SOCKET="${XDG_RUNTIME_DIR}/bus"

# Инициализируем/прогреваем systemd user-manager с информативным предупреждением при сбое
echo "🔄 Инициализация пользовательской systemd-сессии..."
if ! sudo -iu "${NEW_USER}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" systemctl --user daemon-reexec >/dev/null 2>&1; then
    echo "⚠️ Предупреждение: Не удалось выполнить daemon-reexec для user systemd."
fi

# Диагностика D-Bus после попытки инициализации (предупреждение, не фатал)
if [ ! -S "${DBUS_SOCKET}" ]; then
    echo "⚠️ Предупреждение: Пользовательский D-Bus сокет еще не создан (${DBUS_SOCKET})."
fi

# Запуск интерактивного скрипта с гарантией правильного рабочего каталога и чистой передачей ENV (без хрупких export внутри)
echo "🚀 Запуск интерактивного скрипта установки NanoClaw..."
if ! sudo -iu "${NEW_USER}" \
    XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=${DBUS_SOCKET}" \
    bash -lc "cd '${APP_DIR}' && exec ./nanoclaw.sh" </dev/tty; then
    echo "❌ Ошибка: Установка NanoClaw завершилась с ошибкой или была отменена." >&2
    exit 1
fi

# ==========================================
# 9. CADDY REVERSE PROXY SETUP
# ==========================================
echo "===> 9. Настройка и запуск Caddy Reverse Proxy..."

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
echo "===> 10. Проверка статуса сервисов и очистка..."

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