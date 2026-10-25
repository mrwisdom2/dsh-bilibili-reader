# 第三方声明（NOTICE）

本仓库自身的代码以 **MIT** 发布（见 `LICENSE`）。以下第三方项目的权利归其作者所有。

## 一、上游插件的代码片段（重要）

`patches/dmsplit_patch.py` 与 `scripts/patch-plugin.sh` 中**出现上游插件的代码原文** ——
这是**运行时打补丁的必要条件**（补丁靠"逐字比对改动前后的文本"来保证幂等，所以必须原样引用）。

- 项目：[`c1overzz/dsh-bili-scroll`](https://github.com/c1overzz/dsh-bili-scroll)（MIT）

**边界**：本仓库**不复制、不再分发该插件的完整源码**，只包含用于精确匹配的**片段**。
使用者需要**自行安装上游插件**（见 `README.md` 第三节）。若上游作者认为这些片段的收录不妥，
提 issue 即可删除。

## 二、被调用（但不包含其代码）的项目

| 项目 | 与本仓库的关系 |
|---|---|
| [meow-memory](https://github.com/Phant0Meow/dsh-meow-memory)（MIT） | 记忆层：本仓库只在**配置层**调用它，并提供一个"定时器 unref"补丁（同样是运行时施加）|
| dsh-memory-semantic（MIT） | 语义检索层：配置层调用 |
| [Kaalia0912/dsh-whale-musume-persona](https://github.com/Kaalia0912/dsh-whale-musume-persona)（MIT） | **只参考人设的调性**，不含其代码 |
| DSH（DeepSeek Harness）本体 | 运行环境 |

## 三、使用者自己的数据

本仓库**不包含**任何凭证、记忆库、日报、日志或会话记录；`.gitignore` 采用**白名单式**
（先忽略一切、再逐条放行），并提供 `tools/publish-check.sh` 做发布前敏感扫描。
