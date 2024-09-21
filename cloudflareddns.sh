#!/bin/bash

# 赋予脚本执行权限
if [ ! -x "$0" ]; then
    echo "正在为脚本添加执行权限..."
    chmod +x "$0"
    echo "执行权限已添加，继续运行脚本..."
fi

# 检查并安装 jq，如果未安装
if ! command -v jq &> /dev/null
then
    echo "jq 未安装，正在安装..."
    if [ -f /etc/debian_version ]; then
        # 如果是 Debian/Ubuntu 系统
        apt update
        apt install -y jq
    elif [ -f /etc/redhat-release ]; then
        # 如果是 CentOS/Red Hat 系统
        yum install -y jq
    else
        echo "无法确定系统类型，请手动安装 jq。"
        exit 1
    fi
fi

# 配置文件路径
CONFIG_FILE="/root/cloudflare-ddns-config.txt"

# 读取配置文件中的参数
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 函数：提示用户输入 Cloudflare API 信息
function input_parameters() {
    # 如果配置文件中没有这些参数，才提示输入
    if [ -z "$CF_API_TOKEN" ]; then
        read -p "请输入 Cloudflare API 令牌: " CF_API_TOKEN
    fi
    if [ -z "$CF_EMAIL" ]; then
        read -p "请输入 Cloudflare 账户邮箱: " CF_EMAIL
    fi
    if [ -z "$DNS_NAME" ]; then
        read -p "请输入你的域名 (例如: example.com): " DNS_NAME
    fi
    if [ -z "$DNS_RECORD" ]; then
        read -p "请输入要更新的 DNS 记录 (例如: www.example.com): " DNS_RECORD
    fi

    # 保存输入的参数到配置文件中
    echo "CF_API_TOKEN=$CF_API_TOKEN" > "$CONFIG_FILE"
    echo "CF_EMAIL=$CF_EMAIL" >> "$CONFIG_FILE"
    echo "DNS_NAME=$DNS_NAME" >> "$CONFIG_FILE"
    echo "DNS_RECORD=$DNS_RECORD" >> "$CONFIG_FILE"
}

# 函数：显示当前输入的参数
function display_parameters() {
    echo "---------------------------------------"
    echo "当前输入的参数如下:"
    echo "Cloudflare API 令牌: $CF_API_TOKEN"
    echo "Cloudflare 账户邮箱: $CF_EMAIL"
    echo "域名: $DNS_NAME"
    echo "DNS 记录: $DNS_RECORD"
    echo "---------------------------------------"
}

# 函数：修改参数
function modify_parameters() {
    echo "请选择要修改的参数:"
    echo "1) Cloudflare API 令牌"
    echo "2) Cloudflare 账户邮箱"
    echo "3) 域名"
    echo "4) DNS 记录"
    echo "5) 不修改，继续运行脚本"
    read -p "请输入选项 (1-5): " choice

    case $choice in
        1) read -p "请输入新的 Cloudflare API 令牌: " CF_API_TOKEN ;;
        2) read -p "请输入新的 Cloudflare 账户邮箱: " CF_EMAIL ;;
        3) read -p "请输入新的域名 (例如: example.com): " DNS_NAME ;;
        4) read -p "请输入新的 DNS 记录 (例如: www.example.com): " DNS_RECORD ;;
        5) return ;;
        *) echo "无效选项，请重新选择。" ;;
    esac

    # 保存修改后的参数到配置文件中
    echo "CF_API_TOKEN=$CF_API_TOKEN" > "$CONFIG_FILE"
    echo "CF_EMAIL=$CF_EMAIL" >> "$CONFIG_FILE"
    echo "DNS_NAME=$DNS_NAME" >> "$CONFIG_FILE"
    echo "DNS_RECORD=$DNS_RECORD" >> "$CONFIG_FILE"

    # 显示修改后的参数
    display_parameters
    modify_parameters  # 询问是否继续修改
}

# 主程序：判断是否在交互式终端中运行
if [ -t 0 ]; then
    # 如果是交互式运行，提示输入或修改参数
    input_parameters
    display_parameters

    # 询问是否需要修改
    read -p "是否需要修改参数？(y/n): " modify_choice
    if [[ $modify_choice == "y" || $modify_choice == "Y" ]]; then
        modify_parameters
    fi
else
    # 如果是定时任务运行，直接使用配置文件中的参数
    echo "脚本在非交互模式下运行，直接使用配置文件中的参数。"
fi

# 获取 Zone ID
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DNS_NAME" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

# 检查 Zone ID 是否成功获取
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
    echo "无法获取 Zone ID，请检查域名或 API 配置信息。"
    exit 1
fi

# 获取 DNS 记录 ID
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DNS_RECORD" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

# 检查 DNS 记录 ID 是否成功获取
if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    echo "无法获取 DNS 记录 ID，请检查 DNS 记录是否正确。"
    exit 1
fi

# 获取当前的外部 IP
CURRENT_IP=$(curl -s https://ifconfig.co)

# 获取 Cloudflare 中现有的 IP 地址
OLD_IP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result.content')

# 调试输出：显示 IP 地址
echo "当前服务器的外部 IP: $CURRENT_IP"
echo "Cloudflare 上的 DNS 记录 IP: $OLD_IP"

# 检查 IP 是否发生变化
if [ "$CURRENT_IP" != "$OLD_IP" ];then
  echo "IP 地址已改变，正在更新 Cloudflare DNS 记录..."

  # 更新 DNS 记录
  RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD\",\"content\":\"$CURRENT_IP\",\"proxied\":false}")

  # 输出 API 响应
  echo "API 响应: $RESPONSE"

  if [[ $RESPONSE == *"\"success\":true"* ]]; then
    echo "DNS 记录更新成功，新 IP: $CURRENT_IP"
  else
    echo "DNS 记录更新失败，请检查响应内容。"
  fi
else
  echo "IP 地址未改变，无需更新。"
fi

# 添加定时任务，每 2 分钟运行一次
CRON_JOB="*/2 * * * * /root/cloudflareddns.sh >> /var/log/cloudflare-ddns.log 2>&1"
(crontab -l 2>/dev/null | grep -v -F "/root/cloudflareddns.sh"; echo "$CRON_JOB") | crontab -

echo "定时任务已设置，每 2 分钟更新一次。"
