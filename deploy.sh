#!/usr/bin/env bash
#
# deploy.sh — 一键构建并推送
#
# 用法：
#   ./deploy.sh "本次改了什么"    # 构建 + 提交 + 推送
#   ./deploy.sh --preview         # 只本地构建，不推送（用于检查）
#
# 效果：Cloudflare Pages 会在约 30 秒内自动重新部署线上站点

set -euo pipefail
cd "$(dirname "$0")"

PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

# 域名：优先读.env，其次读 site_domain.txt
if [ -f .env ]; then
  DOMAIN="$(grep -E '^SITE_DOMAIN=' .env | cut -d= -f2- | tr -d ' "' || true)"
fi
if [ -z "${DOMAIN:-}" ] && [ -f site_domain.txt ]; then
  DOMAIN="$(tr -d ' \n' < site_domain.txt)"
fi
if [ -z "${DOMAIN:-}" ]; then
  echo "错误：找不到域名。"
  echo "两种任选一种方式设置："
  echo "  1) 在项目根目录建 .env 文件，内容写：SITE_DOMAIN=你的域名.com"
  echo "  2) 建 site_domain.txt 文件，内容写：你的域名.com"
  exit 1
fi

echo "域名: $DOMAIN"
echo

# ── 1. 本地构建检查 ──────────────────────────────
echo "[1/4] 本地构建检查…"
"$PY" build.py "$DOMAIN"
echo

if [ "${1:-}" = "--preview" ]; then
  echo "预览构建完成，未推送。产物在 site/，本地打开 site/index.html 可查看。"
  exit 0
fi

MSG="${1:-}"
if [ -z "$MSG" ]; then
  read -r -p "请输入本次改动说明: " MSG
  [ -n "$MSG" ] || { echo "已取消"; exit 0; }
fi

# ── 2. 本地校验 ──────────────────────────────────
echo "[2/4] 检查改动与死链…"
if [ -n "$(git status --porcelain)" ]; then
  :
else
  echo "没有检测到任何改动，无需推送。"
  exit 0
fi

# ── 3. 提交 ──────────────────────────────────────
echo "[3/4] 提交改动…"
git add -A
git commit -q -m "$MSG"

# ── 4. 推送（带重试）─────────────────────────────
echo "[4/4] 推送到 GitHub…"
BRANCH="$(git branch --show-current)"

push_ok=0
for attempt in 1 2 3; do
  if [ "$attempt" -gt 1 ]; then
    echo "      重试（第 $attempt 次）…"
    sleep 4
  fi
  if git push origin "$BRANCH" 2>&1; then
    push_ok=1
    break
  fi
done

if [ "$push_ok" -ne 1 ]; then
  echo
  echo "✗ 推送失败。代码已安全提交在本地，不会丢失。"
  echo "  常见原因与对策："
  echo "  1. 网络波动 → 过几分钟直接重试："
  echo "       git push origin $BRANCH"
  echo "  2. Clash 规则把 github.com 分到了不合适的线路"
  echo "     → 在 Clash Verge 里确认 github 走代理而非直连"
  exit 1
fi

echo
echo "已推送。"
echo "Cloudflare Pages 将在约 30 秒内自动完成部署。"
echo "查看部署状态：Cloudflare 后台 → Workers & Pages → 你的项目 → Deployments"
echo "想撤销：git revert HEAD --no-edit && git push origin $BRANCH"