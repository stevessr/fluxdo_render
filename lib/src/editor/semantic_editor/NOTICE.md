# 生产语义 codec 来源与边界

`token_parser.dart` 的栈式解析和 `token_serializer.dart` 的延迟闭块、列表缩进、mark 状态机提取自本仓库已翻译的 prosemirror-markdown / Discourse 实现；相应许可证见 `licenses/`。生产文件不导入 `port_probe`，不使用 ProbeCodec，也不包含脚注位置替换和 JS coercion 仿真。

`SemanticDocumentCodec.parseTokens` 接受官方 tokenizer 的 tokens 数组，`serialize` 直接访问正式 SemanticNode 树。宿主须通过原 raw 与输出的完整 cook 严格等价门禁决定是否提供编辑模式。当前已用于默认富文本编辑入口。

范围：paragraph、heading、四类 marks（em/strong/link/code）、显式及自动链接/附件、blockquote/quote、details（纯文本 summary）、嵌套列表、代码、HTML 块（包括媒体原文）、允许的 HTML inline、image、emoji、mention、local_date（含范围）。空引用填充可编辑空段落，导出仍为空引用。未知 JSON attrs/meta 留在树中，修改只由投影复制已改路径；不会把未知 attrs 强制写入 Markdown 语法。HTML 块是保源内容，安全渲染仍由 cook 负责。

已扩展 table、poll、footnote、math、check、image-grid、hashtag、wrap、spoiler/callout 和underline/strikethrough等既有能力。任意未注册 token/node/mark 仍抛 SemanticCodecUnsupported，不静默跳过。引用标题/control 是官方派生 UI token，仅在找到对应结束 token 时跳过。

schema 验证已知属性的实际类型、有限数值、合法 heading/list 范围、HTML 属性名/字符串值、链接和媒体 URL，不接受 JS 数组/对象字符串化等怪值。原始 HTML 块不被伪装成结构化安全 HTML；必须遵循既有 cook 的安全边界。
