# 生产语义编辑内核

当前默认富文本已使用本模块。生产架构、支持范围、验收记录及已知边界统一见
`docs/semantic-production-acceptance.md`（主仓库）；codec来源见本目录NOTICE.md。

## 接口

- `SemanticNode(type, {attrs, content, marks, text})` 与 `SemanticMark(type, [attrs])`：提供 `fromJson` / `toJson`、`copy` / `copyWith`；节点额外提供 `textContent` / `nodeSize`。复制可显式传 `text: null` 清空文本。脚注引用按原子计数，不沿用实验容器规则。
- `sameSemanticMarks(a, b)`：按标记顺序、类型及深层属性比较，忽略属性键插入顺序。

- `SemanticEditorProjection.project(tree)`：生成 `blocks` 与只读 `sources`（stable block id → 原节点）。内部 path 记录原容器边界。
- `projection.synchronize(blocks)`：验证块身份及结构，只复制改动路径；不改动的子树直接复用。
- `SemanticEditorSession(tree)`：拥有真实 `EditorState editor`，前置绑定文字/属性事务，undo/redo 同步恢复 `tree`。
- 通过可选 `EditorDocumentBinding` 在提交前纯计算同步；失败抛 `EditorDocumentRejection(code: semantic_unsupported)`，正文与历史均不接受该事务。`tree` 直接读取 `editor.documentBindingState`，undo/redo 与正文同时恢复树快照，不监听事后修补。

## 当前能力与边界

支持 paragraph、heading（含级别修改）、em/strong/code/普通显式 link 的文本编辑；保留 link title 和所有未映射 attrs。blockquote、quote、details 正文、嵌套列表递归映射，不通过 flat list run 重建，故相邻同型容器不会错误合并。details summary 原节点保持原样，目前不开放 summary 属性编辑。

已支持 video/audio 与可识别的 html_block 媒体投影为真实媒体岛；image/emoji/mention/local_date/特殊链接投影为真实行内原子，字段修改、旁段输入与undo保持来源。未知节点/未知 inline、空容器仍作为不透明岛，真实内容只存在原树旁表中。占位 CodeBlockNode 仅供模型验证，**不可当生产渲染或导出结果**。空段落可以编辑；全岛/空 doc 的虚拟落点不会污染原文档，但编辑该虚拟点目前显式失败。

已支持顶层段落/标题精确拆分合并、同区域重排删除，以及同父引用段落拆分；成功后保存新的稳定ID映射快照。来源不明的新块、列表结构操作、跨容器/不透明边界操作、换组及类型转换仍显式 unsupported。跨不同 text attrs 的替换同样拒绝歧义，不假设丢弃来源属性。IR 使用 `EditorState.exportBlocks()` 的只读归一化快照，支持物化期间同步文本和链接编辑，并保留原树中未显示的 title/attrs；不调用 Markdown serializer/parser。

生产已有 image/emoji/mention/date/attachment 等 atom 与 media 能力不能因此降级：本适配未声明完整 schema 或全生产等价，后续须为这些节点补双向来源适配、专用展示和结构事务，再接生产入口。任何接入方必须绕开旧 `docToMarkdown` 对占位岛的导出，提交只读取 session 的语义树。

## 验证

`flutter test test/editor/semantic_editor_test.dart`：全内存语义模型 + 实际 EditorState，无平台/网络 mock；验证未知 attrs、link title、text attrs、空段与空容器、嵌套 list/details/quote、opaque 身份、undo/redo、结构前置拒绝与虚拟落点、IR 物化/归一化语义保持。


## 新增媒体、原子与复合事务验证

- `media_projection.dart`：原HTML未修改保源，模型修改经局部媒体codec写回；不能无损表达的字段更新前置拒绝。地址/尺寸校验与生产媒体一致。
- `inline_projection.dart`：保映射字段与未映射attrs；同U+FFFC相邻原子按保留实例身份定位，避免删除首个却继承其未知属性；原子前后拆分切片按1个编辑单位处理。
- `EditorState.runAtomicEdit`：绑定下常用复合插删/分块/粘贴自动隔离；失败完整回滚、成功最多通知一次并合并内部历史，原idle截止时间保持。同步回调不能包含外部副作用或异步工作；每次内部prepare仍必须合法。
- 模型/真实widget测试包含图片缩放、媒体渲染、附件/特殊链接实际点选工具编辑、日期范围、相邻原子删除、原子前后拆分及撤销。

本轮子包非golden全量2115项通过，修改文件定向analyze无问题。生产入口仍未启用；
完整生产 codec、跨容器与列表结构事务、上传占位语义历史清理与所有片段导出仍需衔接，
不得将未知节点的 UI 占位直接当成生产导出结果。


## 正式编解码、片段及临时节点

- 正式模型独立deep-freeze JSON属性；不继承probe schema、JS怪值coercion或已知脚注异常。
- `SemanticDocumentCodec`：token→tree→Markdown，支持矩阵见NOTICE.md；未知token/无支持结构明确拒绝，不调用旧转换器补结果。
- 主仓库`SemanticComposerCodec`复用整体预算及严格cook门禁，可注入测试tokenizer/cook。多行段落、空quote/details/list、带marks日期等有真实gate与编辑回归。
- `insertFragmentAtBlock`/复制/删除：只在可证明的整根边界操作，一次性受信计划严格匹配，保稳定IDs/frame与历史；不支持任意光标文本拼接。
- `insertTransientNodeAtBlock`/`resolveTransient`/`exportTree`：按token稳定来源过滤导出；取消/替换原子重映射当前、undo和redo，不恢复孤儿，保留周边正文。普通节点编辑不可盗用临时授权。

本轮全子包非golden2151项、主仓库新旧组合68项通过；本轮核心和新主入口analyze无问题。
以上为早期接入记录；实际上传、日常结构命令、三页面与默认入口现已切换，最终验收以主仓库文档为准。
