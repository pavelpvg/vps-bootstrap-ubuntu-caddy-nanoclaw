# VPS Bootstrap for Ubuntu + Caddy + NanoClaw

Автоматизированный скрипт первично подготавливает свежий сервер Ubuntu (22.04 / 24.04 LTS), создаёт безопасно настроенного пользователя, разворачивает swap, Caddy в качестве Reverse Proxy и устанавливает NanoClaw.

## 🚀 Быстрый запуск

```bash
curl -fsSL [https://raw.githubusercontent.com/pavelpvg/vps-bootstrap-ubuntu-caddy-nanoclaw/main/bootstrap-ubuntu-setup.sh](https://raw.githubusercontent.com/pavelpvg/vps-bootstrap-ubuntu-caddy-nanoclaw/main/bootstrap-ubuntu-setup.sh) | bash

## Архитектура
                Internet
                    │
             HTTPS (443)
                    │
                    ▼
              Caddy Reverse Proxy
        • Let's Encrypt
        • Автопродление сертификатов
        • HTTP → HTTPS
        • Reverse Proxy
        • WebSocket
        • HTTP/2 / HTTP/3
                    │
           localhost:3000
                    │
                    ▼
               NanoClaw