#!/usr/bin/env bash

# RSS Bridge LXC Installation Script for Proxmox VE
# Автоматическая установка RSS Bridge в LXC контейнер
# 
# Использование: bash rss-bridge-install.sh

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
║         RSS Bridge LXC Installer              ║
║         для Proxmox VE 8.x/9.x                ║
╚═══════════════════════════════════════════════╝
EOF
echo -e "${NC}"

# Настройки по умолчанию
CTID=$(pvesh get /cluster/nextid)
HOSTNAME="rss-bridge"
DISK_SIZE=4
CPU_CORES=1
RAM_MB=1024
STORAGE="local-lvm"
BRIDGE="vmbr0"
PASSWORD="rssbridge"
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
msg_info "Начинаю установку RSS Bridge..."
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
    --description "RSS Bridge - RSS feed generator"

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

# Установка Docker и RSS Bridge
msg_info "Установка Docker и RSS Bridge (это займёт несколько минут)..."

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
mkdir -p /opt/rss-bridge

echo "Создание docker-compose.yml..."
cat > /opt/rss-bridge/docker-compose.yml << "COMPOSE_EOF"
version: "3"
services:
  rss-bridge:
    image: rssbridge/rss-bridge:latest
    container_name: rss-bridge
    restart: unless-stopped
    ports:
      - "80:80"
    environment:
      - TZ=Europe/Warsaw
    volumes:
      - ./config:/config
COMPOSE_EOF

echo "Запуск RSS Bridge..."
cd /opt/rss-bridge
docker compose up -d

echo "Ожидание запуска RSS Bridge..."
sleep 10

echo "Настройка whitelist..."
docker exec rss-bridge sh -c "echo \"*\" > /config/whitelist.txt"

echo "Создание custom bridge для in-poland.com..."
docker exec rss-bridge sh -c '\''cat > /app/bridges/InPolandBridge.php << "BRIDGE_EOF"
<?php

class InPolandBridge extends BridgeAbstract
{
    const NAME = '\''In-Poland News'\'';
    const URI = '\''https://in-poland.com'\'';
    const DESCRIPTION = '\''Новости Польши с сайта in-poland.com'\'';
    const MAINTAINER = '\''anonymous'\'';
    const PARAMETERS = [
        [
            '\''category'\'' => [
                '\''name'\'' => '\''Категория'\'',
                '\''type'\'' => '\''list'\'',
                '\''required'\'' => false,
                '\''defaultValue'\'' => '\''novosti'\'',
                '\''values'\'' => [
                    '\''Новости'\'' => '\''novosti'\'',
                    '\''Работа'\'' => '\''rabota'\'',
                    '\''Жизнь в Польше'\'' => '\''zhizn'\'',
                ]
            ],
            '\''limit'\'' => [
                '\''name'\'' => '\''Количество статей'\'',
                '\''type'\'' => '\''number'\'',
                '\''required'\'' => false,
                '\''defaultValue'\'' => 10
            ]
        ]
    ];

    public function collectData()
    {
        $category = $this->getInput('\''category'\'') ?: '\''novosti'\'';
        $limit = $this->getInput('\''limit'\'') ?: 10;
        
        $url = self::URI . '\''/category/'\'' . $category . '\''/'\'';
        
        $opts = [
            '\''http'\'' => [
                '\''method'\'' => "GET",
                '\''header'\'' => "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36\r\n"
            ]
        ];
        $context = stream_context_create($opts);
        
        $html = getContents($url, [], $context);
        $dom = new DOMDocument();
        @$dom->loadHTML($html);
        $xpath = new DOMXPath($dom);
        
        // Поиск статей
        $articles = $xpath->query('\''//article | //div[contains(@class, "post")] | //div[contains(@class, "news-item")]'\'');
        
        $count = 0;
        foreach ($articles as $article) {
            if ($count >= $limit) break;
            
            // Заголовок
            $titleNodes = $xpath->query('\''.//h2 | .//h3 | .//h1'\'', $article);
            if ($titleNodes->length == 0) continue;
            $title = trim($titleNodes->item(0)->textContent);
            
            // Ссылка
            $linkNodes = $xpath->query('\''.//a'\'', $article);
            if ($linkNodes->length == 0) continue;
            $link = $linkNodes->item(0)->getAttribute('\''href'\'');
            
            // Если относительная ссылка, добавить базовый URL
            if (!preg_match('\''~^https?://~'\'', $link)) {
                $link = self::URI . $link;
            }
            
            // Описание
            $descNodes = $xpath->query('\''.//p'\'', $article);
            $description = $descNodes->length > 0 ? trim($descNodes->item(0)->textContent) : '\'''\'';
            
            // Дата
            $dateNodes = $xpath->query('\''.//time'\'', $article);
            $timestamp = time();
            if ($dateNodes->length > 0) {
                $dateStr = $dateNodes->item(0)->getAttribute('\''datetime'\'');
                if (!empty($dateStr)) {
                    $timestamp = strtotime($dateStr);
                }
            }
            
            if (!empty($title) && !empty($link)) {
                $item = [
                    '\''title'\'' => $title,
                    '\''uri'\'' => $link,
                    '\''content'\'' => $description,
                    '\''timestamp'\'' => $timestamp
                ];
                
                $this->items[] = $item;
                $count++;
            }
        }
    }

    public function getName()
    {
        $category = $this->getInput('\''category'\'') ?: '\''novosti'\'';
        return self::NAME . '\'' - '\'' . ucfirst($category);
    }
}
BRIDGE_EOF'\''

echo "Перезапуск RSS Bridge..."
docker restart rss-bridge
sleep 10
'

if [ $? -ne 0 ]; then
    msg_error "Ошибка при установке"
    exit 1
fi
msg_ok "RSS Bridge установлен и запущен"

# Получение IP адреса
IP=$(pct exec $CTID -- hostname -I | awk '{print $1}')

# Финальный вывод
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         RSS Bridge успешно установлен!                    ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Информация о контейнере:${NC}"
echo -e "  Container ID:    ${GREEN}$CTID${NC}"
echo -e "  Hostname:        ${GREEN}$HOSTNAME${NC}"
echo -e "  IP Address:      ${GREEN}$IP${NC}"
echo -e "  Root Password:   ${GREEN}$PASSWORD${NC}"
echo ""
echo -e "${YELLOW}Доступ к RSS Bridge:${NC}"
echo -e "  Web интерфейс:   ${GREEN}http://$IP${NC}"
echo ""
echo -e "${YELLOW}RSS feeds для in-poland.com:${NC}"
echo -e "  Новости:         ${GREEN}http://$IP/?action=display&bridge=InPoland&category=novosti&format=Atom${NC}"
echo -e "  Работа:          ${GREEN}http://$IP/?action=display&bridge=InPoland&category=rabota&format=Atom${NC}"
echo -e "  Жизнь:           ${GREEN}http://$IP/?action=display&bridge=InPoland&category=zhizn&format=Atom${NC}"
echo ""
echo -e "${YELLOW}Альтернативные форматы:${NC}"
echo -e "  RSS:             ${GREEN}format=Rss${NC}"
echo -e "  JSON:            ${GREEN}format=Json${NC}"
echo -e "  HTML:            ${GREEN}format=Html${NC}"
echo ""
echo -e "${YELLOW}Полезные команды:${NC}"
echo -e "  Войти в shell:           ${BLUE}pct enter $CTID${NC}"
echo -e "  Просмотр логов:          ${BLUE}pct exec $CTID -- docker logs -f rss-bridge${NC}"
echo -e "  Перезапуск:              ${BLUE}pct exec $CTID -- docker restart rss-bridge${NC}"
echo -e "  Остановить контейнер:    ${BLUE}pct stop $CTID${NC}"
echo -e "  Запустить контейнер:     ${BLUE}pct start $CTID${NC}"
echo ""
echo -e "${YELLOW}Обновление RSS Bridge:${NC}"
echo -e "  ${BLUE}pct exec $CTID -- bash -c 'cd /opt/rss-bridge && docker compose pull && docker compose up -d'${NC}"
echo ""
echo -e "${YELLOW}Добавить feed в FreshRSS:${NC}"
echo -e "  1. Откройте FreshRSS"
echo -e "  2. Подписка → Добавить поток"
echo -e "  3. URL: ${GREEN}http://$IP/?action=display&bridge=InPoland&category=novosti&format=Atom${NC}"
echo -e "  4. Тип: ${GREEN}RSS/Atom feed${NC}"
echo ""
echo -e "${GREEN}✓ Готово! Откройте http://$IP в браузере и найдите 'In-Poland News'${NC}"
echo ""
