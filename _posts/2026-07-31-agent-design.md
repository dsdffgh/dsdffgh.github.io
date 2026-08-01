---
title: "用 Codex 做一个 Research Agent MVP （下）"
date: 2026-07-31
categories: [llm, agent]
tags: ["Codex", "Ollama", "Gemma 3", "Agent", "Prompt Engineering"]
---

上一篇文章里，我用三次 Codex 任务做了一个 research agent MVP，并对比了不同提示词对代码形态的影响。那个 MVP 的核心路径很短：用户输入 query，provider 发起一次 `shell_search`，runtime 执行本地搜索，再把结果交给 provider 输出结构化答案。

这个路径能证明最小研究流程可以跑起来，但它还只是 agent runtime 的起点。为了判断这个设计后续应该怎么走，我又把它和 `pi` 做了一次对照。`pi` 是一个成熟得多的 TypeScript monorepo，里面有 `pi-ai`、`pi-agent-core`、`pi-coding-agent`、`pi-tui`、`orchestrator` 等包。它的目标也更大：支撑一个可交互、可扩展、有 session 和工具体系的 coding agent。

这次对比让我更清楚地看到：我的设计主干没有偏，但缺少 lifecycle semantics。真正的差距不在“有没有 provider、loop、runtime、session 这些目录”，而在运行时每个事件如何排序、状态何时快照、配置何时生效、工具结果如何进入 transcript、session 如何恢复、compaction 如何保持上下文结构。

## 对照 pi 的整体分层

我当前的设计是四层：

```text
messages -> loop -> runtime -> session
```

`pi` 的工程结构可以和这四层对应起来：

| 我的设计 | pi 中接近的部分 | 成熟度差异 |
| --- | --- | --- |
| `messages` | `packages/agent` 的 `AgentMessage`，以及 `packages/ai` 的 LLM message | `pi` 支持 app-specific message，并通过 projection 进入 LLM |
| `loop` | `packages/agent/src/agent-loop.ts` | `pi` 有完整生命周期事件和多轮 tool loop |
| `runtime` | `Agent` 和 `AgentHarness` | `pi` 有 steering、follow-up、tool hooks、turn snapshot、save point |
| `session` | `packages/agent/src/harness/session/*` | `pi` 已经有 append-only tree entries、leaf、compaction、branch summary |
| provider | `packages/ai` | `pi` 已经有统一多 provider API、retry、usage、provider hooks |
| 产品层 | `packages/coding-agent` | `pi` 把 agent core 和 CLI/UI/具体工具分开 |

这个对照说明，我最初定的四层方向是合理的。尤其第三版的 streaming provider 和 loop event 设计，和 `pi` 的低层 loop 更接近。问题是我的每层还比较薄，只规定了“谁负责什么”，没有深入到运行中的状态规则。

## Loop：从两轮 MVP 到完整生命周期

我的 MVP loop 当前只处理一条短路径：

```text
provider emits tool_call
runtime executes shell_search
provider emits final answer
```

这足够验证 MVP，但完整 agent loop 要处理更多事件。`pi` 的 loop 会发出类似这样的事件序列：

```text
agent_start
turn_start
message_start
message_end
message_start
message_update
message_end
tool_execution_start
tool_execution_end
message_start
message_end
turn_end
agent_end
```

一旦 assistant 发起 tool call，loop 会执行工具，把 tool result 作为消息加入 context，然后继续下一轮 LLM 调用。它还支持 steering 和 follow-up：用户可以在工具运行后改变方向，也可以在 agent 完成本轮任务后追加下一轮任务。低层 loop 还有 `shouldStopAfterTurn`，允许外层在一个完整 turn 结束后决定是否继续。

这对我的设计有一个直接启发：`LoopExecutor` 不应该只返回 `final/tool_call/retry/stop` 这四种结果，还应该产生可观察事件。比较合理的演进方向是：

```text
LoopResult 负责控制流
LoopEvent 负责 UI、debug timeline、session persistence
```

也就是说，`tool_call` 仍然是 runtime 的控制信号，但 `message_start`、`message_update`、`tool_execution_start`、`turn_end` 这类事件也要稳定存在。否则后续做 debug timeline、session replay、UI 渲染时，会缺少统一事实来源。

## Message：AgentMessage 和 LLM Message 应该分开

我当前的 message schema 更像直接给 provider 使用的 canonical message。它能表达 user、assistant、tool result、text part、tool call part，但没有把“agent 内部消息”和“provider 可见消息”分开。

`pi` 这里做得更细。它有 `AgentMessage`，里面可以放标准 LLM message，也可以放 app-specific message，比如 UI-only message、custom message、branch summary、compaction summary。真正调用 provider 前，再通过两个步骤进入 LLM：

```text
AgentMessage[] -> transformContext() -> AgentMessage[] -> convertToLlm() -> Message[] -> LLM
```

这个设计的好处很明显。session 和 UI 可以保留更多信息，provider 只看到它能理解的内容。比如 branch summary 可以在 UI 和 session 中存在，但不一定每次都传给 LLM；compaction summary 可以作为特殊 message 存在，再由 projection 决定如何进入上下文。

我的 design 下一步应该把 message 分成两种：

```text
AgentMessage: runtime/session/UI 使用，允许扩展
LlmMessage: provider 边界使用，只包含 provider 能理解的 role/content/tool
```

`messages` 层不应该只做 Pydantic schema，还应该有 projection contract。这样后续要加 debug timeline、session event、branch summary 时，不会污染 provider adapter。

## Runtime：需要 turn snapshot 和 save point

我的 runtime 现在负责组织 prompt、执行工具、回传 tool result、校验 final answer。这个职责方向没问题，但还缺一个非常关键的概念：turn snapshot。

`pi` 的 `AgentHarness` 把状态分成几类：

```text
harness config
turn snapshot
session
pending session writes
```

`harness config` 是当前最新配置，比如 model、thinking level、tools、resources、system prompt。`turn snapshot` 是某一轮 LLM 请求实际使用的状态。运行中如果用户或 extension 改了 model、tool、resources，这些修改不会改变已经发出去的 provider request，只影响下一轮。

这个规则需要一个 save point。`pi` 的 save point 大致发生在 assistant turn 和 tool result messages 都完成之后。到这个点，harness 可以刷新 context、model、thinking level、resources、stream options，再准备下一次 provider request。

这解决了一个很容易混乱的问题：运行中修改配置到底影响当前请求还是下一轮请求？没有 turn snapshot，代码很容易在某个 await 之后读到已经变化的全局状态，导致一次 turn 内部前后不一致。

我的 design 应该加入这条规则：

```text
runtime 每次调用 loop 前创建 TurnSnapshot。
TurnSnapshot 包含本轮 messages、model、tools、resources、system prompt、stream options。
运行中配置修改只影响下一次 TurnSnapshot。
save point 出现在 assistant message 和对应 tool result 全部完成之后。
```

这比简单维护一个 `_state` 更重要。`_state` 只是变量集合，turn snapshot 才是并发和恢复语义。

## Session：append-only log 还不够，要变成 tree entries

我原来的 session 设想是 append-only event log，支持 resume、branch、debug timeline。这个方向对，但还不够具体。

`pi` 的 session 更像 append-only tree。每个 entry 有 `id`、`parentId`、`timestamp` 和类型。除了 message entry，还有 model change、thinking level change、active tools change、leaf entry、compaction entry、branch summary entry 等。当前分支由 leaf 决定，恢复时通过减少 entries 得到当前上下文和配置。

这比普通线性日志强，因为 agent 往往不止一条对话时间线。用户可能从某个历史点 fork，可能做 compaction，可能生成 branch summary，也可能导航到另一个 leaf。线性日志可以记录发生过什么，tree entries 更适合表达“当前分支是哪条路径”。

我的 design 里已经提到 branch 用 `id/pid` 树结构表达，后续应该把它具体化为 session entry model：

```text
message_entry
tool_result_entry
model_change_entry
thinking_level_change_entry
active_tools_change_entry
leaf_entry
compaction_entry
branch_summary_entry
operation_started_entry
operation_finished_entry
operation_interrupted_entry
```

这里还有一个恢复边界问题。provider stream 不能真正从中间恢复，工具实现、model/auth provider、resource loader、extension hook 也都是宿主应用提供的运行时对象。`pi` 的 durable harness 文档里把这个说得很清楚：session 可以保存可序列化状态，但工具实现和 auth provider 需要宿主应用在 resume 时重新提供。

所以我的 session 目标应该叫 semi-durable。更现实的恢复策略是：

```text
provider request 未完成：标记 interrupted，不自动重试
tool call 未完成：默认写入 interrupted/error tool result，只有工具声明 retry-safe 才允许重试
compaction 未完成：如果没有 final compaction entry，可以重新执行
branch navigation 未完成：根据 leaf entry 和 branch summary entry 判断是否继续完成
```

这样写，resume 的边界会清楚很多。

## Compaction：不能只说 tool_call 和 tool_result 成对

我之前最关注的 compaction 约束是：`tool_call` 和 `tool_result` 必须成对保留。这个约束很重要，但完整 compaction 还要考虑更多。

`pi` 的 compaction 设计包含这些元素：

- token 估算
- 判断是否达到 compaction 阈值
- 查找保留区间的起点
- 识别 turn boundary
- 处理 split-turn 场景
- 生成 compaction summary
- 保留 previous summary
- 记录 `firstKeptEntryId`
- 记录 file operation details
- 生成 branch summary

这里最值得学的是：compaction 不应该直接对 message array 做简单裁剪，而应该基于 session entries 和 turn boundary 做选择。否则很容易破坏上下文结构。

我的 design 可以把 compaction 分成三个阶段：

```text
prepareCompaction(entries, budget) -> CompactionPlan
generateSummary(plan) -> summary
appendCompactionEntry(summary, firstKeptEntryId, details)
```

其中 `CompactionPlan` 至少要包含：

```text
messagesToSummarize
turnPrefixMessages
firstKeptEntryId
isSplitTurn
tokensBefore
fileOps
previousSummary
```

这样一来，context compaction 就从“把前面的消息缩短”变成一个可测试、可恢复、可审计的 session mutation。

## Tool：工具生命周期要比 shell_search 更完整

我的 MVP 只有一个 `shell_search`。它已经暴露出不少真实问题：Windows 路径、UTF-8、`rg` 输出解析、无证据语义。对 research agent 来说，这些问题很重要，但它们属于具体工具的正确性。工具系统本身还需要更完整的生命周期。

`pi` 的工具定义有：

```text
name
label
description
parameters
executionMode
execute()
onUpdate
details
```

工具可以并行执行，也可以要求顺序执行。如果 assistant 一次返回多个 tool call，`pi` 可以让工具完成事件按实际完成顺序发出，但 transcript 里的 tool result 仍按 assistant 原始 tool call 顺序保存。这是一个很细但很重要的规则：UI 可以显示真实完成顺序，模型上下文保持稳定顺序。

我的 design 应该把 tool lifecycle 写成事件：

```text
tool_execution_start
tool_execution_update
tool_execution_end
tool_result_message_appended
```

错误语义也要统一。工具失败应该抛出或返回 typed error，由 runtime 转成 `is_error: true` 的 tool result。工具错误不能当 evidence。对于 research agent，后续 final answer validator 还要检查：如果所有 tool result 都是 error，answer 必须降低 confidence，并把限制写进 limitations。

## Observability：默认只记录安全元数据

我原先提到 debug timeline，但没有细说可观测事件的安全边界。`pi` 的 observability 文档给了一个很好的方向：core 只发稳定、安全的结构化事件，不绑定 OpenTelemetry、Sentry 或某个 APM。

适合默认记录的字段包括：

```text
provider
model
session id
entry type
tool name
status code
stop reason
token counts
costs
durations
```

默认不应该记录：

```text
prompt
completion
tool args
tool result
shell output
file contents
provider request payload
provider response body
API key
headers
```

这对 research agent 很重要。因为它会读本地文件，工具结果里可能有路径、源码、配置甚至敏感内容。如果 debug timeline 默认记录全量 prompt 和 tool output，很快就会变成安全风险。比较合理的做法是：timeline 默认记录事件和摘要，内容捕获必须显式开启，并允许 redaction。

## 当前设计应该怎么改

对照 `pi` 后，我会把自己的 research agent roadmap 调整成下面这样。

第一阶段继续保留 MVP，但修正语义问题：

- 使用第三版的 `stream()` loop 作为骨架
- `shell_search` 返回结构化结果
- 无 hits 时 evidence 为空，confidence 为 `low`
- query 中存在本地目录时，把它作为 research cwd
- 固定 Windows 编码和路径解析

第二阶段加入完整 loop lifecycle：

- `agent_start`
- `turn_start`
- `message_start`
- `message_update`
- `message_end`
- `tool_execution_start`
- `tool_execution_update`
- `tool_execution_end`
- `turn_end`
- `agent_end`

第三阶段拆分 `AgentMessage` 和 `LlmMessage`：

- `AgentMessage` 支持 custom、branchSummary、compactionSummary、toolResult、assistant
- `transformContext()` 负责裁剪和注入外部上下文
- `convertToLlm()` 负责 provider 边界投影

第四阶段加入 turn snapshot 和 save point：

- 每轮创建 `TurnSnapshot`
- runtime config 修改影响下一轮
- assistant message 和 tool result 完成后刷新下一轮状态

第五阶段做 session tree：

- append-only entry
- leaf entry
- branch summary
- compaction entry
- active tools/model/thinking config entry

第六阶段做 compaction：

- token estimate
- turn boundary
- previous summary
- split-turn plan
- file operation details
- compaction summary

第七阶段做 semi-durable resume：

- 恢复 session tree
- 校验宿主应用提供的 model/tool/resource/auth
- 未完成 provider request 标记 interrupted
- 未完成 tool call 默认不重试
- retry-safe 工具可以显式允许重试

这样排下来，MVP 不会一下子变成大型 harness，但每一步都和最终架构能接上。

## 下篇提示词应该怎么写

如果要让 Codex 按这个方向继续实现，提示词不能只说“参考 pi”。这样模型很可能直接模仿目录结构，或者引入过多当前阶段不需要的东西。更好的写法是指定要借鉴的机制，并限制当前阶段只实现一件事。

比如下一阶段可以这样写：

```md
继续当前 research agent 项目。

参考 E:\GitClone\pi 的 agent loop 思路，但不要复制 pi 的目录结构，也不要一次性实现 harness/session/compaction。

当前阶段只做 loop lifecycle events。

目标：
把现有 LoopExecutor / AgentRuntime 从只返回最终结果，扩展为稳定发出生命周期事件：
- agent_start
- turn_start
- message_start
- message_update
- message_end
- tool_execution_start
- tool_execution_update
- tool_execution_end
- turn_end
- agent_end

边界：
- 不实现 session persistence
- 不实现 compaction
- 不实现 branch
- 不实现 multi-provider registry
- 不改变 shell_search 的业务逻辑，除非现有测试要求

要求：
1. 新增 AgentEvent schema。
2. Runtime 在执行 MVP 流程时按确定顺序记录 events。
3. Provider stream delta 对应 message_update。
4. tool_call 前后必须有 tool_execution_start / tool_execution_end。
5. tool result 作为 message_start / message_end 进入事件流。
6. 当前 CLI 输出不变。
7. 新增测试断言完整事件顺序。
8. 测试必须使用 deterministic provider，不依赖 Ollama。

验收：
uv run pytest -q
uv run ruff check .
uv run python -m compileall -q src tests
```

这个提示词的重点是：只借鉴机制，不复制整个系统；只做 lifecycle events，不同时碰 session 和 compaction。这样可以把成熟项目里的经验转成当前项目能承受的增量。

## 小结

`pi` 对我当前设计最大的参考价值，是它把“agent 运行中发生了什么”变成了稳定的事件、快照和 session entry。相比之下，我的 MVP 还停在“能完成一次 research flow”。这个阶段已经够验证想法，但还不足以承载可恢复、可观测、多轮工具调用的 agent。

如果继续做，我会以第三版的 streaming loop 作为骨架，把第一、二版暴露出的 Windows 和 evidence 问题修进去，然后按 `pi` 的经验逐步加入 lifecycle event、AgentMessage projection、turn snapshot、session tree、compaction plan 和 semi-durable resume。

最终目标并非把 `pi` 重新写一遍。更值得做的是提炼它已经证明有效的 runtime 语义，再用于一个更专注的 research agent。这个 agent 的特殊价值应该体现在 evidence policy、source provenance 和 structured final answer 上；通用 harness 机制可以向 `pi` 学，研究结果可信度这部分则要自己做得更严格。
