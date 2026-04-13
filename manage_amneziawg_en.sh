#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.8.0
# Date: 2026-04-07
# Repository: https://github.com/bootkiTdll/amneziawg-installer-fork
# ==============================================================================

# --- Safe mode and Constants ---
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

# --- Auto-cleanup of temporary files and directories ---
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

# --- Argument handling ---
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
        --*)               echo "Unknown option: $1" >&2; COMMAND="help"; break ;;
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

# Update paths after possible --conf-dir override
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Logging functions
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
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
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
# Utilities
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Escape special characters for sed (prevents command injection)
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
    read -rp "Are you sure you want to $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Action cancelled."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Name is empty."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Name exceeds 63 chars."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Name contains invalid characters."; return 1; fi
    return 0
}

# ==============================================================================
# Dependency check
# ==============================================================================

check_dependencies() {
    log "Checking dependencies..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Not found: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Not found: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Not found: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Installation files not found. Run install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' not found."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode not found (QR codes will not be created)."; fi

    # Load common library
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Failed to load $COMMON_SCRIPT_PATH"

    log "Dependencies OK."
}

# ==============================================================================
# Helper functions for Bot
# ==============================================================================

# Search client name by index in SERVER_CONF_FILE
get_name_by_idx() {
    local idx="$1"
    grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sed -n "${idx}p"
}

# ==============================================================================
# Speed Limit Management
# ==============================================================================

limit_client() {
    local name="$1" down="$2" up="$3"
    [[ -z "$up" ]] && up="$down"

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        die "Client '$name' not found."
    fi

    log "Setting speed limits for '$name': Down=${down}Mbit, Up=${up}Mbit..."

    if [[ "$down" -eq 0 ]]; then
        sed -i "/#_Name = ${name}/,/\[Peer\]/ { /#_LimitDown = /d; /#_LimitUp = /d }" "$SERVER_CONF_FILE"
        log "Limits removed for '$name'."
    else
        # Remove old limits if exist
        sed -i "/#_Name = ${name}/,/\[Peer\]/ { /#_LimitDown = /d; /#_LimitUp = /d }" "$SERVER_CONF_FILE"
        # Add new limits
        sed -i "/#_Name = ${name}/a #_LimitDown = ${down}\n#_LimitUp = ${up}" "$SERVER_CONF_FILE"
        log "Limits set for '$name'."
    fi

    # Apply immediately
    apply_speed_limits
    return 0
}

apply_speed_limits() {
    if ! command -v tc &>/dev/null; then
        log_warn "tc tool not found, speed limits cannot be applied."
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    [[ -z "$nic" ]] && return 1

    # Clear existing rules for awg0
    tc qdisc del dev awg0 root 2>/dev/null
    tc qdisc del dev "$nic" root 2>/dev/null

    # Setup qdisc
    tc qdisc add dev awg0 root handle 1: htb default 10
    tc qdisc add dev "$nic" root handle 1: htb default 10

    local _cn="" _ip="" _ld="" _lu=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cn="${line#\#_Name = }"
        elif [[ "$line" == "#_LimitDown = "* ]]; then
            _ld="${line#\#_LimitDown = }"
        elif [[ "$line" == "#_LimitUp = "* ]]; then
            _lu="${line#\#_LimitUp = }"
        elif [[ "$line" == "AllowedIPs = "* ]]; then
            _ip=$(echo "$line" | grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+')
            
            if [[ -n "$_ld" && -n "$_ip" ]]; then
                local class_id
                class_id=$(echo "$_ip" | cut -d'.' -f4)
                
                # Download (awg0 -> user)
                tc class add dev awg0 parent 1: classid 1:"$class_id" htb rate "${_ld}mbit" ceil "${_ld}mbit"
                tc filter add dev awg0 protocol ip parent 1:0 prio 1 u32 match ip dst "$_ip" flowid 1:"$class_id"
                
                # Upload (user -> nic)
                tc class add dev "$nic" parent 1: classid 1:"$class_id" htb rate "${_lu}mbit" ceil "${_lu}mbit"
                tc filter add dev "$nic" protocol ip parent 1:0 prio 1 u32 match ip src "$_ip" flowid 1:"$class_id"
            fi
            _ld="" _lu="" _cn="" _ip=""
        fi
    done < "$SERVER_CONF_FILE"
    
    log_debug "Speed limits applied."
}

clear_speed_limits() {
    local nic
    nic=$(get_main_nic)
    tc qdisc del dev awg0 root 2>/dev/null
    [[ -n "$nic" ]] && tc qdisc del dev "$nic" root 2>/dev/null
    log_debug "Speed limits cleared."
}

# ==============================================================================
# WARP Integration
# ==============================================================================

install_wgcf() {
    if [[ -f "$WGCF_PATH" && -s "$WGCF_PATH" ]]; then
        if ! head -n 1 "$WGCF_PATH" | grep -q "Not Found"; then
            log_debug "wgcf is already installed."
            return 0
        fi
    fi

    log "Installing wgcf..."
    local arch
    arch=$(uname -m)
    local bin_suffix=""
    case "$arch" in
        x86_64|x86-64|amd64) bin_suffix="amd64" ;;
        aarch64|arm64)      bin_suffix="arm64" ;;
        armv7l)             bin_suffix="armv7" ;;
        *) die "Architecture $arch is not supported for wgcf." ;;
    esac

    log "Searching for the latest wgcf version..."
    local url
    url=$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep "browser_download_url.*linux_${bin_suffix}" | cut -d '"' -f 4)
    
    if [[ -z "$url" ]]; then
        url="https://github.com/ViRb3/wgcf/releases/latest/download/wgcf_2.2.22_linux_${bin_suffix}"
    fi

    log "Downloading wgcf ($arch) from $url..."
    if ! curl -L -o "$WGCF_PATH" "$url"; then
        die "Failed to download wgcf."
    fi
    chmod +x "$WGCF_PATH"
    log "wgcf installed to $WGCF_PATH"
}

setup_warp_config() {
    install_wgcf
    
    local td
    td=$(manage_mktempdir) || die "Temporary directory error"
    cd "$td" || die "Failed to enter $td"

    log "Registering Cloudflare WARP account..."
    if ! "$WGCF_PATH" --config "$td/wgcf-account.toml" register --accept-tos; then
        die "WARP registration failed."
    fi

    log "Generating WireGuard configuration..."
    if ! "$WGCF_PATH" --config "$td/wgcf-account.toml" generate; then
        die "WARP profile generation failed."
    fi

    local src_conf="$td/wgcf-profile.conf"
    if [[ ! -f "$src_conf" ]]; then die "WARP profile not found after generation."; fi

    log "Configuring WARP..."
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$src_conf"
    if ! grep -q "^Table =" "$src_conf"; then
        sed -i '/^\[Interface\]/a Table = off' "$src_conf"
    fi

    if [[ ! -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
        log "IPv6 detected as disabled. Removing IPv6 address from WARP config..."
        sed -i '/^Address =/s/,[[:space:]]*[^,]*:[^,]*//g' "$src_conf"
    fi

    mkdir -p "$(dirname "$WARP_CONF")"
    cp "$src_conf" "$WARP_CONF" || die "Error copying config to $WARP_CONF"
    chmod 600 "$WARP_CONF"
    
    cd "$AWG_DIR" || exit 1
    log "WARP configuration created: $WARP_CONF"
}

apply_warp_routing() {
    log "Configuring routing through WARP..."
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.0/24}"
    
    # Wait for wg-warp interface (protect against race condition on boot)
    local wait_count=0
    while ! ip link show wg-warp &>/dev/null; do
        if [[ $wait_count -ge 10 ]]; then
            log_error "Interface wg-warp did not appear after 10 seconds."
            return 1
        fi
        log_debug "Waiting for wg-warp... ($wait_count)"
        sleep 1
        ((wait_count++))
    done

    # Create table and routes
    ip route replace default dev wg-warp table "$WARP_TABLE" 2>/dev/null || \
        ip route add default dev wg-warp table "$WARP_TABLE" 2>/dev/null
    
    # Rule for AmneziaWG subnet
    ip rule del from "$subnet" table "$WARP_TABLE" 2>/dev/null
    ip rule add from "$subnet" table "$WARP_TABLE"
    
    # Flush route cache
    ip route flush cache
    log "Routing through WARP is active for $subnet"
}

clear_warp_routing() {
    log "Clearing WARP routing..."
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
                log_warn "WARP is not configured. Run 'warp install'."
                return 1
            fi

            if [[ ! -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || [[ $(cat /proc/sys/net/ipv6/conf/all/disable_ipv6) -eq 1 ]]; then
                if grep "^Address =" "$WARP_CONF" | grep -q ":"; then
                    log "Cleaning IPv6 from existing config..."
                    sed -i '/^Address =/s/,[[:space:]]*[^,]*:[^,]*//g' "$WARP_CONF"
                fi
            fi

            log "Enabling WARP..."
            systemctl enable awg-quick@wg-warp 2>/dev/null
            if systemctl start awg-quick@wg-warp; then
                # Save state BEFORE render_server_config
                sed -i '/^USE_WARP=/d' "$CONFIG_FILE"
                echo "USE_WARP=1" >> "$CONFIG_FILE"
                
                # Update awg0.conf so PostUp rules are persistent
                render_server_config
                
                apply_warp_routing
                log "WARP enabled."
            else
                log_error "Failed to start wg-warp interface."
                return 1
            fi
            ;;
        off)
            log "Disabling WARP..."
            clear_warp_routing
            systemctl stop awg-quick@wg-warp 2>/dev/null
            systemctl disable awg-quick@wg-warp 2>/dev/null
            
            sed -i '/^USE_WARP=/d' "$CONFIG_FILE"
            echo "USE_WARP=0" >> "$CONFIG_FILE"
            
            # Update awg0.conf to remove WARP PostUp rules
            render_server_config
            
            log "WARP disabled."
            ;;
        status)
            if systemctl is-active --quiet awg-quick@wg-warp; then
                log "WARP status: Active (Interface is up)"
                if ip rule show | grep -q "table $WARP_TABLE"; then
                    log "Routing: Enabled"
                else
                    log_warn "Routing: Disabled or not configured"
                fi
                local wg_ip
                wg_ip=$(curl -4 -s --max-time 5 --interface wg-warp https://api.ipify.org 2>/dev/null)
                log "External IP through WARP: ${wg_ip:-unknown}"
            else
                log "WARP status: Disabled"
            fi
            ;;
        *)
            echo "Usage: warp <install|on|off|status>"
            return 1
            ;;
    esac
}

# ==============================================================================
# Telegram Bot
# ==============================================================================

manage_bot() {
    local subcmd="$1"
    local bot_script="$AWG_DIR/tg_bot.sh"
    local service_file="/etc/systemd/system/awg-bot.service"

    case "$subcmd" in
        on)
            log "Enabling Telegram Bot..."
            # shellcheck source=/dev/null
            safe_load_config "$CONFIG_FILE"
            if [[ -z "$TG_TOKEN" || -z "$TG_ADMIN_ID" ]]; then
                die "TG_TOKEN and TG_ADMIN_ID not found in $CONFIG_FILE. Run setup manually."
            fi

            log "Setting up Python environment (venv)..."
            if [[ ! -d "$AWG_DIR/venv" ]]; then
                python3 -m venv "$AWG_DIR/venv" || die "Failed to create venv."
            fi
            
            log "Installing dependencies (aiogram)..."
            "$AWG_DIR/venv/bin/pip" install --upgrade pip >/dev/null
            "$AWG_DIR/venv/bin/pip" install aiogram==3.4.1 >/dev/null || die "Failed to install aiogram."

            log "Generating bot script (Python)..."
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

# --- Configuration ---
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
        return f"Error: {str(e)}"

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

# --- Keyboards ---
def get_main_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="👥 Clients Management", callback_data="manage_clients")],
        [InlineKeyboardButton(text="🌍 WARP Status", callback_data="warp_status"), InlineKeyboardButton(text="📊 Statistics", callback_data="stats")],
        [InlineKeyboardButton(text="🖥 Server", callback_data="server_info")],
        [InlineKeyboardButton(text="🔄 Refresh Menu", callback_data="start")]
    ])

def get_manage_menu():
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="➕ Add Client", callback_data="add_start"), InlineKeyboardButton(text="🗑 Delete", callback_data="del_list")],
        [InlineKeyboardButton(text="⚙️ Settings", callback_data="options_list")],
        [InlineKeyboardButton(text="⬅️ Back", callback_data="start")]
    ])

def get_clients_kb(prefix):
    names = get_client_names()
    kb = []
    for i, name in enumerate(names, 1):
        kb.append([InlineKeyboardButton(text=name, callback_data=f"{prefix}{i}")])
    kb.append([InlineKeyboardButton(text="⬅️ Back", callback_data="manage_clients")])
    return InlineKeyboardMarkup(inline_keyboard=kb)

# --- Handlers ---
@dp.message(Command("start"))
async def cmd_start(message: types.Message):
    if message.from_user.id != ADMIN_ID: return
    await message.answer("🏷 <b>AmneziaWG Management</b>\nSelect an action from the menu:", 
                         reply_markup=get_main_menu(), parse_mode="HTML")

@dp.callback_query(F.data == "start")
async def cb_start(callback: types.CallbackQuery):
    await callback.message.edit_text("🏷 <b>AmneziaWG Management</b>\nSelect an action from the menu:", 
                                     reply_markup=get_main_menu(), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "manage_clients")
async def cb_manage_clients(callback: types.CallbackQuery):
    await callback.message.edit_text("👥 <b>Clients Management</b>\nSelect an action:", 
                                     reply_markup=get_manage_menu(), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "add_start")
async def cb_add_start(callback: types.CallbackQuery, state: FSMContext):
    await state.set_state(Form.wait_client_name)
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="❌ Cancel", callback_data="manage_clients")]])
    await callback.message.edit_text("➕ <b>Add Client</b>\nEnter the name of the new client:", 
                                     reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.message(Form.wait_client_name)
async def process_name(message: types.Message, state: FSMContext):
    if message.from_user.id != ADMIN_ID: return
    name = message.text.strip()
    await state.clear()
    msg = await message.answer(f"⏳ Creating client <b>{name}</b>...", parse_mode="HTML")
    
    res = run_cmd(["add", name])
    if "success" in res.lower() or "created" in res.lower() or os.path.exists(f"{AWG_DIR}/{name}.conf"): 
        await message.answer(f"✅ Client <b>{name}</b> created!", parse_mode="HTML")
        conf_path = f"{AWG_DIR}/{name}.conf"
        png_path = f"{AWG_DIR}/{name}.png"
        if os.path.exists(conf_path):
            await message.answer_document(types.FSInputFile(conf_path))
        if os.path.exists(png_path):
            await message.answer_photo(types.FSInputFile(png_path))
        await cmd_start(message)
    else:
        await message.answer(f"❌ Error creating <b>{name}</b>.\n{res}", reply_markup=get_main_menu(), parse_mode="HTML")

@dp.callback_query(F.data == "del_list")
async def cb_del_list(callback: types.CallbackQuery):
    await callback.message.edit_text("🗑 <b>Delete Client</b>\nSelect a client to delete:", 
                                     reply_markup=get_clients_kb("del_conf:"), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "options_list")
async def cb_options_list(callback: types.CallbackQuery):
    await callback.message.edit_text("⚙️ <b>Client Settings</b>\nSelect a client to configure:", 
                                     reply_markup=get_clients_kb("client:"), parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("client:"))
async def cb_client_options(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    if not name:
        await callback.answer("Error: client not found")
        return
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📄 Config", callback_data=f"get:conf:{idx}"), InlineKeyboardButton(text="🖼 QR code", callback_data=f"get:qr:{idx}")],
        [InlineKeyboardButton(text="⚡️ Speed Limit", callback_data=f"limit_menu:{idx}")],
        [InlineKeyboardButton(text="🗑 Delete", callback_data=f"del_conf:{idx}")],
        [InlineKeyboardButton(text="⬅️ Back", callback_data="options_list")]
    ])
    await callback.message.edit_text(f"👤 Client: <b>{name}</b>", reply_markup=kb, parse_mode="HTML")
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
        [InlineKeyboardButton(text="5M", callback_data=f"setlim:{idx}:5"), InlineKeyboardButton(text="10M", callback_data=f"setlim:{idx}:10"), InlineKeyboardButton(text="20M", callback_data=f"setlim:{idx}:20")],
        [InlineKeyboardButton(text="50M", callback_data=f"setlim:{idx}:50"), InlineKeyboardButton(text="Max (0)", callback_data=f"setlim:{idx}:0")],
        [InlineKeyboardButton(text="⬅️ Back", callback_data=f"client:{idx}")]
    ])
    await callback.message.edit_text(f"⚡️ Set limit for <b>{name}</b> (Mbit/s):", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("setlim:"))
async def cb_set_limit(callback: types.CallbackQuery):
    parts = callback.data.split(":")
    idx, val = parts[1], parts[2]
    name = get_name_by_idx(idx)
    run_cmd(["limit", name, val, val])
    await callback.answer(f"Limit {val} Mbit set")
    await cb_client_options(callback)

@dp.callback_query(F.data.startswith("del_conf:"))
async def cb_del_confirm(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="✅ YES, DELETE", callback_data=f"del_do:{idx}")],
        [InlineKeyboardButton(text="❌ CANCEL", callback_data="manage_clients")]
    ])
    await callback.message.edit_text(f"⚠️ Are you sure you want to delete <b>{name}</b>?", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data.startswith("del_do:"))
async def cb_del_do(callback: types.CallbackQuery):
    idx = callback.data.split(":")[1]
    name = get_name_by_idx(idx)
    run_cmd(["remove", name, "--apply-mode=syncconf", "-y"])
    await callback.answer(f"Client {name} deleted")
    await cb_manage_clients(callback)

@dp.callback_query(F.data == "warp_status")
async def cb_warp_status(callback: types.CallbackQuery):
    status = run_cmd(["warp", "status"])
    kb = InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="▶️ Enable", callback_data="warp_on"), InlineKeyboardButton(text="⏹ Disable", callback_data="warp_off")],
        [InlineKeyboardButton(text="⬅️ Back", callback_data="start")]
    ])
    await callback.message.edit_text(f"🌍 <b>WARP Status:</b>\n<pre>{status}</pre>", reply_markup=kb, parse_mode="HTML")
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
    stats = run_cmd(["stats"])
    clean_stats = "\n".join([line for line in stats.split("\n") if not any(x in line for x in ["INFO:", "DEBUG:", "WARN:", "ERROR:"])])
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="⬅️ Back", callback_data="start")]])
    await callback.message.edit_text(f"📊 <b>Traffic Statistics:</b>\n<pre>{clean_stats}</pre>", reply_markup=kb, parse_mode="HTML")
    await callback.answer()

@dp.callback_query(F.data == "server_info")
async def cb_server_info(callback: types.CallbackQuery):
    info = run_cmd(["server"])
    kb = InlineKeyboardMarkup(inline_keyboard=[[InlineKeyboardButton(text="⬅️ Back", callback_data="start")]])
    await callback.message.edit_text(info, reply_markup=kb, parse_mode="HTML")
    await callback.answer()

async def main():
    logging.info("Bot started.")
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())
EOF
            sed -i "s/{BOT_TOKEN}/$TG_TOKEN/g" "$bot_script"
            sed -i "s/{BOT_OWNER_ID}/$TG_ADMIN_ID/g" "$bot_script"
            chmod +x "$bot_script"

            log "Configuring systemd service (Python)..."
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
            log "Telegram Bot (Python) enabled and started."
            ;;

        off)
            log "Disabling Telegram Bot..."
            systemctl stop awg-bot 2>/dev/null
            systemctl disable awg-bot 2>/dev/null
            rm -f "$service_file"
            systemctl daemon-reload
            log "Bot disabled."
            ;;

        status)
            if systemctl is-active --quiet awg-bot; then
                log "Bot Status: Active"
                tail -n 5 /var/log/syslog | grep awg-bot || true
            else
                log "Bot Status: Disabled"
            fi
            ;;
    esac
}

# ==============================================================================
# Modify client parameter
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Usage: modify <name> <param> <value>"
        return 1
    fi

    # Allowed parameters
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Parameter '$param' cannot be changed via modify."
        log_error "Allowed parameters: ${allowed_params//|/, }"
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        die "Client '$name' not found."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then die "File $cf not found."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Parameter '$param' not found in $cf."
        return 1
    fi

    log "Changing '$param' to '$value' for '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%H-%M-%S)"
    cp "$cf" "$bak" || log_warn "Backup error $bak"
    log "Backup: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "sed error. Restoring..."
        cp "$bak" "$cf" || log_warn "Restore error."
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Replacement failed for '$param'. Restoring..."
        cp "$bak" "$cf" || log_warn "Restore error."
        return 1
    fi
    log_debug "sed: ${param} = ${value} in $cf"

    log "Parameter '$param' changed."
    rm -f "$bak"

    log "Regenerating QR code and vpn:// URI..."
    generate_qr "$name" || log_warn "Failed to update QR code."
    generate_vpn_uri "$name" || log_warn "Failed to update vpn:// URI."

    return 0
}

# ==============================================================================
# Server status check
# ==============================================================================

check_server() {
    log "Checking AmneziaWG 2.0 status..."
    local ok=1

    log "Service status:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Interface awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Interface not found!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Port listening:"
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Failed to determine port."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Port ${port}/udp is NOT listening!"
            ok=0
        else
            log " - Port ${port}/udp is listening."
        fi
    fi

    log "Kernel settings:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding is disabled ($fwd)!"
        ok=0
    else
        log " - IP Forwarding is enabled."
    fi

    log "UFW rules:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - UFW rule for ${port}/udp not found!"
        else
            log " - UFW rule for ${port}/udp is present."
        fi
    else
        log_warn " - UFW is not installed."
    fi

    log "AmneziaWG 2.0 status:"
    local _awg_out
    if ! _awg_out=$(awg show awg0 2>&1); then
        log_error " - awg show awg0 failed:"
        while IFS= read -r _l; do log_error "  $_l"; done <<< "$_awg_out"
        ok=0
    else
        while IFS= read -r _l; do log "  $_l"; done <<< "$_awg_out"
        if grep -q "jc:" <<< "$_awg_out"; then
            log " - AWG 2.0 obfuscation parameters: active"
        else
            log_warn " - AWG 2.0 obfuscation parameters not detected"
        fi
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Check completed: Status OK."
        return 0
    else
        log_error "Check completed: ISSUES FOUND!"
        return 1
    fi
}

# ==============================================================================
# Client List
# ==============================================================================

list_clients() {
    log "Getting client list..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "No clients found."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

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

    local -A _pk_to_hs
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || awg_dump=""
    if [[ -n "$awg_dump" ]]; then
        while IFS=$'\t' read -r _dpk _dpsk _dep _daips _dhs _drx _dtx _dka; do
            _pk_to_hs["$_dpk"]="$_dhs"
        done < <(echo "$awg_dump" | tail -n +2)
    fi

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Client Name" "Conf" "QR" "IP Address" "Key (start)" "Status"
        printf -- "-%.0s" {1..95}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Client Name" "Conf" "QR" "Status"
        printf -- "-%.0s" {1..50}
        echo
    fi

    local now
    now=$(date +%s)

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="No data"
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
                        st="Active"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Recent"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="No handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="No handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Key error"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        local exp_str=""
        local exp_ts
        exp_ts=$(get_client_expiry "$name" 2>/dev/null)
        if [[ -n "$exp_ts" ]]; then
            exp_str=" [$(format_remaining "$exp_ts")]"
        fi

        local lim_str=""
        if [[ -n "${_name_to_limit_down[$name]:-}" || -n "${_name_to_limit_up[$name]:-}" ]]; then
            lim_str=" [Limit: ${_name_to_limit_down[$name]:-Max}/${_name_to_limit_up[$name]:-Max} Mbit]"
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}%s%s\n" "$name" "$cf" "$png" "$ip" "$pk" "$st" "$exp_str" "$lim_str"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}%s%s\n" "$name" "$cf" "$png" "$st" "$exp_str" "$lim_str"
        fi
    done <<< "$clients"
    echo ""
    log "Total clients: $tot, Active/Recent: $act"
}

# ==============================================================================
# Traffic Statistics
# ==============================================================================

json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

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
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then echo "[]"; else log "No clients found."; fi
        return 0
    fi

    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || { log_error "Failed to get awg data."; return 1; }

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

    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        [[ "$cname" == "unknown" ]] && continue

        local ip="-"
        [[ -f "$AWG_DIR/${cname}.conf" ]] && ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${cname}.conf" 2>/dev/null) || ip="?"

        local hs_str="never"
        local status="Inactive"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local now
            now=$(date +%s)
            local diff=$((now - handshake))
            if [[ $diff -lt 180 ]]; then status="Active"; elif [[ $diff -lt 86400 ]]; then status="Recent"; fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
        else
            table_rows+=("$(printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$(format_bytes "$rx")" "$(format_bytes "$tx")" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Client traffic statistics:"
        echo ""
        printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s\n" "Name" "IP" "Received" "Sent" "Last Handshake" "Status"
        printf -- "-%.0s" {1..95}
        echo
        for row in "${table_rows[@]}"; do echo "$row"; done
        echo ""
        log "Total: Received $(format_bytes "$total_rx"), Sent $(format_bytes "$total_tx")"
    fi
}

server_info() {
    local cpu_load ram_total ram_used disk_usage disk_free active_users=0 total_rx=0 total_tx=0 now
    cpu_load=$(top -bn1 | grep "Cpu(s)" | awk '{print $2 + $4}')
    ram_total=$(free -m | awk '/Mem:/ {print $2}')
    ram_used=$(free -m | awk '/Mem:/ {print $3}')
    disk_usage=$(df -h / | awk 'NR==2 {print $5}')
    disk_free=$(df -h / | awk 'NR==2 {print $4}')
    now=$(date +%s)
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null)
    if [[ -n "$awg_dump" ]]; then
        while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
            [[ -z "$pk" ]] && continue
            total_rx=$((total_rx + rx))
            total_tx=$((total_tx + tx))
            if [[ "$handshake" -gt 0 ]]; then
                [[ $((now - handshake)) -lt 180 ]] && ((active_users++))
            fi
        done < <(echo "$awg_dump" | tail -n +2)
    fi
    echo "🖥 <b>Server Information:</b>"
    echo "━━━━━━━━━━━━━━━━━━━━"
    echo "📈 <b>CPU Load:</b> ${cpu_load}%"
    echo "🧠 <b>RAM:</b> ${ram_used}MB / ${ram_total}MB"
    echo "💾 <b>Disk:</b> ${disk_usage} used (${disk_free} free)"
    echo "👥 <b>Active Clients:</b> ${active_users}"
    echo "⬇️ <b>Total Received:</b> $(format_bytes "$total_rx")"
    echo "⬆️ <b>Total Sent:</b> $(format_bytes "$total_tx")"
}

# ==============================================================================
# Usage and Main
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "AmneziaWG 2.0 management script (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Usage: $0 [OPTIONS] <COMMAND> [ARGUMENTS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo "  -v, --verbose         Verbose output (for list command)"
    echo "  --no-color            Disable colored output"
    echo "  --json                JSON output (for stats command)"
    echo "  --expires=DUR         Expiry duration for add (1h, 7d, 4w, etc.)"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo "  --apply-mode=MODE     syncconf (default) or restart"
    echo ""
    echo "Commands:"
    echo "  add <name> [n2 ...]   Add client(s)"
    echo "  remove <name> [n2 ...] Remove client(s)"
    echo "  list [-v]             List clients"
    echo "  stats [--json]        Traffic statistics"
    echo "  regen [name]          Regenerate client file(s)"
    echo "  modify <n> <p> <v>    Modify client parameter"
    echo "  limit <n> <d> [u]     Set speed limit in Mbit/s (0 to remove)"
    echo "  warp <in|on|off|st>   Cloudflare WARP management"
    echo "  bot <on|off|status>   Telegram Bot management"
    echo "  backup                Create backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  show                  Show \`awg show\`"
    echo "  restart               Restart service"
    echo "  server                Show server statistics"
    echo "  help                  Show this help"
    echo ""
    exit 1
}

if [[ "$COMMAND" == "help" || -z "$COMMAND" ]]; then usage; fi
check_dependencies || exit 1
cd "$AWG_DIR" || die "Failed to change to $AWG_DIR"

log "Running command '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."
        _added=0
        for _cname in "${ARGS[@]}"; do
            validate_client_name "$_cname" || { _cmd_rc=1; continue; }
            if grep -qxF "#_Name = ${_cname}" "$SERVER_CONF_FILE"; then log_warn "Client '$_cname' exists, skipping."; continue; fi
            log "Adding '$_cname'..."
            if generate_client "$_cname"; then
                log "Client '$_cname' added."
                if [[ -n "$EXPIRES_DURATION" ]]; then
                    set_client_expiry "$_cname" "$EXPIRES_DURATION" && install_expiry_cron
                fi
                ((_added++))
            else
                log_error "Error adding '$_cname'."; _cmd_rc=1
            fi
        done
        if [[ $_added -gt 0 ]]; then
            [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
            if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then apply_config; log "Added: $_added. Apply deferred."; elif apply_config; then log "Added: $_added. Applied."; else log_error "Apply failed."; _cmd_rc=1; fi
        fi
        ;;
    remove)
        [[ ${#ARGS[@]} -eq 0 ]] && die "Client name not specified."
        _valid_names=()
        for _rname in "${ARGS[@]}"; do
            validate_client_name "$_rname" || { _cmd_rc=1; continue; }
            grep -qxF "#_Name = ${_rname}" "$SERVER_CONF_FILE" && _valid_names+=("$_rname") || log_warn "Client '$_rname' not found."
        done
        if [[ ${#_valid_names[@]} -eq 0 ]]; then log_error "No clients to remove."; _cmd_rc=1
        else
            if [[ ${#_valid_names[@]} -eq 1 ]]; then confirm_action "remove" "client '${_valid_names[0]}'" || exit 1; else confirm_action "remove" "${#_valid_names[@]} clients" || exit 1; fi
            _removed=0
            for _rname in "${_valid_names[@]}"; do
                log "Removing '$_rname'..."
                if remove_peer_from_server "$_rname"; then
                    rm -f "$AWG_DIR/$_rname.conf" "$AWG_DIR/$_rname.png" "$AWG_DIR/$_rname.vpnuri"
                    rm -f "$KEYS_DIR/${_rname}.private" "$KEYS_DIR/${_rname}.public"
                    remove_client_expiry "$_rname"
                    log "Client '$_rname' removed."
                    ((_removed++))
                else log_error "Error removing '$_rname'."; _cmd_rc=1; fi
            done
            if [[ $_removed -gt 0 ]]; then
                [[ -n "${_CLI_APPLY_MODE:-}" ]] && export AWG_APPLY_MODE="$_CLI_APPLY_MODE"
                if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then apply_config; log "Removed: $_removed. Apply deferred."; elif apply_config; then log "Removed: $_removed. Applied."; else log_error "Apply failed."; _cmd_rc=1; fi
            fi
        fi
        ;;
    list) list_clients || _cmd_rc=1 ;;
    stats) stats_clients || _cmd_rc=1 ;;
    regen)
        if [[ -n "$CLIENT_NAME" ]]; then
            validate_client_name "$CLIENT_NAME" || exit 1
            grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE" || die "Client not found."
            regenerate_client "$CLIENT_NAME" || { log_error "Regen failed."; _cmd_rc=1; }
        else
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            while IFS= read -r cname; do
                [[ -z "$cname" ]] && continue
                log "Regenerating '$cname'..."
                regenerate_client "$cname" || { log_warn "Regen error '$cname'"; _cmd_rc=1; }
            done <<< "$all_clients"
        fi
        ;;
    modify) [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."; validate_client_name "$CLIENT_NAME" || exit 1; modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1 ;;
    backup) backup_configs || _cmd_rc=1 ;;
    restore) restore_backup "$CLIENT_NAME" || _cmd_rc=1 ;;
    check|status) check_server || _cmd_rc=1 ;;
    show) log "AmneziaWG status..."; awg show || { log_error "awg show error."; _cmd_rc=1; } ;;
    restart) log "Restarting service..."; confirm_action "restart" "service" || exit 1; systemctl restart awg-quick@awg0 || { log_error "Restart failed."; _cmd_rc=1; } ;;
    limit) [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."; validate_client_name "$CLIENT_NAME" || exit 1; limit_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1 ;;
    warp) manage_warp "$CLIENT_NAME" || _cmd_rc=1 ;;
    bot) manage_bot "$CLIENT_NAME" || _cmd_rc=1 ;;
    apply-limits) apply_speed_limits || _cmd_rc=1 ;;
    clear-limits) clear_speed_limits || _cmd_rc=1 ;;
    apply-warp-routing) apply_warp_routing || _cmd_rc=1 ;;
    clear-warp-routing) clear_warp_routing || _cmd_rc=1 ;;
    server) server_info ;;
    help) usage ;;
    *) log_error "Unknown command: '$COMMAND'"; _cmd_rc=1; usage ;;
esac

log "Management script finished."
exit $_cmd_rc
