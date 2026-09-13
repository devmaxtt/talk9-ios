# Talk9 iOS ↔ Android 功能对齐账本

> **给 AI 助手 / 后续维护者**：本文档是一次逐项源码比对的沉淀（2026-09-13），
> 记录 **Android 有、iOS 没有** 的功能。每一条的「Android 位置」与「iOS 现况」
> 都是实际 grep 过两边全树得出的结论，**直接采信，不要重新推导**。
>
> ⚠️ **不要用 Android 仓库的 `IOS_SYNC.md` 当待办清单** —— 那份文件停在 Android 1.0.17，
> 其中 12 项 iOS 早已实作完成（见 §5）。照它排期会做重工。

---

## 0-A. 实作进度（2026-09-13）

| 项目 | 状态 | 落点 |
|---|---|---|
| §2.1 广播上限 50 → 200 | ✅ 已实作 | `Broadcast/BroadcastViewModel.swift:17` |
| §2.2–2.4 时间戳三个缺陷 | ✅ 已实作 + 验证 | `Extensions/Date+Helpers.swift` |
| §1.1 版本检查 / 强制更新 | ✅ 已实作 + 验证 | `Helpers/AppUpdateChecker.swift`（新）、`AppCoordinator.swift` |
| §1.10 QR 扫 Talk9 深链 | ✅ 已实作 + 验证 | `QRCode/ScanViewController.swift` |
| **深链跨平台互通（新发现）** | ✅ 已修复 + 验证 | `Helpers/JamiURI.swift` — 见 §1.10-A |
| §1.7 开发者模式 + 设定锁定 | ✅ 已实作 + 验证 | `Helpers/DevMode.swift`（新）、`AboutSwiftUIView.swift`、`AccountSettingsViews.swift` |
| §1.4 未读分隔线 | ✅ 已实作（**待真机验证**） | `MessagesListVM.swift`、`MessagesListView.swift` |
| §1.3 群组成员系统讯息 | ⚠️ iOS 已有，剩文案决策 | 见 §1.3 更正 |
| §1.2 被移出群组 + self-ban | ✅ 已实作 + 验证（**待真机验证**） | `ConversationModel.swift`、`ConversationViewModel.swift`、`MessagesListVM/View.swift` |
| §1.5 语音列表预览带时长 | ✅ 已实作（**待真机验证**） | `MessagesListVM.swift` |
| §1.6 语音通知带时长 | ⛔ **架构性阻断，已停止尝试** | 论证见 §1.6 |
| **D2 通知子系统**（非 Android 对齐） | ✅ 已修 + 编译验证 | `AppDelegate.swift`、`NOTIFICATIONS.md` §4ter |
| §1.8 OTPq 整合 | ⬜ 待产品决策 | — |
| §1.9 国码动态拉取 | ⬜ 待产品决策 | — |

> **两个新增档案已加入 Xcode target**（`project.pbxproj`，group `Helpers`，target `Ring`）。
>
> **编译状态（2026-09-14）**：`xcodebuild -sdk iphoneos -scheme Ring` → **BUILD SUCCEEDED**。
> 13 个改动档案全部参与编译、零 error；唯一警告落在既有的 `debugLastMessageStatus`
> （`MessageStatus` 的 switch），与本次改动无关。
>
> 逻辑层（版本比对、DevMode 连点、深链解析、时间戳、分隔线落点、self-ban 判断）
> 另有 70 项独立 `swiftc` 测试验证。
>
> ⚠️ **仍未验证的是 UI 与非同步时序** —— 编译通过不代表行为正确。合并前请实机确认：
> 1. 被移出群组时横幅是否即时出现，以及**正常群组是否被误锁输入框**（最严重的失败模式）
> 2. 未读分隔线在翻转坐标系中的位置，以及滚动载入更多历史时是否乱跳
> 3. 强制更新弹窗是否真的无法绕过
>
> 模拟器构建目前不可用（daemon 的 simulator slice 是空壳），原因与解法见 `CLAUDE.md`
> 的「模拟器构建」一节。

---

## 0. 比对基线与方法

| 项目 | 值 |
|---|---|
| Android 版本 | 1.0.29（versionCode 29） |
| `IOS_SYNC.md` 记录到 | 1.0.17 —— 落后 12 个版本 |
| 比对日期 | 2026-09-13 |
| iOS 比对范围 | `Ring/Ring/`、`Ring/jamiNotificationExtension/`、`Ring/jamiShareExtension/`、`Ring/CommonObjc/` |

**方法**：以 `IOS_SYNC.md` 加上 Android 1.0.17→1.0.29 的提交记录取得功能清单，
再逐项在 iOS 全树 grep 关键字与实作确认，而非只读文件。

> 注：1.0.18 之后的 Android 提交，message 多数只写 "Update"，
> 功能要从 `git show --stat` 与实际 diff 里挖。下次同步时请沿用这个方法。

---

## 1. iOS 完全没有（10 项）

以下关键字在 iOS 全树 **零命中**，属真正的功能缺口。

### 1.1 App 版本检查 / 强制更新 ⭐ 建议优先

| | |
|---|---|
| Android | `jami-android/app/src/main/java/cx/ring/utils/AppUpdateChecker.kt`，由 `HomeActivity.kt:233` 启动时调用 |
| iOS | 无。`app_list` / `min_version` / `latest_version` 零命中 |

**逻辑**：`GET https://app.talk9.co/api/app_list`（免鉴权，10 秒超时），取 `ios` key：

> ⚠️ host 是 **app.talk9.co**，不是 `talk9.co`。Android `AppConfig.kt:10-17` 的
> `BASE_URL` = `https://app.talk9.co`，端点由它拼出。
> Android 仓库 `IOS_SYNC.md` 写的 `https://talk9.co/api` 是错的 ——
> iOS `Talk9APIService.baseURL` 已经是 `https://app.talk9.co/`，与 Android 一致，沿用即可。

```json
{ "ios": { "min_version": "1.0.1", "latest_version": "1.0.1", "store_url": "https://apps.apple.com/app/id..." } }
```

| 条件 | 行为 |
|---|---|
| current < `min_version` | 强制更新弹窗，**不可关闭**，无「稍后」按钮 |
| `min_version` ≤ current < `latest_version` | 软更新弹窗，有「稍后」可关闭 |
| current ≥ `latest_version` | 不弹 |

**红线**：版本比对必须 **逐段转 Int** 比较，不可用字串比较，否则 `1.0.9` 会被判成大于 `1.0.10`。
current 版本读 `CFBundleShortVersionString`。请求失败静默略过，不可给使用者看错误。

> 后端已经就绪（JSON 里已有 `ios` key），只差客户端接。

### 1.2 被移出群组横幅 + self-ban 侦测 ⭐ 建议优先

| | |
|---|---|
| Android | `ConversationFragment.kt:1189 switchToRemovedFromGroupView()`、`ConversationPresenter.kt:217`、`Conversation.selfBanned`（@Volatile） |
| iOS | 无。被踢出群后 UI 无对应处理 |

被管理员移出群组后，会话顶部显示「You were removed from this group」横幅并 **停用输入框**。
目前 iOS 使用者被踢出后仍能在一个已失效的会话里打字。

**Android 踩过的坑（iOS 实作时会遇到同样问题）**：

1. **Race condition**：`initContact()` 与 self-ban 订阅都 post 到 UI thread，initContact 后跑会覆盖掉被移除画面。
   Android 的解法是加 `@Volatile selfBanned` 供同步读取，并在 `initContact` 里先检查再决定切哪个 view。
2. **启动时侦测**：不能只在 `conversationReady` 判断。App 冷启动载入既有会话时，
   若 `getConversationMembers` 的结果 **不含自己**，即代表已被 ban，要在载入时就判定。
3. 订阅用 `.skipWhile { !it }` 而非 `.skip(1)`，否则已被 ban 的成员重启 App 后收不到状态。

**iOS 实作（2026-09-13）**

| 层 | 改动 |
|---|---|
| `ConversationModel.isSelfRemovedFromGroup()` | 判断：`isSwarm() && type != .oneToOne`，取 `isLocal` 的成员，role 为 `banned`/`left`，或自己已不在名单 → true |
| `ConversationViewModel.updateBlockedStatus()` | 并入既有的 `isBlocked`（它本来就隐藏输入框），另送 `isRemovedFromGroup` 供横幅使用 |
| `ConversationViewModel.subscribeMemberChanges()` | 订阅 `conversationMemberEvent`，被移出的当下即时更新 |
| `MessagesListView.removedFromGroupBanner()` | 以横幅取代输入框，而非让它默默消失 |

> **iOS 的时序反而比 Android 干净**：`ConversationsService.conversationMemberEvent`
> 先 `addParticipantsFromArray` 更新名单、**再**发事件，所以订阅端读到的必是最新名单，
> 不存在 Android 那种两个订阅竞争 UI 的 race，无须 `@Volatile` 等价物。
>
> **防误判是这段的重点**：名单为空（尚未载入）必须回 `false`，否则每个群组一开启
> 就会锁住输入框。12 项逻辑测试涵盖此点，以及 1:1／SIP／JAMS／非 swarm。
>
> 订阅用独立的 `memberEventDisposeBag`，每次指派 conversation 时重置 ——
> `ConversationViewModel` 会被 `createOrRetrieveViewModel` 重用，共用主 bag 会累积重复订阅。

### 1.3 群组成员变更系统讯息 ⚠️ 修正：iOS 已有，差异比原先记录的小

> **2026-09-13 更正**：本节初版写成「iOS 无此类系统讯息」，**是错的**。
> iOS 有完整的成员事件渲染链路，缺的只是两个细节。

| | |
|---|---|
| Android | `ConversationAdapter.kt:1523 configureForContactEvent()` |
| iOS | **已有** —— `MessageType.contact(ContactAction)`（`MessageModel.swift:46`），<br>`ContactAction` 含 `add`/`remove`/`join`/`banned`/`unban`（:105），<br>由 `ContactMessageVM.swift:47` 渲染 |

实际剩余差异只有两点：

| # | 差异 | Android | iOS |
|---|---|---|---|
| a | **措辞** | removed / added（群组语境下更准确） | blocked / unblocked（`L10n.GeneratedMessage.contactBlocked`） |
| b | **操作者名字** | 「[管理员] 移除了 [成员]」，`combineLatest` 解析双方名字 | 只显示被操作者一人：「[成员] 已被封锁」 |

补 (b) 是可行的：`MessageModel` 已同时带 `uri`（被操作的成员）与 `authorId`（操作者），
`ContactMessageVM.swift:45` 目前只取其一。需改 `ContactAction.getInteractionString`
的签名接受两个名字，并新增对应字串。

> **(a) 是文案决策，不是纯技术缺口**：iOS 现有的 blocked/unblocked 在 1:1 语境下是正确的，
> Android 改成 removed/added 是为了群组语境。两者都要照顾的话，措辞需依 conversation
> 是否为 swarm 分流。另外 iOS 也有多语系字串要一并更新，动之前请先确认产品意见。

### 1.4 会话内「未读讯息」分隔线

| | |
|---|---|
| Android | `MessageType.kt:39 UNREAD_DIVIDER`、`ConversationAdapter.kt:1246`、`layout/item_conv_unread_divider.xml` |
| iOS | 无。`MessagesListView.swift` 里的 Divider 是其他用途 |

开启有未读的会话时，在第一则未读讯息上方插入一条「N 则未读讯息」分隔线
（两条水平线夹中央标签）。纯视觉、**不持久化**，每次开启会话重算，
使用者读过后分隔线移动或消失。

### 1.5 会话列表语音讯息预览带时长

| | |
|---|---|
| Android | `SmartListViewHolder.kt:291`（麦克风 drawable 内联于文字） |
| iOS | 无。SmartList 无语音讯息特化预览 |

- 收到：`🎤 Voice message (0:30)`
- 自己发：`You: 🎤 Voice message (0:30)`

时长从档案实际读取；**未下载完成则省略时长**，下载完成后自动刷新该行。

### 1.6 语音讯息通知带时长

| | |
|---|---|
| Android | `NotificationServiceImpl.kt:972` `getVoiceMessageDuration()` |
| iOS | NSE 无 duration 处理 |

通知标题为寄件者名，内容为 `🎤 + 时长`（比照 WhatsApp）。群组则为 `寄件者名: 🎤 …`。

### ⛔ 2026-09-14 结论：此项在现行 iOS 架构下**做不到**，已停止尝试

不是「还没做」，是**架构性阻断**。三个已验证的事实各自独立地封死了这条路：

| # | 事实 | 代码证据 |
|---|---|---|
| 1 | **NSE 绝不能启动 daemon**（红线，启动会 EXC_BAD_ACCESS 并回落成原始 APNs 占位横幅） | `NOTIFICATIONS.md` §2.4 |
| 2 | 因此 NSE 跑的时候，**语音档案根本没下载到本地** —— 没有档案就没有时长可读 | 同上推论 |
| 3 | NSE 的 body 只有两个来源：主 app 预写的 `talk9_last_msg_` **文字**缓存，或 fallback `"New message"`。没有任何栏位能携带时长 | `NotificationService.swift:715-755` |

**那能不能让主 app 写缓存时就带上时长？** 也不行：

```
ConversationsManager.newInteraction()
  → newMessage.transferStatus = .awaiting        ← 还没下载
  → notificationBody = "Voice message"
  → cacheMessageForNotification(body:)           ← 此刻写缓存
  → dataTransferService.downloadFile(...)        ← 下载在【最后】才开始
```

写缓存的时间点，档案必然还不存在（`ConversationsManager.swift:652-695`）。

**Android 为什么可以**：它的通知由 `NotificationServiceImpl` 在**档案已落地后**发出，
`getVoiceMessageDuration(audioFile)` 读的是本地既有档案。iOS 的 NSE 模型没有这个时间点。

**若将来仍要做，只有三条路**（都不是「对齐 Android」能涵盖的）：

1. 服务端在 push payload 带上时长栏位 —— 最干净，但需后端配合
2. R5 filtering entitlement 落地后重新评估整个 NSE 模型
3. 主 app 在背景时，于传输完成事件里用同一 identifier 覆盖已发出的通知 ——
   属于新增机制而非对齐，且只覆盖 app 未被杀死的场景

按 `NOTIFICATIONS.md` §6⑤（修在根因层）与 §6⑧（大重构列为建议），这三条都应立项讨论，
不该用症状层补丁硬凑。

> 附带说明：会话列表的语音时长（§1.5）**不受此限制**，因为那是在 app 内渲染、
> 档案通常已下载完成，且可非同步补上 —— 已于 2026-09-14 实作。

### 1.7 开发者模式 + 进阶设定锁定

| | |
|---|---|
| Android | `utils/DevModeUtils.kt`（SharedPreferences `talk9_prefs` / key `dev_mode`）、锁定逻辑 `AdvancedAccountFragment.kt:137` |
| iOS | 无此概念，进阶设定恒可编辑 |

- 关于页 **连点版本号 7 次** 开启，过程中提示「You are N steps away from developer mode」
- 未开启时 **所有进阶帐号设定为唯读**
- 「重置进阶设定」按钮已移除

### 1.8 OTPq App 整合 + OTP 状态保存 ⚠️ 需先确认产品决策

| | |
|---|---|
| Android | `account/OtpqGuideBottomSheet.kt`、状态保存 `talk9_otp_state`、重导向 `HomeActivity.kt:393` |
| iOS | 无 |

OTP 页提供「用 OTPq 接收验证码」引导浮层（5 步骤 + 商店下载连结）。
使用者切到 OTPq App 再回来时，OTP 画面状态被保存并自动跳回。

> **决策前提**：Android 的 `AppConfig.kt:19-23` 注释明写
> 「OTPq app download links … **The iOS link deliberately has no home here**」——
> 商店连结是 **刻意** 不给 iOS 的（Apple 审查 3.1.1 / 2.3.10 顾虑）。
> 但「引导 UI」与「切 App 后状态保存」两件事 iOS 同样没有，
> 这部分是否要做需要产品决策，不是纯技术缺口。

Android 为状态保存修过两轮 bug，iOS 若要做需注意等价场景：
系统在背景回收 App、以及从其他 App 切回时如何回到 OTP 画面。

### 1.9 国码清单动态拉取 ⚠️ 可能为刻意

| | |
|---|---|
| Android | `RegisterStep1Fragment.kt:51` → `GET /api/country_codes`，并用装置地区自动选中 |
| iOS | `Talk9APIService.swift:361` 硬编码约十余国，预设 Malaysia |

iOS 的 `Talk9Country.list` 上方注释写着
「Keeping it small on purpose — the user asked for "common countries only"」，
所以这是当初的明确决定。**风险**：后端新增国家时 iOS 不会跟进。
建议至少改成「拉取失败时 fallback 到硬编码清单」，兼顾两者。

### 1.10 QR 扫描支援 Talk9 深链

| | |
|---|---|
| Android | `ScanFragment.kt:336 handleScannedText()`（2026-09-03 加入，+204 行） |
| iOS | `ScanViewController.swift` 只认 `JamiURI.isJami` |

Android 扫到 `https://talk9.co/id/<x>` 或 `talk9://` 时，
先用 `parseTalk9Link()` 解析成裸 id 再走既有流程，支援
`Conversation` / `Invite` / `Swarm` / `Call` 四种型态，解析失败才 fallback 到原字串。

iOS 目前扫到 Talk9 网址会直接判为无效 QR。
**注意**：装置连结用的 `talk9-auth://` iOS 有独立入口
（`LinkDeviceView.swift:230` 的 `ScanQRCodeView`），**该项不缺**，不要重复实作。

iOS 已有 `applinks:talk9.co` 的 Universal Link 解析能力（`AppDelegate.swift:1224`），
缺的只是把同一套解析接到 QR 扫描结果上。

### 1.10-A 深链路径两边对不上 🔴 跨平台互通 bug（比对 QR 时发现，已修复）

比对 §1.10 时发现的独立问题：**两边的深链路径根本没有交集**。

| 路径 | Android | iOS（修复前） |
|---|---|---|
| `id` ← Android 分享连结用的就是这个 | ✅ Conversation | ❌ 不认 |
| `swarm` | ✅ | ❌ 不认 |
| `invite` | ✅ | ❌ 不认 |
| `u` / `user` / `conversation` / `c` | ❌ 不认 | ✅ |

Android 的 `ActionHelper.kt:80` → `Talk9Link.forContact()` 产生
`https://talk9.co/id/<contactId>` 并分享出去。iOS 的 `DeepLink` 只认
`user`/`u`/`call`/`conversation`/`c` —— **Android 用户分享的每一个联系人连结，
iOS 点开都没反应**。host 也只认 `talk9.co`，不认 Android 同样接受的
`www.talk9.co` / `app.talk9.co`。

**已修复**（`Helpers/JamiURI.swift`）：`id`/`invite` → `.user`，`swarm` → `.conversation`，
并把 host 白名单扩成三个。16 项解析测试通过，含安全性拒绝案例
（他站网域、非 40 hex 的 id、补零后缀、错误 scheme）。iOS 原有格式无回归。

> iOS 只消费深链、不产生（分享的是纯文字 + `https://talk9.co` 首页），
> 所以反向（iOS → Android）没有对应问题。

---

## 2. 两边都有、但行为已漂移（5 项）

不是缺功能，是同一功能两边表现不一致 —— 通常比缺功能更难察觉。

### 2.1 广播讯息收件人上限：差 4 倍

**状态：已修复（2026-09-13）**，iOS 已对齐为 200。

| Android | iOS |
|---|---|
| `AppConfig.kt:7` `BROADCAST_MAX_RECIPIENTS = 200` | `Broadcast/BroadcastViewModel.swift:17` 已改为 `200` |

> ⚠️ **改 Broadcast 前必读：仓库里有两份同名档案，只有一份会编译。**
>
> | 路径 | 状态 |
> |---|---|
> | `Ring/Ring/Features/Conversations/Broadcast/` | ✅ **活的** —— Xcode group `path = Broadcast`，实际编译这份 |
> | `Ring/Ring/Features/Conversations/Broadcast*.swift` | ❌ 死代码，未加入 target，旧版遗留 |
>
> 两份的 `BroadcastViewModel.swift` 都有 `maxRecipients`，活的那份多了名称解析
> （`resolveName` / `lookupUnresolvedNames`）。改到根目录那份不会生效。
> 死代码尚未清理 —— 清理前请确认没有其他引用。

### 2.2 – 2.4 会话列表时间戳：iOS 三个实作缺陷

全部位于 `Ring/Ring/Extensions/Date+Helpers.swift` 的 `conversationTimestamp()`：

| # | 问题 | iOS 现况 | Android 对照 |
|---|---|---|---|
| 2.2 | **不跟随 12/24 小时设定** | 硬编码 `formatter.dateFormat = "HH:mm"` | 跟随装置设定，AM/PM 转大写 |
| 2.3 | **「昨天」每月 1 号失效** | `day == todayDay - 1` 纯比日号；1 号时前一天是上月 31 号，判断式永不成立 | `TextUtils.kt:84 isYesterday(timestamp)` |
| 2.4 | **週一看不到上週的星期名** | 用 `todayWeekOfYear == weekOfYear` 判断「同一週」 | `SmartListViewHolder.kt:206` `daysDiff < 7` |

修 2.2 用 `DateFormatter` 的 `timeStyle = .short`（自动跟随地区与 12/24h 设定）。
修 2.3 用 `Calendar.current.isDateInYesterday(self)`。
修 2.4 改成比较日数差 `< 7`。

### 2.5 7 天以上的日期格式（建议保留 iOS 现状）

| Android | iOS |
|---|---|
| 固定 `dd/MM/yyyy` | `.medium` dateStyle，跟随地区 |

iOS 的写法其实更尊重使用者地区设定。**建议改 Android 对齐 iOS**，而非反过来。

---

## 3. Android 平台限定，iOS 不需补（5 项）

看 Android 提交记录时可直接略过这些，它们不构成落差。

| 功能 | 说明 |
|---|---|
| 开机自动同步 | `BootReceiver.kt` + `SyncStartWorker.kt`，经 WorkManager 绕过 Android 15 禁止从 BOOT_COMPLETED 直接启前台服务的限制。iOS 无等价能力 |
| 电池优化豁免提示 | 首次启动提示使用者豁免。iOS 无对应系统概念 |
| 华为 HMS 推送 / AppGallery | 独立 build flavor 与分发管道，版本检查走单独的 `huawei` key。iOS 统一走 APNs |
| Android TV（Leanback） | 整套 `cx.ring.tv.*` 平行 UI。iOS 无 tvOS 目标 |
| Digital Asset Links | `.well-known/assetlinks.json`（需部署到 app.talk9.co）。**iOS 对应的 associated-domains 已设定 `applinks:talk9.co`，与 Android 的 `talk9Host` 一致 —— 已对齐** |

---

## 4. 服务器配置（两边应一致，已核对）

| 用途 | 值 |
|---|---|
| Bootstrap (DHT) | `bootstrap.talk9.co` |
| DHT Proxy | `https://dht.talk9.co` |
| 管理服务器 (JAMS) | `https://app.talk9.co` |
| REST API Base | `https://app.talk9.co/api` |

> ⚠️ Android 仓库 `IOS_SYNC.md` §1 把 REST API Base 写成 `https://talk9.co/api`，**是错的**。
> 以 Android `AppConfig.kt:10-11` 为准：`BASE_URL = "https://app.talk9.co"`、`API_URL = "$BASE_URL/api"`。
> iOS `Talk9APIService.swift:128` 的 `baseURL` 已经是正确值。

TURN 与其他敏感凭证见 Android 仓库 `IOS_SYNC.md` §1，此处不复制。

---

## 5. `IOS_SYNC.md` 列为待办、但 iOS 早已完成（12 项）

**这些不要再排期。** 已在 iOS 源码中确认实作：

| 功能 | iOS 实作位置 |
|---|---|
| 广播讯息（选人 + 群发） | `Features/Conversations/BroadcastViewModel.swift` 等 3 个档案 |
| OTP 注册与重设密码 | `Features/Walkthrough/Models/Talk9APIService.swift` |
| 手机号抓取与个人页显示 | `Talk9APIService.swift:230`、`AccountSummaryVM.swift:87` |
| 会话列表下拉刷新 | `SmartListContentView.swift:67` `.refreshableIfAvailable` |
| QR 从相册选图解码 | `QRCode/ScanViewController.swift:190` |
| 重置卡住的同步会话 | `ConversationViewModel.swift:170` `onResetConversation` |
| 未读数徽章与粗体样式 | `ConversationsView.swift:177, 211` |
| 群组管理员移除成员 | `SwarmInfoVM.swift:297`、`MembersList.swift:40` |
| 群组改名（管理员） | `SwarmInfoView.swift:177` |
| 语音讯息 waveform UI | `Conversations/views/PlayerView.swift` |
| App 内语音录制 | `Conversations/MediaRecord/MediaRecordView.swift` |
| `talk9://` 深链路由 | `AppDelegate.swift:1224`、`SceneDelegate.swift:87` |

---

## 6. 下次同步怎么做

1. 取 Android 仓库最新 versionName（`jami-android/app/build.gradle.kts`），与本文档 §0 的基线比对
2. `git log --oneline <上次基线>..HEAD`，对 message 只写 "Update" 的提交跑 `git show --stat`
3. 每个疑似功能点，**在 iOS 全树 grep 关键字确认**再下结论 —— 不要相信任何待办清单
4. 更新本文档 §0 基线与对应章节

> zsh 陷阱：`grep -rl "kw" $SRC` 在 zsh 下不做变量分词，多路径会被当成单一路径而静默返回空。
> 请直接写出路径，或用 `${=SRC}`。这个坑在本次比对中造成过一轮假阴性。
