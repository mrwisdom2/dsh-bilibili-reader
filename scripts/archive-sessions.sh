#!/bin/bash
# archive-sessions.sh —— 把刷B站工作区里「除私信链以外」的会话归档
#
# 【为什么】
#   刷B站每一轮都是**新开的会话**（不 adopt 历史、用完即弃）。跑久了
#   ~/.dsh/sessions/--Users-zifan-.dsh-bili-duty--/ 会堆几十上百个，
#   除了占会话列表和磁盘没有别的用途。
#   两条链里唯一需要"连续性"的是**私信链**（id 见 local.config.json 的 dmSessionId），必须留。
#
# 【用法】bash ~/.dsh/bili-duty/archive-sessions.sh
#   KEEP 名单：想永远归档不掉的会话（例如给 GUI 当默认替身的那条），
#   把 id 写进 ~/.dsh/bili-duty/session-archive/KEEP.txt（一行一个）。
#   归档到 ~/.dsh/bili-duty/session-archive/<日期>/ ，并追加清单到 ARCHIVED-LIST.txt
#
# 【安全】
#   · 有轮次在跑时**拒绝执行**（锁着的会话不能动）
#   · 只动 bili-duty 工作区下、名字形如 session-<uuid> 的目录
#   · 永远跳过 KEEP（私信链）
#   · 只 mv（同盘是改名，不是复制）⇒ 不会损坏文件
set -u

SRC="$HOME/.dsh/sessions/--Users-zifan-.dsh-bili-duty--"
# 私信链的会话 id：环境变量 BILI_DM_SESSION_ID → local.config.json（读不到 = 不特别保留）
# ⚠️ 注意：别把带引号的多行命令塞进 ${VAR:-$(...)}，引号会被吃掉（踩过）。
BILI_HOME="${BILI_DUTY_HOME:-$HOME/.dsh/bili-duty}"
KEEP="${BILI_DM_SESSION_ID:-}"
if [ -z "$KEEP" ] && [ -f "$BILI_HOME/local.config.json" ]; then
  KEEP=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("dmSessionId",""))' "$BILI_HOME/local.config.json" 2>/dev/null)
fi   # ← 私信链，永远保留
DAY="$(date +%Y-%m-%d)"
DST="$HOME/.dsh/bili-duty/session-archive/$DAY"
LISTFILE="$HOME/.dsh/bili-duty/session-archive/ARCHIVED-LIST.txt"
KEEPLIST="$HOME/.dsh/bili-duty/session-archive/KEEP.txt"

[ -d "$SRC" ] || { echo "❌ 找不到工作区目录：$SRC"; exit 1; }

# ① 有轮次在跑就别动
#    ⚠️ 别用 `ps | grep 模式`：grep 会匹配到**它自己**的命令行 ⇒ 永远为真（2026-10-23 踩过）。
#    pgrep -f 不会把自己算进去。
if pgrep -f "dm-session\.mjs" >/dev/null 2>&1 || pgrep -f "profile headless" >/dev/null 2>&1; then
  echo "⛔ 有刷B站轮次正在跑（或刚起）⇒ 先等它结束再归档。"
  echo "   （先查 duty.log 里有没有配对的「刷B站结束」再重试）"
  exit 1
fi

mkdir -p "$DST"
moved=0
for d in "$SRC"/session-*/; do
  [ -d "$d" ] || continue
  id="$(basename "$d")"
  [ "$id" = "$KEEP" ] && continue            # ② 私信链永远跳过
  if [ -f "$KEEPLIST" ] && grep -qx "$id" "$KEEPLIST" 2>/dev/null; then
    echo "  skip(kept): $id"
    continue
  fi
  case "$id" in session-*) ;; *) continue;; esac   # ③ 只认 session-<uuid>
  mt="$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$d" 2>/dev/null)"
  printf "%s  %s  %s\n" "$id" "$mt" "$DAY" >> "$LISTFILE"
  mv "$d" "$DST/$id" && moved=$((moved+1))
done

echo "✅ 已归档 $moved 个会话 → $DST"
echo "   保留（私信链）：$KEEP"
echo "   恢复：mv $DST/session-<id> $SRC/"
