# PAgent — Personal Agent iOS App 实现文档

> 版本 v1.0 · 2026-11-10
> 架构方向：端侧优先 + 云端兜底混合推理；数据源为 EventKit / CoreLocation+MapKit / PhotoKit+HealthKit / Share Extension+App Intents

---

## 1. 产品定义

PAgent 是一个常驻 iOS 的个人代理。它做三件事：

1. **理解我** — 从日历、位置轨迹、照片元数据、健康作息、以及我主动分享的内容中，持续构建一份可解释的兴趣与生活节奏画像。
2. **替我规划** — 基于画像 + 实时约束（空闲时段、通勤时间、营业时间、天气），生成具体可执行的行程方案。
3. **写回系统** — 用户确认后，把行程落到系统日历与提醒事项，并在执行过程中做轻量跟进。

**核心设计原则（贯穿全文）**

| 原则 | 含义 |
|---|---|
| 原始数据不出设备 | 离开设备的只有一张经端侧模型压缩的「画像卡」（≤500 token）和当次任务必需的最小上下文 |
| 写操作必须用户确认 | Agent 永不自动创建/修改日历事件，只提交待确认的提案 |
| 画像可解释、可编辑、可删除 | 每条兴趣标签都能追溯到来源信号，用户可逐条否决 |
| 端侧做原子任务，云端做推理 | 由端侧模型的硬约束决定（见 §2） |

---

## 2. 关键技术约束（已核实）

这一节是全文架构的事实依据。**两条约束直接否决了"纯端侧规划"的方案。**

### 2.1 端侧模型：Foundation Models framework

| 项目 | 事实 | 影响 |
|---|---|---|
| 上下文窗口 | **4096 token**（iOS 26），且**包含**系统指令 + 提示 + 响应 + 工具定义与工具输入输出的全部开销 | 端侧**无法**承载多日行程推理（需要同时装入画像、空闲时段、候选地点、交通时间——轻易超 10k token） |
| 参数规模 | 约 3B（dense） | 适合打标签、意图分类、短摘要、结构化抽取；不适合多步约束求解 |
| 超限行为 | 抛 `.exceededContextWindowSize`；错误里报的 token 数是**触发时**的数字（可能显示 4090/4100），真实上限恒为 4096 | 必须自己做 token 预算，不能依赖错误信息 |
| 运行时读取上限 | iOS 26.4+ 提供 `SystemLanguageModel.default.contextSize` 与 `tokenCount(for:)`，且标注 `@backDeployed(before: iOS 26.4)` | **不要硬编码 4096**；用 `contextSize` 读取，用 `tokenCount(for:)` 做预算 |
| 用量统计 | session / response 上有 `usage`（total / cache-read / reasoning tokens） | 可用于端侧预算监控 |
| 设备门槛 | 需 Apple Intelligence 可用机型（iPhone 15 Pro 及以上 / M 系列） | **必须有云端降级路径**；端侧是优化项，不是必需项 |
| 护栏误报 | 生产环境中 guardrail false positive 是已知的真实问题 | 每个端侧调用都要有 catch + 降级，不能当成稳定返回 |

权威参考：Apple TN3193《Managing the on-device foundation model's context window》，以及 WWDC25 session 301 / WWDC26 session 241。

> **关于 PrivateCloudComputeLanguageModel**（iOS 27 起，32K 窗口 + reasoning，换一行代码即可切换）：这是一条很有吸引力的中间路线——同样的 `LanguageModelSession` / `@Generable` / `Tool` 协议，隐私模型优于第三方云。但它需要 entitlement，且 API 细节来自二手资料。**列为 Phase 4 的评估项**，不作为 v1 依赖；若申请到 entitlement，可替代部分 Sonnet 调用。

### 2.2 iOS 沙盒：拿不到的数据

明确记录，避免后续返工。以下数据在 App Store 上架的应用中**完全不可获取**：微信/iMessage 聊天记录、Safari 浏览历史、通话记录、其他 App 的使用内容。

因此"从手机历史交互中学习"的可行实现是：**可授权的系统数据源（日历/位置/照片元数据/健康）+ 用户主动分享（Share Extension）**。Share Extension 是绕开沙盒限制的唯一通用途径——用户从任意 App 分享链接或文字给 PAgent，由 Agent 解析入库。

### 2.3 API Key 不能进客户端

`ANTHROPIC_API_KEY` 绝不可打进 iOS 二进制（可被轻易提取）。因此**必须有一个后端代理**。这同时带来一个架构简化：代理保持无状态，只做鉴权 + 注入 key + 配额，不存任何个人数据——这也是最干净的隐私叙事（见 §9）。

---

## 3. 整体架构

```
┌───────────────────────────── iOS Device ──────────────────────────────┐
│                                                                       │
│  ┌─ Capture 层 ─────────────────────────────────────────────────┐    │
│  │ EventKit  CoreLocation  PhotoKit  HealthKit  ShareExtension  │    │
│  └───────────────────────────┬──────────────────────────────────┘    │
│                              ↓ SignalEvent (append-only)              │
│  ┌─ Profile 层 ─────────────────────────────────────────────────┐    │
│  │  NightlyDigestJob (BGTaskScheduler)                          │    │
│  │    └→ Foundation Models：分批打标签/抽取（每批 <2500 tok）   │    │
│  │  InterestGraph：衰减权重标签分 + 来源溯源                     │    │
│  │  ProfileCard 生成器（≤500 tok，唯一出境载荷）                 │    │
│  └───────────────────────────┬──────────────────────────────────┘    │
│                              ↓                                        │
│  ┌─ Agent 层（Agent Loop 跑在设备上）────────────────────────────┐   │
│  │  Router：意图分类 → 端侧 / Sonnet / Opus                      │   │
│  │  本地工具执行：Calendar / Places / TravelTime / Profile       │   │
│  │  ItineraryProposal（结构化，待确认）                          │   │
│  └───────────────────────────┬──────────────────────────────────┘    │
│                              ↓ 用户确认                               │
│  ┌─ Commit 层 ──────────────────────────────────────────────────┐    │
│  │  EventKit 写入（日历事件 + 提醒）· 可撤销                     │    │
│  └──────────────────────────────────────────────────────────────┘    │
└───────────────────────────────┬───────────────────────────────────────┘
                                │ HTTPS（画像卡 + 任务上下文，无原始数据）
                                ↓
┌──────────── Stateless Proxy（Cloudflare Workers）─────────────┐
│  DeviceCheck 鉴权 · 注入 API Key · 配额/限流 · SSE 转发        │
│  不落盘任何请求体                                              │
└───────────────────────────────┬───────────────────────────────┘
                                ↓
                        Claude API (Messages)
```

### 3.1 为什么 Agent Loop 跑在设备上

两个可选方案：

- **方案 A：Loop 在后端。** 后端调 Claude，Claude 请求工具 → 后端需要设备数据 → 回程到设备取 → 再继续。每次工具调用一个额外 RTT，且后端必须理解个人数据结构。
- **方案 B（采用）：Loop 在设备。** 设备持有 `messages` 数组，每一轮把请求打给代理（代理只加 key 后转发），拿到 `tool_use` 后在本地执行（EventKit 查询、MapKit 搜索），把 `tool_result` 塞回数组继续下一轮。

选 B。原因：代理彻底无状态、原始日历/位置数据从不离开设备、工具实现与数据层同进程（无序列化开销）、离线时端侧路径可独立工作。

代价：移动网络下多轮 tool use 的延迟累加。缓解手段见 §7.4。

---

## 4. 技术栈

### 4.1 iOS 客户端

| 层 | 选型 | 理由 |
|---|---|---|
| 语言 | Swift 6.2+（strict concurrency） | 本机已装 Swift 6.4.2 |
| UI | SwiftUI + Observation | 新项目无 UIKit 包袱；`@Observable` 替代 ObservableObject |
| 最低部署 | **iOS 26.0** | Foundation Models 的下限；低于此版本无端侧路径，混合架构失去意义 |
| 本地持久化 | **SwiftData** | 与 SwiftUI/Observation 集成最好；模型即 Swift 类型。注意：复杂聚合查询性能弱于 GRDB，故把"标签分聚合"做成物化表而非每次 query 时算（见 §5.3） |
| 端侧推理 | FoundationModels（`LanguageModelSession` / `@Generable` / `Tool`） | 系统框架，免费、离线、过审友好 |
| 日历/提醒 | EventKit | 唯一途径 |
| 位置 | CoreLocation（`CLMonitor` 区域监测 + visit monitoring） | 用 visit/region 而非持续定位，省电且过审理由充分 |
| 地点/路线 | MapKit（`MKLocalSearch`, `MKDirections`） | 免费额度内，不需第三方 POI 服务 |
| 照片元数据 | PhotoKit（`PHAsset.location` / `creationDate`，**只读元数据，不读像素**） | 元数据足以还原"去过哪里"；不读像素大幅降低隐私风险与审核摩擦 |
| 健康 | HealthKit（睡眠、步数、锻炼） | **Phase 3 才接入**，见 §11 风险 R4 |
| 分享入口 | Share Extension + App Intents + Siri/Shortcuts | 绕开沙盒的通用入口 |
| 后台任务 | BGTaskScheduler（`BGProcessingTask` 跑夜间 digest） | 端侧推理耗电，必须在充电+闲时跑 |
| 网络 | URLSession（SSE 流式解析自实现） | **Swift 无官方 Anthropic SDK**；且客户端只跟自家代理说话，协议由我们定 |
| 密钥 | Keychain + DeviceCheck/App Attest | 客户端只持设备凭证，不持 API key |
| 测试 | Swift Testing + XCTest(UI) | |

### 4.2 后端代理

| 层 | 选型 | 理由 |
|---|---|---|
| 运行时 | **Cloudflare Workers**（TypeScript / Hono） | 边缘部署降低 RTT；天然适合 SSE 转发；无状态场景下运维成本近零 |
| Claude 接入 | `@anthropic-ai/sdk` | 后端有官方 TS SDK，直接用（避免手写 HTTP） |
| 鉴权 | App Attest 断言校验 → 短期 JWT | 防止 key 被白嫖 |
| 配额 | Durable Objects 或 KV 计数 | 按设备/订阅层级限流 |
| 日志 | **只记元数据**（token 数、延迟、模型、错误码），**绝不记请求体** | 隐私承诺的技术落地 |
| 密钥 | Workers Secrets | |

> 替代方案：若团队更熟 Python，FastAPI + `anthropic` SDK 部署在 Fly.io 同样可行；SSE 转发代码量相当。选 Workers 的唯一硬理由是边缘延迟。

### 4.3 模型选型与成本

| 用途 | 模型 | 单价（per MTok） | 说明 |
|---|---|---|---|
| 信号打标签、意图分类、短摘要 | Foundation Models（端侧） | **$0** | 占调用量 ~85% |
| 单日规划、改期、问答 | `claude-sonnet-5` | $3 / $15 | 1M 窗口，adaptive thinking 默认开 |
| 多日/多约束复杂规划 | `claude-opus-4-8` | $5 / $25 | 1M 窗口，长程 agentic 最强 |
| 云端批量分类（端侧不可用时降级） | `claude-haiku-4-5` | $1 / $5 | 200K 窗口 |

**单次规划成本估算**（启用 prompt caching：系统提示 + 工具定义 + 画像卡共约 12k token 命中缓存，新增 3k uncached input，输出 3k）：

```
Sonnet 5:   12k×$0.30 + 3k×$3  + 3k×$15  ≈ $0.0036 + $0.009 + $0.045 ≈ $0.058
Opus 4.8:   12k×$0.50 + 3k×$5  + 3k×$25  ≈ $0.0060 + $0.015 + $0.075 ≈ $0.096
```

按重度用户每月 20 次规划（其中 4 次走 Opus）≈ $1.31/月。订阅定价需 ≥ $6.99/月 才有健康毛利。**路由器质量直接决定单位经济性**——把能走 Sonnet 的任务误判给 Opus，成本翻 1.65 倍。

---

## 5. 数据模型（SwiftData）

### 5.1 信号层（append-only，原始事实）

```swift
@Model final class SignalEvent {
    #Index<SignalEvent>([\.occurredAt], [\.source])
    var id: UUID
    var source: SignalSource          // .calendar/.visit/.photo/.health/.shared/.manual
    var occurredAt: Date
    var payload: Data                 // 源特定的 Codable，JSON 编码
    var digestedAt: Date?             // nil = 待夜间处理
    var retentionUntil: Date          // 到期自动清理（默认 occurredAt + 180d）
}
```

`payload` 保持源特定、不做早期归一化——归一化规则一定会变，而原始信号重放是唯一的修正手段。`retentionUntil` 是数据最小化原则的强制执行点。

### 5.2 兴趣图谱（派生，可解释）

```swift
@Model final class InterestTag {
    @Attribute(.unique) var slug: String   // "cuisine.sichuan", "activity.hiking"
    var displayName: String
    var score: Double                      // 衰减权重累加分，0...1 归一化
    var lastReinforcedAt: Date
    var userVerdict: UserVerdict           // .unreviewed / .confirmed / .rejected
    @Relationship(deleteRule: .cascade) var evidence: [TagEvidence]
}

@Model final class TagEvidence {
    var signalEventID: UUID                // 溯源到原始信号
    var weight: Double
    var extractedAt: Date
    var rationale: String                  // 端侧模型给出的一句话理由，用于 UI 展示
}
```

`evidence` + `rationale` 是"可解释画像"的实现基础：UI 上每个标签都能展开成"因为你在 9/14 去过 XX，10/2 分享了 YY"。`userVerdict == .rejected` 的标签永久排除出画像卡，且其 evidence 不再参与任何重算。

### 5.3 物化聚合（绕开 SwiftData 聚合查询弱项）

```swift
@Model final class ProfileSnapshot {
    var generatedAt: Date
    var cardMarkdown: String      // ≤500 token 的画像卡，出境载荷
    var cardTokenCount: Int       // 用 tokenCount(for:) 实测
    var topTagSlugs: [String]
    var routineSummary: String     // "工作日 7:10 起床；周六通常 10-12 点在城西活动"
}
```

每次夜间 digest 后重算一份 snapshot。规划请求直接读最新 snapshot，不在请求路径上做聚合。

### 5.4 行程提案（待确认）

```swift
@Model final class ItineraryProposal {
    var id: UUID
    var createdAt: Date
    var requestSummary: String
    var status: ProposalStatus         // .draft/.presented/.committed/.discarded
    var modelUsed: String              // 审计用："claude-opus-4-8"
    @Relationship(deleteRule: .cascade) var items: [ItineraryItem]
    var committedEventIdentifiers: [String]   // EventKit ID，用于撤销
}

@Model final class ItineraryItem {
    var title: String
    var startsAt: Date
    var endsAt: Date
    var placeName: String?
    var coordinate: CLLocationCoordinate2D?
    var travelFromPrevious: TimeInterval?
    var rationale: String              // 为什么选它 —— 必填，不允许黑箱推荐
    var alternatives: [String]         // 备选，用户可一键替换
}
```

`committedEventIdentifiers` 让"撤销整个行程"成为一次确定性操作，而不是让用户手动删 8 个日历事件。

---

## 6. 偏好/兴趣建模

### 6.1 夜间 Digest 流水线

端侧模型 4096 token 窗口是这条流水线的全部设计约束：**不能把一天的信号一次喂进去**。

```
BGProcessingTask（要求充电 + 网络可选）
  ↓
取 digestedAt == nil 的 SignalEvent，按 occurredAt 排序
  ↓
分批：用 tokenCount(for:) 累加，每批硬上限 2500 token
      （留 ~1000 给系统指令 + @Generable schema + 输出）
  ↓
每批 → LanguageModelSession.respond(generating: TagExtraction.self)
  ↓
失败（护栏误报 / 超窗）→ 批次减半重试一次 → 仍失败则标记 skipped 并留给云端 Haiku 兜底
  ↓
合并标签 → 衰减更新 InterestGraph → 重算 ProfileSnapshot
```

```swift
@Generable struct TagExtraction {
    @Guide(description: "最多 5 个兴趣标签，使用点分 slug 如 cuisine.sichuan")
    var tags: [ExtractedTag]
}

@Generable struct ExtractedTag {
    var slug: String
    @Guide(description: "0.0 到 1.0 的置信度")
    var confidence: Double
    @Guide(description: "一句话说明从哪条信号得出此标签")
    var rationale: String
}
```

**每个端侧调用都必须包在 do/catch 里并有降级分支**——护栏误报在生产中是常态，不是异常。

### 6.2 衰减与强化

```
score_new = score_old × exp(-λ · Δt) + Σ(confidence_i × sourceWeight_i)
```

- `λ` 取半衰期 90 天（兴趣会变，但不该一周就忘）
- `sourceWeight`：主动分享 1.0 > 日历事件 0.8 > 重复到访 0.6 > 照片位置 0.4 > 健康推断 0.3
  —— 主动行为权重最高，被动推断最低，这既是准确性判断也是隐私姿态
- `userVerdict == .confirmed` 的标签 `λ = 0`（不衰减）

### 6.3 画像卡 —— 出境边界

画像卡是**唯一默认离开设备的个人数据**，必须 ≤500 token 且人类可读（用户可在设置里完整查看"我发出去的是什么"）。

```markdown
## 画像
口味：川菜/云南菜偏好强；不吃生食。
活动：徒步（月均 2 次）、独立书店、小型 livehouse。
节奏：工作日 7:10 起 / 23:30 睡；周六上午通常空闲。
地理：常驻城西，可接受单程 ≤40 分钟。
规避：人多的商场；连续两天高强度行程。
```

生成方式：端侧模型基于 top tags + routine 汇总成自然语言；生成后用 `tokenCount(for:)` 校验，超限则削减低分标签重试。

---

## 7. Agent 设计

### 7.1 路由器

意图分类跑在端侧（4096 窗口对单句分类完全够用），决定去哪：

| 意图 | 路由 | 示例 |
|---|---|---|
| 信号打标签、分享内容解析 | 端侧 | — |
| 事实问答、单项查询 | 端侧 + 本地工具 | "我周六几点有空" |
| 单日规划、改期、单点替换 | Sonnet 5 | "周六下午安排点事" |
| 多日规划、多约束、跨城 | Opus 4.8 | "下周末两天，想去看展+徒步，别太赶" |
| 端侧不可用（设备不支持/护栏失败） | Haiku 4.5 降级 | — |

路由决策必须记录在 `ItineraryProposal.modelUsed`，用于后续成本归因与路由器调优。

### 7.2 工具（全部在设备上执行）

```
search_calendar(start, end)              → 空闲时段 + 既有事件（标题脱敏为类别）
search_places(query, near, radius, open_at) → MKLocalSearch 结果
get_travel_time(from, to, mode, depart_at)  → MKDirections ETA
get_user_profile(facets)                 → 画像卡的指定切面
get_routine(dayOfWeek)                   → 作息/习惯模式
```

`search_calendar` 返回时**把事件标题替换为类别**（"会议"/"私人"/"通勤"），除非用户显式开启"允许发送日历标题"。模型需要的是时间结构，不是"和 X 谈离职"。

**`create_calendar_events` 不是工具。** 写操作不进 Agent 的工具集——模型只能产出 `ItineraryProposal`，提交由 UI 层在用户点击确认后调用。这样模型即使被 prompt injection 攻陷（分享来的网页内容是不可信输入！）也无法改动日历。

### 7.3 云端请求构造

```ts
// 代理透传；以下为设备侧构造的请求体要点
{
  model: "claude-opus-4-8",
  max_tokens: 64000,                        // 流式，给足空间
  thinking: { type: "adaptive" },           // Opus 4.8 省略该字段 = 不思考，必须显式开
  output_config: { effort: "high" },        // 长程 agentic 的推荐起点；按 eval 扫 medium/high/xhigh
  system: [
    { type: "text", text: AGENT_INSTRUCTIONS },
    { type: "text", text: profileCard, cache_control: { type: "ephemeral" } }
  ],
  tools: TOOLS,                             // 固定顺序，序列化确定性
  messages: [...]
}
```

要点与踩坑：

- **`thinking: {type:"adaptive"}` 必须显式写。** Opus 4.8 / 4.7 省略 `thinking` 字段 = 不思考。且 `budget_tokens` 在 4.7+ 已移除（传了报 400），`temperature`/`top_p`/`top_k` 同样报 400。
- **`display: "summarized"`** — 若 UI 要展示"正在思考什么"，必须显式设置；默认是 `"omitted"`，`thinking` 字段为空串，UI 上表现为长时间空白。
- **Prompt caching 的字节稳定性是硬要求。** 渲染顺序为 `tools → system → messages`。缓存断点打在 system 最后一块上，可同时缓存 tools + system。因此：**系统提示里绝不能插入当前时间/UUID**（会让每次请求前缀不同、缓存全废）；工具列表按名字排序固定；画像卡只在夜间 digest 后变更，日内稳定。当前时间作为 user turn 的内容传入。
- **最低可缓存前缀：Opus 4.8 为 4096 token。** 系统提示 + 工具定义 + 画像卡必须超过这个量才会真正命中缓存，否则静默不缓存（`cache_creation_input_tokens` 为 0，不报错）。实测确认。
- **必须流式。** `max_tokens` 超过 ~16k 的非流式请求会撞 HTTP 超时。
- **工具结果必须合并在一条 user message 里。** 一轮 assistant 的多个 `tool_use` → 一条 user message 装所有 `tool_result`。拆成多条会静默地让模型以后不再并行调用工具。
- **`stop_reason` 必须分支处理**：`pause_turn`（服务端工具迭代上限，回传后继续）、`max_tokens`、`refusal`（读 `content[0]` 前先查，否则越界崩溃）。
- **工具输入一律 JSON 解析**，不做字符串匹配——转义行为在模型间有差异。

### 7.4 延迟控制

多轮 tool use 在移动网络下会累加 RTT。缓解：

1. **预取**：用户打开规划界面时就并行跑 `search_calendar` + `get_user_profile`，把结果作为首轮 user message 的一部分直接给出，省掉第一轮工具往返。
2. **并行工具**：模型一轮内发多个 `tool_use` 时，`withThrowingTaskGroup` 并发执行（MapKit 搜索天然可并行）。
3. **流式渲染**：`thinking` summary + 文本增量边到边显示，感知延迟远低于实际。
4. **边缘代理**：Workers 部署降低 TLS + 转发开销。

---

## 8. 后端代理

职责边界极窄 —— 这是设计目标，不是偷懒：

```ts
// POST /v1/messages  (SSE passthrough)
async function handle(req: Request, env: Env) {
  const device = await verifyAppAttest(req, env);     // 1. 设备鉴权
  await assertQuota(device, env);                     // 2. 配额
  const upstream = await anthropic.beta.messages      // 3. 注入 key + 转发
    .stream(await req.json());
  logMetadataOnly(device, upstream);                  // 4. 只记元数据
  return sseResponse(upstream);
}
```

**不做**：不解析请求体内容、不落盘、不做会话管理、不理解个人数据结构。这让"原始数据不出设备 + 出境数据不留存"成为一条可在隐私政策里写明、且技术上可审计的承诺。

---

## 9. 隐私与 App Store 合规

### 9.1 Info.plist 用途说明

| Key | 说明要点（必须具体，泛泛而谈会被拒） |
|---|---|
| `NSCalendarsFullAccessUsageDescription` | iOS 17+ 的新 key。说明：读取空闲时段以规划行程，并在你确认后写入日程 |
| `NSRemindersFullAccessUsageDescription` | 同上 |
| `NSLocationWhenInUseUsageDescription` | 推荐附近地点、计算通勤时间 |
| `NSLocationAlwaysAndWhenInUseUsageDescription` | 识别常去区域与生活节奏。**需要充分理由**，且必须提供仅前台模式的降级体验 |
| `NSPhotoLibraryUsageDescription` | 明确写"仅读取拍摄时间与地点，不读取照片内容" |
| `NSHealthShareUsageDescription` | 了解作息与运动习惯以避免过载安排（Phase 3） |

### 9.2 Privacy Manifest（`PrivacyInfo.xcprivacy`）

自 2024 年 5 月起为必需项。需申报：
- `NSPrivacyCollectedDataTypes`：位置（精确）、健康与健身、日历、照片或视频（元数据）、用户内容
- 每项的 `Purposes` 与 **`LinkedToUser` / `UsedForTracking`** —— 本应用全部 `UsedForTracking = false`
- `NSPrivacyAccessedAPITypes`：如用到 file timestamp / user defaults / disk space 等需申报 reason code
- 第三方 SDK 的 manifest 与签名（尽量不引入第三方 SDK，正是为了避免这块）

### 9.3 审核红线

| 条款 | 要求 | 本设计的应对 |
|---|---|---|
| HealthKit | 必须有清晰健康用途；**不得用于广告**；**不得存入 iCloud** | 健康数据仅参与端侧推断，派生标签不含原始数值；无广告；不同步 |
| 5.1.1 数据最小化 | 不得索取非功能必需的数据 | 四个数据源全部可独立关闭，关闭后功能降级而非崩溃；`retentionUntil` 自动清理 |
| 5.1.2 数据使用 | 不得在用户不知情下外传 | 设置页可完整查看画像卡原文 + 出境记录 |
| 后台位置 | 需明确说明且不得过度 | 用 visit/region monitoring 而非持续定位；首次使用先申请 WhenInUse，有价值后再升级 |
| AI 功能披露 | 云端处理需告知 | 首启动与设置页明示"复杂规划会将画像卡发送至 Anthropic 处理" |
| 权限时机 | 启动即弹一堆权限 = 高拒绝率 | 按功能分批请求（just-in-time），首启动只要日历 |

### 9.4 Prompt Injection 防护

分享进来的网页/文字是**不可信输入**。防护：

1. 写操作不在工具集中（§7.2）—— 这是最关键的一道
2. 分享内容在送入模型前包裹明确边界标记，并在系统提示中声明其中的指令不得执行
3. 提案的每一项都带 `rationale` 并经用户确认，异常项人眼可见

---

## 10. 分阶段实施计划

**前置：本机未安装 Xcode**（已检测：`xcodebuild` 不存在，仅有 Swift 6.4.2 toolchain）。需先装 Xcode 26.x + iOS 26 SDK，以及一台 Apple Intelligence 可用的真机（模拟器上 Foundation Models 行为与真机不一致）。

### Phase 0 · 地基（第 1 周）

- Xcode 项目骨架：App + ShareExtension + 共享 Framework 三 target
- SwiftData schema（§5 全部模型）+ 迁移策略
- Cloudflare Workers 代理骨架：App Attest 校验 + SSE 透传
- CI：`swift build` + Swift Testing，PR 门禁

**验收**：真机跑通一次「本地构造 messages → 经代理 → Claude 返回流式文本 → UI 渲染」的端到端打通，不含任何个人数据。

### Phase 1 · 单数据源闭环（第 2–4 周）

只接 **EventKit**。不做画像，不做端侧模型。

- 日历读取 + 空闲时段计算
- `search_calendar` / `search_places` / `get_travel_time` 三个工具
- Agent loop（设备侧）+ Sonnet 5 单日规划
- `ItineraryProposal` UI：卡片展示 + 逐项编辑 + 确认写回 + 一键撤销
- Prompt caching 接入，用 `cache_read_input_tokens` 验证命中

**验收**：说"周六下午帮我安排点事"，得到 3 项带理由的提案，确认后正确落入日历，可整体撤销。缓存命中率 >80%。

> 这是**第一个可用版本**，也是最重要的里程碑。在这里拿到真实使用反馈，再决定后续数据源的优先级。

### Phase 2 · 画像引擎（第 5–8 周）

- Foundation Models 接入：`SystemLanguageModel.availability` 门控 + `contextSize` 读取 + `tokenCount(for:)` 预算器
- 夜间 Digest 流水线（分批 + 失败降级，§6.1）
- 兴趣图谱 + 衰减 + 溯源 UI（标签可展开看证据、可否决）
- 画像卡生成器 + token 校验 + "我发出去了什么"查看页
- 接入 **位置**（visit/region monitoring）与 **照片元数据**
- Haiku 4.5 云端降级路径（不支持端侧的设备）

**验收**：连续 7 天真机使用后，画像卡内容被用户主观判定"大致准确"；每个标签都能追溯到来源；端侧 digest 在夜间充电时完成且耗电 <2%。

### Phase 3 · 深度规划与健康（第 9–12 周）

- Opus 4.8 多日规划路径 + 路由器（含成本归因看板）
- 多约束处理：天气、营业时间、连续强度平衡
- Share Extension 完整实现 + 不可信输入隔离
- App Intents / Siri / Shortcuts
- **HealthKit 接入**（排在最后：审核摩擦最大，且边际价值最低）

**验收**：多日复杂请求产出合理行程；路由器误判率 <10%（人工标注 100 条请求验证）；HealthKit 权限流程通过内部合规检查。

### Phase 4 · 上架准备（第 13–16 周）

- Privacy Manifest + 隐私标签完整填写
- 订阅（StoreKit 2）+ 配额策略落地
- 成本压测：模拟 1000 用户的月度账单
- 无障碍（VoiceOver / Dynamic Type）
- TestFlight 外部测试 ≥2 轮
- **评估 `PrivateCloudComputeLanguageModel`**：若 entitlement 获批，评估用它替代部分 Sonnet 调用（32K 窗口 + reasoning，隐私叙事更强、边际成本为零）
- 提审

---

## 11. 风险登记

| ID | 风险 | 影响 | 应对 |
|---|---|---|---|
| R1 | 端侧 4096 token 窗口比预期更紧，复杂抽取也放不下 | 高 | 已在 §6.1 设计分批（硬上限 2500/批）+ 失败减半重试 + 云端 Haiku 兜底。Phase 2 第一周先做 token 预算器压测，用真实信号量验证批次大小 |
| R2 | Apple Intelligence 设备门槛（iPhone 15 Pro+）砍掉大部分存量市场 | 高 | 端侧定位为**优化项**；Haiku 4.5 降级路径保证全设备可用。注意这条降级路径会推高单位成本——需纳入定价模型 |
| R3 | 端侧 guardrail 误报导致 digest 大面积失败 | 中 | 每次调用 do/catch + 降级；`skipped` 状态可重放；监控失败率，超阈值自动切云端 |
| R4 | HealthKit 审核被拒或反复问询 | 中 | **排到 Phase 3 最后**，前面功能不依赖它；健康数据仅参与端侧推断、不外传、不入 iCloud、无广告。若受阻可直接砍掉而不影响主链路 |
| R5 | 路由器误判把 Sonnet 任务送给 Opus，成本翻 1.65× | 中 | 记录 `modelUsed` 做成本归因；Phase 3 用 100 条人工标注请求验证误判率；设置每用户月度硬性配额上限 |
| R6 | 后台位置监测耗电引发用户卸载/差评 | 中 | 用 visit/region monitoring，不用持续定位；设置页展示本周定位耗电；提供"仅前台"模式 |
| R7 | 冷启动无数据 → 首次体验为空 | 中 | 首启动引导：导入日历（立即有空闲时段）+ 3 个兴趣的手选 onboarding，先让 Phase 1 能力可用，画像随使用积累 |
| R8 | Prompt caching 被静默破坏（前缀注入时间戳等） | 中 | CI 加一条断言：连续两次相同请求的 `cache_read_input_tokens` > 0；系统提示构造函数禁止传入时变参数（类型层面约束） |
| R9 | 分享内容的 prompt injection | 中 | 写操作不入工具集（最关键）+ 输入边界标记 + 逐项用户确认（§9.4） |
| R10 | SwiftData 复杂聚合性能不足 | 低 | 已用 `ProfileSnapshot` 物化聚合绕开；若仍不足，迁移到 GRDB 的成本局限在 Profile 层 |

---

## 12. 下一步

1. 安装 Xcode 26.x，准备 Apple Intelligence 可用真机
2. 执行 Phase 0，目标是一周内打通端到端链路（不含个人数据）
3. **Phase 1 结束后暂停，用真实使用反馈重新排序 Phase 2/3 的数据源优先级** —— 位置和照片元数据哪个对画像质量贡献更大，是一个应该用数据而非直觉回答的问题

---

## 附录 A · 关键事实来源

- Foundation Models 上下文窗口（4096 token，含全部开销；`contextSize` / `tokenCount(for:)` 于 iOS 26.4 引入并 back-deploy）：[FoundationModel context length 开发者论坛](https://developer.apple.com/forums/thread/806542)、[Tracking token usage in Foundation Models](https://artemnovichkov.com/blog/tracking-token-usage-in-foundation-models)、Apple TN3193
- `LanguageModelSession` / `@Generable` / `Tool` 协议语义与工具生命周期：[Deep dive into the Foundation Models framework (WWDC25 session 301)](https://developer.apple.com/videos/play/wwdc2025/301/)、[The Ultimate Guide To The Foundation Models Framework](https://azamsharp.com/2025/06/18/the-ultimate-guide-to-the-foundation-models-framework.html)
- 生产环境护栏误报：[Putting Apple Foundation Models in a real app](https://drobinin.com/consulting/foundation-models-apple-intelligence/putting-apple-foundation-models-in-a-real-app/)
- `PrivateCloudComputeLanguageModel`（32K 窗口 + reasoning，iOS 27）：[Foundation Models on Private Cloud Compute](https://blakecrosley.com/blog/foundation-models-private-cloud-compute) —— **二手来源，Phase 4 需对照 Apple 官方文档核实类型名与 entitlement 流程后再依赖**
- Claude API 模型 ID、定价、adaptive thinking、prompt caching 行为、工具使用约定：Anthropic 官方文档（经 claude-api skill 核实）
