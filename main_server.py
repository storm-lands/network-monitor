#!/usr/bin/env python3

from flask import Flask, request, jsonify
import sqlite3
import os
import json
import time
import logging
from datetime import datetime

# Setup logging
logging.basicConfig(
    filename=os.path.expanduser('~/.network_monitor/main_server.log'),
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)

app = Flask(__name__)

# Configuration
CONFIG_DIR = os.path.expanduser('~/.network_monitor')
DB_FILE = os.path.join(CONFIG_DIR, 'network_data.db')
SERVER_LIST_FILE = os.path.join(CONFIG_DIR, 'server_list.txt')
DB_SAVING_STATUS_FILE = os.path.join(CONFIG_DIR, 'db_saving_status.txt')

# Initialize database
def init_db():
    if not os.path.exists(CONFIG_DIR):
        os.makedirs(CONFIG_DIR)
    
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Create servers table if it doesn't exist
    cursor.execute('''
    CREATE TABLE IF NOT EXISTS servers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ip TEXT UNIQUE,
        hostname TEXT,
        first_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    ''')
    
    conn.commit()
    conn.close()
    logging.info("Database initialized")

# Create or get table for a specific server
def ensure_server_table(server_ip):
    conn = sqlite3.connect(DB_FILE)
    cursor = conn.cursor()
    
    # Create table for this server if it doesn't exist
    table_name = f"traffic_{server_ip.replace('.', '_')}"
    cursor.execute(f'''
    CREATE TABLE IF NOT EXISTS {table_name} (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        upload_kbps REAL,
        download_kbps REAL
    )
    ''')
    
    conn.commit()
    conn.close()
    return table_name

# Check if server is in the allowed list
def is_server_allowed(server_ip):
    if not os.path.exists(SERVER_LIST_FILE):
        return False
    
    with open(SERVER_LIST_FILE, 'r') as f:
        allowed_servers = [line.strip() for line in f.readlines()]
    
    return server_ip in allowed_servers

# Check if database saving is enabled
def is_db_saving_enabled():
    if not os.path.exists(DB_SAVING_STATUS_FILE):
        return False
    
    with open(DB_SAVING_STATUS_FILE, 'r') as f:
        status = f.read().strip()
    
    return status == "enabled"

@app.route('/report', methods=['POST'])
def receive_report():
    data = request.json
    client_ip = request.remote_addr
    
    if not data or 'upload' not in data or 'download' not in data:
        return jsonify({"status": "error", "message": "Invalid data format"}), 400
    
    # Log the received data
    logging.info(f"Received traffic report from {client_ip}: {data}")
    
    # Check if this server is allowed
    if not is_server_allowed(client_ip):
        logging.warning(f"Rejected traffic report from unauthorized server: {client_ip}")
        return jsonify({"status": "error", "message": "Server not authorized"}), 403
    
    # If database saving is enabled, store the data
    if is_db_saving_enabled():
        try:
            # Ensure server exists in servers table
            conn = sqlite3.connect(DB_FILE)
            cursor = conn.cursor()
            
            # Check if server exists
            cursor.execute("SELECT id FROM servers WHERE ip = ?", (client_ip,))
            result = cursor.fetchone()
            
            if not result:
                hostname = data.get('hostname', 'unknown')
                cursor.execute("INSERT INTO servers (ip, hostname) VALUES (?, ?)", 
                              (client_ip, hostname))
            
            # Get server-specific table
            table_name = ensure_server_table(client_ip)
            
            # Insert traffic data
            cursor.execute(f"INSERT INTO {table_name} (upload_kbps, download_kbps) VALUES (?, ?)",
                         (data['upload'], data['download']))
            
            conn.commit()
            conn.close()
            logging.info(f"Saved traffic data for {client_ip}")
        except Exception as e:
            logging.error(f"Database error: {str(e)}")
            return jsonify({"status": "error", "message": f"Database error: {str(e)}"}), 500
    
    return jsonify({"status": "success"})

@app.route('/servers', methods=['GET'])
def get_servers():
    try:
        conn = sqlite3.connect(DB_FILE)
        cursor = conn.cursor()
        
        cursor.execute("SELECT ip, hostname, first_seen FROM servers")
        servers = [{
            "ip": row[0],
            "hostname": row[1],
            "first_seen": row[2]
        } for row in cursor.fetchall()]
        
        conn.close()
        return jsonify({"status": "success", "servers": servers})
    except Exception as e:
        logging.error(f"Error getting servers: {str(e)}")
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/latest', methods=['GET'])
def get_latest_data():
    try:
        # Get all servers from the allowed list
        if not os.path.exists(SERVER_LIST_FILE):
            return jsonify({"status": "error", "message": "No servers in list"}), 404
        
        with open(SERVER_LIST_FILE, 'r') as f:
            servers = [line.strip() for line in f.readlines()]
        
        result = {}
        conn = sqlite3.connect(DB_FILE)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        for server_ip in servers:
            table_name = f"traffic_{server_ip.replace('.', '_')}"
            
            # Check if table exists
            cursor.execute(f"SELECT name FROM sqlite_master WHERE type='table' AND name='{table_name}'")
            if not cursor.fetchone():
                result[server_ip] = {"status": "no_data"}
                continue
            
            # Get latest entry
            cursor.execute(f"SELECT * FROM {table_name} ORDER BY timestamp DESC LIMIT 1")
            row = cursor.fetchone()
            
            if row:
                result[server_ip] = {
                    "status": "ok",
                    "timestamp": row['timestamp'],
                    "upload_kbps": row['upload_kbps'],
                    "download_kbps": row['download_kbps']
                }
            else:
                result[server_ip] = {"status": "no_data"}
        
        conn.close()
        return jsonify({"status": "success", "data": result})
    except Exception as e:
        logging.error(f"Error getting latest data: {str(e)}")
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/history/<server_ip>', methods=['GET'])
def get_server_history(server_ip):
    try:
        # Check if this server is allowed
        if not is_server_allowed(server_ip):
            return jsonify({"status": "error", "message": "Server not authorized"}), 403
        
        # Get time range from query parameters
        hours = request.args.get('hours', default=24, type=int)
        
        conn = sqlite3.connect(DB_FILE)
        conn.row_factory = sqlite3.Row
        cursor = conn.cursor()
        
        table_name = f"traffic_{server_ip.replace('.', '_')}"
        
        # Check if table exists
        cursor.execute(f"SELECT name FROM sqlite_master WHERE type='table' AND name='{table_name}'")
        if not cursor.fetchone():
            return jsonify({"status": "error", "message": "No data for this server"}), 404
        
        # Get data for the specified time range
        cursor.execute(f"""
            SELECT timestamp, upload_kbps, download_kbps 
            FROM {table_name} 
            WHERE timestamp >= datetime('now', '-{hours} hours') 
            ORDER BY timestamp
        """)
        
        data = [{
            "timestamp": row['timestamp'],
            "upload_kbps": row['upload_kbps'],
            "download_kbps": row['download_kbps']
        } for row in cursor.fetchall()]
        
        conn.close()
        return jsonify({"status": "success", "data": data})
    except Exception as e:
        logging.error(f"Error getting server history: {str(e)}")
        return jsonify({"status": "error", "message": str(e)}), 500

@app.route('/', methods=['GET'])
def index():
    return jsonify({
        "status": "success",
        "message": "Network Monitoring API is running",
        "endpoints": [
            "/report - POST - Send traffic data",
            "/servers - GET - List all servers",
            "/latest - GET - Get latest traffic data for all servers",
            "/history/<server_ip> - GET - Get traffic history for a specific server"
        ]
    })

if __name__ == '__main__':
    init_db()
    app.run(host='0.0.0.0', port=5000)