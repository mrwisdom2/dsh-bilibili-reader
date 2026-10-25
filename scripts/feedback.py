#!/usr/bin/env python3
"""feedback.py —— 采集「主人对刷B站产出」的反馈信号，输出一段可直接贴进 AGENTS.md 的 Markdown。

【为什么需要它】
  刷B站那一轮（headless profile）**读不到记忆库、也读不到用户的点赞投币** —— 它的反馈是开环的。
  唯一能让它"看到主人反应"的办法是：有人在 web 侧把这些信号取出来、写进它每轮都会自动加载的
  `~/.dsh/bili-duty/AGENTS.md`。本脚本就是那个"取出来"的部分。

【三个信号源（都实测可用）】
  ① 主号公开收藏夹（fid 见 local.config.json 的 favMediaId，attr=0 公开）里、最近几天被收藏的**推荐视频** ← 最强的正向信号
  ② 小号收到的赞 / @（`bili_received_at_and_likes`）—— 主人给小号的评论点赞会出现在这里
  ③ 小号收到的回复（`bili_received_replies`）

⚠️ 读不到的是「主人给视频本身的赞和币」：B站 的 archive/relation 只反映**登录账号**（小号）的关系，
   主号的赞币不可见 —— 这是账号结构决定的，不是脚本的问题。

用法：
  .venv/bin/python feedback.py            # 默认看最近 3 天
  .venv/bin/python feedback.py --days 7
输出：stdout 一段 Markdown（宿主把它写进 AGENTS.md 的「反馈台账」区）。
"""
import os
import argparse
import asyncio
import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

HOME = Path(__file__).resolve().parent
sys.path.insert(0, str(HOME))

def _local_cfg():
    # 本地配置：$BILI_DUTY_HOME/local.config.json（不进仓库）
    import json, os, pathlib
    p = pathlib.Path(os.environ.get('BILI_DUTY_HOME') or (pathlib.Path.home() / '.dsh' / 'bili-duty')) / 'local.config.json'
    try:
        return json.loads(p.read_text(encoding='utf-8'))
    except Exception:
        return {}

_CFG = _local_cfg()
# 主号：收私信、被 @、收藏夹的主人（来源：环境变量 → local.config.json → 0 表示未配置）
MAIN_UID = int(os.environ.get('BILI_MAIN_UID') or _CFG.get('mainUid') or 0)
# 主号「默认收藏夹」（公开）（来源同上）
FAV_MEDIA_ID = int(os.environ.get('BILI_FAV_MEDIA_ID') or _CFG.get('favMediaId') or 0)
FAV_PAGES = 2                 # 按收藏时间倒序，前 2 页（40 条）足够覆盖最近几天


def recent_picks(days):
    """从 out/<日期>.md 里取出最近 N 天推荐的 BV → {bv: (日期, 标题)}。"""
    picks = {}
    today = datetime.now().date()
    for i in range(days):
        d = today - timedelta(days=i)
        f = HOME / 'out' / f'{d.isoformat()}.md'
        if not f.exists():
            continue
        text = f.read_text(encoding='utf-8', errors='replace')
        cur = None
        for line in text.splitlines():
            m = re.match(r'^###\s+(BV[0-9A-Za-z]+)', line)
            if m:
                cur = m.group(1)
                picks.setdefault(cur, [d.isoformat(), ''])
                continue
            if cur and line.startswith('**标题**'):
                picks[cur][1] = line.split('：', 1)[-1].strip()[:60]
                cur = None
    return picks


async def gather(days):
    import mcp_server

    out = {'faved': [], 'likes': [], 'replies': [], 'errors': []}
    picks = recent_picks(days)
    out['picks_total'] = len(picks)

    # ① 主号收藏夹里出现的推荐视频（按收藏时间倒序）
    try:
        faved = {}
        for pg in range(1, FAV_PAGES + 1):
            raw = await mcp_server.bili_favorite_content(FAV_MEDIA_ID, page=pg)
            j = json.loads(raw) if isinstance(raw, str) else raw
            for m in (j.get('medias') or []):
                bv = m.get('bvid')
                if bv in picks:
                    faved[bv] = {'title': (m.get('title') or '')[:50], 'fav_time': m.get('fav_time')}
        out['faved'] = [{'bv': k, **v, 'picked_on': picks[k][0]} for k, v in faved.items()]
    except Exception as e:
        out['errors'].append(f'收藏夹: {e}')

    # ② 小号收到的赞/@
    try:
        raw = await mcp_server.bili_received_at_and_likes()
        j = json.loads(raw) if isinstance(raw, str) else raw
        likes = ((j.get('likes') or {}).get('latest') or {}).get('items') or []
        ats = ((j.get('at') or {}).get('items')) or []
        for it in likes:
            inner = it.get('item') if isinstance(it.get('item'), dict) else {}
            u = it.get('user') or {}
            out['likes'].append({
                'user': u.get('nickname') or u.get('uname') or it.get('nickname') or '有人',
                'item_id': inner.get('item_id') or it.get('item_id'),
                'type': inner.get('type') or it.get('type') or '评论',
                'text': str(it.get('title') or it.get('content') or '')[:60],
            })
        for it in ats:
            out['likes'].append({'user': (it.get('user') or {}).get('nickname'),
                                 'text': '@ ' + str(it.get('title') or it.get('content') or '')[:60],
                                 'time': it.get('at_time') or it.get('time')})
    except Exception as e:
        out['errors'].append(f'收到的赞/@: {e}')

    # ③ 小号收到的回复
    try:
        raw = await mcp_server.bili_received_replies()
        j = json.loads(raw) if isinstance(raw, str) else raw
        items = (j.get('replies') or j.get('items') or [])
        for it in items:
            inner = it.get('item') if isinstance(it.get('item'), dict) else {}
            # ⭐ 2026-10-24：回复正文其实在 item.title 里（原来只找 content/message ⇒ 渲染成空）
            txt = (inner.get('title') or it.get('title') or it.get('content') or it.get('message') or '')
            uri = str(inner.get('uri') or it.get('uri') or '')
            bv = (uri.split('/video/')[-1].split('?')[0] if '/video/' in uri else '')
            usr = it.get('user') if isinstance(it.get('user'), dict) else {}
            mid = int((usr.get('mid') or it.get('mid') or 0) or 0)
            out['replies'].append({
                'user': usr.get('nickname') or it.get('uname') or '有人',
                'mid': mid,
                'is_main': mid == MAIN_UID,   # ⭐ 按 mid 区分主人本人（原来不分，把观众也算进"主人回过话" ✗）
                'text': str(txt)[:80],
                'bv': bv,
            })
    except Exception as e:
        out['errors'].append(f'收到的回复: {e}')

    return out


def render(data, days):
    L = []
    L.append(f'## 反馈台账（{datetime.now().strftime("%Y-%m-%d %H:%M")} 更新 · 近 {days} 天）')
    L.append('')
    L.append(f'- 近 {days} 天共推荐 **{data.get("picks_total", 0)}** 条；其中被主人收藏 **{len(data["faved"])}** 条')
    if data['faved']:
        for f in data['faved']:
            L.append(f'  - ✅ `{f["bv"]}`（{f.get("picked_on")} 推荐）{f["title"]}')
        L.append('- ⇒ **主人愿意收藏这一类**：下一轮往这个方向加权')
    else:
        L.append('- （暂无「推荐→被收藏」记录：不代表不喜欢，也可能他还没看）')
    if data['likes']:
        L.append(f'- 收到的赞/@：**{len(data["likes"])} 条**（⚠️ B站 这个列表**读一次就清空**，这里就是唯一留档）')
        for x in data['likes'][:8]:
            rid = f'（rpid={x["item_id"]}）' if x.get('item_id') else ''
            L.append(f'  - 👍 {x.get("user")} 赞了你的{x.get("type")}{rid}')
    if data['replies']:
        mains = [x for x in data['replies'] if x.get('is_main')]
        others = [x for x in data['replies'] if not x.get('is_main')]
        head = f"- ⭐ **主人回过话：{len(mains)} 条**"
        if others:
            head += f"（另有 **{len(others)}** 条是别的观众在回你的评论）"
        L.append(head)
        for x in mains[:3]:
            bv = f"（`{x['bv']}`）" if x.get('bv') else ''
            L.append(f"  - 💬 主人{bv}：{x.get('text')}")
        for x in others[:3]:
            bv = f"（`{x['bv']}`）" if x.get('bv') else ''
            L.append(f"  - 💬 {x.get('user')}{bv}：{x.get('text')}")
    if not data['likes'] and not data['replies']:
        L.append('- （主人还没对评论点过赞、也没回复过 —— **别因此改变做法**，这只是"还没有信号"）')
    if data['errors']:
        L.append('- ⚠️ 采集异常：' + '；'.join(str(e)[:80] for e in data['errors']))
    L.append('')
    L.append('> 读不到的部分：主人给**视频本身**的赞/币（B站 只暴露登录账号自己的关系）。')
    L.append('> 最强的反馈其实是**他私信里说的话** —— 那部分由宿主从对话里提炼，写进「主人偏好」区。')
    return '\n'.join(L)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--days', type=int, default=3)
    ap.add_argument('--json', action='store_true')
    a = ap.parse_args()
    d = asyncio.run(gather(a.days))
    print(json.dumps(d, ensure_ascii=False, indent=2) if a.json else render(d, a.days))
