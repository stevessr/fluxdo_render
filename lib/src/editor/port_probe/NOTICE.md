# 原型来源及许可声明

本目录是移植可行性验证，不是生产编辑器接口。

- 部分解析、模型、序列化算法翻译自 ProseMirror 的 prosemirror-markdown 1.13.4 与 prosemirror-model 1.25.4，MIT 许可与原版权声明保留于 licenses/。
- Discourse 扩展规则翻译自 commit b3b561e5fad412c038e222499ebe22050b4a8de4。上游 COPYRIGHT.md 声明 GPL v2 或更新版本；其原许可全文保留于 licenses/discourse-GPL-2.0.txt。逐文件来源映射见 README.md 和测试工具 source-manifest.v1.json。
- 本次 Dart 翻译及适配由 Fluxdo 项目维护。完整工程分发仍需遵循项目与上述第三方许可要求；这里不以“语言翻译”改变上游代码许可。

JS oracle 仅测试使用，依赖包保留各自许可；不把浏览器 EditorView 或测试 DOM 加入应用运行时。
