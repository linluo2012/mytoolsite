#!/usr/bin/env bash
#
# gh-login.sh — 交互式 GitHub 登录，避开手工粘贴 token 的坑
#
# 用法：./gh-login.sh
#
# 为什么需要它：直接 git push 时粘贴 token 容易出这几种错
#   - 前后带空格或换行
#   - 粘到了 Username 字段
#   - token 过期了但没察觉
# 这个脚本会引导你逐项确认，并在推送后验证是否真的成功。

set -euo pipefail
cd "$(dirname "$0")"

echo "==============================================="
echo " GitHub 登录配置向导"
echo "==============================================="
echo ""

# ── 1. 检查仓库地址 ──────────────────────────────
REPO_URL="$(git remote get-url origin 2>/dev/null || echo '')"
if [ -z "$REPO_URL" ]; then
  echo "✗ 没有配置远程仓库。先运行："
  echo "  git remote add origin https://github.com/你的用户名/仓库名.git"
  exit 1
fi
echo "远程仓库: $REPO_URL"

USER="$(echo "$REPO_URL" | sed -E 's#.*github\.com[:/]+([^/]+)/.*#\1#')"
echo "用户: $USER"
echo ""

# ── 2. 清除旧凭据 ────────────────────────────────
echo "[1/4] 清除可能存在的旧凭据…"
printf "protocol=https\nhost=github.com\n\n" | git credential-osxkeychain erase 2>/dev/null || true
git config --global credential.helper osxkeychain
echo "      已启用 macOS 钥匙串，之后只需登录一次"
echo ""

# ── 3. 校验 Token ────────────────────────────────
echo "[2/4] 校验 Token…"
echo
echo "  如果还没有 Token，现在去生成："
echo "    github.com/settings/tokens/new"
echo "    Note 随便填，勾选 repo 权限，滑到底点 Generate"
echo "    复制那串 ghp_开头的字符"
echo

read -r -s -p "  粘贴 Token（输入时屏幕不显示，属正常）: " TOKEN
echo
echo

if [ -z "$TOKEN" ]; then
  echo "✗ 未输入 Token，已取消。"
  exit 1
fi

# 去掉可能存在的前后空白与换行
CLEAN_TOKEN="$(printf '%s' "$TOKEN" | tr -d '[:space:]')"

case "$CLEAN_TOKEN" in
  ghp_*|github_pat_*) ;;
  *)
    echo "⚠️  Token 格式看起来不对。正常的 Personal Access Token 应该："
    echo "    - 以 ghp_ 开头（classic token），或"
    echo "    - 以 github_pat_ 开头（fine-grained token）"
    echo "    你输入的是: ${CLEAN_TOKEN:0:8}..."
    echo
    read -r -p "  仍要继续？(y/n) " c
    [ "$c" = "y" ] || exit 1
    ;;
esac

# 用 API 验证 token 是否有效且有权限
echo "      正在验证…"
CODE="$(curl -s -o /tmp/_gh_check.json -w "%{http_code}" \
  -H "Authorization: Bearer $CLEAN_TOKEN" \
  https://api.github.com/user 2>/dev/null || echo "000")"

if [ "$CODE" = "200" ]; then
  LOGIN="$(grep -o '"login"[[:space:]]*:[[:space:]]*"[^"]*"' /tmp/_gh_check.json | head -1 | sed -E 's/.*"([^"]*)"$/\1/')"
  echo "      Token 有效，认证身份: $LOGIN"
  if [ "$LOGIN" != "$USER" ]; then
    echo "      ⚠️  注意：这个 Token 属于 $LOGIN，但仓库路径是 $USER"
    echo "         如果不是同一个账号，推送会失败。"
  fi
  rm -f /tmp/_gh_check.json
elif [ "$CODE" = "401" ]; then
  echo "      Token 无效或已过期。请重新生成一个。"
  exit 1
elif [ "$CODE" = "000" ]; then
  echo "      无法连接 API，检查网络或代理。"
  exit 1
else
  echo "      验证返回 HTTP $CODE，继续尝试推送。"
fi
echo ""

# ── 4. 存入钥匙串 ────────────────────────────────
echo "[3/4] 保存凭据到钥匙串…"
printf "protocol=https\nhost=github.com\nusername=%s\npassword=%s\n\n" \
  "$USER" "$CLEAN_TOKEN" | git credential-osxkeychain store
echo "      已保存"
echo ""

# ── 5. 推送 ──────────────────────────────────────
echo "[4/4] 推送代码…"
echo "      （如果失败，多半是 Token 缺少 repo 权限或已过期）"
echo ""

if git push -u origin main 2>&1; then
  echo ""
  echo "==============================================="
  echo "✓ 推送成功"
  echo "==============================================="
  echo ""
  echo "下一步：Cloudflare 后台配置（3 项）"
  echo "  Build command:            python3 build.py --build"
  echo "  Build output directory:   dist"
  echo "  环境变量:                  SITE_DOMAIN = 你的域名"
else
  echo ""
  echo "推送失败。常见原因："
  echo "  1. Token 没勾选 repo 权限 → 重新生成时勾上"
  echo "  2. Token 已过期 → 生成时把有效期选长一些"
  echo "  3. 仓库名拼错 → 检查 github.com/$USER 下确实有这个仓库"
  exit 1
fi

# 清理临时文件
unset CLEAN_TOKEN TOKEN