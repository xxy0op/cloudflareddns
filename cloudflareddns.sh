#!/bin/bash

# 赋予脚本执行权限
if [ ! -x "$0" ]; then
    echo "正在为脚本添加执行权限..."
    chmod +x "$0"
    echo "执行权限已添加，继续运行脚本..."
fi

# 函数：提示用户输入Cloudflare API信息
function input_parameters() {
    read -p "请输入Cloudflare API令牌: " CF_API_TOKEN
    read -p "请输入Cloudflare账户邮箱: " CF_EMAIL
    read -p "请输入你的域名 (例如: example.com): " DNS_NAME
    read -p "请输入要更新的DNS记录 (例如: www.example.com): " DNS_RECORD
}

# 函数：显示当前输入的参数
function display_parameters() {
    echo "---------------------------------------"
    echo "当前输入的参数如下:"
    echo "Cloudflare API令牌: $CF_API_TOKEN"
    echo "Cloudflare账户邮箱: $CF_EMAIL"
    echo "域名: $DNS_NAME"
    echo "DNS记录: $DNS_RECORD"
    echo "---------------------------------------"
}

# 函数：修改参数
function modify_parameters() {
    echo "请选择要修改的参数:"
    echo "1) Cloudflare API令牌"
    echo "2) Cloudflare账户邮箱"
    echo "3) 域名"
    echo "4) DNS记录"
    echo "5) 不修改，继续运行脚本"
    read -p "请输入选项 (1-5): " choice

    case $choice in
        1) read -p "请输入新的Cloudflare API令牌: " CF_API_TOKEN ;;
        2) read -p "请输入新的Cloudflare账户邮箱: " CF_EMAIL ;;
        3) read -p "请输入新的域名 (例如: example.com): " DNS_NAME ;;
        4) read -p "请输入新的DNS记录 (例如: www.example.com): " DNS_RECORD ;;
        5) return ;;
        *) echo "无效选项，请重新选择。" ;;
    esac

    # 显示修改后的参数
    display_parameters
    modify_parameters  # 询问是否继续修改
}

# 主程序：输入参数
input_parameters

# 显示输入的参数
display_parameters

# 询问是否需要修改
read -p "是否需要修改参数？(y/n): " modify_choice
if [[ $modify_choice == "y" || $modify_choice == "Y" ]]; then
    modify_parameters
fi

# 获取Zone ID
ZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$DNS_NAME" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

# 检查Zone ID是否成功获取
if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" == "null" ]; then
    echo "无法获取Zone ID，请检查域名或API配置信息。"
    exit 1
fi

# 获取DNS记录ID
RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records?name=$DNS_RECORD" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result[0].id')

# 检查DNS记录ID是否成功获取
if [ -z "$RECORD_ID" ] || [ "$RECORD_ID" == "null" ]; then
    echo "无法获取DNS记录ID，请检查DNS记录是否正确。"
    exit 1
fi

# 获取当前的外部IP
CURRENT_IP=$(curl -s https://ipv4.icanhazip.com)

# 获取Cloudflare中现有的IP地址
OLD_IP=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" | jq -r '.result.content')

# 如果当前IP与Cloudflare中的IP不同，则更新
if [ "$CURRENT_IP" != "$OLD_IP" ]; then
  echo "IP地址已改变，正在更新Cloudflare DNS记录..."

  # 更新DNS记录
  RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
     -H "X-Auth-Email: $CF_EMAIL" \
     -H "X-Auth-Key: $CF_API_TOKEN" \
     -H "Content-Type: application/json" \
     --data "{\"type\":\"A\",\"name\":\"$DNS_RECORD\",\"content\":\"$CURRENT_IP\",\"proxied\":false}")

  # 检查是否更新成功
  if [[ $RESPONSE == *"\"success\":true"* ]]; then
    echo "DNS记录更新成功，新IP: $CURRENT_IP"
  else
    echo "DNS记录更新失败，响应: $RESPONSE"
  fi
else
  echo "IP地址未改变，无需更新。"
fi

# 添加定时任务，每2分钟运行一次
CRON_JOB="*/2 * * * * /root/cloudflare-ddns.sh >> /var/log/cloudflare-ddns.log 2>&1"
(crontab -l 2>/dev/null | grep -v -F "/root/cloudflare-ddns.sh"; echo "$CRON_JOB") | crontab -

echo "定时任务已设置，每2分钟更新一次。"
