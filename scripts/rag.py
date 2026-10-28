#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""rag.py —— 刷B站历史语料的**本机 RAG**（分块 → bge-m3 嵌入 → SQLite → 余弦检索）

【为什么要有它】
  `out/`（日报）、`reports/`（单条笔记）、`digest/`（归档）、`seen.md`（判重表）
  以前是**只写不读**的档案 —— 那一轮每天从零做同样的判断，问不了
  「我三天前是不是推过类似的东西」「这个主题我以前推过哪些」。
  把它们索引起来，就等于给两条链一个"可检索的过去"。

【为什么不用现成的 dsh-memory-semantic】
  它 README 明写「只读记忆库、绝不写入」，语料只认 meow 的库 ⇒ **不能索引任意文件**。
  但嵌入引擎可以直接复用：本机 Ollama + bge-m3（离线、免费）。

【用法】
  .venv/bin/python rag.py index              # 增量建/更新索引
  .venv/bin/python rag.py search "记忆插件" -k 5
  .venv/bin/python rag.py seen BV18Ubv6tEWN  # 判重：这条见过吗
  .venv/bin/python rag.py stats
"""
import argparse
import hashlib
import json
import math
import os
import re
import sqlite3
import sys
import urllib.request
from datetime import datetime
from pathlib import Path

HOME = Path(__file__).resolve().parent
DB = HOME / 'rag.db'
OLLAMA = os.environ.get('OLLAMA_URL', 'http://127.0.0.1:11434')
MODEL = os.environ.get('RAG_EMBED_MODEL', 'bge-m3')

try:
    import numpy as _np
except Exception:
    _np = None


# ── 嵌入 ────────────────────────────────────────────────────────────────────
def embed(texts, timeout=180):
    """一次拿一批向量（Ollama /api/embed）。返回 [[float,...], ...]"""
    out = []
    B = 16
    for i in range(0, len(texts), B):
        batch = [t[:1200] for t in texts[i:i + B]]
        body = json.dumps({'model': MODEL, 'input': batch}).encode()
        req = urllib.request.Request(OLLAMA + '/api/embed', data=body,
                                     headers={'Content-Type': 'application/json'})
        j = json.load(urllib.request.urlopen(req, timeout=timeout))
        out.extend(j.get('embeddings') or [])
    return out


def pack(vec):
    return json.dumps([round(float(x), 6) for x in vec]).encode()


def unpack(blob):
    return json.loads(blob.decode())


def cosine(a, b):
    if _np is not None:
        return float(_np.dot(a, b) / ((_np.linalg.norm(a) * _np.linalg.norm(b)) or 1))
    s = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    return s / ((na * nb) or 1)


# ── 分块 ────────────────────────────────────────────────────────────────────
def _title_of(block):
    for pat in (r'\*\*标题\*\*：(.+)', r'^- 标题：(.+)', r'^\*\*标题\*\*:(.+)'):
        m = re.search(pat, block, re.M)
        if m:
            return m.group(1).strip()[:120]
    m = re.search(r'^#\s*(.+)', block, re.M)
    return (m.group(1).strip()[:120] if m else '')


def chunks_from_corpus():
    """扫全部语料，产出 [{ckey, kind, date, bvid, title, text}]"""
    out = []

    def add(kind, date, bvid, title, text):
        text = (text or '').strip()
        if len(text) < 10:
            return
        key = hashlib.sha1(f'{kind}|{date}|{bvid}|{text}'.encode()).hexdigest()
        out.append({'ckey': key, 'kind': kind, 'date': date, 'bvid': bvid,
                    'title': title[:120], 'text': text[:4000]})

    # ① out/<日期>.md —— 按 `### BVxxx` 切
    for f in sorted((HOME / 'out').glob('*.md')):
        if f.name.endswith('.bak'):
            continue
        date = f.stem
        txt = f.read_text(encoding='utf-8', errors='replace')
        parts = re.split(r'^###\s+(BV[0-9A-Za-z]{10})', txt, flags=re.M)
        for i in range(1, len(parts), 2):
            bv, body = parts[i], parts[i + 1]
            add('日报', date, bv, _title_of(body), f'{bv}\n{body}')

    # ② reports/<BV>-<日期>.md —— 一份 = 一个 chunk
    for f in sorted((HOME / 'reports').glob('*.md')):
        m = re.match(r'(BV[0-9A-Za-z]{10})-(\d{4}-\d{2}-\d{2})', f.name)
        if not m:
            continue
        txt = f.read_text(encoding='utf-8', errors='replace')
        add('单条笔记', m.group(2), m.group(1), _title_of(txt), txt)

    # ②b QQ 聊天记录（我们自己那座桥写的：一行一条 `- <日期> <说话人> <内容>`）
    for f in sorted((HOME / 'digest').glob('qq-*.md')):
        for line in f.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if not line.startswith('- '):
                continue
            parts = line[2:].split(' ', 2)
            if len(parts) < 3:
                continue
            add('QQ聊天', parts[0], '', parts[1], parts[2][:1500])

    # ③ digest/*.md —— 一行一条（连"跳过"的都在，是全集索引）
    for f in sorted((HOME / 'digest').glob('*.md')):
        for line in f.read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.match(r'(\d{4}-\d{2}-\d{2})\s*·\s*(BV[0-9A-Za-z]{10})\s*·\s*([^·]+)·\s*([^·]*)·\s*(.*)', line)
            if m:
                add('归档', m.group(1), m.group(2), m.group(3).strip(),
                    f'{m.group(3).strip()} / {m.group(4).strip()}\n{m.group(5).strip()}')

    # ④ seen.md —— 判重表（评论记录 + 挑中记录），逐行
    sp = HOME / 'seen.md'
    if sp.exists():
        for line in sp.read_text(encoding='utf-8', errors='replace').splitlines():
            m = re.search(r'(BV[0-9A-Za-z]{10})', line)
            if m and '|' in line:
                add('判重表', '', m.group(1), '', line.strip()[:1500])

    return out


# ── 库 ──────────────────────────────────────────────────────────────────────
def conn():
    c = sqlite3.connect(DB)
    c.execute('''CREATE TABLE IF NOT EXISTS chunks(
        ckey TEXT PRIMARY KEY, kind TEXT, date TEXT, bvid TEXT, title TEXT,
        text TEXT, dim INTEGER, vec BLOB, seen_at TEXT)''')
    c.execute('CREATE INDEX IF NOT EXISTS idx_bv ON chunks(bvid)')
    return c


def cmd_index(args):
    c = conn()
    want = chunks_from_corpus()
    have = {r[0] for r in c.execute('SELECT ckey FROM chunks')}
    new = [x for x in want if x['ckey'] not in have]
    print(f'语料共 {len(want)} 个 chunk；已有 {len(have)}；本次要嵌 {len(new)}')
    if new:
        vecs = embed([x['text'] for x in new])
        now = datetime.now().isoformat(timespec='seconds')
        for x, v in zip(new, vecs):
            c.execute('INSERT OR REPLACE INTO chunks VALUES(?,?,?,?,?,?,?,?,?)',
                      (x['ckey'], x['kind'], x['date'], x['bvid'], x['title'],
                       x['text'], len(v), pack(v), now))
        c.commit()
    # 删掉语料里已经没有的（比如某天报告被清掉）
    gone = have - {x['ckey'] for x in want}
    if gone:
        c.executemany('DELETE FROM chunks WHERE ckey=?', [(k,) for k in gone])
        c.commit()
        print(f'清理已消失的 chunk: {len(gone)}')
    tot = c.execute('SELECT count(*) FROM chunks').fetchone()[0]
    print(f'✅ 索引完成：{tot} 条（新增 {len(new)}）')
    c.close()


def cmd_search(args):
    c = conn()
    rows = list(c.execute('SELECT ckey,kind,date,bvid,title,text,vec FROM chunks'))
    if not rows:
        print('索引是空的，先跑 index'); return
    qv = embed([args.query])[0]
    scored = []
    for ckey, kind, date, bvid, title, text, blob in rows:
        scored.append((cosine(qv, unpack(blob)), kind, date, bvid, title, text))
    scored.sort(key=lambda x: -x[0])
    for s, kind, date, bvid, title, text in scored[:args.k]:
        head = re.sub(r'\s+', ' ', text)[:220]
        print(f'\n[{s:.3f}] {kind} {date} {bvid} {title}')
        print(f'   {head}')
    c.close()


def cmd_seen(args):
    c = conn()
    key = args.bvid.strip()
    m = re.search(r'(BV[0-9A-Za-z]{10})', key)
    key = m.group(1) if m else key
    rows = list(c.execute('SELECT kind,date,title,text FROM chunks WHERE bvid=?', (key,)))
    if not rows:
        print(f'❌ 没见过：{key}（索引里没有）')
    for kind, date, title, text in rows:
        print(f'✅ 见过：{kind} {date} {title}')
        print('   ', re.sub(r'\s+', ' ', text)[:200])
    c.close()


def cmd_stats(args):
    c = conn()
    for kind, n in c.execute('SELECT kind, count(*) FROM chunks GROUP BY kind ORDER BY 2 DESC'):
        print(f'  {kind}: {n}')
    tot = c.execute('SELECT count(*) FROM chunks').fetchone()[0]
    dim = c.execute('SELECT dim FROM chunks LIMIT 1').fetchone()
    print(f'  合计 {tot} 条；维度 {dim[0] if dim else "-"}；库 {DB}')
    c.close()


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    sub.add_parser('index').set_defaults(fn=cmd_index)
    p = sub.add_parser('search'); p.add_argument('query'); p.add_argument('-k', type=int, default=5); p.set_defaults(fn=cmd_search)
    p = sub.add_parser('seen'); p.add_argument('bvid'); p.set_defaults(fn=cmd_seen)
    sub.add_parser('stats').set_defaults(fn=cmd_stats)
    a = ap.parse_args()
    a.fn(a)
