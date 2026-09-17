#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   log_error "Этот скрипт должен выполняться от root (sudo)"
   exit 1
fi

# Проверка, что это Omarchy (Arch-based)
if ! command -v pacman &> /dev/null; then
    log_error "Omarchy должна использовать pacman. Менеджер пакетов не найден."
    exit 1
fi

log_step "=== Omarchy System Configuration Script ==="
echo

# ============================================================
# 1. Ввод IP-адреса (опционально)
# ============================================================
log_step "1. Настройка сети (опционально)"
echo
log_info "Настроить статический IP? (y/n):"
read -r CONFIGURE_NETWORK

if [[ "$CONFIGURE_NETWORK" == "y" || "$CONFIGURE_NETWORK" == "Y" ]]; then
    # Текущие значения по умолчанию
    CURRENT_IP=$(ip -4 addr show enp4s0 2>/dev/null | grep -oP 'inet \K[\d.]+' || echo "192.168.0.177")
    CURRENT_PREFIX="22"
    CURRENT_GATEWAY=$(ip route show default 2>/dev/null | awk '{print $3}' || echo "192.168.1.1")
    CURRENT_DNS=$(grep -oP 'nameserver \K[\d.]+' /etc/resolv.conf 2>/dev/null | head -1 || echo "192.168.1.92")
    CURRENT_SEARCH=$(grep -oP 'search \K\S+' /etc/resolv.conf 2>/dev/null | head -1 || echo "SRG-ECO.LOC")

    log_info "Введите статический IPv4-адрес (по умолчанию: ${CURRENT_IP}):"
    read -r NEW_IP
    NEW_IP=${NEW_IP:-$CURRENT_IP}

    # Валидация простого формата IPv4
    if ! [[ $NEW_IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Неверный формат IP-адреса"
        exit 1
    fi

    # Ввод шлюза по умолчанию
    echo
    log_info "Введите шлюз по умолчанию (по умолчанию: ${CURRENT_GATEWAY}):"
    read -r GATEWAY
    GATEWAY=${GATEWAY:-$CURRENT_GATEWAY}

    # Ввод маски подсети (префикс)
    echo
    log_info "Введите префикс подсети (по умолчанию: ${CURRENT_PREFIX}):"
    read -r PREFIX
    PREFIX=${PREFIX:-$CURRENT_PREFIX}

    # Ввод DNS
    echo
    log_info "Введите DNS-сервер (по умолчанию: ${CURRENT_DNS}):"
    read -r DNS_SERVER
    DNS_SERVER=${DNS_SERVER:-$CURRENT_DNS}

    # Ввод домена для поиска
    echo
    log_info "Введите домен для поиска (по умолчанию: ${CURRENT_SEARCH}):"
    read -r DNS_SEARCH
    DNS_SEARCH=${DNS_SEARCH:-$CURRENT_SEARCH}

    # Попытка настройки NetworkManager
    echo
    log_step "1.1 Настройка NetworkManager"
    echo

    CONNECTION_FILE=$(find /etc/NetworkManager/system-connections/ -name "*.nmconnection" -type f 2>/dev/null | head -n1)

    if [[ -n "$CONNECTION_FILE" ]]; then
        log_info "✓ Найдено соединение: $CONNECTION_FILE"
        cp "$CONNECTION_FILE" "${CONNECTION_FILE}.bak.$(date +%s)"

        sed -i "s/^address1=.*/address1=${NEW_IP}\/${PREFIX}/" "$CONNECTION_FILE"
        sed -i "s/^gateway=.*/gateway=${GATEWAY}/" "$CONNECTION_FILE"
        sed -i "s/^dns=.*/dns=${DNS_SERVER};/" "$CONNECTION_FILE"
        sed -i "s/^dns-search=.*/dns-search=${DNS_SEARCH};/" "$CONNECTION_FILE"

        chmod 600 "$CONNECTION_FILE"

        if nmcli connection reload 2>/dev/null; then
            log_info "✓ NetworkManager перезагружен"
        else
            log_warn "nmcli connection reload не удался"
        fi

        # Перезапуск соединения
        CONN_NAME=$(nmcli -t -f NAME connection show --active 2>/dev/null | grep -E "ethernet|Wired" | head -1 | cut -d: -f1)
        if [[ -n "$CONN_NAME" ]]; then
            if nmcli connection down "$CONN_NAME" 2>/dev/null && nmcli connection up "$CONN_NAME" 2>/dev/null; then
                log_info "✓ Соединение '${CONN_NAME}' перезапущено"
            else
                log_warn "Не удалось перезапустить соединение"
            fi
        fi

        # Обновление resolv.conf
        cat > /etc/resolv.conf <<EOF
search ${DNS_SEARCH}
nameserver ${DNS_SERVER}
EOF
        chmod 644 /etc/resolv.conf

        log_info "✓ NetworkManager обновлён"
        log_info "  IP:   ${NEW_IP}/${PREFIX}"
        log_info "  DNS:  ${DNS_SERVER}"
        log_info "  Поиск: ${DNS_SEARCH}"
    else
        log_warn "NetworkManager не найден или не настроен"
        log_info "Настройка сети пропущена"
        log_info "Для настройки используйте:"
        log_info "  - nmtui (текстовый интерфейс)"
        log_info "  - nm-connection-editor (GUI)"
        log_info "  - Настройки в Omarchy Menu (Super + A)"
    fi
else
    log_info "Настройка сети пропущена"
fi

# ============================================================
# 2. Выбор диска для монтирования
# ============================================================
echo
log_step "2. Настройка монтирования диска"
echo
log_info "Доступные диски и разделы:"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,FSTYPE --noheadings | grep -v "loop" || true

echo
log_info "Введите имя устройства (например, sdb1):"
read -r DISK_NAME

# Проверка существования устройства
if [[ ! -b "/dev/$DISK_NAME" ]]; then
    log_error "Устройство /dev/$DISK_NAME не найдено"
    exit 1
fi

echo
log_info "Введите точку монтирования (например, /mnt/Disk):"
read -r MOUNT_POINT

echo
log_info "Введите тип файловой системы (ntfs-3g, ext4, vfat, exfat и т.д.):"
read -r FS_TYPE

# Опции монтирования по умолчанию
echo
log_info "Введите опции монтирования (или нажмите Enter для defaults):"
log_info "Пример: defaults,uid=1000,gid=1000,umask=077,noatime"
read -r MOUNT_OPTIONS

if [[ -z "$MOUNT_OPTIONS" ]]; then
    MOUNT_OPTIONS="defaults,uid=1000,gid=1000,umask=077,noatime"
fi

# ============================================================
# 3. Настройка fstab (монтирование диска)
# ============================================================
echo
log_step "3. Настройка /etc/fstab"
echo

# Создание точки монтирования
mkdir -p "$MOUNT_POINT"
log_info "✓ Создана точка монтирования: $MOUNT_POINT"

# Получение UUID диска
DISK_UUID=$(blkid -s UUID -o value "/dev/$DISK_NAME" 2>/dev/null || true)

if [[ -z "$DISK_UUID" ]]; then
    log_warn "UUID для /dev/$DISK_NAME не найден"
    log_info "Используем прямое указание устройства"
    FSTAB_ENTRY="/dev/${DISK_NAME} ${MOUNT_POINT} ${FS_TYPE} ${MOUNT_OPTIONS} 0 0"
else
    log_info "✓ UUID диска: ${DISK_UUID}"
    FSTAB_ENTRY="UUID=${DISK_UUID} ${MOUNT_POINT} ${FS_TYPE} ${MOUNT_OPTIONS} 0 0"
fi

# Проверка, существует ли уже запись
if ! grep -q "/dev/$DISK_NAME" /etc/fstab && ! grep -q "$DISK_UUID" /etc/fstab 2>/dev/null; then
    echo "$FSTAB_ENTRY" >> /etc/fstab
    log_info "✓ Добавлена запись в /etc/fstab"
    log_info "  Запись: $FSTAB_ENTRY"
else
    log_warn "Запись для ${DISK_NAME} уже существует в /etc/fstab"
    log_info "Пропускаем добавление"
fi

# ============================================================
# 4. Настройка SSH для текущего пользователя
# ============================================================
echo
log_step "4. Настройка SSH (Omarchy/Arch)"
echo

# Определение текущего пользователя
CURRENT_USER=$(who | awk '{print $1}' | head -n1)
if [[ -z "$CURRENT_USER" ]]; then
    CURRENT_USER=$(logname 2>/dev/null || echo "user")
fi

log_info "Текущий пользователь: $CURRENT_USER"

# Проверка установки OpenSSH
if command -v sshd &> /dev/null; then
    log_info "✓ OpenSSH уже установлен"
else
    log_info "Установка OpenSSH через pacman..."
    pacman -Sy --noconfirm openssh
fi

# Включение и запуск службы SSH
log_info "Включение службы sshd..."
systemctl enable sshd

log_info "Запуск службы sshd..."
systemctl start sshd

# Проверка статуса
if systemctl is-active --quiet sshd; then
    log_info "✓ SSH-сервер запущен"
else
    log_error "Не удалось запустить SSH-сервер"
fi

# Настройка брандмауэра (если есть)
if command -v ufw &> /dev/null; then
    log_info "Настройка ufw..."
    ufw allow ssh
    ufw enable
    log_info "✓ Порт SSH (22) открыт в ufw"
elif command -v firewall-cmd &> /dev/null; then
    log_info "Настройка firewalld..."
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --reload
    log_info "✓ Порт SSH (22) открыт в firewalld"
else
    log_info "ℹ Брандмауэр не обнаружен (настройте вручную при необходимости)"
fi

log_info "✓ SSH настроен для пользователя: $CURRENT_USER"

# ============================================================
# 5. Итог
# ============================================================
echo
log_step "=== Настройка завершена ==="
echo
echo "┌─────────────────────────────────────────────────┐"
echo "│  ДИСК                                           │"
echo "│  Устройство:    /dev/${DISK_NAME}"
echo "│  Точка:         ${MOUNT_POINT}"
echo "│  Тип ФС:        ${FS_TYPE}"
echo "│  Опции:         ${MOUNT_OPTIONS}"
echo "├─────────────────────────────────────────────────┤"
echo "│  SSH                                            │"
echo "│  Пользователь:  ${CURRENT_USER}"
echo "│  Статус:        Активен"
echo "└─────────────────────────────────────────────────┘"
echo
log_warn "Рекомендуется проверить монтирование:"
log_warn "  sudo mount -a"
log_warn "  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT"
echo
log_info "Для подключения по SSH:"
log_info "  ssh ${CURRENT_USER}@<IP-адрес>"
