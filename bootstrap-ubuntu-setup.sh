#!/usr/bin/env bash

set -euo pipefail
set -o errtrace

# Продвинутый трап ошибок с поддержкой BASH_LINENO
trap 'rc=$?; echo "❌ ERROR: Ошибка (код $rc) в строке ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2; exit $rc' ERR

# ==========================================
# CONFIGURATION
# ==========================================

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
apt install -y acl caddy curl wget git ufw fail2ban sysstat htop unzip software-properties-common ca-certificates gnupg dbus-user-session

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
# 4. NODE.JS 20 & PNPM (COREPACK PINNED)
# ==========================================
echo "===> 4. Установка и проверка Node.js 20 и pnpm..."

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
# 5. DOCKER ENGINE INSTALLATION
# ==========================================
echo "===> 5. Установка и проверка Docker..."

# Установка Docker при отсутствии
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

    chmod a+r /etc/apt/keyrings/docker.gpg

    cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable
EOF

    apt update -qq
    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

# Гарантируем запуск Docker
systemctl enable --now docker

echo "🔄 Проверка Docker Daemon..."

if ! timeout 15 docker info >/dev/null 2>&1; then
    echo "❌ Docker daemon недоступен." >&2
    exit 1
fi

if ! timeout 15 docker version >/dev/null 2>&1; then
    echo "❌ Docker API недоступен." >&2
    exit 1
fi

# Добавляем пользователя в docker только если требуется
if ! id -nG "${NEW_USER}" | grep -qw docker; then
    echo "➕ Добавление ${NEW_USER} в группу docker..."
    usermod -aG docker "${NEW_USER}"

    if ! getent group docker | grep -qw "${NEW_USER}"; then
        echo "❌ Не удалось добавить пользователя ${NEW_USER} в группу docker." >&2
        exit 1
    fi
fi

# Немедленный доступ к Docker без новой login-сессии
if command -v setfacl >/dev/null 2>&1 && [ -S /var/run/docker.sock ]; then
    echo "🔑 Выдача ACL на Docker socket..."

    if setfacl -m "u:${NEW_USER}:rw" /var/run/docker.sock; then

        if sudo -u "${NEW_USER}" test -r /var/run/docker.sock &&
           sudo -u "${NEW_USER}" test -w /var/run/docker.sock; then

            echo "✔ Пользователь ${NEW_USER} получил доступ к Docker socket."

        else
            echo "⚠️ ACL установлен, но проверка доступа не пройдена."
        fi

    else
        echo "⚠️ Не удалось установить ACL на /var/run/docker.sock."
    fi
else
    echo "⚠️ ACL не применён (нет setfacl или отсутствует docker.sock)."
fi

echo "✔ Docker Engine : $(docker version --format '{{.Client.Version}}')"
echo "✔ Docker Compose: $(docker compose version --short)"

# ==========================================
# 6. HARDENING: SSH, FIREWALL, FAIL2BAN
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
# 8. CADDY REVERSE PROXY SETUP
# ==========================================

if [ -z "${PUBLIC_DOMAIN:-}" ]; then
    read -rp "Домен для NanoClaw (оставьте пустым для работы по IP): " PUBLIC_DOMAIN
    PUBLIC_DOMAIN="$(printf '%s' "${PUBLIC_DOMAIN}" | xargs)"
fi

echo "✔ Используется домен: ${PUBLIC_DOMAIN:-<IP>}"

echo "===> 8. Настройка Caddy Reverse Proxy..."

if ! command -v caddy >/dev/null 2>&1; then
    echo "❌ Caddy не установлен." >&2
    exit 1
fi

if ! command -v systemctl >/dev/null 2>&1; then
    echo "❌ systemctl не найден (требуется окружение с systemd)." >&2
    exit 1
fi

echo "📦 Подготовка директорий..."

install -d -m 755 \
    -o "${NEW_USER}" \
    -g "${NEW_USER}" \
    "${CADDY_DIR}"

if [ -z "${PUBLIC_DOMAIN:-}" ]; then
    read -rp "Домен для NanoClaw (оставьте пустым для работы по IP): " PUBLIC_DOMAIN
    PUBLIC_DOMAIN="$(printf '%s' "${PUBLIC_DOMAIN}" | xargs)"
fi

echo "📝 Создание шаблона Caddyfile..."

if [ -n "${PUBLIC_DOMAIN:-}" ]; then
    install -m 644 \
        -o "${NEW_USER}" \
        -g "${NEW_USER}" \
        /dev/stdin \
        "${CADDY_DIR}/Caddyfile" <<EOF
${PUBLIC_DOMAIN} {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3000
    log
}
EOF
else
    install -m 644 \
        -o "${NEW_USER}" \
        -g "${NEW_USER}" \
        /dev/stdin \
        "${CADDY_DIR}/Caddyfile" <<'EOF'
:80 {
    encode gzip zstd
    reverse_proxy 127.0.0.1:3000
    log
}
EOF
fi

echo "📋 Настройка системной конфигурации Caddy..."

install -d -m 755 /etc/caddy

ln -sfn "${CADDY_DIR}/Caddyfile" /etc/caddy/Caddyfile

if [ "$(readlink -f /etc/caddy/Caddyfile)" != "${CADDY_DIR}/Caddyfile" ]; then
    echo "❌ Символическая ссылка /etc/caddy/Caddyfile настроена неверно." >&2
    exit 1
fi

echo "📝 Форматирование конфигурации..."

if ! caddy fmt --overwrite "${CADDY_DIR}/Caddyfile"; then
    echo "❌ Ошибка форматирования Caddyfile." >&2
    exit 1
fi

echo "🔍 Проверка конфигурации..."

if ! caddy validate --adapter caddyfile --config "${CADDY_DIR}/Caddyfile"; then
    echo "❌ Конфигурация Caddy содержит ошибки." >&2
    exit 1
fi

echo "🚀 Управление сервисом Caddy..."

if systemctl is-active --quiet caddy; then
    echo "♻ Перезапуск Caddy..."
    if ! systemctl restart caddy; then
        echo "❌ Не удалось перезапустить Caddy." >&2
        systemctl --no-pager --lines=10 status caddy
        journalctl -u caddy --no-pager --no-hostname -n 50
        exit 1
    fi
else
    echo "🚀 Запуск Caddy..."
    if ! systemctl enable --now caddy >/dev/null; then
        echo "❌ Не удалось запустить Caddy." >&2
        systemctl --no-pager --lines=10 status caddy
        journalctl -u caddy --no-pager --no-hostname -n 50
        exit 1
    fi
fi

if systemctl is-active --quiet caddy; then
    echo "♻ Перезапуск Caddy..."
    systemctl restart caddy
else
    echo "🚀 Запуск Caddy..."
    systemctl start caddy
fi


echo "⏳ Ожидание отклика от Caddy..."

CADDY_READY=false
for i in {1..15}; do
    if curl --max-time 5 http://127.0.0.1 >/dev/null 2>&1; then
        CADDY_READY=true
        break
    fi
    sleep 1
done

if [ "${CADDY_READY}" != "true" ]; then
    echo "❌ Caddy запущен, но не отвечает на запросы." >&2
    systemctl --no-pager --lines=10 status caddy
    journalctl -u caddy --no-pager --no-hostname -n 50
    exit 1
fi

systemctl --no-pager --lines=10 status caddy

echo "✔ Caddy успешно установлен и запущен."

if [ -n "${PUBLIC_DOMAIN:-}" ]; then
    echo "🌐 Reverse Proxy: https://${PUBLIC_DOMAIN}/webhook/telegram"
    echo "ℹ️  Убедитесь, что DNS-запись ${PUBLIC_DOMAIN} уже указывает на этот сервер."
else
    echo "🌐 Reverse Proxy: http://<IP-адрес-сервера>"
    echo "ℹ️  Для автоматического HTTPS повторно запустите установку и укажите домен."
fi

# ==========================================
# 9. POST-INSTALLATION HEALTH CHECK & CLEANUP
# ==========================================
echo "===> 9. Проверка статуса сервисов и очистка..."

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