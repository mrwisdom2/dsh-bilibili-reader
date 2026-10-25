#!/bin/bash
# selfcheck-headless.sh —— 基线自检：headless 那一轮**能不能自己退出** + 私信链有没有被占用
#
# 【为什么需要它】
#   meow-memory 的 dream 调度器 / 心跳 / 服务重试都用普通定时器，会让 Node 事件循环
#   "永远有事做" ⇒ 一次性 headless 会话**永不退出**。而刷B站那一轮就是这种会话，
#   于是会**永久挂死**：不报错、不写「刷B站结束」、窗口名额白烧。
#   我们靠 patch-plugin.sh 的补丁4 给它加了 unref —— **但插件一升级，补丁就没了**。
#   这个自检就是那道兜底：跑一句极短提示词，正常应数秒内退出。
#
# 判据：👉 **3 秒左右 = 正常；超过 90 秒 = 被钉住了**（危险，刷B站会挂死）
#
# 用法：bash ~/.dsh/bili-duty/selfcheck-headless.sh
#   退出码 0 = 正常；1 = 异常（并在输出里给出修复命令）
#
# 【第二项检查（2026-10-24 加）】私信链的常驻会话有没有被别的进程攥着
#   `session.lock` 是持久化层的**跨进程 flock**，持有期 = 写句柄存活期。
#   2026-10-24 实证：`dsh web`（GUI 宿主）会长期持有它 ⇒ 私信轮 adopt 不了 ⇒
#   回复降级成"缺逐字历史"（仍会回，所以是**静默**的质量下降）。
#   内核在进程退出时自动释放 ⇒ **重启 dsh 即可解开**。这里只做检测与提示。
set -u
LIMIT="${SELFCHECK_LIMIT:-90}"
HOME_DIR="$HOME/.dsh/bili-duty"
OUT="/tmp/headless-selfcheck.out"
cd "$HOME_DIR" || { echo "❌ 找不到 $HOME_DIR"; exit 2; }

# ── 检查：私信链常驻会话的写句柄有没有被别的进程占着 ──
# 读会话 id：环境变量 BILI_DM_SESSION_ID → local.config.json（读不到就返回空）
# ⚠️ 路径走 argv 传进 python，python 程序整体用单引号包 —— 别把多行 python 塞进 $()，引号会打架。
read_dm_sid() {
  if [ -n "${BILI_DM_SESSION_ID:-}" ]; then printf '%s' "$BILI_DM_SESSION_ID"; return; fi
  local cfg="${BILI_DUTY_HOME:-$HOME/.dsh/bili-duty}/local.config.json"
  [ -f "$cfg" ] || return 0
  python3 -c 'import json,sys;print(json.load(open(sys.argv[1],encoding="utf-8")).get("dmSessionId",""))' "$cfg" 2>/dev/null
}

check_dm_lock() {
  local sid lock holder
  sid=$(read_dm_sid)
  [ -n "$sid" ] || return 0
  lock=$(ls -1 "${DSH_HOME:-$HOME/.dsh}"/sessions/*/"$sid"/session.lock 2>/dev/null | head -1)
  [ -n "$lock" ] || return 0
  holder=$(lsof "$lock" 2>/dev/null | tail -1 | awk '{print $2}')
  if [ -n "$holder" ]; then
    echo "⚠️  私信链被 PID $holder 占着（$(ps -o comm= -p "$holder" 2>/dev/null | sed 's|.*/||')）"
    echo "    ⇒ 从现在起私信回复会「缺逐字历史」（仍会回）；重启 dsh 即可释放。"
  else
    echo "✅ 私信链未被占用（adopt 可用）"
  fi
}

START=$(date +%s)
dsh --profile headless --patch "$HOME_DIR/headless-overlay.yml" "只回复两个字：可以" >"$OUT" 2>&1 &
PID=$!

for _ in $(seq 1 "$LIMIT"); do
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID"; CODE=$?
    ELAPSED=$(( $(date +%s) - START ))
    if [ "$CODE" = 0 ]; then
      echo "✅ headless 基线正常：${ELAPSED}s 退出（code=0）"
      check_dm_lock
      exit 0
    fi
    echo "⚠️ headless 基线异常：${ELAPSED}s 退出，但 code=$CODE"
    tail -5 "$OUT"
    check_dm_lock
    exit 1
  fi
  sleep 1
done

kill -9 "$PID" 2>/dev/null
echo "❌ headless 基线失败：超过 ${LIMIT}s 仍未退出。"
echo "   十有八九是某个插件的定时器没 unref（补丁被升级冲掉了）⇒ 刷B站会永久挂死。"
echo "   修复：bash ~/.dsh/bili-duty/patch-plugin.sh"
check_dm_lock
exit 1
