#!/bin/bash

# CCS Master Management Script (ccs.sh)
# Consolidates VNC, Performance, and Mount management tools.

VERSION="1.0.0"

# --- Colors for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Globals & Config ---
# --- Configuration Loading ---
CONFIG_FILE="/etc/ccs/ccs.conf"
[ -f "./ccs.conf" ] && CONFIG_FILE="./ccs.conf" # Allow local override for testing

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
else
    # Default fallback values for backward compatibility
    NAS_IP=${NAS_IP:-"10.11.33.135"}
    USER_HOME_BASE=${USER_HOME_BASE:-"/serverdata/ccshome"}
    READ_ACCESS_PATH=${READ_ACCESS_PATH:-"/NAS/readaccess"}
    FULL_ACCESS_PATH=${FULL_ACCESS_PATH:-"/NAS/fullaccess"}
    NAS_ALL_PATH=${NAS_ALL_PATH:-"/NAS_all"}
    CONDA_PATH=${CONDA_PATH:-"/serverdata/miniconda3"}
    PYTHON_ENV_YML=${PYTHON_ENV_YML:-"/NAS_all/CCS_Common/CustomCodes/Python/ccs_environment.yml"}
    PYTHON_REQS_TXT=${PYTHON_REQS_TXT:-"/NAS_all/CCS_Common/CustomCodes/Python/ccs_requirements.txt"}
    DEFAULT_MEMORY_MAX=${DEFAULT_MEMORY_MAX:-"256G"}
    DEFAULT_TASKS_MAX=${DEFAULT_TASKS_MAX:-"14336"}
fi

readonly BASE_USER_PATH="$USER_HOME_BASE"
readonly READ_ACCESS_PATH="$READ_ACCESS_PATH"
readonly FULL_ACCESS_PATH="$FULL_ACCESS_PATH"
readonly NAS_ALL_PATH="$NAS_ALL_PATH"
THREAD_THRESHOLD=500

# ==============================================================================
# DIAGNOSTIC HELPERS
# ==============================================================================

# Core hardware and system health overview
system_summary() {
    echo "==============================================================="
    echo "  CCS System Overview"
    echo "---------------------------------------------------------------"
        local load_raw=$(uptime | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//')
    local load5=$(echo "$load_raw" | cut -d, -f2 | xargs)
    local demand_pct=$(echo "scale=1; $load5 * 100 / 256" | bc | sed 's/^\./0./')
    local actual_used=$(ps -eo pcpu --no-headers | awk '{th+=$1} END {printf "%.1f", th/100}')
    local available=$(echo "scale=1; 256 - $actual_used" | bc | sed 's/^\./0./')
    (( $(echo "$available < 0" | bc -l) )) && available="0.0"

    echo "CPU Status (256 Cores Total):"
    echo "  Total CPU Demand (5m):    $load5 cores (Saturation: ${demand_pct}%)"
    echo "  Actual CPU Used (Active): $actual_used cores (Throttled by Quotas)"
    echo "  Remaining Available:      $available cores"
    local HANGS=$(ps -eo state | grep "^D" | wc -l)
    [ "$HANGS" -gt 0 ] && echo -e "${RED}!!! ALERT: $HANGS processes are stuck in I/O wait (D-state) !!!${NC}"
    echo "Memory:       $(free -h | grep Mem: | awk '{print "Used: " $3 ", Free: " $4 ", Total: " $2}')"
    local disk_usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    local DISK_INFO=$(df -h / | tail -n 1 | awk '{print "Used: " $3 " (" $5 "), Avail: " $4}')
    echo "Disk /:       $DISK_INFO"
    [ "$disk_usage" -gt 85 ] && echo -e "${RED}!!! ALERT: Disk / is critically full ($disk_usage%) !!!${NC}"
}

# ==============================================================================
# UTILITIES & INTERACTIVE HELPERS
# ==============================================================================

# Helper to select a user interactively if not provided
select_user() {
    local prompt=${1:-"Select a user"}
    local users=($(ls "$BASE_USER_PATH" | sort))
    
    if [ ${#users[@]} -eq 0 ]; then
        echo -e "${RED}Error: No users found in $BASE_USER_PATH${NC}"
        return 1
    fi

    echo -e "${BLUE}$prompt:${NC}" >&2
    for i in "${!users[@]}"; do
        printf "  %2d) %s\n" $((i+1)) "${users[$i]}" >&2
    done

    local choice
    while true; do
        read -p "Choice [1-${#users[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#users[@]}" ]; then
            echo "${users[$((choice-1))]}"
            return 0
        fi
        echo -e "${YELLOW}Invalid choice. Please try again.${NC}"
    done
}

# Helper to select a folder from a path interactively
select_folder() {
    local base_path=$1
    local prompt=${2:-"Select a folder"}
    local folders=($(ls -d "$base_path"/*/ 2>/dev/null | xargs -r -n1 basename | sort))

    if [ ${#folders[@]} -eq 0 ]; then
        echo -e "${RED}Error: No folders found in $base_path${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}$prompt (from $base_path):${NC}" >&2
    for i in "${!folders[@]}"; do
        printf "  %2d) %s\n" $((i+1)) "${folders[$i]}" >&2
    done

    local choice
    while true; do
        read -p "Choice [1-${#folders[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#folders[@]}" ]; then
            echo "${folders[$((choice-1))]}"
            return 0
        fi
        echo -e "${YELLOW}Invalid choice. Please try again.${NC}"
    done
}

# Helper for confirmations
confirm_action() {
    local prompt=$1
    read -p "$prompt [y/N]: " confirm
    [[ "$confirm" == [yY] ]] && return 0 || return 1
}

# Helper to select an active mount interactively
select_active_mount() {
    local username=$1
    local user_nas_dir="${BASE_USER_PATH}/${username}/NAS"
    
    if [ ! -d "$user_nas_dir" ]; then return 1; fi

    local active_mounts=()
    while IFS= read -r -d $'\0' dir; do
        if mountpoint -q "$dir"; then
            active_mounts+=("$(basename "$dir")")
        fi
    done < <(find "$user_nas_dir" -maxdepth 1 -mindepth 1 -type d -print0)

    if [ ${#active_mounts[@]} -eq 0 ]; then
        echo -e "${YELLOW}No active mounts found for user '$username'.${NC}" >&2
        return 1
    fi

    echo -e "${BLUE}Select a mount to remove:${NC}" >&2
    for i in "${!active_mounts[@]}"; do
        printf "  %2d) %s\n" $((i+1)) "${active_mounts[$i]}" >&2
    done
    printf "  %2s) %s\n" "all" "Remove ALL active mounts" >&2

    local choice
    while true; do
        read -p "Choice [1-${#active_mounts[@]} or 'all']: " choice
        if [ "$choice" == "all" ]; then
            echo "--all"
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#active_mounts[@]}" ]; then
            echo "${active_mounts[$((choice-1))]}"
            return 0
        fi
        echo -e "${YELLOW}Invalid choice. Please try again.${NC}" >&2
    done
}

# ==============================================================================
# HELP & USAGE
# ==============================================================================

ccs_full_help() {
    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}   CCS Master Management Script (ccs) - User Guide${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo ""
    echo -e "${YELLOW}General Usage:${NC}"
    echo "  sudo ccs <category> <action> [arguments]"
    echo ""
    echo "Most commands require sudo privileges. Run 'ccs <category> help' for action lists."
    echo ""

    echo -e "${GREEN}[1] VNC Management (ccs vnc)${NC}"
    echo "---------------------------------------------------------------"
    printf "  %-16s %-s\n" "info [--cleanup]"  "List all VNC sessions; optionally remove dead/redundant ones."
    printf "  %-16s %-s\n" "health"            "System-wide VNC diagnostic: throttling, ports, latency."
    printf "  %-16s %-s\n" "troubleshoot [me]" "Deep diagnostics: WM, throttling, I/O, compositing."
    printf "  %-16s %-s\n" "boost [me|user]"   "Elevate VNC CPU priority to keep UI responsive under load."
    printf "  %-16s %-s\n" "optimize [me|all]" "Apply VNC & desktop tweaks (disables compositing, etc)."
    printf "  %-16s %-s\n" "setup"             "Interactive: Create a new VNC session for a user."
    printf "  %-16s %-s\n" "switch [me|user]"  "Switch desktop environment (xfce/gnome) for user or --all."
    printf "  %-16s %-s\n" "remove"            "Interactive: Safely stop and remove a VNC systemd service."
    echo ""

    echo -e "${GREEN}[2] Performance & Health (ccs perf)${NC}"
    echo "---------------------------------------------------------------"
    printf "  %-16s %-s\n" "status"            "Dashboard: threads, CPU/RAM per user, GPU, and NAS health."
    printf "  %-16s %-s\n" "stabilize"         "One-shot: Apply limits + clean runaway processes."
    printf "  %-16s %-s\n" "top"               "Top 20 processes by thread count (NLWP)."
    printf "  %-16s %-s\n" "noisy"             "Identify processes exceeding the thread threshold."
    printf "  %-16s %-s\n" "hangs"             "Detect processes stuck in I/O wait (D-state)."
    printf "  %-16s %-s\n" "kill [--interactive]" "Kill by pattern (matlab|python|...) or interactively."
    printf "  %-16s %-s\n" "limits"            "View/set system-wide CPU, Memory, and TasksMax quotas."
    printf "  %-16s %-s\n" "gpu"               "Detailed NVIDIA GPU diagnostics."
    printf "  %-16s %-s\n" "hw"                "Hardware health: IPMI temps, fans, PSU status."
    printf "  %-16s %-s\n" "conda-init"        "Configure current user shell for Miniconda3."
    printf "  %-16s %-s\n" "conda-user-env"    "Configure local default CCS Conda environment for user."
    printf "  %-16s %-s\n" "spyder-hub"        "Launch the centralized CCS Spyder Hub."
    echo ""

    echo -e "${GREEN}[3] NAS Mount Management (ccs mount)${NC}"
    echo "---------------------------------------------------------------"
    printf "  %-16s %-s\n" "setup"    "Interactive: Navigate NAS categories and create a bind-mount."
    printf "  %-16s %-s\n" "remove"   "Interactive: Safely unmount and remove an fstab entry."
    printf "  %-16s %-s\n" "flush"    "Force-unmount all NAS bind-mounts for a user or --all."
    printf "  %-16s %-s\n" "restore"  "Re-mount all fstab entries (runs 'mount -a')."
    printf "  %-16s %-s\n" "cleanup"  "Deep-clean: flatten stacked mounts and remove stale folders."
    printf "  %-16s %-s\n" "auto-fix" "Automatically detect and repair broken bind-mounts."
    echo -e "  ${BLUE}Tip: Run 'sudo ccs mount cleanup --all' if the Remote GUI is cluttered.${NC}"
    echo ""

    echo -e "${GREEN}[4] User Access (ccs user)${NC}"
    echo "---------------------------------------------------------------"
    printf "  %-16s %-s\n" "sudo list" "List users in the administrative 'wheel' group."
    printf "  %-16s %-s\n" "sudo add"  "Interactive: Grant sudo access to a user."
    printf "  %-16s %-s\n" "sudo rem"  "Interactive: Remove sudo access from a user."
    echo ""

    echo -e "${GREEN}[5] Network Diagnostics (ccs net)${NC}"
    echo "---------------------------------------------------------------"
    printf "  %-16s %-s\n" "info"     "Check local IP and basic routing to NAS."
    printf "  %-16s %-s\n" "latency"  "Detailed latency test to the NAS gateway."
    printf "  %-16s %-s\n" "dns"      "Check DNS resolution."
    printf "  %-16s %-s\n" "stats"    "Network interface statistics."
    printf "  %-16s %-s\n" "monitor"  "Real-time: Monitor NAS reachability and CIFS logs."
    echo ""
    exit 1
}

alias usage=ccs_full_help


vnc_usage() {
    echo -e "${BLUE}VNC Actions:${NC}"
    echo "  add <user> <display> [xfce|gnome]  Create a new VNC user"
    echo "  setup                              Interactive VNC setup"
    echo "  info [--cleanup]                   List sessions & clean redundant ones"
    echo "  health                             System-wide VNC health diagnostic"
    echo "  switch <xfce|gnome> [user|--all]   Switch VNC desktop environment"
    echo "  optimize [all|me]                  Apply VNC performance tweaks"
    echo "  boost [me|user]                    Increase VNC CPU priority (UI Boost)"
    echo "  troubleshoot [me|user]             Diagnose UI lag/hanging issues"
    echo "  check [--cleanup]                  List sessions & clean redundant ones"
    echo "  start <name-num> <user>            Manual start of VNC session"
    echo "  remove                             Interactive VNC session removal"
    exit 1
}

perf_actions() {
    echo -e "${BLUE}Performance Actions:${NC}"
    echo "  status                             Show system health & user resource usage"
    echo "  stabilize                          Apply server-wide stabilization (Limits + Cleanup)"
    echo "  top                                Show top 20 processes by threads"
    echo "  noisy                              Highlight processes exceeding $THREAD_THRESHOLD threads"
    echo "  kill [pattern] [--interactive]     Cleanup processes (matlab|python|...)"
    echo "  limits                             Configure CPU/Memory/Tasks quotas"
    echo "  conda-env <name>                   Create standard CCS Conda environment"
    echo "  conda-user-env [user|--all] [name] Create local Conda environment (default: ccs)"
    echo "  conda-optimize <user> <env>        Optimize environment threads (OpenBLAS/MKL)"
    echo "  conda-optimize-all                 Optimize ALL environments for ALL users"
    echo "  gpu                                Check GPU health and diagnostics"
    echo "  hw                                 Check hardware health via IPMI"
    echo "  noisy                              Detect processes exceeding thread threshold"
    echo "  hangs                              List processes in D-state"
    echo "  kill                               Kill noisy processes (Interactive)"
    echo "  cleanup                            Rotate logs and clean /tmp"
    echo "  persistence <on|off>               Enable/Disable GPU Persistence Mode"
    exit 1
}

mount_usage() {
    echo -e "${BLUE}Mount Actions:${NC}"
    echo "  setup <user> <target> <source> <read|full> [--persistent]  Bind mount NAS folders"
    echo "  remove <user> [target|--all]      Unmount and remove NAS folders
  cleanup <user>                    Remove unmounted NAS dirs & fstab entries
  restore                           Troubleshoot: Wipe and rebuild all mounts safely
  auto-fix                          Monitor & Auto-repair: Detect stacked/empty mounts
"
    exit 1
}

net_usage() {
    echo -e "${BLUE}Network Actions:${NC}"
    echo "  info                               Comprehensive network health check"
    echo "  latency                            Check latency to gateway and external"
    echo "  dns                                Test DNS resolution speed"
    echo "  stats                              Interface statistics and errors"
    echo "  monitor                            Real-time NAS & Network monitoring"
    exit 1
}

# ==============================================================================
# VNC CATEGORY
# ==============================================================================

vnc_generate_xstartup() {
    local username=$1
    local de=$2
    local user_home="$BASE_USER_PATH/$username"
    local xstartup="$user_home/.vnc/xstartup"
    local de_cmd

    if [ "$de" == "gnome" ]; then
        if command -v gnome-session-classic >/dev/null 2>&1; then
            de_cmd="export XDG_CURRENT_DESKTOP=\"GNOME\"\nexport GNOME_SHELL_SESSION_MODE=\"ubuntu\"\nexec dbus-run-session gnome-session-classic"
        else
            de_cmd="export XDG_CURRENT_DESKTOP=\"GNOME\"\nexport GNOME_SHELL_SESSION_MODE=\"ubuntu\"\nexec dbus-run-session gnome-session"
        fi
    else
        de_cmd="exec startxfce4"
    fi

    cat << EOF > "$xstartup"
#!/bin/sh
unset SESSION_MANAGER
unset DBUS_SESSION_BUS_ADDRESS
export LIBGL_ALWAYS_SOFTWARE=1
export GALLIUM_DRIVER=llvmpipe
export LP_NUM_THREADS=8
export QT_X11_NO_MITSHM=1

# --- Session Hygiene ---
# Disable compositing and hanging services after a short delay to ensure DE is up
(
  sleep 10
  xfconf-query -c xfwm4 -p /general/use_compositing -s false
  xfce4-screensaver --exit
  xfce4-power-manager --exit
) >/dev/null 2>&1 &

$(echo -e "$de_cmd")
EOF
    chown "$username:$username" "$xstartup"
    chmod 755 "$xstartup"
}

vnc_add() {
    local USERNAME=$1
    local DISPLAY_NUM=$2
    local TARGET_DE=$3
    
    if [ -z "$USERNAME" ]; then
        echo -e "${BLUE}=== Interactive VNC Setup ===${NC}"
        USERNAME=$(select_user "Select user for VNC") || return 1
        
        # Suggest next available display
        local last_disp=$(ls /etc/systemd/system/vncserver@*.service 2>/dev/null | grep -oP "@\d+" | tr -d '@' | sort -rn | head -n 1)
        local suggest_disp=$((last_disp + 1))
        [ -z "$last_disp" ] && suggest_disp=1
        
        read -p "Display Number (e.g. 1) [$suggest_disp]: " DISPLAY_NUM
        DISPLAY_NUM=${DISPLAY_NUM:-$suggest_disp}
        
        echo -e "Desktop Environment:\n  1) XFCE (Recommended)\n  2) GNOME"
        read -p "Choice [1-2]: " de_choice
        [ "$de_choice" == "2" ] && TARGET_DE="gnome" || TARGET_DE="xfce"
    fi

    local USER_HOME="$BASE_USER_PATH/$USERNAME"

    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Root required.${NC}"; return 1; fi

    echo "Stopping any existing VNC service for display :${DISPLAY_NUM}..."
    systemctl stop "vncserver@${DISPLAY_NUM}.service" >/dev/null 2>&1
    rm -f "/etc/systemd/system/vncserver@${DISPLAY_NUM}.service"
    rm -f "$USER_HOME/.vnc/%H:${DISPLAY_NUM}.pid"
    systemctl daemon-reload

    echo "Setting up VNC password for $USERNAME..."
    mkdir -p "$USER_HOME/.vnc"
    chown "$USERNAME:$USERNAME" "$USER_HOME/.vnc"
    sudo -u "$USERNAME" vncpasswd
    sudo -u "$USERNAME" chmod 600 "$USER_HOME/.vnc/passwd"

    echo "Configuring performance optimizations..."
    local VNC_CONFIG="$USER_HOME/.vnc/config"
    # We keep it minimal for maximum compatibility.
    echo -e "### CCS Optimized Settings\nLazyTight=1\nAlwaysShared=0\nDisconnectClients=1\n# (Command-line quality flags removed for 1.15.0 compatibility)" > "$VNC_CONFIG"
    chown "$USERNAME:$USERNAME" "$VNC_CONFIG"

    echo "Configuring $TARGET_DE startup script..."
    vnc_generate_xstartup "$USERNAME" "$TARGET_DE"

    echo "Initializing conda for $USERNAME..."
    sudo -i -u "$USERNAME" /serverdata/miniconda3/bin/conda init

    local SERVICE_FILE="/etc/systemd/system/vncserver@${DISPLAY_NUM}.service"
    local VNC_PORT=$((5900 + DISPLAY_NUM))
    echo "Creating systemd service file..."
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=TigerVNC server for $USERNAME on display :%i
After=syslog.target network.target

[Service]
Type=forking
User=$USERNAME
Group=$USERNAME
WorkingDirectory=$USER_HOME
PIDFile=$USER_HOME/.vnc/%H:%i.pid
ExecStart=/usr/bin/vncserver :%i -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :%i

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "vncserver@${DISPLAY_NUM}.service"
    systemctl start "vncserver@${DISPLAY_NUM}.service"

    echo "Opening port ${VNC_PORT} in the firewall..."
    firewall-cmd --permanent --add-port=${VNC_PORT}/tcp >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1

    echo -e "\n${GREEN}✅ Setup complete for user '${USERNAME}' on display ':${DISPLAY_NUM}'${NC}"
    systemctl status "vncserver@${DISPLAY_NUM}.service" --no-pager
}

vnc_remove() {
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Root required.${NC}"; return 1; fi
    echo -e "${BLUE}=== Interactive VNC Removal ===${NC}"
    
    local services=($(ls /etc/systemd/system/vncserver@*.service 2>/dev/null | xargs -n1 basename | sort))
    if [ ${#services[@]} -eq 0 ]; then
        echo "No VNC services found."
        return 0
    fi

    echo "Select service to remove:"
    for i in "${!services[@]}"; do
        local user=$(grep "^User=" "/etc/systemd/system/${services[$i]}" | cut -d'=' -f2)
        printf "  %2d) %-20s (User: %s)\n" $((i+1)) "${services[$i]}" "$user"
    done

    local choice
    while true; do
        read -p "Choice [1-${#services[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#services[@]}" ]; then
            local svc_name="${services[$((choice-1))]}"
            if confirm_action "Are you sure you want to PERMANENTLY remove $svc_name?"; then
                echo "Stopping and disabling $svc_name..."
                systemctl stop "$svc_name"
                systemctl disable "$svc_name"
                rm -f "/etc/systemd/system/$svc_name"
                systemctl daemon-reload
                echo -e "${GREEN}Successfully removed $svc_name.${NC}"
            fi
            break
        else
            echo "Invalid selection."
        fi
    done
}


vnc_switch() {
    if [ "$#" -lt 1 ]; then vnc_usage; fi
    local TARGET_DE=$1
    local TARGET_USER=$2
    local is_root=0
    [ "$(id -u)" -eq 0 ] && is_root=1

    switch_user_de() {
        local username=$1
        local de=$2
        local user_info=$(getent passwd "$username")
        [ -z "$user_info" ] && echo "Error: User '$username' not found." && return 1
        local user_home=$(echo "$user_info" | cut -d: -f6)

        echo "Processing user: $username (Setting to $de)..."
        [ -f "$user_home/.vnc/xstartup" ] && cp "$user_home/.vnc/xstartup" "$user_home/.vnc/xstartup.bak_$(date +%Y%m%d%H%M%S)"
        mkdir -p "$user_home/.vnc"
        
        vnc_generate_xstartup "$username" "$de"
        echo "  -> xstartup updated to $de."

        if [ "$is_root" -eq 1 ]; then
            local service_files=$(grep -l "^User=$username$" /etc/systemd/system/vncserver@*.service 2>/dev/null)
            if [ -n "$service_files" ]; then
                local displays=$(for f in $service_files; do basename "$f" | cut -d"@" -f2 | cut -d"." -f1 | tr -d ':'; done | sort -u)
                for d in $displays; do
                    echo "  -> Restarting session for display :$d..."
                    # Force kill session processes to ensure clean DE switch
                    for cmd_pattern in "Xvnc :$d" "gnome-session" "xfce4-session"; do
                        pkill -u "$username" -9 -f "$cmd_pattern" 2>/dev/null
                    done
                    systemctl stop "vncserver@$d" >/dev/null 2>&1
                    rm -f "/tmp/.X$d-lock" "/tmp/.X11-unix/X$d" "$user_home/.vnc/"*":$d.pid" 2>/dev/null
                    systemctl start "vncserver@$d" && echo "  -> Display :$d RESTARTED." || echo "  -> FAILED to restart :$d."
                done
            fi
        else
            echo -e "${YELLOW}  ⚠️  Manual restart required: Please kill and restart your VNC session for changes to take effect.${NC}"
        fi
    }

    if [ -z "$TARGET_USER" ]; then
        REAL_USER=$(whoami); [ -n "$SUDO_USER" ] && REAL_USER=$SUDO_USER
        switch_user_de "$REAL_USER" "$TARGET_DE"
    elif [ "$TARGET_USER" == "--all" ]; then
        if [ "$is_root" -eq 0 ]; then echo "Error: --all requires sudo."; return 1; fi
        local all_vnc_users=$(grep -h "^User=" /etc/systemd/system/vncserver@*.service 2>/dev/null | cut -d"=" -f2 | sort -u)
        for u in $all_vnc_users; do switch_user_de "$u" "$TARGET_DE"; done
    else
        if [ "$is_root" -eq 0 ] && [ "$TARGET_USER" != "$(whoami)" ]; then echo "Error: Root required."; return 1; fi
        switch_user_de "$TARGET_USER" "$TARGET_DE"
    fi
}

vnc_optimize() {
    local target=$1
    local OPTIMIZED_SETTINGS="### CCS Optimized Settings\n# (Config flags removed for 1.15.0 compatibility)"

    optimize_user() {
        local user_dir=$1
        local user_config="$user_dir/.vnc/config"
        [ ! -d "$user_dir/.vnc" ] && return
        echo -n "Cleaning config for $user_dir... "
        if [ ! -f "$user_config" ]; then
            echo -e "$OPTIMIZED_SETTINGS" > "$user_config"
            chown $(stat -c '%U:%G' "$user_dir") "$user_config" 2>/dev/null
        else
            sed -i '/preferredencoding/I d;/compresslevel/I d;/compressionlevel/I d;/quality/I d;/### CCS Optimized/d;/lazytight/I d;/alwaysshared/I d;/disconnectclients/I d' "$user_config"
            echo -e "$OPTIMIZED_SETTINGS" >> "$user_config"
        fi
        echo "DONE"
    }

    standardize_services() {
        if [ "$EUID" -ne 0 ]; then echo "Sudo required."; return; fi
        
        # 1. First, migrate any old-style filenames (vncserver@:1.service -> vncserver@1.service)
        local non_files=$(ls /etc/systemd/system/vncserver@:*.service 2>/dev/null)
        for old_file in $non_files; do
            local old_name=$(basename "$old_file"); local d_num=$(echo "$old_name" | cut -d":" -f2 | cut -d"." -f1)
            local new_name="vncserver@${d_num}.service"; local new_file="/etc/systemd/system/$new_name"
            echo "  -> Migrating filename $old_name to $new_name..."
            systemctl stop "$old_name" >/dev/null 2>&1; systemctl disable "$old_name" >/dev/null 2>&1
            mv "$old_file" "$new_file"
        done

        # 2. Now, rewrite all service files to match the standard CCS template
        local services=( /etc/systemd/system/vncserver@*.service )
        for svc_file in "${services[@]}"; do
            [ ! -f "$svc_file" ] && continue
            local filename=$(basename "$svc_file")
            local d_num=$(echo "$filename" | cut -d"@" -f2 | cut -d"." -f1)
            local user=$(grep "^User=" "$svc_file" | cut -d"=" -f2)
            [ -z "$user" ] && continue
            local user_home=$(getent passwd "$user" | cut -d: -f6)
            [ -z "$user_home" ] && continue
            
            echo "  -> Applying CCS template to $filename (User: $user)..."
            cat <<EOF > "$svc_file"
[Unit]
Description=TigerVNC server for $user on display :$d_num
After=syslog.target network.target

[Service]
Type=forking
User=$user
Group=$user
WorkingDirectory=$user_home
PIDFile=$user_home/.vnc/%H:$d_num.pid
ExecStart=/usr/bin/vncserver :$d_num -geometry 1920x1080 -depth 24 -localhost no
ExecStop=/usr/bin/vncserver -kill :$d_num

[Install]
WantedBy=multi-user.target
EOF
        done
        
        systemctl daemon-reload
        echo "Service standardization complete."
    }

    case "$target" in
        all) 
            standardize_services
            for d in /serverdata/ccshome/*; do 
                if [ -d "$d" ]; then
                    optimize_user "$d"
                    local uname=$(basename "$d")
                    vnc_tune_de "$uname"
                fi
            done 
            ;;
        me|"") 
            optimize_user "$HOME"
            vnc_tune_de
            ;;
        *) echo "Usage: ccs vnc optimize [all|me]" ;;
    esac
}

vnc_tune_de() {
    local target_user=${1:-$(whoami)}
    [ "$target_user" == "me" ] && target_user=$(whoami)
    local user_info=$(getent passwd "$target_user")
    local user_home=$(echo "$user_info" | cut -d: -f6)

    echo "Optimizing Desktop Environment for $target_user..."
    
    # 1. Xfce Optimization: Disable Compositing
    if [ -f "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" ]; then
        echo "  - Detected Xfce. Disabling window manager compositing..."
        if [ "$target_user" == "$(whoami)" ]; then
            xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null || \
            sed -i 's/property name="use_compositing" type="bool" value="true"/property name="use_compositing" type="bool" value="false"/' "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
        else
            sudo -u "$target_user" bash -c "xfconf-query -c xfwm4 -p /general/use_compositing -s false 2>/dev/null" || \
            sed -i 's/property name="use_compositing" type="bool" value="true"/property name="use_compositing" type="bool" value="false"/' "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
        fi
        echo -e "${GREEN}    Done. (Restart session to see full effect)${NC}"
    fi

    # 2. GNOME Optimization: Disable animations
    if [ -d "$user_home/.config/dconf" ]; then
        echo "  - Detected GNOME/dconf. Disabling animations..."
        sudo -u "$target_user" gsettings set org.gnome.desktop.interface enable-animations false 2>/dev/null || true
    fi
}

vnc_boost() {
    local target_user=${1:-$(whoami)}
    [ "$target_user" == "me" ] && target_user=$(whoami)
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Root required to boost services.${NC}"; return 1; fi

    echo -e "${BLUE}=== CCS VNC UI Boost ===${NC}"
    echo "Increasing CPU priority for $target_user's VNC sessions..."

    local service_files=$(grep -l "^User=$target_user" /etc/systemd/system/vncserver@*.service 2>/dev/null)
    if [ -z "$service_files" ]; then
        echo "No active VNC services found for $target_user."
        return 1
    fi

    for f in $service_files; do
        local svc_name=$(basename "$f")
        echo "  -> Boosting $svc_name..."
        # Increase CPUWeight to 500 (default 100)
        systemctl set-property "$svc_name" CPUWeight=500 2>/dev/null
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}     Success.${NC}"
        else
            echo -e "${RED}     Failed to set properties.${NC}"
        fi
    done
    echo -e "\n${YELLOW}Tip: This gives the UI priority over background computations.${NC}"
}

vnc_troubleshoot() {
    local target_user=${1:-$(whoami)}
    [ "$target_user" == "me" ] && target_user=$(whoami)
    
    echo "==============================================================="
    echo "  CCS VNC Troubleshooter: UI Responsiveness & Lag"
    echo "==============================================================="
    echo "Diagnosing user: $target_user"

    # 1. Check for Throttling (Cgroups)
    echo -e "\n[1] Checking for CPU Throttling..."
    local user_slice=$(systemctl list-units "user-$(id -u $target_user).slice" --no-legend | awk '{print $1}')
    if [ -n "$user_slice" ]; then
        if [ -f "/sys/fs/cgroup/user.slice/$user_slice/cpu.stat" ]; then
            local throttled=$(grep "nr_throttled" "/sys/fs/cgroup/user.slice/$user_slice/cpu.stat" | awk '{print $2}')
            local throttled_time=$(grep "throttled_usec" "/sys/fs/cgroup/user.slice/$user_slice/cpu.stat" | awk '{print $2}')
            echo "User slice $user_slice found."
            echo "  - Total throttled count: $throttled"
            echo "  - Total throttled time:  $((throttled_time / 1000)) ms"
            if [ "$throttled" -gt 0 ]; then
                echo -e "${YELLOW}⚠️  Detected CPU throttling. This user is hitting their CPU quota.${NC}"
            else
                echo -e "${GREEN}✅ No significant CPU throttling detected.${NC}"
            fi
        fi
    else
        echo "No active user slice found for $target_user."
    fi

    # 2. Check Window Manager (process-based, works without DISPLAY)
    echo -e "\n[2] Checking Window Manager Status..."
    local wm_procs=$(ps -u "$target_user" -o pid,comm --no-headers 2>/dev/null | grep -E "xfwm4|gnome-shell|kwin|marco|openbox|metacity")
    if [ -z "$wm_procs" ]; then
        echo -e "${RED}❌ No active Window Manager found for $target_user.${NC}"
        echo "The UI will be unresponsive (no window borders, cannot move windows)."
    else
        echo -e "${GREEN}✅ Window Manager is running:${NC}"
        echo "$wm_procs" | sed 's/^/  - /'
    fi

    # 3. Check VNC Logs for Errors
    echo -e "\n[3] Scanning VNC Logs for Recent Errors..."
    local user_home=$(getent passwd "$target_user" | cut -d: -f6)
    local latest_log=$(ls -t "$user_home/.vnc/"*.log 2>/dev/null | head -n 1)
    if [ -n "$latest_log" ]; then
        echo "Log file: $(basename "$latest_log")"
        local errors=$(grep -iE "error|critical|failed|refused|full" "$latest_log" | tail -n 5)
        if [ -n "$errors" ]; then
            echo -e "${YELLOW}Recent errors found:${NC}"
            echo "$errors" | sed 's/^/  /'
        else
            echo -e "${GREEN}✅ No recent errors found in logs.${NC}"
        fi
    else
        echo "No VNC logs found for $target_user."
    fi

    # 4. Check for I/O Wait & Disk Latency
    echo -e "\n[4] Checking for Blocking Processes & Disk I/O Wait..."
    local io_hangs=$(ps -u "$target_user" -o state,pid,comm | grep "^D" 2>/dev/null)
    if [ -n "$io_hangs" ]; then
        echo -e "${RED}⚠️  Blocking processes (D-State) found:${NC}"
        echo "$io_hangs" | sed 's/^/  /'
    else
        echo -e "${GREEN}✅ No I/O-blocked processes found for this user.${NC}"
    fi
    local iowait=$(iostat -c 1 2 2>/dev/null | awk '/^avg-cpu/ {getline; print $4}' | tail -n 1)
    if [ -n "$iowait" ]; then
        echo "System I/O Wait: $iowait%"
        if (( $(echo "$iowait > 5.0" | bc -l) )); then
            echo -e "${YELLOW}⚠️  High I/O Wait detected. The disk might be slow or overloaded.${NC}"
        fi
    fi

    # 5. Check Desktop Features
    echo -e "\n[5] Checking Desktop Environment Features..."
    if [ -f "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" ]; then
        local comp=$(grep "use_compositing" "$user_home/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml" | grep -o "true")
        if [ "$comp" == "true" ]; then
            echo -e "${YELLOW}⚠️  Xfce Compositing is ENABLED. This causes major VNC lag.${NC}"
        else
            echo -e "${GREEN}✅ Xfce Compositing is disabled.${NC}"
        fi
    fi

    echo -e "\n---------------------------------------------------------------"
    echo "Recommendation:"
    echo " - If throttled: Increase CPU quota using 'sudo ccs perf limits'."
    echo " - If WM missing: Restart session using 'sudo systemctl restart vncserver@<display>'."
    echo " - If lag persists: Run 'ccs vnc optimize me' to refresh VNC settings."
    echo "==============================================================="
}

vnc_health() {
    echo "==============================================================="
    echo "  CCS VNC Health & Responsiveness Diagnostic"
    echo "==============================================================="

    # 1. System Load & Throttling Summary
    echo -e "\n[1] Resource Throttling Summary"
    echo "---------------------------------------------------------------"
    local throttled_found=0
    for slice in $(systemctl list-units "user-*.slice" --no-legend | awk '{print $1}'); do
        if [ -f "/sys/fs/cgroup/user.slice/$slice/cpu.stat" ]; then
            local throttled=$(grep "nr_throttled" "/sys/fs/cgroup/user.slice/$slice/cpu.stat" | awk '{print $2}')
            if [ "$throttled" -gt 0 ]; then
                local user_id=$(echo $slice | cut -d'-' -f2 | cut -d'.' -f1)
                local username=$(id -nu $user_id 2>/dev/null || echo "UID:$user_id")
                echo -e "${RED}⚠️  User $username is being THROTTLED ($throttled times)${NC}"
                throttled_found=1
            fi
        fi
    done
    [ "$throttled_found" -eq 0 ] && echo -e "${GREEN}✅ No users currently hitting CPU quotas.${NC}"

    # 2. Network Latency (Internal Gateway)
    echo -e "\n[2] Internal Network Latency (Gateway)"
    echo "---------------------------------------------------------------"
    local gateway=$(ip route | grep default | awk '{print $3}' | head -n 1)
    if [ -n "$gateway" ]; then
        ping -c 3 -W 1 "$gateway" | tail -n 1
    else
        echo "No gateway found."
    fi

    # 3. Port & Socket Status
    echo -e "\n[3] VNC Listening Ports & X11 Sockets"
    echo "---------------------------------------------------------------"
    if command -v ss >/dev/null 2>&1; then
        ss -tlnp | grep Xvnc | awk '{print "Port: " $4}'
    else
        netstat -tlnp | grep Xvnc | awk '{print "Port: " $4}'
    fi
    local socket_count=$(ls /tmp/.X11-unix/ | grep "^X" | wc -l)
    echo "Active X11 Sockets: $socket_count"

    echo -e "\n${BLUE}Recommendation:${NC}"
    echo " - If throttling is high: Increase 'sudo ccs perf limits'."
    echo " - If ports are missing: Run 'ccs vnc check' to find inactive services."
    echo "==============================================================="
}

vnc_info() {
    local CLEANUP=0
    if [[ "$*" == *"--cleanup"* ]]; then CLEANUP=1; fi
    if [ "$EUID" -ne 0 ]; then echo "Root required for full scan."; fi

    echo "=========================================================================================="
    echo "  CCS VNC User Status Monitor & Cleanup"
    echo "=========================================================================================="
    printf "%-10s %-15s %-12s %-10s %-15s %-s\n" "DISPLAY" "USER" "SERVICE" "NETWORK" "PID" "START TIME"
    echo "------------------------------------------------------------------------------------------"

    local services=( /etc/systemd/system/vncserver@*.service )
    if [ ! -e "${services[0]}" ]; then echo "No VNC services found."; return; fi

    declare -A normalized_displays; declare -A user_sessions; declare -A session_info; declare -a to_remove

    for service in "${services[@]}"; do
        local filename=$(basename "$service")
        local raw_display=$(echo "$filename" | cut -d"@" -f2 | cut -d"." -f1)
        local display_num=$(echo "$raw_display" | tr -d ':')
        if [ -z "$display_num" ] || ! [[ "$display_num" =~ ^[0-9]+$ ]]; then
            [ "$CLEANUP" -eq 1 ] && to_remove+=("$service"); continue
        fi

        local user=$(grep -i "^User=" "$service" | cut -d"=" -f2 | xargs)
        [ -z "$user" ] && user="N/A"
        local svc_status=$(systemctl is-active "$filename" 2>/dev/null)
        local port=$((5900 + display_num))
        local svc_display="INACTIVE"; local net_status="-"; local pid="-"; local start_time="-"

        if [ "$svc_status" == "active" ]; then
            svc_display="ACTIVE"
            netstat -an | grep ":$port " | grep "ESTABLISHED" >/dev/null 2>&1 && net_status="CONNECTED" || net_status="IDLE"
            pid=$(pgrep -u "$user" -f "Xvnc :$raw_display" | head -n 1)
            [ -n "$pid" ] && start_time=$(ps -p "$pid" -o lstart= | awk '{print $2" "$3" "$4}')
        fi

        if [ -n "${normalized_displays[$display_num]}" ] && [[ "$raw_display" == *":"* ]]; then
             printf ":%-9s %-15s %-12s %-10s %-15s %-s\n" "$raw_display" "$user" "DUPLICATE" "-" "-" "-"
             [ "$CLEANUP" -eq 1 ] && to_remove+=("$service"); continue
        fi
        normalized_displays[$display_num]="$service"
        session_info[$display_num]="$svc_display|$net_status|$service|$raw_display|$user|$pid|$start_time"
        user_sessions[$user]="${user_sessions[$user]}${user_sessions[$user]:+,}$display_num"
    done

    declare -A is_redundant
    for user in "${!user_sessions[@]}"; do
        IFS=',' read -r -a d_list <<< "${user_sessions[$user]}"
        if [ ${#d_list[@]} -gt 1 ]; then
            local best_d=""; local best_score=-1
            for d in "${d_list[@]}"; do
                local data=${session_info[$d]}; local s_status=$(echo "$data" | cut -d'|' -f1); local s_net=$(echo "$data" | cut -d'|' -f2); local score=1
                [ "$s_status" == "ACTIVE" ] && score=2; [ "$s_net" == "CONNECTED" ] && score=3
                if [ "$score" -gt "$best_score" ] || ([ "$score" -eq "$best_score" ] && ([ -z "$best_d" ] || [ "$d" -lt "$best_d" ])); then
                    best_score=$score; best_d=$d
                fi
            done
            for d in "${d_list[@]}"; do
                if [ "$d" != "$best_d" ]; then
                    is_redundant[$d]=1; [ "$CLEANUP" -eq 1 ] && to_remove+=("$(echo "${session_info[$d]}" | cut -d'|' -f3)")
                fi
            done
        fi
    done

    for d in $(echo "${!session_info[@]}" | tr ' ' '\n' | sort -n); do
        local data=${session_info[$d]}
        local label=$(echo "$data" | cut -d'|' -f1)
        [ "$(echo "$data" | cut -d'|' -f5)" == "N/A" ] && label="BAD_USER"
        [ "${is_redundant[$d]}" == "1" ] && label="REDUNDANT"
        printf ":%-9s %-15s %-12s %-10s %-15s %-s\n" "$d" "$(echo "$data" | cut -d'|' -f5)" "$label" "$(echo "$data" | cut -d'|' -f2)" "$(echo "$data" | cut -d'|' -f6)" "$(echo "$data" | cut -d'|' -f7)"
    done

    if [ "$CLEANUP" -eq 1 ] && [ ${#to_remove[@]} -gt 0 ]; then
        echo -e "------------------------------------------------------------------------------------------\nStarting cleanup..."
        for svc_file in $(echo "${to_remove[@]}" | tr ' ' '\n' | sort -u); do
            local svc_name=$(basename "$svc_file")
            echo -n "  -> Removing $svc_name... "
            systemctl stop "$svc_name" >/dev/null 2>&1; systemctl disable "$svc_name" >/dev/null 2>&1; rm -f "$svc_file"; echo "DONE"
        done
        systemctl daemon-reload
        echo "Cleanup complete."
    fi
}

vnc_start() {
    if [ "$#" -ne 2 ]; then
        echo "Usage: ccs vnc start <instance_name> <username>"
        echo "Example: ccs vnc start arun-3 arun"
        return 1
    fi

    local instance_name="$1"
    local user_name="$2"
    local display_num=$(echo "$instance_name" | cut -d- -f2)

    if [ -z "$display_num" ] || ! [[ "$display_num" =~ ^[0-9]+$ ]]; then
        echo "Error: Instance name must be in the format 'username-display' (e.g., arun-3)."
        return 1
    fi

    local display_string=":$display_num"
    local home_dir="$BASE_USER_PATH/$user_name"

    if [ ! -d "$home_dir" ]; then
        echo "Error: Home directory not found for user $user_name at $home_dir"
        return 1
    fi

    echo "Starting Xfce desktop for $user_name on $display_string..."
    export DISPLAY="$display_string"
    if [ -x /usr/bin/startxfce4 ]; then
        runuser -l "$user_name" -c "/usr/bin/startxfce4" &
    else
        echo "Warning: startxfce4 not found."
    fi

    echo "Starting Xvnc..."
    exec /usr/bin/Xvnc "${display_string}" \
        -auth "${home_dir}/.Xauthority" \
        -desktop "CCS-SERVER${display_string} (${user_name})" \
        -geometry 1920x1080 \
        -depth 24 \
        -rfbauth "${home_dir}/.vnc/passwd" \
        -rfbport "$((5900 + display_num))" \
        -fp catalogue:/etc/X11/fontpath.d
}

# ==============================================================================
# PERFORMANCE CATEGORY
# ==============================================================================

perf_status() {
    echo "==============================================================="
    echo "  CCS System Performance & Health Status"
    echo "==============================================================="

    # 1. System resource overview
    system_summary

    # 2. Thread & Core Usage per User
    echo -e "\n[2] Current Resource Usage per User"
    echo "---------------------------------------------------------------"
    printf "%-20s %-10s %-10s\n" "USER" "THREADS" "CORES"
    ps -eo user:20,nlwp,pcpu --no-headers | awk '{th[$1]+=$2; cpu[$1]+=$3} END {for (u in th) if (th[u] > 1 || cpu[u] > 1) printf "%-20s %-10s %-10.1f\n", u, th[u], cpu[u]/100}' | sort -rnk3 | head -n 10

    # 3. Top Processes (from perf_top)
    echo -e "\n[3] Top Processes by Thread Count"
    echo "---------------------------------------------------------------"
    printf "%-20s %-8s %-6s %-6s %-s\n" "USER" "PID" "NLWP" "CORES" "COMMAND"
    ps -eo user:20,pid,nlwp,pcpu,comm --sort=-nlwp --no-headers | head -n 10 | awk '{
        cores = sprintf("%.1f", $4/100)
        printf "%-20s %-8s %-6s %-6s %s\n", $1, $2, $3, cores, $5
    }'

    # 4. GPU Status (from perf_gpu)
    if command -v nvidia-smi >/dev/null 2>&1; then
        echo -e "\n[4] Current GPU Status"
        echo "---------------------------------------------------------------"
        nvidia-smi --format=csv,noheader --query-gpu=index,name,memory.total,memory.used,utilization.gpu,temperature.gpu
    fi

    # 5. NAS Mount Health (Enhanced)
    echo -e "\n[5] NAS Mount Health Check"
    echo "---------------------------------------------------------------"
    local stacked_mounts=$(findmnt -lnvo TARGET --list | grep "/serverdata/ccshome/" | sort | uniq -d)
    
    # Empty bind-mount check (detects disconnected NAS source)
    local empty_mounts=""
    while read -r mnt; do
        [ -z "$mnt" ] && continue
        if [ ! "$(ls -A "$mnt" 2>/dev/null)" ]; then
            empty_mounts="${empty_mounts}\n - $mnt"
        fi
    done < <(findmnt -lnvo TARGET --list | grep "/serverdata/ccshome/.*/NAS/")

    if [ -n "$stacked_mounts" ]; then
        echo -e "${RED}⚠️  STACKED MOUNTS DETECTED:${NC}"
        echo "$stacked_mounts" | while read -r mnt; do
            local count=$(findmnt -lnvo TARGET --list | grep -F "$mnt" | wc -l)
            echo " - $mnt ($count layers)"
        done
    fi

    if [ -n "$empty_mounts" ]; then
        echo -e "${RED}⚠️  EMPTY BIND-MOUNTS DETECTED (Host disconnected?):${NC}"
        echo -e "$empty_mounts"
    fi
    
    # 6. User Resource Usage (Consolidated from perf_usage)
    echo -e "\n[6] Aggregate Resource Usage per User"
    echo "---------------------------------------------------------------"
    printf "%-15s %-15s %-15s\n" "USER" "CPU (%)" "RAM (%)"
    local USERS=$(ps -eo user | sort -u | grep -v 'USER')
    for u in $USERS; do
        local CPU_USAGE=$(ps -u "$u" -o %cpu --no-headers | awk -v cores="$(nproc)" '{s+=$1} END {printf "%.2f", s/cores}')
        local MEM_USAGE=$(ps -u "$u" -o %mem --no-headers | awk '{s+=$1} END {printf "%.2f", s}')
        if [ -n "$CPU_USAGE" ] && [ -n "$MEM_USAGE" ] && (( $(echo "$CPU_USAGE > 0.1 || $MEM_USAGE > 0.1" | bc -l) )); then
            printf "%-15s %-15.2f %-15.2f\n" "$u" "$CPU_USAGE" "$MEM_USAGE"
        fi
    done
    
    # 7. Recommendations & Corrective Actions
    echo -e "\n[7] Recommended Corrective Actions"
    echo "---------------------------------------------------------------"
    local issues=0
    
    # Check D-state
    local HANGS=$(ps -eo state | grep "^D" | wc -l)
    if [ "$HANGS" -gt 0 ]; then
        echo -e "${YELLOW}  [!] I/O Hangs detected (${HANGS} processes).${NC}"
        echo -e "      👉 Run: ${GREEN}sudo ccs perf stabilize${NC} to clean up hangs."
        issues=$((issues + 1))
    fi

    # Check Throttling
    local t_count=0
    for slice in $(systemctl list-units "user-*.slice" --no-legend | awk '{print $1}'); do
        if [ -f "/sys/fs/cgroup/user.slice/$slice/cpu.stat" ]; then
            local throttled=$(grep "nr_throttled" "/sys/fs/cgroup/user.slice/$slice/cpu.stat" | awk '{print $2}')
            [ "$throttled" -gt 100 ] && t_count=$((t_count + 1))
        fi
    done
    if [ "$t_count" -gt 0 ]; then
        echo -e "${YELLOW}  [!] CPU Throttling detected for ${t_count} user(s).${NC}"
        echo -e "      👉 Run: ${GREEN}sudo ccs perf limits${NC} to increase CPU quotas."
        issues=$((issues + 1))
    fi

    # Check Mounts
    if [ -n "$stacked_mounts" ]; then
        echo -e "${YELLOW}  [!] Stacked bind-mounts detected.${NC}"
        echo -e "      👉 Run: ${GREEN}sudo ccs mount cleanup --all${NC}"
        issues=$((issues + 1))
    fi
    if [ -n "$empty_mounts" ]; then
        echo -e "${YELLOW}  [!] Empty bind-mounts detected (NAS disconnected).${NC}"
        echo -e "      👉 Run: ${GREEN}sudo ccs mount restore${NC} to reconnect."
        issues=$((issues + 1))
    fi

    # Check Disk
    local du=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
    if [ "$du" -gt 85 ]; then
        echo -e "${YELLOW}  [!] Disk / is nearly full ($du%).${NC}"
        echo -e "      👉 Action: Run ${GREEN}sudo ccs perf cleanup${NC} or check large files."
        issues=$((issues + 1))
    fi

    if [ "$issues" -eq 0 ]; then
        echo -e "${GREEN}  ✅ No major issues detected. System is healthy.${NC}"
    fi

    # 8. Reboot History (Last 7 Days)
    echo -e "\n[8] Reboot History (Last 7 Days)"
    echo "---------------------------------------------------------------"
    local now=$(date +%s)
    local week_ago=$((now - 7 * 24 * 3600))
    local boots_7d=0
    while read -r line; do
        # Extract date from journalctl --list-boots format: "... Day YYYY-MM-DD HH:MM:SS ..."
        # Note: format varies by journal version. Let's try to extract the timestamp part.
        local boot_time=$(echo "$line" | grep -oE "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}" | head -1)
        if [ -n "$boot_time" ]; then
            local boot_ts=$(date -d "$boot_time" +%s 2>/dev/null)
            if [ -n "$boot_ts" ] && [ "$boot_ts" -ge "$week_ago" ]; then
                boots_7d=$((boots_7d + 1))
            fi
        fi
    done < <(journalctl --list-boots 2>/dev/null)

    echo "Total Reboots (7d): $boots_7d"
    
    if [ "$boots_7d" -gt 2 ]; then
        echo -e "${YELLOW}⚠️  High reboot frequency detected. Check hardware/power stability.${NC}"
    fi

    # Check last boot termination
    local last_boot_end=$(journalctl -b -1 -n 5 --no-pager 2>/dev/null)
    if [ -n "$last_boot_end" ]; then
        local is_clean=$(echo "$last_boot_end" | grep -Ei "reboot|shutdown|poweroff|stopping|reached target|systemd-logind: System is")
        if [ -n "$is_clean" ]; then
            echo -e "Last Reboot Status: ${GREEN}Clean Shutdown${NC}"
        else
            echo -e "Last Reboot Status: ${RED}Unexpected (Crash/Power Loss)${NC}"
            echo "  -> Last log snippet:"
            echo "$last_boot_end" | sed 's/^/     /'
        fi
    fi

    echo -e "\nDone."
}

perf_top() {
    echo -e "\n[Top 20 Processes by Thread Count (NLWP)]"
    printf "%-20s %-8s %-6s %-6s %s\n" "USER" "PID" "NLWP" "CORES" "COMMAND"
    ps -eo user:20,pid,nlwp,pcpu,args --sort=-nlwp --no-headers | awk '{
        cores = sprintf("%.1f", $4/100)
        printf "%-20s %-8s %-6s %-6s ", $1, $2, $3, cores
        for(i=5;i<=NF;i++) printf "%s ", $i
        printf "\n"
    }' | head -n 20
}

perf_noisy() {
    echo -e "\n[Noisy Neighbors (> $THREAD_THRESHOLD threads)]"
    printf "%-20s %-8s %-6s %-6s %s\n" "USER" "PID" "NLWP" "CORES" "COMMAND"
    ps -eo user:20,pid,nlwp,pcpu,args --sort=-nlwp --no-headers | awk -v thresh=$THREAD_THRESHOLD '$3 > thresh {
        cores = sprintf("%.1f", $4/100)
        printf "%-20s %-8s %-6s %-6s ", $1, $2, $3, cores
        for(i=5;i<=NF;i++) printf "%s ", $i
        printf "\n"
    }' | head -n 20
    if [ $(ps -eo nlwp | awk -v thresh=$THREAD_THRESHOLD '$1 > thresh' | wc -l) -eq 0 ]; then
        echo "No processes exceed the threshold of $THREAD_THRESHOLD threads."
    fi
}

perf_hangs() {
    echo -e "\n[I/O Hang Detection: Processes in Uninterruptible Sleep (D-State)]"
    printf "%-20s %-8s %-s\n" "USER" "PID" "COMMAND"
    local hangs=$(ps -eo state,user:20,pid,args | grep "^D" | grep -v grep)
    if [ -z "$hangs" ]; then echo "No major I/O hangs detected."; else echo "$hangs" | awk '{printf "%-20s %-8s %s\n", $2, $3, $4}'; fi
}

perf_kill() {
    local target=$1
    local interactive=0
    [[ "$*" == *"--interactive"* || "$*" == *"-i"* ]] && interactive=1

    if [ "$interactive" -eq 1 ]; then
        echo -e "\n[Interactive Cleanup Mode]"
        local noisy_procs=$(ps -eo user:20,pid,nlwp,args --sort=-nlwp | awk -v thresh=$THREAD_THRESHOLD -v me=$$ -v u=$(whoami) '($1 == u || u == "root") && $3 > thresh && $2 != me && $1 != "root" {print $2":"$3":"$4}')
        if [ -z "$noisy_procs" ]; then echo "No noisy processes (> $THREAD_THRESHOLD threads) found."; return; fi
        for proc in $noisy_procs; do
            local pid=$(echo $proc | cut -d: -f1); local nlwp=$(echo $proc | cut -d: -f2); local cmd=$(echo $proc | cut -d: -f3)
            echo -n "Kill process $pid ($cmd) with $nlwp threads? [y/N]: "; read confirm
            [[ "$confirm" == [yY] ]] && kill -9 $pid && echo "Killed $pid."
        done
        return
    fi

    local search_pattern
    case "$target" in
        matlab) search_pattern="MATLAB" ;;
        python) search_pattern="python|spyder_kernels" ;;
        servicehost) search_pattern="MathWorksServiceHost" ;;
        aggressive) search_pattern="MATLAB|python|spyder_kernels|MathWorksServiceHost" ;;
        *) 
            if [ -n "$target" ]; then search_pattern="$target"; else
                echo "Usage: ccs perf kill <matlab|python|servicehost|aggressive|PATTERN> [--interactive]"; return 
            fi
            ;;
    esac
    
    local myuser=$(whoami); local procs
    if [ "$myuser" == "root" ]; then
        procs=$(ps -eo user:20,pid,nlwp,args | grep -Ei "$search_pattern" | grep -v grep | grep -v "ccs")
    else
        procs=$(ps -u "$myuser" -o user:20,pid,nlwp,args | grep -Ei "$search_pattern" | grep -v grep | grep -v "ccs")
    fi

    if [ -z "$procs" ]; then echo "No '$target' instances found."; return; fi
    echo "$procs" | awk '{printf "%-20s %-8s %-6s %s\n", $1, $2, $3, $4}'
    echo -n "Kill ALL listed $target processes? [y/N]: "; read confirm
    if [[ "$confirm" == [yY] ]]; then echo "$procs" | awk '{print $2}' | xargs -r kill -9; echo "Cleanup complete."; fi
}


perf_stabilize() {
    echo -e "${BLUE}=== CCS Server Stabilization ===${NC}"
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Root required.${NC}"; return 1; fi

    echo -e "\n[1/3] Updating Resource Limits..."
    perf_limits "$DEFAULT_MEMORY_MAX" "10" "$DEFAULT_TASKS_MAX"

    echo -e "\n[2/3] Cleaning up runaway processes..."
    pkill -9 -f MathWorksServiceHost && echo -e "  - Terminated runaway Matlab service hosts."
    pkill -9 -f xfce4-screensaver && echo -e "  - Terminated hanging screensavers."
    pkill -9 -f xfce4-power-manager && echo -e "  - Terminated hanging power managers."
    pkill -9 -f nvidia-settings && echo -e "  - Terminated hanging nvidia-settings."

    echo -e "\n[3/3] Verifying System State..."
    perf_status
    echo -e "\n${GREEN}✅ Server stabilization complete.${NC}"
}

perf_cleanup() {
    echo -e "${BLUE}=== CCS System Cleanup ===${NC}"
    if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: Root required.${NC}"; return 1; fi
    
    echo "Cleaning up journal logs older than 7 days..."
    journalctl --vacuum-time=7d
    
    echo "Cleaning up temporary files in /tmp..."
    find /tmp -type f -atime +7 -delete 2>/dev/null
    
    echo "Cleaning up stale VNC logs..."
    find /serverdata/ccshome/*/ .vnc/ -name "*.log" -mtime +30 -delete 2>/dev/null
    
    echo -e "${GREEN}Cleanup complete.${NC}"
}

perf_limits() {
    local MEMORY_MAX=$1
    local CPU_QUOTA_PERCENTAGE=$2
    local TASKS_MAX=$3

    if [ -z "$MEMORY_MAX" ]; then
        echo -e "${BLUE}Resource Limit Configuration${NC}"
        read -p "Memory Limit (e.g. 256G) [$DEFAULT_MEMORY_MAX]: " MEMORY_MAX
        MEMORY_MAX=${MEMORY_MAX:-$DEFAULT_MEMORY_MAX}
        read -p "CPU Quota % per user [10]: " CPU_QUOTA_PERCENTAGE
        CPU_QUOTA_PERCENTAGE=${CPU_QUOTA_PERCENTAGE:-10}
        read -p "Tasks (Threads) Max [$DEFAULT_TASKS_MAX]: " TASKS_MAX
        TASKS_MAX=${TASKS_MAX:-$DEFAULT_TASKS_MAX}
    fi

    if ! [[ "$CPU_QUOTA_PERCENTAGE" =~ ^[0-9]+$ ]]; then
        echo "Error: CPU quota must be a whole number (e.g., 10, 50)."
        return 1
    fi

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Setting limits requires root access.${NC}"
        return 1
    fi

    if ! command -v bc >/dev/null 2>&1; then
        echo -e "${RED}Error: 'bc' is not installed. Please install it (sudo apt install bc).${NC}"
        return 1
    fi

    local TOTAL_CORES=$(nproc)
    local CPU_QUOTA_VALUE=$(echo "scale=0; ($CPU_QUOTA_PERCENTAGE * $TOTAL_CORES)" | bc)
    local FINAL_CPU_QUOTA="${CPU_QUOTA_VALUE}%"
    
    local USER_DROPIN="/etc/systemd/system/user-.slice.d"
    local VNC_DROPIN="/etc/systemd/system/vncserver@.service.d"
    local VNC_SLICE_DROPIN="/etc/systemd/system/system-vncserver.slice.d"

    echo "Configuring CPU Quotas ($FINAL_CPU_QUOTA)..."
    mkdir -p "$USER_DROPIN" "$VNC_DROPIN" "$VNC_SLICE_DROPIN"
    
    local CONFIG_CONTENT="[Slice]\nCPUAccounting=yes\nCPUQuota=$FINAL_CPU_QUOTA\nMemoryAccounting=yes\nMemoryMax=$MEMORY_MAX\nTasksAccounting=yes\nTasksMax=$TASKS_MAX"
    local SVC_CONFIG_CONTENT="[Service]\nCPUAccounting=yes\nCPUQuota=$FINAL_CPU_QUOTA\nMemoryAccounting=yes\nMemoryMax=$MEMORY_MAX\nTasksAccounting=yes\nTasksMax=$TASKS_MAX"

    echo -e "$CONFIG_CONTENT" > "$USER_DROPIN/10-resources.conf"
    echo -e "$CONFIG_CONTENT" > "$VNC_SLICE_DROPIN/10-resources.conf"
    echo -e "$SVC_CONFIG_CONTENT" > "$VNC_DROPIN/10-resources.conf"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ Resource limits successfully configured.${NC}"
        echo "CPU Quota:   $FINAL_CPU_QUOTA (~$CPU_QUOTA_VALUE cores)"
        echo "MemoryMax:   $MEMORY_MAX"
        echo "TasksMax:    $TASKS_MAX"
        
        systemctl daemon-reload 2>/dev/null || echo "Warning: daemon-reload timed out, but properties will be applied to active units."
        
        echo "Applying limits to active user and VNC units..."
        # 1. Active User Slices
        for slice in $(systemctl list-units "user-*.slice" --no-legend | awk '{print $1}'); do
            systemctl set-property "$slice" CPUQuota=$FINAL_CPU_QUOTA TasksMax=$TASKS_MAX MemoryMax=$MEMORY_MAX 2>/dev/null
        done
        # 2. Active VNC Services
        for svc in $(systemctl list-units "vncserver@*.service" --no-legend | awk '{print $1}'); do
            systemctl set-property "$svc" CPUQuota=$FINAL_CPU_QUOTA TasksMax=$TASKS_MAX MemoryMax=$MEMORY_MAX 2>/dev/null
        done
    else
        echo -e "${RED}Failed to write configuration files.${NC}"
        return 1
    fi
}


perf_conda_env() {
    if [ -z "$1" ]; then
        echo "Usage: ccs perf conda-env <environment_name>"
        return 1
    fi

    local ENV_NAME=$1
    local CONDA_EXE="${CONDA_PATH}/bin/conda"
    local SOLVER_EXE="${CONDA_PATH}/bin/mamba"
    local YML_FILE="$PYTHON_ENV_YML"
    local REQS_FILE="$PYTHON_REQS_TXT"

    if [ ! -f "$CONDA_EXE" ]; then echo -e "${RED}Error: Conda not found at $CONDA_EXE${NC}"; return 1; fi
    if [ ! -f "$SOLVER_EXE" ]; then SOLVER_EXE=$CONDA_EXE; fi # Fallback to conda if mamba missing

    if $CONDA_EXE env list | grep -q -w "$ENV_NAME"; then
        echo -e "${YELLOW}⚠️ Environment '$ENV_NAME' already exists.${NC}"
        read -p "Overwrite existing environment? [y/N]: " -n 1 -r
        echo
        if [[ $REPLY =~ ^[yY]$ ]]; then
            echo "Removing existing environment..."
            $CONDA_EXE env remove -n "$ENV_NAME" --yes
        else
            echo "Operation cancelled."
            return 0
        fi
    fi

    echo -e "\n▶️  Step 1/2: Creating environment '$ENV_NAME' using $YML_FILE..."
    $SOLVER_EXE env create -f "$YML_FILE" -n "$ENV_NAME"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Failed to create environment.${NC}"
        return 1
    fi

    echo -e "\n▶️  Step 2/2: Installing Pip packages from '$REQS_FILE'..."
    $CONDA_EXE run -n "$ENV_NAME" pip install -r "$REQS_FILE"
    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ Pip install failed. Removing incomplete environment.${NC}"
        $CONDA_EXE env remove -n "$ENV_NAME" --yes
        return 1
    fi

    echo -e "\n${GREEN}✅ Success! Environment '$ENV_NAME' is ready.${NC}"
    echo "Optimizing environment threads..."
    perf_conda_optimize_env "root" "$ENV_NAME"
    echo "To activate: conda activate $ENV_NAME"
}

perf_conda_optimize_env() {
    local u="$1"
    local env_name="$2"
    local conda_exe="${CONDA_PATH}/bin/conda"
    
    if [ "$u" == "root" ]; then
        $conda_exe env config vars set OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 -n "$env_name" >/dev/null 2>&1
    else
        sudo -H -i -u "$u" bash -c "$conda_exe env config vars set OPENBLAS_NUM_THREADS=1 MKL_NUM_THREADS=1 -n '$env_name' >/dev/null 2>&1"
    fi
}

perf_conda_optimize_all() {
    local conda_exe="${CONDA_PATH}/bin/conda"
    echo -e "${BLUE}=== Optimizing ALL Conda Environments for ALL Users ===${NC}"
    
    # 1. Root environments
    for env in $($conda_exe env list | grep '^ ' | awk '{print $1}'); do
        echo "Optimizing system env: $env"
        perf_conda_optimize_env "root" "$env"
    done

    # 2. User environments
    for user_dir in "$BASE_USER_PATH"/*; do
        if [ -d "$user_dir" ]; then
            local u=$(basename "$user_dir")
            echo "Processing user: $u"
            # Get list of environments for this user
            local user_envs=$(sudo -H -i -u "$u" bash -c "$conda_exe env list | grep '^  *' | awk '{print \$1}'" 2>/dev/null)
            for env in $user_envs; do
                echo "  -> Optimizing env: $env"
                perf_conda_optimize_env "$u" "$env"
            done
        fi
    done
    echo -e "${GREEN}✅ All environments optimized.${NC}"
}

perf_conda_user_env() {
    local TARGET_USER="$1"
    local CUSTOM_ENV_NAME="$2"
    local ENV_NAME="${CUSTOM_ENV_NAME:-ccs}"
    local CONDA_EXE="${CONDA_PATH}/bin/conda"
    local SOLVER_EXE="${CONDA_PATH}/bin/mamba"
    local YML_FILE="$PYTHON_ENV_YML"
    local REQS_FILE="$PYTHON_REQS_TXT"

    if [ ! -f "$CONDA_EXE" ]; then echo -e "${RED}Error: Conda not found at $CONDA_EXE${NC}"; return 1; fi
    if [ ! -f "$SOLVER_EXE" ]; then SOLVER_EXE=$CONDA_EXE; fi

    setup_user_env() {
        local u="$1"
        local u_home="$BASE_USER_PATH/$u"
        if [ ! -d "$u_home" ]; then return 0; fi # Skip silently if not a valid home folder
        
        echo -e "${BLUE}=== Configuring local conda env '$ENV_NAME' for user: $u ===${NC}"

        # Initialize conda for user if they don't have it explicitly active
        if ! sudo -H -u "$u" grep -q "miniconda3" "$u_home/.bashrc" 2>/dev/null; then
            echo "Initializing Conda in .bashrc for $u..."
            sudo -H -i -u "$u" bash -c "cd ~ && $CONDA_EXE init bash >/dev/null 2>&1"
        fi

        # Check if environment already exists inside their localized prefix
        if sudo -H -i -u "$u" bash -c "cd ~ && $CONDA_EXE env list | grep -q -w '$ENV_NAME'"; then
            echo -e "${YELLOW}Environment '$ENV_NAME' already exists for $u. Skipping...${NC}"
            return 0
        fi

        echo "Building local environment '$ENV_NAME' for $u (this may take a few minutes)..."
        # Run explicitly wrapped inside bash as the target user to map their exact bashrc / conda configuration
        if sudo -H -i -u "$u" bash -c "cd ~ && $SOLVER_EXE env create -f '$YML_FILE' -n '$ENV_NAME' -q -y"; then
            echo "Installing pip requirements..."
            if sudo -H -i -u "$u" bash -c "cd ~ && $CONDA_EXE run -n '$ENV_NAME' pip install -r '$REQS_FILE' -q"; then
                echo "Optimizing environment threads..."
                perf_conda_optimize_env "$u" "$ENV_NAME"
                echo -e "${GREEN}✅ Success! Environment ready for $u.${NC}"
            else
                echo -e "${RED}❌ Pip install failed for $u.${NC}"
            fi
        else
            echo -e "${RED}❌ Failed to create environment for $u.${NC}"
        fi
        echo "---------------------------------------------------------------"
    }

    if [ "$TARGET_USER" == "--all" ]; then
        if [ "$EUID" -ne 0 ]; then echo -e "${RED}Error: '--all' requires root privileges.${NC}"; return 1; fi
        for user_dir in "$BASE_USER_PATH"/*; do
            [ -d "$user_dir" ] && setup_user_env "$(basename "$user_dir")"
        done
    else
        local the_user="${TARGET_USER:-$(whoami)}"
        if [ -n "$SUDO_USER" ] && [ -z "$TARGET_USER" ]; then the_user="$SUDO_USER"; fi # Default to actual user if running via sudo
        if [ "$EUID" -ne 0 ] && [ "$the_user" != "$(whoami)" ]; then
            echo -e "${RED}Error: Root privileges required to configure for another user.${NC}"
            return 1
        fi
        setup_user_env "$the_user"
    fi
}

perf_conda_init() {
    local shell_rc="$HOME/.bashrc"
    local conda_path="$CONDA_PATH"
    
    echo "Configuring shell initialization for Conda (Miniconda3/Mamba)..."
    if grep -q "miniconda3" "$shell_rc"; then
        echo -e "${YELLOW}⚠️  Conda initialization already exists in $shell_rc.${NC}"
    else
        $conda_path/bin/conda init bash >/dev/null
        echo -e "${GREEN}✅ Shell initialization ADDED to $shell_rc.${NC}"
        echo "Please run 'source $shell_rc' to apply changes to your current session."
    fi
}

perf_spyder_hub() {
    local spyder_exe="${CONDA_PATH}/envs/spyder-hub/bin/spyder"
    
    if [ ! -f "$spyder_exe" ]; then
        echo -e "${RED}Error: Centralized Spyder not found at $spyder_exe${NC}"
        echo "You may need to create the hub: sudo ccs perf conda-env spyder-hub"
        return 1
    fi

    echo -e "${BLUE}===============================================================${NC}"
    echo -e "${BLUE}   CCS Centralized Spyder Hub (v6.0.7)${NC}"
    echo -e "${BLUE}===============================================================${NC}"
    echo "Launching Spyder..."
    nohup "$spyder_exe" >/dev/null 2>&1 &
    
    echo -e "\n${YELLOW}PRO-TIP:${NC}"
    echo "To use your specific environment (e.g., mne, ccs) within this Spyder:"
    echo "  1. Open Spyder Preferences -> Python Interpreter."
    echo "  2. Select 'Use the following Python interpreter'."
    echo "  3. Point it to: /serverdata/miniconda3/envs/<YOUR_ENV>/bin/python"
    echo "---------------------------------------------------------------"
}

perf_gpu() {
    echo "==============================================================="
    echo "  CCS GPU Diagnostic Tool"
    echo "==============================================================="

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo -e "${RED}Error: nvidia-smi not found. NVIDIA drivers may not be installed.${NC}"
        return 1
    fi

    echo -e "\n[1] Current GPU Status"
    echo "---------------------------------------------------------------"
    nvidia-smi --format=csv,noheader --query-gpu=index,name,driver_version,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw,power.limit

    echo -e "\n[2] Detailed Power & Temperature Info"
    echo "---------------------------------------------------------------"
    nvidia-smi -q -d TEMP,POWER | grep -E "GPU|Temperature|Power Draw|Power Limit|Default Applications Clock"

    echo -e "\n[3] Historical Kernel Logs (Recent Errors)"
    echo "---------------------------------------------------------------"
    if command -v journalctl >/dev/null 2>&1; then
        local logs=$(journalctl -k | grep -iE 'nvidia|gpu|nv-char-dev|Xid' | tail -n 20)
        if [ -z "$logs" ]; then echo "No recent GPU-related kernel errors found."; else echo "$logs"; fi
    else
        echo "journalctl not found. Manual check of /var/log/syslog required."
    fi

    echo -e "\n[4] Persistence Mode Status"
    echo "---------------------------------------------------------------"
    nvidia-smi -q | grep -i "Persistence Mode" || echo "Persistence Mode: Unknown"

    echo -e "\nRecommendation: If reboots occur during heavy load, check for 'Xid 79' (GPU fallen off the bus) or 'Xid 61' (Internal micro-controller error) in logs."
}

perf_hw() {
    echo "==============================================================="
    echo "  CCS Hardware Diagnostic Tool (IPMI)"
    echo "==============================================================="

    if ! command -v ipmitool >/dev/null 2>&1; then
        echo -e "${RED}Error: ipmitool not found. Please install it (sudo dnf install ipmitool).${NC}"
        return 1
    fi

    if [ "$EUID" -ne 0 ]; then
        echo -e "${YELLOW}Warning: Some IPMI commands may require root access.${NC}"
    fi

    echo -e "\n[1] System Event Log (Recent hardware events)"
    echo "---------------------------------------------------------------"
    sudo ipmitool sel list | tail -20 || echo "Failed to read SEL"

    echo -e "\n[2] Temperature Status"
    echo "---------------------------------------------------------------"
    sudo ipmitool sdr type Temperature || echo "Failed to read temperatures"

    echo -e "\n[3] Power Supply Status"
    echo "---------------------------------------------------------------"
    sudo ipmitool sdr type "Power Supply" || echo "Failed to read PSU status"

    echo -e "\n[4] Fan Status"
    echo "---------------------------------------------------------------"
    sudo ipmitool sdr type Fan || echo "Failed to read fan status"
}

perf_persistence() {
    local mode=$1
    if [[ "$mode" != "on" && "$mode" != "off" ]]; then
        echo "Usage: ccs perf persistence <on|off>"
        return 1
    fi

    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Error: Controlling persistence mode requires root access.${NC}"
        return 1
    fi

    local status=0
    if [ "$mode" == "on" ]; then
        echo "Enabling GPU Persistence Mode..."
        nvidia-smi -pm 1
        status=$?
    else
        echo "Disabling GPU Persistence Mode..."
        nvidia-smi -pm 0
        status=$?
    fi

    if [ $status -eq 0 ]; then
        echo -e "${GREEN}✅ Persistence Mode set to $mode.${NC}"
    else
        echo -e "${RED}❌ Failed to set Persistence Mode.${NC}"
    fi
}

# ==============================================================================
# MOUNT CATEGORY
# ==============================================================================

mount_setup() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}❌ Error: Directory lookup failed. Please run this command with 'sudo'.${NC}"
        return 1
    fi
    local USERNAME=$1; local TARGET_DIR_NAME=$2; local SOURCE_DIR_NAME=$3; local ACCESS_TYPE=$4; local PERSISTENT_FLAG=$5
    
    if [ -z "$USERNAME" ]; then
        echo -e "${BLUE}=== Interactive Mount Setup ===${NC}"
        USERNAME=$(select_user "Select user for the mount") || return 1
        
        echo -e "\nSelect access type:"
        echo "  1) Read Only (from $READ_ACCESS_PATH)"
        echo "  2) Full Access (from $FULL_ACCESS_PATH)"
        read -p "Choice [1-2]: " acc_choice
        case "$acc_choice" in
            1) ACCESS_TYPE="read"; base_source=$READ_ACCESS_PATH ;;
            2) ACCESS_TYPE="full"; base_source=$FULL_ACCESS_PATH ;;
            *) echo "Invalid choice."; return 1 ;;
        esac

        SOURCE_DIR_NAME=$(select_folder "$base_source" "Select initial source folder") || return 1
        local current_rel_path="$SOURCE_DIR_NAME"
        local default_target_name=$(basename "$SOURCE_DIR_NAME")

        while true; do
            local full_path="${base_source}/${current_rel_path}"
            # Check if there are subfolders
            if [ $(ls -d "$full_path"/*/ 2>/dev/null | wc -l) -eq 0 ]; then
                break
            fi
            
            echo -e "\n${BLUE}Current selection: ${current_rel_path}${NC}" >&2
            if ! confirm_action "Navigate deeper into subfolders?"; then
                break
            fi
            
            local sub_folder=$(select_folder "$full_path" "Select subfolder in $current_rel_path")
            if [ $? -ne 0 ]; then break; fi
            
            current_rel_path="${current_rel_path}/${sub_folder}"
            default_target_name=$sub_folder
        done
        SOURCE_DIR_NAME="$current_rel_path"

        echo -e "\n${BLUE}--- Mount Naming ---${NC}" >&2
        while true; do
            read -p "Target folder name in NAS/ [$default_target_name]: " TARGET_DIR_NAME
            TARGET_DIR_NAME=${TARGET_DIR_NAME:-$default_target_name}
            
            # Defensive check for accidental y/n naming
            if [[ "$TARGET_DIR_NAME" == "y" || "$TARGET_DIR_NAME" == "n" ]]; then
                if confirm_action "Are you sure you want to name the folder '$TARGET_DIR_NAME'?"; then
                    break
                fi
            else
                break
            fi
        done
        
        confirm_action "Make mount persistent in fstab?" && PERSISTENT_FLAG="--persistent"
    fi

    if [[ $EUID -ne 0 ]]; then echo "Error: This script must be run as root."; return 1; fi

    local RAW_SOURCE; case "$ACCESS_TYPE" in
        read) RAW_SOURCE="${READ_ACCESS_PATH}/${SOURCE_DIR_NAME}" ;;
        full) RAW_SOURCE="${FULL_ACCESS_PATH}/${SOURCE_DIR_NAME}" ;;
        *) mount_usage ;;
    esac

    local SOURCE_PATH=$(readlink -f "$RAW_SOURCE"); local TARGET_PATH=$(readlink -f "${BASE_USER_PATH}/${USERNAME}/NAS")/"$TARGET_DIR_NAME"
    
    # Safety check: Ensure source is not empty
    if [ ! -d "$SOURCE_PATH" ] || [ ! "$(ls -A "$SOURCE_PATH" 2>/dev/null)" ]; then
        echo -e "${RED}Error: Source directory is empty or does not exist: $SOURCE_PATH${NC}"
        echo "Please ensure the NAS is correctly mounted before proceeding."
        return 1
    fi

    if [[ "$TARGET_PATH" == "$SOURCE_PATH"* ]] || [[ "$SOURCE_PATH" == "$TARGET_PATH"* ]]; then echo "Error: Recursive mounting detected!"; return 1; fi

    mkdir -p "$TARGET_PATH"; chown "$USERNAME:$USERNAME" "$TARGET_PATH"
    
    # Robust check for existing mounts (including stacked ones)
    if mountpoint -q "$TARGET_PATH"; then
        local CURRENT_MOUNT_SOURCE=$(findmnt -n -o SOURCE "$TARGET_PATH" 2>/dev/null)
        if [[ "$CURRENT_MOUNT_SOURCE" == *"${SOURCE_PATH}"* ]] || [[ "$(readlink -f "$CURRENT_MOUNT_SOURCE")" == "$SOURCE_PATH" ]]; then
            echo "SUCCESS: Correct source already mounted."
        else
            echo "WARNING: Target occupied by different mount ($CURRENT_MOUNT_SOURCE)."
            return 1
        fi
    else
        mount --bind "$SOURCE_PATH" "$TARGET_PATH" && echo "Mount successful." || { echo "FAILED to mount."; return 1; }
    fi

    if [ "$PERSISTENT_FLAG" == "--persistent" ]; then
        local FSTAB_ENTRY="${SOURCE_PATH} ${TARGET_PATH} none bind 0 0"
        if grep -qF -- "$TARGET_PATH" /etc/fstab; then
            grep -qF -- "$FSTAB_ENTRY" /etc/fstab && echo "fstab is already correct." || echo "ALERT: fstab mismatch."
        else
            echo "$FSTAB_ENTRY" >> /etc/fstab && echo "Added to /etc/fstab."
            systemctl daemon-reload
        fi
    fi
}

mount_remove() {
    local USERNAME=$1; local TARGET_DIR_NAME=$2
    
    if [ -z "$USERNAME" ]; then
        echo -e "${BLUE}=== Interactive Mount Removal ===${NC}"
        USERNAME=$(select_user "Select user to remove mounts from") || return 1
    fi

    if [ -z "$TARGET_DIR_NAME" ]; then
        TARGET_DIR_NAME=$(select_active_mount "$USERNAME") || return 1
    fi

    if [[ $EUID -ne 0 ]]; then echo "Error: This script must be run as root."; return 1; fi

    local USER_NAS_DIR="${BASE_USER_PATH}/${USERNAME}/NAS"

    remove_single_mount() {
        local target_name=$1
        local target_path="${USER_NAS_DIR}/${target_name}"
        
        while mountpoint -q "$target_path"; do
            echo "Unmounting $target_path layer..."
            umount -l "$target_path" || { echo "Failed to unmount $target_path"; break; }
        done

        # Remove fstab entry
        local FSTAB_LINE_TO_DELETE=$(grep -Fw "$target_path" /etc/fstab)
        if [ -n "$FSTAB_LINE_TO_DELETE" ]; then
            sed -i.bak "\#${target_path}#d" /etc/fstab && echo " - FSTAB Entry REMOVED."
        fi

        # Remove directory if empty
        if [ -d "$target_path" ] && [ -z "$(ls -A "$target_path")" ]; then
            rm -rf "$target_path" && echo " - Directory REMOVED."
        fi
    }

    if [ "$TARGET_DIR_NAME" == "--all" ]; then
        echo "Removing ALL mounts for user $USERNAME..."
        while IFS= read -r -d $'\0' dir; do
            if mountpoint -q "$dir"; then
                remove_single_mount "$(basename "$dir")"
            fi
        done < <(find "$USER_NAS_DIR" -maxdepth 1 -mindepth 1 -type d -print0)
    else
        remove_single_mount "$TARGET_DIR_NAME"
    fi
    systemctl daemon-reload
}


mount_flush() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Error: Root required for mount flush.${NC}"; return 1; fi
    echo -e "${BLUE}=== Deep Flush: Clearing ALL NAS-related mounts ===${NC}"
    
    # Identify and stop systemd mount/automount units to prevent reactive remounting
    echo -n "Stopping systemd mount units... "
    # Get all mount/automount units for user NAS folders
    local units=$(systemctl list-units --type=mount,automount --all --no-legend "serverdata-ccshome-*" | awk '{print $1}')
    if [ -n "$units" ]; then
        echo "$units" | xargs -r sudo systemctl stop >/dev/null 2>&1
    fi
    echo "DONE."

    # 1. Exhaustive Unmount (Multi-pass to handle deep stacking)
    echo -n "Flushing user home mounts (multi-pass)... "
    for i in {1..20}; do
        # Use findmnt for more robust path detection (handles spaces better)
        local mnts=$(findmnt -lnvo TARGET | grep "/serverdata/ccshome/" | grep "/NAS/" | sort -r)
        if [ -z "$mnts" ]; then break; fi
        echo "$mnts" | xargs -r -n1 sudo umount -l 2>/dev/null
        sleep 0.2
    done
    echo "DONE."

    # 2. Unmount global NAS category mounts
    echo -n "Flushing base NAS category mounts... "
    for p in /NAS/fullaccess /NAS/readaccess /NAS_all; do
        for i in {1..5}; do
            local mnts=$(findmnt -lnvo TARGET | grep "$p" | sort -r)
            if [ -z "$mnts" ]; then break; fi
            echo "$mnts" | xargs -r -n1 sudo umount -l 2>/dev/null
            sleep 0.2
        done
    done
    echo "DONE."

    sudo systemctl daemon-reload
    echo "Filesystem state reset."
}


mount_restore() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Error: Root required for mount restore.${NC}"; return 1; fi
    echo -e "${BLUE}=== CCS Mount Restoration (Troubleshooting) ===${NC}"
    echo "This will unmount all NAS/Bind layers and attempt a clean reconstruction."
    
    # 1. Exhaustive Unmount
    echo -e "\n[1/4] Clearing all active layers..."
    mount_flush
    
    # 2. Sync with fstab
    echo -e "\n[2/4] Reloading systemd configuration..."
    sudo systemctl daemon-reload
    
    # 3. Mount CIFS Base Categories first (ordered)
    echo -e "\n[3/4] Validating and Mounting NAS Base shares..."
    # Get all CIFS mount points from fstab
    local cifs_points=$(grep "cifs" /etc/fstab | awk '{print $2}')
    local all_good=1
    for p in $cifs_points; do
        echo -n "  -> Mounting $p... "
        # Attempt to mount
        sudo mount "$p" 2>/dev/null
        # Verify it's actually mounted and NOT EMPTY
        if mountpoint -q "$p" && [ "$(ls -A "$p" 2>/dev/null)" ]; then
            echo -e "${GREEN}SUCCESS (Populated)${NC}"
        else
            echo -e "${RED}FAILED or EMPTY${NC}"
            all_good=0
        fi
    done
    
    # 4. Mount Bindings
    if [ $all_good -eq 1 ]; then
        echo -e "\n[4/4] Restoring Bind Mounts..."
        sudo mount -a
        echo -e "${GREEN}✅ Restoration complete.${NC}"
    else
        echo -e "\n${YELLOW}⚠️  Warning: Some base NAS shares are not ready. Skipped bind-mount restoration to prevent empty mounts.${NC}"
        echo "Please check NAS server connectivity (10.11.33.135) and try again."
    fi
    
    echo -e "\n[Final Status]"
    perf_status | grep -A 20 "NAS Mount Health Check"
}

mount_auto_fix() {
    if [[ $EUID -ne 0 ]]; then echo -e "${RED}Error: Root required for auto-fix.${NC}"; return 1; fi
    local LOG_FILE="/var/log/ccs-auto-fix.log"
    echo "--- CCS Auto-Fix Check: $(date) ---" | tee -a "$LOG_FILE"
    
    # 1. Check for issues using findmnt
    local stacked=$(findmnt -lnvo TARGET --list | grep "/serverdata/ccshome/" | sort | uniq -d)
    
    # Check for empty bind mounts (ignoring those that shouldn't be there yet)
    local empty_mounts=$(findmnt -lnvo TARGET --list | grep "/serverdata/ccshome/.*/NAS/" | while read -r mnt; do 
        [ -z "$mnt" ] && continue
        if [ ! "$(ls -A "$mnt" 2>/dev/null)" ]; then
            echo "$mnt"
        fi
    done)

    if [ -n "$stacked" ] || [ -n "$empty_mounts" ]; then
        echo "[ACTION REQUIRED] Found issues:" | tee -a "$LOG_FILE"
        [ -n "$stacked" ] && echo "  - Stacked: $(echo "$stacked" | tr '\n' ' ')" | tee -a "$LOG_FILE"
        [ -n "$empty_mounts" ] && echo "  - Empty: $(echo "$empty_mounts" | tr '\n' ' ')" | tee -a "$LOG_FILE"
        echo "Performing safe restoration..." | tee -a "$LOG_FILE"
        mount_restore >> "$LOG_FILE" 2>&1
    else
        echo "[HEALTHY] No stacked or empty bind-mounts detected." | tee -a "$LOG_FILE"
    fi
    
    # 2. Monitor I/O hangs
    local hangs=$(ps -eo state,user:20,pid,comm | grep "^D" | grep -v grep)
    if [ -n "$hangs" ]; then
        echo "[WARNING] I/O Hangs detected (D-state processes):" | tee -a "$LOG_FILE"
        echo "$hangs" | tee -a "$LOG_FILE"
    fi
}



mount_cleanup() {
    if [[ $EUID -ne 0 ]]; then echo "Error: Must be run as root."; return 1; fi
    if [ "$#" -lt 1 ]; then mount_usage; fi
    local TARGET_ARG=$1

    cleanup_user_inner() {
        local USERNAME=$1
        local USER_NAS_DIR="${BASE_USER_PATH}/${USERNAME}/NAS"
        if [ ! -d "$USER_NAS_DIR" ]; then return; fi

        echo "--- Cleaning up NAS for user: $USERNAME ---"
        # 1. Clean up stale/unmounted folders that have fstab entries
        find "$USER_NAS_DIR" -type d -print0 2>/dev/null | while IFS= read -r -d $'\0' target_path; do
            if ! mountpoint -q "$target_path" && [ "$target_path" != "$USER_NAS_DIR" ]; then
                local FSTAB_LINE_TO_DELETE=$(grep -Fw "$target_path" /etc/fstab)
                if [ -n "$FSTAB_LINE_TO_DELETE" ]; then
                    echo "[UNMOUNTED FOUND] Target: $target_path"
                    sed -i "\#${target_path}#d" /etc/fstab && echo " - FSTAB Entry REMOVED."
                fi
            fi
        done

        # 2. Deep unmount ALL layers for every folder in the NAS
        echo "Exhaustive unmount check for $USER_NAS_DIR..."
        find "$USER_NAS_DIR" -mindepth 1 -maxdepth 2 -type d | while read -r p; do
            [ -z "$p" ] && continue
            local layers=0
            while mountpoint -q "$p"; do
                umount -l "$p" || break
                ((layers++))
            done
            [ $layers -gt 0 ] && echo " - Unmounted $layers layer(s) from $(basename "$p")"
        done

        # 3. Recursively remove ALL empty directories in the NAS folder
        echo "Cleaning up empty directories in $USER_NAS_DIR..."
        find "$USER_NAS_DIR" -depth -mindepth 1 -type d | while IFS= read -r dir; do
            if [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] && ! mountpoint -q "$dir" 2>/dev/null; then
                rmdir "$dir" 2>/dev/null && echo " - Empty directory removed: $(basename "$dir")"
            fi
        done

        # 4. Recreate any missing mount points from fstab to ensure mount -a succeeds
        grep "$USER_NAS_DIR" /etc/fstab | awk '{print $2}' | while read -r mnt; do
            if [ ! -d "$mnt" ]; then
                mkdir -p "$mnt" && echo " - Restored missing mount point: $(basename "$mnt")"
            fi
        done
    }

    if [ "$TARGET_ARG" == "--all" ]; then
        echo "Performing Deep Flush of ALL NAS mounts..."
        mount_flush
        echo "Cleaning up stale directories for ALL users..."
        while IFS= read -r -d $'\0' user_home; do
            local user=$(basename "$user_home")
            if [ -d "${user_home}/NAS" ]; then
                cleanup_user_inner "$user"
            fi
        done < <(find "${BASE_USER_PATH}" -maxdepth 1 -mindepth 1 -type d -print0)
    else
        cleanup_user_inner "$TARGET_ARG"
    fi

    mount -a
    systemctl daemon-reload
    echo "Done."
}

# ==============================================================================
# USER CATEGORY
# ==============================================================================

user_usage() {
    echo "Usage: ccs user <command> [args]"
    echo ""
    echo "Commands:"
    echo "  sudo list             List all users with sudo privileges"
    echo "  sudo add <user>       Add a user to the sudo group"
    echo "  sudo remove <user>    Remove a user from the sudo group"
    echo ""
}

user_sudo() {
    if [[ $EUID -ne 0 ]]; then echo "Error: Must be run as root."; return 1; fi
    local sub_cmd=$1
    local target_user=$2

    # Identify the administrative group (usually 'wheel' on RHEL/Alma, 'sudo' on Debian/Ubuntu)
    local admin_group="wheel"
    if ! grep -q "^${admin_group}:" /etc/group; then
        admin_group="sudo"
    fi

    case "$sub_cmd" in
        list)
            echo -e "\n[Sudo Users (Group: $admin_group)]"
            echo "---------------------------------------------------------------"
            grep "^${admin_group}:.*$" /etc/group | cut -d: -f4 | sed 's/,/\n/g' | sort
            ;;
        add)
            if [ -z "$target_user" ]; then
                read -p "Enter username to add to $admin_group: " target_user
            fi
            if id "$target_user" >/dev/null 2>&1; then
                usermod -aG "$admin_group" "$target_user" && echo "✅ User '$target_user' added to $admin_group group."
            else
                echo "❌ Error: User '$target_user' does not exist."
                return 1
            fi
            ;;
        remove)
            if [ -z "$target_user" ]; then
                read -p "Enter username to remove from $admin_group: " target_user
            fi
            if id "$target_user" >/dev/null 2>&1; then
                echo -n "⚠️  Are you sure you want to remove '$target_user' from $admin_group? [y/N]: "
                read confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    gpasswd -d "$target_user" "$admin_group" && echo "✅ User '$target_user' removed from $admin_group group."
                else
                    echo "Aborted."
                fi
            else
                echo "❌ Error: User '$target_user' does not exist."
                return 1
            fi
            ;;
        *)
            user_usage
            ;;
    esac
}

# ==============================================================================
# NETWORK CATEGORY
# ==============================================================================

net_info() {
    echo "==============================================================="
    echo "  CCS Network Diagnostic Tool"
    echo "==============================================================="

    echo -e "\n[1] Connectivity & Latency"
    echo "---------------------------------------------------------------"
    local gateway=$(ip route | grep default | awk '{print $3}' | head -n 1)
    if [ -n "$gateway" ]; then
        echo -n "Internal Gateway ($gateway): "
        ping -c 3 -W 2 "$gateway" >/dev/null 2>&1 && echo -e "${GREEN}REACHABLE${NC}" || echo -e "${RED}UNREACHABLE${NC}"
    else
        echo "Internal Gateway: NOT FOUND"
    fi

    echo -n "External (8.8.8.8):        "
    ping -c 3 -W 2 8.8.8.8 >/dev/null 2>&1 && echo -e "${GREEN}REACHABLE${NC}" || echo -e "${RED}UNREACHABLE${NC}"

    echo -e "\n[2] DNS Resolution Speed"
    echo "---------------------------------------------------------------"
    if command -v dig >/dev/null 2>&1; then
        local dns_time=$( (time -p dig google.com +stats +short >/dev/null) 2>&1 | grep real | awk '{print $2}')
        echo "Resolve 'google.com': ${dns_time}s"
        if (( $(echo "$dns_time > 1.0" | bc -l) )); then
            echo -e "${YELLOW}⚠️  Warning: DNS resolution is slow (>1s)${NC}"
        fi
    else
        echo "dig not found. Skipping DNS speed test."
    fi

    echo -e "\n[3] Interface Statistics"
    echo "---------------------------------------------------------------"
    ip -s link | grep -A 1 "^[0-9]"

    echo -e "\n[4] Connection Summary"
    echo "---------------------------------------------------------------"
    if command -v ss >/dev/null 2>&1; then
        ss -s
    else
        netstat -ant | awk 'NR>2 {print $6}' | sort | uniq -c
    fi
}

net_latency() {
    local gateway=$(ip route | grep default | awk '{print $3}' | head -n 1)
    echo "Latency to Gateway ($gateway):"
    [ -n "$gateway" ] && ping -c 10 "$gateway" || echo "Gateway not found."
    echo -e "\nLatency to External (8.8.8.8):"
    ping -c 10 8.8.8.8
}

net_dns() {
    echo "Testing DNS resolution for 'google.com' 5 times..."
    for i in {1..5}; do
        (time -p dig google.com +short >/dev/null) 2>&1 | grep real
    done
}

net_stats() {
    echo "Interface Statistics (ip -s link):"
    ip -s link
}

net_monitor() {
    echo -e "${BLUE}=== CCS Real-time Network Monitor ===${NC}"
    echo "Pinging NAS ($NAS_IP) - Press Ctrl+C to stop"
    printf "%-25s %-10s %-s\n" "TIMESTAMP" "LATENCY" "STATUS"
    while true; do
        local ts=$(date "+%Y-%m-%d %H:%M:%S")
        local ping_out=$(ping -c 1 -W 1 "$NAS_IP" 2>/dev/null)
        if [ $? -eq 0 ]; then
            local latency=$(echo "$ping_out" | grep 'time=' | awk -F'time=' '{print $2}' | awk '{print $1}')
            echo -e "$ts  ${GREEN}$latency ms${NC}  REACHABLE"
        else
            echo -e "$ts  ${RED}TIMEOUT${NC}    UNREACHABLE"
            # Log failure to dmesg for root traceability
            [ "$EUID" -eq 0 ] && echo "CCS_MONITOR: NAS $NAS_IP unreachable at $ts" > /dev/kmsg
        fi
        
        # Check for CIFS errors in last 10 lines of dmesg
        local cifs_err=$(dmesg | tail -n 20 | grep -iE "cifs|stale|timeout" | tail -n 1)
        if [ -n "$cifs_err" ]; then
            echo -e "${YELLOW}Latest CIFS Event: $cifs_err${NC}"
        fi
        
        sleep 5
    done
}

# ==============================================================================
# MAIN ROUTING
# ==============================================================================

CATEGORY=$1
ACTION=$2
shift 2

case "$CATEGORY" in
    vnc)
        case "$ACTION" in
            add|setup) vnc_add "$@" ;;
            info|check) vnc_info "$@" ;;
            health) vnc_health "$@" ;;
            switch) vnc_switch "$@" ;;
            optimize) vnc_optimize "$@" ;;
            boost) vnc_boost "$@" ;;
            troubleshoot) vnc_troubleshoot "$@" ;;
            start) vnc_start "$@" ;;
            remove) vnc_remove "$@" ;;
            help|"") vnc_usage ;;
            *) echo -e "${RED}Unknown VNC action: $ACTION${NC}"; vnc_usage ;;
        esac
        ;;
    perf)
        case "$ACTION" in
            status|usage) perf_status "$@" ;;
            stabilize) perf_stabilize "$@" ;;
            top) perf_top "$@" ;;
            noisy) perf_noisy "$@" ;;
            hangs) perf_hangs "$@" ;;
            kill) perf_kill "$@" ;;
            cleanup) perf_cleanup "$@" ;;
            limits) perf_limits "$@" ;;
            conda-env) perf_conda_env "$@" ;;
            conda-user-env) perf_conda_user_env "$@" ;;
            conda-optimize) perf_conda_optimize_env "$@" ;;
            conda-optimize-all) perf_conda_optimize_all "$@" ;;
            conda-init) perf_conda_init "$@" ;;
            spyder-hub) perf_spyder_hub "$@" ;;
            gpu) perf_gpu "$@" ;;
            hw) perf_hw "$@" ;;
            persistence) perf_persistence "$@" ;;
            help|"") perf_actions ;;
            *) echo -e "${RED}Unknown Performance action: $ACTION${NC}"; perf_actions ;;
        esac
        ;;
    mount)
        case "$ACTION" in
            setup) mount_setup "$@" ;;
            remove) mount_remove "$@" ;;
            cleanup) 
                echo "Deep cleanup of stacked mounts..."
                mount_cleanup "$@" 
                ;;
            flush)
                mount_flush
                ;;
            restore)
                mount_restore
                ;;
            auto-fix)
                mount_auto_fix
                ;;
            help|"") mount_usage ;;
            *) echo -e "${RED}Unknown Mount action: $ACTION${NC}"; mount_usage ;;
        esac
        ;;
    net)
        case "$ACTION" in
            info) net_info "$@" ;;
            latency) net_latency "$@" ;;
            dns) net_dns "$@" ;;
            stats) net_stats "$@" ;;
            monitor) net_monitor "$@" ;;
            help|"") net_usage ;;
            *) echo -e "${RED}Unknown Network action: $ACTION${NC}"; net_usage ;;
        esac
        ;;
    user)
        case "$ACTION" in
            sudo) user_sudo "$@" ;;
            help|"") user_usage ;;
            *) echo -e "${RED}Unknown User action: $ACTION${NC}"; user_usage ;;
        esac
        ;;
    help|""|*)
        ccs_full_help
        ;;
esac
