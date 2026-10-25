#!/bin/bash
# publish-check.sh —— 发布前敏感信息扫描（做 git 仓库的 pre-commit 也合适）
#
# 用法：bash tools/publish-check.sh [要扫描的目录]      # 默认当前目录
# 退出码：0 = 干净（或只有"待人工确认"的提示）；1 = 有必须处理的命中
#
# 设计：分三级
#   ① 致命：这些**文件/目录本身**就不该出现在仓库里
#   ② 致命：文件**内容**里出现高置信敏感串（凭证、密钥、UID、会话 id）
#   ③ 提示：需要人工确认的（硬编码本机路径、个人昵称等）
set -u
ROOT="${1:-.}"
cd "$ROOT" || { echo "❌ 目录不存在：$ROOT"; exit 2; }

FATAL=0
warn() { printf '  ⚠️  %s\n' "$*"; }
bad()  { printf '  🔴 %s\n' "$*"; FATAL=1; }

# 只扫"会被 git 跟踪的文件"（尊重 .gitignore）——比扫全盘更准
if git rev-parse --git-dir >/dev/null 2>&1; then
  FILES=$(git ls-files -co --exclude-standard 2>/dev/null)
else
  FILES=$(find . -type f -not -path './.git/*' -not -path '*/__pycache__/*')
fi
# ⚠️ 排掉扫描器自己：它正文里就写着那些模式串，否则会"自己命中自己"
FILES=$(printf '%s\n' "$FILES" | grep -vE '(^|/)publish-check\.sh$')
[ -z "$FILES" ] && { echo "（没有可扫描的文件）"; exit 0; }

echo "════════ 发布前敏感扫描 ════════"
echo "扫描范围：$(echo "$FILES" | wc -l | tr -d ' ') 个文件（已按 .gitignore 过滤）"
echo

echo "① 不该存在的文件名："
HIT1=0
while IFS= read -r f; do
  case "$(basename "$f")" in
    bili_credential.json|.credentials.yaml|memory.db|turns.db|vectors.json|duty.log|state.json|verify-state.json|seen.md|rag.db|*.db|*.bak|*.bak-*)
      bad "$f"; HIT1=1 ;;
    *.zstd|*.m4a|*.mp4|*.mp3)
      bad "$f（运行产物/媒体文件）"; HIT1=1 ;;
    session-*)
      bad "$f（会话文件）"; HIT1=1 ;;
  esac
done <<< "$FILES"
[ "$HIT1" = 0 ] && echo "  ✅ 无"

echo
echo "② 内容里的高置信敏感串："
# 凭证 / Cookie / 密钥
PAT_CRED='SESSDATA|bili_jct|DedeUserID|dedeuserid|buvid|sessdata'
PAT_KEY='-----BEGIN [A-Z ]*PRIVATE KEY|sk-[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{16}|apiKey[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{8,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}'
# 你的身份 / 你的机器
PAT_ID='399853786|3546710689187965|亓迹流浪|收集橘子的Do(ro|ra)|session-dd8ebcb3'
PAT_HOST='/Users/[a-z]+/|/home/[a-z]+/'
HIT2=0
for pat in "$PAT_CRED" "$PAT_KEY" "$PAT_ID"; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # ⭐ 允许用 tools/publish-check.allow 逐条豁免（例如"只是 Cookie 字段名、没有值"）
    # ⭐ 行内标记豁免：该行带 `publish-check: ok`（并写明理由）就跳过 —— 例：
    #    pairs = (('SESSDATA', c.get('sessdata')), …)   # publish-check: ok 仅字段名
    if echo "$line" | grep -q 'publish-check: ok'; then
      printf '  （已豁免·行内标记）%s\n' "${line:0:110}"; continue
    fi
    bad "${line:0:150}"; HIT2=1
  done < <(grep -InE -- "$pat" $FILES 2>/dev/null | head -20)
done
[ "$HIT2" = 0 ] && echo "  ✅ 无"

echo
echo "③ 需要人工确认（不致命，但发布前最好处理）："
HIT3=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  warn "${line:0:150}"; HIT3=1
done < <(grep -InE -- "$PAT_HOST" $FILES 2>/dev/null | head -15)
[ "$HIT3" = 0 ] && echo "  ✅ 无"

echo
echo "════════ 结论 ════════"
if [ "$FATAL" = 1 ]; then
  echo "🔴 有必须处理的命中 —— **先别提交/推送**"
  echo "   处理办法：删掉该文件，或把内容换成占位符（如 <YOUR_UID> / \$HOME）"
  exit 1
fi
echo "✅ 没有致命命中$([ "$HIT3" = 1 ] && echo '（但 ③ 那些建议看一下）')"
echo "   下一步：用 'git add -A -n' 复核一遍即将提交的文件清单"
exit 0
