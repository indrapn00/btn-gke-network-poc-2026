#!/bin/bash
cat << 'PYEOF' > /usr/local/bin/alicloud_http_server.py
import http.server
import json
import socket
import datetime
import threading

LOG_FILE = "/var/log/alicloud-http.log"

def get_local_ip():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        ip = s.getsockname()[0]
    except Exception:
        ip = "127.0.0.1"
    finally:
        s.close()
    return ip

SERVER_IP = get_local_ip()

def make_handler(port):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            now = datetime.datetime.now(datetime.timezone.utc).isoformat()
            payload = {
                "service": "Simulated Alibaba Cloud Endpoint (BTN Hybrid PoC)",
                "timestamp": now,
                "observed_client_ip": self.client_address[0],
                "observed_client_port": self.client_address[1],
                "server_hostname": socket.gethostname(),
                "server_ip": SERVER_IP,
                "server_port": port,
                "request_path": self.path,
                "headers": dict(self.headers)
            }
            line = json.dumps(payload)
            with open(LOG_FILE, "a") as f:
                f.write(line + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write((json.dumps(payload, indent=2) + "\n").encode("utf-8"))
    return Handler

threading.Thread(target=lambda: http.server.ThreadingHTTPServer(("0.0.0.0", 80), make_handler(80)).serve_forever(), daemon=True).start()
http.server.ThreadingHTTPServer(("0.0.0.0", 8080), make_handler(8080)).serve_forever()
PYEOF

cat << 'SVCEOF' > /etc/systemd/system/alicloud-http.service
[Unit]
Description=Simulated Alibaba Cloud HTTP Server
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/alicloud_http_server.py
Restart=always

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --now alicloud-http.service
