# VPS Bootstrap for Ubuntu + Caddy + NanoClaw

Автоматизированный скрипт первично подготавливает свежий сервер Ubuntu (22.04 / 24.04 LTS), создаёт безопасно настроенного пользователя, разворачивает swap, Caddy в качестве Reverse Proxy и устанавливает NanoClaw.

## 🚀 Быстрый запуск

```bash
curl -fsSL [https://raw.githubusercontent.com/pavelpvg/vps-bootstrap-ubuntu-caddy-nanoclaw/main/bootstrap-ubuntu-setup.sh](https://raw.githubusercontent.com/pavelpvg/vps-bootstrap-ubuntu-caddy-nanoclaw/main/bootstrap-ubuntu-setup.sh) | bash