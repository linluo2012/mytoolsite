#!/usr/bin/env bash
#
# check-deploy.sh — 上线前本地预检，模拟 Cloudflare 构建环境
#
# 用法：./check-deploy.sh
#
# 作用：在推送前发现"域名没生效"这类问题，避免反复等 2 分钟看构建日志。

set -euo pipefail
cd "$(dirname "$0")"

PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

echo "==============================================="
echo " 上线预检（模拟 Cloudflare 构建）"
echo "==============================================="
echo

FAIL=0

# ── 检查 1：域名来源 ─────────────────────────────
echo "[检查 1] 域名解析"
echo "  当前构建会用到的域名："
"$PY" - <<'PY'
import os, pathlib, re, sys
ROOT = pathlib.Path(".")
env = os.environ.get("SITE_DOMAIN", "").strip()
def dotenv():
    p = ROOT/".env"
    if not p.exists(): return ""
    m = re.search(r'^SITE_DOMAIN\s*=\s*(.+)$', p.read_text(), re.M)
    return m.group(1).strip().strip('"\'') if m else ""
def wrl():
    p = ROOT/"wrangler.toml"
    if not p.exists(): return ""
    m = re.search(r'SITE_DOMAIN\s*=\s*"([^"]+)"', p.read_text())
    return m.group(1).strip() if m else ""
src = [("环境变量", env), (".env", dotenv()), ("wrangler.toml", wrl())]
found = False
for name, val in src:
    if val:
        print(f"    找到 -> {name}: {val}")
        found = True
if not found:
    print("    未找到任何域名配置")
    sys.exit(1)
PY
echo ""

# ── 检查 2：模拟云端构建 ─────────────────────────
echo "[检查 2] 模拟云端构建（不带环境变量）"
rm -rf dist
if "$PY" build.py --build; then
  echo "  构建成功"
else
  echo "  构建失败"
  FAIL=1
fi
echo ""

# ── 检查 3：产物检查 ─────────────────────────────
echo "[检查 3] 产物内容"
if [ -d dist ]; then
  echo "  页面数: $(ls dist/*.html 2>/dev/null | wc -l | tr -d ' ')"
  if [ -f dist/sitemap.xml ]; then
    echo "  sitemap: $(grep -c '<loc>' dist/sitemap.xml) 条"
  else
    echo "  sitemap: 缺失"; FAIL=1
  fi
  if [ -f dist/robots.txt ]; then
    echo "  robots: $(tail -1 dist/robots.txt)"
  else
    echo "  robots: 缺失"; FAIL=1
  fi
  if [ -f dist/_headers ]; then
    echo "  _headers: 已生成"
  else
    echo "  _headers: 缺失（安全响应头会丢失）"; FAIL=1
  fi

  # 关键：检查域名是否真的替换了
  if grep -q "example.com" dist/*.html 2>/dev/null; then
    echo ""
    echo "  ✗ 产物里仍有 example.com —— 线上所有链接会失效"
    FAIL=1
  else
    echo ""
    echo "  域名替换正常，无 example.com 残留"
  fi
else
  echo "  dist/ 未生成"; FAIL=1
fi
echo ""

rm -rf dist

# ── 结论 ─────────────────────────────────────────
echo "==============================================="
if [ "$FAIL" -eq 0 ]; then
  echo " 预检通过，可以推送"
  echo "==============================================="
  echo ""
  echo "下一步："
  echo "  ./deploy.sh \"说明\""
  echo ""
  echo "若 Cloudflare 构建仍报域名错误，在后台补环境变量："
  echo "  Settings → Environment variables → Add"
  echo "    SITE_DOMAIN = linwt.top"
  exit 0
else
  echo " 预检发现问题，请先修复"
  echo "==============================================="
  exit 1
fi