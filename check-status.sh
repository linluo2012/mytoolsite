#!/usr/bin/env bash
#
# check-status.sh — 站点状态日报
#
# 用法：
#   ./check-status.sh          完整检查（较慢，约 60 秒）
#   ./check-status.sh --quick  只查关键项（约 15 秒）
#
# 建议每天早上跑一次，存下输出做趋势对比。
# 搜索引擎的收录是渐进的，单次快照没意义，变化趋势才有意义。

set -uo pipefail
cd "$(dirname "$0")"

QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

DOMAIN="$(tr -d ' \n' < domain.txt 2>/dev/null)"
UA="Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
TODAY="$(date +%Y-%m-%d)"
LOG="status-log.txt"

fetch() { curl -s --noproxy '*' -L -A "$UA" --max-time 20 "$1" 2>/dev/null; }
code()  { curl -s --noproxy '*' -L -o /dev/null -w "%{http_code}" -A "$UA" --max-time 20 "$1" 2>/dev/null; }

echo "==============================================="
echo " 站点状态日报 · $DOMAIN · $TODAY"
echo "==============================================="
echo

# ── 1. 站点是否在线 ──
echo "【站点可用性】"
HOME_CODE=""
for i in 1 2 3; do
  HOME_CODE=$(code "https://$DOMAIN/")
  [ -n "$HOME_CODE" ] && [ "$HOME_CODE" != "000" ] && break
  sleep 1
done
if [ "$HOME_CODE" = "200" ]; then
  printf "  \033[32m✓\033[0m 首页 200\n"
else
  printf "  \033[31m✗\033[0m 首页 %s（站点可能异常）\n" "$HOME_CODE"
fi
echo

# ── 2. sitemap 状态 ──
echo "【sitemap】"
SM_CODE=$(code "https://$DOMAIN/sitemap.xml")
SM_N=$(fetch "https://$DOMAIN/sitemap.xml" | grep -c "<loc>")
SRC_N=$(ls source/*.html 2>/dev/null | wc -l | tr -d ' ')
if [ "$SM_CODE" = "200" ]; then
  printf "  \033[32m✓\033[0m 可访问，包含 %s 条 URL\n" "$SM_N"
else
  printf "  \033[31m✗\033[0m 返回 %s\n" "$SM_CODE"
fi
if [ "$SM_N" != "$SRC_N" ]; then
  printf "  \033[33m!\033[0m 与实际页面数 %s 不一致，需重新构建\n" "$SRC_N"
fi
echo

# ── 3. 关键页面可访问性 ──
echo "【关键页面】"
KEY_PAGES="index.html tools.html sales-tax-calculators.html payroll-burden-calculator.html break-even-calculator.html profit-margin-by-industry.html privacy.html"
FAILN=0
for p in $KEY_PAGES; do
  C=$(code "https://$DOMAIN/$p")
  if [ "$C" = "200" ]; then
    printf "  \033[32m✓\033[0m %-38s\n" "$p"
  else
    printf "  \033[31m✗\033[0m %-38s %s\n" "$p" "$C"
    FAILN=$((FAILN+1))
  fi
done
echo

# ── 4. 技术检查（quick 模式跳过）──
if [ "$QUICK" = "0" ]; then
  echo "【技术检查】"
  INDEX_OUT=$(./check-indexing.sh 2>/dev/null | grep -E "通过 [0-9]+ / [0-9]+")
  if [ -n "$INDEX_OUT" ]; then
    printf "  %s\n" "$INDEX_OUT" | sed 's/^  //'
    PASSN=$(printf "%s" "$INDEX_OUT" | grep -oE "通过 [0-9]+" | grep -oE "[0-9]+")
    if [ "$PASSN" = "17" ]; then
      printf "  \033[32m→ 全部通过\033[0m\n"
    else
      printf "  \033[33m→ 有未通过项，运行 ./check-indexing.sh 看详情\033[0m\n"
    fi
  fi
  echo
fi

# ── 5. 外部收录查询 ──
echo "【收录情况】"
printf "  BingSiteAuth  %s\n" "$(code "https://$DOMAIN/BingSiteAuth.xml")"
printf "  站点已就绪%s\n" "$( [ "$HOME_CODE" = "200" ] && echo "  ✓" || echo "  ✗")"
cat <<'TXT'
  需手动确认（搜索引擎后台数据无法通过脚本读取）：
    Bing→ 网站地图，看已收录页数
    GSC  → 网址检查 → 覆盖率，看已编入索引数
    GSC  → 效果，看曝光与点击
TXT
echo

# ── 6. 写入日志做趋势对比 ──
if [ -f "$LOG" ]; then
  PREV=$(tail -1 "$LOG" | awk -F'|' '{print $3}')
  if [ -n "$PREV" ] && [ "$PREV" != "$SM_N" ]; then
    echo "【变化】"
    printf "  sitemap URL 数：%s → %s（%+d）\n" "$PREV" "$SM_N" "$((SM_N-PREV))"
  fi
fi
# 追加并按「日期|状态|URL数」去重
printf "%s|%s|%s\n" "$TODAY" "$HOME_CODE" "$SM_N" >> "$LOG"
sort -u "$LOG" -o "$LOG"

echo "==============================================="
echo " 历史记录已存至 $LOG"
echo "==============================================="
echo
echo "等待期建议："
echo "  · 每天同一时间跑一次 ./check-status.sh，存下输出"
echo "  · 收录是渐进的，看趋势不看单次"
echo "  · AdSense / 联盟审核期间不必每天查，等通知即可"
