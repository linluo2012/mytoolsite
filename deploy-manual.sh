#!/usr/bin/env bash
#
# deploy-manual.sh — 手动部署通道（GitHub 自动集成失效时使用）
#
# 用法：
#   ./deploy-manual.sh            # 部署到默认项目 linwt
#   ./deploy-manual.sh linwt      # 指定 Workers 项目名
#
# 与 deploy.sh 的区别：
#   deploy.sh       = git push，靠 Cloudflare Workers Builds 自动构建（平时走这条）
#   deploy-manual.sh = 本地构建 + wrangler 直推（自动集成挂了才走这条）
#
# 三个关键细节（都是踩过的坑，改动时别删）：
#   1. NODE_OPTIONS=--dns-result-order=ipv4first
#      不加这个，wrangler 在代理环境下约一半请求会 "API timed out"。
#      原因是 Node 默认优先解析 IPv6，而本地代理只对 IPv4 生效。
#   2. --compatibility-date 必填
#      仓库里刻意不放 wrangler.toml（Workers Builds 会读它、覆盖后台构建配置），
#      所以只能在命令行传。
#   3. 用 --name 指定同名项目
#      项目名写错会新建一个 Worker，不会覆盖线上站点。
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="${1:-linwt}"
PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"
W="/Users/linluo2012/.workbuddy/binaries/node/workspace/node_modules/.bin/wrangler"
COMPAT_DATE="2026-10-06"

if [ ! -x "$W" ]; then
  echo "✗ 找不到 wrangler：$W"
  echo "  安装：cd /Users/linluo2012/.workbuddy/binaries/node/workspace \\"
  echo "        && npm install wrangler"
  exit 1
fi

echo "【1/3】构建产物（build.py --build → dist/）"
"$PY" build.py --build | tail -3
echo "      dist/ 共 $(ls dist | wc -l | tr -d ' ') 个文件"

echo
echo "【2/3】部署到 Workers 项目：$PROJECT"
deploy_out=""
for i in 1 2 3 4 5 6; do
  out=$(NODE_OPTIONS="--dns-result-order=ipv4first" \
        "$W" deploy --name "$PROJECT" --assets dist \
        --compatibility-date "$COMPAT_DATE" 2>&1)
  if echo "$out" | grep -q "timed out"; then
    echo "      第 $i 次超时，重试…"
    sleep 4
    continue
  fi
  deploy_out="$out"
  break
done

if [ -z "$deploy_out" ]; then
  echo
  echo "✗ 6 次全部超时，未部署成功。"
  echo "  常见原因：代理不通（先确认 curl https://api.cloudflare.com 能返回 400）、"
  echo "  或登录失效（重跑：wrangler login）。代码在本地没有丢失。"
  exit 1
fi

# 注意：没有新文件时 wrangler 不打印 "Success!" 字样，
# 所以成功标志用 "Version ID"，不要用 Success 判断。
echo "$deploy_out" | grep -E "Uploaded|Deployed|Version ID|https://" | tail -6 || true

if ! echo "$deploy_out" | grep -q "Version ID"; then
  echo
  echo "✗ 部署未成功，完整输出如下："
  echo "$deploy_out" | tail -25
  exit 1
fi

echo
echo "【3/3】线上验证"
DOMAIN="$(grep -E '^SITE_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "' || true)"
[ -n "$DOMAIN" ] || DOMAIN="linwt.top"
for u in "/" "/sitemap.xml" "/ads.txt"; do
  code=$(curl -sL -A "Mozilla/5.0" -o /dev/null -w "%{http_code}" "https://$DOMAIN$u")
  printf "      %-14s %s\n" "$u" "$code"
done
echo
echo "完成。若上面都是 200，改动已生效。"
