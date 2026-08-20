# Recall 项目指引

## 项目目标

Recall 是一个本地优先的 macOS 个人记忆应用。任何实现必须维护三个不变式：**用户明确触发、敏感数据最小化、结果可以删除和追溯**。

## 结构

`Sources/RecallKit` 存放可复用核心逻辑，涵盖采集、OCR、隐私、持久化、检索、会话和提醒。`Sources/RecallApp` 存放 SwiftUI 与 AppKit 用户界面。`Verification` 是无网络、无真实截图、无真实密钥的集成验证器。

## 开发约束

不要新增默认连续采集、裸 Enter 监听、音频录制、自动外发或未确认的外部动作。新增任何屏幕采集、模型调用、提醒、导出或同步能力时，必须实现暂停、关闭、删除和失败回退路径。根据项目所有者的明确要求，模型 API Key 存储在用户本机 Application Support 配置中，不通过 Keychain；该配置必须被 Git 忽略，密钥不得写入日志、示例、测试夹具或仓库文件。

不要在仓库中提交真实截图、真实 OCR 文本、个人数据或服务密钥。涉及云端模型时，只允许发送与当前任务相关且经过最小化处理的文本片段；默认关闭该能力。

## 验证

修改核心逻辑后运行：

```bash
swift build --jobs 1
swift run RecallVerifier
```

修改 UI、ScreenCaptureKit、Vision 或 UserNotifications 后，还应在安装完整 Xcode 的 macOS 环境中手动验证权限提示、实际截图、OCR、删除、通知和菜单栏交互。当前环境如只有 Command Line Tools，不应声称已完成这类图形与权限的端到端验收。
