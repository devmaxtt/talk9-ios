# CLAUDE.md — Talk9 iOS

> **语言要求：** 请始终用**中文**回答所有问题与请求。
> **Language requirement:** Always respond in **Chinese (Simplified)** for all questions and requests.

---

## 项目概览

Talk9 是基于 [Jami](https://jami.net) 的去中心化通信 iOS 客户端，提供端对端加密的语音/视频通话、即时消息与文件传输功能。

- **Bundle ID:** `com.talk9.mobile`
- **最低支持:** iOS 14.5
- **开发语言:** Swift 5.0（混合 UIKit + SwiftUI）+ Objective-C 桥接层

---

## 构建方法

### 前提条件

- macOS 12+，Xcode 13+
- Carthage（依赖管理）
- Python 3（daemon 编译脚本）

### 构建步骤

```bash
# 1. 编译 daemon 及依赖（C++ 层）
./compile-ios.sh --platform=iPhoneSimulator   # 模拟器
./compile-ios.sh --platform=iPhoneOS          # 真机
./compile-ios.sh --platform=all               # 全平台
./compile-ios.sh --platform=all --release     # Release

# 2. 拉取 Carthage 依赖
cd Ring && ./fetch-dependencies.sh

# 3. 用 Xcode 打开并运行
open Ring/Ring.xcodeproj
```

---

## 项目目录结构

```
talk9-ios/
├── Ring/Ring/               # 主应用源码
│   ├── AppDelegate.swift    # 应用入口
│   ├── Services/            # 业务逻辑服务层（34 个服务）
│   ├── Models/              # 数据模型
│   ├── Features/            # 功能模块（Conversations / Settings / Walkthrough）
│   ├── Calls/               # 通话管理 UI
│   ├── Contact/             # 联系人管理 UI
│   ├── Account/             # 账号管理 UI
│   ├── Coordinators/        # 导航协调器
│   ├── Bridging/            # ObjC ↔ Swift 桥接（daemon 通信）
│   ├── Database/            # Core Data 封装（DBManager）
│   ├── Helpers/             # 工具类
│   ├── Extensions/          # Swift 扩展
│   ├── Protocols/           # 基础协议
│   ├── Constants/           # 全局常量
│   └── Resources/           # 资源文件、本地化字符串
├── Ring/RingTests/          # 单元测试（29 个文件）
├── Ring/RingUITests/        # UI 自动化测试
├── Ring/fastlane/           # Fastlane 自动化配置
├── Ring/API.md              # Talk9 注册门户 API 文档
├── jamiNotificationExtension/ # 通知服务扩展
├── jamiShareExtension/      # 分享扩展
├── daemon/                  # C++ 守护进程（子模块）
└── xcframework/             # 预编译 XCFramework
```

---

## 架构模式

### 核心模式

| 模式 | 说明 |
|------|------|
| **Service Layer** | 每个业务域有独立 Service（AccountsService、CallsService 等） |
| **Coordinator Pattern** | 导航由 AppCoordinator 及各 Feature Coordinator 统一管理 |
| **RxSwift 响应式** | Service 通过 Observable 暴露状态，UI 层订阅驱动更新 |
| **Dependency Injection** | `InjectionBag` 作为服务容器，通过构造器注入 |
| **Adapter Pattern** | ObjC daemon 接口通过 Adapter（CallsAdapter 等）桥接到 Swift |

### 应用状态

`AppState` 枚举控制全局导航：

```
initialLoading → needToOnboard / allSet / addAccount / needAccountMigration
```

### 关键服务

| 服务 | 职责 |
|------|------|
| `AccountsService` | 账号创建、登录、配置管理 |
| `ConversationsService` | 消息/会话 CRUD |
| `CallsService` | 通话生命周期管理 |
| `CallsProviderService` | CallKit 集成 |
| `ContactsService` | 联系人同步、vCard |
| `DaemonService` | C++ daemon 桥接 |
| `VideoService` | 视频采集与渲染 |
| `LocationSharingService` | 位置共享 |
| `DataTransferService` | 文件传输 |

---

## 依赖管理

依赖通过 **Carthage** 管理（`Ring/Cartfile`）：

| 依赖 | 用途 |
|------|------|
| RxSwift / RxDataSources | 响应式编程 |
| SQLite.swift | 本地数据库查询 |
| SwiftyBeaver | 日志 |
| Reusable | 可复用 Cell/VC |
| AMPopTip | 气泡提示 UI |
| GSKStretchyHeaderView | 弹性头部视图 |

---

## 测试

```bash
# 在 Xcode 中运行单元测试
# Product → Test (⌘U)

# 测试文件位置
Ring/RingTests/           # 单元测试
Ring/RingUITests/         # UI 测试
```

关键测试文件：`AccountsServiceTest.swift`、`CallsServiceTests.swift`、`ConversationsService` 相关测试。

---

## 代码规范

- 遵循 SwiftLint 规则（`.swiftlint.yml`）
- 新 Service 需实现 `ServiceEvent` 事件通知
- 导航变更通过 Coordinator 而非直接 push/present
- 响应式流程使用 RxSwift，避免 delegate 回调嵌套
- ObjC 桥接代码放在 `Bridging/` 目录

---

## 本地化

字符串资源位于 `Ring/Ring/Resources/*.lproj/Localizable.strings`，生成文件为 `Constants/Generated/Strings.swift`（勿手动编辑）。更新本地化使用 Transifex 脚本。

---

## 相关文档

- `Ring/API.md` — Talk9 注册门户 API（OTP 注册、密码重置流程）
- `README.md` — 完整构建说明
- `compile-ios.sh` — Daemon 编译脚本说明
