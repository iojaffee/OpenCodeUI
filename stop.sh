#!/bin/bash

# ============================================
# 一键停止 OpenCodeUI（standalone 模式）
# 同时停止前端容器和 opencode serve
# ============================================

set -e

COMPOSE_FILE="docker-compose.standalone.yml"

echo "🛑 停止前端容器..."
docker compose -f "$COMPOSE_FILE" down 2>/dev/null || echo "   (容器未运行)"

echo "🛑 停止 opencode serve..."
if pkill -TERM -f "^opencode serve" 2>/dev/null; then
  echo "   ⏳ 已发送停止信号，等待退出..."
  sleep 2
  if pgrep -f "^opencode serve" > /dev/null 2>&1; then
    pkill -KILL -f "^opencode serve" 2>/dev/null || true
    echo "   ⚠️ 超时未退出，已强制结束"
  else
    echo "   ✅ serve 已停止"
  fi
else
  echo "   (serve 未运行)"
fi

echo ""
echo "✅ 所有服务已停止"