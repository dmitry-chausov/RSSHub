#!/usr/bin/env bash

# RSSHub LXC Installation Script for Proxmox VE
# Автоматическая установка RSSHub в LXC контейнер
# 
# Использование: bash rsshub-install.sh

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Функции для вывода
msg_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

msg_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

msg_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

msg_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Проверка что скрипт запущен на Proxmox
if ! command -v pct &> /dev/null; then
    msg_error "Этот скрипт должен быть запущен на Proxmox VE хосте"
    exit 1
fi

# Баннер
clear
echo -e "${GREEN}"
cat << "EOF"
╔═══════════════════════════════════════════════╗
║          RSSHub LXC Installer                 ║
║         для Proxmox VE 8.x/9.x                ║
╚═══════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Настройки по умолчанию
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="rsshub"
DISK_SIZE=8
CPU_CORES=2
RAM_MB=2048
STORAGE="local-lvm"
BRIDGE="vmbr0"
PASSWORD="rsshub123"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

echo -e "${YELLOW}Настройки по умолчанию:${NC}"
echo "Container ID: $CTID"
echo "Hostname: $HOSTNAME"
echo "Disk: ${DISK_SIZE}GB"
echo "CPU: $CPU_CORES cores"
echo "RAM: ${RAM_MB}MB"
echo "Network: DHCP on $BRIDGE"
echo "Password: $PASSWORD"
echo ""

read -p "Использовать эти настройки? (y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    read -p "Container ID [$CTID]: " input
    CTID=${input:-$CTID}
    
    read -p "Hostname [$HOSTNAME]: " input
    HOSTNAME=${input:-$HOSTNAME}
    
    read -p "Disk Size GB [$DISK_SIZE]: " input
    DISK_SIZE=${input:-$DISK_SIZE}
    
    read -p "CPU Cores [$CPU_CORES]: " input
    CPU_CORES=${input:-$CPU_CORES}
    
    read -p "RAM MB [$RAM_MB]: " input
    RAM_MB=${input:-$RAM_MB}
    
    read -p "Root Password [$PASSWORD]: " input
    PASSWORD=${input:-$PASSWORD}
fi

echo ""
msg_info "Начинаю установку RSSHub..."
echo ""

# Проверка и загрузка шаблона
msg_info "Проверка наличия Debian 12 template..."
if ! pveam list local | grep -q "$TEMPLATE"; then
    msg_warn "Template не найден, загружаю..."
    pveam download local $TEMPLATE
    msg_ok "Template загружен"
else
    msg_ok "Template найден"
fi

# Создание контейнера
msg_info "Создание LXC контейнера..."
pct create $CTID local:vztmpl/$TEMPLATE \
    --hostname $HOSTNAME \
    --cores $CPU_CORES \
    --memory $RAM_MB \
    --swap 512 \
    --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
    --onboot 1 \
    --password "$PASSWORD" \
    --rootfs $STORAGE:$DISK_SIZE \
    --features nesting=1 \
    --unprivileged 1 \
    --ostype debian \
    --description "RSSHub - RSS feed generator"

if [ $? -ne 0 ]; then
    msg_error "Не удалось создать контейнер"
    exit 1
fi
msg_ok "Контейнер создан (ID: $CTID)"

# Запуск контейнера
msg_info "Запуск контейнера..."
pct start $CTID
sleep 5
msg_ok "Контейнер запущен"

# Установка Docker и RSSHub
msg_info "Установка Docker и RSSHub (это займёт несколько минут)..."

pct exec $CTID -- bash -c '
export DEBIAN_FRONTEND=noninteractive

echo "Обновление системы..."
apt-get update > /dev/null 2>&1
apt-get upgrade -y > /dev/null 2>&1

echo "Установка зависимостей..."
apt-get install -y ca-certificates curl gnupg lsb-release > /dev/null 2>&1

echo "Добавление Docker репозитория..."
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

echo "Установка Docker..."
apt-get update > /dev/null 2>&1
apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin > /dev/null 2>&1

echo "Запуск Docker..."
systemctl enable docker > /dev/null 2>&1
systemctl start docker

echo "Создание директорий..."
mkdir -p /opt/rsshub

echo "Создание docker-compose.yml..."
cat > /opt/rsshub/docker-compose.yml << "COMPOSE_EOF"
version: "3"
services:
  rsshub:
    image: diygod/rsshub:latest
    container_name: rsshub
    restart: unless-stopped
    ports:
      - "1200:1200"
    environment:
      NODE_ENV: production
      CACHE_TYPE: memory
      CACHE_EXPIRE: 300
      LISTEN_INADDR_ANY: 1
      # Разрешить доступ ко всем route
      ALLOW_LOCALHOST: "true"
    volumes:
      - ./data:/app/data
COMPOSE_EOF

echo "Запуск RSSHub..."
cd /opt/rsshub
docker compose up -d

echo "Ожидание запуска RSSHub..."
sleep 10
'

if [ $? -ne 0 ]; then
    msg_error "Ошибка при установке"
    exit 1
fi
msg_ok "RSSHub установлен и запущен"

# Получение IP адреса
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

# Создание custom route для in-poland.com
msg_info "Создание custom route для in-poland.com..."

pct exec $CTID -- bash << 'ROUTE_SCRIPT'
# Создание директории для custom routes
docker exec rsshub mkdir -p /app/lib/routes/in-poland

# Создание route файла
docker exec rsshub bash -c 'cat > /app/lib/routes/in-poland/novosti.ts << "EOF"
import { Route } from "@/types";
import cache from "@/utils/cache";
import got from "@/utils/got";
import { load } from "cheerio";
import { parseDate } from "@/utils/parse-date";

export const route: Route = {
    path: "/novosti",
    categories: ["new-media"],
    example: "/in-poland/novosti",
    parameters: {},
    features: {
        requireConfig: false,
        requirePuppeteer: false,
        antiCrawler: false,
        supportBT: false,
        supportPodcast: false,
        supportScihub: false,
    },
    radar: [
        {
            source: ["in-poland.com/category/novosti/"],
        },
    ],
    name: "Новости Польши",
    maintainer: ["anonymous"],
    handler: async () => {
        const baseUrl = "https://in-poland.com";
        const url = `${baseUrl}/category/novosti/`;

        const response = await got({
            method: "get",
            url: url,
            headers: {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            },
        });

        const $ = load(response.data);
        
        let items = $("article, div.post, div.news-item, div[class*=entry]")
            .toArray()
            .slice(0, 20)
            .map((item) => {
                const elem = $(item);
                const title = elem.find("h2, h3, h1").first().text().trim();
                const link = elem.find("a").first().attr("href");
                const description = elem.find("p, div.excerpt, div.summary").first().text().trim();
                const dateStr = elem.find("time").attr("datetime") || elem.find("time").text() || "";
                
                return {
                    title: title || "No title",
                    link: link?.startsWith("http") ? link : `${baseUrl}${link}`,
                    description: description || "",
                    pubDate: dateStr ? parseDate(dateStr) : new Date(),
                };
            })
            .filter((item) => item.title && item.link);

        return {
            title: "In-Poland - Новости Польши",
            link: url,
            description: "Новости Польши с сайта in-poland.com",
            item: items,
        };
    },
};
EOF'

# Перезапуск контейнера для применения изменений
docker restart rsshub
sleep 10
ROUTE_SCRIPT

msg_ok "Custom route создан"

# Финальный вывод
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           RSSHub успешно установлен!                      ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Информация о контейнере:${NC}"
echo -e "  Container ID:    ${GREEN}$CTID${NC}"
echo -e "  Hostname:        ${GREEN}$HOSTNAME${NC}"
echo -e "  IP Address:      ${GREEN}$IP${NC}"
echo -e "  Root Password:   ${GREEN}$PASSWORD${NC}"
echo ""
echo -e "${YELLOW}Доступ к RSSHub:${NC}"
echo -e "  Web интерфейс:   ${GREEN}http://$IP:1200${NC}"
echo ""
echo -e "${YELLOW}RSS feeds для in-poland.com:${NC}"
echo -e "  Atom:            ${GREEN}http://$IP:1200/in-poland/novosti${NC}"
echo -e "  RSS:             ${GREEN}http://$IP:1200/in-poland/novosti?format=rss${NC}"
echo -e "  JSON:            ${GREEN}http://$IP:1200/in-poland/novosti?format=json${NC}"
echo ""
echo -e "${YELLOW}Полезные команды:${NC}"
echo -e "  Войти в shell:           ${BLUE}pct enter $CTID${NC}"
echo -e "  Просмотр логов:          ${BLUE}pct exec $CTID -- docker logs -f rsshub${NC}"
echo -e "  Перезапуск RSSHub:       ${BLUE}pct exec $CTID -- docker restart rsshub${NC}"
echo -e "  Остановить контейнер:    ${BLUE}pct stop $CTID${NC}"
echo -e "  Запустить контейнер:     ${BLUE}pct start $CTID${NC}"
echo ""
echo -e "${YELLOW}Обновление RSSHub:${NC}"
echo -e "  ${BLUE}pct exec $CTID -- bash -c 'cd /opt/rsshub && docker compose pull && docker compose up -d'${NC}"
echo ""
echo -e "${YELLOW}Добавить feed в FreshRSS:${NC}"
echo -e "  1. Откройте FreshRSS"
echo -e "  2. Подписка → Добавить поток"
echo -e "  3. URL: ${GREEN}http://$IP:1200/in-poland/novosti${NC}"
echo -e "  4. Тип: ${GREEN}RSS/Atom feed${NC} (не XPath!)"
echo ""
echo -e "${GREEN}✓ Готово! Проверьте доступность по адресу http://$IP:1200${NC}"
echo ""
