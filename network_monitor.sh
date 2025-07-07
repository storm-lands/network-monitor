#!/bin/bash

# Network Monitoring Script
# This script uses ifstat to monitor network traffic and send data to a main server

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration file paths
CONFIG_DIR="$HOME/.network_monitor"
CONFIG_FILE="$CONFIG_DIR/config.json"
MAIN_SERVER_FILE="$CONFIG_DIR/main_server.txt"
MONITORING_STATUS_FILE="$CONFIG_DIR/monitoring_status.txt"

# Create configuration directory if it doesn't exist
mkdir -p "$CONFIG_DIR"

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to install required dependencies
install_dependencies() {
    echo -e "${YELLOW}Checking and installing required dependencies...${NC}"
    
    # Check if we're running as root, if not, use sudo
    SUDO=""
    if [ "$(id -u)" -ne 0 ]; then
        SUDO="sudo"
    fi
    
    # Check and install ifstat
    if ! command_exists ifstat; then
        echo -e "${YELLOW}Installing ifstat...${NC}"
        if command_exists apt-get; then
            $SUDO apt-get update && $SUDO apt-get install -y ifstat
        elif command_exists yum; then
            $SUDO yum install -y ifstat
        elif command_exists dnf; then
            $SUDO dnf install -y ifstat
        elif command_exists pacman; then
            $SUDO pacman -S --noconfirm ifstat
        else
            echo -e "${RED}Error: Could not install ifstat. Please install it manually.${NC}"
            exit 1
        fi
    fi
    
    # Check and install curl
    if ! command_exists curl; then
        echo -e "${YELLOW}Installing curl...${NC}"
        if command_exists apt-get; then
            $SUDO apt-get update && $SUDO apt-get install -y curl
        elif command_exists yum; then
            $SUDO yum install -y curl
        elif command_exists dnf; then
            $SUDO dnf install -y curl
        elif command_exists pacman; then
            $SUDO pacman -S --noconfirm curl
        else
            echo -e "${RED}Error: Could not install curl. Please install it manually.${NC}"
            exit 1
        fi
    fi
    
    # Check and install jq for JSON parsing
    if ! command_exists jq; then
        echo -e "${YELLOW}Installing jq...${NC}"
        if command_exists apt-get; then
            $SUDO apt-get update && $SUDO apt-get install -y jq
        elif command_exists yum; then
            $SUDO yum install -y jq
        elif command_exists dnf; then
            $SUDO dnf install -y jq
        elif command_exists pacman; then
            $SUDO pacman -S --noconfirm jq
        else
            echo -e "${RED}Error: Could not install jq. Please install it manually.${NC}"
            exit 1
        fi
    fi
    
    echo -e "${GREEN}All dependencies installed successfully!${NC}"
}

# Function to check if this server is the main server
is_main_server() {
    if [ -f "$MAIN_SERVER_FILE" ] && [ "$(cat "$MAIN_SERVER_FILE")" = "true" ]; then
        return 0 # True
    else
        return 1 # False
    fi
}

# Function to get the main server IP
get_main_server_ip() {
    if [ -f "$CONFIG_FILE" ]; then
        jq -r '.main_server_ip' "$CONFIG_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Function to check if monitoring is active
is_monitoring_active() {
    if [ -f "$MONITORING_STATUS_FILE" ] && [ "$(cat "$MONITORING_STATUS_FILE")" = "active" ]; then
        return 0 # True
    else
        return 1 # False
    fi
}

# Function to set monitoring status
set_monitoring_status() {
    echo "$1" > "$MONITORING_STATUS_FILE"
}

# Function to get server list from config
get_server_list() {
    if [ -f "$CONFIG_FILE" ]; then
        jq -r '.server_list[]' "$CONFIG_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# Function to add server to server list
add_server_to_list() {
    local server_ip="$1"
    
    # Create config file with empty server list if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"main_server_ip":"", "server_list":[], "db_status":"inactive"}' > "$CONFIG_FILE"
    fi
    
    # Check if server is already in the list
    if jq -e ".server_list | index(\"$server_ip\")" "$CONFIG_FILE" >/dev/null; then
        echo -e "${YELLOW}Server $server_ip is already in the list.${NC}"
        return
    fi
    
    # Add server to the list
    jq ".server_list += [\"$server_ip\"]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "${GREEN}Server $server_ip added to the list.${NC}"
}

# Function to remove server from server list
remove_server_from_list() {
    local server_ip="$1"
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${RED}Config file does not exist.${NC}"
        return
    fi
    
    # Remove server from the list
    jq ".server_list -= [\"$server_ip\"]" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "${GREEN}Server $server_ip removed from the list.${NC}"
}

# Function to set this server as the main server
set_as_main_server() {
    echo "true" > "$MAIN_SERVER_FILE"
    
    # Get local IP address
    local_ip=$(hostname -I | awk '{print $1}')
    
    # Create or update config file
    if [ -f "$CONFIG_FILE" ]; then
        jq ".main_server_ip = \"$local_ip\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        echo "{\"main_server_ip\":\"$local_ip\", \"server_list\":[], \"db_status\":\"inactive\"}" > "$CONFIG_FILE"
    fi
    
    echo -e "${GREEN}This server has been set as the main server with IP: $local_ip${NC}"
}

# Function to set another server as the main server
set_another_main_server() {
    echo "false" > "$MAIN_SERVER_FILE"
    
    read -p "Enter the main server IP address: " main_server_ip
    
    # Create or update config file
    if [ -f "$CONFIG_FILE" ]; then
        jq ".main_server_ip = \"$main_server_ip\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    else
        echo "{\"main_server_ip\":\"$main_server_ip\", \"server_list\":[], \"db_status\":\"inactive\"}" > "$CONFIG_FILE"
    fi
    
    echo -e "${GREEN}Main server set to: $main_server_ip${NC}"
}

# Function to start monitoring and sending data to main server
start_monitoring() {
    local main_server_ip=$(get_main_server_ip)
    
    if [ -z "$main_server_ip" ]; then
        echo -e "${RED}Error: Main server IP is not set. Please set a main server first.${NC}"
        return
    fi
    
    set_monitoring_status "active"
    echo -e "${GREEN}Monitoring started. Sending data to main server: $main_server_ip${NC}"
    
    # Start monitoring in background
    nohup bash -c '
        while true; do
            if [ -f "'"$MONITORING_STATUS_FILE"'" ] && [ "$(cat "'"$MONITORING_STATUS_FILE"'")" = "active" ]; then
                # Get server hostname and IP
                hostname=$(hostname)
                ip=$(hostname -I | awk "{print \$1}")
                
                # Get network stats using ifstat (1 second sample)
                ifstat_output=$(ifstat -i "$(ip route | grep default | awk "{print \$5}")" -b 1 1 | tail -1)
                in_traffic=$(echo "$ifstat_output" | awk "{print \$1}")
                out_traffic=$(echo "$ifstat_output" | awk "{print \$2}")
                
                # Send data to main server
                curl -s -X POST "http://$(cat "'"$CONFIG_DIR/config.json"'" | jq -r ".main_server_ip"):5000/report" \
                     -H "Content-Type: application/json" \
                     -d "{\
                        \"hostname\": \"$hostname\",\
                        \"ip\": \"$ip\",\
                        \"in_traffic\": $in_traffic,\
                        \"out_traffic\": $out_traffic,\
                        \"timestamp\": \"$(date +"%Y-%m-%d %H:%M:%S\")\
                     }" >/dev/null 2>&1
                
                sleep 5
            else
                break
            fi
        done
    ' > /dev/null 2>&1 &
}

# Function to stop monitoring
stop_monitoring() {
    set_monitoring_status "inactive"
    echo -e "${YELLOW}Monitoring stopped.${NC}"
    # Give some time for the background process to exit
    sleep 1
}

# Function to display server state (for non-main server)
display_server_state() {
    if is_monitoring_active; then
        echo -e "${GREEN}Monitoring Status: Active${NC}"
        echo -e "${BLUE}Sending data to main server: $(get_main_server_ip)${NC}"
        
        # Display current network stats
        echo -e "\n${CYAN}Current Network Traffic:${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        echo -e "${CYAN}Interface | Download (KB/s) | Upload (KB/s)${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        
        # Get default interface
        default_interface=$(ip route | grep default | awk '{print $5}')
        
        # Use ifstat to get real-time stats
        ifstat -i "$default_interface" -b 1 1 | tail -1 | while read in_traffic out_traffic; do
            echo -e "${CYAN}$default_interface | $in_traffic | $out_traffic${NC}"
        done
        echo -e "${CYAN}---------------------------------------------------${NC}"
    else
        echo -e "${YELLOW}Monitoring Status: Inactive${NC}"
    fi
}

# Function to display server state (for main server)
display_main_server_state() {
    echo -e "${GREEN}Main Server Status: Active${NC}"
    
    # Check if database saving is active
    db_status=$(jq -r '.db_status' "$CONFIG_FILE" 2>/dev/null || echo "inactive")
    if [ "$db_status" = "active" ]; then
        echo -e "${GREEN}Database Saving: Active${NC}"
    else
        echo -e "${YELLOW}Database Saving: Inactive${NC}"
    fi
    
    # Display server list
    echo -e "\n${CYAN}Connected Servers:${NC}"
    echo -e "${CYAN}---------------------------------------------------${NC}"
    echo -e "${CYAN}IP Address | Download (KB/s) | Upload (KB/s) | Last Update${NC}"
    echo -e "${CYAN}---------------------------------------------------${NC}"
    
    # This would normally display data from the database, but for now we'll just show a placeholder
    echo -e "${CYAN}Data will be displayed when servers start reporting${NC}"
    echo -e "${CYAN}---------------------------------------------------${NC}"
}

# Function to start saving data to database
start_db_saving() {
    jq ".db_status = \"active\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "${GREEN}Database saving started.${NC}"
}

# Function to stop saving data to database
stop_db_saving() {
    jq ".db_status = \"inactive\"" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
    echo -e "${YELLOW}Database saving stopped.${NC}"
}

# Function to display server list menu
server_list_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== Server List ===${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        
        # Display server list
        server_count=0
        while read -r server_ip; do
            if [ -n "$server_ip" ]; then
                echo -e "${CYAN}$((++server_count)). $server_ip${NC}"
            fi
        done < <(get_server_list)
        
        if [ $server_count -eq 0 ]; then
            echo -e "${YELLOW}No servers in the list.${NC}"
        fi
        
        echo -e "${CYAN}---------------------------------------------------${NC}"
        echo -e "${GREEN}a. Add server${NC}"
        echo -e "${RED}r. Remove server${NC}"
        echo -e "${BLUE}b. Back to main menu${NC}"
        
        read -p "Select an option: " option
        
        case $option in
            a)
                read -p "Enter server IP to add: " server_ip
                add_server_to_list "$server_ip"
                sleep 2
                ;;
            r)
                if [ $server_count -eq 0 ]; then
                    echo -e "${YELLOW}No servers to remove.${NC}"
                    sleep 2
                    continue
                fi
                read -p "Enter server number to remove: " server_num
                if [[ $server_num =~ ^[0-9]+$ ]] && [ $server_num -ge 1 ] && [ $server_num -le $server_count ]; then
                    server_ip=$(get_server_list | sed -n "${server_num}p")
                    remove_server_from_list "$server_ip"
                else
                    echo -e "${RED}Invalid server number.${NC}"
                fi
                sleep 2
                ;;
            b)
                break
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Function to display non-main server menu
display_client_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== Network Monitoring Client ===${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        echo -e "${GREEN}1. Server State${NC}"
        echo -e "${GREEN}2. Set this server as Main Server${NC}"
        echo -e "${GREEN}3. Set another Main Server${NC}"
        
        if is_monitoring_active; then
            echo -e "${RED}4. Stop Monitoring${NC}"
        else
            echo -e "${GREEN}4. Start Monitoring${NC}"
        fi
        
        echo -e "${RED}5. Exit${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        
        read -p "Select an option: " option
        
        case $option in
            1)
                clear
                display_server_state
                read -p "Press Enter to continue..."
                ;;
            2)
                set_as_main_server
                echo -e "${GREEN}This server is now the main server. Restarting script...${NC}"
                sleep 2
                exec "$0"
                ;;
            3)
                set_another_main_server
                sleep 2
                ;;
            4)
                if is_monitoring_active; then
                    stop_monitoring
                else
                    start_monitoring
                fi
                sleep 2
                ;;
            5)
                echo -e "${YELLOW}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Function to display main server menu
display_main_server_menu() {
    while true; do
        clear
        echo -e "${BLUE}=== Network Monitoring Main Server ===${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        echo -e "${GREEN}1. Server State${NC}"
        echo -e "${GREEN}2. Server List${NC}"
        
        db_status=$(jq -r '.db_status' "$CONFIG_FILE" 2>/dev/null || echo "inactive")
        if [ "$db_status" = "active" ]; then
            echo -e "${RED}3. Stop Saving Data to Database${NC}"
        else
            echo -e "${GREEN}3. Start Saving Data to Database${NC}"
        fi
        
        echo -e "${RED}4. Exit${NC}"
        echo -e "${CYAN}---------------------------------------------------${NC}"
        
        read -p "Select an option: " option
        
        case $option in
            1)
                clear
                display_main_server_state
                read -p "Press Enter to continue..."
                ;;
            2)
                server_list_menu
                ;;
            3)
                if [ "$db_status" = "active" ]; then
                    stop_db_saving
                else
                    start_db_saving
                fi
                sleep 2
                ;;
            4)
                echo -e "${YELLOW}Exiting...${NC}"
                exit 0
                ;;
            *)
                echo -e "${RED}Invalid option.${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main function
main() {
    # Install dependencies
    install_dependencies
    
    # Check if this is the main server
    if is_main_server; then
        # Start the main server API in the background if it's not already running
        if ! pgrep -f "python3 $CONFIG_DIR/main_server.py" > /dev/null; then
            # Create main server Python script if it doesn't exist
            if [ ! -f "$CONFIG_DIR/main_server.py" ]; then
                cat > "$CONFIG_DIR/main_server.py" << 'EOF'
#!/usr/bin/env python3

from flask import Flask, request, jsonify
import sqlite3
import json
import os
import time
from datetime import datetime

app = Flask(__name__)

# Configuration
CONFIG_DIR = os.path.expanduser("~/.network_monitor")
CONFIG_FILE = os.path.join(CONFIG_DIR, "config.json")
DB_FILE = os.path.join(CONFIG_DIR, "network_data.db")

# Ensure config directory exists
os.makedirs(CONFIG_DIR, exist_ok=True)

# Initialize database
def init_db():
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Create servers table if it doesn't exist
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS servers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        hostname TEXT,
        ip TEXT UNIQUE,
        last_seen TIMESTAMP
    )
    ''')
    
    conn.commit()
    conn.close()

# Get database status from config
def get_db_status():
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
            return config.get('db_status', 'inactive')
    except (FileNotFoundError, json.JSONDecodeError):
        return 'inactive'

# Get server list from config
def get_server_list():
    try:
        with open(CONFIG_FILE, 'r') as f:
            config = json.load(f)
            return config.get('server_list', [])
    except (FileNotFoundError, json.JSONDecodeError):
        return []

# Create table for a specific server if it doesn't exist
def create_server_table(ip):
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Create table name by replacing dots with underscores
    table_name = f"traffic_{ip.replace('.', '_')}"
    
    cursor.execute(f'''
    CREATE TABLE IF NOT EXISTS {table_name} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TIMESTAMP,
        in_traffic REAL,
        out_traffic REAL
    )
    ''')
    
    conn.commit()
    conn.close()
    
    return table_name

# Route for receiving traffic data from clients
@app.route('/report', methods=['POST'])
def report():
    data = request.json
    
    # Check if the server is in the allowed list
    server_list = get_server_list()
    if data['ip'] not in server_list:
        return jsonify({'status': 'error', 'message': 'Server not in allowed list'}), 403
    
    # Update server info
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Update or insert server info
    cursor.execute(
        "INSERT OR REPLACE INTO servers (hostname, ip, last_seen) VALUES (?, ?, ?)",
        (data['hostname'], data['ip'], datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    )
    
    # If database saving is active, save traffic data
    if get_db_status() == 'active':
        # Create table for this server if it doesn't exist
        table_name = create_server_table(data['ip'])
        
        # Insert traffic data
        cursor.execute(
            f"INSERT INTO {table_name} (timestamp, in_traffic, out_traffic) VALUES (?, ?, ?)",
            (data['timestamp'], data['in_traffic'], data['out_traffic'])
        )
    
    conn.commit()
    conn.close()
    
    return jsonify({'status': 'success'})

# Route for getting server status
@app.route('/status', methods=['GET'])
def status():
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Get all servers
    cursor.execute("SELECT hostname, ip, last_seen FROM servers")
    servers = [{'hostname': row[0], 'ip': row[1], 'last_seen': row[2]} for row in cursor.fetchall()]
    
    # Get latest traffic data for each server
    for server in servers:
        table_name = f"traffic_{server['ip'].replace('.', '_')}"
        try:
            cursor.execute(f"SELECT timestamp, in_traffic, out_traffic FROM {table_name} ORDER BY timestamp DESC LIMIT 1")
            row = cursor.fetchone()
            if row:
                server['latest_data'] = {
                    'timestamp': row[0],
                    'in_traffic': row[1],
                    'out_traffic': row[2]
                }
            else:
                server['latest_data'] = None
        except sqlite3.OperationalError:
            # Table doesn't exist yet
            server['latest_data'] = None
    
    conn.close()
    
    return jsonify({
        'servers': servers,
        'db_status': get_db_status()
    })

if __name__ == '__main__':
    # Initialize database
    init_db()
    
    # Run the Flask app
    app.run(host='0.0.0.0', port=5000)
EOF
                chmod +x "$CONFIG_DIR/main_server.py"
            fi
            
            # Check if Python3 and Flask are installed
            if ! command_exists python3; then
                echo -e "${YELLOW}Installing Python3...${NC}"
                if command_exists apt-get; then
                    sudo apt-get update && sudo apt-get install -y python3 python3-pip
                elif command_exists yum; then
                    sudo yum install -y python3 python3-pip
                elif command_exists dnf; then
                    sudo dnf install -y python3 python3-pip
                elif command_exists pacman; then
                    sudo pacman -S --noconfirm python python-pip
                else
                    echo -e "${RED}Error: Could not install Python3. Please install it manually.${NC}"
                    exit 1
                fi
            fi
            
            # Install Flask if not already installed
            if ! python3 -c "import flask" 2>/dev/null; then
                echo -e "${YELLOW}Installing Flask...${NC}"
                pip3 install flask
            fi
            
            # Start the main server API in the background
            nohup python3 "$CONFIG_DIR/main_server.py" > "$CONFIG_DIR/main_server.log" 2>&1 &
            echo -e "${GREEN}Main server API started on port 5000.${NC}"
            sleep 2
        fi
        
        # Display main server menu
        display_main_server_menu
    else
        # Display client menu
        display_client_menu
    fi
}

# Run the main function
main