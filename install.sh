#!/bin/bash
# install.sh —— 把本仓库的脚本铺到刷B站的家目录，并渲染模板
#
# 设计原则：**只做加法、不删东西**；要覆盖的文件先备份到 install-backup-<时间>/
# 用法：bash install.sh            （家目录取 $BILI_DUTY_HOME，默认 ~/.dsh/bili-duty）
set -euo pipefail

KIT="$(cd "$(dirname "$0")" && pwd)"
HOME_DIR="${BILI_DUTY_HOME:-$HOME/.dsh/bili-duty}"
DSH_HOME="${DSH_HOME:-$HOME/.dsh}"
TS="$(date +%m%d-%H%M)"
BK="$HOME_DIR/install-backup-$TS"

say() { printf '  %s\n' "$*"; }

echo "① 目标家目录：$HOME_DIR"
mkdir -p "$HOME_DIR" "$BK"

echo "② 铺脚本（要覆盖的先备份到 $(basename "$BK")/）"
for f in "$KIT"/scripts/*; do
  n="$(basename "$f")"
  case "$n" in *.template) continue;; esac
  if [ -f "$HOME_DIR/$n" ] && ! cmp -s "$f" "$HOME_DIR/$n"; then
    cp -a "$HOME_DIR/$n" "$BK/$n"; say "覆盖 $n（旧版已备份）"
  else
    say "放置 $n"
  fi
  cp -a "$f" "$HOME_DIR/$n"
done

echo "③ 渲染配置模板"
sed "s|{{BILI_DUTY_HOME}}|$HOME_DIR|g" \
    "$KIT/scripts/vision-overlay.yml.template" > "$HOME_DIR/vision-overlay.yml"
say "已生成 $HOME_DIR/vision-overlay.yml"
if [ ! -f "$HOME_DIR/local.config.json" ]; then
  cp "$KIT/config.example.json" "$HOME_DIR/local.config.json"
  say "已生成 local.config.json —— ⚠️ **请先填它**（dmSessionId / mainUid / favMediaId）"
else
  say "local.config.json 已存在，未动"
fi

echo "④ 检查运行时依赖"
command -v python3 >/dev/null && say "python3 ✓" || say "⚠️ 缺 python3"
curl -s --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1 \
  && say "Ollama ✓（RAG 语义检索用得上）" || say "⚠️ Ollama 不可达（RAG 检索会退化成关键词）"
[ -d "$DSH_HOME/profiles/web/node_modules/dsh-bili-scroll" ] \
  && say "上游插件已装在 web profile ✓" || say "⚠️ 没找到上游插件（先装它：见 README 第三节）"

cat <<EOF

⑤ 剩下的手动步骤（本脚本**不会**替你改 profile 配置）：
   1. 填 $HOME_DIR/local.config.json
   2. 把 $KIT/templates/cordis.patch.*.yml 里的配置**合并**进
      $DSH_HOME/profiles/<web|headless>/cordis.patch.yml（密钥只写 apiKeyEnv）
   3. bash $HOME_DIR/patch-plugin.sh      # 打七件补丁（幂等；每次插件升级后重跑）
   4. bash $HOME_DIR/selfcheck-headless.sh # 自检：那一轮能不能自己退出
EOF
