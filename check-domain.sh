#!/usr/bin/env bash
#
# check-domain.sh — 诊断自定义域名是否可用
#
# 用法：./check-domain.sh
#
# 检查三件事：
#   1. DNS 是否解析（用 DoH 绕过本地代理污染）
#   2. HTTPS 证书是否签发
#   3. 页面实际能否返回内容

set -uo pipefail
cd "$(dirname "$0")"

DOMAIN="$(grep -E '^SITE_DOMAIN=' .env 2>/dev/null | cut -d= -f2- | tr -d ' \"')"
[ -z "$DOMAIN" ] && DOMAIN="$(tr -d ' \n' < domain.txt 2>/dev/null)"
[ -z "$DOMAIN" ] && { echo "找不到域名配置"; exit 1; }

PY="/Users/linluo2012/.workbuddy/binaries/python/versions/3.13.12/bin/python3"
[ -x "$PY" ] || PY="$(command -v python3)"

echo "==============================================="
echo " 域名诊断：$DOMAIN"
echo "==============================================="
echo

# ── 1. DNS ───────────────────────────────────────
echo "[1/3] DNS 解析"
IPS="$("$PY" - "$DOMAIN" <<'PY'
import sys, urllib.request, json
d = sys.argv[1]
req = urllib.request.Request(
    f"https://cloudflare-dns.com/dns-query?name={d}&type=A",
    headers={"accept": "application/dns-json"})
try:
    r = json.load(urllib.request.urlopen(req, timeout=12))
    out = [a["data"] for a in r.get("Answer", []) if a.get("type") == 1]
    print(" ".join(out))
except Exception as e:
    print("ERR:" + str(e))
PY
)"
if [[ "$IPS" == ERR:* || -z "$IPS" ]]; then
  # DoH 偶发失败时退回系统 dig，避免误报"域名未生效"
  IPS2="$(dig +short "$DOMAIN" A 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ')"
  if [ -n "$IPS2" ]; then
    echo "  ✓ A 记录: $IPS2  (DoH 查询失败，已回退到 dig)"
  else
    echo "  ✗ 查不到 A 记录 —— 域名可能尚未生效，或 NS 未正确指向 Cloudflare"
  fi
else
  echo "  ✓ A 记录: $IPS"
  if echo "$IPS" | grep -q "^198\.18\."; then
    echo "    ⚠ 这是代理的 fake-IP，本地查询被劫持了（不影响真实用户）"
  fi
fi
echo

# ── 2. HTTPS ─────────────────────────────────────
echo "[2/3] HTTPS 可达性"
CODE="$(curl -s --noproxy '*' -o /dev/null -w "%{http_code}" \
        --max-time 20 "https://$DOMAIN/" 2>/dev/null)"
if [ "$CODE" = "200" ]; then
  echo "  ✓ 首页返回 HTTP 200，站点正常"
elif [ "$CODE" = "307" ] || [ "$CODE" = "308" ]; then
  # Cloudflare 对 .html 页面可能返回 307 规范跳转，属正常行为
  FINAL="$(curl -s --noproxy '*' -L -o /dev/null -w "%{http_code}" \
          --max-time 25 "https://$DOMAIN/" 2>/dev/null)"
  if [ "$FINAL" = "200" ]; then
    echo "  ✓ 返回 $CODE 跳转，跟随后HTTP $FINAL（Cloudflare 规范跳转，正常）"
    CODE=200
  else
    echo "  ✗ 跳转后仍无法访问（最终 HTTP $FINAL）"
  fi
elif [ "$CODE" = "000" ]; then
  echo "  ✗ 无法建立连接"
  echo ""
  echo "    可能原因："
  echo "      1. Cloudflare 后台 Workers & Pages → linwt → Settings"
  echo "         → Domains & Routes 里没有添加 $DOMAIN"
  echo "      2. 加了但状态不是 Active（等证书签发，通常几分钟）"
  echo "      3. DNS 记录是灰云（DNS only），改成橙云 Proxied"
else
  echo "  ! 返回 HTTP $CODE（站点已响应，但有异常）"
  case "$CODE" in
    522) echo "    522 = Cloudflare 无法连接到源站，检查项目是否在运行" ;;
    525) echo "    525 = SSL 握手失败，检查证书状态" ;;
    530) echo "    530 = 域名未关联到任何项目，需在 Domains & Routes 添加" ;;
  esac
fi
echo

# ── 3. sitemap ───────────────────────────────────
echo "[3/3] sitemap 可访问性"
SCODE="$(curl -s --noproxy '*' -o /dev/null -w "%{http_code}" \
         --max-time 20 "https://$DOMAIN/sitemap.xml" 2>/dev/null)"
if [ "$SCODE" = "200" ]; then
  N="$(curl -s --noproxy '*' --max-time 20 "https://$DOMAIN/sitemap.xml" 2>/dev/null | grep -c '<loc>')"
  echo "  ✓ sitemap.xml 可访问，包含 $N 条 URL"
  echo ""
  echo "  现在可以去 Search Console 提交："
  echo "    https://$DOMAIN/sitemap.xml"
elif [ "$SCODE" = "000" ]; then
  echo "  ✗ 无法访问（同上，先解决域名问题）"
else
  echo "  ! HTTP $SCODE"
fi
echo

echo "==============================================="
if [ "$CODE" = "200" ] && [ "$SCODE" = "200" ]; then
  echo " 域名完全正常，可以提交 sitemap 了"
else
  echo " 域名还不可用，请先解决上面的问题"
fi
echo "==============================================="

exit 0