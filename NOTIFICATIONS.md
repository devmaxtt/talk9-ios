# Talk9 iOS 通知系统 — 维护手册与排障方法论

> **给 AI 助手（Claude Sonnet/Opus/任何模型）**：动任何通知相关代码之前，通读本文档。
> 这里的每一条"已验证事实"都花费了大量调查成本，**直接采信，不要重新推导**；
> 每一条"红线"背后都是一个已经修复过的线上 bug，违反即回归。
> 本文档由 2026-07 的一次全面审计与修复会话沉淀（Claude Fable 5），
> 修复状态账本见 §4，方法论见 §6 —— §6 是"如何像那次会话一样思考"的操作指南。

---

## 1. 架构一图流（已验证，勿重查）

**没有 FCM/Firebase。** 推送链路：

```
对端设备 daemon --put--> OpenDHT proxy (dht.talk9.co)
                              |
                              v  (每个 DHT value 一条 alert push, mutable-content)
                            APNs
                              |
                              v
        NSE (Ring/jamiNotificationExtension/NotificationService.swift)
          1. Talk9PushQueue.enqueue(payload)   ← 先入队，无论后续如何
          2. Darwin 握手问主 app "活着吗"(0.3s) ← app 用 notify_register_dispatch 秒答
          3. app 活着 → 完全抑制，app 侧 drain 队列喂 daemon
          4. app 死了 → HTTP stream 拉 DHT 值 → 本地 OpenDHT 解密（不启动 daemon！）
          5. 解密结果分流: .call → CallKit / .gitMessage → 横幅
                          .conversationRequest → 邀请横幅 / .unknown → 抑制空卡
```

关键文件速查（相对仓库根）：

| 文件 | 角色 |
|---|---|
| `Ring/jamiNotificationExtension/NotificationService.swift` | NSE 主逻辑（抑制/去重/横幅/清理全在这） |
| `Ring/jamiNotificationExtension/Adapter.mm` | 无 daemon 解密（OpenDHT decrypt + TrustRequest 分类），`isMessageTreated` **只读** |
| `Ring/Ring/AppDelegate.swift` | push 注册、握手应答、drain、prewarm 防护、6 个重试 trigger、退避门 |
| `Ring/Ring/Constants/Constants.swift` | app group keys + `Talk9PushQueue`（三 target 共享） |
| `Ring/Ring/Services/ConversationsManager.swift` | 前后台账号活性、正文缓存写入（`talk9_last_msg_`） |
| `Ring/Ring/Services/ConversationsService.swift` | left/active 集合维护、`syncConversation` |
| `Ring/Ring/Services/NetworkService.swift` | NWPathMonitor（status + 接口签名双重判断） |
| `Ring/Ring/Services/CallsProviderService.swift` | CallKit、unhandeled call 15s 超时 |
| `Ring/jamiShareExtension/AdapterService.swift` | 第三个队列 drain 方（易被遗忘！） |

App Group（`group.m.talk.talk9.shared`）状态清单：

| 位置 | 用途 | 写入方 → 读取方 |
|---|---|---|
| `Library/Caches/talk9-push-queue/` | 待喂 daemon 的推送队列（每推送一文件） | NSE → 主 app + 分享扩展（删除即认领） |
| `Library/Caches/talk9-push-dedup/` | burst 窗口标记（mtime=时钟，内容=最新横幅 id） | NSE ↔ NSE |
| `Library/Caches/talk9-push-seen/` | value-id 已处理认领（O_EXCL 即认领） | NSE ↔ NSE |
| UserDefaults `talk9_left_conversations` | 退群黑名单（NSE 抑制幽灵推送） | 主 app → NSE |
| UserDefaults `talk9_last_msg_*` | 横幅正文缓存（2s 新鲜度窗口） | 主 app daemon → NSE |
| UserDefaults `talk9_pending_notification_removal` | NSE 委托主 app 删的卡片 id | NSE → 主 app |
| UserDefaults `notificationData` | 旧队列（仅兼容排空，**勿再写入**） | 无 → drain() 兼容读 |
| UserDefaults `talk9_active_conversations` | ⚠️ 死白名单：有写入方、**NSE 从不读**（历史遗留，见 D5） | — |

## 2. 已验证事实（直接采信）

每条都标注了"为什么重要"——弱化这些认知会直接产出错误设计。

1. **一条语音消息 ≈ 4 条 alert，value_id 互不相同**（服务器侧实测）。
   → 纯 value-id 去重会退化成 4 条横幅；必须双层：value-id 认领 + (convId,peerId) 12s 窗口。
2. **`isMessageTreated`（Adapter.mm）只读**，treated 文件只有主 app daemon 写。
   → NSE 没有"已展示"持久记录这件事由 `talk9-push-seen/` 目录承担，别指望 treated 文件。
3. **`CFNotificationCenterGetDarwinNotifyCenter` 的观察者回调只在主 run loop 转动时投递**。
   → 任何延迟敏感的 darwin 监听（如 NSE 握手应答）必须用 `notify_register_dispatch` + 专用队列。
4. **NSE 绝不能启动 daemon**（`libjami::start` 在扩展进程触发 SSL/TURN → EXC_BAD_ACCESS
   → iOS 回落显示原始 APNs 占位横幅）。NSE 内大量 daemon 生命周期代码是死代码残骸。
5. **`Constants.swift` 通篇无 import**，靠各 target 的 bridging header 隐式导入 Foundation；
   它编译进 Ring / jamiNotificationExtension / jamiShareExtension 三个 target
   → 跨进程共享的助手代码放这里，零 pbxproj 手术。
6. **本环境的 SourceKit/clangd 诊断不可信**（对刚编译通过的文件报 "No such module UIKit/RxSwift"）。
   **唯一裁决 = xcodebuild**。且 `xcodebuild -target` 不构建 SPM 依赖会假失败，**必须用 `-scheme`**：
   ```bash
   xcodebuild -project Ring/Ring.xcodeproj -scheme <Ring|jamiNotificationExtension|jamiShareExtension> \
     -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
   ```
7. **`PKPushRegistry.didUpdate` 空实现是刻意的**：VoIP push 只来自 NSE 本地
   `reportNewIncomingVoIPPushPayload`，VoIP token 绝不上传（补全它会触发 iOS 13+ 的
   "VoIP push 必须报 CallKit 否则杀 app"政策风险）。
8. **`UIApplication.applicationState` 是 main-thread-only**；跨线程需要时用
   AppDelegate 的 `appIsInBackgroundForHandshake` 队列限定镜像模式。
   CXCallObserver / libjami adapter 调用实践上可跨线程。
9. **UserDefaults 跨进程读改写必丢数据**（app 读 `[A]` → NSE 写 `[A,B]` → app 写回 `[]`）。
   跨进程共享可变状态的唯一正确姿势 = App Group 文件 + `open(O_CREAT|O_EXCL)`（原子认领）
   或"唯一文件名 + 删除即认领"。仓库里已有三处成熟范本（§1 表格前三行）。
10. **推送队列有三个消费方**：主 app 两处 + **分享扩展** `handleAccountQuery`。
    改队列语义时三处都要看，漏掉分享扩展是历史事故点。
11. TrustRequest（会话邀请）解密后 `conversationRequest.conversationId` 可得、
    发送者从 `decrypted->owner` 的证书链解析（陌生人回退 device id）。
    邀请**刻意绕过** left 黑名单（退群重邀必须可见）。
12. iOS 15+ prewarm 会执行 `didFinishLaunching` 但永不激活 scene；
    **VoIP 冷启动同样落在 `.background`**（锁屏接听永不前台化 app）——
    任何"后台启动就去激活账号"的逻辑必须先排除通话在途。
13. 服务器因 OpenDHT push payload 的 `pt` 字段恒空而**无法区分**消息与输入状态/回执
    → 非消息事件的空卡抑制机制是结构性的，根治只能靠 filtering entitlement（见
    `Ring/jamiNotificationExtension/FILTERING_ENTITLEMENT.md`）或服务端 silent 降级。
14. 判断 resubscribe 保活推送靠 `data["timeout"] != nil && != "<null>"` 的字符串巧合（D3，脆弱）。
15. **`talk9_last_msg_*` 正文缓存只有一个写入方**：主 app 的 `ConversationsManager`
    （NSE 与分享扩展都只读）。又因为 NSE 只有在**主 app 进程已死**时才会走到读缓存那一步
    （app 活着会在 `processNotificationRequest` 的 `appIsActive()` 分支提前 return），
    **在 NSE 里等待该缓存被更新永远等不到**；何况新鲜度阈值 `extensionStartTime - 2.0`
    本身只接受扩展启动**之前**写入的条目，等待在语义上就是自相矛盾的。
    → 2026-09 据此删除 `handleGitMessage` 的固定 2s 等待（见 §4 B1）。

## 3. 红线（违反即回归已修复的线上 bug）

1. **alert push 永不附带 `content-available=1`**（后台 app daemon 会先消费 DHT 值 →
   NSE 解密 unknown → 真实消息横幅永久丢失，客户端无防御）。写进服务端契约。
2. **所有 NSE 抑制路径必须走 `deliverSuppressed()`** 单一出口（R5 entitlement 切换点）。
3. `filteringEntitlementGranted` **在 Apple 批准前保持 false**；entitlement key 获批前
   **不进** `.entitlements`（签名失败）。顺序错误的后果见 FILTERING_ENTITLEMENT.md。
4. `finish()` 的 `didPresentLocalNotification` 分支必须抑制远程副本（否则一条消息两张横幅，D1）。
5. prewarm 防护的 `setAccountsActive(false)` 必须保留
   `!presentingCallScreen && !hasActiveCalls()` 条件（否则锁屏冷启动来电 15s 静默挂断，R1）。
6. burst 窗口语义 = **替换**（删前任横幅+静音投递），不是抑制（抑制会吞掉窗口内的第二条真实消息）；
   value-id 认领在所有过滤器**之前**执行（R3）。
7. `seedLeftConversationsSuppressionSet` 必须排除并 subtract daemon 的 active 会话
   （否则重邀接受后被重新拉黑，R4）。
8. 推送队列 = 每推送一文件；**永不**退回共享 UserDefaults 数组（R2）。
9. 握手应答**留在 `handshakeQueue`**，任何一跳都不许回主线程（R11）。
10. NetworkService 必须同时比较 status **和接口签名**（只比 status 会吞掉 WiFi↔蜂窝切换，R6）。
11. 所有重试必须经过 `reRegisterAccountForSyncRetry` 的退避门；别新增绕过它的直接
    `enableAccount(false/true)` 循环（R8）。
12. **失败策略统一为 fail-open：宁可重复横幅，绝不丢消息**（目录不可用→放行；
    peerId 解析不出→放行）。任何"拿不准就抑制"的改动都要三思。

## 4. 修复状态账本（2026-07-05）

已修复并提交（分支 `feature/upstream-call-video-fixes`）：

| 提交 | 项 | 一句话 |
|---|---|---|
| `3aa43293` | R1 | prewarm 防护加通话在途检查（曾是发版阻断回归） |
| `84633183` | R2 | Talk9PushQueue 文件化队列（读取侧 + 兼容排空） |
| `db882854` | R3+R4+D1+R5准备 | value-id 认领、burst 替换、邀请横幅、黑名单治愈、双横幅雷、deliverSuppressed 收敛 |
| `91d5b480` | R6 | WiFi↔蜂窝切换触发重连（2s 尾部去抖） |
| `a21cb1a5` | R11 | 握手应答出主线程（notify_register_dispatch） |
| `64fe15e6` | R9+分组 | threadIdentifier=talk9.real.<convId>、名字解析 8s 限时 |
| `4bb08442` | R8 | 重注册指数退避门 30s→300s |
| _(未提交)_ | B1 | 删除 `handleGitMessage` 的固定 2s 缓存等待（论证见 §2.15），横幅提前 2s |

客户问题映射：**#2 退群重邀无通知 → R4**；**#3 语音通知时有时无 → R3**（均待真机确认）。

仍开放：

- **R5**（立项级）：filtering entitlement 申请是外部步骤，材料齐备于
  `Ring/jamiNotificationExtension/FILTERING_ENTITLEMENT.md`；获批后两步切换 + 删除清理机器五件套。
- **R7**（服务端）：① `apns-collapse-id` = convId（同会话横幅替换不堆叠）；
  ② 来电推送 `apns-expiration` 30-45s（防幽灵响铃）；③ 非消息值 silent 降级（配合 R5 二选一）。
- **R10**（架构）：接收链路零 ack、git DAG 无 gap 检测——`performThrottledActiveSync`
  是现行补偿，别删。
- ~~**D2**~~：**✅ 已修（2026-09-14）**，见 §4ter。
- **D3**：`isResubscribe` 字符串巧合判定（换显式类型字段需双端同步）。
- **D4**：AppDelegate 5 处 block 观察者 token 丢弃。
  ⚠️ **2026-09-14 修正原判断**：原文写「`subscribeConversationSyncRetry` 二次调用会双倍触发」，
  但该函数**只有一处真实调用**（`AppDelegate:191`，在 `didFinishLaunching` 内，每进程一次）；
  另一处 grep 命中在 `:821` 只是注释里提到函数名。**当前不会双倍触发**，
  降级为防御性清理（谁将来加第二处调用谁中招）。
- **D5**：`talk9_active_conversations` 死白名单（写入方+注释声称 NSE 在读，实际零读取）。
- 小项：`bestAttemptContent` 三线程写无同步。
  （原列在此处的「`handleGitMessage` 固定 2s 等待（刻意保留）」已于 2026-09-04 删除 —— 见 B1）

## 4bis. 2026-09-04 复审：新增发现（B1 已修，其余待决）

一次只读复审，逐条核对 §4 开放项并全仓库 grep 验证。**结论：§4 所有开放项均仍然存在**，
另发现以下 5 项（按是否影响用户排序）。未做的几项都已写明论证与取舍，将来要动直接接续。

| 项 | 位置 | 状态 | 判断 |
|---|---|---|---|
| **B1** | `NotificationService.handleGitMessage` | ✅ 已修 | 固定 2s 等待是保证空转，论证见 §2.15。收益：横幅提前 2s，burst 时 4 个进程各省 2s 预算与内存占用 |
| **B2** | `finish()` SHOW 分支的 `removeOldSuppressedNotifications()` | ❌ 建议不做 | 在投递真实横幅**之前**同步清扫（典型 50–350ms，最坏 1.8s）。挪到 `contentHandler` 之后可提速，但会削弱「每条真实消息顺手扫一次空卡」这条兜底路径 —— 几百毫秒不值得换 |
| **A1** | `scheduleRemoval()` | ⚠️ 可做，用户零收益 | **违反红线 9**：跨进程 UserDefaults 读-改-写，并行 NSE 会互相覆盖。但 `AppDelegate.removePendingNotifications()` 里的全量 sweep 与 per-id 删除**在同一函数内相隔 5 行**，且所有抑制卡的 `threadIdentifier` 恒为 `talk9.suppressed` ⟹ per-id 列表是全量 sweep 的严格子集，丢 id **不产生任何用户可见后果**。删掉它的价值是不给后人留红线违规范本，兼提前完成 FILTERING_ENTITLEMENT.md 第 7 步清理 |
| **C1** | `Constants.talk9ActiveConversationsKey` + `ConversationsService` 三函数 + 5 处调用点 | ⚠️ 建议做 | D5 实锤：写入方 5 处（`AppDelegate:479`、`ConversationsService:442/508/584`、`RequestsService:252`），**NSE 零读取**。危害不在浪费，而在 `Constants.swift` 与 `ConversationsService` 的注释仍宣称「NSE 用它做白名单」（还标了 CRITICAL），与 `processMap` 里那段「为何废除白名单改用纯黑名单」的注释**直接矛盾** —— 排查「消息没横幅」的人会被引向一个不存在的机制 |
| **C2** | `skipDaemonSync`、`didStartDaemon`、`jamiTaskId`/`verifyTasksStatus` | ⚠️ 建议做 | §2.4 所述 daemon 残骸的具体实例：`skipDaemonSync` 声明后从未读写；`didStartDaemon` 恒 false ⟹ `finish()` 的 `else if didStartDaemon` 是**永不可达分支**；`jamiTaskId` **从未 enter** ⟹ `verifyTasksStatus()` 唯一的动作是 leave 一个不存在的 id（`AutoDispatchGroup.leave` 对未 enter 的 id 是 no-op），连带 `waitForCloning`/`syncCompleted`/`itemsToPresent` 整套也是死的 |

**关于空卡堆积的根因（复审修正）**：A1 的 id 丢失**不是**空卡堆积的原因（全量 sweep 兜住了）。
真实链条是 —— NSE 三件清理全是尽力而为（`aggressiveImmediateRemoval` 在 `contentHandler` 之后
才跑、`scheduleAutoRemove` 随进程死、异步删除无完成回调），全部输给进程回收后，
**唯一可靠的全量 sweep 只在 `sceneDidBecomeActive` 触发** ⟹ 用户不打开 app 的期间空卡必然累积。
这是结构性的，再加第六件清理机器也堵不住，**只有 R5 能根治**。

**R5 状态**：代码侧 100% 就绪（`deliverSuppressed` 单一出口 + `filteringEntitlementGranted = false`），
FILTERING_ENTITLEMENT.md 连英文 justification 都备好。唯一卡点是**有没有人去 Apple 提交那张表**。
在所有待办里杠杆最大，且不是写代码能推进的。

**新加分项（未立项）**：Communication Notifications（iOS 15+ `INSendMessageIntent`
+ `UNNotificationContent.updating(from:)`）目前完全没用 —— 接上后横幅可显示发送者头像、
系统按人分组、支持「专注模式」人物白名单。属产品级提升，非修 bug。

## 4ter. 2026-09-14：D2 已修

**完整失败链**（每步都有代码行号支撑，§6④ 格式）：

```
切换账号
 → currentAccountChanged (AppDelegate:387)
 → reloadDataFor (:399) → prepareConversationsForAccount
 → getConversationsForAccount → addSwarm (ConversationsService:183)
 → ConversationModel(withId:) 建立【全新实例】
 → conversations.accept(新模型)
 → AppDelegate Trigger1 收到
 → syncWatchedIds.insert(conv.id).inserted == false  ← 旧 id 仍在 set 内
 → continue
 → 【新模型的 Trigger1a / 1b 都没建立】
 → 会话卡 synchronizing 时，30s 自动 re-register 永不触发
 → 用户看到「Syncing conversation history…」不再自愈，只能手动 Reset Conversation
```

附带：旧账号 N 个会话的 `synchronizing` 订阅全挂在 app 级 `disposeBag` 上，每切一次账号累积一批。

**修法**（`AppDelegate.swift`，手术刀最小集）：

1. 新增 `syncWatchDisposeBag`，Trigger1b 的订阅改挂它（不再进永不释放的 app 级 bag）
2. `reloadDataFor` 开头清空 `syncWatchedIds` + 重建该 bag —— 模型重建了，watch 也必须重建
3. Trigger1 加 `.observe(on: MainScheduler.instance)`

第 3 点是顺带修的既有隐患，**不属于 D2 本身**：`syncWatchedIds` 原本就跨线程访问
（`reloadDataFor` 跑在 background queue，Trigger1 回调跟着 `conversations.accept` 的线程），
Swift 的 `Set` 并发读写是未定义行为。加清空操作会提高撞上的概率，故一并收进 main。
若要更保守，这一行可单独回退。

**为何不是症状层补丁**（§6⑤）：根因是「模型换代了但 watch 没换代」，
修在换代点（`reloadDataFor`）上，将来任何新的重载路径只要经过它就自动被覆盖。

**待真机验证**：
- 多账号：A ↔ B 切换后，A 的卡住会话仍能在 30s 后自动 re-register（看 `[Talk9-ICE][Retry] Trigger1b`）
- 单账号冷启动：Trigger1a/1b 日志照常出现，无重复触发
- 切换账号数次后无记忆体增长

## 5. 真机回归五链路（改通知代码后必跑）

1. **锁屏冷启动接听**：杀 app → 锁屏来电 → 直接接听 → 通话建立（R1；修复前 15s 静默挂断）。
2. **语音 burst**：杀 app → 收一条语音 → 恰好一张横幅一声提示音；
   再试"文本+5s 内语音" → 横幅始终存在且刷新（R3）。
3. **退群重邀全链路**：退群 → 杀 app → 对方重邀 → 出横幅 → 接受 → 后台再前台一次 →
   群消息通知恢复（R4，含黑名单治愈验证）。
4. **网络切换**：WiFi 聊天中关 WiFi 留 LTE → 消息数秒内恢复；
   控制台一次 `Network interface changed` + 一次 connectivityChanged（R6）。
5. **前台压力**：重度滚动会话列表时对端连发消息 → 零系统横幅，仅 app 内更新（R11）。

日志过滤 token：`[Talk9-Push]`（NSE 决策流）、`[Talk9-Notif]`（NSE 细节）、
`[Talk9-Decrypt]`（解密）、`[Talk9-ICE][Retry]`（重试机器）、`[Talk9-Diag]`（生命周期）。

## 6. 排障方法论 —— 如何在这个子系统里正确地思考

这一节是给未来模型的推理纪律。那次审计之所以有效，靠的不是模型多聪明，而是严格执行以下步骤。

**① 先验证前提，再设计方案。**
最典型教训：审计初版结论"用 value-id 替代时间窗"，落地前核对服务器观察记录才发现
burst 是**不同** value id——原方案会直接退化成 4 横幅。规则：设计依赖的每个事实
（"X 是同一个 id"、"Y 只有一个消费方"、"Z 在主线程"）都要用 grep/read 找到代码证据
或明确标注"未验证假设"。本文档 §2 就是已付费的前提库。

**② 读代码本体，别信注释和记忆。**
本仓库有整段注释描述已不存在的机制（D5 死白名单最典型）。记忆/文档里的文件路径、
函数名，使用前 `rg` 确认仍存在。

**③ 改共享状态前，先画进程×线程矩阵。**
问三个问题：这个状态有哪几个**进程**读写？（主 app / N 个并行 NSE 实例 / 分享扩展）
每一方在哪个**线程/队列**？共享写入是否原子？——UserDefaults RMW 跨进程必丢；
文件 + O_EXCL 是本仓库的标准答案。找齐所有读写方的方法：对 key/目录名全仓库 `rg`，
**包括 `Ring/jamiShareExtension/`**（历史上最容易漏的角落）。

**④ 动手前写出完整失败链。**
格式："场景 X → 步骤1 → 步骤2 → … → 用户看到 Y"。写不出完整链条说明还没理解问题。
例（R1）：杀 app → 来电 push → NSE 拉起 → previewPendingCall 激活打在未启动的 daemon 上（空操作）
→ 4-9s 后 daemon 启动完成 → 防护见 .background → 去激活 → 账号不注册 → 对端 ICE 落空
→ 15s 超时挂断。链条里每个箭头都应有代码行号支撑。

**⑤ 修复取"手术刀最小集"，但要修在根因层。**
症状层补丁（再加一套清理定时器）会累积成现在 NSE 里的清理机器群；根因层修复
（entitlement / 文件队列 / 退避门）一次终结一类问题。判断标准：修复后，
同类新场景是否自动被覆盖？

**⑥ 每次改动的验证阶梯。**
a. 受影响 target 全部 `xcodebuild -scheme` 构建（共享文件=三个都要）；
b. 无法真机时，明确写出"待真机验证清单"（§5 模板）并存入记忆/提交信息；
c. 提交按关注点拆分——同文件多关注点时用
   `git diff > x.patch` 手工切 hunk + `git apply --cached` 分块暂存（AppDelegate 曾这样拆 R1/R2）；
   hunk 物理交错时不硬拆，提交信息逐条列明。提交前缀沿用：`nse:` `push:` `calls:` `sync:` `network:` `notifications:`。

**⑦ 症状 → 首查位置速查表。**

| 症状 | 先查 |
|---|---|
| 空卡/垃圾横幅 | `deliverSuppressed` 各分支的触发原因日志；`pt` 分类问题→R5/R7 |
| 同一消息重复横幅 | `talk9-push-seen/` 认领是否命中；服务端是否重发不同 value id（→需 collapse-id） |
| 该来的横幅没来 | 按序排查五道闸：appIsActive 握手误判 → isResubscribe 误判 → 陌生人过滤 → left 黑名单 → burst 替换逻辑；再查 Talk9PushQueue 是否滞留 |
| 消息延迟/丢失（app 内） | NetworkService 是否发出重连 → 退避门是否卡住(`[Talk9-ICE][Retry]`) → performThrottledActiveSync 是否执行 |
| 来电问题 | prewarm 防护条件 → unhandeled call 15s 超时 → NSE `.call` 认领/过滤 |
| 横幅内容错（占位/错名） | `talk9_last_msg_` 缓存命中与 2s 新鲜度 → vCard/nameserver 8s 解析 |

**⑧ 不确定时的默认取向。**
展示 vs 抑制 → 展示（fail-open）；立即修 vs 先报告 → 用户只描述问题时先给评估，
明确要求才动手；大重构 vs 手术刀 → 手术刀，把大重构列为建议。

---

*维护：修复/回归任何 §4 条目后更新该表；新增红线时同步 §3。
配套文档：`Ring/jamiNotificationExtension/FILTERING_ENTITLEMENT.md`（R5 rollout）、
`CLAUDE.md`（构建与仓库总览）。*
