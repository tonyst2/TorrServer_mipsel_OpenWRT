#!/bin/sh

username="torrserver"
dirInstall="/opt/torrserver"
serviceName="torrserver"
scriptname=$(basename "$0")
architecture="arm64" # Для FriendlyWrt явно указываем архитектуру (arm64/arm/x64/mipsel и т.д.)

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'

colorize() {
    color=$1; text=$2
    case "$color" in
        red)    echo -e "${RED}${text}${NC}" ;;
        green)  echo -e "${GREEN}${text}${NC}" ;;
        yellow) echo -e "${YELLOW}${text}${NC}" ;;
        *)      echo -e "${text}" ;;
    esac
}

isRoot() { [ "$(id -u)" -eq 0 ]; }

# Имя бинаря по архитектуре
binName() {
    echo "TorrServer-linux-${architecture}"
}

# Проверка интернета (через GitHub API, без ping)
checkInternet() {
    echo " Проверяем соединение с Интернетом..."
    if ! curl -sSf https://api.github.com/ >/dev/null 2>&1; then
        echo " - Нет доступа к api.github.com. Проверьте соединение/DNS."
        exit 1
    fi
    echo " - Соединение с Интернетом успешно"
}

initialCheck() {
    if ! isRoot; then
        echo " Вам нужно запустить скрипт от root. Пример: sh $scriptname -i"
        exit 1
    fi
    command -v curl >/dev/null 2>&1 || { echo " Требуется: opkg update && opkg install curl"; exit 1; }
    checkInternet
}

# Предпочтительно показывать LAN-IP (br-lan), затем fallback на default route
getIP() {
    if ip -4 addr show br-lan >/dev/null 2>&1; then
        ip -4 addr show br-lan | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
        return
    fi
    def_if=$(ip route | awk '/default/{print $5; exit}')
    [ -z "$def_if" ] && { echo "127.0.0.1"; return; }
    ip -4 addr show dev "$def_if" | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
}

# Последний тег релиза
getLatestRelease() {
    curl -s https://api.github.com/repos/YouROK/TorrServer/releases/latest \
      | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/'
}

# Установка shadow-utils при необходимости
ensureUserMgmtTools() {
    if command -v useradd >/dev/null 2>&1 || command -v adduser >/dev/null 2>&1; then
        return 0
    fi
    if command -v opkg >/dev/null 2>&1; then
        echo " Не найдены useradd/adduser. Установить shadow-utils? (установим: shadow-useradd shadow-groupadd shadow-usermod)"
        read -p " Установить через opkg? ($(colorize green Y)es/$(colorize yellow N)o) " ans </dev/tty
        if [ "$ans" != "${ans#[YyДд]}" ]; then
            opkg update && opkg install shadow-useradd shadow-groupadd shadow-usermod || {
                echo " - Не удалось установить shadow-utils"
                return 1
            }
            return 0
        fi
    fi
    echo " - Команды useradd/adduser отсутствуют, продолжим с ручным фолбэком."
    return 0
}

# Убедимся, что есть группа nogroup (gid 65534 обычно занята под неё)
ensureNogroup() {
    if ! grep -q "^nogroup:" /etc/group; then
        if command -v groupadd >/dev/null 2>&1; then
            groupadd -g 65534 nogroup 2>/dev/null || groupadd nogroup 2>/dev/null
        else
            echo "nogroup:x:65534:" >> /etc/group
        fi
    fi
}

addUser() {
    if ! isRoot; then return 1; fi
    [ "$username" = "root" ] && return 0

    [ -d "$dirInstall" ] || mkdir -p "$dirInstall"
    ensureNogroup

    if id "$username" >/dev/null 2>&1; then
        chown -R "$username:nogroup" "$dirInstall"
        chmod 755 "$dirInstall"
        echo " - Пользователь $username уже существует; права на $dirInstall обновлены"
        return 0
    fi

    echo " - Добавляем пользователя $username..."

    if command -v useradd >/dev/null 2>&1; then
        if ! useradd -r -M -d "$dirInstall" -s /bin/false -g nogroup "$username"; then
            echo " - Ошибка: useradd не смог создать $username"
            return 1
        fi
    elif command -v adduser >/dev/null 2>&1; then
        if ! adduser -D -H -h "$dirInstall" -s /bin/false -G nogroup "$username"; then
            echo " - Ошибка: adduser не смог создать $username"
            return 1
        fi
    else
        # Крайний ручной фолбэк — подберём корректный UID >= 1000
        next_uid=$(awk -F: 'BEGIN{max=999} {if($3>max) max=$3} END{print (max<1000?1000:max+1)}' /etc/passwd)
        echo "$username:x:${next_uid}:65534:$username:$dirInstall:/bin/false" >> /etc/passwd
        if ! grep -q "^$username:" /etc/shadow 2>/dev/null; then
            echo "$username:!*:0:0:99999:7:::" >> /etc/shadow
        fi
    fi

    chown -R "$username:nogroup" "$dirInstall"
    chmod 755 "$dirInstall"
    echo " - Пользователь $username создан и назначен владельцем $dirInstall"
    return 0
}

delUser() {
    if ! isRoot; then return 1; fi
    [ "$username" = "root" ] && return 0

    if id "$username" >/dev/null 2>&1; then
        if command -v userdel >/dev/null 2>&1; then
            userdel "$username" 2>/dev/null || echo " - Не удалось удалить через userdel"
        elif command -v deluser >/dev/null 2>&1; then
            deluser "$username" 2>/dev/null || echo " - Не удалось удалить через deluser"
        else
            sed -i "\|^$username:|d" /etc/passwd
            [ -f /etc/shadow ] && sed -i "\|^$username:|d" /etc/shadow
        fi
        echo " - Пользователь $username удален!"
    else
        echo " - Пользователь $username не найден!"
        return 1
    fi
}

checkRunning() {
    pidof "$(binName)" | head -n 1
}

uninstall() {
    checkInstalled
    echo ""
    echo " Директория c TorrServer - ${dirInstall}"
    echo ""
    echo " Это действие удалит все данные TorrServer включая базу и настройки!"
    echo ""
    read -p " Вы уверены что хотите удалить программу? ($(colorize red Y)es/$(colorize yellow N)o) " answer_del </dev/tty
    if [ "$answer_del" != "${answer_del#[YyДд]}" ]; then
        cleanup
        echo " - TorrServer удален из системы!"
        echo ""
    else
        echo ""
    fi
}

cleanup() {
    /etc/init.d/$serviceName stop 2>/dev/null
    /etc/init.d/$serviceName disable 2>/dev/null
    rm -rf "/etc/init.d/$serviceName" "$dirInstall" 2>/dev/null
    delUser
}

helpUsage() {
    echo "$scriptname"
    echo "  -i | --install | install - установка последней версии"
    echo "  -u | --update  | update  - установка последнего обновления, если имеется"
    echo "  -r | --remove  | remove  - удаление TorrServer"
    echo "  -h | --help    | help    - эта справка"
}

# Проверка окружения
initialCheckFull() {
    initialCheck
    ensureUserMgmtTools || true
}

getLatestUrl() {
    tag="$(getLatestRelease)"
    [ -z "$tag" ] && tag="MatriX.136"
    echo "https://github.com/YouROK/TorrServer/releases/download/${tag}/$(binName)"
}

installTorrServer() {
    echo " Устанавливаем и настраиваем TorrServer..."

    [ -d "$dirInstall" ] || mkdir -p "$dirInstall"

    if [ -f "$dirInstall/$(binName)" ]; then
        read -p " TorrServer уже установлен. Хотите обновить? ($(colorize green Y)es/$(colorize yellow N)o) " answer_up </dev/tty
        if [ "$answer_up" != "${answer_up#[YyДд]}" ]; then
            UpdateVersion
            return
        fi
    fi

    urlBin="$(getLatestUrl)"
    echo " Загружаем TorrServer..."
    if ! curl -fL -o "$dirInstall/$(binName)" "$urlBin"; then
        echo " - Скачивание не удалось: $urlBin"
        exit 1
    fi
    chmod +x "$dirInstall/$(binName)"

    addUser || { echo " - Не удалось создать пользователя"; exit 1; }

    # Порт
    read -p " Хотите изменить порт для TorrServer (по умолчанию 8090)? ($(colorize yellow Y)es/$(colorize green N)o) " answer_cp </dev/tty
    if [ "$answer_cp" != "${answer_cp#[YyДд]}" ]; then
        read -p " Введите номер порта: " answer_port </dev/tty
        if echo "$answer_port" | grep -Eq '^[0-9]+$' && [ "$answer_port" -ge 1 ] && [ "$answer_port" -le 65535 ]; then
            servicePort="$answer_port"
        else
            echo " - Некорректный порт, оставляю 8090"
            servicePort="8090"
        fi
    else
        servicePort="8090"
    fi

    # Авторизация
    read -p " Включить авторизацию на сервере? ($(colorize green Y)es/$(colorize yellow N)o) " answer_auth </dev/tty
    if [ "$answer_auth" != "${answer_auth#[YyДд]}" ]; then
        read -p " Пользователь: " isAuthUser </dev/tty
        read -p " Пароль: " isAuthPass </dev/tty
        umask 077
        printf '{\n  "%s": "%s"\n}\n' "$isAuthUser" "$isAuthPass" > "$dirInstall/accs.db"
        authOptions="--port $servicePort --path $dirInstall --httpauth"
    else
        isAuthUser=""
        isAuthPass=""
        authOptions="--port $servicePort --path $dirInstall"
    fi

    # Создаём init-скрипт procd (запуск от пользователя torrserver/nogroup)
    cat << EOF > /etc/init.d/$serviceName
#!/bin/sh /etc/rc.common

START=99
STOP=10

USE_PROCD=1
PROG="$dirInstall/$(binName)"

start_service() {
    procd_open_instance
    procd_set_param command \$PROG $authOptions
    procd_set_param user "$username"
    procd_set_param group "nogroup"
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall $(binName) 2>/dev/null
}

reload_service() {
    stop
    start
}
EOF

    chmod +x /etc/init.d/$serviceName
    /etc/init.d/$serviceName enable
    /etc/init.d/$serviceName start

    serverIP=$(getIP)
    echo ""
    echo " TorrServer установлен в директории ${dirInstall}"
    echo " Теперь вы можете открыть браузер по адресу http://${serverIP}:${servicePort}"
    echo ""
    if [ -n "$isAuthUser" ]; then
        echo " Для авторизации используйте пользователя «$isAuthUser» с паролем «$isAuthPass»"
        echo ""
    fi
    echo " Примечание: предупреждение 'ffprobe not found' некритично. При желании: opkg install ffmpeg"
}

checkInstalled() {
    if [ -f "$dirInstall/$(binName)" ]; then
        echo " - TorrServer найден в директории $dirInstall"
        return 0
    else
        echo " - TorrServer не найден"
        return 1
    fi
}

UpdateVersion() {
    /etc/init.d/$serviceName stop 2>/dev/null
    urlBin="$(getLatestUrl)"
    echo " Обновляем TorrServer..."
    if ! curl -fL -o "$dirInstall/$(binName)" "$urlBin"; then
        echo " - Скачивание не удалось: $urlBin"
        exit 1
    fi
    chmod +x "$dirInstall/$(binName)"
    /etc/init.d/$serviceName start 2>/dev/null || /etc/init.d/$serviceName restart 2>/dev/null
    echo " - TorrServer обновлен!"
}

# Основной код
case "$1" in
    -i|--install|install)
        initialCheckFull
        installTorrServer
        exit
        ;;
    -u|--update|update)
        initialCheckFull
        if checkInstalled; then
            UpdateVersion
        fi
        exit
        ;;
    -r|--remove|remove)
        uninstall
        exit
        ;;
    -h|--help|help)
        helpUsage
        exit
        ;;
    *)
        echo ""
        echo "============================================================="
        echo " Скрипт установки TorrServer для OpenWrt/FriendlyWrt"
        echo "============================================================="
        echo ""
        echo " Введите $scriptname -h для вызова справки"
        ;;
esac

while true; do
    echo ""
    read -p " Хотите установить или настроить TorrServer? ($(colorize green Y)es|$(colorize yellow N)o) Для удаления введите «$(colorize red D)elete» " ydn </dev/tty
    case "$ydn" in
        [YyДд]*)
            initialCheckFull
            installTorrServer
            break
            ;;
        [DdУу]*)
            uninstall
            break
            ;;
        [NnНн]*)
            break
            ;;
        *)
            echo " Введите $(colorize green Y)es, $(colorize yellow N)o или $(colorize red D)elete"
            ;;
    esac
done

echo " Удачи!"
echo ""
