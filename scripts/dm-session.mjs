#!/usr/bin/env node
/**
 * dm-session.mjs —— 给「刷B站」的私信回复轮套一条**常驻会话**
 *
 * 【为什么需要它】
 *   插件每收到主人一条 B站 私信，就 spawn 一次：
 *     dsh --profile headless --patch <overlay> <私信提示词>
 *   这是**一次性会话** ⇒ 它永远记不住上一句，每条私信都像第一次认识你。
 *   而 dsh headless 其实支持 `--session-id <id>`（adopt the persisted Session），
 *   只是插件那一行是写死的、也没有「附加参数」配置项 —— 唯一能插手的钩子是 `dshBin`。
 *
 * 【做法】
 *   dshBin 指向本文件（resolveDsh 用 `process.execPath` + `[dshBin]` 跑它 ⇒ 必须是 JS）。
 *   本文件**只在「私信回复」那一轮**把 `--session-id <DM_SESSION_ID>` 插到任务文本**之前**
 *   （headless 的 task 是变长位置参数，flag 放到后面会被当成任务正文）；
 *   刷B站的正经轮次（duty / 手动跑一轮 / 复核）**原样透传** ⇒ 依旧每次新会话，不被历史污染。
 *
 * 【三种降级（都为了同一件事：别让主人的私信没人回）】
 *   ① 会话不存在 ⇒ 不带 --session-id（headless 对未知 id 直接报错）
 *   ② 会话被别的进程占着（2026-10-23 实证：**GUI 里打开着那条会话**时，web 主进程
 *      持进程内写句柄 ⇒ `session "…" is already owned by an active write handle`，
 *      1.4 秒就 code=1）⇒ **自动去掉 --session-id 重跑一次**，回复照发，只是这一条
 *      缺逐字历史（人设与共享记忆都还在）。
 *   ③ 上面两种都会在 stderr 留一行说明（会进 duty.log）
 *
 * 【真实 dsh 路径怎么找】
 *   不写死：env DM_SESSION_DSH → duty.log 里插件自己报过的「自动找到 dsh：…」→
 *   npx 缓存里最新的那份 → 全局安装位置。这样 dsh 升级换了目录也不会瞎。
 */
import { spawn } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'

/** 本地配置读取（不入库；放在 $BILI_DUTY_HOME/local.config.json） */
function localConfig() {
  try {
    const home = process.env.BILI_DUTY_HOME || path.join(os.homedir(), '.dsh', 'bili-duty')
    return JSON.parse(fs.readFileSync(path.join(home, 'local.config.json'), 'utf8'))
  } catch { return {} }
}

/** ⭐ 专属私信会话 id：环境变量 BILI_DM_SESSION_ID → local.config.json → 空（空 = 不 adopt，每轮新会话） */
const DM_SESSION_ID = String(
  process.env.BILI_DM_SESSION_ID || localConfig().dmSessionId || ''
).trim()

/** 认「私信回复轮」的指纹 —— 与插件 dmPromptFor() 的开头一致 */
const DM_MARKER = 'B站 私信里主人发来的一句话'

/** 写句柄冲突的报错指纹（dsh 原文） */
const LOCKED_RE = /already owned by an active write handle/i

function realDshCandidates() {
  const out = []
  if (process.env.DM_SESSION_DSH) out.push(process.env.DM_SESSION_DSH)

  // ① duty.log 里插件最近一次自动探测到的那个（最贴近它自己的选择）
  try {
    const home = process.env.BILI_DUTY_HOME
    if (home) {
      const txt = fs.readFileSync(path.join(home, 'duty.log'), 'utf8').slice(-40000)
      const hits = [...txt.matchAll(/自动找到 dsh：(.+?)（/g)]
      if (hits.length) out.push(hits[hits.length - 1][1].trim())
    }
  } catch { /* 读不到就算了 */ }

  // ② npx 缓存里的所有 dsh（取最新的那份；dsh 升级会换目录，所以不写死）
  try {
    const base = path.join(os.homedir(), '.npm', '_npx')
    const found = fs.readdirSync(base)
      .map((d) => path.join(base, d, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'))
      .filter((p) => { try { return fs.statSync(p).isFile() } catch { return false } })
      .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs)
    out.push(...found)
  } catch { /* 没有 npx 缓存 */ }

  // ③ 全局安装位置
  out.push('/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  out.push('/usr/lib/node_modules/@deepseek-ai/dsh/lib/bin.js')
  return out
}

function resolveRealDsh() {
  for (const c of realDshCandidates()) {
    try { if (c && fs.statSync(c).isFile()) return c } catch { /* 下一个 */ }
  }
  return null
}

/** 会话是否还在（不存在就别带 --session-id，否则 headless 直接报错） */
function sessionExists(id) {
  const root = path.join(os.homedir(), '.dsh', 'sessions')
  try {
    for (const ws of fs.readdirSync(root)) {
      if (fs.existsSync(path.join(root, ws, id))) return true
    }
  } catch { /* 读不到就当不存在 */ }
  return false
}

const argv = process.argv.slice(2)
const last = argv.length ? argv[argv.length - 1] : ''
const isDm = last.includes(DM_MARKER)

/** ⭐ 我们自己的「视觉 + 历史检索」MCP（零改插件） */
const VISION_OVERLAY = path.join(os.homedir(), '.dsh', 'bili-duty', 'vision-overlay.yml')

/**
 * 组装最终参数。
 * ⚠️ 顺序很关键：`--patch` 是**启动器**参数、`--session-id` 是 **headless 应用**参数，
 *    启动器一遇到应用参数就停止解析 ⇒ `--patch` 必须排在 `--session-id` 之前，
 *    否则会报 `error: unknown option '--patch'`（实测踩过，只走私信链才暴露）。
 */
function buildArgs({ withSession }) {
  let a = argv
  if (a.length > 0 && fs.existsSync(VISION_OVERLAY)) {
    a = [...a.slice(0, -1), '--patch', VISION_OVERLAY, a[a.length - 1]]
  }
  if (isDm && withSession) {
    // ⚠️ 必须插在任务文本之前：headless 的 task 是变长位置参数
    a = [...a.slice(0, -1), '--session-id', DM_SESSION_ID, a[a.length - 1]]
  }
  return a
}

const real = resolveRealDsh()
if (!real) {
  process.stderr.write('[dm-session] ⚠️ 找不到真正的 dsh bin.js ⇒ 本轮跑不起来。可设 DM_SESSION_DSH 环境变量指定\n')
  process.exit(1)
}

// ⭐ 2026-10-23：**跑轮期间不许空闲睡眠**。
//    实证：白天两次刷B站轮次都跑到一半被 macOS 的 Idle Sleep 冻住
//    （pmset 日志：'Entering Sleep state due to Idle Sleep'，一次 955 秒），
//    醒来时 LLM 长连接已经断了 ⇒ `dsh: TRANSPORT: Connection error.` ⇒ code=1、
//    窗口名额白烧。caffeinate -i 只挡"空闲睡眠"，**屏幕照样可以关**，
//    且它跟着子进程一起退出 —— 轮次一结束就恢复正常的睡眠行为。
const CAFFEINATE = '/usr/bin/caffeinate'
const useCaffeinate = fs.existsSync(CAFFEINATE)

/** 跑一轮：输出原样转发，同时把 stderr 收下来用于判错 */
function run(args) {
  return new Promise((resolve) => {
    const cmd = useCaffeinate ? CAFFEINATE : process.execPath
    const cmdArgs = useCaffeinate ? ['-i', process.execPath, real, ...args] : [real, ...args]
    const child = spawn(cmd, cmdArgs, { stdio: ['ignore', 'pipe', 'pipe'] })
    let err = ''
    child.stdout?.on('data', (d) => process.stdout.write(d))
    child.stderr?.on('data', (d) => { err += d.toString(); process.stderr.write(d) })
    child.on('error', (e) => resolve({ code: 1, signal: null, err: err + String(e?.message ?? e) }))
    child.on('exit', (code, signal) => {
      if (signal) { try { process.kill(process.pid, signal) } catch { /* ignore */ } }
      resolve({ code: code ?? 0, signal, err })
    })
  })
}

if (useCaffeinate) process.stderr.write('[dm-session] 已套 caffeinate -i（跑这一轮期间不空闲睡眠）\n')

const wantSession = isDm && sessionExists(DM_SESSION_ID)
if (isDm && !wantSession) {
  process.stderr.write(`[dm-session] ⚠️ 私信会话 ${DM_SESSION_ID} 不存在 ⇒ 本轮降级为新会话（连续性丢失）。重建后请更新 dm-session.mjs 里的 DM_SESSION_ID\n`)
} else if (wantSession) {
  process.stderr.write(`[dm-session] 接上常驻私信会话 ${DM_SESSION_ID}\n`)
}

let res = await run(buildArgs({ withSession: wantSession }))

// ② 被别的进程占着（GUI 打开着那条会话）⇒ 去掉 --session-id 重跑一次
if (wantSession && res.code !== 0 && LOCKED_RE.test(res.err)) {
  process.stderr.write(
    '[dm-session] ⚠️ 常驻私信会话被别的进程占着（多半是在 GUI 里打开着它；那是进程内写句柄，lsof 查不到）\n'
    + '[dm-session] ⇒ 本轮降级为新会话重跑一次：回复照发，但这一条会缺逐字历史（人设与共享记忆仍在）。\n'
    + '[dm-session] ⇒ 想要连续性的话，请在 GUI 里切到别的会话，把那条放开。\n')
  res = await run(buildArgs({ withSession: false }))
}

process.exit(res.code ?? 0)
