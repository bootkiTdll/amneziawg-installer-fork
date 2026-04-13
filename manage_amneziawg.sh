#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.8.0
# Дата: 2026-04-07
# Репозиторий: https://github.com/bootkiTdll/amneziawg-installer-fork
# ==============================================================================

# --- Безопасный режим и Константы ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.8.0"
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0
JSON_OUTPUT=0
EXPIRES_DURATION=""
WARP_CONF="/etc/amnezia/amneziawg/wg-warp.conf"
WGCF_PATH="$AWG_DIR/wgcf"
WARP_TABLE=1000

# --- Автоочистка временных файлов и директорий ---
# _manage_temp_dirs хранит mktemp -d пути для backup/restore.
# _awg_cleanup из awg_common.sh удаляет файлы (awg_mktemp), но не директории —
# поэтому здесь chained cleanup: сначала наши директории, потом библиотечный.
# Гарантирует что SIGINT во время backup_configs/restore_backup не оставит
# orphan /tmp/tmp.XXXX (audit).
_manage_temp_dirs=()

manage_mktempdir() {
    local d
    d=$(mktemp -d) || return 1
    _manage_temp_dirs+=("$d")
    echo "$d"
}

_manage_cleanup() {
    local d
    for d in "${_manage_temp_dirs[@]}"; do
        [[ -d "$d" ]] && rm -rf "$d"
    done
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _manage_cleanup EXIT INT TERM

# --- Обработка аргументов ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --apply-mode=*)    _CLI_APPLY_MODE="${1#*=}"; export AWG_APPLY_MODE="$_CLI_APPLY_MODE"; shift ;;
        --*)               echo "Неизвестная опция: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Обновляем пути после возможного переопределения --conf-dir
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Функции логирования
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local safe_msg
    safe_msg="${msg//%/%%}"
    local entry="[$ts] $type: $safe_msg"
    local color_start="" color_end=""

    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$type" in
            INFO)  color_start="\033[0;32m" ;;
            WARN)  color_start="\033[0;33m" ;;
            ERROR) color_start="\033[1;31m" ;;
            DEBUG) color_start="\033[0;36m" ;;
            *)     color_start=""; color_end="" ;;
        esac
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
    fi

    if [[ "$type" == "ERROR" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    else
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "$1"; exit 1; }

# ==============================================================================
# Утилиты
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Экранирование спецсимволов для sed (предотвращает command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -rp "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Действие отменено."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi
    return 0
}

# ==============================================================================
# Проверка зависимостей
# ==============================================================================

check_dependencies() {
    log "Проверка зависимостей..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Не найден: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Не найден: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Не найден: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Не найдены файлы установки. Запустите install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode не найден (QR-коды не будут созданы)."; fi

    # Подключаем общую библиотеку
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Ошибка загрузки $COMMON_SCRIPT_PATH"

    log "Зависимости OK."
}

# ==============================================================================
# Резервное копирование
# ==============================================================================

backup_configs() {
    log "Создание бэкапа..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "Ошибка mkdir $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    ts=$(date +%F_%H-%M-%S)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(manage_mktempdir) || die "Ошибка создания временной директории"

    mkdir -p "$td/server" "$td/clients" "$td/keys"
    cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri "$CONFIG_FILE" "$td/clients/" 2>/dev/null || true
    cp -a "$KEYS_DIR"/* "$td/keys/" 2>/dev/null || true
    cp -a "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$td/" 2>/dev/null || true
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry" 2>/dev/null || true
    fi
    [[ -f /etc/cron.d/awg-expiry ]] && cp -a /etc/cron.d/awg-expiry "$td/" 2>/dev/null || true

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }
    log_debug "tar: архив создан $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"

    # Оставляем максимум 10 бэкапов
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Ошибка удаления старых бэкапов"

    log "Бэкап создан: $bf"
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Путь к бэкапу обязателен в неинтерактивном режиме: restore <файл>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "Бэкапы не найдены в $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "Бэкапы не найдены."; fi

        echo "Доступные бэкапы:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Отмена."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"
    if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi

    log "Создание бэкапа текущей..."
    backup_configs

    local td restore_errors=0
    td=$(manage_mktempdir) || { log_error "Ошибка создания временной директории"; return 1; }
    if ! tar -xzf "$bf" -C "$td"; then
        log_error "Ошибка tar $bf"
        rm -rf "$td"
        return 1
    fi

    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."

    if [[ -d "$td/server" ]]; then
        log "Восстановление конфига сервера..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        cp -a "$td/server/"* "$server_conf_dir/" || { log_error "Ошибка копирования server"; restore_errors=1; }
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Конфиг сервера восстановлен в $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Восстановление файлов клиентов..."
        cp -a "$td/clients/"* "$AWG_DIR/" || { log_error "Ошибка копирования clients"; restore_errors=1; }
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log_debug "Файлы клиентов восстановлены в $AWG_DIR"
    fi

    if [[ -d "$td/keys" ]]; then
        log "Восстановление ключей..."
        mkdir -p "$KEYS_DIR"
        cp -a "$td/keys/"* "$KEYS_DIR/" || { log_error "Ошибка копирования keys"; restore_errors=1; }
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
        log_debug "Ключи восстановлены в $KEYS_DIR"
    fi

    # Серверные ключи: cp -a сохраняет mode из архива, поэтому форсируем 600
    # независимо от того с какими правами они лежали в backup-е (audit fix).
    if [[ -f "$td/server_private.key" ]]; then
        cp -a "$td/server_private.key" "$AWG_DIR/"
        chmod 600 "$AWG_DIR/server_private.key" 2>/dev/null || true
    fi
    if [[ -f "$td/server_public.key" ]]; then
        cp -a "$td/server_public.key" "$AWG_DIR/"
        chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    fi

    if [[ -d "$td/expiry" ]]; then
        log "Восстановление данных expiry..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    rm -rf "$td"

    log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Ошибка запуска сервиса!"
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi
    if [[ "$restore_errors" -ne 0 ]]; then
        log_warn "Восстановление завершено с ошибками. Проверьте конфигурацию."
        return 1
    fi
    log "Восстановление завершено."
}

# ==============================================================================
# Ограничение скорости (Traffic Control)
# ==============================================================================

apply_speed_limits() {
    log_debug "Применение ограничений скорости..."
    # 1. Загрузка ifb
    modprobe ifb numifbs=1 2>/dev/null || log_warn "Не удалось загрузить модуль ifb"
    ip link set dev ifb0 up 2>/dev/null || log_warn "Не удалось поднять ifb0"

    # Очистка старых правил
    tc qdisc del dev awg0 root 2>/dev/null
    tc qdisc del dev awg0 ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null

    # Проверка, есть ли вообще лимиты
    if ! grep -q "#_LimitDown" "$SERVER_CONF_FILE" && ! grep -q "#_LimitUp" "$SERVER_CONF_FILE"; then
        log_debug "Лимиты не найдены."
        return 0
    fi

    # Инициализация корня Download (awg0)
    tc qdisc add dev awg0 root handle 1: htb default 10
    tc class add dev awg0 parent 1: classid 1:10 htb rate 1000mbit

    # Инициализация корня Upload (ifb0)
    tc qdisc add dev awg0 handle ffff: ingress
    tc filter add dev awg0 parent ffff: protocol ip u32 match u32 0 0 action mirred egress redirect dev ifb0 2>/dev/null || \
        log_warn "mirred не поддерживается? Upload limit может не работать."
    tc qdisc add dev ifb0 root handle 1: htb default 10
    tc class add dev ifb0 parent 1: classid 1:10 htb rate 1000mbit

    # Парсинг конфига
    local _cname="" _pk="" _ip="" _l_down="" _l_up=""
    local _class_id=10
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cname="${line#\#_Name = }"
            _cname="${_cname## }"; _cname="${_cname%% }"
            _l_down=""
            _l_up=""
            _ip=""
        elif [[ -n "$_cname" && "$line" == "#_LimitDown = "* ]]; then
            _l_down="${line#\#_LimitDown = }"
            _l_down="${_l_down## }"; _l_down="${_l_down%% }"
        elif [[ -n "$_cname" && "$line" == "#_LimitUp = "* ]]; then
            _l_up="${line#\#_LimitUp = }"
            _l_up="${_l_up## }"; _l_up="${_l_up%% }"
        elif [[ -n "$_cname" && "$line" == "AllowedIPs = "* ]]; then
            _ip="${line#AllowedIPs = }"
            _ip="${_ip%%/*}"; _ip="${_ip## }"; _ip="${_ip%% }"

            # Применение лимитов
            if [[ -n "$_l_down" && "$_l_down" -gt 0 || -n "$_l_up" && "$_l_up" -gt 0 ]]; then
                ((_class_id++))
                if [[ -n "$_l_down" && "$_l_down" -gt 0 ]]; then
                    tc class add dev awg0 parent 1: classid 1:$_class_id htb rate ${_l_down}mbit
                    tc filter add dev awg0 protocol ip parent 1: prio 1 u32 match ip dst "$_ip" flowid 1:$_class_id
                fi
                if [[ -n "$_l_up" && "$_l_up" -gt 0 ]]; then
                    tc class add dev ifb0 parent 1: classid 1:$_class_id htb rate ${_l_up}mbit
                    tc filter add dev ifb0 protocol ip parent 1: prio 1 u32 match ip src "$_ip" flowid 1:$_class_id
                fi
            fi
            
            # Сброс контекста пира
            _cname=""
        fi
    done < "$SERVER_CONF_FILE"

    log_debug "Лимиты скорости применены."
}

clear_speed_limits() {
    log_debug "Очистка правил скорости..."
    tc qdisc del dev awg0 root 2>/dev/null
    tc qdisc del dev awg0 ingress 2>/dev/null
    tc qdisc del dev ifb0 root 2>/dev/null
    return 0
}

limit_client() {
    local name="$1" down="$2" up="$3"

    if [[ -z "$name" || -z "$down" ]]; then
        log_error "Использование: limit <имя> <down_mbit> [up_mbit]"
        return 1
    fi

    if [[ "$down" -eq 0 ]]; then
        up=0
    elif [[ -z "$up" ]]; then
        up="$down"
    fi

    if ! [[ "$down" =~ ^[0-9]+$ ]] || ! [[ "$up" =~ ^[0-9]+$ ]]; then
        log_error "Скорость должна быть целым числом (Мбит/с)."
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        die "Клиент '$name' не найден."
    fi

    local bak
    bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H-%M-%S)"
    cp "$SERVER_CONF_FILE" "$bak" || log_warn "Ошибка бэкапа $bak"

    local td
    td=$(manage_mktempdir) || die "Ошибка создания временной директории"
    local tmpfile="$td/srv_mod.conf"
    
    awk -v target="$name" -v down="$down" -v up="$up" '
    BEGIN { in_target=0 }
    /^\[Peer\]/ {
        in_target=0
        print
        next
    }
    /^#_Name =/ {
        print
        if ($0 == "#_Name = " target) {
            in_target=1
            if (down > 0) print "#_LimitDown = " down
            if (up > 0) print "#_LimitUp = " up
        }
        next
    }
    /^#_LimitDown =/ || /^#_LimitUp =/ {
        if (!in_target) print
        next
    }
    { print }
    ' "$SERVER_CONF_FILE" > "$tmpfile"

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        cp "$bak" "$SERVER_CONF_FILE"
        die "Ошибка обновления файла конфигурации."
    fi

    rm -f "$bak"

    if [[ "$down" -eq 0 && "$up" -eq 0 ]]; then
        log "Лимиты скорости для '$name' сняты."
    else
        log "Установлены лимиты для '$name': Загрузка ${down}Mbit, Отдача ${up}Mbit."
    fi

    apply_speed_limits
}

# ==============================================================================
# Управление Cloudflare WARP
# ==============================================================================

install_wgcf() {
    if [[ -f "$WGCF_PATH" && -s "$WGCF_PATH" ]]; then
        # Проверка, что файл не является текстовой ошибкой 404
        if ! head -n 1 "$WGCF_PATH" | grep -q "Not Found"; then
            log_debug "wgcf уже установлен."
            return 0
        fi
    fi

    log "Установка wgcf..."
    local arch
    arch=$(uname -m)
    local bin_suffix=""
    case "$arch" in
        x86_64|x86-64|amd64) bin_suffix="amd64" ;;
        aarch64|arm64)      bin_suffix="arm64" ;;
        armv7l)             bin_suffix="armv7" ;;
        *) die "Архитектура $arch не поддерживается для wgcf." ;;
    esac

    log "Поиск последней версии wgcf..."
    local url
    url=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep "browser_download_url.*linux_${bin_suffix}" | cut -d '"' -f 4)
    
    if [[ -z "$url" ]]; then
        # Фолбэк на хардкод, если API недоступно
        url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_2.2.22_linux_${bin_suffix}"
    fi

    log "Загрузка wgcf ($arch) с $url..."
    if ! curl -L -o "$WGCF_PATH" "$url"; then
        die "Не удалось загрузить wgcf."
    fi
    chmod +x "$WGCF_PATH"
    log "wgcf установлен в $WGCF_PATH"
}

setup_warp_config() {
    install_wgcf
    
    local td
    td=$(manage_mktempdir) || die "Ошибка временной директории"
    cd "$td" || die "Ошибка перехода в $td"

    log "Регистрация аккаунта Cloudflare WARP..."
    # wgcf register создаёт wgcf-account.toml
    if ! "$WGCF_PATH" --config "$td/wgcf-account.toml" register --accept-tos; then
        die "Ошибка регистрации WARP."
    fi

    log "Генерация конфигурации WireGuard..."
    # wgcf generate создаёт wgcf-profile.conf
    if ! "$WGCF_PATH" --config "$td/wgcf-account.toml" generate; then
        die "Ошибка генерации профиля WARP."
    fi

    local src_conf="$td/wgcf-profile.conf"
    if [[ ! -f "$src_conf" ]]; then die "Профиль WARP не найден после генерации."; fi

    log "Настройка конфигурации..."
    # Модифицируем конфиг для работы в качестве апстрима:
    # 1. Меняем DNS на 1.1.1.1 (опционально)
    # 2. Убираем маршруты по умолчанию (Table = off), мы настроим их сами
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$src_conf"
    if ! grep -q "^Table =" "$src_conf"; then
        sed -i '/^\[Interface\]/a Table = off' "$src_conf"
    fi

    # 3. Удаляем IPv6 если он отключен в системе (защита от ошибок запуска)
    if [[ ! -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        log "Обнаружено, что IPv6 отключен. Удаление IPv6 адреса из конфига WARP..."
        # Удаляем всё, что идет после запятой и содержит двоеточие (IPv6 адрес)
        sed -i '/^Address =/s/,[[:space:]]*[^,]*:[^,]*//g' "$src_conf"
    fi

    mkdir -p "$(dirname "$WARP_CONF")"
    cp "$src_conf" "$WARP_CONF" || die "Ошибка копирования конфига в $WARP_CONF"
    chmod 600 "$WARP_CONF"
    
    cd "$AWG_DIR" || exit 1
    log "Конфигурация WARP создана: $WARP_CONF"
}

apply_warp_routing() {
    log "Настройка маршрутизации через WARP..."
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.0/24}"
    
    # Ожидание появления интерфейса wg-warp (защита от гонки при загрузке)
    local wait_count=0
    while ! ip link show wg-warp &>/dev/null; do
        if [[ $wait_count -ge 10 ]]; then
            log_error "Интерфейс wg-warp не появился спустя 10 секунд."
            return 1
        fi
        log_debug "Ожидание wg-warp... ($wait_count)"
        sleep 1
        ((wait_count++))
    done

    # Создание таблицы и маршрутов
    ip route replace default dev wg-warp table "$WARP_TABLE" 2>/dev/null || \
        ip route add default dev wg-warp table "$WARP_TABLE" 2>/dev/null
    
    # Правило для подсети AmneziaWG
    ip rule del from "$subnet" table "$WARP_TABLE" 2>/dev/null
    ip rule add from "$subnet" table "$WARP_TABLE"
    
    # Очистка кэша маршрутов
    ip route flush cache
    log "Маршрутизация через WARP активна для $subnet"
}

clear_warp_routing() {
    log "Очистка маршрутизации WARP..."
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.0/24}"
    ip rule del from "$subnet" table "$WARP_TABLE" 2>/dev/null
    ip route flush table "$WARP_TABLE" 2>/dev/null
    ip route flush cache
}

manage_warp() {
    local cmd="$1"
    case "$cmd" in
        install)
            setup_warp_config
            ;;
        on)
            if [[ ! -f "$WARP_CONF" ]]; then
                log_warn "WARP не настроен. Запустите 'warp install'."
                return 1
            fi

            # Дополнительная проверка на IPv6 перед запуском (если конфиг остался старый)
            if [[ ! -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
                if grep "^Address =" "$WARP_CONF" | grep -q ":"; then
                    log "Чистка IPv6 из существующего конфига..."
                    sed -i '/^Address =/s/,[[:space:]]*[^,]*:[^,]*//g' "$WARP_CONF"
                fi
            fi

            log "Включение WARP..."
            systemctl enable awg-quick@wg-warp 2>/dev/null
            if systemctl start awg-quick@wg-warp; then
                # Сохраняем состояние ПЕРЕД render_server_config
                sed -i '/^USE_WARP=/d' "$CONFIG_FILE"
                echo "USE_WARP=1" >> "$CONFIG_FILE"
                
                # Обновляем awg0.conf, чтобы PostUp правила были постоянными
                render_server_config
                
                apply_warp_routing
                log "WARP включен."
            else
                log_error "Не удалось запустить интерфейс wg-warp."
                return 1
            fi
            ;;
        off)
            log "Выключение WARP..."
            clear_warp_routing
            systemctl stop awg-quick@wg-warp 2>/dev/null
            systemctl disable awg-quick@wg-warp 2>/dev/null
            
            sed -i '/^USE_WARP=/d' "$CONFIG_FILE"
            echo "USE_WARP=0" >> "$CONFIG_FILE"
            
            # Обновляем awg0.conf, чтобы убрать PostUp правила WARP
            render_server_config
            
            log "WARP выключен."
            ;;
        status)
            if systemctl is-active --quiet awg-quick@wg-warp; then
                log "WARP статус: Активен (Интерфейс подняты)"
                if ip rule show | grep -q "table $WARP_TABLE"; then
                    log "Маршрутизация: Включена"
                else
                    log_warn "Маршрутизация: Отключена или не настроена"
                fi
                # Проверка внешнего IP через WARP
                local wg_ip
                wg_ip=$(curl -4 -s --max-time 5 --interface wg-warp https://api.ipify.org 2>/dev/null)
                log "Внешний IP через WARP: ${wg_ip:-неизвестно}"
            else
                log "WARP статус: Отключен"
            fi
            ;;
        *)
            log_error "Использование: warp <install|on|off|status>"
            return 1
            ;;
    esac
}

# ==============================================================================
# Управление Telegram ботом
# ==============================================================================

manage_bot() {
    local action="$1"
    local bot_script="$AWG_DIR/awg_bot.sh"
    local service_file="/etc/systemd/system/awg-bot.service"

    case "$action" in
        on)
            log "Настройка Telegram-бота..."
            
            # Проверка зависимостей
            if ! command -v jq &>/dev/null; then
                log "Установка jq для работы с JSON..."
                apt-get update && apt-get install -y jq || die "Не удалось установить jq"
            fi

            local token="" owner_id=""
            # Загружаем текущие если есть
            [ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE" 2>/dev/null
            
            echo -e "\n--- Настройка Telegram-бота ---"
            read -p "Введите Токен бота (от @BotFather) [${BOT_TOKEN:-}]: " input_token
            token="${input_token:-$BOT_TOKEN}"
            
            read -p "Введите Ваш Telegram ID (от @userinfobot) [${BOT_OWNER_ID:-}]: " input_id
            owner_id="${input_id:-$BOT_OWNER_ID}"

            if [[ -z "$token" || -z "$owner_id" ]]; then
                log_error "Токен и ID обязательны для работы бота."
                return 1
            fi

            # Сохраняем в конфиг
            sed -i '/^BOT_TOKEN=/d' "$CONFIG_FILE"
            sed -i '/^BOT_OWNER_ID=/d' "$CONFIG_FILE"
            echo "BOT_TOKEN=\"$token\"" >> "$CONFIG_FILE"
            echo "BOT_OWNER_ID=\"$owner_id\"" >> "$CONFIG_FILE"

            log "Генерация скрипта бота..."
            log "Настройка окружения Python (venv)..."
            if [[ ! -d "$AWG_DIR/venv" ]]; then
                python3 -m venv "$AWG_DIR/venv" || die "Не удалось создать venv."
            fi
            
            log "Установка зависимостей (aiogram)..."
            "$AWG_DIR/venv/bin/pip" install --upgrade pip >/dev/null
            "$AWG_DIR/venv/bin/pip" install aiogram==3.4.1 >/dev/null || die "Не удалось установить aiogram."

            log "Генерация скрипта бота (Python)..."
            cat << 'EOF' > "$bot_script"
import asyncio
import logging
import sys
import os
import subprocess
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton, BufferedInputFile
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup

# --- Конфигурация ---
AWG_DIR = "/root/awg"
CONF_PATH = "/etc/amnezia/amneziawg/awg0.conf"
MAN_SCRIPT = os.path.join(AWG_DIR, "manage_amneziawg.sh")
BOT_TOKEN = "{BOT_TOKEN}"
ADMIN_ID = {BOT_OWNER_ID}

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher()
logging.basicConfig(level=logging.INFO, format='[%(asctime)s] Bot: %(message)s')

class Form(StatesGroup):
    wait_client_name = State()

def run_cmd(args):
    try:
        res = subprocess.run(["bash", MAN_SCRIPT, "--no-color"] + args, capture_output=True, text=True)
        return res.stdout.strip()
    except Exception as e:
        return f"Ошибка: {str(e)}"

def get_client_names():
    names = []
    if os.path.exists(CONF_PATH):
        with open(CONF_PATH, "r") as f:
            for line in f:
                if line.startswith("#_Name = "):
                    names.append(line.split("=")[1].strip())
    return names

def get_name_by_idx(idx):
    names = get_client_names()
    try:
        return names[int(idx) - 1]
    except:
        return None

# --- Клавиатуры ---
def get_main_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="👥 Управление клиентами", callback_data="manage_clients")],
        [InlineKeyboardButton(text="🌍 Статус WARP", callback_data="warp_status"), InlineKeyboardButton(text="📊 Статистика", callback_data="stats")],
        [InlineKeyboardButton(text="🖥 Сервер", callback_data="server_info")],
        [InlineKeyboardButton(text="🔄 Обновить меню", callback_data="start")]
    ])

def get_manage_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Добавить", callback_data="add_start"), InlineKeyboardButton(text="🗑 Удалить", callback_data="del_list")],
        [InlineKeyboardButton(text="⚙️ Настройка", callback_data="options_list")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="start")]
    ])

def get_clients_kb(prefix):
    names = get_client_names()
    kb = []
    for i, name in enumerate(names, 1):
        kb.append([InlineKeyboardButton(text=name, callback_data=f"{prefix}{i}")])
    kb.append([InlineKeyboardButton(text="⬅️ Назад", callback_data="manage_clients")])
    return InlineKeyboardMarkup(inline_keyboard=kb)

# --- Обработчики ---
@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    if message.from_user.id != ADMIN_ID: return
    await message.answer("🏷 <b>Управление AmneziaWG</b>\nВыберите действие в меню:", 
                         reply_markup=get_main_menu(), parse_mode="HTML")

@dp.callback_query(F.data == "start")
async def cb_start(callback: types.CallbackQuery):
    await callback.message.edit_text("🏷 <b>Управление AmneziaWG</b>\nВыберите действие в меню:", 
                                     reply_markup=get_main_menu(), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "manage_clients")
async def cb_manage_clients(callback: types.CallbackQuery):
    await callback.message.edit_text("👥 <b>Управление клиентами</b>\nВыберите действие:", 
                                     reply_markup=get_manage_menu(), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "add_start")
async def cb_add_start(callback: types.CallbackQuery, state: FSMContext):
    await state.set_state(Form.wait_client_name)
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="❌ Отмена", callback_data="manage_clients")]])
    await callback.message.edit_text("➕ <b>Добавление клиента</b>\nВведите имя нового клиента:", 
                                     reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.message(Form.wait_client_name)
async def process_name(message: types.Message, state: FSMContext):
    if message.from_user.id != ADMIN_ID: return
    name = message.text.strip()
    await state.clear()
    msg = await message.answer(f"⏳ Создаю клиента <b>{name}</b>...", parse_mode="HTML")
    
    res = run_cmd(["add", name])
    if "успешно" in res.lower() or "created" in res.lower() or os.path.exists(f"{AWG_DIR}/{name}.conf"): # Simple check
        await message.answer(f"✅ Клиент <b>{name}</b> создан!", parse_mode="HTML")
        conf_path = f"{AWG_DIR}/{name}.conf"
        png_path = f"{AWG_DIR}/{name}.png"
        if os.path.exists(conf_path):
            await message.answer_document(types.FSInputFile(conf_path))
        if os.path.exists(png_path):
            await message.answer_photo(types.FSInputFile(png_path))
        await cmd_start(message)
    else:
        await message.answer(f"❌ Ошибка при создании <b>{name}</b>.\n{res}", reply_markup=get_main_menu(), parse_mode="HTML")

@dp.callback_query(F.data == "del_list")
async def cb_del_list(callback: types.CallbackQuery):
    await callback.message.edit_text("🗑 <b>Удаление клиента</b>\nВыберите клиента для удаления:", 
                                     reply_markup=get_clients_kb("del_conf:"), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "options_list")
async def cb_options_list(callback: types.CallbackQuery):
    await callback.message.edit_text("⚙️ <b>Настройка клиента</b>\nВыберите клиента для настройки:", 
                                     reply_markup=get_clients_kb("client:"), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("client:"))
async def cb_client_options(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    if not name:
        await callback.answer("Ошибка: клиент не найден")
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📄 Конфиг", callback_data=f"get:conf:{idx}"), InlineKeyboardButton(text="🖼 QR-код", callback_data=f"get:qr:{idx}")],
        [InlineKeyboardButton(text="⚡️ Лимит скорости", callback_data=f"limit_menu:{idx}")],
        [InlineKeyboardButton(text="🗑 Удалить", callback_data=f"del_conf:{idx}")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="options_list")]
    ])
    await callback.message.edit_text(f"👤 Клиент: <b>{name}</b>", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("get:"))
async def cb_get_file(callback: types.CallbackQuery):
    parts = callback.data.split(":")
    mode = parts[1]
    idx = parts[2]
    name = get_name_by_idx(idx)
    if not name: return
    
    if mode == "conf":
        path = f"{AWG_DIR}/{name}.conf"
        if os.path.exists(path):
            await callback.message.answer_document(types.FSInputFile(path))
    elif mode == "qr":
        path = f"{AWG_DIR}/{name}.png"
        if os.path.exists(path):
            await callback.message.answer_photo(types.FSInputFile(path))
    await callback.answer()

@dp.callback_query(F.data.startswith("limit_menu:"))
async def cb_limit_menu(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="5М", callback_data=f"setlim:{idx}:5"), InlineKeyboardButton(text="10М", callback_data=f"setlim:{idx}:10"), InlineKeyboardButton(text="20М", callback_data=f"setlim:{idx}:20")],
        [InlineKeyboardButton(text="50М", callback_data=f"setlim:{idx}:50"), InlineKeyboardButton(text="Макс (0)", callback_data=f"setlim:{idx}:0")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data=f"client:{idx}")]
    ])
    await callback.message.edit_text(f"⚡️ Установка лимита для <b>{name}</b> (Мбит/с):", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("setlim:"))
async def cb_set_limit(callback: types.CallbackQuery):
    parts = callback.data.split(":")
    idx, val = parts[1], parts[2]
    name = get_name_by_idx(idx)
    run_cmd(["limit", name, val, val])
    await callback.answer(f"Лимит {val} Мбит установлен")
    await cb_client_options(callback)

@dp.callback_query(F.data.startswith("del_conf:"))
async def cb_del_confirm(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ ДА, УДАЛИТЬ", callback_data=f"del_do:{idx}")],
        [InlineKeyboardButton(text="❌ ОТМЕНА", callback_data="manage_clients")]
    ])
    await callback.message.edit_text(f"⚠️ Вы уверены, что хотите удалить <b>{name}</b>?", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("del_do:"))
async def cb_del_do(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    run_cmd(["remove", name, "--apply-mode=syncconf", "-y"])
    await callback.answer(f"Клиент {name} удален")
    await cb_manage_clients(callback)

@dp.callback_query(F.data == "warp_status")
async def cb_warp_status(callback: types.CallbackQuery):
    status = run_cmd(["warp", "status"])
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="▶️ Включить", callback_data="warp_on"), InlineKeyboardButton(text="⏹ Выключить", callback_data="warp_off")],
        [InlineKeyboardButton(text="⬅️ Назад", callback_data="start")]
    ])
    await callback.message.edit_text(f"🌍 <b>Статус WARP:</b>\n<pre>{status}</pre>", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "warp_on")
async def cb_warp_on(callback: types.CallbackQuery):
    run_cmd(["warp", "on"])
    await cb_warp_status(callback)

@dp.callback_query(F.data == "warp_off")
async def cb_warp_off(callback: types.CallbackQuery):
    run_cmd(["warp", "off"])
    await cb_warp_status(callback)

@dp.callback_query(F.data == "stats")
async def cb_stats(callback: types.CallbackQuery):
    # Очистка вывода от логов
    stats = run_cmd(["stats"])
    clean_stats = "\n".join([line for line in stats.split("\n") if not any(x in line for x in ["INFO:", "DEBUG:", "WARN:", "ERROR:"])])
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="⬅️ Назад", callback_data="start")]])
    await callback.message.edit_text(f"📊 <b>Статистика трафика:</b>\n<pre>{clean_stats}</pre>", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "server_info")
async def cb_server_info(callback: types.CallbackQuery):
    info = run_cmd(["server"])
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="⬅️ Назад", callback_data="start")]])
    await callback.message.edit_text(info, reply_markup=kb, parse_mode="HTML")
    await callback.answer()

async def main():
    logging.info("Бот запущен.")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
EOF
            sed -i "s/{BOT_TOKEN}/$BOT_TOKEN/g" "$bot_script"
            sed -i "s/{BOT_OWNER_ID}/$BOT_OWNER_ID/g" "$bot_script"
            chmod +x "$bot_script"

            log "Настройка системного сервиса (Python)..."
            cat << EOF > "$service_file"
[Unit]
Description=AmneziaWG Telegram Bot (Python)
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$AWG_DIR
ExecStart=$AWG_DIR/venv/bin/python3 $bot_script
Restart=always
RestartSec=10
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=awg-bot

[Install]
WantedBy=multi-user.target
EOF
            systemctl daemon-reload
            systemctl enable awg-bot
            systemctl restart awg-bot
            log "Telegram-бот (Python) включен и запущен."
            ;;

        off)
            log "Выключение Telegram-бота..."
            systemctl stop awg-bot 2>/dev/null
            systemctl disable awg-bot 2>/dev/null
            rm -f "$service_file"
            systemctl daemon-reload
            log "Бот выключен."
            ;;

        status)
            if systemctl is-active --quiet awg-bot; then
                log "Бот статус: Активен"
                tail -n 5 /var/log/syslog | grep awg-bot || true
            else
                log "Бот статус: Отключен"
            fi
            ;;
    esac
}

# ==============================================================================
# Изменение параметра клиента
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Использование: modify <имя> <параметр> <значение>"
        return 1
    fi

    # Допустимые для модификации параметры
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Параметр '$param' нельзя изменить через modify."
        log_error "Допустимые параметры: ${allowed_params//|/, }"
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        die "Клиент '$name' не найден."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then die "Файл $cf не найден."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Параметр '$param' не найден в $cf."
        return 1
    fi

    log "Изменение '$param' на '$value' для '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    cp "$cf" "$bak" || log_warn "Ошибка бэкапа $bak"
    log "Бэкап: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "Ошибка sed. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Замена не выполнена для '$param'. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        return 1
    fi
    log_debug "sed: ${param} = ${value} в $cf"

    log "Параметр '$param' изменен."
    rm -f "$bak"

    log "Перегенерация QR-кода и vpn:// URI..."
    generate_qr "$name" || log_warn "Не удалось обновить QR-код."
    generate_vpn_uri "$name" || log_warn "Не удалось обновить vpn:// URI."

    return 0
}

# ==============================================================================
# Проверка состояния сервера
# ==============================================================================

check_server() {
    log "Проверка состояния сервера AmneziaWG 2.0..."
    local ok=1

    log "Статус сервиса:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Интерфейс awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Интерфейс не найден!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Прослушивание порта:"
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Не удалось определить порт."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Порт ${port}/udp НЕ прослушивается!"
            ok=0
        else
            log " - Порт ${port}/udp прослушивается."
        fi
    fi

    log "Настройки ядра:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding выключен ($fwd)!"
        ok=0
    else
        log " - IP Forwarding включен."
    fi

    log "Правила UFW:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - Правило UFW для ${port}/udp не найдено!"
        else
            log " - Правило UFW для ${port}/udp есть."
        fi
    else
        log_warn " - UFW не установлен."
    fi

    log "Статус AmneziaWG 2.0:"
    # Раньше awg show вызывался через process substitution без проверки exit code,
    # из-за чего check мог отрапортовать "Состояние OK" даже когда awg упал.
    # Теперь захватываем вывод и проверяем exit code (audit).
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 завершился с ошибкой:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 параметры обфускации: активны"
        else
            log_warn " - AWG 2.0 параметры обфускации не обнаружены"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Проверка завершена: Состояние OK."
        return 0
    else
        log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"
        return 1
    fi
}

# ==============================================================================
# Список клиентов
# ==============================================================================

list_clients() {
    log "Получение списка клиентов..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "Клиенты не найдены."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Однопроходный парсинг серверного конфига: name → pubkey, limit
    local -A _name_to_pk
    local -A _name_to_limit_down
    local -A _name_to_limit_up
    local _cn=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cn="${line#\#_Name = }"
            _cn="${_cn## }"; _cn="${_cn%% }"
        elif [[ -n "$_cn" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && _name_to_pk["$_cn"]="$_pk"
            _cn=""
        elif [[ -n "$_cn" && "$line" == "#_LimitDown = "* ]]; then
            local _ld="${line#\#_LimitDown = }"
            _ld="${_ld## }"; _ld="${_ld%% }"
            [[ -n "$_ld" ]] && _name_to_limit_down["$_cn"]="$_ld"
        elif [[ -n "$_cn" && "$line" == "#_LimitUp = "* ]]; then
            local _lu="${line#\#_LimitUp = }"
            _lu="${_lu## }"; _lu="${_lu%% }"
            [[ -n "$_lu" ]] && _name_to_limit_up["$_cn"]="$_lu"
        fi
    done < "$SERVER_CONF_FILE"

    # Однопроходный парсинг awg show dump: pubkey → handshake timestamp
    local -A _pk_to_hs
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || awg_dump=""
    if [[ -n "$awg_dump" ]]; then
        # shellcheck disable=SC2034
        while IFS=$'\t' read -r _dpk _dpsk _dep _daips _dhs _drx _dtx _dka; do
            _pk_to_hs["$_dpk"]="$_dhs"
        done < <(echo "$awg_dump" | tail -n +2)
    fi

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"
        printf -- "-%.0s" {1..95}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"
        printf -- "-%.0s" {1..50}
        echo
    fi

    local now
    now=$(date +%s)

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="Нет данных"
        local color_start="" color_end=""
        if [[ "$NO_COLOR" -eq 0 ]]; then
            color_end="\033[0m"
            color_start="\033[0;37m"
        fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"

            local current_pk="${_name_to_pk[$name]:-}"

            if [[ -n "$current_pk" ]]; then
                pk="${current_pk:0:10}..."
                local handshake="${_pk_to_hs[$current_pk]:-0}"
                if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
                    local diff=$((now - handshake))
                    if [[ $diff -lt 180 ]]; then
                        st="Активен"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Недавно"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="Нет handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="Нет handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Ошибка ключа"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info
        local exp_str=""
        local exp_ts
        exp_ts=$(get_client_expiry "$name" 2>/dev/null)
        if [[ -n "$exp_ts" ]]; then
            exp_str=" [$(format_remaining "$exp_ts")]"
        fi

        # Limit info
        local lim_str=""
        if [[ -n "${_name_to_limit_down[$name]:-}" || -n "${_name_to_limit_up[$name]:-}" ]]; then
            lim_str=" [Лимит: ${_name_to_limit_down[$name]:-Max}/${_name_to_limit_up[$name]:-Max} Мбит]"
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}%s%s\n" "$name" "$cf" "$png" "$ip" "$pk" "$st" "$exp_str" "$lim_str"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}%s%s\n" "$name" "$cf" "$png" "$st" "$exp_str" "$lim_str"
        fi
    done <<< "$clients"
    echo ""
    log "Всего клиентов: $tot, Активных/Недавно: $act"
}

# ==============================================================================
# Статистика трафика
# ==============================================================================

# Экранирование строки для безопасного включения в JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Форматирование размера в человекочитаемый формат
format_bytes() {
    local bytes="${1:-0}"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then printf "0 B"; return; fi
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN{printf \"%.2f GiB\", $bytes/1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN{printf \"%.2f MiB\", $bytes/1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN{printf \"%.1f KiB\", $bytes/1024}"
    else
        printf "%d B" "$bytes"
    fi
}

stats_clients() {
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "Клиенты не найдены."
        fi
        return 0
    fi

    # Получаем данные awg show awg0
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Ошибка получения данных awg show."
        return 1
    }

    # Маппинг: публичный ключ → имя клиента (single-pass)
    local -A pk_to_name
    local _current_name=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _current_name="${line#\#_Name = }"
            _current_name="${_current_name## }"; _current_name="${_current_name%% }"
        elif [[ -n "$_current_name" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && pk_to_name["$_pk"]="$_current_name"
            _current_name=""
        fi
    done < "$SERVER_CONF_FILE"

    local json_entries=()
    local table_rows=()
    local total_rx=0 total_tx=0

    # awg show dump: каждая строка пира = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-"
        if [[ -f "$AWG_DIR/${cname}.conf" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${cname}.conf" 2>/dev/null) || ip="?"
        fi

        local hs_str="никогда"
        local status="Неактивен"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local now
            now=$(date +%s)
            local diff=$((now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Активен"
            elif [[ $diff -lt 86400 ]]; then
                status="Недавно"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
        else
            local rx_h tx_h
            rx_h=$(format_bytes "$rx")
            tx_h=$(format_bytes "$tx")
            table_rows+=("$(printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$rx_h" "$tx_h" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Статистика трафика клиентов:"
        echo ""
        printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s\n" "Имя" "IP" "Получено" "Отправлено" "Последний handshake" "Статус"
        printf -- "-%.0s" {1..95}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Итого: Получено $(format_bytes "$total_rx"), Отправлено $(format_bytes "$total_tx")"
    fi
}

server_info() {
    # CPU Load
    local cpu_load
    cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    
    # RAM
    local ram_total ram_used
    ram_total=$(free -m | awk '/Mem:/ {print $2}')
    ram_used=$(free -m | awk '/Mem:/ {print $3}')
    
    # Disk
    local disk_usage disk_free
    disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    disk_free=$(df -h / | awk 'NR==2 {print $4}')
    
    # VPN Stats
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null)
    local active_users=0 total_rx=0 total_tx=0
    local now
    now=$(date +%s)
    
    if [[ -n "$awg_dump" ]]; then
        while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
            [[ -z "$pk" ]] && continue
            total_rx=$((total_rx + rx))
            total_tx=$((total_tx + tx))
            if [[ "$handshake" -gt 0 ]]; then
                local diff=$((now - handshake))
                if [[ $diff -lt 180 ]]; then
                    ((active_users++))
                fi
            fi
        done < <(echo "$awg_dump" | tail -n +2)
    fi
    
    local rx_h tx_h
    rx_h=$(format_bytes "$total_rx")
    tx_h=$(format_bytes "$total_tx")
    
    echo "🖥 <b>Информация о сервере:</b>"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo "📈 <b>Нагрузка CPU:</b> ${cpu_load}%"
    echo "🧠 <b>ОЗУ:</b> ${ram_used}MB / ${ram_total}MB"
    echo "💾 <b>Диск:</b> ${disk_usage} занято (${disk_free} свободно)"
    echo "👥 <b>Активных клиентов:</b> ${active_users}"
    echo "⬇️ <b>Всего получено:</b> ${rx_h}"
    echo "⬆️ <b>Всего отправлено:</b> ${tx_h}"
}

# ==============================================================================
# Справка
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "Скрипт управления AmneziaWG 2.0 (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo ""
    echo "Опции:"
    echo "  -h, --help            Показать эту справку"
    echo "  -v, --verbose         Расширенный вывод (для команды list)"
    echo "  --no-color            Отключить цветной вывод"
    echo "  --json                JSON-вывод (для команды stats)"
    echo "  --expires=ВРЕМЯ       Срок действия при add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"
    echo "  --server-conf=ПУТЬ    Указать файл конфига сервера"
    echo "  --apply-mode=РЕЖИМ    syncconf (умолч.) или restart (обход kernel panic)"
    echo ""
    echo "Команды:"
    echo "  add <имя> [имя2 ...]        Добавить клиента(ов). --expires применяется ко всем"
    echo "  remove <имя> [имя2 ...]     Удалить клиента(ов)"
    echo "  list [-v]             Показать список клиентов"
    echo "  stats [--json]        Статистика трафика по клиентам"
    echo "  regen [имя]           Перегенерировать файлы клиента(ов)"
    echo "  modify <имя> <пар> <зн> Изменить параметр клиента"
    echo "  limit <имя> <down> [up] Установить лимит скорости в Мбит/с (0 - снять)"
    echo "  warp <install|on|off|status> Управление Cloudflare WARP"
    echo "  bot <on|off|status>   Управление Telegram-ботом"
    echo "  backup                Создать бэкап"
    echo "  restore [файл]        Восстановить из бэкапа"
    echo "  check | status        Проверить состояние сервера"
    echo "  show                  Показать статус \`awg show\`"
    echo "  restart               Перезапустить сервис AmneziaWG"
    echo "  help                  Показать эту справку"
    echo ""
    exit 1
}

# ==============================================================================
# Основная логика
# ==============================================================================

if [[ "$COMMAND" == "help" || -z "$COMMAND" ]]; then
    usage
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

log "Запуск команды '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }

            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_cname' уже существует, пропуск."
                continue
            fi

            log "Добавление '$_cname'..."
            if generate_client "$_cname"; then
                log "Клиент '$_cname' добавлен."
                log "Файлы: $AWG_DIR/${_cname}.conf, $AWG_DIR/${_cname}.png"
                if [[ -f "$AWG_DIR/${_cname}.vpnuri" ]]; then
                    log "vpn:// URI: $AWG_DIR/${_cname}.vpnuri"
                fi
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    if set_client_expiry "$_cname" "$EXPIRES_DURATION"; then
                        install_expiry_cron
                    fi
                fi
                ((_added++))
            else
                log_error "Ошибка добавления клиента '$_cname'."
                _cmd_rc=1
            fi
        done

        if [[ $_added -gt 0 ]]; then
            [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                # apply_config сам залогирует и вернёт 0
                apply_config
                log "Добавлено клиентов: $_added. Применение отложено (AWG_SKIP_APPLY=1)."
            elif apply_config; then
                log "Добавлено клиентов: $_added. Конфигурация применена."
            else
                log_error "Добавлено клиентов: $_added, но apply_config упал. Конфиг записан, но НЕ применён к live интерфейсу. Проверьте: systemctl status awg-quick@awg0"
                _cmd_rc=1
            fi
        fi
        ;;

    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Не указано имя клиента."

        # Валидация всех имён перед удалением
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            if ! grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE"; then
                log_warn "Клиент '$_rname' не найден, пропуск."
                continue
            fi
            _valid_names+=("$_rname")
        done

        if [[ ${#_valid_names[@]} -eq 0 ]]; then
            log_error "Нет клиентов для удаления."
            _cmd_rc=1
        else
            # Подтверждение
            if [[ ${#_valid_names[@]} -eq 1 ]]; then
                if ! confirm_action "удалить" "клиента '${_valid_names[0]}'"; then exit 1; fi
            else
                if ! confirm_action "удалить" "${#_valid_names[@]} клиентов"; then exit 1; fi
            fi

            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Удаление '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    rm -f "$AWG_DIR/$_rname.conf" "$AWG_DIR/$_rname.png" "$AWG_DIR/$_rname.vpnuri"
                    rm -f "$KEYS_DIR/${_rname}.private" "$KEYS_DIR/${_rname}.public"
                    remove_client_expiry "$_rname"
                    log "Клиент '$_rname' удалён."
                    ((_removed++))
                else
                    log_error "Ошибка удаления '$_rname'."
                    _cmd_rc=1
                fi
            done

            if [[ $_removed -gt 0 ]]; then
                [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
                    apply_config
                    log "Удалено клиентов: $_removed. Применение отложено (AWG_SKIP_APPLY=1)."
                elif apply_config; then
                    log "Удалено клиентов: $_removed. Конфигурация применена."
                else
                    log_error "Удалено клиентов: $_removed, но apply_config упал. Peer-ы убраны из конфига, но могут оставаться на live интерфейсе. Проверьте: systemctl status awg-quick@awg0"
                    _cmd_rc=1
                fi
            fi
        fi
        ;;

    list)
        list_clients || _cmd_rc=1
        ;;

    stats)
        stats_clients || _cmd_rc=1
        ;;

    regen)
        log "Перегенерация файлов конфигурации и QR..."
        if [[ -n "$CLIENT_NAME" ]]; then
            # Перегенерация одного клиента
            validate_client_name "$CLIENT_NAME" || exit 1
            if ! grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE"; then
                die "Клиент '$CLIENT_NAME' не найден."
            fi
            regenerate_client "$CLIENT_NAME" || { log_error "Ошибка перегенерации '$CLIENT_NAME'."; _cmd_rc=1; }
        else
            # Перегенерация всех клиентов
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "Клиенты не найдены."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Перегенерация '$cname'..."
                    regenerate_client "$cname" || { log_warn "Ошибка перегенерации '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Перегенерация завершена."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME используется как [файл]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "Статус AmneziaWG 2.0..."
        if ! awg show; then log_error "Ошибка awg show."; _cmd_rc=1; fi
        ;;

    restart)
        log "Перезапуск сервиса..."
        if ! confirm_action "перезапустить" "сервис"; then exit 1; fi
        if ! systemctl restart awg-quick@awg0; then
            log_error "Ошибка перезапуска."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Сервис перезапущен."
        fi
        ;;

    limit)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        limit_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    warp)
        manage_warp "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME здесь это подкоманда warp
        ;;

    bot)
        manage_bot "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME здесь это подкоманда bot
        ;;

    apply-limits)
        apply_speed_limits || _cmd_rc=1
        ;;

    clear-limits)
        clear_speed_limits || _cmd_rc=1
        ;;

    apply-warp-routing)
        apply_warp_routing || _cmd_rc=1
        ;;

    clear-warp-routing)
        clear_warp_routing || _cmd_rc=1
        ;;

    server)
        server_info
        ;;

    help)
        usage
        ;;

    *)
        log_error "Неизвестная команда: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Скрипт управления завершил работу."
exit $_cmd_rc
