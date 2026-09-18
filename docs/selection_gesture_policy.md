# 阅读态与编辑态的选区复用

以项目当前 Flutter SDK 的下列实现为依据：

- `widgets/selectable_region.dart`：只读内容的连击、拖选及工具栏规则。
- `widgets/text_selection.dart`：可编辑文本的连击和选区扩展规则。
- `rendering/paragraph.dart`、`rendering/editable.dart`：文本边界与位置处理。
- `gestures/tap_and_drag.dart`：连续点击计时、设备阈值及拖动识别。

## 共享层

`selection/text_selection_rules.dart` 提供：

- 带 `editable` / `readOnly` 参数的平台连击规则。
- 词边界、段落边界以及保留起始单位的正反向拖选算法。
- 带可选命中过滤的 SDK 点击/拖动识别器；过滤发生在进入手势竞争之前。

`BlockTextGeometry` 提供渲染坐标下的文本与几何。普通 `RenderParagraph`
和缓存直绘 `RenderCachedParagraph` 均接入这个接口，偏移不使用无障碍标签文本。

编辑器负责渲染偏移与文档模型偏移互转、虚拟段落分隔符、光标和 IME。
阅读态负责跨块投影、虚拟化、复制/引用工具栏，不生成编辑光标或输入连接。

## 原生差异保留为规则

| 场景 | 编辑态 | 阅读态 |
| --- | --- | --- |
| Android 触摸连击 | 单击、双击、三击循环 | 单击、双击循环，第三击清除选区 |
| Windows 第四击起 | 选词、选段交替 | 保持三击选段 |
| Linux 三击 | 选择显示行 | 选择段落，可跨自动换行 |
| iOS 触摸第三击 | 选段 | 保留选词，点选区切换工具栏 |
| 空白点击 | 按位置落光标或按平台规则失焦 | 清除选区，不唤起键盘 |

阅读页面保留外层横向翻页的手势优先级；复制输出仍按帖子块级结构补换行，
不是原生 `SelectionArea` 对独立 `Text` 节点的简单拼接。

## 回归验证

- `test/editor/native_multitap_test.dart` 与真实 `TextField` 重放同组手势。
- `test/selection/native_reading_gestures_test.dart` 与真实 `SelectionArea` 对照，
  同时运行普通文本与缓存直绘路径。比较选中字元时仅去掉导出层额外添加的块间
  分隔符，文本本身的换行仍参与断言。
- `test/selection` 保留复制、投影、滚动扩选、裁剪和虚拟化回归。

## 图片与块选区

`SelectableObjectBlock` 把没有文本几何的块注册为一个不可拆分的选区单位，
复用 `SelectableTextBox` 的注册、生命周期和高亮。阅读态网格/轮播、媒体、
链接卡片、公式、SVG、投票、聊天引用和自定义代码图表接入同一几何；
编辑态岛块也使用它，子编辑器仍保留自己的交互和焦点。

从文字拖进图片或块时，根据固定端在文档中的前后位置选择整个对象。
双击/长按扩选和手柄拖动复用相同命中逻辑，反向拖回能退出对象。
普通代码、列表、引用、表格单元格在阅读态保持文字粒度；编辑态从正文
跨入独立的表格/代码编辑器时按整块选择，内部编辑仍由子编辑器处理。

图片高亮与同行文字分开绘制；手柄贴图片边缘，但拖动补偿使用文字行高。
无 alt 图片的复制内容回退到地址，引用匹配仍使用 cooked 的原始文本投影。
跨块直接输入和 IME 使用同一个替换事务，撤销一次恢复图片/块与原文。

`test/selection/object_range_selection_test.dart` 覆盖两种渲染路径、正反向
拖选、手机长按跨块、块内原有点击、复制与输入替换后的撤销。
