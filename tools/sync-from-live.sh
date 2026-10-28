#!/bin/bash
# sync-from-live.sh —— 把「线上正在跑的那份」**单向同步**进本仓库
#
# 为什么需要它：脚本平时是在 $BILI_DUTY_HOME 里改的（那才是运行的那份），
# 本仓库只是它的发布快照。**别两边各改** ✗ —— 改完线上就跑这个把改动搬过来。
#
# 用法：bash tools/sync-from-live.sh
set -euo pipefail

LIVE="${BILI_DUTY_HOME:-$HOME/.dsh/bili-duty}"
KIT="$(cd "$(dirname "$0")/.." && pwd)"

[ -d "$LIVE" ] || { echo "❌ 找不到线上目录：$LIVE（用 BILI_DUTY_HOME 指定）"; exit 1; }

echo "① 同步脚本（$LIVE → $KIT/scripts）"
for f in patch-plugin.sh selfcheck-headless.sh archive-sessions.sh \
         dm-session.mjs feedback.py rag.py duty_mcp.py persona-selfwrite.sh; do
  if [ -f "$LIVE/$f" ]; then
    cp -p "$LIVE/$f" "$KIT/scripts/$f"; echo "   ✓ $f"
  else
    echo "   ⚠️ 线上没有 $f"
  fi
done

echo "② 渲染视觉 overlay 模板（把真实 home 换成占位符）"
sed "s|$LIVE|{{BILI_DUTY_HOME}}|g" "$LIVE/vision-overlay.yml" \
  > "$KIT/scripts/vision-overlay.yml.template"
echo "   ✓ vision-overlay.yml.template"

echo "③ 同步补丁素材"
cp -p "$LIVE/patches/dmsplit_patch.py" "$KIT/patches/dmsplit_patch.py"
echo "   ✓ patches/dmsplit_patch.py"

cat <<'EOF'

④ 交给你复核（这一步别省）：
   bash tools/publish-check.sh .     # 三级敏感扫描
   git add -A -n                     # 白名单会挡掉新文件，**看清清单里有没有你要的东西**
EOF
