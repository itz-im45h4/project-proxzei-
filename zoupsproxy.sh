#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# CachyOS / Arch Proxy Toggle - FINAL
# ============================================================
#
# DEFAULT PROXIES
# ------------------------------------------------------------
# HTTP and SOCKS5 each have their own default port.
#
DEFAULT_HOST="192.168.43.1"
DEFAULT_HTTP_PORT="44355"
DEFAULT_SOCKS_PORT="1080"
#
# Supplying another host/port NEVER changes these defaults.
#
#
# USAGE
# ------------------------------------------------------------
#
# Use default:
#   ./proxy-toggle-final.sh on
#   -> choose HTTP (192.168.43.1:44355) or SOCKS5 (192.168.43.1:1080)
#
# Temporary runtime override:
#   ./proxy-toggle-final.sh on 192.168.43.1 44366
#
# Also supported:
#   ./proxy-toggle-final.sh 192.168.43.1 44366 on
#
# Disable:
#   ./proxy-toggle-final.sh off
#
# Status:
#   ./proxy-toggle-final.sh status
#
# ============================================================


# ============================================================
# Paths
# ============================================================

STATE_DIR="/var/lib/proxy-toggle-final"
ORIGINALS_DIR="$STATE_DIR/originals"
ENABLED_FILE="$STATE_DIR/enabled"
ACTIVE_PROXY_FILE="$STATE_DIR/active-proxy"

ENV_FILE="/etc/environment"

PROFILE_FILE="/etc/profile.d/proxy.sh"
FISH_PROFILE_FILE="/etc/fish/conf.d/proxy.fish"

SUDOERS_FILE="/etc/sudoers.d/99-proxy-env"

PACMAN_CONF="/etc/pacman.conf"
FLATPAK_CONF="/etc/flatpak/config"
PROXYCHAINS_CONF="/etc/proxychains.conf"

SHELLY_BIN="/usr/bin/shelly"
SHELLY_UI_BIN="/usr/bin/shelly-ui"

SHELLY_WRAPPER="/usr/local/bin/shelly"
SHELLY_UI_WRAPPER="/usr/local/bin/shelly-ui"

SHELLY_DESKTOP="/usr/share/applications/com.shellyorg.shelly.desktop"

USER_APPS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
USER_SHELLY_DESKTOP="$USER_APPS_DIR/com.shellyorg.shelly.desktop"

CODE_SETTINGS_FILE="$HOME/.config/Code - OSS/User/settings.json"

LOG_DIR="$HOME/.local/state/proxy-toggle"
LOG_FILE="$LOG_DIR/proxy-toggle.log"


# ============================================================
# Runtime values
# ============================================================

ACTION=""
HOST="$DEFAULT_HOST"
PORT=""
PROXY_TYPE=""

PROXY_URL=""
ELECTRON_PROXY_URL=""
NO_PROXY_VAL="localhost,127.0.0.1,::1"


# ============================================================
# Logging
# ============================================================

setup_logging() {
    mkdir -p "$LOG_DIR"

    # Keep the log reasonably sized.
    if [[ -f "$LOG_FILE" && "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]]; then
        mv -f "$LOG_FILE" "$LOG_FILE.old" 2>/dev/null || true
    fi
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    local message="[$(timestamp)] [INFO] $*"

    printf '%s\n' "$message"
    printf '%s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

warn() {
    local message="[$(timestamp)] [WARN] $*"

    printf '%s\n' "$message" >&2
    printf '%s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

error() {
    local message="[$(timestamp)] [ERROR] $*"

    printf '%s\n' "$message" >&2
    printf '%s\n' "$message" >> "$LOG_FILE" 2>/dev/null || true
}

die() {
    error "$*"
    exit 1
}


# ============================================================
# Global error trap
# ============================================================

on_error() {
    local exit_code=$?
    local line_no="${1:-unknown}"

    error "FAILED at line $line_no with exit code $exit_code."
    error "The configuration may be partially changed."
    error "Check: $LOG_FILE"

    exit "$exit_code"
}

trap 'on_error $LINENO' ERR


# ============================================================
# Requirements 
# ============================================================

require_not_root() {
    [[ "$EUID" -ne 0 ]] ||
        die "Do not run this script with sudo."
}

require_sudo() {
    sudo -v ||
        die "sudo authentication failed."
}

check_command() {
    command -v "$1" >/dev/null 2>&1 ||
        die "Required command not found: $1"
}


# ============================================================
# Argument parser
# ============================================================

parse_arguments() {

    case "${1:-}" in

        on)
            (( $# <= 3 )) || die "Usage: $0 on [host] [port]"
            ACTION="on"
            HOST="${2:-$DEFAULT_HOST}"
            PORT="${3:-}"
            ;;

        off)
            (( $# == 1 )) || die "Usage: $0 off"
            ACTION="off"
            ;;

        status)
            (( $# == 1 )) || die "Usage: $0 status"
            ACTION="status"
            ;;

        "")
            die "No action specified."

            ;;

        *)
            # Supports:
            # HOST PORT on

            if (( $# == 3 )) && [[ "${3:-}" == "on" ]]; then

                ACTION="on"
                HOST="$1"
                PORT="$2"

            else

                die "Invalid arguments."

            fi

            ;;
    esac
}


select_proxy_type() {

    local choice

    echo
    echo "Select proxy type:"
    echo "  1) HTTP   (${DEFAULT_HOST}:${DEFAULT_HTTP_PORT})"
    echo "  2) SOCKS5 (${DEFAULT_HOST}:${DEFAULT_SOCKS_PORT})"
    read -r -p "Choice [1-2]: " choice

    case "$choice" in
        1) PROXY_TYPE="http" ;;
        2) PROXY_TYPE="socks5" ;;
        *) die "Invalid proxy type. Enter 1 for HTTP or 2 for SOCKS5." ;;
    esac

    if [[ -z "$PORT" ]]; then
        case "$PROXY_TYPE" in
            http) PORT="$DEFAULT_HTTP_PORT" ;;
            socks5) PORT="$DEFAULT_SOCKS_PORT" ;;
        esac
    fi
}


# ============================================================
# Validate proxy
# ============================================================

validate_proxy() {

    [[ "$PROXY_TYPE" == "http" || "$PROXY_TYPE" == "socks5" ]] ||
        die "Invalid proxy type: $PROXY_TYPE"

    if [[ "$HOST" == *:* ]]; then
        [[ "$HOST" =~ ^[0-9A-Fa-f:]+$ ]] ||
            die "Invalid IPv6 proxy host: $HOST"
    else
        [[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] ||
            die "Invalid proxy host: $HOST"
    fi

    [[ "$PORT" =~ ^[0-9]+$ ]] ||
        die "Invalid proxy port: $PORT"

    (( PORT >= 1 && PORT <= 65535 )) ||
        die "Proxy port must be between 1 and 65535."
}


set_proxy_values() {

    local url_host="$HOST"

    # URLs require brackets around literal IPv6 addresses; GNOME, Firefox,
    # and proxychains continue to receive the unbracketed host value.
    if [[ "$HOST" == *:* ]]; then
        url_host="[$HOST]"
    fi

    case "$PROXY_TYPE" in
        http)
            PROXY_URL="http://${url_host}:${PORT}"
            ELECTRON_PROXY_URL="$PROXY_URL"
            ;;
        socks5)
            PROXY_URL="socks5h://${url_host}:${PORT}"
            # Chromium/Electron accepts socks5, but not curl's socks5h alias.
            ELECTRON_PROXY_URL="socks5://${url_host}:${PORT}"
            ;;
    esac
}


# ============================================================
# State
# ============================================================

is_enabled() {
    [[ -f "$ENABLED_FILE" ]]
}

state_path() {
    printf '%s/%s\n' "$ORIGINALS_DIR" "$1"
}

prepare_state() {
    sudo mkdir -p "$ORIGINALS_DIR"
}

clear_state() {
    sudo rm -rf "$STATE_DIR"
}

save_active_proxy() {
    sudo tee "$ACTIVE_PROXY_FILE" >/dev/null <<EOF
type=$PROXY_TYPE
host=$HOST
port=$PORT
url=$PROXY_URL
EOF
}

load_active_proxy() {

    [[ -f "$ACTIVE_PROXY_FILE" ]] || return 1

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            type) PROXY_TYPE="$value" ;;
            host) HOST="$value" ;;
            port) PORT="$value" ;;
            url) PROXY_URL="$value" ;;
        esac
    done < "$ACTIVE_PROXY_FILE"

    [[ "$PROXY_TYPE" == "http" || "$PROXY_TYPE" == "socks5" ]] || return 1
    if [[ "$HOST" == *:* ]]; then
        [[ "$HOST" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    else
        [[ "$HOST" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    fi
    [[ "$PORT" =~ ^[0-9]+$ ]] || return 1
    (( PORT >= 1 && PORT <= 65535 )) || return 1
    set_proxy_values
}


# ============================================================
# Snapshot
#
# IMPORTANT:
# Existing snapshots are NEVER overwritten while enabled.
# This guarantees OFF restores the state from before ON.
# ============================================================

snapshot_file() {

    local source="$1"
    local name="$2"

    local backup
    local missing

    backup="$(state_path "$name")"
    missing="$(state_path "$name.missing")"

    if [[ -e "$backup" ||
          -L "$backup" ||
          -f "$missing" ]]; then
        return 0
    fi

    if [[ -e "$source" ||
          -L "$source" ]]; then

        sudo cp -a "$source" "$backup"

        log "Snapshot: $source"

    else

        sudo touch "$missing"

        log "Snapshot: $source did not exist"

    fi
}


restore_file() {

    local destination="$1"
    local name="$2"

    local backup
    local missing

    backup="$(state_path "$name")"
    missing="$(state_path "$name.missing")"

    if [[ -e "$backup" ||
          -L "$backup" ]]; then

        sudo rm -rf "$destination"
        sudo cp -a "$backup" "$destination"

        log "Restored: $destination"

    elif [[ -f "$missing" ]]; then

        sudo rm -rf "$destination"

        log "Removed: $destination (did not exist before proxy)"

    fi
}


# ============================================================
# CURRENT SHELL ENVIRONMENT
# ============================================================

set_current_proxy_environment() {

    export http_proxy="$PROXY_URL"
    export https_proxy="$PROXY_URL"

    export HTTP_PROXY="$PROXY_URL"
    export HTTPS_PROXY="$PROXY_URL"

    export ftp_proxy="$PROXY_URL"
    export FTP_PROXY="$PROXY_URL"

    export all_proxy="$PROXY_URL"
    export ALL_PROXY="$PROXY_URL"

    export no_proxy="$NO_PROXY_VAL"
    export NO_PROXY="$NO_PROXY_VAL"
}

clear_current_proxy_environment() {

    unset http_proxy
    unset https_proxy

    unset HTTP_PROXY
    unset HTTPS_PROXY

    unset ftp_proxy
    unset FTP_PROXY

    unset all_proxy
    unset ALL_PROXY

    unset no_proxy
    unset NO_PROXY
}


# ============================================================
# /etc/environment
# ============================================================

environment_on() {

    log "Configuring /etc/environment..."

    snapshot_file "$ENV_FILE" "environment"

    sudo sed -i \
        '/^[[:space:]]*# PROXY-FINAL START$/,/^[[:space:]]*# PROXY-FINAL END$/d' \
        "$ENV_FILE"

    sudo sed -i \
        '/^[[:space:]]*http_proxy=/d;
         /^[[:space:]]*https_proxy=/d;
         /^[[:space:]]*HTTP_PROXY=/d;
         /^[[:space:]]*HTTPS_PROXY=/d;
         /^[[:space:]]*ftp_proxy=/d;
         /^[[:space:]]*FTP_PROXY=/d;
         /^[[:space:]]*all_proxy=/d;
         /^[[:space:]]*ALL_PROXY=/d;
         /^[[:space:]]*no_proxy=/d;
         /^[[:space:]]*NO_PROXY=/d' \
        "$ENV_FILE"

    sudo tee -a "$ENV_FILE" >/dev/null <<EOF

# PROXY-FINAL START
http_proxy=$PROXY_URL
https_proxy=$PROXY_URL
HTTP_PROXY=$PROXY_URL
HTTPS_PROXY=$PROXY_URL
ftp_proxy=$PROXY_URL
FTP_PROXY=$PROXY_URL
all_proxy=$PROXY_URL
ALL_PROXY=$PROXY_URL
no_proxy=$NO_PROXY_VAL
NO_PROXY=$NO_PROXY_VAL
# PROXY-FINAL END
EOF

    log "OK: /etc/environment"
}


# ============================================================
# Bash
# ============================================================

profile_on() {

    log "Configuring Bash/login profile..."

    snapshot_file "$PROFILE_FILE" "proxy.sh"

    sudo mkdir -p "$(dirname "$PROFILE_FILE")"

    sudo tee "$PROFILE_FILE" >/dev/null <<EOF
# PROXY-FINAL START

export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"

export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"

export ftp_proxy="$PROXY_URL"
export FTP_PROXY="$PROXY_URL"

export all_proxy="$PROXY_URL"
export ALL_PROXY="$PROXY_URL"

export no_proxy="$NO_PROXY_VAL"
export NO_PROXY="$NO_PROXY_VAL"

# PROXY-FINAL END
EOF

    sudo chmod 0644 "$PROFILE_FILE"

    log "OK: Bash profile"
}


# ============================================================
# Fish
# ============================================================

fish_on() {

    log "Configuring Fish profile..."

    snapshot_file "$FISH_PROFILE_FILE" "proxy.fish"

    sudo mkdir -p "$(dirname "$FISH_PROFILE_FILE")"

    sudo tee "$FISH_PROFILE_FILE" >/dev/null <<EOF
# PROXY-FINAL START

set -gx http_proxy "$PROXY_URL"
set -gx https_proxy "$PROXY_URL"

set -gx HTTP_PROXY "$PROXY_URL"
set -gx HTTPS_PROXY "$PROXY_URL"

set -gx ftp_proxy "$PROXY_URL"
set -gx FTP_PROXY "$PROXY_URL"

set -gx all_proxy "$PROXY_URL"
set -gx ALL_PROXY "$PROXY_URL"

set -gx no_proxy "$NO_PROXY_VAL"
set -gx NO_PROXY "$NO_PROXY_VAL"

# PROXY-FINAL END
EOF

    sudo chmod 0644 "$FISH_PROFILE_FILE"

    log "OK: Fish profile"
}


# ============================================================
# sudo
# ============================================================

sudoers_on() {

    log "Configuring sudo proxy environment..."

    snapshot_file "$SUDOERS_FILE" "sudoers"

    local tmp
    tmp="$(mktemp)"

    printf '%s\n' \
        'Defaults env_keep += "http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY"' \
        > "$tmp"

    if sudo visudo -c -f "$tmp" >/dev/null 2>&1; then

        sudo install -m 0440 "$tmp" "$SUDOERS_FILE"

    else

        rm -f "$tmp"
        die "sudoers validation failed."

    fi

    rm -f "$tmp"

    log "OK: sudo proxy environment"
}


# ============================================================
# systemd / D-Bus
# ============================================================

systemd_on() {

    log "Configuring systemd environment..."

    sudo systemctl set-environment \
        http_proxy="$PROXY_URL" \
        https_proxy="$PROXY_URL" \
        HTTP_PROXY="$PROXY_URL" \
        HTTPS_PROXY="$PROXY_URL" \
        ftp_proxy="$PROXY_URL" \
        FTP_PROXY="$PROXY_URL" \
        all_proxy="$PROXY_URL" \
        ALL_PROXY="$PROXY_URL" \
        no_proxy="$NO_PROXY_VAL" \
        NO_PROXY="$NO_PROXY_VAL"

    systemctl --user set-environment \
        http_proxy="$PROXY_URL" \
        https_proxy="$PROXY_URL" \
        HTTP_PROXY="$PROXY_URL" \
        HTTPS_PROXY="$PROXY_URL" \
        ftp_proxy="$PROXY_URL" \
        FTP_PROXY="$PROXY_URL" \
        all_proxy="$PROXY_URL" \
        ALL_PROXY="$PROXY_URL" \
        no_proxy="$NO_PROXY_VAL" \
        NO_PROXY="$NO_PROXY_VAL" \
        2>/dev/null || true

    if command -v dbus-update-activation-environment >/dev/null 2>&1; then

        dbus-update-activation-environment --systemd \
            http_proxy="$PROXY_URL" \
            https_proxy="$PROXY_URL" \
            HTTP_PROXY="$PROXY_URL" \
            HTTPS_PROXY="$PROXY_URL" \
            ftp_proxy="$PROXY_URL" \
            FTP_PROXY="$PROXY_URL" \
            all_proxy="$PROXY_URL" \
            ALL_PROXY="$PROXY_URL" \
            no_proxy="$NO_PROXY_VAL" \
            NO_PROXY="$NO_PROXY_VAL" \
            2>/dev/null || true

    fi

    log "OK: systemd / D-Bus"
}

systemd_off() {

    log "Clearing runtime systemd/D-Bus proxy environment..."

    sudo systemctl unset-environment \
        http_proxy https_proxy \
        HTTP_PROXY HTTPS_PROXY \
        ftp_proxy FTP_PROXY \
        all_proxy ALL_PROXY \
        no_proxy NO_PROXY \
        2>/dev/null || true

    systemctl --user unset-environment \
        http_proxy https_proxy \
        HTTP_PROXY HTTPS_PROXY \
        ftp_proxy FTP_PROXY \
        all_proxy ALL_PROXY \
        no_proxy NO_PROXY \
        2>/dev/null || true

    # dbus-update-activation-environment has no per-variable unset option.
    # Leaving these values behind means a desktop application started through
    # D-Bus after `off` can still inherit the old proxy.  Replace them with
    # empty values so newly activated applications, including Firefox, cannot
    # receive a stale proxy URL.
    if command -v dbus-update-activation-environment >/dev/null 2>&1; then
        dbus-update-activation-environment --systemd \
            http_proxy= https_proxy= \
            HTTP_PROXY= HTTPS_PROXY= \
            ftp_proxy= FTP_PROXY= \
            all_proxy= ALL_PROXY= \
            no_proxy= NO_PROXY= \
            2>/dev/null || true

        # The preceding command also updates the user systemd manager; remove
        # the empty placeholders there after D-Bus has been sanitised.
        systemctl --user unset-environment \
            http_proxy https_proxy \
            HTTP_PROXY HTTPS_PROXY \
            ftp_proxy FTP_PROXY \
            all_proxy ALL_PROXY \
            no_proxy NO_PROXY \
            2>/dev/null || true
    fi
}


# ============================================================
# GNOME
# ============================================================

gnome_snapshot_setting() {

    local schema="$1"
    local key="$2"
    local name="$3"

    [[ -f "$(state_path "$name")" ]] && return 0

    gsettings get "$schema" "$key" |
        sudo tee "$(state_path "$name")" >/dev/null
}


gnome_snapshot() {

    command -v gsettings >/dev/null 2>&1 ||
        return 0

    gnome_snapshot_setting org.gnome.system.proxy mode gnome-mode
    gnome_snapshot_setting org.gnome.system.proxy.http host gnome-http-host
    gnome_snapshot_setting org.gnome.system.proxy.http port gnome-http-port
    gnome_snapshot_setting org.gnome.system.proxy.https host gnome-https-host
    gnome_snapshot_setting org.gnome.system.proxy.https port gnome-https-port
    gnome_snapshot_setting org.gnome.system.proxy.socks host gnome-socks-host
    gnome_snapshot_setting org.gnome.system.proxy.socks port gnome-socks-port
    gnome_snapshot_setting org.gnome.system.proxy use-same-proxy gnome-use-same-proxy
    gnome_snapshot_setting org.gnome.system.proxy ignore-hosts gnome-ignore-hosts
}


gnome_on() {

    log "Configuring GNOME proxy..."

    command -v gsettings >/dev/null 2>&1 ||
        die "gsettings is not available."

    gnome_snapshot

    gsettings set org.gnome.system.proxy mode manual

    if [[ "$PROXY_TYPE" == "socks5" ]]; then

        # Clear HTTP/HTTPS endpoints so GNOME applications select the SOCKS
        # endpoint instead of attempting HTTP CONNECT against a SOCKS server.
        gsettings set org.gnome.system.proxy use-same-proxy false
        gsettings set org.gnome.system.proxy.http host ''
        gsettings set org.gnome.system.proxy.http port 0
        gsettings set org.gnome.system.proxy.https host ''
        gsettings set org.gnome.system.proxy.https port 0

        gsettings set org.gnome.system.proxy.socks host "$HOST"
        gsettings set org.gnome.system.proxy.socks port "$PORT"

    else

        gsettings set org.gnome.system.proxy.http host "$HOST"
        gsettings set org.gnome.system.proxy.http port "$PORT"

        gsettings set org.gnome.system.proxy.https host "$HOST"
        gsettings set org.gnome.system.proxy.https port "$PORT"

        gsettings set org.gnome.system.proxy.socks host ''
        gsettings set org.gnome.system.proxy.socks port 0
    fi

    gsettings set org.gnome.system.proxy ignore-hosts \
        "['localhost','127.0.0.1','::1']"

    log "OK: GNOME proxy = $PROXY_URL"
}


gnome_restore() {

    command -v gsettings >/dev/null 2>&1 ||
        return 0

    log "Restoring GNOME proxy settings..."

    local value

    if [[ -f "$(state_path gnome-mode)" ]]; then
        value="$(cat "$(state_path gnome-mode)")"
        gsettings set org.gnome.system.proxy mode "$value"
    fi

    if [[ -f "$(state_path gnome-http-host)" ]]; then
        value="$(cat "$(state_path gnome-http-host)")"
        gsettings set org.gnome.system.proxy.http host "$value"
    fi

    if [[ -f "$(state_path gnome-http-port)" ]]; then
        value="$(cat "$(state_path gnome-http-port)")"
        gsettings set org.gnome.system.proxy.http port "$value"
    fi

    if [[ -f "$(state_path gnome-https-host)" ]]; then
        value="$(cat "$(state_path gnome-https-host)")"
        gsettings set org.gnome.system.proxy.https host "$value"
    fi

    if [[ -f "$(state_path gnome-https-port)" ]]; then
        value="$(cat "$(state_path gnome-https-port)")"
        gsettings set org.gnome.system.proxy.https port "$value"
    fi

    if [[ -f "$(state_path gnome-socks-host)" ]]; then
        value="$(cat "$(state_path gnome-socks-host)")"
        gsettings set org.gnome.system.proxy.socks host "$value"
    fi

    if [[ -f "$(state_path gnome-socks-port)" ]]; then
        value="$(cat "$(state_path gnome-socks-port)")"
        gsettings set org.gnome.system.proxy.socks port "$value"
    fi

    if [[ -f "$(state_path gnome-use-same-proxy)" ]]; then
        value="$(cat "$(state_path gnome-use-same-proxy)")"
        gsettings set org.gnome.system.proxy use-same-proxy "$value"
    fi

    if [[ -f "$(state_path gnome-ignore-hosts)" ]]; then
        value="$(cat "$(state_path gnome-ignore-hosts)")"
        gsettings set org.gnome.system.proxy ignore-hosts "$value"
    fi

    log "OK: GNOME restored"
}


# ============================================================
# FIREFOX
#
# FINAL POLICY:
#
# ON:
#   Firefox receives explicit HTTP or SOCKS5 settings. Firefox's system
#   proxy mode is not reliably applying the GNOME SOCKS endpoint here.
#
# OFF:
#   network.proxy.type = 0
#   Firefox uses NO proxy.
#
# This deliberately prevents an old Firefox manual-proxy
# setting from surviving the proxy OFF operation.
# ============================================================

firefox_profile_dirs() {

    local base

    local bases=(
        "$HOME/.mozilla/firefox"
        # Some Arch Firefox packages store the profile under XDG config rather
        # than the legacy ~/.mozilla location.
        "$HOME/.config/mozilla/firefox"
        "$HOME/.var/app/org.mozilla.firefox/.mozilla/firefox"
        "$HOME/snap/firefox/common/.mozilla/firefox"
    )

    for base in "${bases[@]}"; do

        [[ -d "$base" ]] || continue

        find "$base" \
            -mindepth 1 \
            -maxdepth 2 \
            -type f \
            -name "prefs.js" \
            -printf '%h\n' \
            2>/dev/null

    done | sort -u
}


firefox_proxy_preferences() {

    case "$PROXY_TYPE" in
        http)
            cat <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.share_proxy_settings", false);
user_pref("network.proxy.http", "$HOST");
user_pref("network.proxy.http_port", $PORT);
user_pref("network.proxy.ssl", "$HOST");
user_pref("network.proxy.ssl_port", $PORT);
user_pref("network.proxy.socks", "");
user_pref("network.proxy.socks_port", 0);
user_pref("network.proxy.socks_remote_dns", false);
user_pref("network.proxy.no_proxies_on", "$NO_PROXY_VAL");
EOF
            ;;
        socks5)
            cat <<EOF
user_pref("network.proxy.type", 1);
user_pref("network.proxy.share_proxy_settings", false);
user_pref("network.proxy.http", "");
user_pref("network.proxy.http_port", 0);
user_pref("network.proxy.ssl", "");
user_pref("network.proxy.ssl_port", 0);
user_pref("network.proxy.socks", "$HOST");
user_pref("network.proxy.socks_port", $PORT);
user_pref("network.proxy.socks_version", 5);
user_pref("network.proxy.socks_remote_dns", true);
user_pref("network.proxy.no_proxies_on", "$NO_PROXY_VAL");
EOF
            ;;
    esac
}


firefox_userjs_write() {

    local profile
    local userjs

    local found=0

    log "Configuring Firefox proxy mode..."

    while IFS= read -r profile; do

        [[ -n "$profile" ]] || continue

        found=1

        userjs="$profile/user.js"

        # Back up the original user.js once.
        if [[ ! -f "$(state_path "firefox-$(printf '%s' "$profile" | sha256sum | cut -c1-16).user.js")" &&
              ! -f "$(state_path "firefox-$(printf '%s' "$profile" | sha256sum | cut -c1-16).user.js.missing")" ]]; then

            local id
            id="$(printf '%s' "$profile" | sha256sum | cut -c1-16)"

            if [[ -f "$userjs" ]]; then
                sudo cp -a "$userjs" \
                    "$(state_path "firefox-$id.user.js")"
            else
                sudo touch \
                    "$(state_path "firefox-$id.user.js.missing")"
            fi

            sudo tee "$(state_path "firefox-$id.path")" >/dev/null <<< "$profile"
        fi

        # Remove only our managed block.
        if [[ -f "$userjs" ]]; then

            sed -i \
                '/^[[:space:]]*\/\/ PROXY-FINAL FIREFOX START$/,/^[[:space:]]*\/\/ PROXY-FINAL FIREFOX END$/d' \
                "$userjs"

        else

            touch "$userjs"

        fi

        cat >> "$userjs" <<'EOF'

// PROXY-FINAL FIREFOX START
EOF
        firefox_proxy_preferences >> "$userjs"
        cat >> "$userjs" <<'EOF'
// PROXY-FINAL FIREFOX END
EOF

    done < <(firefox_profile_dirs)

    if (( found == 0 )); then
        warn "No existing Firefox profiles with prefs.js were detected."
        warn "Firefox may not have been started yet."
    else
        log "OK: Firefox proxy = $PROXY_URL"
    fi
}


firefox_on() {
    firefox_userjs_write
}


firefox_configuration_matches_active() {

    local profile
    local userjs

    while IFS= read -r profile; do
        [[ -n "$profile" ]] || continue
        userjs="$profile/user.js"

        [[ -f "$userjs" ]] || continue
        grep -Fq '// PROXY-FINAL FIREFOX START' "$userjs" || continue

        case "$PROXY_TYPE" in
            http)
                grep -Fq "user_pref(\"network.proxy.http\", \"$HOST\");" "$userjs" &&
                    grep -Fq "user_pref(\"network.proxy.http_port\", $PORT);" "$userjs" &&
                    grep -Fq "user_pref(\"network.proxy.ssl\", \"$HOST\");" "$userjs" &&
                    return 0
                ;;
            socks5)
                grep -Fq "user_pref(\"network.proxy.socks\", \"$HOST\");" "$userjs" &&
                    grep -Fq "user_pref(\"network.proxy.socks_port\", $PORT);" "$userjs" &&
                    grep -Fq 'user_pref("network.proxy.socks_version", 5);' "$userjs" &&
                    grep -Fq 'user_pref("network.proxy.socks_remote_dns", true);' "$userjs" &&
                    return 0
                ;;
        esac
    done < <(firefox_profile_dirs)

    return 1
}


firefox_off() {

    local profile
    local userjs

    local found=0

    log "Disabling Firefox proxy..."

    while IFS= read -r profile; do

        [[ -n "$profile" ]] || continue

        found=1

        userjs="$profile/user.js"

        if [[ -f "$userjs" ]]; then

            sed -i \
                '/^[[:space:]]*\/\/ PROXY-FINAL FIREFOX START$/,/^[[:space:]]*\/\/ PROXY-FINAL FIREFOX END$/d' \
                "$userjs"

        else

            # A profile can exist without user.js (for example, if it was
            # created while the proxy was enabled).  Create it so OFF always
            # installs the direct-connection preference.
            touch "$userjs"

        fi

        cat >> "$userjs" <<'EOF'

// PROXY-FINAL FIREFOX START
user_pref("network.proxy.type", 0);
user_pref("network.proxy.autoconfig_url", "");
// PROXY-FINAL FIREFOX END
EOF

    done < <(firefox_profile_dirs)

    if (( found == 0 )); then
        warn "No Firefox profiles found while disabling Firefox proxy."
    else
        log "OK: Firefox forced to NO PROXY"
    fi

    if pgrep -u "$UID" -x firefox >/dev/null 2>&1; then
        warn "Firefox is still running. Its current session may retain the old proxy until Firefox is fully closed and reopened."
    fi
}


# ============================================================
# PACMAN
#
# Arch supports XferCommand inside [options] for proxy
# downloads through a tool such as curl.
# ============================================================

pacman_on() {

    log "Configuring pacman/makepkg..."

    snapshot_file "$PACMAN_CONF" "pacman.conf"

    sudo sed -i \
        '/^[[:space:]]*# PROXY-FINAL PACMAN START$/,/^[[:space:]]*# PROXY-FINAL PACMAN END$/d' \
        "$PACMAN_CONF"

    # Clean entries left by older revisions of this script before inserting
    # the one active transfer command. Multiple XferCommand entries can make
    # pacman use a stale HTTP endpoint after switching to SOCKS5.
    sudo sed -i \
        '/^[[:space:]]*# PROXY-TOGGLE PACMAN START$/,/^[[:space:]]*# PROXY-TOGGLE PACMAN END$/d;
         /^[[:space:]]*XferCommand[[:space:]]*=.*\/usr\/bin\/curl.*\(--proxy\|-x\)[[:space:]]/d' \
        "$PACMAN_CONF"

    local tmp
    tmp="$(mktemp)"

    awk -v proxy="$PROXY_URL" '
        BEGIN {
            inserted=0
        }

        /^\[options\][[:space:]]*$/ {

            print
            print ""
            print "# PROXY-FINAL PACMAN START"
            print "XferCommand = /usr/bin/curl --proxy \"" proxy "\" --location --continue-at - --fail --output %o %u"
            print "# PROXY-FINAL PACMAN END"

            inserted=1
            next
        }

        {
            print
        }

        END {
            if (!inserted)
                exit 42
        }
    ' "$PACMAN_CONF" > "$tmp"

    if [[ "$?" -ne 0 ]]; then

        rm -f "$tmp"

        die "Could not find [options] in $PACMAN_CONF."

    fi

    sudo install -m 0644 \
        "$tmp" \
        "$PACMAN_CONF"

    rm -f "$tmp"

    log "OK: pacman XferCommand = $PROXY_URL"
}


# ============================================================
# FLATPAK
# ============================================================

flatpak_on() {

    command -v flatpak >/dev/null 2>&1 || {
        warn "Flatpak not installed; skipping Flatpak configuration."
        return 0
    }

    log "Configuring Flatpak..."

    sudo mkdir -p /etc/flatpak

    snapshot_file "$FLATPAK_CONF" "flatpak-config"

    [[ -f "$FLATPAK_CONF" ]] ||
        sudo touch "$FLATPAK_CONF"

    sudo sed -i \
        '/^[[:space:]]*# PROXY-FINAL FLATPAK START$/,/^[[:space:]]*# PROXY-FINAL FLATPAK END$/d' \
        "$FLATPAK_CONF"

    local tmp
    tmp="$(mktemp)"

    awk -v proxy="$PROXY_URL" '
        BEGIN {
            in_system=0
            inserted=0
        }

        /^\[system\][[:space:]]*$/ {

            print

            print "# PROXY-FINAL FLATPAK START"
            print "http-proxy=" proxy
            print "https-proxy=" proxy
            print "# PROXY-FINAL FLATPAK END"

            in_system=1
            inserted=1

            next
        }

        /^\[[^]]+\][[:space:]]*$/ {

            in_system=0
            print

            next
        }

        {

            if (in_system &&
                ($0 ~ /^[[:space:]]*http-proxy=/ ||
                 $0 ~ /^[[:space:]]*https-proxy=/)) {

                next
            }

            print
        }

        END {

            if (!inserted) {

                print ""
                print "[system]"
                print "# PROXY-FINAL FLATPAK START"
                print "http-proxy=" proxy
                print "https-proxy=" proxy
                print "# PROXY-FINAL FLATPAK END"

            }
        }
    ' "$FLATPAK_CONF" > "$tmp"

    sudo install -m 0644 \
        "$tmp" \
        "$FLATPAK_CONF"

    rm -f "$tmp"

    sudo systemctl restart flatpak-system-helper.service \
        2>/dev/null || true

    log "OK: Flatpak proxy = $PROXY_URL"
}


# ============================================================
# PROXYCHAINS
# ============================================================

proxychains_on() {

    check_command proxychains4

    [[ -f "$PROXYCHAINS_CONF" ]] ||
        die "$PROXYCHAINS_CONF does not exist."

    log "Configuring proxychains..."

    snapshot_file "$PROXYCHAINS_CONF" "proxychains.conf"

    # Re-enabling with another type must replace our previous proxy entry,
    # not append a second hop to the ProxyList.
    sudo sed -i \
        '/^[[:space:]]*# PROXY-FINAL SHELLY START$/,/^[[:space:]]*# PROXY-FINAL SHELLY END$/d' \
        "$PROXYCHAINS_CONF"

    local tmp
    tmp="$(mktemp)"

    awk -v type="$PROXY_TYPE" -v host="$HOST" -v port="$PORT" '
        BEGIN {
            inserted=0
            in_proxy_list=0
        }

        /^\[ProxyList\][[:space:]]*$/ {

            print

            print ""
            print "# PROXY-FINAL SHELLY START"
            print type " " host " " port
            print "# PROXY-FINAL SHELLY END"

            inserted=1
            in_proxy_list=1
            next
        }

        /^\[[^]]+\][[:space:]]*$/ {
            in_proxy_list=0
            print
            next
        }

        # While enabled, proxychains must use only the proxy selected by this
        # script.  Original active entries are safely restored from the
        # snapshot when the user runs `off`.
        in_proxy_list && $0 !~ /^[[:space:]]*(#|$)/ {
            next
        }

        {
            print
        }

        END {

            if (!inserted) {

                print ""
                print "[ProxyList]"
                print "# PROXY-FINAL SHELLY START"
                print type " " host " " port
                print "# PROXY-FINAL SHELLY END"

            }
        }
    ' "$PROXYCHAINS_CONF" > "$tmp"

    sudo install -m 0644 \
        "$tmp" \
        "$PROXYCHAINS_CONF"

    rm -f "$tmp"

    log "OK: proxychains = $PROXY_URL"
}


# ============================================================
# SHELLY
# ============================================================

shelly_wrappers_on() {

    check_command proxychains4

    [[ -x "$SHELLY_BIN" ]] ||
        die "$SHELLY_BIN not found."

    [[ -x "$SHELLY_UI_BIN" ]] ||
        die "$SHELLY_UI_BIN not found."

    log "Configuring Shelly wrappers..."

    snapshot_file "$SHELLY_WRAPPER" "shelly-wrapper"
    snapshot_file "$SHELLY_UI_WRAPPER" "shelly-ui-wrapper"

    sudo mkdir -p /usr/local/bin

    sudo tee "$SHELLY_WRAPPER" >/dev/null <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/proxychains4 -q /usr/bin/shelly "$@"
EOF

    sudo chmod 0755 "$SHELLY_WRAPPER"

    sudo tee "$SHELLY_UI_WRAPPER" >/dev/null <<'EOF'
#!/usr/bin/env bash
exec /usr/bin/proxychains4 -q /usr/bin/shelly-ui "$@"
EOF

    sudo chmod 0755 "$SHELLY_UI_WRAPPER"

    log "OK: Shelly CLI wrapper"
    log "OK: Shelly UI wrapper"
}


shelly_desktop_on() {

    [[ -f "$SHELLY_DESKTOP" ]] || {
        warn "Shelly desktop file not found."
        return 0
    }

    log "Configuring GNOME Shelly launcher..."

    snapshot_file \
        "$USER_SHELLY_DESKTOP" \
        "user-shelly.desktop"

    mkdir -p "$USER_APPS_DIR"

    cp "$SHELLY_DESKTOP" \
        "$USER_SHELLY_DESKTOP"

    sed -i \
        's#Exec=/usr/bin/shelly-ui#Exec=/usr/local/bin/shelly-ui#g' \
        "$USER_SHELLY_DESKTOP"

    update-desktop-database \
        "$USER_APPS_DIR" \
        >/dev/null 2>&1 || true

    log "OK: GNOME Shelly launcher"
}


shelly_desktop_restore() {

    local backup
    local missing

    backup="$(state_path user-shelly.desktop)"
    missing="$(state_path user-shelly.desktop.missing)"

    if [[ -e "$backup" ]]; then

        mkdir -p "$USER_APPS_DIR"

        rm -f "$USER_SHELLY_DESKTOP"

        cp "$backup" "$USER_SHELLY_DESKTOP"

    elif [[ -f "$missing" ]]; then

        rm -f "$USER_SHELLY_DESKTOP"

    fi

    update-desktop-database \
        "$USER_APPS_DIR" \
        >/dev/null 2>&1 || true
}


# ============================================================
# VISUAL STUDIO CODE SETTINGS
# ============================================================

vscode_on() {

    log "Configuring VS Code settings..."

    snapshot_file "$CODE_SETTINGS_FILE" "vscode-settings.json"
    mkdir -p "$(dirname "$CODE_SETTINGS_FILE")"

    [[ -f "$CODE_SETTINGS_FILE" ]] || printf '{}\n' > "$CODE_SETTINGS_FILE"

    local tmp
    tmp="$(mktemp)"

    if ! jq \
        --arg proxy "$ELECTRON_PROXY_URL" \
        '. + {"http.proxy": $proxy, "http.proxySupport": "override"}' \
        "$CODE_SETTINGS_FILE" > "$tmp"; then
        rm -f "$tmp"
        die "VS Code settings are not valid JSON: $CODE_SETTINGS_FILE"
    fi

    cp "$tmp" "$CODE_SETTINGS_FILE"
    rm -f "$tmp"

    log "OK: VS Code http.proxy = $ELECTRON_PROXY_URL"
}


vscode_restore() {
    restore_file "$CODE_SETTINGS_FILE" "vscode-settings.json"
}


vscode_configuration_matches_active() {
    [[ -f "$CODE_SETTINGS_FILE" ]] &&
        jq -e \
            --arg proxy "$ELECTRON_PROXY_URL" \
            '."http.proxy" == $proxy and ."http.proxySupport" == "override"' \
            "$CODE_SETTINGS_FILE" >/dev/null 2>&1
}


vscode_restart_warning() {
    if pgrep -u "$UID" -f '(^|/)(code|code-oss)( |$)' >/dev/null 2>&1; then
        warn "VS Code is still running. Fully close and reopen it so Codex and other extensions read the new settings."
    fi
}


# ============================================================
# CONNECTION TEST
# ============================================================

test_proxy() {

    check_command curl

    curl \
        --proxy "$PROXY_URL" \
        --connect-timeout 8 \
        --max-time 15 \
        -fsSI \
        https://aur.archlinux.org \
        >/dev/null
}


# ============================================================
# STATUS
# ============================================================

status() {

    echo
    echo "=============================================="
    echo "          PROXY TOGGLE FINAL STATUS"
    echo "=============================================="
    echo

    if is_enabled; then

        echo "Persistent state:   ENABLED"

    else

        echo "Persistent state:   DISABLED"

    fi

    echo "HTTP default:       http://${DEFAULT_HOST}:${DEFAULT_HTTP_PORT}"
    echo "SOCKS5 default:     socks5h://${DEFAULT_HOST}:${DEFAULT_SOCKS_PORT}"

    local active_proxy_loaded=0

    if is_enabled; then
        if load_active_proxy; then
            active_proxy_loaded=1
            echo "Active type:        $PROXY_TYPE"
            echo "Active proxy:       $PROXY_URL"
        else
            echo "Active proxy:       metadata unavailable"
        fi
    fi

    echo

    printf "Current shell vars: "

    if [[ -n "${http_proxy:-}" ]]; then
        echo "present"
    else
        echo "not present"
    fi

    printf "GNOME:              "

    if command -v gsettings >/dev/null 2>&1 &&
       [[ "$(gsettings get org.gnome.system.proxy mode 2>/dev/null)" == "'manual'" ]]; then

        echo "manual"

    else

        echo "not manual"

    fi

    printf "Pacman:             "

    if grep -q \
        'PROXY-FINAL PACMAN START' \
        "$PACMAN_CONF" 2>/dev/null; then

        echo "configured"

    else

        echo "not configured"

    fi

    printf "Flatpak:            "

    if grep -q \
        'PROXY-FINAL FLATPAK START' \
        "$FLATPAK_CONF" 2>/dev/null; then

        echo "configured"

    else

        echo "not configured"

    fi

    printf "Proxychains:        "

    if grep -q \
        'PROXY-FINAL SHELLY START' \
        "$PROXYCHAINS_CONF" 2>/dev/null; then

        echo "configured"

    else

        echo "not configured"

    fi

    printf "Shelly CLI:         "

    if [[ -x "$SHELLY_WRAPPER" ]]; then
        echo "proxied"
    else
        echo "normal"
    fi

    printf "Shelly UI:          "

    if [[ -x "$SHELLY_UI_WRAPPER" ]]; then
        echo "proxied"
    else
        echo "normal"
    fi

    printf "GNOME Shelly:       "

    if [[ -f "$USER_SHELLY_DESKTOP" ]] &&
       grep -q \
           'Exec=/usr/local/bin/shelly-ui' \
           "$USER_SHELLY_DESKTOP"; then

        echo "proxied"

    else

        echo "normal"

    fi

    printf "VS Code settings:   "

    if (( active_proxy_loaded )) && vscode_configuration_matches_active; then
        echo "active $PROXY_TYPE / override"
    elif [[ -f "$CODE_SETTINGS_FILE" ]] &&
         jq -e '."http.proxySupport" == "override" and (."http.proxy" | type == "string")' \
             "$CODE_SETTINGS_FILE" >/dev/null 2>&1; then
        echo "configured for another proxy"
    else
        echo "not configured"
    fi

    printf "Firefox:            "

    if (( active_proxy_loaded )) && firefox_configuration_matches_active; then
        echo "active $PROXY_TYPE"
    elif (( active_proxy_loaded )); then
        echo "does not match active proxy"
    else
        echo "active proxy metadata unavailable"
    fi

    if (( active_proxy_loaded )); then

        printf "Proxy connectivity: "

        if test_proxy; then
            echo "OK"
        else
            echo "FAILED"
        fi

    fi

    echo
    echo "Log file:           $LOG_FILE"
    echo
    echo "=============================================="
    echo
}


# ============================================================
# ENABLE
# ============================================================

enable_proxy() {

    require_sudo
    select_proxy_type
    validate_proxy
    set_proxy_values

    log "=============================================="
    log "ENABLE REQUEST"
    log "Proxy: $PROXY_URL"

    if [[ "$HOST" == "$DEFAULT_HOST" &&
          ( ( "$PROXY_TYPE" == "http" && "$PORT" == "$DEFAULT_HTTP_PORT" ) ||
            ( "$PROXY_TYPE" == "socks5" && "$PORT" == "$DEFAULT_SOCKS_PORT" ) ) ]]; then

        log "Using hard-coded DEFAULT proxy."

    else

        log "Using RUNTIME OVERRIDE."
        log "Hard-coded default remains:"
        log "  HTTP: ${DEFAULT_HOST}:${DEFAULT_HTTP_PORT}"
        log "  SOCKS5: ${DEFAULT_HOST}:${DEFAULT_SOCKS_PORT}"

    fi

    log "=============================================="

    if is_enabled; then

        log "Existing proxy configuration detected."
        log "Updating active proxy without replacing original snapshots."

    else

        log "Creating new clean configuration snapshot."

        clear_state
        prepare_state

    fi

    environment_on
    profile_on
    fish_on

    sudoers_on

    gnome_on

    pacman_on
    flatpak_on
    proxychains_on

    shelly_wrappers_on
    shelly_desktop_on
    vscode_on

    firefox_on

    systemd_on

    set_current_proxy_environment

    save_active_proxy
    sudo touch "$ENABLED_FILE"

    echo
    echo "=============================================="
    echo "             PROXY ENABLED"
    echo "=============================================="
    echo
    echo "Active type:   $PROXY_TYPE"
    echo "Active proxy:  $PROXY_URL"
    echo
    echo "[OK] Environment"
    echo "[OK] Bash"
    echo "[OK] Fish"
    echo "[OK] sudo"
    echo "[OK] systemd / D-Bus"
    echo "[OK] GNOME"
    echo "[OK] pacman / makepkg / AUR"
    echo "[OK] Flatpak"
    echo "[OK] proxychains"
    echo "[OK] Shelly CLI"
    echo "[OK] Shelly GUI"
    echo "[OK] GNOME Shelly launcher"
    echo "[OK] VS Code settings / Codex / AI extensions"
    echo "[OK] Firefox → explicit $PROXY_TYPE proxy"
    echo
    vscode_restart_warning
    echo "Configuration persists across reboot/login."
    echo
}


# ============================================================
# DISABLE
# ============================================================

disable_proxy() {

    require_sudo

    log "=============================================="
    log "DISABLE REQUEST"
    log "=============================================="

    if ! is_enabled; then

        warn "Persistent proxy state is already DISABLED."

        # OFF must be idempotent.  In particular, an older script version may
        # have removed its state flag without ever finding the user's Firefox
        # profile.  Still install Firefox's direct-connection preference when
        # the user runs OFF again.
        log "Applying Firefox direct-connection cleanup despite missing state."
        firefox_off
        systemd_off

        echo
        echo "Firefox and runtime proxy cleanup was applied."
        echo
        return 0

    fi

    log "Restoring original system configuration..."

    gnome_restore

    restore_file "$ENV_FILE" "environment"
    restore_file "$PROFILE_FILE" "proxy.sh"
    restore_file "$FISH_PROFILE_FILE" "proxy.fish"

    restore_file "$SUDOERS_FILE" "sudoers"

    restore_file "$PACMAN_CONF" "pacman.conf"
    restore_file "$FLATPAK_CONF" "flatpak-config"
    restore_file "$PROXYCHAINS_CONF" "proxychains.conf"

    restore_file "$SHELLY_WRAPPER" "shelly-wrapper"
    restore_file "$SHELLY_UI_WRAPPER" "shelly-ui-wrapper"

    shelly_desktop_restore
    vscode_restore

    # Firefox is intentionally forced to DIRECT.
    # This handles old Firefox proxy settings which may have
    # survived previous versions of this script.
    firefox_off

    systemd_off
    clear_current_proxy_environment

    sudo systemctl restart \
        flatpak-system-helper.service \
        2>/dev/null || true

    clear_state

    vscode_restart_warning

    echo
    echo "=============================================="
    echo "             PROXY DISABLED"
    echo "=============================================="
    echo
    echo "System proxy configuration restored."
    echo "Firefox forced to DIRECT / NO PROXY."
    echo "VS Code settings restored."
    echo
    echo "IMPORTANT:"
    echo "  Fully close Firefox and open it again."
    echo "  Open a new terminal to clear old shell variables."
    echo
    echo "=============================================="
}


# ============================================================
# MAIN
# ============================================================

setup_logging
require_not_root

parse_arguments "$@"

case "$ACTION" in

    on)
        enable_proxy
        ;;

    off)
        disable_proxy
        ;;

    status)
        status
        ;;

    *)
        echo
        echo "Usage:"
        echo
        echo "  $0 on"
        echo "  $0 on [host] [port]"
        echo "  $0 [host] [port] on"
        echo "  $0 off"
        echo "  $0 status"
        echo
        echo "Examples:"
        echo
        echo "  $0 on"
        echo "      -> prompts for HTTP or SOCKS5"
        echo
        echo "  $0 on 192.168.43.1 44366"
        echo "      -> prompts for type and uses that endpoint"
        echo
        echo "  $0 192.168.43.1 44366 on"
        echo "      -> same runtime override"
        echo
        echo "  $0 off"
        echo "      -> disables proxy"
        echo
        exit 1
        ;;

esac
