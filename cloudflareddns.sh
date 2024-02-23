#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Automatically update your CloudFlare DNS record to the IP, Dynamic DNS
# Can retrieve cloudflare Domain id and list zone's, because, lazy

# Usage:
# cf-ddns.sh -k cloudflare-api-key \
#            -u user@example.com \
#            -h host.example.com \     # fqdn of the record you want to update
#            -z example.com \          # will show you all zones if forgot, but you need this
#            -t A|AAAA                 # specify ipv4/ipv6, default: ipv4

# Optional flags:
#            -f false|true \           # force dns update, disregard local stored ip

# default config

# API key, see https://www.cloudflare.com/a/account/my-account,
# incorrect api-key results in E_UNAUTH error
CFKEY=

# Username, eg: user@example.com
CFUSER=

# Zone name, eg: example.com
CFZONE_NAME=

# Hostname to update, eg: homeserver.example.com
CFRECORD_NAME=

# Record type, A(IPv4)|AAAA(IPv6), default IPv4
CFRECORD_TYPE=A

# Cloudflare TTL for record, between 120 and 86400 seconds
CFTTL=120

# Ignore local file, update ip anyway
FORCE=false

WANIPSITE="http://ipv4.icanhazip.com"

# Site to retrieve WAN ip, other examples are: bot.whatismyipaddress.com, https://api.ipify.org/ ...
if [ "$CFRECORD_TYPE" = "A" ]; then
  :
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  echo "$CFRECORD_TYPE specified is invalid, CFRECORD_TYPE can only be A(for IPv4)|AAAA(for IPv6)"
  exit 2
fi

# Function to start the cron job
start_cron_job() {
  # Check if the cron job already exists
  if crontab -l | grep -q "*/2 * * * * /root/cloudflareddns.sh >/dev/null 2>&1"; then
    echo "Cron job is already running."
  else
    # Add the cron job
    (crontab -l ; echo "*/2 * * * * /root/cloudflareddns.sh >/dev/null 2>&1") | crontab -
    echo "Cron job started."
  fi
}

# Function to stop the cron job
stop_cron_job() {
  # Remove the cron job
  (crontab -l | grep -v "/root/cloudflareddns.sh >/dev/null 2>&1") | crontab -
  echo "Cron job stopped."
}

# Display menu and get user input
echo "请选择要修改的选项:"
echo "1. 修改 Cloudflare API Key"
echo "2. 修改 Cloudflare 用户名"
echo "3. 修改区域名"
echo "4. 修改主机名"
echo "5. 修改记录类型"
echo "6. 修改是否强制更新标志"
echo "7. 启动/停止定时任务"
read -p "请输入选项数字(1-7): " choice

# 根据用户的选择进行相应的操作
case $choice in
  1) read -p "请输入 Cloudflare API Key: " CFKEY ;;
  2) read -p "请输入 Cloudflare 用户名: " CFUSER ;;
  3) read -p "请输入区域名: " CFZONE_NAME ;;
  4) read -p "请输入主机名: " CFRECORD_NAME ;;
  5) read -p "请输入记录类型 (A 或 AAAA): " CFRECORD_TYPE ;;
  6) read -p "请输入是否强制更新标志 (true 或 false): " FORCE ;;
  7)
    echo "请选择操作:"
    echo "1. 启动定时任务"
    echo "2. 停止定时任务"
    read -p "请输入选项数字(1-2): " cron_option
    case $cron_option in
      1) start_cron_job ;;
      2) stop_cron_job ;;
      *) echo "无效的选项，请输入 1 或 2" ;;
    esac
    ;;
  *) echo "无效的选项，请输入 1-7 之间的数字" ;;
esac

# 如果有必填项为空，退出脚本
if [ "$CFKEY" = "" ]; then
  echo "缺少 API Key，请提供 Cloudflare API Key"
  exit 2
fi
if [ "$CFUSER" = "" ]; then
  echo "缺少用户名，请提供 Cloudflare 用户名"
  exit 2
fi
if [ "$CFRECORD_NAME" = "" ]; then 
  echo "缺少主机名，请提供主机名"
  exit 2
fi

# 如果主机名不是完全合格域名（FQDN）
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  echo " => 主机名不是完全合格域名（FQDN），已自动修正为 $CFRECORD_NAME"
fi

# 获取当前和旧的 WAN IP
WAN_IP=$(curl -s ${WANIPSITE})
WAN_IP_FILE=$HOME/.cf-wan_ip_$CFRECORD_NAME.txt
if [ -f $WAN_IP_FILE ]; then
  OLD_WAN_IP=$(cat $WAN_IP_FILE)
else
  echo "未找到 IP 文件"
  OLD_WAN_IP=""
fi

# 如果 WAN IP 没有变化且不是强制更新，则退出
if [ "$WAN_IP" = "$OLD_WAN_IP" ] && [ "$FORCE" = false ]; then
  echo "WAN IP 没有变化，如需强制更新请设置 -f true"
  exit 0
fi

# 获取区域标识符和记录标识符
ID_FILE=$HOME/.cf-id_$CFRECORD_NAME.txt
if [ -f $ID_FILE ] && [ $(wc -l $ID_FILE | cut -d " " -f 1) == 4 ] \
  && [ "$(sed -n '3,1p' "$ID_FILE")" == "$CFZONE_NAME" ] \
  && [ "$(sed -n '4,1p' "$ID_FILE")" == "$CFRECORD_NAME" ]; then
    CFZONE_ID=$(sed -n '1,1p' "$ID_FILE")
    CFRECORD_ID=$(sed -n '2,1p' "$ID_FILE")
else
    echo "更新区域标识符和记录标识符"
    CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1 )
    CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" -H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY" -H "Content-Type: application/json"  | grep -Po '(?<="id":")[^"]*' | head -1 )
    echo "$CFZONE_ID" > $ID_FILE
    echo "$CFRECORD_ID" >> $ID_FILE
    echo "$CFZONE_NAME" >> $ID_FILE
    echo "$CFRECORD_NAME" >> $ID_FILE
fi

# 如果 WAN IP 发生变化，则更新 Cloudflare
echo "正在更新 DNS 到 $WAN_IP"

RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  -H "X-Auth-Email: $CFUSER" \
  -H "X-Auth-Key: $CFKEY" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL}")

if [ "$RESPONSE" != "${RESPONSE%success*}" ] && [ "$(echo $RESPONSE | grep "\"success\":true")" != "" ]; then
  echo "更新成功！"
  echo $WAN_IP > $WAN_IP_FILE
else
  echo '出错了 :('
  echo "响应: $RESPONSE"
fi
