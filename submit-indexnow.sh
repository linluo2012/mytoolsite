#!/usr/bin/env bash
#
# submit-indexnow.sh — 主动把 URL 推送给 Bing（IndexNow 协议）
#
# 用法：
#   ./submit-indexnow.sh                    # 推送 sitemap 里的全部 URL
#   ./submit-indexnow.sh https://linwt.top/x.html   # 只推某一条（刚上线的新页面用这个）
#
# 说明：
#   · IndexNow 是 Bing / Yandex / Seznam 支持的即时推送协议，Google 目前不支持。
#     它的作用是「通知搜索引擎这些 URL 有更新」，能明显加快 Bing 的抓取，
#     但不等于保证收录——最终仍要等爬虫抓完。
#   · 密钥文件必须放在 source/ 下，文件名是「32 位十六进制.txt」，文件内容就是密钥本身。
#     （放在 source/ 里才会被 build.py 自动复制到线上根目录）
#   · 每上线一个新页面跑一次即可，不需要天天重复推送。
#
set -euo pipefail
cd "$(dirname "$0")"

PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

KEY_FILE="$(ls source/ 2>/dev/null | grep -E '^[0-9a-f]{32}\.txt$' | head -1 || true)"
if [ -z "$KEY_FILE" ]; then
  echo "✗ source/ 下没有找到 IndexNow 密钥文件（形如 32位十六进制.txt）"
  exit 1
fi
KEY="${KEY_FILE%.txt}"

DOMAIN="$(grep -E '^SITE_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' "' || true)"
[ -n "$DOMAIN" ] || DOMAIN="$(tr -d ' \n' < domain.txt)"

if [ $# -ge 1 ]; then
  URLS="$(printf '%s\n' "$@")"
else
  URLS="$(curl -sL "https://$DOMAIN/sitemap.xml" | grep -o '<loc>[^<]*</loc>' | sed 's/<[^>]*>//g')"
fi

COUNT="$(printf '%s\n' "$URLS" | grep -c . || true)"
echo "域名:   $DOMAIN"
echo "密钥:   $KEY_FILE"
echo "待推送: $COUNT 条"

JSON="$(printf '%s\n' "$URLS" | DOMAIN="$DOMAIN" KEY="$KEY" "$PY" -c '
import sys, json, os
urls = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps({"host": os.environ["DOMAIN"],
                  "key": os.environ["KEY"],
                  "urlList": urls}, ensure_ascii=False))
')"

echo
echo "POST https://api.indexnow.org/indexnow"
curl -s -X POST "https://api.indexnow.org/indexnow" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d "$JSON" \
  -w "\nHTTP %{http_code}\n"
echo
echo "返回码：200 已接受 / 202 已排队（都算成功）；400 参数有误；403 密钥无效或文件取不到。"
