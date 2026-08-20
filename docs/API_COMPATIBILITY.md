# 模型 API 兼容性说明

Recall 将模型类型与底层协议分开，用户可编辑服务地址、模型名称和 API Key；密钥只存储于 Keychain。当前支持两种协议，均默认关闭网络外发，只有用户显式启用云端上下文发送后才会发起请求。

| 模型类型 | 请求方式 | 认证方式 | 主要请求字段 | 文本响应读取 |
|---|---|---|---|---|
| 兼容 OpenAI API | `POST {baseURL}/chat/completions` | `Authorization: Bearer {key}` | `model`、`messages`、`temperature`、`max_tokens` | `choices[0].message.content` |
| 兼容 Anthropic API | `POST {baseURL}/v1/messages` | `x-api-key: {key}`、`anthropic-version` | `model`、`system`、`messages`、`max_tokens`、`temperature` | `content` 数组中的 `type: text` 块 |

在请求前，Recall 的上下文管理器会保留系统约束、会话摘要、最近若干轮对话和本轮检索到的记忆证据。较早的会话被压缩为结构化摘要，原始详细消息不再全部进入后续模型请求；检索记忆以独立证据块注入，不与会话摘要混淆。这样既限制长对话输入大小，也保留用户结论、待办、偏好、未解决问题与来源引用。

## 官方资料

- [Anthropic Messages API](https://platform.claude.com/docs/en/api/messages)
- [OpenAI Chat Completions API](https://developers.openai.com/api/reference/resources/chat)
