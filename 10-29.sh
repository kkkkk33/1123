#!/usr/bin/env bash
# ================================================================
# VLESS + REALITY 一体化部署脚本
# 服务端: sing-box (VLESS + REALITY)
# 平台: Debian/Ubuntu | Docker Compose v2
# 特性: 密钥环境变量 | 镜像锁版本 | REALITY 伪装
#       多源取 IP | 容器健康检查 | Telegram 降级推送
# 说明: 无需自签证书，无需 Nginx 回落，伪装目标为真实大站
# ================================================================

set -euo pipefail

# ── 1. 配置区（可用环境变量覆盖）────────────────────────────────
TG_TOKEN="${TG_TOKEN:-8526087156:AAHR5forb44MA061r0zgcPMiGtkkxHD5K6o}"
TG_CHAT_ID="${TG_CHAT_ID:-6303873752}"

# VLESS UUID，可用 uuidgen 生成
VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}"

TROJAN_PORT="${TROJAN_PORT:-51566}"   # 变量名保留兼容，实际是 VLESS 端口
REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"  # 伪装目标大站，需支持 TLS 1.3
DOH_URL="${DOH_URL:-https://223.5.5.5/dns-query}"

# REALITY 密钥对（脚本首次运行自动生成并保存）
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID="0123456789abcdef"

SINGBOX_IMAGE="ghcr.io/sagernet/sing-box:v1.10.7"

WORK_DIR="/opt/vless-reality"
CONTAINER_NAME="vless-reality"

# ── 颜色 ────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── 2. root 检查 ────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "请使用 root 运行: sudo bash $0"

# ── 3. 安装 Docker + python3 ────────────────────────────────────
install_docker() {
  if command -v docker &>/dev/null && docker compose version &>/dev/null; then
    success "Docker + Compose v2 已就绪"
  else
    info "安装 Docker..."
    apt-get update -y
    apt-get install -y ca-certificates curl gnupg
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg" \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      > /etc/apt/sources.list.d/docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    systemctl enable --now docker
    success "Docker 安装完成"
  fi

  if ! command -v python3 &>/dev/null; then
    info "安装 python3..."
    apt-get install -y python3
  fi
}

# ── 4. 生成 REALITY 密钥对（幂等）──────────────────────────────
gen_reality_keys() {
  mkdir -p "${WORK_DIR}"
  local key_file="${WORK_DIR}/reality_keys"

  if [[ -f "$key_file" ]]; then
    # shellcheck disable=SC1090
    source "$key_file"
    success "REALITY 密钥已存在，跳过生成"
    return
  fi

  info "生成 REALITY 密钥对..."
  # sing-box 自带 generate 命令，或借用 xray 的 x25519
  local output
  output=$(docker run --rm "${SINGBOX_IMAGE}" generate reality-keypair 2>/dev/null) || {
    error "生成密钥失败，请确认镜像可用: docker pull ${SINGBOX_IMAGE}"
  }

  REALITY_PRIVATE_KEY=$(echo "$output" | grep "PrivateKey" | awk '{print $2}')
  REALITY_PUBLIC_KEY=$(echo "$output" | grep "PublicKey" | awk '{print $2}')

  [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || error "密钥解析失败"

  cat > "$key_file" <<EOF
REALITY_PRIVATE_KEY="${REALITY_PRIVATE_KEY}"
REALITY_PUBLIC_KEY="${REALITY_PUBLIC_KEY}"
EOF
  chmod 600 "$key_file"
  success "REALITY 密钥生成完成"
}

# ── 5. sing-box 配置（VLESS + REALITY）─────────────────────────
write_singbox_config() {
  info "写入 sing-box VLESS+REALITY 配置..."
  mkdir -p "${WORK_DIR}"
  cat > "${WORK_DIR}/config.json" <<EOF
{
  "log": { "level": "info", "timestamp": true },
  "dns": {
    "servers": [{ "tag": "dns-remote", "address": "${DOH_URL}", "detour": "direct" }],
    "strategy": "ipv4_only"
  },
  "inbounds": [{
    "type": "vless",
    "tag": "vless-in",
    "listen": "::",
    "listen_port": ${TROJAN_PORT},
    "users": [{
      "uuid": "${VLESS_UUID}",
      "flow": "xtls-rprx-vision"
    }],
    "tls": {
      "enabled": true,
      "server_name": "${REALITY_SNI}",
      "reality": {
        "enabled": true,
        "handshake": {
          "server": "${REALITY_SNI}",
          "server_port": 443
        },
        "private_key": "${REALITY_PRIVATE_KEY}",
        "short_id": ["${REALITY_SHORT_ID}"]
      }
    }
  }],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
  success "sing-box 配置完成（REALITY 伪装目标: ${REALITY_SNI}）"
}

# ── 6. docker-compose.yml（单容器，无 Nginx）────────────────────
write_compose() {
  info "写入 docker-compose.yml..."
  cat > "${WORK_DIR}/docker-compose.yml" <<EOF
services:
  vless:
    image: ${SINGBOX_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: always
    ports:
      - "${TROJAN_PORT}:${TROJAN_PORT}/tcp"
    volumes:
      - ./config.json:/etc/sing-box/config.json:ro
    command: run -D /var/lib/sing-box -c /etc/sing-box/config.json
    healthcheck:
      test: ["CMD", "sing-box", "check", "-c", "/etc/sing-box/config.json"]
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 10s
EOF
  success "docker-compose.yml 写入完成"
}

# ── 7. 防火墙 ──────────────────────────────────────────────────
open_firewall() {
  info "放行端口 ${TROJAN_PORT}..."
  if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${TROJAN_PORT}/tcp" >/dev/null 2>&1 || true
  fi
  iptables -I INPUT -p tcp --dport "${TROJAN_PORT}" -j ACCEPT 2>/dev/null || true
  success "防火墙规则已处理（云安全组需手动放行 ${TROJAN_PORT}）"
}

# ── 8. 启动 ────────────────────────────────────────────────────
start_service() {
  info "清理旧容器..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

  info "拉取镜像并启动..."
  cd "${WORK_DIR}"
  docker compose pull
  docker compose up -d

  info "等待容器就绪..."
  local retries=10
  while (( retries-- > 0 )); do
    local status
    status=$(docker inspect --format='{{.State.Health.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo "unknown")
    if [[ "$status" == "healthy" ]]; then
      success "容器 healthy"
      return 0
    fi
    sleep 2
  done
  warn "容器状态未达预期，检查: docker logs ${CONTAINER_NAME}"
  return 0
}

# ── 9. 多源取公网 IPv4 ────────────────────────────────────────
get_public_ip() {
  local ip=""
  ip=$(curl -4 -s --max-time 5 https://api4.ipify.org 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -4 -s --max-time 5 https://ipv4.icanhazip.com 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  ip=$(curl -4 -s --max-time 5 https://ifconfig.me 2>/dev/null) && [[ -n "$ip" ]] && echo "$ip" && return
  echo "YOUR_SERVER_IP"
}

# ── 10. Telegram 推送 ─────────────────────────────────────────
send_telegram() {
  local server_ip="$1" link="$2"

  local plain_msg="VLESS+REALITY 节点部署完成
地址: ${server_ip}
端口: ${TROJAN_PORT}
UUID: ${VLESS_UUID}
SNI : ${REALITY_SNI}
Flow: xtls-rprx-vision

链接:
${link}

请在云安全组放行 TCP ${TROJAN_PORT}"

  local http_code
  http_code=$(curl -s -o /tmp/tg_resp.json -w "%{http_code}" \
    -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=${plain_msg}" \
    --data-urlencode "disable_web_page_preview=true")

  if [[ "$http_code" == "200" ]] && grep -q '"ok":true' /tmp/tg_resp.json 2>/dev/null; then
    success "Telegram 推送成功"
  else
    warn "Telegram 推送失败，请手动记录上方信息"
  fi
}

# ── 11. 输出与推送 ────────────────────────────────────────────
print_and_notify() {
  info "获取公网 IP..."
  local server_ip
  server_ip=$(get_public_ip)
  success "公网 IP: ${server_ip}"

  # VLESS 链接格式（客户端需支持 REALITY）
  local link="vless://${VLESS_UUID}@${server_ip}:${TROJAN_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp#VLESS-REALITY-${server_ip}"

  echo ""
  echo -e "${GREEN}=================================================${NC}"
  echo -e "${GREEN}         🎉 VLESS+REALITY 部署完成              ${NC}"
  echo -e "${GREEN}=================================================${NC}"
  echo -e "  地址    : ${server_ip}"
  echo -e "  端口    : ${TROJAN_PORT}"
  echo -e "  UUID    : ${VLESS_UUID}"
  echo -e "  SNI     : ${REALITY_SNI}"
  echo -e "  Flow    : xtls-rprx-vision"
  echo -e "  PublicKey: ${REALITY_PUBLIC_KEY}"
  echo -e "  ShortId : ${REALITY_SHORT_ID}"
  echo -e "  链接    : ${YELLOW}${link}${NC}"
  echo -e "${GREEN}=================================================${NC}"
  echo -e "  ⚠️  云安全组放行 TCP ${TROJAN_PORT}"
  echo -e "  🐳 日志: docker logs ${CONTAINER_NAME}"
  echo -e "${GREEN}=================================================${NC}"

  send_telegram "${server_ip}" "${link}"
}

# ================================================================
# 主流程
# ================================================================
info "开始部署 VLESS+REALITY..."
install_docker
gen_reality_keys
write_singbox_config
write_compose
open_firewall
start_service
print_and_notify
success "全部完成"