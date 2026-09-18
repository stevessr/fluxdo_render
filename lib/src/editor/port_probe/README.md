# 官方编辑语义受限移植验证（不切生产）

## 接口

`port_probe.dart` 的 `ProbeCodec` 提供 `parseTokens(List<dynamic>)`、`serialize(ProbeNode)`、`applyEdit(ProbeNode, Map<String,dynamic>)`。输入是官方 tokenizer 原始 DTO，不接收 fixture 的 doc/serialized，不重新 tokenize。生产包入口未导出，生产 converter/model 未改。

- `ProbeNode` / `ProbeMark`：独立不可变树，content 索引组成 path；`toJson()` 对齐 PM JSON。
- `ProbeNode.fromJson` 无损读取完整 JSON；`ProbeSchema.fromJson` 额外补默认属性并执行受限检查。两者不等同完整 PM schema.nodeFromJSON。
- `insertText` 只在空 paragraph 加入非空text，用于空文档/空容器首次输入的差分，不是通用事务。
- `replaceText` 使用 Dart/JS 同样的 UTF-16 偏移；不允许产生空 text，与 oracle 拒绝空 TextNode 一致。
- `setAttrs` 只允许 patch schema 已声明节点属性；未知 patch key 明确失败。**已有未知 attrs 保留**是用户指定的有意差异：PM 严格 schema 检查可能拒绝它们，不能宣称这部分与官方等价。
- 编辑仅复制路径节点，未改兄弟保持对象身份，所有 attrs（包括嵌套 Map/List）冻结。不实现 transaction/history/selection/mapping。

## 来源映射

Discourse 固定 commit：`b3b561e5fad412c038e222499ebe22050b4a8de4`。逐文件 SHA、tokenizer SHA 和测试依赖锁见 `tools/editor-port-probe/source-manifest.v1.json`。

| Dart 文件 | 官方来源与移植范围 |
| --- | --- |
| `model.dart` | prosemirror-markdown `src/schema.ts`；prosemirror-model `src/schema.ts` 的默认 attrs/createAndFill/check 子集、`src/mark.ts` 的 mark rank/self-exclusion、`src/node.ts` 的 JSON/节点大小约定 |
| `parser.dart` | prosemirror-markdown `src/from_markdown.ts` 的 MarkdownParseState、token 分派、listIsTight、text 合并、单 token code 规则；Discourse `core/parser.js` 的 softbreak/BBCode 与扩展 handler |
| `parser.dart` HTML/quote/link | `frontend/discourse/app/static/prosemirror/extensions/{html-inline,html-block,quote,link,bullet-list,ordered-list}.js` |
| `parser.dart` details/footnote | `plugins/{discourse-details,footnote}/assets/javascripts/lib/rich-editor-extension.js`；脚注使用 `prosemirror-model/src/replace.ts` flat closed Slice 替换子集 |
| `serializer.dart` | prosemirror-markdown MarkdownSerializerState 与默认节点/mark serializer；上述 Discourse 扩展 serializeNode/serializeMark/afterSerialize |

这里真正需要的底层 API 是：Node/Mark attrs 与 rank、text 合并、nodeSize/descendants 定位、必要空内容填充、解析 frame stack、inline mark 开闭重排、pending close/delim/list-tight 序列化状态、脚注 closed-Slice 替换。不是把224行核心表面代码翻译完即可。

## 明确边界

- 节点：doc/text/paragraph/heading/code_block/blockquote/quote/lists/list_item/hard_break/horizontal_rule/html_inline/html_block/details/summary/footnote。mark：em/strong/link/code。
- 默认 heading 是 `(text | image)*`，本验证未移植 image，故只支持带任意所选 marks 的 text；hard_break/html_inline 在 heading 中拒绝，不误用段落 inline*。
- 不支持 image、表格、mention、emoji、上传、onebox、完整 strikethrough 扩展和其他未注册节点/token，抛 `ProbeUnsupported`，绝不回退生产 converter。
- HTML allowlist 与官方一致：未知 HTML tag token 官方即忽略，本验证同样处理。`s/strike` 需要未注册 mark，会明确失败；不是偷偷当普通文本。
- schema 只实现上述内容表达式及必需填充，不是通用 ContentMatch/Fragment/Slice/DOMParser，不保证任意 malformed token stream 与 PM 同样恢复。非法内容选择明确失败，而不是 PM createAndFill 的丢弃路径。
- 脚注实现 closed-Slice 的单父节点/递归内层替换；跨容器边界明确 unsupported。官方多引用脚注使用原始位置依次 replace 产生的嵌套错位结果照样验证，不以直觉“修正”oracle。
- Typography 设置固定为 oracle 的 `enable_markdown_typographer:false`；无其他站点/插件组合等价承诺。Dart 使用现有 html 包解析属性，不新增 pub 依赖。

## 验证与成本结论

`packages/fluxdo_render/test/editor/port_probe_test.dart` 动态遍历真实官方95案例，分别比较完整 doc、serialized、editedDoc、editedSerialized；额外验证 token DTO 不变、未知 attrs 保留、不可变/路径共享、UTF-16、未知 patch 拒绝、schema 默认值与 unsupported。不比较 cook，也没有 raw/id 特判或预期树反推。

运行：

```sh
flutter test --no-pub packages/fluxdo_render/test/editor/port_probe_test.dart
 dart analyze packages/fluxdo_render/lib/src/editor/port_probe packages/fluxdo_render/test/editor/port_probe_test.dart
```

受限案例通过证明此范围的 codec 可独立移植，不证明完整编辑器低成本。脚注已需要引入节点位置与 Slice 子集；新增插件、非法输入恢复、复杂 schema 可能迫使进一步重建 PM 底层。后续应按扩展增加真实 oracle 差分样本，再估维护成本；本验证没有性能测量，不给速度倍率或工期承诺。
