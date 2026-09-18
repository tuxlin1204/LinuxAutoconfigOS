
#!/bin/bash

# ==========================================
# Omarchy / Arch Linux
# Настройка сетевых интерфейсов через nmcli
# ==========================================

clear

# Проверка NetworkManager
if ! command -v nmcli &>/dev/null; then
    echo "Ошибка: nmcli не найден."
    echo "Установите NetworkManager."
    exit 1
fi

# Проверка sudo
if ! sudo -v; then
    echo "Не удалось получить права sudo."
    exit 1
fi

# ------------------------------------------
# Преобразование маски в CIDR
# ------------------------------------------

mask_to_cidr() {
    local mask=$1
    local cidr=0
    local octet

    IFS='.' read -ra OCTETS <<< "$mask"

    if [ "${#OCTETS[@]}" -ne 4 ]; then
        return 1
    fi

    for octet in "${OCTETS[@]}"; do
        case "$octet" in
            255) cidr=$((cidr + 8)) ;;
            254) cidr=$((cidr + 7)) ;;
            252) cidr=$((cidr + 6)) ;;
            248) cidr=$((cidr + 5)) ;;
            240) cidr=$((cidr + 4)) ;;
            224) cidr=$((cidr + 3)) ;;
            192) cidr=$((cidr + 2)) ;;
            128) cidr=$((cidr + 1)) ;;
            0) ;;
            *) return 1 ;;
        esac
    done

    echo "$cidr"
}

# ------------------------------------------
# Проверка IPv4
# ------------------------------------------

valid_ip() {
    local ip=$1
    local IFS=.
    read -ra ADDR <<< "$ip"

    [ "${#ADDR[@]}" -eq 4 ] || return 1

    for i in "${ADDR[@]}"; do
        [[ "$i" =~ ^[0-9]+$ ]] || return 1
        [ "$i" -ge 0 ] && [ "$i" -le 255 ] || return 1
    done

    return 0
}

# ------------------------------------------
# Выбор интерфейса
# ------------------------------------------

choose_interface() {

    while true; do
        clear

        echo "=========================================="
        echo "       СЕТЕВЫЕ ИНТЕРФЕЙСЫ"
        echo "=========================================="
        echo

        mapfile -t INTERFACES < <(
            nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status |
            grep -v '^lo:'
        )

        if [ "${#INTERFACES[@]}" -eq 0 ]; then
            echo "Сетевые интерфейсы не найдены."
            read -rp "Нажмите Enter для выхода..."
            exit 1
        fi

        echo "№  ИНТЕРФЕЙС        ТИП        СОСТОЯНИЕ       ПОДКЛЮЧЕНИЕ"
        echo "----------------------------------------------------------"

        for i in "${!INTERFACES[@]}"; do

            IFS=':' read -r DEVICE TYPE STATE CONNECTION <<< "${INTERFACES[$i]}"

            printf "%-3s %-16s %-10s %-15s %s\n" \
                "$((i+1))" \
                "$DEVICE" \
                "$TYPE" \
                "$STATE" \
                "$CONNECTION"
        done

        echo
        echo "0) Выход"
        echo

        read -rp "Выберите интерфейс: " CHOICE

        if [[ "$CHOICE" == "0" ]]; then
            exit 0
        fi

        if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] ||
           [ "$CHOICE" -lt 1 ] ||
           [ "$CHOICE" -gt "${#INTERFACES[@]}" ]; then

            echo
            echo "Неверный выбор."
            sleep 2
            continue
        fi

        SELECTED="${INTERFACES[$((CHOICE-1))]}"

        IFS=':' read -r DEVICE TYPE STATE CONNECTION <<< "$SELECTED"

        # Если подключения нет — создаём его
        if [ "$CONNECTION" = "--" ] || [ -z "$CONNECTION" ]; then

            echo
            echo "Для $DEVICE нет NetworkManager-подключения."
            echo "Создаём новое подключение..."

            CONNECTION="$DEVICE"

            sudo nmcli connection add \
                type "$TYPE" \
                ifname "$DEVICE" \
                con-name "$CONNECTION" \
                >/dev/null

        fi

        configure_interface
    done
}

# ------------------------------------------
# Настройка интерфейса
# ------------------------------------------

configure_interface() {

    while true; do

        clear

        echo "=========================================="
        echo "       НАСТРОЙКА СЕТИ"
        echo "=========================================="
        echo
        echo "Интерфейс : $DEVICE"
        echo "Тип       : $TYPE"
        echo "Подключение: $CONNECTION"
        echo

        echo "1) Статический IP"
        echo "2) DHCP"
        echo "3) Показать текущие настройки"
        echo "4) Назад"
        echo "0) Выход"
        echo

        read -rp "Выберите действие: " ACTION

        case "$ACTION" in

            1)
                configure_static
                ;;

            2)
                configure_dhcp
                ;;

            3)
                clear

                echo "=========================================="
                echo "       ТЕКУЩИЕ НАСТРОЙКИ"
                echo "=========================================="
                echo

                nmcli connection show "$CONNECTION"

                echo
                echo "IP:"
                nmcli device show "$DEVICE" | grep -E \
                    'IP4.ADDRESS|IP4.GATEWAY|IP4.DNS'

                echo
                read -rp "Нажмите Enter..."
                ;;

            4)
                return
                ;;

            0)
                exit 0
                ;;

            *)
                echo "Неверный выбор."
                sleep 2
                ;;

        esac
    done
}

# ------------------------------------------
# Статический IP
# ------------------------------------------

configure_static() {

    clear

    echo "=========================================="
    echo "       СТАТИЧЕСКИЙ IP"
    echo "=========================================="
    echo
    echo "Интерфейс: $DEVICE"
    echo

    while true; do
        read -rp "IP-адрес: " IP

        if valid_ip "$IP"; then
            break
        fi

        echo "Ошибка: неправильный IP."
    done

    while true; do
        read -rp "Маска (например 255.255.255.0): " MASK

        CIDR=$(mask_to_cidr "$MASK")

        if [ $? -eq 0 ]; then
            break
        fi

        echo "Ошибка: неправильная маска."
    done

    while true; do
        read -rp "Шлюз: " GATEWAY

        if valid_ip "$GATEWAY"; then
            break
        fi

        echo "Ошибка: неправильный шлюз."
    done

    read -rp "DNS-сервер [8.8.8.8]: " DNS

    if [ -z "$DNS" ]; then
        DNS="8.8.8.8"
    fi

    read -rp "DNS-домен/суффикс (можно оставить пустым): " DOMAIN

    echo
    echo "=========================================="
    echo "ПРОВЕРКА НАСТРОЕК"
    echo "=========================================="
    echo
    echo "Интерфейс : $DEVICE"
    echo "IP        : $IP/$CIDR"
    echo "Маска     : $MASK"
    echo "Шлюз      : $GATEWAY"
    echo "DNS       : $DNS"
    echo "Домен     : ${DOMAIN:-не указан}"
    echo

    read -rp "Применить настройки? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "Отменено."
        sleep 2
        return
    fi

    echo
    echo "Применяем настройки..."

    # IPv4
    sudo nmcli connection modify "$CONNECTION" \
        ipv4.method manual \
        ipv4.addresses "$IP/$CIDR" \
        ipv4.gateway "$GATEWAY" \
        ipv4.dns "$DNS"

    # DNS search domain
    if [ -n "$DOMAIN" ]; then
        sudo nmcli connection modify "$CONNECTION" \
            ipv4.dns-search "$DOMAIN"
    else
        sudo nmcli connection modify "$CONNECTION" \
            ipv4.dns-search ""
    fi

    # Отключаем и включаем подключение
    sudo nmcli connection down "$CONNECTION" 2>/dev/null
    sleep 1
    sudo nmcli connection up "$CONNECTION"

    echo
    echo "=========================================="
    echo "       ГОТОВО"
    echo "=========================================="
    echo

    nmcli device show "$DEVICE" | grep -E \
        'GENERAL.DEVICE|GENERAL.STATE|IP4.ADDRESS|IP4.GATEWAY|IP4.DNS'

    echo
    read -rp "Нажмите Enter..."
}

# ------------------------------------------
# DHCP
# ------------------------------------------

configure_dhcp() {

    clear

    echo "=========================================="
    echo "       НАСТРОЙКА DHCP"
    echo "=========================================="
    echo

    read -rp "Перевести $DEVICE в DHCP? [y/N]: " CONFIRM

    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        return
    fi

    sudo nmcli connection modify "$CONNECTION" \
        ipv4.method auto \
        ipv4.addresses "" \
        ipv4.gateway "" \
        ipv4.dns "" \
        ipv4.dns-search ""

    sudo nmcli connection down "$CONNECTION" 2>/dev/null
    sleep 1
    sudo nmcli connection up "$CONNECTION"

    echo
    echo "DHCP включён."
    echo

    nmcli device show "$DEVICE" | grep -E \
        'GENERAL.DEVICE|GENERAL.STATE|IP4.ADDRESS|IP4.GATEWAY|IP4.DNS'

    echo
    read -rp "Нажмите Enter..."
}

# ------------------------------------------
# Запуск
# ------------------------------------------

choose_interface
```

