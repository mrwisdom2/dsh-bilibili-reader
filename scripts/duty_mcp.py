#!/usr/bin/env python3
"""duty_mcp.py —— 给「刷B站」两条链（正经轮 + 私信回复轮）用的**宿主侧小工具**：视觉 + 历史检索。

【为什么单独一个 MCP，而不是改进插件自带的那个】
  插件那个 MCP 的工具白名单是**硬编码**在 index.js 里的，overlay 又每轮被重写 ⇒
  往里加工具是白费功夫。而 `dshBin` 包装器（dm-session.mjs）能给我们自己的
  `--patch` 叠一层 ⇒ 在这个独立 MCP 里加工具**零改插件**。

【怎么把图片递给模型】
  DSH 的 MCP 客户端支持图片内容块（`type: "image"`），所以工具直接
  返回 `Image(...)` 就行 —— 模型会"看见"它，不需要另装视觉模型
  （本机模型 DeepSeek-V4.1-Flash 实测支持视觉：给它一张纯红 PNG，它答"红色"）。

【工具清单】
  · make_test_image  —— 返回一张纯色测试图（自检用，验证链路通不通）
  · view_image       —— 看一张本地图片或 http(s) 图片（用户私信里发的图走这条）
  · bili_frames      —— 拉一个 B站 视频，抽 N 帧出来给模型看（需要 yt-dlp + ffmpeg）
"""
import base64
import io
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import time
import urllib.request
import zlib
from pathlib import Path

from mcp.server.fastmcp import FastMCP, Image

HOME = Path(__file__).resolve().parent
ASR_VENV = HOME / '.venv-asr'          # yt-dlp 在这里
YTDLP = ASR_VENV / 'bin' / 'yt-dlp'
TMP = HOME / 'tmp' / 'vision'
TMP.mkdir(parents=True, exist_ok=True)
tempfile.tempdir = str(TMP)

mcp = FastMCP('vision')


def _png(w: int, h: int, rgb) -> bytes:
    raw = b''.join(b'\x00' + bytes(rgb) * w for _ in range(h))

    def ch(t, d):
        c = struct.pack('>I', len(d)) + t + d
        return c + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

    return (b'\x89PNG\r\n\x1a\n'
            + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
            + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))


def _ffmpeg() -> str:
    """拿一个可用的 ffmpeg：优先 imageio-ffmpeg 自带的，其次 PATH 里的。"""
    try:
        import imageio_ffmpeg
        return imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return 'ffmpeg'


@mcp.tool()
def make_test_image() -> Image:
    """返回一张 64x64 的纯红色测试图。用来验证「工具返回的图能不能被模型看见」。"""
    return Image(data=_png(64, 64, (220, 30, 30)), format='png')


@mcp.tool()
def view_image(target: str, max_side: int = 1024) -> Image:
    """看一张图片（本地路径、file:// 或 http(s):// 都行）。

    Args:
        target: 图片路径或 URL
        max_side: 最长边缩到这个像素以内（默认 1024；越小越省 token）
    """
    t = (target or '').strip()
    if not t:
        raise ValueError('target 不能为空')
    if t.startswith('http://') or t.startswith('https://'):
        req = urllib.request.Request(t, headers={
            'User-Agent': 'Mozilla/5.0', 'Referer': 'https://www.bilibili.com/'})
        data = urllib.request.urlopen(req, timeout=30).read()
    else:
        p = Path(t.replace('file://', ''))
        if not p.is_absolute():
            p = HOME / p
        app = p.read_bytes()
        data = app
    # 需要缩就交给 ffmpeg 缩（省 token；ffmpeg 不可用就原样返回）
    if max_side and len(data) > 50_000:
        try:
            out = TMP / ('view_' + str(abs(hash(t)) % 10 ** 12) + '.png')
            subprocess.run([_ffmpeg(), '-y', '-i', 'pipe:0',
                            '-vf', f'scale={max_side}:{max_side}:force_original_aspect_ratio=decrease',
                            str(out)], input=data, capture_output=True, timeout=30)
            if out.exists():
                data = out.read_bytes()
                try:
                    out.unlink()
                except Exception:
                    pass
        except Exception:
            pass
    return Image(data=data, format='png' if data[:4] == b'\x89PNG' else 'jpeg')


# ⭐⭐ 2026-10-25：看画面改成"两条腿"，因为原来那条（下载视频再抽帧）在这台机器上会超时 ✗
#   ① 封面 —— 走 view API + 图片 CDN（i0/i2.hdslb.com，实测可达 ✓），一次几百 KB、秒级
#   ② 故事板拼图 —— 走 x/player/videoshot（每格 480×270、10×10 一格一张），只下小图 ✓
#   两条都只碰 API + 图片 CDN，不碰视频流 ⇒ 正是上游 2.1.0 走的那条路 ✓
CRED_FILE = HOME / 'bili_credential.json'


def _bili_headers() -> dict:
    h = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)',
         'Referer': 'https://www.bilibili.com'}
    try:
        c = json.loads(CRED_FILE.read_text(encoding='utf-8'))
        # 下面这些都是 **Cookie 的字段名**（值从 bili_credential.json 读，文件里没有真值）
        pairs = (('SESSDATA', c.get('sessdata')), ('bili_jct', c.get('bili_jct')),   # publish-check: ok 仅字段名
                 ('buvid3', c.get('buvid3')), ('DedeUserID', c.get('dedeuserid')))  # publish-check: ok 仅字段名
        cookie = '; '.join(f'{k}={v}' for k, v in pairs if v)
        if cookie:
            h['Cookie'] = cookie
    except Exception:
        pass
    return h


def _bili_json(url: str, timeout: int = 20) -> dict:
    req = urllib.request.Request(url, headers=_bili_headers())
    return json.load(urllib.request.urlopen(req, timeout=timeout))


def _fetch_img(url: str, timeout: int = 30) -> bytes:
    if url.startswith('//'):
        url = 'https:' + url
    req = urllib.request.Request(url, headers=_bili_headers())
    return urllib.request.urlopen(req, timeout=timeout).read()


def _bv_of(bvid: str) -> str:
    m = re.search(r'(BV[0-9A-Za-z]{10})', bvid or '')
    if not m:
        raise ValueError('没找到 BV 号')
    return m.group(1)


def _video_meta(bv: str) -> dict:
    """基本信息：aid / cid / 封面 / 时长 / 标题"""
    j = _bili_json('https://api.bilibili.com/x/web-interface/view?bvid=' + bv)
    if j.get('code') != 0:
        raise RuntimeError(f"取视频信息失败：code={j.get('code')} {j.get('message')}")
    d = j.get('data') or {}
    cid = (d.get('pages') or [{}])[0].get('cid') or d.get('cid')
    return {'aid': d.get('aid'), 'cid': cid, 'cover': d.get('pic'),
            'duration': int(d.get('duration') or 0), 'title': d.get('title') or ''}


def _ff_font() -> str:
    for c in ('/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
              '/System/Library/Fonts/PingFang.ttc',
              '/System/Library/Fonts/Supplemental/Songti.ttc'):
        if Path(c).exists():
            return c
    return ''


def _draw_label(data: bytes, text: str) -> bytes:
    """左上角打个标（封面用）。失败就原样返回 —— 标不出来也比没有强。"""
    font = _ff_font()
    if not font or not data:
        return data
    try:
        r = subprocess.run(
            [_ffmpeg(), '-y', '-i', 'pipe:0', '-vf',
             "scale='min(640,iw)':-2,"                     # 先缩（封面原图可能很大 ⇒ 费 token）
             f"drawtext=fontfile='{font}':text='{text}':x=8:y=8:fontsize=26:"
             "fontcolor=white:box=1:boxcolor=black@0.65:boxborderw=6",
             '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-q:v', '4', 'pipe:1'],
            input=data, capture_output=True, timeout=40)
        return r.stdout if r.returncode == 0 and r.stdout else data
    except Exception:
        return data


def _fmt(data: bytes) -> str:
    """按魔数认图片类型 —— 声明错了会被客户端拒收（'Declared image type does not match its bytes' ✗）"""
    if data[:2] == b'\xff\xd8':
        return 'jpeg'
    if data[:8] == b'\x89PNG\r\n\x1a\n':
        return 'png'
    return 'jpeg'


def _crop_cell(blob: bytes, w: int, h: int, x: int, y: int) -> bytes:
    """从拼图里裁一格出来（交 ffmpeg 做）"""
    try:
        r = subprocess.run(
            [_ffmpeg(), '-y', '-i', 'pipe:0', '-vf', f'crop={w}:{h}:{x}:{y}',
             '-frames:v', '1', '-f', 'image2pipe', '-vcodec', 'mjpeg', '-q:v', '4', 'pipe:1'],
            input=blob, capture_output=True, timeout=60)
        return r.stdout if r.returncode == 0 and r.stdout else b''
    except Exception:
        return b''


@mcp.tool()
def bili_cover(bvid: str) -> Image:
    """取一个 B站 视频的**封面图**（不下载视频：只问一次 API + 取一张小图，秒级）。

    封面常常已经把主题写在上面了 —— 拿不准要不要细看画面时，先看它。

    Args:
        bvid: BV 号（或完整链接）
    """
    meta = _video_meta(_bv_of(bvid))
    if not meta.get('cover'):
        raise RuntimeError('这个视频没给封面')
    return Image(data=_fetch_img(meta['cover']), format='jpeg')


@mcp.tool()
def bili_frames(bvid: str, n: int = 4, start: float = 0.0, with_cover: bool = True,
                prefer: str = 'real', download_minutes: float = 30.0) -> list:
    """看一眼这个视频的画面。

    ⭐ **路线（2026-10-25 定稿）**：**默认取"真帧"** —— 下最低档视频再抽帧，
    画面 **640×424**（比预览图清楚一倍多），实测约 **4 秒**；
    **故事板预览图降级为兜底** —— 真帧拿不到（网络/风控）时才用，**480×270、0.8 秒**。

    ⭐ **返回顺序固定**：`with_cover=True`（默认）时，**第 1 张是封面（左上角打着「封面」两字）**，
    之后才是画面；看的时候别把封面当正片。

    ⚠️ 每张图都算 token：**n 开 2~4 就够**；先读字幕/简介/评论，真需要看画面才用它。
    只想"快看一眼"、不想等下载 ⇒ 传 `prefer='preview'`（走故事板小图，0.8 秒）。

    Args:
        bvid: BV 号（或完整链接）
        n: 抽几帧（默认 4，上限 8）
        start: 从第几秒开始抽（默认 0）
        with_cover: 是否把封面当第 1 张一起给（默认 True）
        prefer: `'real'`（默认，真帧，清楚但慢 4 秒）／`'preview'`（预览小图，快）
        download_minutes: 下载的总预算（分钟，默认 30）
    """
    bv = _bv_of(bvid)
    n = max(1, min(int(n or 4), 8))
    meta = None
    out = []

    # ① 封面（带上「封面」标注）
    if with_cover:
        try:
            meta = _video_meta(bv)
            if meta.get('cover'):
                out.append(Image(data=_draw_label(_fetch_img(meta['cover']), '封面'), format='jpeg'))
        except Exception:
            pass

    # ② 故事板：均匀取 n 格
    try:
        meta = meta or _video_meta(bv)
        # ⭐ 2026-10-25：`index`（时间表）**偶发返回空**（上游文档实测约 25% ✗）⇒ 重试两次
        d = {}
        for _try in range(3):
            sb = _bili_json('https://api.bilibili.com/x/player/videoshot'
                            f"?aid={meta['aid']}&bvid={bv}&cid={meta['cid']}&index=1")
            d = sb.get('data') or {}
            if d.get('index'):
                break
        sheets = d.get('image') or []
        XL = int(d.get('img_x_len') or 0); YL = int(d.get('img_y_len') or 0)
        XS = int(d.get('img_x_size') or 480); YS = int(d.get('img_y_size') or 270)
        slots = XL * YL
        # ⭐⭐ 2026-10-25 实测（BV1ZpHK6TEwZ）：
        #   拼图里**只有前 len(index)-1 格有画面**，其余是黑格 ✗（10×10=100 格，实际只用 34 格）；
        #   index 的第 1 项是占位（与第 2 项重复）⇒ **格子 i ↔ index[i+1]**（都是 5 秒一档，正好铺满片长）。
        times = [int(t) for t in (d.get('index') or [])]
        if len(times) > 1 and times[0] == times[1]:
            times = times[1:]
        if times and (times[-1] <= 0):
            times = []
        valid = len(times) or (slots * len(sheets))
        valid = min(valid, slots * len(sheets))
        if valid and XS and YS:
            dur = meta.get('duration') or (times[-1] if times else 0) or 0
            # 按**时间**取 n 帧（比按格子均分准：格子与时间的对应关系由 index 给出）
            targets = [start + (max(float(dur) - start, 1.0)) * (i + 0.5) / n for i in range(n)]
            cells = []
            for t in targets:
                if times:
                    cells.append(min(range(valid), key=lambda k: abs(times[k] - t)))
                else:
                    cells.append(min(valid - 1, int(t / max(float(dur), 1.0) * valid)))
            cache = {}
            for cell in cells:
                si, rem = divmod(cell, XL * YL)
                if si >= len(sheets):
                    continue
                row, col = divmod(rem, XL)
                if si not in cache:
                    try:
                        cache[si] = _fetch_img(sheets[si])
                    except Exception:
                        cache[si] = b''
                if not cache[si]:
                    continue
                png = _crop_cell(cache[si], XS, YS, col * XS, row * YS)
                # ⭐ 黑格/空格的 JPEG 只有 ~1KB ⇒ 直接跳过，别把黑图喂给模型（费 token 还没信息 ✗）
                if png and len(png) > 3000:
                    out.append(Image(data=png, format=_fmt(png)))
    except Exception:
        pass

    # ③ 兜底：老路子（下载视频再抽帧）—— **默认关掉** ✗
    #    2026-10-25 实测：这台机器上视频流/故事板 CDN 都会被 SSL EOF 掐断 ⇒ 走它只会白等
    #    （每次格式 120 秒 × 3 ⇒ MCP 端直接超时 ✗）。真要用得显式 allow_download=True。
    # ⭐⭐ 2026-10-25 路线定稿：**默认用真帧**（下视频再抽 ⇒ 640×424 更清楚），
    #    故事板预览降级为**兜底**（0.8 秒、480×270，小但快）。
    #    prefer='real'（默认）⇒ 真帧优先；真帧没拿到就保留上面已取到的预览帧 ✓（天然兜底）
    #    prefer='preview'      ⇒ 预览优先（要快）；预览不足 n 张才去下载 ✓
    real_first = str(prefer or 'real').lower() != 'preview'
    if real_first or len(out) <= (1 if with_cover else 0):
        dl = None
        work = TMP / bv
        work.mkdir(parents=True, exist_ok=True)
        # 总预算（默认 30 分钟，`download_minutes` 可调）—— 别把"失败"变成"超时" ✗
        deadline = time.time() + max(1.0, float(download_minutes)) * 60.0
        if YTDLP.exists():
            for fmt in ('worstvideo[ext=mp4]/worstvideo/worst',
                        'worst[ext=mp4]/worst',
                        'bestvideo[height<=360]+bestaudio/best[height<=360]'):
                left = deadline - time.time()
                if left <= 5:
                    break
                try:
                    subprocess.run([str(YTDLP), '-f', fmt, '--no-progress', '--no-warnings', '-o',
                                    str(work / 'v.%(ext)s'), '--paths', f'home:{work}',
                                    '--paths', f'temp:{work}', '--referer', 'https://www.bilibili.com',
                                    'https://www.bilibili.com/video/' + bv],
                                   capture_output=True, timeout=left)
                    cand = sorted(work.glob('v.*'))
                    if cand:
                        dl = cand[0]
                        break
                except Exception:
                    continue
        if dl is not None:
            dur = float(meta.get('duration') or 0) if meta else 0.0
            if dur <= 0:
                try:
                    pp = subprocess.run([_ffmpeg(), '-i', str(dl)], capture_output=True, timeout=30)
                    mm = re.search(rb'Duration: (\d+):(\d+):(\d+\.\d+)', pp.stderr)
                    if mm:
                        dur = int(mm.group(1)) * 3600 + int(mm.group(2)) * 60 + float(mm.group(3))
                except Exception:
                    pass
            if dur <= 0:
                dur = 60.0
            span = max(dur - start, 1.0)
            real = []
            for i in range(n):
                t = start + span * (i + 0.5) / n
                f = work / f'f{i}.png'
                try:
                    subprocess.run([_ffmpeg(), '-y', '-ss', f'{t:.2f}', '-i', str(dl),
                                    '-frames:v', '1', '-vf', 'scale=640:-2', str(f)],
                                   capture_output=True, timeout=60)
                except Exception:
                    continue
                if f.exists() and f.stat().st_size > 0:
                    real.append(Image(data=f.read_bytes(), format=_fmt(f.read_bytes())))
            # ⭐ 真帧到手 ⇒ 用它换掉预览帧（封面保留）；一张都没抽到就保留预览帧 ✓
            if real:
                out = (out[:1] if (with_cover and out) else []) + real

    if not out:
        raise RuntimeError(
            '没拿到画面：B站 的故事板图片 CDN（bimp.hdslb.com）在这台机器上被 SSL 掐断 ✗'
            '（接口能通、图片下不来）。**去看封面**用 bili_cover(bvid) ✓；'
            '然后靠字幕、简介、评论判断，**别反复重试** ✗')
    return out


def _rag(*args: str) -> str:
    r = subprocess.run([sys.executable, str(HOME / 'rag.py'), *args],
                       capture_output=True, text=True, timeout=120)
    return (r.stdout or r.stderr or '').strip() or '(没有输出)'


@mcp.tool()
def search_finds(query: str, k: int = 5) -> str:
    """在「刷B站历史语料」里做语义检索（日报/单条笔记/归档/判重表）。

    用来回答：「这个主题我以前推过哪些？」「我是不是推过类似的东西？」
    「主人上次对哪一类点过赞？」——比凭印象可靠。

    Args:
        query: 想找的主题/关键词（自然语言也行）
        k: 返回几条（默认 5）
    """
    return _rag('search', query, '-k', str(max(1, min(int(k or 5), 12))))


@mcp.tool()
def have_seen(bvid: str) -> str:
    """查一条视频**以前有没有见过/推过**（按 BV 号精确查，比 seen.md 好读）。

    Args:
        bvid: BV 号
    """
    return _rag('seen', bvid)


if __name__ == '__main__':
    mcp.run(transport='stdio')
