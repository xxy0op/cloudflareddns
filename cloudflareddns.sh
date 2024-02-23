#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# 默认配置
CFKEY=
CFUSER=
CFZONE_NAME=
CFRECORD_NAME=
CFRECORD_TYPE=A
CFTTL=120
FORCE=false
START_CRON=false

# 获取当前外部 IP 的网址
WANIPSITE="http://ipv4.icanhazip.com"
if [ "$CFRECORD_TYPE" = "A" ]; then
  :
elif [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
else
  echo "$CFRECORD_TYPE 指定无效，请使用 A(用于 IPv4) 或 AAAA(用于 IPv6)"
  exit 2
fi

# 开始循环以接收参数
while true; do
  # 显示菜单选项并提示用户输入选项
  echo "请选择要修改的选项:"
  echo "1. 修改 Cloudflare API Key"
  echo "2. 修改 Cloudflare 用户名"
  echo "3. 修改区域名"
  echo "4. 修改主机名"
  echo "5. 修改记录类型"
  echo "6. 修改是否强制更新标志"
  echo "7. 启动脚本并开始定时任务"
  read -p "请输入选项数字(1-7): " choice

  # 根据用户的选择进行相应的操作
  case $choice in
    1) read -p "请输入 Cloudflare API Key: " CFKEY ;;
    2) read -p "请输入 Cloudflare 用户名: " CFUSER ;;
    3) read -p "请输入区域名: " CFZONE_NAME ;;
    4) read -p "请输入主机名: " CFRECORD_NAME ;;
    5) read -p "请输入记录类型 (A 或 AAAA): " CFRECORD_TYPE ;;
    6) read -p "请输入是否强制更新标志 (true 或 false): " FORCE ;;
    7) START_CRON=true; break ;; # 跳出循环以开始脚本和定时任务
    *) echo "无效的选项，请输入 1-7 之间的数字" ;;
  esac
done

# 循环直到用户提供有效的 API Key
while [ -z "$CFKEY" ]; do
  read -p "缺少 API Key，请提供 Cloudflare API Key: " CFKEY
done

# 循环直到用户提供有效的用户名
while [ -z "$CFUSER" ]; do
  read -p "缺少用户名，请提供 Cloudflare 用户名: " CFUSER
done

# 循环直到用户提供有效的区域名
while [ -z "$CFZONE_NAME" ]; do
  read -p "缺少区域名，请提供 Cloudflare 区域名: " CFUSER
done

# 循环直到用户提供有效的主机名
while [ -z "$CFCFRECORD_NAME" ]; do
  read -p "缺少主机名，请提供 Cloudflare 主机名: " CFUSER
done

# 如果主机名不是完全合格域名（FQDN）
if [ "$CFRECORD_NAME" != "$CFZONE_NAME" ] && ! [ -z "${CFRECORD_NAME##*$CFZONE_NAME}" ]; then
  CFRECORD_NAME="$CFRECORD_NAME.$CFZONE_NAME"
  echo " => 主机名不是完全合格域名（FQDN），已自动修正为 $CFRECORD_NAME"
fi

# 如果需要启动定时任务，则调用相应的函数
if [ "$START_CRON" = true ]; then
  if [ "$CFKEY" = "" ]; then
    echo "缺少 API Key，请提供 Cloudflare API Key"
    exit 2
  fi
  # 添加定时任务
  (crontab -l ; echo "*/2 * * * * /root/cloudflareddns.sh >/dev/null 2>&1") | crontab -
  echo "定时任务已启动"

  # 显示用户输入的所有参数
  echo "您输入的参数如下："
  echo "Cloudflare API Key: $CFKEY"
  echo "Cloudflare 用户名: $CFUSER"
  echo "区域名: $CFZONE_NAME"
  echo "主机名: $CFRECORD_NAME"
  echo "记录类型: $CFRECORD_TYPE"
  echo "是否强制更新标志: $FORCE"

  # 提供选项给用户选择执行脚本或修改参数
  while true; do
    echo "请选择操作:"
    echo "1. 运行脚本"
    echo "2. 修改参数"
    read -p "请输入选项数字(1-2): " option

    case $option in
      1) /root/cloudflareddns.sh ;;  # 运行脚本
      2) break ;;  # 跳出循环以继续修改参数
      *) echo "无效的选项，请输入 1 或 2" ;;
    esac
  done
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

# 更新 Cloudflare
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
