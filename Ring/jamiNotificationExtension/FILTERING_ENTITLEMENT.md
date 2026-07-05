# Notification Filtering Entitlement — 空卡问题根治方案（R5）

## 背景

Talk9 的推送是端对端加密的 DHT 值：服务器（DHT proxy）读不懂内容，只能对**每一个**值发 alert push。NSE 解密后约有一半是非用户可见事件（输入状态、已读回执、同步元数据、已消费副本）。Apple 不允许普通 NSE 丢弃 alert push——交付空内容会回落到原始 APNs 占位横幅——所以现状是投递一张 `talk9.suppressed` 空卡，再用三套异步清理（立即轮询、5s 定时、委托主 app 扫除）和 NSE 进程回收赛跑。清理赛跑输了，就是用户锁屏上堆积的空通知。

`com.apple.developer.usernotifications.filtering` entitlement 是 Apple 为这一场景（E2E 加密、服务端无法预分类）提供的正规出口：持有该权限的 NSE 交付**空的** `UNNotificationContent`，系统直接丢弃推送，不显示任何东西。

## 为什么不用「服务端降级 silent push」

1. 被用户强杀的 app **收不到** `content-available` silent push（iOS 政策），而「app 已死」正是 NSE 方案存在的原因——降级等于放弃核心场景。
2. 服务器因 OpenDHT push payload 的 `pt` 字段恒为空而**无法分类**，不存在「只降级噪声」的判断依据。
3. 红线：alert push 永远不要附带 `content-available=1`——那会让后台存活的主 app daemon 先消费 DHT 值，NSE 解密变 unknown，真实消息横幅永久丢失。

## 当前代码状态（已就绪，默认关闭）

`NotificationService.swift` 中所有抑制分支已收敛到单一出口 `deliverSuppressed(_:reason:)`，由
`filteringEntitlementGranted`（**默认 `false`**）切换：

- `false`（现状）：行为与旧版逐字节一致——`talk9.suppressed` 空卡 + 全套清理机器。
- `true`（获批后）：`contentHandler(UNMutableNotificationContent())`，系统静默丢弃，零清理。

⚠️ **两个操作顺序错误会直接坏事：**
- 未获批就把 entitlement key 写进 `.entitlements` → provisioning profile 不含该权限 → 签名/安装失败。
- 未获批就把 flag 翻成 `true` → 空内容回落为原始 APNs 占位横幅（比空卡更糟）。

## Rollout 步骤

1. **提交申请**：用团队开发者账号填写 Apple 表单
   https://developer.apple.com/contact/request/notification-service
   App ID 填 NSE 的 bundle id：`m.talk.talk9.jamiNotificationExtension`（主 app：`m.talk.talk9`）。
2. **Justification**（可直接粘贴，按需微调）：

   > Talk9 is an end-to-end encrypted messenger built on the Jami/OpenDHT protocol. Our push
   > gateway cannot read message contents or types — every push it forwards is an encrypted
   > DHT value. Only the Notification Service Extension, holding the device's private key, can
   > decrypt the payload and determine whether it is a user-visible message, an incoming call,
   > or protocol traffic (delivery receipts, typing indicators, sync metadata, duplicate DHT
   > replicas). A significant share of pushes turn out to be non-user-facing only after
   > decryption. Without the filtering entitlement we must deliver placeholder notifications
   > for these and then attempt to remove them, which leaves empty notification artifacts on
   > users' lock screens. We request the filtering entitlement so the extension can silently
   > drop pushes that decryption proves are not user-facing. All user-visible messages and
   > calls will continue to be displayed normally.

3. **获批后**：developer.apple.com → Certificates, Identifiers & Profiles → Identifiers →
   `m.talk.talk9.jamiNotificationExtension` → 启用该 capability → 重新生成受影响的 provisioning profiles。
4. **加 entitlement key**（`NotificationService-debug.entitlements` 与 `-release.entitlements` 都要）：

   ```xml
   <key>com.apple.developer.usernotifications.filtering</key>
   <true/>
   ```

5. **翻转开关**：`NotificationService.filteringEntitlementGranted = true`。
6. **回归验证**（真机、app 强杀状态）：
   - 触发噪声推送（对端发已读回执/输入状态）→ 锁屏与通知中心**零卡片**；
   - 真实消息 → 横幅正常（标题=发送者，正文=缓存或 "New message"）；
   - 来电 → CallKit 正常、无伴随横幅；
   - 通知中心不再出现 `talk9.suppressed` 组。
7. **后续清理（单独提交）**：确认线上稳定后，以下遗留机器全部可删——
   `makeSuppressedContent()`、`removeOldSuppressedNotifications()`、`scheduleAutoRemove()`、
   `aggressiveImmediateRemoval()`、`scheduleRemoval()` + `Constants.pendingNotificationRemovalKey`、
   以及 `AppDelegate.removePendingNotifications()` 里的 talk9.suppressed 全量扫除。
   届时 `deliverSuppressed` 收缩为三行。

## 参考

- Apple: [UNNotificationServiceExtension — filtering entitlement](https://developer.apple.com/documentation/usernotifications/unnotificationserviceextension)
- 审计上下文：2026-07-05 Root Cause Ranking，R5（空卡抑制体系）。
