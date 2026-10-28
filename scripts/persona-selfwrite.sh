#!/bin/bash
# persona-selfwrite.sh —— 「她来写人设、宿主只取数和复核」（2026-10-28 起）
#
# 为什么这么分工：
#   ① 取数只能宿主做 —— 赞/回复/收藏那三个信号，链那一轮拿不到 ✗（而且「收到的赞」读一次就清空 ✓）
#   ② 提炼交给她 —— 用她自己的话写 §三/§四/§二 ⇒ 人设、语气、偏好从同一个人格里长出来 ✓
#   ③ 复核必须宿主做 —— 写偏/写长/动到 §一 都有可能 ✗ ⇒ 硬保险：§一 的 md5 变了就**整份回滚** ✓
#
# 用法： bash ~/.dsh/bili-duty/persona-selfwrite.sh        # 每天 08:30 那套九步调它
set -u
cd "$(dirname "$0")" || exit 1
HOME_DIR="$(pwd)"
DATE="$(date +%F)"
AG="$HOME_DIR/AGENTS.md"
SNAP_DIR="$HOME_DIR/persona-history"
FB="$HOME_DIR/digest/feedback-$DATE.md"
PRE="$HOME_DIR/tmp/AGENTS.pre-selfwrite.md"
DIFF="$SNAP_DIR/diff-$DATE.md"
mkdir -p "$SNAP_DIR" "$HOME_DIR/digest" "$HOME_DIR/tmp"

echo "── ① 宿主取数（链拿不到的东西）──"
"$HOME_DIR/.venv/bin/python" "$HOME_DIR/feedback.py" --days 3 > "${FB}" 2>"$HOME_DIR/tmp/fb.err" || {
  echo "   [warn] feedback.py failed; keep old ledger (see tmp/fb.err)"
}
echo "   → ${FB}（$(wc -c < "$FB" 2>/dev/null | tr -d ' ') 字节）"

# 硬保险：记下 §一 的指纹 + 留一份改前副本
cp "$AG" "$PRE"
md5sec() { sed -n '/^## 一/,/^## 二/p' "$1" | md5; }
CORE_BEFORE="$(md5sec "$AG")"
SIZE_BEFORE="$(stat -f%z "$AG")"

echo "── ② 交给她写（起一个回合；cwd = 家目录 ⇒ 人格与记忆自动就在）──"
TASK="【每天的自我整理】今天是 ${DATE}。请**只改当前工作目录里 AGENTS.md 的这三节**，别的什么都不做：

1) 先读两份材料：\`digest/feedback-$DATE.md\`（宿主抓的原始反馈：谁点了赞、谁回过话、收藏了什么）
   和 \`out/$DATE.md\`（你自己的今天日报）；再按需回忆你的记忆库。
2) 然后**用你自己的话**更新这三节（其余节一个字都不许动 ✗）：
   · §二 演进区 —— 随你 ✓（你的观察、教训、想记的；保持简短）
   · §三 反馈台账 —— 把材料里的事实说清楚（谁点了你的赞、谁回过你的话、收藏了什么）；没有新信号就写"近三天没有新信号" ✓
   · §四 主人偏好 —— 3~7 条，**每条后面用括号写上依据**（依据：某天的日报/某条原话/某次反馈），总长 ≤600 字 ✓
3) ⛔ 铁律（违反就算这轮失败）：
   · §一 核心区**一个字都不许动** ✗（宿主会核 md5，动一下就整份回滚 ✗）
   · **不许发明** —— 没依据的偏好不写；拿不准就写"没查到" ✓
   · 每条一句话；别把视频逐条抄进来（素材在 RAG 里 ✓）
   · 改完**不要**发私信、不要动别的文件、不要在回复里解释你做了什么（宿主会自己 diff ✓）"

# 给她一个硬时限：8 分钟后仍在跑就杀掉（今天它把 F 步堵了 949 秒 ✗）
"$HOME_DIR/.venv/bin/python" - "$HOME_DIR" <<'PYEOF'
import subprocess, sys, pathlib
home = pathlib.Path(sys.argv[1])
task = (home / 'tmp' / 'selfwrite.task.txt').read_text(encoding='utf-8')
out = open(home / 'tmp' / 'selfwrite.out', 'w')
try:
    r = subprocess.run(['node', str(home / 'dm-session.mjs'), '--profile', 'headless',
                        '--patch', 'headless-overlay.yml', task], cwd=str(home),
                       stdout=out, stderr=subprocess.STDOUT, timeout=480)
    print(f'   （回合正常结束 code={r.returncode}）')
except subprocess.TimeoutExpired:
    print('   ⏰ 回合超过 8 分钟 ⇒ 已杀掉（她写到一半的改动会被下面的复核兜住 ✓）')
PYEOF
RC=$?
echo "   回合退出码=${RC}（输出尾巴见 tmp/selfwrite.out）"

echo "── ③ 宿主复核 ──"
CORE_AFTER="$(md5sec "$AG")"
SIZE_AFTER="$(stat -f%z "$AG")"
if [ "$CORE_BEFORE" != "$CORE_AFTER" ]; then
  cp "$PRE" "$AG"
  echo "   🚨 §一 核心区被动过 ⇒ **已整份回滚**（改前副本：${PRE}）"
  echo "回滚：§一 md5 变了（$CORE_BEFORE → ${CORE_AFTER}）" > "$DIFF"
else
  echo "   ✅ §一 核心区未被改动（md5 一致）"
  cp "$AG" "$SNAP_DIR/AGENTS-$DATE.md"           # 当天的干净快照
  { echo "# $DATE 她自己改了什么（§二/§三/§四 的 diff 摘要）"; echo
    diff "$PRE" "$AG" | sed -n '1,80p' || true
  } > "$DIFF"
  echo "   快照：persona-history/AGENTS-$DATE.md ｜ 变化摘要：persona-history/diff-$DATE.md"
fi
echo "   体积：$SIZE_BEFORE → $SIZE_AFTER 字节（差 $((SIZE_AFTER-SIZE_BEFORE))）"
echo "── 完成（简报里可写：台账/偏好由她自己写 ✓，核心区 $([ "$CORE_BEFORE" = "$CORE_AFTER" ] && echo 未动 ✓ || echo 已回滚 🚨)）──"
