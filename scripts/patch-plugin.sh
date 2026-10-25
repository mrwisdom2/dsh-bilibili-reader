#!/bin/bash
# patch-plugin.sh —— dsh-bili-scroll 的两处本地修补（幂等，插件升级后重跑一次即可）
#
# 【补丁 1】index.js 里硬编码的自称禁令
#   原文：⚠️ 私信里**不要**写"本鱼 / 本鲸 / 主人 / 人家"那套
#   与 Dora 的人设（鲸鱼娘，自称「本鲸鱼娘 / 本小姐」，称主人「主人」）冲突 ⇒ 换成许可版。
#
# 【补丁 2】lib/favops.py 的「自动收藏」边车有两处 bug，导致它**从来没成功过**：
#   a) add() 里用了 favorite_list 却没 import（那个 import 只写在 folders() 的局部作用域里）
#      ⇒ NameError: name 'favorite_list' is not defined
#   b) 用了本版 bilibili-api 里**不存在**的 favorite_list.FavoriteListResource
#      ⇒ "视频收藏夹需要 media_id"；正确入口是 Video.set_favorite(add_media_ids=[fid])
#   ⚠️ favops.py 在**插件家**和**插件包 lib/** 下各有一份，两份都要修
#      （插件每次装载会把包里的那份重铺到家里）。
#
# 【生效时机】
#   index.js 的改动要**插件重载或 dsh 重启**才生效（代码已加载进内存）；
#   favops.py 是每次调用现 spawn 的，**改完立刻生效**。
#
# 用法：bash ~/.dsh/bili-duty/patch-plugin.sh
set -u

python3 - <<'PY'
import sys
from pathlib import Path

ok = True

# ── 补丁 1：index.js 的自称禁令 ─────────────────────────────────────────────
idx = Path.home() / '.dsh/profiles/web/node_modules/dsh-bili-scroll/index.js'
old_ban = '⚠️ 私信里**不要**写"本鱼 / 本鲸 / 主人 / 人家"那套；'
new_ban = '⚠️ 私信里按人设说话：可以自称「本鲸鱼娘 / 本小姐」、可以叫「主人」；但别用「本鱼 / 人家」那套；'
if not idx.exists():
    print('⚠️ 找不到 index.js（插件没装？）'); ok = False
elif new_ban in idx.read_text(encoding='utf-8'):
    print('✓ 补丁1（自称禁令）：已经打过了')
else:
    s = idx.read_text(encoding='utf-8')
    if old_ban in s:
        (idx.parent / 'index.js.bak-ban').write_text(s, encoding='utf-8')
        idx.write_text(s.replace(old_ban, new_ban, 1), encoding='utf-8')
        print('✓ 补丁1（自称禁令）：已替换（备份 index.js.bak-ban）')
    else:
        print('⚠️ 补丁1：没找到目标字符串 —— 插件可能改过措辞，需人工核对'); ok = False

# ── 补丁 2：favops.py 的自动收藏 ────────────────────────────────────────────
NEW_ADD = '''async def add(bvid, fid):
    from bilibili_api import video as ba_video
    cred, _ = load()
    v = ba_video.Video(bvid=bvid, credential=cred)
    try:
        # ⭐ 2026-10-22 修：本版 bilibili-api 没有 favorite_list.FavoriteListResource，
        #    正确入口是 Video.set_favorite(add_media_ids=[fid])。
        #    原写法会抛 NameError / 报"视频收藏夹需要 media_id"，即这段从来没成功过。
        await v.set_favorite(add_media_ids=[int(fid)])
    except Exception as error:  # noqa: BLE001
        msg = str(error)
        # 已经收藏过不算失败
        if '已经' in msg or 'already' in msg.lower():
            out({'ok': True, 'already': True})
        out({'ok': False, 'error': msg[:200]})
    out({'ok': True})


'''

targets = [
    Path.home() / '.dsh/bili-duty/favops.py',
    Path.home() / '.dsh/profiles/web/node_modules/dsh-bili-scroll/lib/favops.py',
]
for p in targets:
    if not p.exists():
        print(f'⚠️ 补丁2：找不到 {p}'); ok = False; continue
    s = p.read_text(encoding='utf-8')
    if 'set_favorite(add_media_ids=' in s:
        print(f'✓ 补丁2（自动收藏）：已经打过了 — {p}')
        continue
    if 'async def add(bvid, fid):' not in s or 'def main():' not in s:
        print(f'⚠️ 补丁2：{p} 结构不认识了，需人工核对'); ok = False; continue
    (p.parent / (p.name + '.bak-fav')).write_text(s, encoding='utf-8')
    a = s.index('async def add(bvid, fid):'); b = s.index('def main():')
    p.write_text(s[:a] + NEW_ADD + s[b:], encoding='utf-8')
    print(f'✓ 补丁2（自动收藏）：已重写 add() — {p}（备份 {p.name}.bak-fav）')


# ── 补丁 3：asr.py 的转写时长上限（默认 30 分钟）────────────────────────────
#   起因：新关键词会带回长视频（37 分钟转出"中英混杂、整段重复"的废稿，64 分钟根本等不起）
#   ⇒ 超过上限直接跳过，stderr 写明原因、返回码 3，让那一轮在报告里写"因时长跳过"。
ASR_E = [
    ("def fetch_audio(url: str, tmp: str, tag: str) -> str:",
     "def fetch_audio(url: str, tmp: str, tag: str):"),
    ("""    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        return ydl.prepare_filename(info)""",
     """    with YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=True)
        # ⭐ 顺手把时长带回去，给「太长就不转写」用
        return ydl.prepare_filename(info), (info or {}).get('duration')"""),
    ("    ap.add_argument('--lang', default='zh', help='语言（默认 zh；不给就自动判断请传 auto）')",
     """    ap.add_argument('--lang', default='zh', help='语言（默认 zh；不给就自动判断请传 auto）')
    # ⭐ 转写时长上限（默认 30 分钟，0=不限）
    ap.add_argument('--max-minutes', type=float,
                    default=float(os.environ.get('BILI_DUTY_ASR_MAX_MINUTES', '30')),
                    help='视频超过这个时长就跳过转写（分钟；默认 30，0=不限）')"""),
    ("""    try:
        if src.lower().startswith('http') or src.upper().startswith('BV'):
            print('[asr] 先下音频…', file=sys.stderr)
            src = fetch_audio(to_url(src), tmp, tag)
        if not os.path.exists(src):""",
     """    try:
        duration = None
        if src.lower().startswith('http') or src.upper().startswith('BV'):
            print('[asr] 先下音频…', file=sys.stderr)
            src, duration = fetch_audio(to_url(src), tmp, tag)
        # ⭐ 时长上限：超过就跳过（返回码 3），并在 stderr 说明原因
        if duration and args.max_minutes and duration > args.max_minutes * 60:
            print('[asr] ⛔ 跳过转写：视频时长 %.1f 分钟 > 上限 %g 分钟'
                  '（--max-minutes 或 BILI_DUTY_ASR_MAX_MINUTES 可调）'
                  % (duration / 60.0, args.max_minutes), file=sys.stderr)
            return 3
        if not os.path.exists(src):"""),
]
for p in [Path.home() / '.dsh/bili-duty/asr.py',
          Path.home() / '.dsh/profiles/web/node_modules/dsh-bili-scroll/lib/asr.py']:
    if not p.exists():
        print(f'⚠️ 补丁3：找不到 {p}'); ok = False; continue
    t = p.read_text(encoding='utf-8')
    if '时长上限' in t:
        print(f'✓ 补丁3（转写时长上限）：已经打过了 — {p}')
        continue
    for o, n in ASR_E:
        if o not in t:
            print(f'⚠️ 补丁3：{p} 结构不认识了，需人工核对'); ok = False; break
        t = t.replace(o, n, 1)
    else:
        (p.parent / (p.name + '.bak-asr')).write_text(p.read_text(encoding='utf-8'), encoding='utf-8')
        p.write_text(t, encoding='utf-8')
        print(f'✓ 补丁3（转写时长上限）：已加入 — {p}')


# ── 补丁 4：meow-memory 的定时器 unref（让一次性 headless 会话能退出）────────
#   起因：它的 dream 调度器 / 心跳 / 服务重试都用普通定时器 ⇒ 事件循环永远有事做
#   ⇒ 刷B站那一轮**永不退出**（实测同一句提示词 2.6s → 5 分钟以上，连 --help 都挂）。
#   unref 只表示"别为我保持事件循环"；宿主有 HTTP 服务撑着，行为不变。
#   ⚠️ 补丁丢了 = 刷B站会静默挂死，所以 08:30 任务里有一道 selfcheck 兜底。
MEOW_HELPERS = """/* ⭐ 2026-10-23（本地补丁）：把本模块创建的定时器统统 unref。
   为什么：dream 调度器 / 心跳 / 服务重试都用普通定时器，会让 Node 事件循环"永远有事做"
   ⇒ 一次性 headless 会话（刷B站那一轮）永不退出。unref 只表示"别为我保持事件循环"，
   宿主进程有 HTTP 服务撑着，行为完全不变。 */
const unrefTimer = (t) => { try { t?.unref?.() } catch { /* 环境不支持就算了 */ } ; return t }
const setTimeoutU = (...a) => unrefTimer(setTimeout(...a))
const setIntervalU = (...a) => unrefTimer(setInterval(...a))
"""
MEOW_SWAPS = [
    ("const timer = setInterval(() => {", "const timer = setIntervalU(() => {"),
    ("if (!stopped) timer = setTimeout(tick, minutes * 6e4);",
     "if (!stopped) timer = setTimeoutU(tick, minutes * 6e4);"),
    ("setTimeout(dumpDescribe, 5e3);", "setTimeoutU(dumpDescribe, 5e3);"),
    ("setTimeout(resolve3, SETTINGS_SOURCE_WAIT_MS);", "setTimeoutU(resolve3, SETTINGS_SOURCE_WAIT_MS);"),
    ("guideTimer = setTimeout(() => tryRegisterGuideSection(attempt + 1), 1e3);",
     "guideTimer = setTimeoutU(() => tryRegisterGuideSection(attempt + 1), 1e3);"),
    ("routeTimer = setTimeout(() => tryRegisterDreamRoutes(attempt + 1), 1e3);",
     "routeTimer = setTimeoutU(() => tryRegisterDreamRoutes(attempt + 1), 1e3);"),
    ("commandTimer = setTimeout(() => tryRegisterDreamCommand(attempt + 1), 1e3);",
     "commandTimer = setTimeoutU(() => tryRegisterDreamCommand(attempt + 1), 1e3);"),
]
for p in sorted(Path.home().glob('.dsh/profiles/*/node_modules/meow-memory/lib/index.js')):
    t = p.read_text(encoding='utf-8')
    if 'setTimeoutU' in t:
        print(f'✓ 补丁4（定时器 unref）：已经打过了 — {p}')
        continue
    anchor = None
    for a in ('const DREAM_HEARTBEAT_MS = ', 'var DREAM_HEARTBEAT_MS = '):
        if a in t:
            anchor = a; break
    if not anchor:
        print(f'⚠️ 补丁4：{p} 里找不到插入锚点 DREAM_HEARTBEAT_MS'); ok = False; continue
    miss = [o for o, _ in MEOW_SWAPS if o not in t]
    if miss:
        print(f'⚠️ 补丁4：{p} 有 {len(miss)} 处没匹配上（插件可能改过代码），需人工核对'); ok = False; continue
    (p.parent.parent / 'index.js.bak-unref').write_text(t, encoding='utf-8')
    for o, n in MEOW_SWAPS:
        t = t.replace(o, n, 1)
    t = t.replace(anchor, MEOW_HELPERS + anchor, 1)
    p.write_text(t, encoding='utf-8')
    print(f'✓ 补丁4（定时器 unref）：已加入 — {p}')


# ── 补丁 5：lib/dm.mjs 让「私信里的图片」带出 URL ──────────────────────────
#   原来非文字消息一律折叠成「[非文字消息]」⇒ 主人发的图根本没进到那一轮。
#   补上后正文会变成 `[图片] <url>`，那一轮就能用 view_image 真看一眼。
DM_OLD = """      } else {
        text = String(c.content || c.text || '')
      }"""
DM_NEW = """      } else if (mt === 2 || c.url || c.imageType !== undefined || Array.isArray(c.pics)) {
        // ⭐ 图片消息：把 URL 带出去（原来会落到「[非文字消息]」）
        const u = String(
          c.url
          || (Array.isArray(c.pics) && c.pics[0] && (c.pics[0].url || c.pics[0].src))
          || c.image_url || '')
        text = u ? '[图片] ' + u : '[图片]（没拿到 URL）'
      } else {
        text = String(c.content || c.text || '')
      }"""
for p in sorted(Path.home().glob('.dsh/profiles/*/node_modules/dsh-bili-scroll/lib/dm.mjs')):
    t = p.read_text(encoding='utf-8')
    if '[图片] ' in t:
        print(f'✓ 补丁5（私信图片）：已经打过了 — {p}')
        continue
    if DM_OLD not in t:
        print(f'⚠️ 补丁5：{p} 结构不认识了，需人工核对'); ok = False; continue
    (p.parent / 'dm.mjs.bak-pic').write_text(t, encoding='utf-8')
    p.write_text(t.replace(DM_OLD, DM_NEW, 1), encoding='utf-8')
    print(f'✓ 补丁5（私信图片）：已加入 — {p}')

print()

# ── 补丁 6：私信「正常回、不自己分条」（切条交给发送层 → 补丁7）────────────
#   历史：先改成"每条100字自己分条"，用户随后定夺为**模型正常回、由 mcp_server 切条**
#   ⇒ 这里把 index.js 的提示词收敛到 v2：只要求正常聊天、长度随意。
DM_P_V1 = """      + `\\n用 bili_send_message 回他（uid=${Number(fromUid)}），像聊天：**别为了短而压缩内容**，想说就说完整；但**每条只写 100 字左右**，说的长就**分成几条连着发**（真人连发消息那种感觉，别把一大段塞一条里）。单条**不要超过 500 字**（B站 硬上限，超了报 code 21007）。`

      + `\\n（分条时：每条自己说完一小件事，不要重复开场白；几条之间像同一口气连着说。）`"""
DM_P_ORIG = """      + `\\n用 bili_send_message 回他一句（uid=${Number(fromUid)}），100 字以内，像聊天。`"""
DM_P_V2 = """      + `\\n用 bili_send_message 回他（uid=${Number(fromUid)}），像聊天就行：**长度随意**，想说的说完，别刻意压缩、也别自己分条（发送那一层会处理）。`"""
for p in sorted(Path.home().glob('.dsh/profiles/*/node_modules/dsh-bili-scroll/index.js')):
    t = p.read_text(encoding='utf-8')
    if '长度随意' in t:
        print(f'✓ 补丁6（私信正常回）：已经打过了 — {p}')
        continue
    for old, tag in ((DM_P_V1, 'v1'), (DM_P_ORIG, '原始')):
        if old in t:
            (p.parent / 'index.js.bak-dmlen').write_text(t, encoding='utf-8')
            p.write_text(t.replace(old, DM_P_V2, 1), encoding='utf-8')
            print(f'✓ 补丁6（私信正常回）：已从 {tag} 收敛到 v2 — {p}')
            break
    else:
        print(f'⚠️ 补丁6：{p} 结构不认识了，需人工核对')


# ── 补丁 7：私信发送层切条（bili_send_message 自动按 ~100 字分条连发）────────
#   用户要求：模型正常回，切条由发送脚本做。⚠️ 这份文件有**两份**：
#   插件家（运行用）与插件包 vendor/bilibili-mcp/（重铺用）—— 两个都要打。
#   OLD/NEW 文本放在 patches/dmsplit_patch.py（由宿主生成，避免把大段代码塞进本脚本）。
import sys as _sys
_sys.path.insert(0, str(Path.home() / '.dsh/bili-duty' / 'patches'))
_ok7 = True
try:
    import dmsplit_patch as _DMS
    for p in sorted(list(Path.home().glob('.dsh/bili-duty/mcp_server.py')) +
                    list(Path.home().glob('.dsh/profiles/*/node_modules/dsh-bili-scroll/vendor/bilibili-mcp/mcp_server.py'))):
        t = p.read_text(encoding='utf-8')
        if '_split_dm_text' in t:
            print(f'✓ 补丁7（私信切条）：已经打过了 — {p}')
            continue
        if _DMS.OLD not in t:
            print(f'⚠️ 补丁7：{p} 结构不认识了，需人工核对')
            continue
        (p.parent / (p.name + '.bak-dmsplit')).write_text(t, encoding='utf-8')
        p.write_text(t.replace(_DMS.OLD, _DMS.NEW, 1), encoding='utf-8')
        print(f'✓ 补丁7（私信切条）：已加入 — {p}')
except Exception as e:
    print(f'⚠️ 补丁7 失败（不影响其他补丁）：{e}')

print()
print()
print('提醒：补丁1（index.js）要等插件重载 / dsh 重启才生效；补丁2 立刻生效。')
sys.exit(0 if ok else 1)
PY
echo
echo '── 附加步骤：headless 基线自检（补丁4 的兜底）──'
bash "$HOME/.dsh/bili-duty/selfcheck-headless.sh" || echo '⚠️ 基线异常：刷B站那一轮会挂死，务必先修（见上面提示）'
