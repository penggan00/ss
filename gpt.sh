#!/bin/bash

# 定义服务配置
SERVICE_NAME="gpt.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
APP_DIR="/root/rss"
PYTHON_PATH="${APP_DIR}/rss_venv/bin/python3"
SCRIPT_PATH="${APP_DIR}/gpt.py"

# 创建 systemd 服务文件
sudo bash -c "cat > ${SERVICE_FILE}" <<EOF
[Unit]
Description=gpt Service
After=network.target

[Service]
User=root
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=${PYTHON_PATH} ${SCRIPT_PATH}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
sudo systemctl daemon-reload
sudo systemctl enable "${SERVICE_NAME}"
sudo systemctl restart "${SERVICE_NAME}"

# 验证状态
echo -e "\n\033[32m[状态]\033[0m ${SERVICE_NAME}"
sudo systemctl status "${SERVICE_NAME}" --no-pager -l