// App 级语言枚举。
//
// 语言是跨 Feature 的无状态公共值，不依赖 AppSettings 或任意 UI 实现，
// 因此由 app_core 统一定义，避免 Feature 为了展示文案反向依赖 App Shell。
enum AppLanguage { zh, en }
