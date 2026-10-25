# dsh-bilibili-reader

> 在 B站 上养一个**会记得你**的值班机器人：定时刷视频、读字幕挑出值得的、写日报、发私信，
> 并且**它自己也在积累记忆、吃你的反馈、知道自己昨天推过什么**。
>
> 本仓库是**宿主侧的增强层** —— **不改上游插件源码，也不分发它的代码**。

---

## 一、我们的路线（与上游插件的区别）

| | 上游插件 [`c1overzz/dsh-bili-scroll`](https://github.com/c1overzz/dsh-bili-scroll) | **本仓库（宿主侧增强）** |
|---|---|---|
| 定位 | 插件本体：跑一轮、挑视频、写日报、发私信 | **在它外面加一层**：连续性 / 记忆 / 反馈 / 检索 / 自检 |
| 改它的方式 | 改仓库 ⇒ 你得跟着上游升级、维护自己的 fork | **运行时打补丁**：幂等脚本 + 自动备份，升级后重跑一次 |
| 私信连续性 | 2.1.0 起原生支持（`--session-id` + `dm-session.json`） | 我们先用**包装器**做（在 2.0.4 上）：只给私信轮插会话 id，撞锁自动降级 |
| 记忆 | 无 | 「正经轮」与「私信轮」**共享一份记忆库**（meow-memory），cwd 相同 ⇒ 天然同库 |
| 反馈 | 无（判据是静态规则） | **三个信号源 + 文件桥**：收到的赞 / 主号收藏夹 / 私信里的口头反馈 |
| 历史语料 | 只有一堆日报文件 | **本机 RAG**（`search_finds` / `have_seen`）⇒ 历史可检索 + 语义判重 |
| 无人值守保障 | 一轮跑完就结束 | **每日九步任务**：失败轮次检查 / headless 基线自检 / 索引更新 / 会话归档 |
| 权限面 | 2.1.0 起换成专用的**最小权限 profile** | **仍在 headless 上**（我们清楚这是一处取舍，理由见 `docs/CHANGES-vs-upstream.md` 末节）|

**一句话**：上游负责「怎么刷」，本仓库负责「刷完之后怎么变得像同一个人」。

---

## 二、它由什么组成

```
scripts/
  patch-plugin.sh           幂等补丁脚本：一次管七件改动（插件升级后重跑）
  selfcheck-headless.sh     基线自检：那一轮能不能自己退出 + 私信会话有没有被占用
  archive-sessions.sh       会话归档（永远跳过私信链）
  dm-session.mjs            包装器：给私信轮插 --session-id、套 caffeinate -i、挂视觉 MCP
  feedback.py               反馈采集（收藏夹 / 收到的赞 / 收到的回复）
  rag.py                    历史语料索引（SQLite + 本机嵌入模型）
  duty_mcp.py               自建 MCP：看图 / 抽帧 / 语义检索历史 / 判重
  vision-overlay.yml.template 视觉 MCP 的挂载模板（路径由 install.sh 渲染）
patches/
  dmsplit_patch.py          补丁⑦的 OLD/NEW 文本（**按上游版本反推生成**，见文档）
templates/
  cordis.patch.*.yml        两个 profile 的配置模板（密钥只写 apiKeyEnv，不落盘）
  skills/memory-recall/     「什么时候该去查记忆」的按需检索协议（DSH skill）
```

## 三、快速开始

```bash
# 0) 前置：DSH 本体 + 上游插件（装在 web profile 里）+ 本机 Ollama（拉一个嵌入模型）
# 1) 克隆本仓库，渲染配置
git clone https://github.com/mrwisdom2/dsh-bilibili-reader.git ~/dsh-bilibili-reader
cd ~/dsh-bilibili-reader && bash install.sh        # 渲染模板 + 创建 local.config.json
# 2) 填 local.config.json（你自己的 UID、会话 id、收藏夹 id）
# 3) 打补丁 + 自检
bash ~/.dsh/bili-duty/patch-plugin.sh
bash ~/.dsh/bili-duty/selfcheck-headless.sh
```

（`install.sh` 会把脚本铺到 `$BILI_DUTY_HOME`，默认 `~/.dsh/bili-duty`。）

## 四、安全须知（先读这段）

1. **这些轮次是"无人值守的 agent"**：上游 2.0.4 及以前，那一轮跑在 `headless` profile 上，
   **有文件读写、命令行、抓网页的能力**，而 DSH 的沙箱**只限制写、不限制读** ⇒
   它能读到你机器上的东西，而评论/私信是**沙箱外**发的 ⇒「读到 → 发出去」这条链是通的。
   ⇒ 我们的做法是**把红线写进章程与人设**（`duty.md` + `AGENTS.md`），**不指望沙箱兜底**。
   ⇒ 想更进一步：上游 2.1.0 换成最小权限 profile（代价见 `docs/CHANGES-vs-upstream.md`）。
2. **凭证与记忆都不入本仓库**：`.gitignore` 用的是**白名单式**（先忽略一切、再逐条放行），
   凭证、`memory.db`、日报、日志、会话一律不进；提交前跑 `tools/publish-check.sh` 三级扫描。
3. **公开评论是别人的地盘**：默认只发一条「@ 你」的评论、每轮最多回 1 条、对外语气收敛。
4. **免责声明**：本项目是**个人自用工具**，不是 B站 的官方或推荐用法。
   自动评论 / 自动私信属于平台使用条款的**灰色地带**，请自行判断风险；
   用别人的账号、或者拿来刷量刷评，都不是这套东西的用意。**用它 = 你自己承担后果。**

## 五、许可证与致谢

- 本仓库代码：MIT
- 上游插件 [`c1overzz/dsh-bili-scroll`](https://github.com/c1overzz/dsh-bili-scroll)（MIT）
  —— 本仓库**只在运行时**对它打补丁，**不复制、不再分发它的源码**；`patches/` 中出现的代码片段
  仅用于「改动前后」的精确匹配。
- 记忆层 [meow-memory]、语义层 [dsh-memory-semantic]（各自 MIT）
- 人设调性参考 [Kaalia0912/dsh-whale-musume-persona](https://github.com/Kaalia0912/dsh-whale-musume-persona)（MIT）
