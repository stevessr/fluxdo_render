# AGENTS.md

fluxdo_render 是 [FluxDO](https://github.com/Lingyan000/fluxdo) 的帖子渲染引擎：把 Discourse 的 cooked HTML 解析成节点模型，再分块渲染，并带有自研选区和编辑器。
本仓库以 git 子模块的形式挂在主仓的 `packages/fluxdo_render/`，主仓的 [AGENTS.md](../../AGENTS.md) 同样适用。

## 结构

```
lib/src/
  parser/     cooked HTML → 节点
  node/       节点模型
  chunk/      大帖分块
  flatten/    扁平化与布局缓存
  render/     节点 → Widget（node_factory.dart）
  selection/  自研选区
  editor/     编辑器
  config/     宿主可注入的主题扩展
test/
  fixtures/   各节点的 HTML 样例（按节点分目录）
  golden/     golden 基线
example/      演示应用，浏览全部 fixture
```

## 命令

在本目录执行：

```sh
fvm dart analyze lib
fvm flutter test                                         # 全量，包含 golden
fvm flutter test test/golden_framework_smoke_test.dart   # 遍历全部 fixture 的 golden 主套件
dart run test/fixtures/scripts/gen_fixtures_index.dart   # 新增或修改 fixture 后重新生成索引
```

## 约定

- **只依赖 Flutter，不感知宿主**：宿主的主题通过 `ThemeData.extensions` 注入，包括 `FluxdoRenderPalette`（语义色）、`FluxdoRenderShapes`（圆角）、`FluxdoRenderStyle`（标题字体、引用块）。未注入时外观必须与默认一致。新增可定制的样式时也走这条路，不要引用宿主代码。
- **圆角走 `FluxdoRenderShapes`**：拿不到 context 的绘制代码用 `FluxdoRenderShapes.current`。
- **改渲染必须跑全量 golden**：只有 heading、paragraph 有单独的 golden 测试，其他节点都靠 `golden_framework_smoke_test.dart` 覆盖。判读方法和基线更新见主仓的 [fluxdo-render](../../.agents/skills/fluxdo-render/SKILL.md)。
- **fixture 索引入库**：`lib/src/dev/fixtures_index.g.dart` 由脚本生成，需要提交。
- **渲染里少了东西时先查数据**：宿主会在渲染前预处理 cooked HTML（emoji、链接点击数等），直接拿原始 cooked 测试会缺内容，这是数据流问题，不是渲染问题。

## 提交

本仓库独立提交，并推送到 `main` 分支；推送后再回主仓提交子模块指针。
