> 最新更新时间：2026-08-19

# SSH Mobile 模块化重构执行 Plan

> 目标仓库：`hejulian2004/ssh_mobile`
> 适用阶段：开发期直接重构
> 执行对象：Codex / 开发者
> 原则：不考虑旧版本兼容、不迁移旧开发数据库；每个 Step 完成后必须恢复可分析、可测试状态，再进入下一 Step。

兼容层引用基线与模块关闭门禁见
[`COMPATIBILITY_MIGRATION_INVENTORY.md`](COMPATIBILITY_MIGRATION_INVENTORY.md)。

---

## Step 00 执行记录（2026-08-07）

- 基线 commit：`b20b9920efcea8f096c07c4bba9df1d6aad6d400`。
- `flutter pub get`：通过；依赖解析完成。
- `dart format --output=none --set-exit-if-changed lib test tool`：通过，577 个文件，0 个文件变更。
- `flutter analyze --no-pub`：通过，`No issues found!`。
- `flutter test --no-pub`：通过，`All tests passed!`（1017 个测试进度项）。
- `flutter build apk --debug --no-pub`：通过，生成 `build/app/outputs/flutter-apk/app-debug.apk`；构建保留 Android SDK 37/插件兼容性警告。
- `flutter build windows --no-pub`：通过，生成 Windows Release runner；首次构建的 NuGet 下载提示不影响结果。
- 约束记录：native asset hook 按仓库现有实现调用 Cargo；本 Step 仅修复 Android `Debug.MemoryInfo` 对不存在 API 的引用，未改变 MethodChannel 协议或业务规则。

---

## Step 01 执行记录（2026-08-07）

- 已创建 `apps/ssh_mobile_full/`、`packages/core/`、
  `packages/infrastructure/`、`packages/features/`；完整 Flutter App 的代码、
  测试、平台目录、资源和 App 专属工具已移动到
  `apps/ssh_mobile_full/`。
- 已将 `packages/ssh_mobile_network_native` 移动到
  `packages/infrastructure/ssh_mobile_network_native/`，并更新 App 的 xterm、
  native package path dependency。
- 已创建根 `pubspec.yaml` Dart workspace 与初始 Melos format/analyze/test
  脚本；workspace 成员均使用 `resolution: workspace`。初始 `melos.yaml`
  配置已在 Step30 按 Melos 8 规则迁移到根 `pubspec.yaml`。
- 计划描述与实际依赖的最小差异：原生 package 的 `test: ^1.28.0` 在 workspace
  中会解析到与 App 的 `flutter_test` / `drift_dev` 不兼容的版本。为保持原有
  生命周期测试覆盖且不引入运行时依赖，原生 package 改用 Flutter SDK 的
  `flutter_test`，测试导入同步调整为 `package:flutter_test/flutter_test.dart`。
- `dart pub get`：通过；root workspace 统一解析 `test_api 0.7.11` 与
  `analyzer 13.0.0`，并按 Dart workspace 规则清理了成员旧 lock/config 文件。
- 迁移后的 App 目录执行 `flutter pub get`：通过；重新生成
  `apps/ssh_mobile_full/.flutter-plugins-dependencies`，修复了迁移后 Android
  构建仍引用旧根目录插件元数据的问题。未手工修改 generated plugin registrant。
- 迁移后 native asset hook 的 workspace 根目录计算由两级调整为三级，并更新
  Android `local.properties` 查找路径；这是目录迁移所需的最小路径修正，Rust
  workspace 仍保持在根目录 `native/network_core`。
- 最终验证：定向 Dart format 通过（583 个文件，0 个变更）；App
  `flutter analyze --no-pub` 通过；App `flutter test --no-pub` 通过（1017 个
  测试进度项）；native package analyze 通过；native package test 通过（4 个
  测试）；`flutter build apk --debug --no-pub` 通过，生成
  `apps/ssh_mobile_full/build/app/outputs/flutter-apk/app-debug.apk`。
- 本 Step 是目录搬迁与 workspace 接线：Git 中旧路径对应新路径，未删除业务实现；
  未改变 SSH、网络协议、UI、业务规则或 AI Prompt。

---

## Step 02 执行记录（2026-08-07）

- 已创建 `packages/core/app_core/`，生产代码仅依赖 Dart SDK；公共入口导出
  lifecycle、Module、logging 和 Capability 合约。
- 已创建 `Disposable`、`Activatable`、`DisposableBag`、`AppModule`、
  `ModuleContext`、`ModuleDescriptor`、`ModuleRegistry`、`ModuleState`、
  `AppLogger`、`LogLevel`、`LogRecord` 和 `CapabilityRegistry`。Registry 只持有
  Descriptor，不缓存运行时 Module；CapabilityRegistry 不接管 Capability 的
  资源释放责任。
- 已补充 `app_core` 的 README、AGENTS 和 7 个合约测试，并同步根 AGENTS、
  README、维护 Skill、Agent memory 和本执行记录。
- 依赖处理：按官方稳定版本将根 Melos 开发依赖设置为 `^8.2.2`，用于实际执行
  workspace scope 验证。当前 Flutter SDK 将 `flutter_test` 固定到
  `test_api 0.7.11`，而最新 `package:test` 稳定版本与 workspace 的
  `drift_dev` analyzer 约束不能同时满足；因此只在测试侧使用 Flutter SDK 的
  `flutter_test`，`app_core/lib` 仍保持纯 Dart，不引入旧版本或不兼容 override。
- `dart pub get`：通过；workspace 解析包含 Melos 8.2.2。
- `dart run melos exec --scope=app_core -- dart analyze .`：通过（使用仓库内置
  Dart SDK 可执行文件，绕过本机 WindowsApps `dart` wrapper）。
- `dart run melos exec --scope=app_core -- flutter test --no-pub`：通过，7 个测试
  全部通过；定向 format check：通过，17 个文件无变更。
- 本 Step 只建立 Core Contract 和包级工具接线，未迁移 AppLogService、AppRuntime、
  Feature、SSH、网络、数据库或 UI 行为。

---

## Step 03 执行记录（2026-08-07）

- 已将 App Shell 迁移到 `apps/ssh_mobile_full/lib/app/`，新增
  `AppBootstrap`、`AppRuntimeFactory`、`AppRuntime` 和 `SshMobileApp`；根
  `main.dart` 只保留启动委托及旧入口导出兼容面。
- `AppRuntimeFactory` 统一创建现有 App Scope 服务；`AppRuntime` 明确承担
  模块、SSH、网络、数据库/Repository、Logger 的资源释放责任，并以幂等
  Future 防止重复 dispose。现有 Service 类型保留在 Runtime 中并标记后续
  Step TODO，没有提前迁移业务模块。
- `SshMobileApp` 对 Runtime 已有的 ChangeNotifier 使用
  `ChangeNotifierProvider.value`，Connection/SFTP ViewModel 仍由当前根
  Provider 创建，避免本 Step 扩大到 Feature/Route 迁移。
- 应用新增 `app_core` workspace 生产依赖；`dart pub get` 通过，未出现版本
  冲突。依赖解析提示的可升级项均受当前 Flutter/Drift 约束限制，本 Step
  不擅自升级无关依赖。
- 新增 `test/app/app_runtime_test.dart`，验证 Runtime 单一 App Scope 和
  幂等释放；为避免 Flutter test 默认平台误走 background-service 分支，测试
  显式固定 Windows 目标平台，不改变生产代码行为。
- 最终验证：App `flutter analyze --no-pub` 通过；定向 Runtime 测试通过（1
  项）；App `flutter test --no-pub` 通过（1018 个测试进度项）。
- 本 Step 未改变 SSH、网络协议、数据库 schema、UI、业务规则或 AI Prompt；
  只迁移 Composition Root 和资源所有权边界。

---

## Step 04 执行记录（2026-08-07）

- 按职责迁移并拆分旧 `AppLogService`：主 facade 保留 Flutter 错误入口、
  ChangeNotifier 和现有兼容 API；`app_log_store.dart` 负责 Drift 绑定、顺序
  队列和临时 ID；`app_log_disk_sink.dart` 负责磁盘队列与轮转；
  `app_log_models.dart` 负责日志模型和数据库变更模型。没有删除日志业务行为。
- 扩展 `packages/core/app_core/lib/src/logging/`：新增 `AppLoggerImpl`、
  `ScopedLogger`、`LogBuffer`、`LogSink`，并为 `AppLogger` 增加 `scope(name)`。
  Core 生产代码仍为纯 Dart；`AppLoggerImpl` 的内存日志默认上限为 2000，
  AppLogService 为保持现有 UI/数据库行为继续使用 1000 条上限。
- `AppLogService` 实现 Core `AppLogger`，`AppRuntime.logger` 暴露同一个
  App Scope Logger；作用域 Logger 不拥有根实例。AppBootstrap 和后台服务不再
  通过 `AppLogService()` 创建生产实例；兼容构造入口仅保留在
  `AppRuntimeFactory`、测试和 AppLogService 自身的兼容声明中。
- 已补充 Core Logger、Ring Buffer、Sink 生命周期、作用域适配和 AppRuntime
  断言测试；未改动现有日志脱敏、数据库绑定、磁盘轮转、通知合并、UI、SSH、
  网络、业务规则或 AI Prompt。
- 依赖检查：`flutter pub get` 通过；输出中的更新项均受当前 Flutter/Drift
  约束限制，没有版本冲突，因此没有升级无关依赖或新增第三方依赖。
- 最终验证：app_core `dart analyze .` 通过，Core Flutter 测试 13 项通过；
  App `flutter analyze` 通过；App `flutter test` 通过（1019 个测试进度项）；
  定向日志/数据库/Runtime 测试通过；格式检查和 `git diff --check` 通过。
- 本 Step 完成后仍保留后续 Feature 逐步注入 scoped logger 的 TODO；不在本 Step
  扩大范围迁移数百处旧 `AppLogService.instance` 调用。

## Step 05 执行记录（2026-08-08）

- 已创建 `packages/core/connection_core/`，公共入口导出 Connection 模型、
  `ConnectionRepository`、`CredentialRepository`、`HostKeyRepository`、独立
  Drift 数据库和 Secure Storage 凭据实现。旧
  `apps/ssh_mobile_full/lib/features/connection/models/connection.dart` 仅保留
  公共 API 转导出；Screen/ViewModel 目录没有提前移动到 Feature Package。
- `ConnectionConfig` 保留当前业务所需的运行时密码/私钥字段，但 JSON、数据库
  Companion 和 Repository 快照都会排除这些字段；`ConnectionProfile` 明确表示
  非敏感结构。`ConnectionTable` 只保存端点、终端配置、排序、时间和 Host Key
  信任元数据。
- 新增 `ConnectionDatabase`、`ConnectionDao` 和 `DriftConnectionRepository`，
  使用全新的 `connection.sqlite` 数据库基线，schema version 为 1，不读取或迁移
  旧 `AppDatabase` / SharedPreferences 连接数据。Repository 写操作使用串行队列，
  排序写入使用数据库事务；`SecureCredentialRepository` 使用独立模块键名前缀，
  空凭据走删除路径。
- `AppRuntimeFactory` 注册并注入唯一的 ConnectionDatabase、结构 Repository、
  CredentialRepository 和 Host Key capability；`AppRuntime` 在等待 Repository
  首次加载后关闭 ConnectionDatabase。为避免测试依赖平台目录插件，Composition
  Root 增加了可选的测试依赖注入参数，生产路径仍使用 `drift_flutter` 默认数据库路径。
- 当前旧 Connection ViewModel 仍通过 StorageService 兼容接口工作，这是为严格
  遵守 Step 顺序保留的最小过渡；Step 06 才切换 `feature_connection` 通过 Core
  Repository/Capability 访问数据。没有改变 SSH、SFTP、Host Key 策略、UI 或业务规则。
- 依赖查询参考了 [Drift setup](https://drift.simonbinder.eu/setup/)、
  [`driftDatabase` API](https://pub.dev/documentation/drift_flutter/latest/drift_flutter/driftDatabase.html)
  和 [flutter_secure_storage 文档](https://pub.dev/packages/flutter_secure_storage)。
  当前 workspace 的稳定兼容版本为 Drift `^2.34.3`、drift_flutter `^0.3.1`、
  flutter_secure_storage `^10.3.1`；`flutter_secure_storage 11.0.0-beta.1`
  不是稳定版，因此未升级。`dart pub get` 通过，剩余更新提示均受当前 Flutter/Drift
  约束限制，不存在需要处理的版本冲突。
- 已补充模型、CRUD、排序并发、Host Key、凭据隔离和 Runtime Scope 测试。
  `dart run build_runner build` 通过；connection_core `dart analyze` 通过、9 项
  测试通过；App `flutter analyze --no-pub` 通过；定向 Connection/Runtime 测试
  14 项通过；App `flutter test --no-pub` 通过（1019 个测试进度项）；最终格式检查
  （629 个文件，0 个变更）、`git diff --check` 和维护 Skill 同步检查均通过。

## Step 06 执行记录（2026-08-08）

- 已创建 `packages/features/feature_connection/`，公共入口导出连接配置模型、
  `ConnectionViewModel`、`AddEditScreen`、`ConnectionStrings` 以及运行时/验证
  Capability Contract。原 `add_edit_screen.dart` 通过 Git 文件移动迁入
  `src/presentation/`；原 App 路径保留兼容转导出，未删除业务实现。
- `ConnectionViewModel` 现在只依赖 `connection_core` 的
  `ConnectionRepository`、`CredentialRepository`、`HostKeyRepository`，以及
  `ConnectionRuntimePort` / `ConnectionVerificationPort`；它不创建或释放
  Connection DB、Secure Storage、SSH、SFTP、监控服务。凭据保存、删除和 Host
  Key 信任元数据分别走对应契约。
- 因 SSH/SFTP/监控旧实现仍直接读取 `StorageService`，在 App 组合根新增了
  `connection_feature_adapters.dart`：负责新旧结构数据的最小缺失同步、凭据
  双读/双写、Host Key 双写和运行时 Capability 转换。该桥不进入 Feature，待
  后续 SSH/SFTP Steps 迁移完成后删除。此处是针对实际代码差异的最小调整，避免
  迁移期间已有服务器和会话行为断裂。
- `app_ui` 尚未到 Plan Step 09，因此 Feature 暂时只复制连接编辑页所需的
  最小 UI Surface/Header/SectionCard 和响应式 Token；没有扩大为共享 UI 包，后续
  Step 09 再归并。Connection 页面中文/英文文案集中在 `ConnectionStrings`。
- 依赖沿用 workspace 已解析的稳定约束：`provider ^6.1.5+1`、`shadcn_ui
  ^0.56.1`、`uuid ^4.6.0`，没有出现版本冲突；`flutter pub get` 下载完成，
  仅报告受现有 Flutter/其他约束限制的可用更新，没有擅自升级不相关依赖。
  - 已新增 Feature 契约测试 3 项，并更新 Connection/Home/SFTP 相关 Provider
    测试。`feature_connection flutter analyze`、`feature_connection flutter test`
    通过；App `flutter analyze --no-pub` 通过；连接、Home、SFTP 定向回归测试
    通过。完整 App 测试通过（1019 个测试进度项）；最终格式检查通过（601 个
    文件，0 个变更）、`git diff --check` 和 Skill 同步检查均通过。

## Step 07 执行记录（2026-08-08）

- 已创建 `packages/infrastructure/network_transport/`，公共入口导出
  `NetworkRuntime`、Capability、NetworkConfig、TransportEndpoint/Connection、
  metrics snapshot 和 native adapter contract。Package 只依赖 `app_core` 与
  `ssh_mobile_network_native`，没有新增 TCP、UDP、QUIC 或 WebRTC 协议实现。
- `NetworkRuntimeImpl` 由 `AppRuntimeFactory` 唯一创建并注入 `AppRuntime`；
  QUIC/WSS Relay 首次使用时共享 native handle 初始化 Future，初始化失败会清除
  in-flight 状态并允许重试，dispose 会等待未完成的创建并显式 close handle。
- 当前旧 `LanReceiverCoordinator` 仍直接使用已有 LAN `NetworkService`/native
  协议路径，这是为不改变 LAN 行为而保留的最小过渡；后续 LAN 专属 Step 再把它
  收敛到本 Facade。Feature 不得据此新增第二个 NetworkRuntime 实现。
- `flutter pub get` 通过，没有版本冲突；现有可用更新均受当前 Flutter/Workspace
  约束限制，因此没有擅自升级不相关依赖。Rust native hook 使用仓库已安装工具链
  的显式 PATH 运行验证。
- 已完成 `network_transport` 4 项测试、AppRuntime 定向测试和完整 App 回归
  （1019 个测试进度项）；`network_transport` 与 App `flutter analyze --no-pub`
  均通过，最终 Dart 格式检查（599 个文件，0 个变更）、`git diff --check` 和
  Skill 同步检查在 Commit 前完成。

## Step 08 执行记录（2026-08-08）

- 已创建 `packages/infrastructure/ssh_core/`，公共入口导出
  `SshSessionManager`、`SshSessionLease`、`SshSessionPool`、Desktop/Mobile
  `SshRuntimeAdapter`、SSH Client、Host Key Policy、一次性命令执行器和非敏感
  `SshTargetBinding`。Package 只依赖 `app_core`、`connection_core`、Flutter SDK
  和现有稳定约束中的 `dartssh2 ^2.22.5`，不依赖 `StorageService`、Feature 或
  `flutter_background_service`。
- Session Pool 合并同一 Session 的并发创建，维护引用计数和 idle timeout；引用
  归零后 Timer 到期才关闭 Stream，`release` 重复调用幂等，Pool `close` 会取消
  Timer、等待创建中的 Session 并关闭输出流。Manager 对 Runtime 初始化提供
  single-flight、失败重试和幂等关闭。
- AppRuntime 新增 `SshSessionManager` 公共视图；当前 `SshService` 实现该契约，
  因旧 Terminal/Background 方法面仍与 `TerminalHistoryRecord` 和旧后台事件桥
  紧密耦合，未在本 Step 删除或整文件搬迁。两者是同一个 App Scope 实例，旧
  `SshService` 作为兼容表面由 Manager 的 `close` 统一释放；Terminal Pilot 再
  逐个替换其方法面。这是针对实际代码差异的最小迁移，避免重复创建 SSH Owner
  或改变现有连接行为。
- 新增 `ssh_core` 生命周期、并发 acquire/release、multiple consumer、idle
  cleanup、初始化失败重试、dispose 幂等和目标绑定安全测试共 5 项；AppRuntime
  定向测试通过。`flutter pub get` 通过，没有版本冲突；输出中的可升级项均受
  当前 Flutter/Workspace 约束限制，本 Step 未擅自升级无关依赖。
- `ssh_core flutter analyze --no-pub`、`ssh_core flutter test --no-pub`、App
  `flutter analyze --no-pub` 和完整 App `flutter test --no-pub` 均通过（完整回归
  1019 个测试进度项）；Rust native hook 验证使用仓库已有 Rust 工具链 PATH。

## Step 09 执行记录（2026-08-08）

- 已创建 `packages/core/app_ui/`，公共入口为 `package:app_ui/app_ui.dart`，
  只承载主题、响应式指标和无业务依赖的跨 Feature Widget。迁入主题、
  `responsive.dart`、`AppSurface`、连接进度、破坏性确认、溢出文本和触感反馈；
  原 App 路径保留为兼容导出，避免一次性删除旧入口。
- `server_selector`、SSH Host Key 信任对话框、终端窗口对话框以及其他未被
  多个独立 Feature 实际复用的 Widget 未强行迁入：它们仍依赖旧 Connection
  模型、App Service 或 Feature 语义，等待后续公共 Contract/专属 Feature Step。
- 共享 UI 测试随 Package 迁移到 `packages/core/app_ui/test/`，新增/保留主题、
  响应式和 Widget 测试共 13 项；全 App 现有 Feature 导入切换到公开入口，
  兼容导出继续覆盖旧调用面。app_ui 文件只创建 Widget 自己拥有的
  Controller/AnimationController，并在 State `dispose` 中释放。
- `flutter pub get` 通过，没有版本冲突；输出中的 20 个可升级项均受当前
  Flutter/Workspace 约束限制，本 Step 未擅自升级无关依赖。`app_ui` 与 App
  的 `flutter analyze --no-pub` 均通过，Package 测试 13 项、全 App 回归
  1006 项均通过；格式检查、`git diff --check` 和 Skill 同步检查通过。

## Step 10 执行记录（2026-08-08）

- 已创建 `packages/features/feature_terminal/`，将 Terminal 页面、专属
  ViewModel、Widget、键盘模型、Terminal Module 和测试迁入 Package。旧
  `apps/ssh_mobile_full/lib/features/terminal/**` 路径保留为兼容导出，旧测试
  迁移为 Package 测试，没有通过批量删除破坏原有调用面。
- `TerminalModule` 是 `terminal.db` 和 Terminal Repository 的唯一 Owner，当前
  schema 为 1，包含 `terminal_history` 元数据表。Route Scope 在 `/terminal`、
  `/history` 和 `/terminal-windows` 路由创建 Module 与页面 ViewModel，离开路由
  时销毁 ViewModel、关闭数据库；Module 只保存注入的
  `ssh_core.SshSessionManager` 引用，不拥有 App Scope SSH。
- 终端原始输出历史服务已迁入 `feature_terminal` 的 `data` 层，保留加密分片、
  写入队列、尾部读取、旧明文迁移和显式 `dispose`。App Shell 通过
  `AppTerminalHistoryRepository` 与兼容 facade 暂时桥接旧 `StorageService`，
  并由 SSH Owner 负责关闭输出历史资源，等待后续 Storage 收敛 Step 删除桥接。
- App 组合根新增 `AppTerminalSshCapability`、Terminal Settings/Shortcut/
  Connection/Logger Port 适配器；Terminal Feature 不创建 `SshService` 或
  `SshSessionManagerImpl`。`AppRuntime` 仍只创建一个 SSH Owner，测试改为验证
  包装器与同一底层 Service 的关系。
- 按 Step 10 的文件尺寸要求检查了迁移后的终端代码。Session ViewModel、
  `terminal_view_area`、历史页和键盘面板均包含共享的 xterm/Controller/Timer
  生命周期；拆分会破坏私有状态边界，因此保留为内聚的 Route UI 单元。生成的
  `terminal_database.g.dart` 不作为手写文件治理对象；没有机械创建 `part1` 文件。
- `feature_terminal` Package analyze/test 通过（51 项），App analyze 通过，
  从 `apps/ssh_mobile_full/` 包根执行的全 App 测试通过（959 项）。`flutter pub
  get` 没有版本冲突；20 个可升级项仍受当前 Flutter/Workspace 约束限制，未
  越界升级无关依赖。格式检查、`git diff --check` 和 Skill 同步检查在提交前
  复核。

## Step 11 执行记录（2026-08-08）

- 已创建 `packages/features/feature_sftp/`，迁入 SFTP 页面、编辑器、预览器、
  设置页、SFTP ViewModel、Service Port、`SftpModule`、路径 Repository 和
  测试。旧 `apps/ssh_mobile_full/lib/features/sftp/`、旧 `SftpService` 及旧
  测试路径保留为兼容表面；本 Step 采用迁移桥接，没有一次性删除原有实现。
- `SftpModule` 独占并关闭 `sftp.db`，数据库只保存 recent paths、favorite
  paths 及后续可扩展的传输元数据，不保存密码、私钥或 Token。SFTP 页面使用
  Route-scoped `SftpViewModel`；页面销毁只解除 Feature 监听，当前兼容后端的
  SSH、传输任务和连接资源仍由 AppRuntime/旧 `SftpService` Owner 管理，允许
  未迁移的 AI/System Admin 等调用继续使用同一后端。
- App Shell 新增 SFTP Port 适配器：连接目录、设置、Host Key 对话框、日志和
  旧 SFTP 模型转换均在 `sftp_feature_adapters.dart` 完成。Feature 只依赖
  `SftpBackend`、`SftpSettingsPort`、`SftpConnectionCatalogPort`、
  `SftpHostKeyConfirmationPort` 和 `SshSessionManager`，不依赖 App Service 或
  其他 Feature 实现。
- `flutter pub get` 通过；输出中的 20 个可升级项均受当前 Flutter/Drift
  workspace 约束限制，没有版本冲突，因此没有升级无关依赖。新增 `uuid` 依赖
  用于模块内路径记录 ID。Drift `sftp_database.g.dart` 已由 build_runner
  生成并纳入 Package。
- 已新增 SFTP Module/Repository 测试，覆盖数据库初始化 single-flight、Module
  activate/deactivate/dispose、recent path 30 条上限、favorite upsert/rename/
  remove 和连接隔离；旧后端异常在 App 适配器中转换为 Feature 异常，保持预览
  和传输页面的现有错误行为。

## Step 12 执行记录（2026-08-08）

- 已创建 `packages/features/feature_monitoring/`，迁入实时监控模型、
  Linux/Windows 探针与解析器、Monitoring Service、Tool Service、Module、
  Port 和 ViewModel。原 `performance_monitor_service.dart`、
  `performance_monitor_models.dart`、`performance_monitor_tool_service.dart`
  及 `server_status_probe.dart` 路径保留为兼容桥接；本 Step 是迁移并收敛
  实现归属，不是批量删除旧调用面。
- `MonitoringModule` 的 Service 由 `AppRuntime` 持有；`initialize` 创建服务，
  `deactivate`/`dispose` 取消 Timer 与订阅。为保持现有监控“用户或工具显式
  startMonitoring 后才开始采样”的业务行为，`activate` 只恢复模块可用状态，
  不在 App 启动时永久开启 polling。Package 不创建 `monitoring.db`，样本仍是
  有界内存历史。
- Monitoring 的 SSH Port 增加显式 `MonitoringRequestPriority.low` 合约。
  App Shell 适配器保留该优先级标记并复用当前 one-shot SSH 执行路径；现有
  `SshService` 尚未提供独立调度器，因此本 Step 不擅自改写交互 Terminal 的
  调度实现。监控与 Terminal 通过不同的 Capability/Port 边界隔离。
- `server_diagnostics_service.dart` 同时包含系统诊断、平台识别和运维报告
  组合逻辑，不属于纯实时监控能力；本 Step 仅迁移其中可独立归属的
  `ServerStatusProbe`，诊断组合服务保留到后续 System Admin Step。
- 依赖解析通过；输出中的 20 个可升级项受当前 Flutter/Drift workspace
  约束限制，没有版本冲突，因此未升级无关依赖。Package 测试 2 项、完整
  App 回归 959 项、Package/App analyze、格式检查、`git diff --check` 和
  Skill 同步检查均通过。

## Step 13 执行记录（2026-08-08）

- 已创建 `packages/features/feature_system_admin/`，迁入 System Admin 页面、
  Route ViewModel、管理命令 Service、确认流程、解析器和 `SystemAdminModule`。
  旧 `apps/ssh_mobile_full/lib/features/system_admin/**`、旧
  `lib/services/system_admin_service.dart` 及相关旧 Widget 路径保留为兼容
  表面；本 Step 采用 App Shell 适配器接线，不是一次性删除原有实现。
- Package 只依赖 `app_core`、`app_ui`、`connection_core`、`ssh_core` 和 UI
  需要的现有稳定依赖。System Admin 不直接依赖 `feature_monitoring`；
  `system_admin_monitoring.dart` 定义展示所需的本地 Capability DTO/Port，
  `system_admin_feature_adapters.dart` 在 App Shell 完成 Monitoring 到该
  Contract 的转换。
- `SystemAdminModule` 只拥有管理 Service、当前管理 SSH 会话和活动命令的
  释放责任；AppRuntime 继续拥有 SSH、Storage、SFTP、Logger 和 Monitoring。
  Route Scope 创建 ViewModel。没有新增 `system_admin.db`，也没有改变 root
  校验、管理命令白名单、确认 Token、Host Key 确认和按 Tab 加载行为。
- Home Shell 已切换到新 Package 的 `SystemAdminScreen`，旧入口仍可供兼容
  测试使用。新增 Module 生命周期、管理会话释放和命令解析测试；依赖解析
  无版本冲突，`fl_chart` 与现有 workspace 稳定约束统一为 `^1.2.0`。

## Step 14 执行记录（2026-08-08）

- 已创建 `packages/features/feature_lan_share/`，迁入 LAN discovery、配对、
  HTTPS/WebSocket/Web Share、传输协议、安全限制、Relay enrollment 和
  LAN ViewModel/UI。旧 `apps/ssh_mobile_full/lib/features/lan_share/**`、
  `lib/services/lan_share/**` 及旧网络服务保留为兼容表面，没有一次性删除
  原实现。
- `LanShareModule` 现在拥有独立 `lan_share.sqlite`、
  `LanShareHistoryRepository` 和 `LanReceiverCoordinator`；数据库只保存
  transfer history 与不含 secret 的 pairing metadata。Module 只有在 App
  Shell 配置允许时才 activate Receiver，编译或导入 Feature 不会启动监听。
- Feature 仅依赖 `app_core`、`app_ui`、`network_transport` 和本包稳定 Port，
  不依赖 SSH、其他 Feature、App `/src/` 或 native FFI。App Shell 新增
  `lan_share_feature_adapters.dart`，将旧设置、日志、数据保护、QUIC 身份和
  Network Protocol V2 NetworkService 转换为 Feature Contract；生产 native 创建仍只有
  这一处。
- App Runtime 已切换到新 Module/Package 路由和根级配对/传入传输宿主；旧
  `lanReceiverCoordinator` API 作为 Runtime 兼容 getter 保留。AppRuntimeFactory
  支持仅测试使用的数据库工厂和 Receiver 开关，生产不增加内存数据库回退。
- 依赖解析无版本冲突，保持现有 Flutter/Drift 稳定约束；Feature 包新增
  Module、独立数据库、传输安全测试，旧 LAN coordinator/pairing/safety 回归
  测试继续保留并通过。未删除迁移过程中继承的较大旧实现文件，文件尺寸治理
  留给计划中的 Step 31，避免扩大本 Step 范围。
- 验证通过：`flutter pub get`；Feature 包 `dart format`、`flutter analyze`
  和 10 项 `flutter test`；App `dart format`、`flutter analyze` 和完整
  `flutter test`（959 项）；旧 LAN 兼容测试 26 项及 AppRuntime 定向测试 1 项；
  `git diff --check`；`sync_agent_skills.ps1 -Mode Check`。没有依赖版本冲突，
  仅提示 20 个受当前 Flutter/Drift workspace 约束的可升级项，未强行升级。
- Step 14 按 `refactor(lan-share): step 14 migrate lan share module` 独立提交，
  Commit 记录作为本执行记录的追溯入口。

## Step 16 执行记录（2026-08-08）

- 已创建 `packages/features/feature_rag/`，迁入 RAG 页面、Route-scoped
  ViewModel、文档解析、BM25/vector/Hybrid 检索、RAG Module/Service、Drift
  Repository 和缓存 Store。旧 App RAG 路径保留为非 Owner 兼容出口，避免把迁移
  误做成一次性删除。
- `RagModule` 独占并释放 `rag.db`、Repository、缓存和 Service；数据库只保存
  文档、倒排索引和缓存元数据，正文与向量进入有 entry/total/source 大小上限、
  TTL 和最近访问淘汰策略的文件缓存。开发期不读取或迁移旧
  `rag_database.json` / `rag_metadata.json`。
- App Shell 通过 settings/logger/embedding Ports 注入依赖，AI 只依赖公开的
  `RagCapability`；`AppRuntime` 持有 Module，RAG 页面通过 Feature Scope 创建
  Route ViewModel。为验证真实检索路径，Embedding Client 也支持测试替身注入，
  不访问真实网络。
- 依赖解析通过且没有版本冲突；现有可升级提示受 Flutter/Dart workspace 约束，
  未越界升级无关依赖。RAG Package 4 项测试、AppRuntime/RAG 定向回归 13 项和
  完整 App 回归 959 个测试进度项均通过；Package/App analyze、格式检查、
  `git diff --check` 和维护 Skill 同步检查在提交前完成。
- Step 16 按 `refactor(rag): step 16 migrate rag module` 独立提交，Commit
  记录作为本执行记录的追溯入口。

## Step 17 执行记录（2026-08-08）

- 已创建 `packages/features/feature_mcp/`，通过 Git 文件迁移将 MCP Console
  页面、ViewModel、`lib/services/mcp/**` 的业务实现及对应测试迁入 Package；
  没有批量删除 MCP 业务实现。仅移除旧 AppDatabase 中与 MCP 重复的表、DAO、
  Repository 和 StorageService facade 接口，使数据 Owner 收敛到新 Module。
- `McpModule` 独占并释放 `mcp.db`、活动 Repository、MCP Server Controller 和
  审批队列；新数据库 schema 从 1 开始，开发期不读取或迁移旧 MCP 活动表。App
  Runtime 通过 `McpSettingsPort`、`McpLoggerPort` 和工具运行时 Port 注入 App
  能力，App Shell 适配器负责连接 `AppSettings`、`AppLogService` 和现有
  `AiToolService`，Feature 不反向依赖 App 或其他 Feature 实现。
- `McpToolExecutor`、`McpApprovalRequest` 和目标校验 Contract 均位于 Feature
  公共入口；危险 Tool 的 `approval_required` 仍在 HTTP/JSON-RPC 执行层处理，
  审批原始绑定仅通过进程内 `opaqueHandle` 返回执行层，不写入 `mcp.db`。Server、
  审批队列、数据库和 Route ViewModel 均有明确的生命周期 Owner 与释放路径。
- 已更新 Package README/AGENTS、根 README/AGENTS、Agent memory、维护 Skill
  和本执行记录；文档同步说明了 `feature_mcp` 与 `mcp.db` 的 Owner 边界。
- 依赖解析无版本冲突；仅提示受当前 Flutter/Dart/Drift workspace 约束的可升级
  项，未擅自升级不相关依赖。`feature_mcp` 格式检查（49 个文件）、
  `flutter analyze --no-pub` 和全量测试 87 项通过；App 格式检查（537 个文件）、
  `flutter analyze --no-pub` 和全量测试 872 项通过，MCP 安全设置与 AppRuntime
  定向测试 5 项通过。`git diff --check` 和维护 Skill 同步检查在提交前完成。
- Step 17 按 `refactor(mcp): step 17 migrate mcp module` 独立提交，Commit 记录
  作为本执行记录的追溯入口。

## Step 18 执行记录（2026-08-08）

- 已通过 Git 文件迁移创建 `packages/features/feature_ai/`，将 AI Chat、Agent、
  Skills、LLM provider/runtime、工具编排、AI 数据模型和对应测试迁入 Package；
  旧 App 文件保留为兼容出口/适配边界，没有删除业务能力来代替迁移。
- `AiModule` 独占并懒初始化 `ai.db`、`DriftAiRepository` 和 AI 运行时；聊天、
  Agent metrics、trace 及敏感消息字段归属 AI 数据库。原 AppDatabase 的 AI 表、
  DAO 和重复 Repository 已移除，原有数据库测试覆盖迁移到
  `feature_ai/test/data/ai_repository_test.dart`。
- AI 仅通过 `app_core` 的 RemoteCommand、FileTransfer、Monitoring、Playbook、
  RAG、MCP Capability 以及注入 Port 调用 App 能力；App Composition Root 负责
  适配与懒加载，Feature 不引用其他 Feature implementation 或 `/src/`。
- 依赖解析没有发生版本冲突，因此没有升级无关依赖；后续若出现真实冲突，
  按官方稳定版本资料核对后再做最小升级。Package/App 格式、分析和全量测试
  通过后，Step 18 按 `refactor(ai): step 18 migrate ai module` 独立提交。

## Step 19 执行记录（2026-08-08）

- 已通过 Git 文件迁移创建 `packages/features/feature_webview/`，将客户端
  WebView 服务、按聊天会话状态、导航页面、ViewModel、模型/安全策略和测试
  迁入 Package；原有实现保持为迁移后的代码，不以删除业务能力代替迁移。
- `ClientWebViewService` 由 `AppRuntime` 持有，使用注入的 `AppLogger`，按聊天
  ID 管理 `WebViewController` 和 AI 浏览互斥令牌，并在 Runtime 释放时清理会话。
  WebView 页面只消费 `WebViewSettingsPort`，不反向依赖 AppSettings 实现。
- `webview_flutter` 由 `feature_webview` 直接依赖；App Shell 通过公共入口和
  `AppAiWebViewAdapter` 连接 AI 的 `AiWebViewPort`，`feature_ai` 不引用 WebView
  Feature implementation 或 `/src/`。当前稳定版本 `4.14.1` 与 Flutter 3.44.2
  工作区解析兼容，未发生依赖版本冲突，因此没有无关升级。
- Package 测试、App Dart 分析和迁移后的定向测试通过后，Step 19 按
  `refactor(webview): step 19 migrate webview module` 独立提交。

## Step 20 执行记录（2026-08-09）

- 已通过 Git 文件迁移创建 `packages/features/feature_developer/`，将
  Developer Log、Developer Panel、诊断展示、ViewModel、悬浮面板和对应测试
  聚合迁入同一个 Feature Package；原有业务行为保持不变，没有用删除实现
  代替迁移。
- Developer Feature 只依赖公开的 `DeveloperLogPort`、
  `DeveloperSettingsPort` 和 `DeveloperDiagnosticsPort`。AppRuntime 持有
  日志/设置/诊断适配器，向 Feature 提供脱敏快照；Feature 不引用 App Shell
  或其他 Feature implementation，也不控制 App Scope 资源。
- Developer Panel 的帧耗时回调、诊断监听和内存轮询由路由级 ViewModel 持有，
  `dispose()` 会移除监听并取消 Timer；悬浮面板关闭或 Host 销毁时释放自己的
  ViewModel，避免调试页面泄漏资源。
- 依赖解析没有发生版本冲突，因此没有升级无关依赖。Package 测试、App
  分析、格式检查和全量 Flutter 测试均通过；Step 20 按
  `refactor(developer): step 20 migrate developer module` 独立提交。

## Step 21 执行记录（2026-08-09）

- 已收敛 `SshMobileApp` 的 App Shell Provider：根级 `MultiProvider` 只保留
  `AppRuntime` 管理的 App Scope 实例和 Port，不再创建或持有
  `ConnectionViewModel`、`SettingsViewModel` 等 Feature 页面状态。
- 新增 `AppConnectionRouteScope` 负责创建和释放 Connection Route 的
  `ConnectionViewModel`、`ConnectionStrings` 与 UI 适配器。Home Route 共享同一个
  Connection ViewModel 给 Add/Edit 与 SFTP 子路由，保持原有保存后刷新和连接选择行为。
- 各 Feature 公共入口提供纯元数据形式的 Route/Navigation contribution，App Shell
  在 `app/navigation/` 聚合并解释这些贡献。`app_core` 只保存路由描述，不持有
  Widget、ViewModel 或 Module 实例；未新增跨 Package `/src/` 依赖。
- 依赖解析没有发生版本冲突，因此没有升级无关依赖。新增 Route Scope 和路由贡献测试，
  Package 分析、App 分析、格式检查、定向测试及全量 Flutter 测试（861 项）均通过；
  Step 21 按 `refactor(app): step 21 converge app shell` 独立提交。

# 0. 重构目标

将当前单体 Flutter 工程：

```text
lib/
├── core/
├── data/
├── features/
├── services/
├── theme/
├── utils/
├── widgets/
└── main.dart
```

重构为：

```text
ssh_mobile/
├── apps/
│   ├── ssh_mobile_full/
│   └── ssh_mobile_terminal/          # 最后建立，用于验证按需编译
│
├── packages/
│   ├── core/
│   │   ├── app_core/
│   │   ├── app_ui/
│   │   └── connection_core/
│   │
│   ├── infrastructure/
│   │   ├── network_transport/
│   │   ├── ssh_core/
│   │   └── ssh_mobile_network_native/
│   │
│   └── features/
│       ├── feature_connection/
│       ├── feature_terminal/
│       ├── feature_sftp/
│       ├── feature_monitoring/
│       ├── feature_system_admin/
│       ├── feature_lan_share/
│       ├── feature_playbook/
│       ├── feature_rag/
│       ├── feature_mcp/
│       ├── feature_ai/
│       ├── feature_webview/
│       └── feature_developer/
│
├── third_party/
│   └── xterm/
│
├── docs/
├── scripts/
├── pubspec.yaml                       # Dart workspace root and Melos scripts
├── AGENTS.md
└── README.md
```

最终满足：

1. Feature 可独立开发、测试和提交。
2. Feature 禁止直接依赖其他 Feature 的实现。
3. Network、SSH、Log 等共享基础设施全局只有一个运行时实例。
4. 每个 Feature 的数据库由自己的 Module 持有，一个 Module 一个数据库实例。
5. Feature 支持 Lazy Init；没有使用的模块不初始化。
6. 不同 App 的 `pubspec.yaml` 决定实际编译哪些 Feature。
7. 删除当前统一 `AppDatabase` 和 God Object `StorageService`。
8. `main.dart` 只负责启动 App，不再装配所有业务对象。
9. 适合多人或多个 Codex Agent 并行开发。
10. 所有资源都有明确 Owner 和 `dispose/close/cancel/release`。

---

# 1. Codex 执行硬规则

Codex 在执行本 Plan 时必须遵守。

## 1.1 一次只执行一个 Step

禁止跨 Step 顺手重构。

每完成一个 Step：

```bash
dart format .
dart run melos run analyze
dart run melos run test
```

如果该阶段尚未引入 Melos，则运行当前工程已有：

```bash
dart format lib test tool
flutter analyze
flutter test
```

任何验证失败：

> 先修复当前 Step，再执行下一 Step。

---

## 1.2 禁止顺手改变业务行为

模块化阶段只允许：

- 移动代码；
- 调整依赖；
- 拆分职责；
- 生命周期重构；
- 数据库重新分域；
- 注入方式调整；
- 删除开发期旧数据兼容。

除非当前代码因模块边界无法保留，否则不要同时：

- 改 UI；
- 改交互；
- 改 SSH 协议；
- 改 AI Prompt；
- 改业务规则；
- 改网络协议选择策略。

---

## 1.3 文件行数规则

普通手写 Dart 文件：

```text
推荐：80 ~ 250 行
警戒：300 行
需要评估拆分：400 行
原则上禁止：> 500 行
```

以下不受限制：

- `*.g.dart`
- 自动生成文件
- 大型静态字典/国际化生成文件
- 必须保持整体性的协议声明

拆文件标准是“职责”，不是单纯为了行数。

正确：

```text
ssh_session_manager.dart
ssh_session_pool.dart
ssh_session_lease.dart
ssh_runtime_adapter.dart
```

错误：

```text
ssh_service_part1.dart
ssh_service_part2.dart
ssh_service_utils2.dart
```

---

## 1.4 一个文件一个主要职责

允许一个文件包含：

- 一个主要 class；
- 与该 class 强相关的小型 private class/enum；
- 紧密相关的数据结构。

不要把：

```text
Database
Repository
Service
ViewModel
Widget
```

全部放在一个文件。

也不要把一个简单业务对象拆成五六个无意义文件。

---

## 1.5 Public API 最小化

每个 Package：

```text
lib/<package_name>.dart
lib/src/**
```

其他 Package 只能：

```dart
import 'package:feature_terminal/feature_terminal.dart';
```

禁止：

```dart
import 'package:feature_terminal/src/...';
```

Public barrel 只 export 其他模块确实需要使用的 API。

---

## 1.6 Feature 间禁止 Implementation Dependency

禁止：

```text
feature_ai -> feature_sftp
feature_ai -> feature_terminal
feature_monitoring -> feature_connection UI
feature_sftp -> feature_terminal
```

允许：

```text
feature_ai -> app_core capability contracts
feature_terminal -> ssh_core
feature_sftp -> ssh_core
```

跨业务能力由 App Shell 注入接口。

---

## 1.7 资源生命周期规则

任何创建以下对象的代码：

- `Timer`
- `StreamSubscription`
- `StreamController`
- Socket
- SSH Session/Channel
- Drift Database
- Isolate
- Event listener
- FFI/native handle
- file watcher
- background worker

必须在同一个 Owner 或明确上级 Owner 中存在对应：

```text
cancel
close
dispose
release
destroy
```

禁止“创建后依赖 GC 自动处理”。

---

# 2. Scope 与单例规则

只保留“生命周期单例”，不使用到处访问的静态 Singleton。

禁止新增：

```dart
SomeService.instance
```

作为主要依赖获取方式。

---

## 2.1 App Scope

App 生命周期内唯一：

```text
AppRuntime
AppLogger
NetworkRuntime
SshSessionManager
ConnectionRepository
CredentialRepository
AppSettings
ModuleRegistry
```

Owner：

```text
AppRuntime
```

---

## 2.2 Module Scope

模块首次初始化时创建，模块卸载时释放：

```text
TerminalDatabase
TerminalRepository

SftpDatabase
SftpRepository

AiDatabase
AiRepository

PlaybookDatabase
...
```

Owner：

```text
对应 AppModule
```

---

## 2.3 Route Scope

页面进入时创建，页面销毁时释放：

```text
TerminalViewModel
SftpViewModel
AiChatViewModel
```

Owner：

```text
Route / Provider Scope
```

---

# 3. 最终依赖规则

```text
apps
 │
 ▼
App Shell
 │
 ├───────────────┐
 ▼               ▼
Feature A     Feature B
 │               │
 └───────┬───────┘
         ▼
 Core Contracts
         │
         ▼
Infrastructure
         │
         ▼
Native / Platform
```

允许：

```text
apps -> feature_*
apps -> core/*
feature_* -> core/*
feature_* -> infrastructure/ssh_core
feature_lan_share -> infrastructure/network_transport
ssh_core -> network_transport
network_transport -> ssh_mobile_network_native
```

禁止：

```text
core -> feature
infrastructure -> feature
feature -> feature implementation
network_transport -> SSH/UI/Database
ssh_core -> Terminal/SFTP/AI UI
```

---

# 4. Package 划分原则

为了避免过度拆包，本次只建立以下三层。

## Core

### `app_core`

包含：

- AppRuntime contracts
- Module system
- lifecycle/disposable
- logging contract
- capability contracts
- 基础 error/result 类型

不包含业务。

### `app_ui`

包含：

- theme
- 真正跨业务复用 widgets
- responsive helpers
- shared UI primitives

不要把 Feature 专用 Widget 移进去。

### `connection_core`

包含：

- ConnectionProfile / ConnectionTarget
- ConnectionRepository
- CredentialRepository
- HostKey metadata/policy contract
- Connection DB
- Secure credential storage adapter

---

## Infrastructure

### `network_transport`

Flutter/Dart 网络 SDK facade。

### `ssh_core`

共享 SSH Session、Runtime、Pool、Lease。

### `ssh_mobile_network_native`

保留当前 native FFI package；本轮不强制改名。

---

## Feature

保持业务完整性，不把每个 Feature 再横向拆成：

```text
xxx_ui
xxx_domain
xxx_data
```

Package 内部自己分：

```text
lib/src/
├── data/
├── domain/
├── application/
└── presentation/
```

---

# 5. 数据库最终分布

开发阶段不迁移旧数据。

第一次切换新架构后：

> 允许清除 App 数据 / 删除旧 SQLite 文件重新开始。

目标：

```text
connection.db
terminal.db
sftp.db
ai.db
playbook.db
rag.db
mcp.db
lan_share.db
app_log.db（如需要持久化）
```

不需要数据库的模块不要创建数据库。

例如 Monitoring 若只展示实时指标：

```text
不建 monitoring.db
```

---

# 6. Step 00 — 建立重构基线

## 操作

1. 确保当前工作区无未预期修改。
2. 记录当前 commit SHA。
3. 执行：

```bash
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test
```

4. 记录能否构建：

```bash
flutter build apk --debug
flutter build windows
```

只执行当前开发机器支持的平台。

5. 新建：

```text
docs/architecture/MODULAR_REFACTOR_PLAN.md
```

放入本 Plan。

## 完成条件

- 当前 baseline 测试结果已记录。
- 后续失败可以判断是不是重构引入。

---

# 7. Step 01 — 建立 Workspace 目录

## 操作

创建：

```text
apps/
packages/core/
packages/infrastructure/
packages/features/
```

将当前 App 移入：

```text
apps/ssh_mobile_full/
```

移动 App 专属内容：

```text
lib/
test/
android/
ios/
macos/
windows/
web/                 # 若存在
linux/               # 若存在
assets/
tool/                # App 专属 tool
analysis_options.yaml
devtools_options.yaml
.metadata
```

根目录保留：

```text
docs/
scripts/
installer/
packages/
third_party/
.github/
AGENTS.md
README.md
```

当前：

```text
packages/ssh_mobile_network_native
```

移动为：

```text
packages/infrastructure/ssh_mobile_network_native
```

只做路径移动，不改内部 API。

---

## 修改 `apps/ssh_mobile_full/pubspec.yaml`

Path dependency 改成新的相对路径，例如：

```yaml
xterm:
  path: ../../third_party/xterm

ssh_mobile_network_native:
  path: ../../packages/infrastructure/ssh_mobile_network_native
```

---

## 创建根 `pubspec.yaml`

使用 Dart workspace。

Workspace 初始至少包含：

```text
apps/ssh_mobile_full
packages/infrastructure/ssh_mobile_network_native
```

各成员使用 workspace resolution。

---

## 创建 `melos.yaml`

先只定义：

```text
format
analyze
test
```

不要加入复杂 build orchestration。

---

## 更新脚本路径

搜索：

```bash
git grep "flutter build"
git grep "pubspec.yaml"
git grep "lib/main.dart"
git grep "assets/"
```

更新：

```text
scripts/**
.github/workflows/**
installer/**
```

使其指向：

```text
apps/ssh_mobile_full
```

---

## 验证

```bash
dart pub get
cd apps/ssh_mobile_full
flutter analyze
flutter test
flutter build apk --debug
```

## 完成条件

- 项目只是搬家。
- 功能没有变化。
- Root 成为 workspace root。

---

# 8. Step 02 — 建立 `app_core`

创建：

```text
packages/core/app_core/
├── lib/
│   ├── app_core.dart
│   └── src/
│       ├── lifecycle/
│       ├── modules/
│       ├── logging/
│       ├── capability/
│       └── errors/
├── test/
├── README.md
├── AGENTS.md
└── pubspec.yaml
```

---

## 02.1 创建生命周期接口

文件：

```text
src/lifecycle/disposable.dart
src/lifecycle/activatable.dart
src/lifecycle/disposable_bag.dart
```

定义：

```dart
abstract interface class Disposable {
  Future<void> dispose();
}
```

`DisposableBag` 管理：

- StreamSubscription
- Timer
- Disposable callback

不要加入业务代码。

---

## 02.2 创建 Module API

文件：

```text
src/modules/app_module.dart
src/modules/module_context.dart
src/modules/module_descriptor.dart
src/modules/module_registry.dart
src/modules/module_state.dart
```

`AppModule` 统一：

```text
register
initialize
activate
deactivate
dispose
```

初始化必须幂等。

---

## 02.3 ModuleRegistry 只长期持有 Descriptor

永久持有：

```text
id
metadata
factory
route contribution metadata
```

Runtime Module 可 Lazy Create。

不要让 Registry 永久持有所有重型 Runtime。

---

## 02.4 创建 Logging Contract

文件：

```text
src/logging/app_logger.dart
src/logging/log_level.dart
src/logging/log_record.dart
```

只定义接口。

原 `AppLogService` 的实现暂时不移动。

---

## 02.5 创建 Capability 基础接口

只建立机制，不提前定义几十个空接口。

文件：

```text
src/capability/capability_registry.dart
```

具体能力等 AI Step 再增加。

---

## 验证

```bash
dart run melos exec --scope=app_core -- dart analyze .
dart run melos exec --scope=app_core -- dart test
```

## 完成条件

`app_core` 不依赖：

```text
Flutter UI
SSH
Drift
Feature
```

---

# 9. Step 03 — 建立 AppRuntime 与 Composition Root

在：

```text
apps/ssh_mobile_full/lib/app/
```

创建：

```text
app_runtime.dart
app_runtime_factory.dart
app_bootstrap.dart
ssh_mobile_app.dart
```

将原 `main.dart` 缩减。

目标：

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final runtime = await AppRuntimeFactory.create();
  runApp(SshMobileApp(runtime: runtime));
}
```

不要一次移动所有旧 Service。

第一阶段 `AppRuntime` 允许暂时持有当前旧实例，但每个字段标记 TODO，后续 Step 删除。

---

## AppRuntime 必须实现

```text
dispose()
```

销毁顺序：

```text
Modules
→ SSH
→ Network
→ Databases/Repositories
→ Logger
```

不能反向。

---

## 验证

```bash
flutter analyze
flutter test
```

## 完成条件

- `main.dart` 不再直接创建十几个业务 Provider。
- 所有全局实例有唯一 Owner：`AppRuntime`。

---

# 10. Step 04 — 重构全局 Log

当前 `AppLogService` 体积较大，本 Step 只按职责拆，不改日志行为。

创建：

```text
packages/core/app_core/lib/src/logging/
├── app_logger.dart
├── app_logger_impl.dart
├── log_record.dart
├── log_buffer.dart
├── log_sink.dart
└── scoped_logger.dart
```

如日志 DB 较重，可保留：

```text
app_log_store.dart
```

在 App 层或 app_core 实现附近。

---

## 必须实现

```text
AppLogger
    └── scope("terminal")
```

所有 Feature 后续使用 scoped logger：

```text
[terminal]
[sftp]
[ssh]
[network]
[ai]
```

---

## 内存约束

内存 Log 必须使用有界 Ring Buffer。

例如：

```text
maxEntries = 2000
```

禁止无限：

```dart
logs.add(...)
```

---

## 生命周期

`AppRuntime` 创建唯一 Logger。

Feature 不允许：

```dart
AppLogService()
```

---

## 完成条件

搜索：

```bash
git grep "AppLogService()"
```

除 AppRuntimeFactory / 测试外不得创建实例。

---

# 11. Step 05 — 建立 `connection_core`

创建：

```text
packages/core/connection_core/
├── lib/
│   ├── connection_core.dart
│   └── src/
│       ├── model/
│       ├── repository/
│       ├── database/
│       ├── credentials/
│       └── host_key/
```

---

## 05.1 移动 Connection Domain Model

从当前：

```text
lib/features/connection/models/**
```

抽取非 UI 模型到：

```text
connection_core/src/model/
```

例如：

```text
connection_profile.dart
connection_target.dart
connection_id.dart
```

不要把 Screen/ViewModel 移进 core。

---

## 05.2 创建 Repository

文件：

```text
connection_repository.dart
credential_repository.dart
host_key_repository.dart
```

---

## 05.3 创建 `connection.db`

使用 Drift，只保存 Connection 非敏感结构化数据。

文件：

```text
database/connection_database.dart
database/tables/connection_table.dart
database/daos/connection_dao.dart
repository/drift_connection_repository.dart
```

密码、Private Key、Token：

```text
Secure Storage
```

文件：

```text
credentials/secure_credential_repository.dart
```

---

## 05.4 不做旧 DB 迁移

开发机第一次运行新实现：

```text
删除旧 app DB / 清除 App 数据
```

不要写 migration adapter。

---

## 05.5 AppRuntime 注册唯一实例

```text
ConnectionDatabase           1
ConnectionRepository         1
CredentialRepository         1
```

---

## 验证

Connection CRUD 单元测试必须覆盖：

- add
- update
- delete
- reorder/group（若现有支持）
- credential save/read/delete
- host-key metadata

---

# 12. Step 06 — 建立 `feature_connection`

创建：

```text
packages/features/feature_connection/
└── lib/src/
    ├── application/
    ├── presentation/
    └── widgets/
```

移动当前：

```text
lib/features/connection/views/**
lib/features/connection/viewmodels/**
```

Feature 依赖：

```text
connection_core
app_core
app_ui（建立后）
```

Feature 不拥有 Connection DB。

---

## 完成条件

`feature_connection` 只通过：

```text
ConnectionRepository
CredentialRepository
```

访问数据。

---

# 13. Step 07 — 建立 `network_transport`

创建：

```text
packages/infrastructure/network_transport/
├── lib/
│   ├── network_transport.dart
│   └── src/
│       ├── runtime/
│       ├── transport/
│       ├── config/
│       ├── metrics/
│       └── native/
```

依赖现有：

```text
ssh_mobile_network_native
app_core
```

---

## 07.1 第一版只建立稳定 Facade

文件建议：

```text
network_runtime.dart
network_runtime_impl.dart
network_capability.dart
transport_endpoint.dart
transport_connection.dart
network_config.dart
native_network_adapter.dart
```

不要在本 Step 新实现所有：

```text
TCP/UDP/QUIC/WebRTC
```

先包装当前已有 Native 能力。

---

## 07.2 全局实例规则

唯一：

```text
NetworkRuntime
```

由：

```text
AppRuntime
```

创建。

任何 Feature 禁止：

```dart
NetworkRuntimeImpl()
```

---

## 07.3 Lazy Capability

接口允许：

```text
ensureCapability(tcp)
ensureCapability(quic)
...
```

实现必须：

- 幂等；
- 并发共享 init Future；
- 失败后允许 retry；
- dispose 后禁止再次使用或显式重新创建。

---

## 07.4 Native Handle

每个 native handle 必须存在显式：

```text
create -> destroy
open -> close
```

Finalizer 只能兜底。

---

# 14. Step 08 — 建立 `ssh_core`

创建：

```text
packages/infrastructure/ssh_core/
└── lib/src/
    ├── session/
    ├── runtime/
    ├── pool/
    ├── client/
    └── model/
```

迁移当前：

```text
lib/services/ssh_service.dart
lib/services/ssh/**
lib/core/services/ssh_client_factory.dart
lib/core/services/ssh_host_key_policy.dart
相关 remote target / command decoder
```

按职责重写，不保留巨大的单文件 `SshService`。

---

## 推荐文件

```text
ssh_session_manager.dart
ssh_session_manager_impl.dart
ssh_session.dart
ssh_session_lease.dart
ssh_session_pool.dart
ssh_session_metadata.dart
ssh_runtime_adapter.dart
desktop_ssh_runtime.dart
mobile_background_ssh_runtime.dart
ssh_client_factory.dart
ssh_host_key_policy.dart
ssh_command_executor.dart
```

---

## 08.1 移除对 `StorageService` 的依赖

改为依赖：

```text
ConnectionRepository
CredentialRepository
HostKeyRepository
AppLogger
NetworkRuntime（需要时）
```

---

## 08.2 SSH Manager 为 App Scope 单例

由 AppRuntime 创建：

```text
SshSessionManager 1 instance
```

Feature 只能获取接口。

---

## 08.3 Session 资源模型

实现：

```text
acquire
release
idle timeout
```

最少保证：

- Feature 不可直接关闭共享 Session；
- refCount 为 0 后可回收；
- Timer 被取消；
- StreamController 被 close；
- Subscription 被 cancel。

---

## 08.4 移动端 Background Service

平台差异放：

```text
SshRuntimeAdapter
```

Feature 中禁止：

```text
Platform.isAndroid
flutter_background_service
```

---

## 验证

至少测试：

- concurrent `ensureInitialized`
- acquire/release
- multiple consumer
- idle cleanup
- initialization failure retry
- dispose idempotent

---

# 15. Step 09 — 建立 `app_ui`

创建：

```text
packages/core/app_ui/
```

迁移真正共享的：

```text
theme/**
utils/responsive.dart
widgets/ 中跨 Feature widget
```

不要机械移动整个 `widgets/`。

判断规则：

> 被至少两个独立 Feature 实际使用，且不含某个 Feature 业务语义，才进入 `app_ui`。

其他 Widget 随 Feature 移走。

---

# 16. Step 10 — Terminal 作为第一个完整 Pilot

创建：

```text
packages/features/feature_terminal/
├── lib/
│   ├── feature_terminal.dart
│   └── src/
│       ├── data/
│       ├── domain/
│       ├── application/
│       └── presentation/
```

移动当前：

```text
lib/features/terminal/**
lib/services/terminal_history_service.dart
Terminal 专用 widget/model/service
```

---

## 10.1 建 `terminal.db`

包含：

```text
terminal_history
restorable_terminal_session metadata（若确实属于 Terminal）
```

文件：

```text
data/database/terminal_database.dart
data/database/tables/terminal_history_table.dart
data/database/daos/terminal_history_dao.dart
data/repository/terminal_history_repository_impl.dart
```

---

## 10.2 Terminal Module

创建：

```text
terminal_module.dart
```

职责：

```text
initialize:
  open terminal.db
  create repositories

activate:
  只启动当前需要的 route/runtime

deactivate:
  停止 route-independent timer/stream（如果有）

dispose:
  cancel subscriptions
  release SSH lease
  close DB
```

---

## 10.3 Terminal 不创建 SSH

禁止：

```dart
SshService(...)
SshSessionManagerImpl(...)
```

只能注入：

```text
SshSessionManager
```

---

## 10.4 ViewModel Route Scope

Terminal ViewModel 不放到根 `MultiProvider`。

在 Terminal Route 创建：

```text
ChangeNotifierProvider(create: ...)
```

页面销毁后自动 dispose。

---

## 10.5 文件尺寸检查

重点检查原 Terminal 大文件。

按职责拆：

```text
terminal_view_model.dart
terminal_session_controller.dart
terminal_input_controller.dart
terminal_history_controller.dart
```

只有在职责确实独立时拆。

不要做：

```text
terminal_view_model_part1.dart
```

---

## 完成条件

搜索：

```bash
git grep "features/terminal" apps/ssh_mobile_full/lib
```

App Shell 只能引用 Package Public API，不引用旧路径。

---

# 17. Step 11 — SFTP 模块

创建：

```text
packages/features/feature_sftp/
```

移动：

```text
lib/features/sftp/**
lib/services/sftp_service.dart 中 SFTP 业务逻辑
```

---

## 11.1 SFTP 使用共享 SSH

依赖：

```text
SshSessionManager
```

SFTP 可以创建自己的 SFTP Channel/operation context，但不能创建自己的全局 SSH manager。

---

## 11.2 建 `sftp.db`

只保存：

```text
recent paths
favorite paths
transfer metadata（如有必要）
```

不要保存密码。

---

## 11.3 生命周期

传输任务必须有明确 Owner。

页面关闭时：

- UI subscription 取消；
- 是否取消传输由业务策略决定；
- 若允许后台传输，TransferManager 属于 Module Scope；
- 完成后清理 Stream/handle/temp file。

---

# 18. Step 12 — Monitoring 模块

将：

```text
lib/features/performance/**
PerformanceMonitorService
server diagnostics 中纯监控能力
```

整理到：

```text
packages/features/feature_monitoring/
```

不要因为现有目录不同而拆成多个过小 package。

---

## 12.1 不默认创建数据库

如果当前只是实时监控：

```text
不创建 monitoring.db
```

以后确实需要历史趋势再新增。

---

## 12.2 Timer 生命周期

```text
initialize -> 创建 service
activate   -> 启动 polling
deactivate -> cancel polling
dispose    -> cancel all stream/subscription
```

禁止 App 启动即永久 polling。

---

## 12.3 请求优先级

Monitoring 使用 SSH 时标记低优先级。

不要与交互 Terminal 抢占相同调度优先级。

---

# 19. Step 13 — System Admin 模块

创建：

```text
packages/features/feature_system_admin/
```

迁移：

```text
lib/features/system_admin/**
lib/services/system_admin_service.dart
相关 server admin service
```

依赖：

```text
ssh_core
connection_core
app_core
app_ui
```

禁止依赖：

```text
feature_terminal
feature_monitoring implementation
```

如果需要监控数据，定义小型 Capability contract。

---

# 20. Step 14 — LAN Share 模块

创建：

```text
packages/features/feature_lan_share/
```

迁移：

```text
lib/features/lan_share/**
LAN receiver/discovery/pairing/transfer services
```

依赖：

```text
network_transport
app_core
app_ui
```

不要依赖 SSH。

---

## 14.1 建 `lan_share.db`

仅保存：

```text
transfer history
pairing metadata（非 secret）
```

---

## 14.2 Background Receiver

如果 LAN Receiver 必须常驻：

由 App 配置决定是否 activate。

不要因为 Module 被编译就自动启动。

---

# 21. Step 15 — Playbook 模块

创建：

```text
packages/features/feature_playbook/
```

迁移：

```text
lib/features/playbook/**
lib/services/playbook_service.dart
playbook repository
```

建：

```text
playbook.db
```

保存：

```text
playbooks
playbook_runs
playbook_run_steps
```

---

## 安全

保留当前：

- destructive command restriction；
- approval；
- target binding；
- secret filtering。

安全规则不要散落在 UI。

---

# 22. Step 16 — RAG 模块

创建：

```text
packages/features/feature_rag/
```

迁移：

```text
lib/features/rag/**
lib/services/rag_service.dart
```

建：

```text
rag.db
```

只存：

- document/index metadata；
- 必要缓存索引信息。

大型向量/文件缓存必须有：

```text
size limit
TTL / eviction policy
```

---

# 23. Step 17 — MCP 模块

创建：

```text
packages/features/feature_mcp/
```

迁移：

```text
lib/features/mcp_console/**
lib/services/mcp/**
MCP activity repository
```

建：

```text
mcp.db
```

危险 Tool 的：

```text
approval_required
```

必须保留在执行层，不只存在于 UI。

---

# 24. Step 18 — AI 模块

AI 相关高度耦合，保持为一个较大的业务 Package，避免过度拆分。

创建：

```text
packages/features/feature_ai/
```

内部：

```text
lib/src/
├── chat/
├── agent/
├── skills/
├── llm/
├── tools/
├── data/
└── presentation/
```

迁移：

```text
lib/features/ai_chat/**
lib/features/ai_skills/**
lib/services/agent/**
lib/services/ai_tool/**
lib/services/ai_tool_service.dart
lib/services/chat_*
LLM provider/runtime 相关
agent model/profile
```

---

## 18.1 AI 仍按业务子域拆文件

不要重新生成一个：

```text
ai_service.dart 3000 行
```

建议：

```text
chat/
agent/
tools/
llm/
```

但这些是同一个 `feature_ai` package，不继续拆成大量 package。

---

## 18.2 建 `ai.db`

统一 AI 自有数据：

```text
chat sessions
messages
agent runs
agent metrics
agent trace
```

不要为每张表单独建 DB。

---

## 18.3 AI 不直接依赖其他 Feature Implementation

在 `app_core` 增加实际需要的 capability：

```text
RemoteCommandCapability
FileTransferCapability
MonitoringCapability
PlaybookCapability
RagCapability
McpCapability
```

注意：

> 只有 AI 真正使用的能力才新增接口。

由 App Composition Root 注入实现。

---

## 18.4 AI Runtime Lazy Init

只有用户进入 AI 或明确启动 AI 请求时：

```text
open ai.db
create provider/runtime
create tool registry
```

未使用 AI：

```text
不初始化
```

---

# 25. Step 19 — WebView 模块

创建：

```text
packages/features/feature_webview/
```

迁移：

```text
lib/features/client_webview/**
lib/services/client_webview/**
```

让：

```text
webview_flutter
```

成为该 Feature 的直接依赖。

Terminal-only App 不依赖这个 package，因此不会因为 App Shell 引入 WebView。

---

# 26. Step 20 — Developer 模块

将：

```text
developer_log
developer_panel
diagnostics UI
```

聚合：

```text
packages/features/feature_developer/
```

不要继续拆成多个 package。

该模块只能观察 Core/Feature 暴露的 diagnostics contract。

禁止为了 Developer Panel 让 Core 持有 Widget/ViewModel。

---

# 27. Step 21 — 收敛 App Shell

保留在：

```text
apps/ssh_mobile_full/lib/app/
```

主要包含：

```text
main.dart
app_runtime.dart
app_runtime_factory.dart
app_bootstrap.dart
ssh_mobile_app.dart
navigation/
home/
startup/
settings/
```

`home/startup/settings` 属于产品 Shell，不强制拆 Package。

---

## 21.1 Root Provider 只放 App Scope

允许：

```text
AppRuntime
AppLogger
NetworkRuntime
SshSessionManager
ConnectionRepository
CredentialRepository
AppSettings
ModuleRegistry
```

禁止：

```text
TerminalViewModel
SftpViewModel
AiChatViewModel
PerformanceViewModel
```

Feature ViewModel 在自己的 Route Scope 创建。

---

## 21.2 路由贡献

Feature 公共 API 提供 Route/Navigation contribution。

App Shell 统一聚合。

App Shell 不直接 import：

```text
feature_xxx/src/...
```

---

# 28. Step 22 — 删除统一 `StorageService`

此时所有 Feature 必须已经拥有自己的 Repository。

执行搜索：

```bash
git grep "StorageService"
```

逐个清除剩余调用。

然后删除：

```text
旧 lib/services/storage_service.dart
lib/services/storage/**
旧 data/repositories 中已迁移实现
```

如果 Backup 仍依赖 StorageService，本 Step 暂时先移除/重写开发期 Backup，不做旧格式兼容。

> Step22 已于 2026-08-09 完成：生产 Dart 代码不再引用统一 `StorageService`。
> AI、Connection、Playbook、Terminal 元数据及 SFTP 路径分别通过独立
> Repository/Owner 访问；App Shell 只保留注入适配器。Step23 继续处理旧
> `AppDatabase`，不得在本 Step 中提前删除它。

---

## 完成条件

```bash
git grep "StorageService"
```

只允许文档历史说明，生产 Dart 代码为 0。

---

# 29. Step 23 — 删除统一 `AppDatabase`

执行：

```bash
git grep "AppDatabase"
```

确认所有业务表都已归属 Feature/Core DB。

删除：

```text
旧 lib/data/database/app_database.dart
旧 app_database.g.dart
旧 tables/**
旧 daos/**
```

清除：

```text
drift_dev/build_runner
```

只能从真正使用 Drift 的 Package 自己声明。

---

## 完成条件

不存在全局业务 `AppDatabase`。

> Step23 已于 2026-08-09 完成：旧 `AppDatabase`、生成文件、旧 tables/daos
> 和 App 数据库连接入口已移除。Terminal/Playbook/SFTP/LAN/AI 等结构化数据
> 由各自 Feature/Core Module 持有；App 日志保留原队列行为但改由独立
> `AppLogDatabase`（`app_logs`）承载。App Shell 因仍实际使用该 Drift 数据库，
> 保留自身的 `drift`、`drift_dev` 和 `build_runner` 声明。生产和测试 Dart
> 不再引用 `AppDatabase`。

---

# 30. Step 24 — 删除旧根 `lib/services` 杂物

逐文件分类。

规则：

```text
属于业务 -> 对应 feature
属于 SSH -> ssh_core
属于 Network -> network_transport
属于 Connection -> connection_core
属于 App 基础设施 -> app_core/app shell
没有使用 -> 删除
```

禁止新建：

```text
packages/core/common_services/
```

把所有剩余东西重新堆进去。

## Step 24 执行记录（2026-08-09）

- 已逐文件审计 `apps/ssh_mobile_full/lib/services/`。App Scope 日志、设置、
  启动、生命周期、显示模式、原生内存和快捷键服务保留在 App Shell；AI、
  Connection、Remote Target、客户端系统工具和诊断服务只作为 App Port/Feature
  适配器，不拥有 Feature 数据库。
- SSH/SFTP、Monitoring、System Admin、Playbook、RAG、Terminal 和 LAN 的真实
  实现/Module 已分别归属 `ssh_core` 或对应 Feature；仍被旧 App 页面、App
  Runtime 或测试使用的旧入口保留为非 Owner 兼容桥。`network/**`、`relay/**`
  和 LAN 旧协议适配同理：`network_transport` 当前只提供 Network Protocol V2 Runtime/
  Handle Facade，本 Step 不复制或重写协议实现。
- 删除仓库生产代码和测试均无引用的三个旧 AI 导出入口：
  `agent_model_profile.dart`、`llm_provider/llm_api_format.dart`、
  `multi_agent_coordinator.dart`。`tool_secret_policy.dart` 虽无完整路径引用，
  但仍被旧 App Service 通过相对路径使用，因此保留为 `feature_ai` 的兼容导出。
  `part of`、条件
  导出和旧调用面引用的文件没有被误判为无用而删除。完整分类见
  `apps/ssh_mobile_full/lib/services/README.md`。
- 本 Step 未批量删除仍在使用的业务代码；后续只有在补齐对应公共
  Contract/Capability 并迁移调用方后，才能继续删除兼容桥。

---

# 31. Step 25 — 清理依赖

从：

```text
apps/ssh_mobile_full/pubspec.yaml
```

移除所有已经由 Feature/Core 自己声明的第三方依赖。

目标：

App Full 主要依赖：

```text
Flutter
Provider
app_core
app_ui
connection_core
network_transport / ssh_core（如果 AppRuntime 直接创建）
feature_*
```

例如：

```text
webview_flutter
drift
mobile_scanner
fl_chart
```

应由真正需要它们的 Package 声明，而不是 App 全局声明。

## Step 25 执行记录（2026-08-09）

- 已按 App `lib/`、`test/`、`tool/` 的直接 import 审计
  `apps/ssh_mobile_full/pubspec.yaml`，而不是按 workspace lockfile 中的传递依赖
  机械删除。
- 移除 App Full 不再直接使用、且已由 owning Package 声明的依赖：`xterm`、
  `intl`、`flutter_animate`、`http`、`archive` 和 `wakelock_plus`。AppLog 的
  `drift`/`drift_flutter` 仍由 App Shell 的 `AppLogDatabase` 实际使用；旧兼容
  页面直接导入的 `webview_flutter`、`fl_chart`、`mobile_scanner` 等暂时保留。
- `flutter pub get` 通过，并只清理了由 `wakelock_plus` 带入的无用传递依赖及
  macOS 生成插件注册；当前提示的可升级项不构成版本冲突，因此没有升级无关
  依赖。App/Feature 的依赖 Owner 记录同步到 README、AGENTS、Skill 和 Agent
  memory。

---

# 32. Step 26 — 建立 Terminal-only App

复制最小 App Shell，而不是复制业务代码。

创建：

```text
apps/ssh_mobile_terminal/
```

`pubspec.yaml` 只依赖：

```text
app_core
app_ui
connection_core
network_transport
ssh_core
feature_connection
feature_terminal
```

不要依赖：

```text
feature_ai
feature_rag
feature_mcp
feature_webview
feature_lan_share
feature_sftp
```

---

## 验证编译裁剪

运行：

```bash
cd apps/ssh_mobile_terminal
flutter pub deps
```

检查不存在不需要的 Feature。

运行 App 后检查：

```text
不创建 ai.db
不创建 sftp.db
不初始化 AI
不注册 AI route
```

## Step 26 执行记录（2026-08-09）

- 已将 `apps/ssh_mobile_terminal/` 加入 Dart workspace 和 Melos，并创建最小
  Flutter App Shell。当时其生产依赖包括 `feature_connection`；Step32 的最终
  依赖审计确认该 App 没有导入该 Feature 公共 API，已移除这条无效依赖。当前
  依赖严格限制为 `app_core`、`app_ui`、`connection_core`、`network_transport`、
  `ssh_core` 和 `feature_terminal`；`flutter pub deps` 的 App 节点未包含 AI、
  RAG、MCP、WebView、LAN Share 或 SFTP。
- 为避免精简 App 反向依赖 Provider 实现，`feature_terminal` 公共入口新增
  `TerminalFeatureScope`，由 Feature 自己组合公开 Port；App 只注入
  `SshSessionManager`、Terminal Port 和 `terminal.db` 历史 Repository，不拥有
  Feature Scope 内部 Provider 的实现细节。
- Terminal-only Runtime 只创建该切片需要的 Connection、Network、SSH、日志和
  `TerminalModule` 资源，并按 Module → SSH Capability → SSH Manager → Network →
  Database → Port → Logger 顺序释放。没有复制 Full App 的仍在使用的
  `SshService` 兼容业务实现，也没有创建第二个 SSH Owner；当前切片使用安全的
  空 Terminal Capability 作为编译/生命周期探针，真实 SSH 兼容后端继续由 Full
  App 持有，待后续 SSH 方法迁移完成后再接入。
- 已补充 Runtime 幂等释放和 Feature Scope 注入测试；Terminal-only App 与
  `feature_terminal` 的 analyze/test、Windows Debug 构建及格式检查通过。

## Step 27 执行记录（2026-08-09）

- `feature_developer` 新增只读 `DeveloperDiagnosticsSnapshot` Contract 和
  Lifecycle Diagnostics 卡片，展示 Modules 的 initialized/active 状态、SSH
  active/idle sessions 与 Lease、Network active connections/native handles、
  已知数据库打开状态，以及已接入 Owner 的 Timer/Stream subscription 数量。
  旧的 Component Activity 卡片和原有面板行为保留；Feature 仍只依赖公共
  diagnostics Port，不引用 App Shell 或其他 Feature implementation。
- `NetworkRuntime.diagnostics` 和 `SshSessionPool.idleTimerCount` 补充为公共
  只读观察契约；Network Facade 当前不拥有具体协议连接，因此 active connection
  保持为其直接登记值（当前为零），不会为填充 UI 越权接管 LAN/Feature 连接。
  App Shell 适配器动态读取 Module/数据库状态，并将 AppLog、SSH Pool、监控
  Timer 与已知订阅汇总成脱敏快照。
- Debug 模式新增可观测资源断言：Developer Panel ViewModel 释放帧回调、监听
  和内存 Timer 后自检；AppRuntime 在 Module dispose、SSH Manager、Network
  Runtime 和 Developer 适配器释放后检查对应的 disposed/零资源状态。不能被
  当前 Owner 直接枚举的 legacy Timer/Stream 不被伪装成全局精确计数。
- 新增 diagnostics 模型/页面、NetworkRuntime/SSH Pool 生命周期测试和面板
  Widget 测试；未发生依赖版本冲突，因此没有升级无关依赖。
- 验证通过：`feature_developer` 测试 10 项、`network_transport` 测试 4 项、
  `ssh_core` 测试 7 项、LAN Share 定向测试 10 项、Terminal-only App 测试 2
  项；Full App 全量 Flutter 测试 857 项通过，Dart analyze 无错误。

---

# 33. Step 27 — 建立内存泄漏与生命周期检查

在 `feature_developer` 增加 Diagnostics 页面。

只读取 diagnostics contract，展示至少：

```text
Modules:
  initialized
  active

SSH:
  active sessions
  idle sessions
  lease count

Network:
  active connections
  native handles

Databases:
  opened modules

Timers:
  known active timers

Streams:
  known subscriptions
```

---

## 27.1 Debug Assertion

在 debug 模式：

Module dispose 后检查：

```text
subscription count == 0
owned timer count == 0
owned native handle count == 0
```

能够检查的资源应尽量自动检查。

---

# 34. Step 28 — 建立架构守卫

创建：

```text
tool/architecture_check.dart
```

CI 必须检查。

---

## 禁止规则

### Feature -> Feature Implementation

禁止某个：

```text
packages/features/feature_a
```

import：

```text
package:feature_b/
```

例外只允许经过明确 Architecture Allowlist，默认空。

---

### 禁止跨包 `/src/`

禁止：

```text
package:any_package/src/
```

出现在其他 package。

---

### 禁止 Feature 创建 Core Impl

Feature 中禁止：

```text
NetworkRuntimeImpl(
SshSessionManagerImpl(
```

---

### 禁止 static service locator

禁止新增类似：

```text
Service.instance
Global.xxx
GetIt.I
```

除非经过架构 ADR 明确批准。

---

### 禁止旧 Service

检查：

```text
StorageService
AppDatabase
```

不得重新出现。

---

## Step 28 执行记录（2026-08-09）

- 新增根目录 `tool/architecture_check.dart`，扫描 workspace 的 App/Package
  Dart 源文件，守卫 Feature-to-Feature 依赖、跨 Package `/src/` 导入、Feature
  创建 `NetworkRuntimeImpl`/`SshSessionManagerImpl`、新增静态 Service locator，
  以及 `StorageService`/`AppDatabase` 旧标识重新出现。
- 架构例外集中在脚本内的显式 Allowlist：当前只允许 AI 通过
  `feature_playbook` 公共入口使用 `PlaybookAutomationPort`，以及既有兼容层的
  已审计单例名称；禁止通过宽泛目录例外掩盖新增违规。当前 workspace 不需要
  修改现有业务实现即可通过守卫。
- 新增无外部依赖的架构守卫回归测试，覆盖当前 workspace 基线和四类禁止边界；
  GitHub Actions 在根 workspace 依赖安装后执行该守卫。
- 验证通过：架构守卫测试、`dart analyze`、架构守卫本身和格式检查均通过；
  未发生依赖版本冲突，因此没有升级无关依赖。

---

# 35. Step 29 — README / AGENTS 标准化

每个 Package 必须：

```text
README.md
AGENTS.md
pubspec.yaml
lib/
test/
```

有用户可见变更记录需求的 package 再加：

```text
CHANGELOG.md
```

不要为了形式所有内部 package 都维护冗长 CHANGELOG。

---

## README 固定内容

控制在简洁范围：

```text
职责
不负责什么
Public API
依赖
数据库
生命周期
资源 Owner
测试命令
```

---

## AGENTS 固定内容

```text
允许修改范围
禁止依赖
Public API 修改要求
数据库约束
资源释放规则
必须运行的测试
```

---

## Step 29 执行记录（2026-08-09）

- 审计当前 Workspace Member，确认每个维护成员都具备 `README.md`、
  `AGENTS.md`、`pubspec.yaml`、`lib/` 和 `test/`；不把非 Workspace 的
  `example/` 工程误纳入标准化范围。
- 为缺失文档的 App/Package 补充职责、边界、Public API、依赖、数据库、
  生命周期与资源 Owner、测试命令，以及允许修改范围、禁止依赖、Public API
  修改要求、数据库约束、资源释放规则和必须运行的测试。既有文档统一补齐
  `Package contract`，并同步维护中文更新时间标记。
- 本 Step 仅修改模块协作文档，没有新增代码、数据库或依赖版本；没有为内部
  Package 机械创建 `CHANGELOG.md`，因为本次变更不包含用户可见功能发布说明。
- 已同步根 `AGENTS.md`、双语 README、`AGENT_MEMORY.md` 和维护 Skill，保证
  后续 Package 变更以本地合同文档为边界；外部执行 Plan 同步记录相同结论。

---

# 36. Step 30 — CI 调整为模块级

PR 修改某 Feature 时优先运行对应 Package：

```text
format
analyze
unit test
```

同时运行：

```text
architecture_check
```

Main / 合并前运行：

```text
melos run analyze
melos run test
Full App smoke build
Terminal App smoke build
```

---

## Step 30 执行记录（2026-08-10）

- 按 Melos 8 官方配置方式，将 `format`、`analyze`、`test` Workspace Script
  迁移到根 `pubspec.yaml` 的 `melos` 节点；删除旧的重复 `melos.yaml` 配置源，
  不涉及业务代码、Feature 实现或运行时行为。
- PR CI 新增差异包门禁：使用 `melos exec --diff` 检查变更 Package 及其依赖方的
  format、analyze 和 unit test，并单独运行 `tool/architecture_check.dart`。
- main CI 新增全 Workspace 的 Melos format/analyze/test，Full App Android
  debug APK 冒烟构建和 Terminal-only Windows debug 冒烟构建；Workspace 清单
  包含 AI、MCP 在内的全部维护成员。
- 新增无外部依赖的 CI 合同测试，固定 Workflow Job、Melos 脚本、diff 过滤和
  两个冒烟构建入口。`dart pub get` 通过且锁定版本未变化；输出的可升级版本均
  受现有约束限制，未发生需要升级的依赖冲突。

---

# 37. Step 31 — 文件尺寸治理

执行脚本统计：

```text
所有非 generated Dart 文件行数
```

输出：

```text
>300
>400
>500
```

按职责处理。

优先检查当前已知大型区域：

```text
AI tool loop
AI stream handler
system prompt
App settings
App strings
logging
SSH
Storage 残留
```

---

## 拆分原则

例如一个 700 行 ViewModel：

如果同时负责：

```text
history
streaming
generation
message action
approval
```

则拆为：

```text
ai_chat_view_model.dart
chat_history_controller.dart
chat_generation_controller.dart
chat_approval_controller.dart
```

如果 350 行代码只是一个连贯 parser：

> 可以保留，不要为了数字强拆。

---

## Step 31 执行记录（2026-08-10）

- 新增根级 `tool/check_file_sizes.dart` 和
  `test/tool/file_size_report_test.dart`。脚本扫描 `apps/`、`packages/`、
  `tool/`、`test/` 下的非 generated Dart 文件，排除构建产物、缓存和
  vendored 第三方代码，并输出三个复核档位：`>300`、`>400`、`>500`。
- 本次基线报告包含 939 个文件，其中 `>300` 为 261 个、`>400` 为 187 个、
  `>500` 为 131 个。尺寸报告是职责审计工具，不把既有兼容桥、测试 Fixture
  或连贯 parser 机械拆成无意义的小文件。
- 对职责边界清晰且风险低的共享主题进行了最小拆分：
  `app_theme.dart` 保留 `AppTheme` 公共组合入口（215 行），
  `app_theme_variants.dart` 承载浅色/深色主题变体（309 行），
  `app_theme_components.dart` 承载控件级构建器（494 行）。三个 part
  仍属于同一个私有 library，`AppTheme` 公共 API、颜色和主题行为保持不变。
- 已同步 `app_ui` 的 README/AGENTS、根 README、`AGENTS.md`、
  `AGENT_MEMORY.md` 和维护 Skill，记录尺寸阈值、脚本入口和“按职责拆分”
  约束；未修改 AI tool loop、stream handler、系统管理、SSH/Storage 等
  其他大型区域，避免扩大 Step31 的行为变更范围。
- 验证通过：根 `dart format --output=none --set-exit-if-changed`、纯 Dart
  analyzer、尺寸报告测试、`app_ui` Flutter analyze/test（14 项）、Full App
  Flutter test（857 项）。Full App 严格 analyzer 仅有既有 41 条 `info` 级 lint，
  使用 `--no-fatal-infos` 通过；本 Step 未顺带修改这些基线提示。

# 38. Step 32 — 最终依赖审计

对每个 Package 逐个检查：

```text
谁依赖它？
它依赖谁？
是否真的需要？
```

最终绘制：

```text
docs/architecture/MODULE_DEPENDENCY.md
```

---

## 必须满足

```text
无 Feature 循环依赖
无 Core -> Feature
无 Infrastructure -> Feature
无跨包 src import
```

---

## Step 32 执行记录（2026-08-10）

- 新增 `tool/check_module_dependencies.dart`、模型文件和
  `test/tool/module_dependency_check_test.dart`，从根 workspace 清单读取
  20 个成员及直接生产依赖；新增 `docs/architecture/MODULE_DEPENDENCY.md`
  记录层级图、Package 依赖表和维护规则。
- 审计得到 63 条内部生产依赖边；当前没有 Feature-to-Feature 违规、
  Core/Infrastructure -> Feature 反向依赖或依赖循环。唯一显式例外是
  `feature_ai -> feature_playbook`，调用面为公开 `PlaybookAutomationPort`。
- 逐项核对源码使用后移除两条无效 manifest 边：
  `feature_monitoring -> app_ui` 和
  `ssh_mobile_terminal -> feature_connection`；未升级无关依赖版本。
- `tool/architecture_check.dart` 继续负责跨包 `/src/` 导入检查，避免两个
  工具重复解析源码；根 AGENTS、README、维护 Skill 和 Agent memory 已同步。
- 验证通过：`dart pub get`；依赖审计/回归测试、架构守卫、纯 Dart
  analyzer、格式检查、文件尺寸报告测试、`git diff --check` 和 Skill 同步检查；
  Monitoring Package analyze/test（2 项）、Terminal-only App analyze/test（3 项）
  通过；`ssh_mobile_terminal` 自身 `pub deps` 节点不再包含
  `feature_connection`；Full App analyze 使用 `--no-fatal-infos` 通过（既有 41
  条 info），完整 Flutter 测试 857 项通过。

# 39. Step 33 — 最终资源 Owner 审计

建立表：

| Resource | Owner | Scope | Release |
|---|---|---|---|
| AppLogger / AppLogDatabase | AppRuntime / AppLogService | App | flush, close, dispose last |
| NetworkRuntime / Native handle | AppRuntime / native adapter | App/Native | stop, destroy, dispose |
| SshSessionManager / SSH Session | AppRuntime / Session Pool | App/Lease | release lease, idle close, manager close |
| ConnectionDatabase | AppRuntime / Connection Core | App | await init, then close |
| TerminalDatabase | AppTerminalModuleScope / TerminalModule | Route Module | Module dispose, close DB |
| SftpDatabase | AppSftpModuleScope / SftpModule | Route Module | Module dispose, close DB |
| AiDatabase / PlaybookDatabase | AppRuntime / corresponding Module | App Module | Service dispose, then DB close |
| RagDatabase / McpDatabase / LanShareDatabase | AppRuntime / corresponding Module | App Module | stop Service/Receiver, then DB close |
| MonitoringService | AppRuntime / MonitoringModule | App | stop polling, cancel, dispose |
| SystemAdminService | AppSystemAdminModuleScope / SystemAdminModule | Route Module | cancel commands, dispose |
| SFTP compatibility service | AppRuntime / legacy SftpService | App | dispose after Route Modules stop |
| WebViewService / AI chat runtime | AppRuntime / Route Provider | App/Route | cancel sessions/streams, dispose |
| ViewModel / Route Controller | Route Provider / Widget State | Route/Widget | dispose |
| Timer / Subscription / StreamController | owning Module, Service, or Controller | Owner scope | cancel or close before Owner release |
| Isolate | launching parser/transfer/native Owner | Task/Owner scope | stop or kill, await exit |

完整 29 条资源记录和自动检查见 `docs/architecture/RESOURCE_OWNERSHIP.md`。

任何无法填 Owner 的对象：

> 不允许完成重构。

---

## Step 33 执行记录（2026-08-10）

- 新增 `docs/architecture/RESOURCE_OWNERSHIP.md`，逐项记录 AppLogger、AppLog
  Database、AppSettings、Connection/SSH/Network、Feature 数据库、Module/Service、
  WebView、AI Route runtime、ViewModel、Controller、Timer、Subscription、
  StreamController 和 Isolate 的 Owner、Scope 与 Release 动作。
- 根据实际代码校正 Owner：AppRuntime 持有 App Scope Modules 和基础设施；
  `AppTerminalModuleScope`、`AppSftpModuleScope`、`AppSystemAdminModuleScope`
  分别持有对应 Route Module；Feature Repository 不关闭 Module 数据库，
  Lease 使用方不关闭共享 SSH Session。
- 新增 `tool/check_resource_owners.dart` 与
  `test/tool/resource_owner_check_test.dart`，当前表包含 29 条记录，覆盖 27
  个关键资源；缺少 Owner、Scope、Release 或出现占位符时检查失败。
- 已同步根 README（中英文）、AGENTS、Agent memory、维护 Skill 和外部执行
  Plan；未修改业务代码或资源生命周期实现。

# 40. Step 34 — 最终验收

执行：

```bash
dart format --output=none --set-exit-if-changed .
dart run tool/architecture_check.dart
dart run melos run analyze
dart run melos run test
```

构建：

```bash
cd apps/ssh_mobile_full
flutter build apk --debug
```

以及：

```bash
cd apps/ssh_mobile_terminal
flutter build apk --debug
```

如果当前机器支持 Windows：

```bash
flutter build windows
```

---

## Step 34 执行记录（2026-08-10）

- 根 `dart format --output=none --set-exit-if-changed .` 通过，最终检查覆盖
  1065 个 Dart 文件；Step34 只补齐了既有
  `packages/features/feature_system_admin/lib/src/presentation/views/system_admin_server_pane.dart`
  的 formatter 排版，不改变业务行为。
- `dart run tool/architecture_check.dart` 通过；根 `pubspec.yaml` 的 Melos
  analyze 脚本明确使用 `flutter analyze --no-fatal-infos --no-pub`，因此 Full App
  既有 41 条 `info` 级 lint 会显示但不会阻断，error/warning 仍然阻断。
- `dart run melos run analyze` 通过，20 个 Workspace Member 全部成功；
  `dart run melos run test` 通过，Full App 857 项以及其他 Workspace Member
  测试全部成功。
- 构建验收通过：`apps/ssh_mobile_full` Android Debug APK、
  `apps/ssh_mobile_terminal` Android Debug APK，以及 Terminal-only Windows
  构建；Windows 设备可用。Terminal-only APK 首次下载 Android Lint 依赖时
  出现一次 Maven TLS handshake 失败，Flutter 自动重试后成功，未修改依赖版本。
- 已同步根 `AGENTS.md`、双语 README、维护 Skill、Agent memory 和外部执行
  Plan；Step34 没有修改业务规则、协议、网络策略、SSH 行为或 AI Prompt。

---

# 41. 最终 Definition of Done

全部满足才算重构完成。

## 模块

- [x] 每个主要 Feature 为独立 Package。
- [x] Feature 之间无实现依赖。
- [x] Package Public API 最小。
- [x] 每个 Package 有 README / AGENTS。
- [x] 不存在无意义的碎片 package。

## App

- [x] `main.dart` 只做启动。
- [x] `AppRuntime` 是全局资源唯一 Owner。
- [x] Root Provider 不持有 Feature ViewModel。
- [x] Route/导航由 Module contribution 聚合。

## Network / SSH

- [x] NetworkRuntime 全局一个实例。
- [x] SshSessionManager 全局一个实例。
- [x] Feature 不自行 new 网络/SSH实现。
- [x] SSH Session 支持 lease/release。
- [x] Idle Session 会回收。
- [x] Native handles 明确 destroy。

## Database

- [x] 删除统一 AppDatabase。
- [x] 删除 StorageService。
- [x] Connection 使用独立 DB/Secure Storage。
- [x] Terminal/SFTP/AI/Playbook/RAG/MCP/LAN 数据各归属自己的 Module。
- [x] 一个 Module 生命周期内同类 DB 只有一个实例。
- [x] 不做旧开发数据兼容。

## 生命周期

- [x] Module Lazy Init。
- [x] initialize 幂等。
- [x] init 并发安全。
- [x] init 失败可以 retry。
- [x] Timer 全部 cancel。
- [x] Subscription 全部 cancel。
- [x] StreamController 全部 close。
- [x] Database 全部 close。
- [x] SSH lease 全部 release。
- [x] FFI Handle 全部 destroy。
- [x] Core 不持有 BuildContext/State/ViewModel。

## 文件

- [x] 手写文件原则上 < 500 行；既有兼容桥接和 cohesive UI/test 文件的例外由
  Step31 文件规模报告列出并保留职责边界。
- [x] > 400 行文件逐个审查。
- [x] 文件按职责拆，而不是按行数机械拆。
- [x] 不存在新的 God Service/God ViewModel。

## 编译裁剪

- [x] Full App 正常构建。
- [x] Terminal App 正常构建。
- [x] Terminal App dependency graph 不含 AI/SFTP/RAG/MCP/WebView 等未选模块。
- [x] 未编译 Feature 不创建数据库、不初始化 SDK、不注册 Route。

## 并行开发

- [x] Terminal Agent 主要只修改 `feature_terminal/**`。
- [x] SFTP Agent 主要只修改 `feature_sftp/**`。
- [x] AI Agent 主要只修改 `feature_ai/**`。
- [x] Network Agent 主要只修改 `network_transport/**`。
- [x] SSH Agent 主要只修改 `ssh_core/**`。
- [x] Core API 变更需要单独 PR。
- [x] 一个普通 Feature PR 不需要同时改多个其他 Feature。

---

# 42. 推荐并行开发 Ownership

```text
Architecture Owner
  packages/core/**
  workspace config
  architecture_check

Network Owner
  packages/infrastructure/network_transport/**
  packages/infrastructure/ssh_mobile_network_native/**

SSH Owner
  packages/infrastructure/ssh_core/**

Terminal Owner
  packages/features/feature_terminal/**

SFTP Owner
  packages/features/feature_sftp/**

Monitoring Owner
  packages/features/feature_monitoring/**

System Admin Owner
  packages/features/feature_system_admin/**

AI Owner
  packages/features/feature_ai/**

RAG Owner
  packages/features/feature_rag/**

Playbook Owner
  packages/features/feature_playbook/**

MCP Owner
  packages/features/feature_mcp/**

LAN Owner
  packages/features/feature_lan_share/**

App Owner
  apps/**
```

Feature Owner 修改 Core Public API 前：

1. 先提出 Core API 需求；
2. 单独修改 Core；
3. Core 测试通过；
4. 再在 Feature PR 使用。

不要在 Feature PR 中顺手大改 Core。

---

# 43. Codex 每个 Step 的固定输出格式

Codex 完成一个 Step 后必须报告：

```text
Step:
完成内容:
新增文件:
移动文件:
删除文件:
Public API 变化:
依赖变化:
生命周期变化:
验证命令:
验证结果:
剩余 TODO:
```

如果发现 Plan 与实际代码不一致：

> 允许对当前 Step 做最小必要调整，但必须记录原因；不得自行扩大当前 Step 范围。

---

# 44. 推荐实际执行顺序

严格按以下顺序：

```text
00 基线
01 Workspace
02 app_core
03 AppRuntime
04 Log
05 connection_core
06 feature_connection
07 network_transport
08 ssh_core
09 app_ui

10 feature_terminal
11 feature_sftp
12 feature_monitoring
13 feature_system_admin

14 feature_lan_share
15 feature_playbook
16 feature_rag
17 feature_mcp
18 feature_ai
19 feature_webview
20 feature_developer

21 App Shell 收敛
22 删除 StorageService
23 删除 AppDatabase
24 清理旧 services
25 清理 pubspec 依赖

26 Terminal-only App
27 生命周期 Diagnostics
28 Architecture Guard
29 README / AGENTS
30 CI
31 文件尺寸治理
32 依赖审计
33 Owner 审计
34 最终验收
```

前 09 Step 完成之前：

> 不允许多个 Agent 同时开始大规模 Feature 搬迁。

完成 Step 09 后：

```text
Terminal
SFTP
Monitoring
System Admin
LAN
```

可以在接口冻结后并行。

AI/RAG/Playbook/MCP 因相互存在能力调用：

> 先冻结 Capability Contract，再并行迁移。

---

# 45. 最终架构

```text
┌─────────────────────────────────────────────┐
│                  App Shell                  │
│                                             │
│ AppRuntime / ModuleRegistry / Navigation    │
└────────────────────┬────────────────────────┘
                     │
     ┌───────────────┼────────────────────┐
     │               │                    │
     ▼               ▼                    ▼
 TerminalModule   SftpModule           AiModule
     │               │                    │
 terminal.db       sftp.db              ai.db
     │               │                    │
     └──────────┬────┴────────────┬───────┘
                │                 │
                ▼                 ▼
          Core Contracts     Capability APIs
                │
        ┌───────┼──────────┐
        ▼       ▼          ▼
 Connection   Logging    SSH Core
    Core                   │
 connection.db             ▼
                    Network Transport
                           │
                           ▼
                  Native Network / FFI
```

共享基础设施：

```text
AppRuntime
├── AppLogger                # 1
├── NetworkRuntime           # 1
├── SshSessionManager        # 1
├── ConnectionRepository     # 1
├── CredentialRepository     # 1
└── ModuleRegistry           # 1
```

模块私有：

```text
TerminalModule
├── TerminalDatabase         # 1 per module
└── TerminalRepository

SftpModule
├── SftpDatabase             # 1 per module
└── SftpRepository

AiModule
├── AiDatabase               # 1 per module
└── AiRuntime
```

页面私有：

```text
Route
└── ViewModel / Controller
```

这就是本次重构的最终边界。

---

# 46. 最核心的五条约束

如果后续开发只记住五条：

1. **Feature 不依赖 Feature 实现。**
2. **AppRuntime 拥有全局资源，Module 拥有业务资源，Route 拥有页面状态。**
3. **Network/SSH 全局复用；Feature DB 独立。**
4. **所有资源必须能明确释放，禁止隐式永久监听。**
5. **按职责拆文件和模块，不制造 God Object，也不制造碎片化 Package。**
