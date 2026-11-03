# 发现待办与应用图标修复验收

## 问题与修改

截图中的错误来自 `ReminderDiscoveryError.invalid`。旧代码把格式、引用、覆盖清单和独立复核失败合并为同一错误；一个条目无效便拒绝整段结果。仅凭截图无法确定那次模型返回具体哪个字段出错，本次不保存或上传用户原文来推测。

| 环节 | 修改后的行为 |
| --- | --- |
| 纯格式差异 | 清理标题中的 Markdown、移除重复正文、合并相同覆盖项；只有命名片段内唯一的空白差异才还原成原文引用 |
| 无效条目 | 至多请求修正一次，然后保留独立复核通过的条目；伪造引用、未知角色值、无依据期限不能成为提醒 |
| 覆盖或审阅不完整 | 未核对部分保留为不确定，不能撤销该来源的旧提醒，不能推进其检查点；整段无法读取或完全没有覆盖仍报错 |
| 重试与重启 | 不确定来源不写入成功哈希，重复截图继承不确定状态；继续操作只分析剩余记录 |
| 页面提示 | 区分完整成功、部分完成、读取失败、无原文依据、复核未完成、取消；部分完成显示剩余条数与继续入口 |
| 来源权限 | 沿用事件参与设置、应用排除、脱敏、角色归属、输入版本和隐私状态的前后校验；不会自动安排通知 |

单页由 12,000 字/48 片段调整为 8,000 字/24 片段，降低长覆盖清单挤占输出额度的风险。提取器升级为 v5，旧版允许参与深查的记录在下次手动发现时重新检查一次。

旧 ICNS 主体像素的 alpha 最高仅 253，并有边缘杂点；灰色外框不在源图中。结合 Apple 对旧图标自动缩放和底板的说明，新版 macOS 的兼容处理是可能原因，需在用户设备验证最终 Dock 效果，不能只凭 PNG 断言根因。

保留蓝色时钟、回环箭头与星光，重新生成无外框的满幅不透明素材。Xcode 26+ 将 `.icon` 编译为 `Assets.car`，通过 `CFBundleIconName` 采用系统遮罩；旧工具链使用统一轮廓的 11 尺寸 ICNS。没有增加签名、DMG、更新器或分发功能。

## 验证

功能代码 `cd0079634c5aa13b0c757ada6e641cb064701914` 的 [macOS CI 41575557226](https://github.com/samz406/Recall/actions/runs/41575557226) 两个任务均为 success；之后仅补充本验收文档。[PR #77](https://github.com/samz406/Recall/pull/77)。

| 工具链 | 编译 | 集成与提醒专项 | 原生布局与交互 | 图标 |
| --- | --- | --- | --- | --- |
| Swift 6.3.3 / Xcode 26.6 | 通过 | 272 项结束检查，含 18 组提醒场景 | 108 张预览及原生入口回归通过 | 不透明与 11 尺寸检查、现代 Assets.car 编译通过 |
| Swift 6.0.3 / Xcode 16.2 | 通过 | 272 项结束检查，含 18 组提醒场景 | 108 张预览及原生入口回归通过 | 不透明与 11 尺寸检查、旧版 ICNS 回退通过 |

- 本地：ICNS 11 个表示尺寸检查、主体 alpha=255、PNG 格式检查、Shell 语法、`git diff --check`。
- macOS CI：实际执行 `swift build --jobs 1`、`swift run RecallVerifier`、`swift run RecallApp --layout-previews`、图标编译/像素验证，均通过。本地没有 Swift，未将 CI 结果写成本机运行结果。
- 合成模型回归覆盖新增四组场景：格式修复、混合无效行隔离、部分审阅、持久化后增量重试。也覆盖同截图中有效与无效条目并存、重复截图、伪造期限、取消、隐私变化和保存回滚。
- 未执行真实模型准确率评测、用户账户采集或系统 Dock 的人工验收。发布后需在真实 Mac 重启 Recall，确认“继续发现”和 Dock 外观；无需删除用户数据、清缓存或重置系统权限。

## 图标维护

源文件：`Resources/AppIcon.icon/Assets/Recall.png`。生成采用内置图像生成，最终提示的约束为：保留现有蓝色时钟/回环箭头/右上星光，输出不透明、满幅方形蓝色画布；无外框、留白、阴影、文字，符号保持在中央 70%，由系统提供外轮廓。

```bash
# 修改主图后重建旧版资源（需要 Pillow）
python3 scripts/build-legacy-icon.py
# 在 Mac 上检查并编译现代资源
swift scripts/verify-app-icon.swift "$PWD"
bash scripts/compile-app-icon.sh /tmp/recall-icon-check
# 正常运行，自动选用当前工具链支持的资源
./scripts/run-app.sh
```

参考：[Apple 图标兼容处理说明](https://developer.apple.com/videos/play/wwdc2025/220/)、[Icon Composer](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)、[CFBundleIconName](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleiconname)。
