#!/bin/bash

# ============================================
# 一键启动 OpenCodeUI（standalone 模式）
# 同时启动 opencode serve + 前端容器
#
# 默认使用本地代码构建前端镜像（docker-compose.standalone.build.yml）。
# 如果该文件不存在，则 fallback 到远程镜像版 docker-compose.standalone.yml。
# 通过 fingerprint 文件 .docker-build-cache/frontend.stamp 检测代码变更：
#   - 首次 / 代码变更 → 自动 --build
#   - 代码未变         → 复用本地缓存镜像，秒级启动
# ============================================

set -e

LOCAL_COMPOSE_FILE="docker-compose.standalone.build.yml"
REMOTE_COMPOSE_FILE="docker-compose.standalone.yml"
CACHE_DIR=".docker-build-cache"
STAMP_FILE="$CACHE_DIR/frontend.stamp"
PORT_RANGE_START=10000
PORT_RANGE_END=60000

# === 加载 .env（PORT / OPENCODE_SERVER_PASSWORD）===
if [ -f ".env" ]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

# === 选择 compose 文件 ===
if [ -f "$LOCAL_COMPOSE_FILE" ]; then
  COMPOSE_FILE="$LOCAL_COMPOSE_FILE"
  IMAGE_MODE="local"
else
  COMPOSE_FILE="$REMOTE_COMPOSE_FILE"
  IMAGE_MODE="remote"
  echo "⚠️  未找到 $LOCAL_COMPOSE_FILE，将回退到远程镜像（可能不是最新版）"
fi

# === 检查端口是否被占用（跨平台兼容）===
check_port_in_use() {
  local port=$1
  if command -v ss &> /dev/null; then
    ss -tlnp | grep -q ":${port} "
  elif command -v netstat &> /dev/null; then
    netstat -an | grep -q "\.${port}.*LISTEN"
  elif command -v lsof &> /dev/null; then
    lsof -i ":${port}" > /dev/null 2>&1
  else
    python3 -c "import socket; s=socket.socket(); s.settimeout(1); exit(0 if s.connect_ex(('127.0.0.1', ${port})) == 0 else 1)" 2>/dev/null
  fi
}

# === 检查 serve 是否已在运行 ===
echo "🔍 检查 opencode serve 状态..."
SERVE_PID=$(pgrep -f "^opencode serve" | head -1)
if [ -n "$SERVE_PID" ] && kill -0 "$SERVE_PID" 2>/dev/null; then
  echo "✅ opencode serve 已在运行 (PID: $SERVE_PID)"
else
  echo "🚀 启动 opencode serve..."
  if [ -n "$OPENCODE_SERVER_PASSWORD" ]; then
    echo "🔐 已从 .env 加载密码认证"
  else
    echo "⚠️  未配置 OPENCODE_SERVER_PASSWORD，serve 将以无密码模式启动"
  fi
  nohup opencode serve --port 4096 --hostname 127.0.0.1 > /tmp/opencode-serve.log 2>&1 &
  SERVE_PID=$!
  echo "⏳ 等待 serve 启动..."
  sleep 3

  # 验证 serve 是否成功启动
  if kill -0 "$SERVE_PID" 2>/dev/null && netstat -an 2>/dev/null | grep -q "\.4096.*LISTEN"; then
    echo "✅ opencode serve 已启动 (127.0.0.1:4096, PID: $SERVE_PID)"
  else
    echo "❌ opencode serve 启动失败，请检查日志："
    cat /tmp/opencode-serve.log
    exit 1
  fi
fi

# === 前端容器已在运行则直接复用（幂等，避免换端口重建）===
EXISTING_PORT=$(docker port opencodeui 3000/tcp 2>/dev/null | grep -oE '[0-9]+$' | head -1)
if [ -n "$EXISTING_PORT" ]; then
  echo "✅ 前端容器已在运行 (http://localhost:${EXISTING_PORT})，跳过重建"
  FREE_PORT="$EXISTING_PORT"
  SKIP_FRONTEND=1
fi

# === 找前端端口（优先 .env 的 PORT，否则随机空闲端口）===
echo ""
if [ -z "$FREE_PORT" ]; then
  if [ -n "${PORT:-}" ]; then
    if ! check_port_in_use "$PORT"; then
      echo "✅ 使用 .env 配置的前端端口: $PORT"
      FREE_PORT="$PORT"
    else
      echo "⚠️  .env 的 PORT=$PORT 已被占用，改用随机空闲端口"
    fi
  fi

  if [ -z "$FREE_PORT" ]; then
    echo "🔍 搜索空闲前端端口..."
    for port in $(shuf -i ${PORT_RANGE_START}-${PORT_RANGE_END}); do
      if ! check_port_in_use "$port"; then
        FREE_PORT=$port
        break
      fi
    done
  fi
fi

if [ -z "$FREE_PORT" ]; then
  echo "❌ 未找到空闲端口，请手动释放端口后重试"
  exit 1
fi

echo "✅ 找到空闲端口: $FREE_PORT"

# === 计算前端构建 fingerprint ===
# 跨平台 stat：mac 用 -f %m，Linux 用 -c %Y
_stat_mtime() {
  stat -f "%m" "$1" 2>/dev/null || stat -c "%Y" "$1" 2>/dev/null || echo "0"
}

# 聚合目录下所有文件的最新 mtime（用于检测"改了文件但没 commit"）
_dir_max_mtime() {
  local dir="$1"
  [ -d "$dir" ] || { echo "0"; return; }
  find "$dir" -type f -not -path '*/node_modules/*' -not -path '*/dist/*' -not -path '*/.git/*' \
    -printf '%T@\n' 2>/dev/null \
    | sort -nr | head -1 | cut -d. -f1
}

compute_fingerprint() {
  {
    printf 'git=%s\n' "$(git rev-parse HEAD 2>/dev/null || echo 'no-git')"
    printf 'git_status=%s\n' "$(git status --porcelain 2>/dev/null | sha256sum | awk '{print $1}')"
    printf 'pkgjson=%s\n' "$(_stat_mtime package.json)"
    printf 'dockerfile=%s\n' "$(_stat_mtime docker/Dockerfile.frontend)"
    printf 'src_max_mtime=%s\n' "$(_dir_max_mtime src)"
    printf 'public_max_mtime=%s\n' "$(_dir_max_mtime public)"
    printf 'index_mtime=%s\n' "$(_stat_mtime index.html)"
  } | sha256sum | awk '{print $1}'
}

NEED_BUILD=""
NEW_FP=""
if [ -z "$SKIP_FRONTEND" ]; then
  if [ "$IMAGE_MODE" = "local" ]; then
    NEW_FP="$(compute_fingerprint)"
    if [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE" 2>/dev/null || echo '')" != "$NEW_FP" ]; then
      NEED_BUILD="--build"
      echo "🔨 检测到代码变更，将本地构建前端镜像…"
    else
      echo "✅ 代码未变，跳过构建（复用本地缓存镜像）"
    fi
    mkdir -p "$CACHE_DIR"
  else
    echo "ℹ️  远程镜像模式：不会触发本地构建"
  fi
else
  echo "⏭️  跳过指纹计算与构建检查（前端容器已在运行）"
fi

# === 启动前端容器 ===
echo ""
if [ -z "$SKIP_FRONTEND" ]; then
  echo "🚀 启动前端容器..."
  if ! BACKEND_URL=host.docker.internal:4096 PORT=$FREE_PORT docker compose -f "$COMPOSE_FILE" up -d $NEED_BUILD; then
    echo "❌ 前端容器启动失败"
    exit 1
  fi

  # 构建成功后写入 stamp（仅在确实构建了的情况下）
  if [ -n "$NEED_BUILD" ] && [ -n "$NEW_FP" ]; then
    echo "$NEW_FP" > "$STAMP_FILE"
  fi
else
  echo "⏭️  跳过前端容器操作（已在运行）"
fi

if [ "$IMAGE_MODE" = "local" ]; then
  IMAGE_DESC="本地构建 (opencodeui-frontend:local)"
else
  IMAGE_DESC="远程镜像 (ghcr.io/lehhair/opencodeui-frontend:latest)"
fi

echo ""
echo "============================================"
echo "         ✅ 全部服务启动成功！              "
echo "============================================"
echo "🌐 前端访问地址: http://localhost:${FREE_PORT}"
echo "🔗 后端地址:     http://localhost:4096"
echo "📄 前端端口:     ${FREE_PORT}"
echo "📦 前端镜像:     ${IMAGE_DESC}"
echo "📄 停止服务:     ./stop.sh"
echo "============================================"