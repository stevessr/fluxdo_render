// GENERATED — do not edit by hand.
// 重新生成: dart run test/fixtures/scripts/gen_fixtures_index.dart

import 'fixtures_index.dart';

const List<FixtureEntry> allFixtures = [
  FixtureEntry(
    relativePath: r'''_edge_cases/nested_quote_three_levels.html''',
    html: r'''<p>正文段落 1。</p>
<aside class="quote">
<blockquote>
<aside class="quote">
<blockquote>
<aside class="quote">
<blockquote><p>最里层引用,深三层。</p></blockquote>
</aside>
<p>中间层补充。</p>
</blockquote>
</aside>
<p>最外层引用补充。</p>
</blockquote>
</aside>
<p>正文段落 2,引用之后。</p>
''',
    notes: r'''深三层嵌套 quote(aside > blockquote > aside > blockquote > aside > blockquote)。
用于验证递归渲染 + 嵌套层级缩进 + 跨层级 margin 折叠。
历史上 fwfh 在这种 case 上偶有"丢失中间层"的问题。''',
    source: r'''https://example.com/t/sample/1/5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''attachment/secure_upload.html''',
    html: r'''<p><a class="attachment" href="/secure-uploads/original/2X/f/f62055931bb702c7fd8f552fb901f977e0289a18.zip">archive.zip</a> (4.5 MB)</p>''',
    notes: r'''secure-uploads 路径附件(鉴权下载)。验证 isAttachment 仍命中、filename=archive.zip。
launchContentLink._isUploadLink 对 /secure-uploads/ 同样识别为附件。
primary_node 标 attachment(与目录同名)。''',
    source: r'''https://example.com/t/sample/1/attachment2''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''attachment/simple.html''',
    html: r'''<p>详见附件 <a class="attachment" href="/uploads/default/original/1X/abc123def456.pdf">设计规范.pdf</a> (1.2 MB)。</p>''',
    notes: r'''最基础附件链接 a.attachment(Discourse `[设计规范.pdf|attachment](upload://…)`
cook 形态)。验证 parser 产 LinkRun(isAttachment=true, filename="设计规范.pdf"),
渲染加下载图标 + 文件名;尾部 " (1.2 MB)" 是锚点外文本,走普通 TextRun。
primary_node 标 attachment(与目录同名,附件是 inline run,无独立 block NodeKind)。''',
    source: r'''https://example.com/t/sample/1/attachment1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''audio/upload_audio.html''',
    html: r'''<p><audio preload="metadata" controls>
    <source src="/uploads/default/original/1X/abcdef1234567890.mp3" data-orig-src="upload://eyPnj7UzkU0AkGkx2dx8G4YM1Jx.mp3">
    <a href="/uploads/default/original/1X/abcdef1234567890.mp3">/uploads/default/original/1X/abcdef1234567890.mp3</a>
  </audio></p>
''',
    notes: r'''Discourse 上传音频的终态 cooked(无运行时注入):<audio preload="metadata" controls>
+ <source src data-orig-src> + 内层 <a> 文本(常是 URL)。
legacy 走 fwfh_just_audio 默认音频条。
渲染:子包占位卡(音乐图标 + 文件名)。主项目接 audioBuilder 后用 just_audio 播放。''',
    source: r'''https://linux.do/t/sample/1/au1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''audio/voice_message.html''',
    html: r'''<div class="d-wrap" data-wrap="voice">
<audio controls>
  <source src="/uploads/short-url/qUJGpoUSJLSWlI37sAVBL3tPG91.xz" type="audio/mp4">
</audio>
</div>
''',
    notes: r'''本 app 语音消息约定形态:raw = [wrap=voice] + 裸 <audio> 标签(媒体改名
.xz 上传),cook 产 <div class="d-wrap" data-wrap="voice"> 包住原生 audio。
网页端:无样式 div + 原生 controls,零影响。
本 app:parser 识别 data-wrap=voice → AudioNode(voice:true) → 语音条 UI
(主项目 audioBuilder 分流);子包 fallback 仍是占位卡。''',
    source: r'''cook 探针实测(tools/discourse-cook-bundle,[wrap=voice] BBCode 产物)''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''blockquote/multi_paragraph.html''',
    html: r'''<blockquote>
<p>第一段引用。</p>
<p>第二段引用,跟第一段同属一个 blockquote。</p>
</blockquote>
''',
    notes: r'''多段引用,验证 blockquote 内多个 ParagraphNode 之间 1em 段间距
仍生效(段落自己有 vertical em padding,blockquote 容器只加外 8px)。''',
    source: r'''https://example.com/t/sample/1/bq2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''blockquote/nested_three_levels.html''',
    html: r'''<blockquote>
<p>外层引用。</p>
<blockquote>
<p>中层引用。</p>
<blockquote>
<p>最里层引用。</p>
</blockquote>
</blockquote>
</blockquote>
''',
    notes: r'''三层嵌套 blockquote。验证 parser 递归 + renderer 递归 build。
每层都有自己的灰底 + 左竖条,深嵌套时视觉层次清晰。''',
    source: r'''https://example.com/t/sample/1/bq4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''blockquote/simple.html''',
    html: r'''<blockquote>
<p>这是一段普通的引用。</p>
</blockquote>
''',
    notes: r'''最基础形态:单 blockquote 含一段 p。验证 BlockquoteNode 解析 +
灰底 + 左竖条 + 右上下圆角。''',
    source: r'''https://example.com/t/sample/1/bq1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''blockquote/with_inline_mix.html''',
    html: r'''<blockquote>
<p>引用里含 <strong>粗体</strong>、<em>斜体</em>、<code>inline code</code> 和 <a href="https://example.com">链接</a>。</p>
</blockquote>
''',
    notes: r'''引用内含 strong/em/code/link inline 混排。验证 inline 节点在
blockquote 子段落里正常渲染,字色受 DefaultTextStyle.merge 影响
(onSurfaceVariant,但 link 仍是 primary 因为 LinkRun 显式设)。''',
    source: r'''https://example.com/t/sample/1/bq3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''blockquote/with_list_inside.html''',
    html: r'''<blockquote>
<p>引用前置说明。</p>
<ul>
<li>引用内的列表项 1</li>
<li>引用内的列表项 2,含 <a href="/x">链接</a></li>
</ul>
<p>引用后置说明。</p>
</blockquote>
''',
    notes: r'''引用内含 list:p + ul + p 混合。验证 BlockquoteNode.children 是
BlockNode 序列,可以包含 ParagraphNode + ListNode 等任意块级类型,
renderer 通过 build() dispatch 递归。''',
    source: r'''https://example.com/t/sample/1/bq5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''callout/foldable_closed_danger.html''',
    html: r'''<blockquote>
<p>[!danger]- 不要点击<br>
这里有一个会触发宇宙重置的按钮,默认折叠,提醒用户慎重展开。</p>
</blockquote>
''',
    notes: r'''[!danger]- 可折叠 + 默认折叠。
渲染:红色 + dangerous 图标 + 标题 "不要点击" + 未旋转的箭头 + 内容隐藏。''',
    source: r'''https://example.com/t/sample/1/callout4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''callout/foldable_open_tip.html''',
    html: r'''<blockquote>
<p>[!tip]+ 进阶技巧<br>
你可以通过 <code>--update-goldens</code> 刷新 golden 基线。</p>
<ul>
<li>不要在 CI 上加该参数</li>
<li>commit 前检查 diff</li>
</ul>
</blockquote>
''',
    notes: r'''[!tip]+ 可折叠 + 默认展开。
渲染:teal + tips_and_updates 图标 + 标题 "进阶技巧" + 旋转过的展开箭头
+ 一段含 inline code 的内容 + 无序列表。''',
    source: r'''https://example.com/t/sample/1/callout3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''callout/simple_note.html''',
    html: r'''<blockquote>
<p>[!note]<br>
这是一段说明,提醒读者注意。</p>
</blockquote>
''',
    notes: r'''最简形态:[!note] 不带折叠标记、不带自定义标题。
渲染:蓝色 + edit_note 图标 + 默认标题 "Note",一行正文。''',
    source: r'''https://example.com/t/sample/1/callout1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''callout/unknown_type.html''',
    html: r'''<blockquote>
<p>[!xyz]<br>
未知类型,应该走灰色兜底,标题首字母大写 "Xyz"。</p>
</blockquote>
''',
    notes: r'''未知类型 [!xyz]:CalloutKind.unknown + 灰色 + format_quote 图标 +
typeRaw 首字母大写作为默认标题。''',
    source: r'''https://example.com/t/sample/1/callout5''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''callout/warning_with_title.html''',
    html: r'''<blockquote>
<p>[!warning] 操作不可逆<br>
请在执行前确认你已经备份了数据库。</p>
<p>本操作会清空所有 cookies。</p>
</blockquote>
''',
    notes: r'''[!warning] + 自定义标题(覆盖默认 "Warning")+ 多段正文。
渲染:橙色 + warning_amber 图标 + 标题 "操作不可逆" + 两段内容。''',
    source: r'''https://example.com/t/sample/1/callout2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''chat_transcript/chained.html''',
    html: r'''<div class="chat-transcript chat-transcript-chained" data-username="bob" data-datetime="2026-02-12T10:31:00Z">
<div class="chat-transcript-messages">
<p>这是链式引用的第二条,无边框无频道名</p>
</div>
</div>
''',
    notes: r'''链式引用 chat-transcript(chat-transcript-chained,无频道名/无头像)。
验证 isChained → 去边框 + margin 0,紧贴上一条。''',
    source: r'''https://example.com/t/sample/1/ct2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''chat_transcript/simple.html''',
    html: r'''<div class="chat-transcript" data-message-id="123" data-username="alice" data-datetime="2026-02-12T10:30:00Z" data-channel-name="general">
<div class="chat-transcript-user">
<div class="chat-transcript-user-avatar">
<img loading="lazy" alt="alice" width="20" height="20" src="https://cdn.example.com/avatar/alice.png" class="avatar">
</div>
<span class="chat-transcript-username">alice</span>
<span class="chat-transcript-datetime"><a href="https://example.com/chat/c/-/1/123">10:30 AM</a></span>
</div>
<div class="chat-transcript-messages">
<p>大家好,这是一条聊天记录消息</p>
</div>
</div>
''',
    notes: r'''最简 chat-transcript(频道 general + 头像 + 用户名 + 时间 + 消息)。
纯 DOM,主项目接 legacy buildChatTranscript;子包 fallback 卡。''',
    source: r'''https://example.com/t/sample/1/ct1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''click_count/after_links.html''',
    html: r'''<p>查看 <a href="https://example.com/post/123">这条帖子</a> <span class="click-count"> 42 </span> 和 <a href="https://example.com/post/456">另一条</a> <span class="click-count"> 1.2k </span>。</p>
''',
    notes: r'''典型形态:Discourse _injectClickCounts 在 <a> 后追加
<span class="click-count"> 42 </span> 显示帖内链接点击次数。
渲染:链接后跟小灰底圆角 chip(10 字号)。''',
    source: r'''https://example.com/t/sample/1/cc1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''click_count/various_formats.html''',
    html: r'''<p>大点击数:<span class="click-count"> 12.3k </span>;小点击数:<span class="click-count"> 5 </span>;还有 <span class="click-count">空格已被 trim 仅数字 100</span>。</p>
''',
    notes: r'''各种点击数格式:1.2k / 5 / 含 thin space ( ) 的纯数字。
验证 parser thin space trim 行为。''',
    source: r'''https://example.com/t/sample/1/cc2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''code_block/dart_hello_world.html''',
    html: r'''<pre><code class="lang-dart">void main() {
  print('hello');
}
</code></pre>
''',
    notes: r'''<pre><code class="lang-dart"> 形态,3 行 dart 代码。
用于验证代码块基础渲染 + 语言识别。''',
    source: r'''https://example.com/t/sample/1/3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''code_block/json_with_entities.html''',
    html: r'''<pre><code class="lang-json">{
  "name": "fluxdo",
  "version": "1.0.0",
  "dependencies": {
    "flutter": "&gt;=3.10.0",
    "html": "^0.15.0"
  }
}
</code></pre>
''',
    notes: r'''JSON 代码块含 HTML 实体 &gt;(>),验证 package:html 自动解码,
CodeBlockNode.code 是字面值 ">"。''',
    source: r'''https://example.com/t/sample/1/code4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''code_block/long_line_scrolls.html''',
    html: r'''<pre><code class="lang-bash">flutter run -d macos --dart-define=FLAVOR=staging --observatory-port=9100 --enable-vm-service --disable-service-auth-codes
echo "this is a very long single line that should trigger horizontal scrolling because we cannot wrap code"
</code></pre>
''',
    notes: r'''超长单行 bash 命令,验证横向滚动(SingleChildScrollView Axis.horizontal)。
不会换行,可左右滑动查看完整命令。''',
    source: r'''https://example.com/t/sample/1/code5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''code_block/no_language.html''',
    html: r'''<pre><code>plain text without language hint
just multiple lines
no syntax highlight needed
</code></pre>
''',
    notes: r'''无 lang-xxx class 的 pre/code,验证 language = null + 顶栏显示 "TEXT"。''',
    source: r'''https://example.com/t/sample/1/code3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''code_block/python_function.html''',
    html: r'''<pre><code class="lang-python">def hello():
    print("hi")
    return 42
</code></pre>
''',
    notes: r'''python 函数,验证非 dart 语言 lang-xxx 解析。''',
    source: r'''https://example.com/t/sample/1/code2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''definition_list/nested_blocks.html''',
    html: r'''<dl>
<dt>常见问题</dt>
<dd>
<p>这是第一段释义。</p>
<ul>
<li>要点一</li>
<li>要点二</li>
</ul>
</dd>
</dl>
''',
    notes: r'''dd 内含块级子节点(段落 + 嵌套无序列表)。验证 dd 走 _parseBlocks 递归、
dd 内块级走 compact factory(消除多余段距),左缩进 40 仍生效。''',
    source: r'''https://example.com/t/sample/1/dl2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''definition_list/simple.html''',
    html: r'''<dl>
<dt>HTML</dt>
<dd>超文本标记语言,用于描述网页结构。</dd>
<dt>CSS</dt>
<dd>层叠样式表,用于描述网页表现。</dd>
<dd>可与 HTML/SVG/XML 等配合使用。</dd>
</dl>
''',
    notes: r'''最基础定义列表(dl + dt/dd,含「一个 dt 多个 dd」)。验证 DefinitionListNode/
DefinitionItem 解析 + dt 常规字重 + dd 左缩进 40(对齐 fwfh/浏览器默认 dl)。''',
    source: r'''https://example.com/t/sample/1/dl1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''details/nested.html''',
    html: r'''<details>
<summary>外层</summary>
<p>外层内容。</p>
<details>
<summary>内层</summary>
<p>内层内容。</p>
</details>
</details>
''',
    notes: r'''两层嵌套 <details>。验证 _parseDetails 递归 + buildDetails 递归 build,
内层独立展开/折叠不互相影响。''',
    source: r'''https://example.com/t/sample/1/details3''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''details/open_with_rich.html''',
    html: r'''<details open>
<summary>默认展开</summary>
<p>这是 <details open> 默认展开形态。</p>
<p>含多段 + <strong>样式</strong> + <a href="https://example.com">链接</a>。</p>
</details>
''',
    notes: r'''<details open> 默认展开 + 内含富文本(多段 + 样式 + 链接)。
验证 initiallyOpen=true 时 buildBody 立即构造 + 子节点递归走 compact factory
(消除嵌套 paragraph 多余 margin)。''',
    source: r'''https://example.com/t/sample/1/details2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''details/simple_closed.html''',
    html: r'''<details>
<summary>点我展开</summary>
<p>这是被折叠的内容,默认折叠状态。</p>
</details>
''',
    notes: r'''最简形态:<details> 默认折叠,只显示标题栏 + 旋转箭头。
点击箭头展开,heightFactor 200ms easeInOut。''',
    source: r'''https://example.com/t/sample/1/details1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''emoji/custom_emoji.html''',
    html: r'''<p>自定义表情 <img src="https://cdn.example.com/uploads/custom/bili_114.gif" alt=":bili_114:" class="emoji emoji-custom" title=":bili_114:"> 来自 Discourse。</p>
''',
    notes: r'''自定义 emoji(Discourse extendedEmojiMap,服务端 customEmoji),URL 来自
CDN 而非确定性路径。验证 parser 不做 CDN 重写,把原 src 原样存入
EmojiRun.url —— 主项目的 EmojiImageBuilder 自行做 CDN 路由。
附加 `emoji-custom` class 不影响 parser(只检查 `emoji`)。''',
    source: r'''https://example.com/t/sample/1/emoji4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''emoji/in_heading_vs_paragraph.html''',
    html: r'''<h2>H2 标题里 <img src="https://example.com/images/emoji/twitter/star.png?v=12" alt=":star:" class="emoji" title=":star:"> 的 emoji</h2>
<p>段落里 <img src="https://example.com/images/emoji/twitter/star.png?v=12" alt=":star:" class="emoji" title=":star:"> 的 emoji 应该比上面小。</p>
''',
    notes: r'''H2 里的 emoji 应该跟随父字号(更大),段落里的 emoji 是 1em。
验证 emoji 尺寸跟随 baseStyle.fontSize(InlineFlattener 把
baseStyle.fontSize 传给 emojiBuilder 作 size)。''',
    source: r'''https://example.com/t/sample/1/emoji5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''emoji/multiple.html''',
    html: r'''<p>多个表情 <img src="https://example.com/images/emoji/twitter/smile.png?v=12" alt=":smile:" class="emoji" title=":smile:"> <img src="https://example.com/images/emoji/twitter/heart.png?v=12" alt=":heart:" class="emoji" title=":heart:"> <img src="https://example.com/images/emoji/twitter/fire.png?v=12" alt=":fire:" class="emoji" title=":fire:"> 一起。</p>
''',
    notes: r'''一段里多个 emoji 紧邻,验证 WidgetSpan 之间不互相错位。''',
    source: r'''https://example.com/t/sample/1/emoji2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''emoji/only_emoji_large.html''',
    html: r'''<p><img src="https://example.com/images/emoji/twitter/tada.png?v=12" alt=":tada:" class="emoji only-emoji" title=":tada:"></p>
''',
    notes: r'''整段仅含 emoji + class="only-emoji",Discourse 渲染为 32dp 大图。
验证 EmojiRun.isOnlyEmoji 解析 + 32px 显示。''',
    source: r'''https://example.com/t/sample/1/emoji3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''emoji/simple_heart.html''',
    html: r'''<p>Hello <img src="https://example.com/images/emoji/twitter/heart.png?v=12" alt=":heart:" class="emoji" title=":heart:"> world.</p>
''',
    notes: r'''最基础形态:段落内嵌 :heart: 标准 emoji。验证 EmojiRun 解析 +
WidgetSpan 渲染 + 1em 字号(跟 baseStyle 一致)。''',
    source: r'''https://example.com/t/sample/1/emoji1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''footnote/inline_with_other.html''',
    html: r'''<p>含 <strong>加粗</strong>、<em>斜体</em>、<code>code</code> 和脚注 <sup class="footnote-ref"><a href="#fn:x">1</a></sup> 的混合段。</p>
<section class="footnotes">
<ol class="footnotes-list">
<li id="fn:x"><p>脚注里也能有 <a href="https://example.com">链接</a>。<a class="footnote-backref" href="#x">↩︎</a></p></li>
</ol>
</section>
''',
    notes: r'''脚注引用与 strong / em / inline_code / a 混排;脚注正文含 a 链接。
无 hr.footnotes-sep(部分 cooked 形态省略)。''',
    source: r'''https://example.com/t/sample/1/fn3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''footnote/multiple_refs.html''',
    html: r'''<p>第一个 <sup class="footnote-ref"><a href="#fn:a">1</a></sup>,第二个 <sup class="footnote-ref"><a href="#fn:b">2</a></sup>,第三个 <sup class="footnote-ref"><a href="#fn:c">3</a></sup>。</p>
<hr class="footnotes-sep">
<section class="footnotes">
<ol class="footnotes-list">
<li id="fn:a"><p>脚注 A 的内容。<a class="footnote-backref" href="#x">↩︎</a></p></li>
<li id="fn:b"><p>脚注 B 的内容,可以含 <strong>样式</strong>。<a class="footnote-backref" href="#x">↩︎</a></p></li>
<li id="fn:c"><p>脚注 C。<a class="footnote-backref" href="#x">↩︎</a></p></li>
</ol>
</section>
''',
    notes: r'''3 个脚注引用,内容含 inline 样式;验证多 ref 各自取对应 content。''',
    source: r'''https://example.com/t/sample/1/fn2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''footnote/section_list.html''',
    html: r'''<p>第一处引用 <sup class="footnote-ref"><a href="#fn:1">1</a></sup>,第二处引用 <sup class="footnote-ref"><a href="#fn:2">2</a></sup>。</p>
<hr class="footnotes-sep">
<section class="footnotes">
<ol class="footnotes-list">
<li id="fn:1"><p>第一条脚注,含 <a href="https://example.com">链接</a> 和 <strong>加粗</strong>。 <a class="footnote-backref" href="#fnref:1">↩︎</a></p></li>
<li id="fn:2"><p>第二条脚注正文。 <a class="footnote-backref" href="#fnref:2">↩︎</a></p></li>
</ol>
</section>
''',
    notes: r'''底部脚注区:正文 2 处上标 + section.footnotes 渲染成「分隔线 + 编号列表」。
验证 FootnotesSectionNode.entries 解析(id/number/inlines,strip backref),
正文条目保留链接/加粗;上标 popover 与底部列表并存。''',
    source: r'''https://example.com/t/sample/1/fn-section''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''footnote/single_ref.html''',
    html: r'''<p>正文中引用脚注 <sup class="footnote-ref"><a href="#fn:1">1</a></sup> 一下。</p>
<hr class="footnotes-sep">
<section class="footnotes">
<ol class="footnotes-list">
<li id="fn:1"><p>这是脚注正文。 <a class="footnote-backref" href="#fnref:1">↩︎</a></p></li>
</ol>
</section>
''',
    notes: r'''单个脚注引用 + section.footnotes 隐藏占位。
渲染:正文段 + 蓝色 [1] 上标(点击调 footnoteTapHandler)+ section 隐藏。''',
    source: r'''https://example.com/t/sample/1/fn1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h1_h2_h3.html''',
    html: r'''<h1>顶层标题</h1>
<h2>二级标题</h2>
<h3>三级标题</h3>
''',
    notes: r'''h1/h2/h3 三级标题相邻,用于验证标题样式 + margin 折叠。''',
    source: r'''https://example.com/t/sample/1/2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h1_only.html''',
    html: r'''<h1>这是一级标题(h1)</h1>
''',
    notes: r'''最简形态:单个 <h1>,验证最大字号 + 加粗 + 上下间距。''',
    source: r'''https://example.com/t/sample/1/h1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h2_only.html''',
    html: r'''<h2>这是二级标题(h2)</h2>
''',
    notes: r'''单个 <h2>,Discourse 最常用的标题级别。''',
    source: r'''https://example.com/t/sample/1/h2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h2_with_inline.html''',
    html: r'''<h2>标题中含 <em>斜体</em> 和 <strong>粗体</strong> 与 <br>换行</h2>
''',
    notes: r'''h2 内含 <em> / <strong> / <br>,验证 heading 复用 InlineFlattener
的嵌套样式合并 + LineBreak。''',
    source: r'''https://example.com/t/sample/1/h2-inline''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h3_only.html''',
    html: r'''<h3>这是三级标题(h3)</h3>
''',
    notes: r'''单个 <h3>。''',
    source: r'''https://example.com/t/sample/1/h3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/h4_h5_h6.html''',
    html: r'''<h4>这是四级标题(h4)</h4>
<h5>这是五级标题(h5)</h5>
<h6>这是六级标题(h6)</h6>
''',
    notes: r'''h4 / h5 / h6 三个低级别标题相邻,验证字号梯度 + 间距。''',
    source: r'''https://example.com/t/sample/1/h456''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''heading/heading_with_paragraphs.html''',
    html: r'''<h2>章节 1</h2>
<p>这是章节 1 的正文,验证 heading 跟下一段 paragraph 的间距。</p>
<h2>章节 2</h2>
<p>章节 2 的正文段落。</p>
''',
    notes: r'''heading 跟 paragraph 交替,验证两类节点间距过渡是否符合视觉直觉
(heading 上下 margin 大于 paragraph)。''',
    source: r'''https://example.com/t/sample/1/h2-p''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''horizontal_rule/between_paragraphs.html''',
    html: r'''<p>前一段。</p>
<hr>
<p>后一段。</p>
''',
    notes: r'''hr 在两段之间,验证视觉分隔效果:p 段落本身上下有 1em margin,
hr 自带 12 上下 padding,叠加不会塌缩(Column 不折叠 margin)。''',
    source: r'''https://example.com/t/sample/1/hr2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''horizontal_rule/multiple_consecutive.html''',
    html: r'''<hr>
<hr>
<hr>
''',
    notes: r'''连续 3 条 hr(罕见但合法)。每条独立 BlockNode,id 各自递增;
视觉上三条等距分隔线。''',
    source: r'''https://example.com/t/sample/1/hr3''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''horizontal_rule/simple.html''',
    html: r'''<hr>
''',
    notes: r'''最基础形态:单独一条 hr。验证 HorizontalRuleNode 解析 + 1px 线
+ 上下 12 padding。''',
    source: r'''https://example.com/t/sample/1/hr1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''iframe/codepen_sandboxed.html''',
    html: r'''<iframe src="https://codepen.io/team/codepen/embed/PNaGbb" sandbox="allow-scripts allow-same-origin" referrerpolicy="no-referrer" loading="lazy" width="600" height="400"></iframe>
''',
    notes: r'''CodePen 嵌入(带 sandbox + referrerpolicy + loading=lazy)。
验证多属性 parse:sandboxFlags={allow-scripts, allow-same-origin}
+ lazyLoad=true + referrerPolicy="no-referrer"。''',
    source: r'''https://example.com/t/sample/1/if2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''iframe/lazy_data_src.html''',
    html: r'''<iframe data-src="https://player.bilibili.com/player.html?bvid=BVxxx" width="800" height="450"></iframe>
''',
    notes: r'''lazy 形态:`src` 缺失,`data-src` 提供真实 URL(Discourse 懒加载常见)。
parser 应该 fallback 到 data-src。''',
    source: r'''https://example.com/t/sample/1/if3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''iframe/youtube_embed.html''',
    html: r'''<iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ" width="560" height="315" allow="autoplay; encrypted-media; picture-in-picture" allowfullscreen title="嵌入的 YouTube 视频"></iframe>
''',
    notes: r'''YouTube 嵌入 iframe(典型 16:9 + allowfullscreen + allow Permissions Policy)。
渲染:子包占位卡(图标 + youtube.com 域名 + 完整 src + 箭头)。
主项目接 iframeBuilder 后会替换为真实 webview。''',
    source: r'''https://example.com/t/sample/1/if1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image/figure_with_caption.html''',
    html: r'''<figure>
<img src="https://example.com/upload/diagram.png" alt="架构图" width="600" height="360">
<figcaption>图 1:系统整体架构</figcaption>
</figure>
''',
    notes: r'''<figure> 图片容器 + <figcaption> 说明(通用 HTML / Discourse 偶发形态)。
legacy 走 fwfh:figure=block(margin 1em 40px)+ 内部 img + figcaption(block,
浏览器默认左对齐正常字号)。新引擎块级 switch 此前无 figure case → default
文本兜底:丢掉 <img>,只把 figcaption 文字当纯文本渲染(丢图 bug)。
期望:拆壳 → image-only ParagraphNode(ImageRun src=diagram.png 600x360)
+ 居中小字 caption 段(StyledRun.small + textAlign.center,文本「图 1:系统整体架构」)。
sha256 占位:本 fixture 为新引擎构造样例非线上抓取,提交前可用真实 cooked 替换并重算。''',
    source: r'''https://example.com/t/sample/1/figure1''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/inside_link.html''',
    html: r'''<p>点击查看大图:<a href="https://example.com/lightbox/foo"><img src="https://example.com/upload/thumb.png" alt="thumbnail" width="100" height="100"></a></p>
''',
    notes: r'''img 嵌套在 link 内 — 验证 LinkRun.children 含 ImageRun 正常解析。
WidgetSpan 不吃 TextSpan 的 recognizer:flattener 用 ImageLinkScope 把
外层链接的点击回调递给图片,主项目图片 widget 读到后单击改为打开链接。''',
    source: r'''https://example.com/t/sample/1/img4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/lightbox_consecutive.html''',
    html: r'''<p><strong>段落 1。</strong></p>
<p><div class="lightbox-wrapper"><a class="lightbox" href="https://cdn.example.com/original/img1.png" title="img1"><img src="https://cdn.example.com/optimized/img1_690x52.png" alt="img1" width="690" height="52"><div class="meta"><svg class="d-icon"><use href="#far-image"></use></svg><span class="filename">img1</span><span class="informations">1686×128 15.7 KB</span></div></a></div><br>
<div class="lightbox-wrapper"><a class="lightbox" href="https://cdn.example.com/original/img2.png" title="img2"><img src="https://cdn.example.com/optimized/img2_509x500.png" alt="img2" width="509" height="500"><div class="meta"><svg class="d-icon"><use href="#far-image"></use></svg><span class="filename">img2</span><span class="informations">832×816 54.4 KB</span></div></a></div></p>
<p><strong>段落 2,两图之后。</strong></p>
''',
    notes: r'''两张连续 lightbox-wrapper(中间 <br> 分隔)。重要回归 case:
不能让两张图各产 ParagraphNode,否则 1em+1em margin 堆出大空隙。
parser 改:lightbox 走 pendingInlines 流,两张图 + LineBreakRun 合并
到同一 ParagraphNode,自然垂直排列且段间距正常。''',
    source: r'''https://example.com/t/sample/1/img7''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/lightbox_wrapper.html''',
    html: r'''<p><strong>段落 1。</strong></p>
<p><div class="lightbox-wrapper"><a class="lightbox" href="https://cdn.example.com/original/4X/d/1/e/abcdef.png" data-download-href="/uploads/short-url/xyz.png?dl=1" title="d5112e737a71778e6de420459be91f92" rel="noopener nofollow ugc"><img src="https://cdn.example.com/optimized/4X/d/1/e/abcdef_2_690x52.png" alt="d5112e737a71778e6de420459be91f92" data-base62-sha1="xyz" width="690" height="52" srcset="https://cdn.example.com/optimized/4X/d/1/e/abcdef_2_690x52.png, https://cdn.example.com/optimized/4X/d/1/e/abcdef_2_1035x78.png 1.5x, https://cdn.example.com/optimized/4X/d/1/e/abcdef_2_1380x104.png 2x" data-dominant-color="E8F0D5"><div class="meta"><svg class="fa d-icon d-icon-far-image svg-icon" aria-hidden="true"><use href="#far-image"></use></svg><span class="filename">d5112e737a71778e6de420459be91f92</span><span class="informations">1686×128 15.7 KB</span><svg class="fa d-icon d-icon-discourse-expand svg-icon" aria-hidden="true"><use href="#discourse-expand"></use></svg></div></a></div></p>
<p><strong>段落 2,图片之后。</strong></p>

''',
    notes: r'''Discourse cooked 把上传图包成 lightbox-wrapper:
  div.lightbox-wrapper > a.lightbox(href=原图) > img(src=缩略图) +
  div.meta(文件名 + 尺寸 + svg)
HTML5 不允许 p 含 div,package:html 会自动闭合 p,所以 wrapper 实际
顶层 block。Parser 应该:
  1. 识别 div.lightbox-wrapper
  2. 提 img 的 src (缩略图) + a 的 href (原图,填 lightboxUrl)
  3. .meta 子树不进 textContent(否则会显示 filename + 尺寸 KB 文字)
  4. 契约字段全提取(2026-07 按官方 cooked_processor_mixin 补):
     srcset(1x/1.5x/2x 档位)→ ImageRun.srcset;
     data-dominant-color → dominantColor(官方唯一加载占位);
     data-base62-sha1 → base62Sha1(稳定标识);
     .informations "1686×128 15.7 KB" → naturalWidth/Height(原图
     尺寸,img width/height 是显示尺寸)+ fileSizeText。
没修之前:全靠 fallback textContent 把 .meta 文字渲染成 "filename 尺寸 KB"。''',
    source: r'''https://example.com/t/sample/1/img6''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/multiple_in_paragraph.html''',
    html: r'''<p>对比图:<img src="https://example.com/upload/before.png" alt="before" width="120" height="80"> 和 <img src="https://example.com/upload/after.png" alt="after" width="120" height="80"></p>
''',
    notes: r'''一段里多张图,验证 WidgetSpan 之间正常排列 + 中间文本不被吞。''',
    source: r'''https://example.com/t/sample/1/img3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image/picture_responsive.html''',
    html: r'''<picture><source srcset="https://example.com/upload/hero-480.webp 480w, https://example.com/upload/hero-960.webp 960w" type="image/webp"><img src="https://example.com/upload/hero.png" alt="响应式图片" width="480" height="270"></picture>
''',
    notes: r'''块级 <picture>(响应式图片:多个 <source srcset> + <img> fallback)。
fwfh 不认 picture/source,只渲染内部 <img> fallback、忽略 srcset;新引擎块级
switch 此前无 case → default 文本兜底,而 <img> 在 picture 内不被块级 default
收集 → 整张图丢失(probe 实测 nodes=[])。
期望:拆壳 → 单图 ParagraphNode,ImageRun src=hero.png(取 <img> fallback,
480x270)。无 <img> 时才回退取首个 source srcset 首个 URL。
sha256 占位:同 figure_with_caption,提交前可替换为真实 cooked 并重算。''',
    source: r'''https://example.com/t/sample/1/picture1''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/simple.html''',
    html: r'''<p>看这张截图:<img src="https://example.com/upload/screenshot.png" alt="screenshot"></p>
''',
    notes: r'''最基础形态:段落内一张无尺寸 img。验证 ImageRun 解析(width/height
= null)+ 子包默认 builder 走 fallback placeholder(假 URL 加载失败)。''',
    source: r'''https://example.com/t/sample/1/img1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image/standalone_blocks.html''',
    html: r'''<p>第一张图:</p>
<p><img src="https://example.com/upload/first.png" alt="first" width="200" height="120"></p>
<p>第二张图:</p>
<p><img src="https://example.com/upload/second.png" alt="second" width="200" height="120"></p>
''',
    notes: r'''Discourse 通常把图片 cooked 成独立 `<p><img></p>` 块,验证两张图
各自独立段落。这是图片帖正文最常见的形态。''',
    source: r'''https://example.com/t/sample/1/img5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''image/with_dimensions.html''',
    html: r'''<p>固定尺寸的图:<img src="https://example.com/upload/diagram.png" alt="diagram" width="200" height="120"></p>
''',
    notes: r'''带 width/height attribute,验证 parser 把数字 attribute 转 double
填到 ImageRun.width/height,fallback placeholder 用这个尺寸撑出
正确的占位框。''',
    source: r'''https://example.com/t/sample/1/img2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image_grid/carousel_mode.html''',
    html: r'''<div class="d-image-grid d-image-grid--carousel" data-mode="carousel">
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/c1.jpg"><img src="https://example.com/c1_thumb.jpg" alt="片 1" width="800" height="450"></a></div>
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/c2.jpg"><img src="https://example.com/c2_thumb.jpg" alt="片 2" width="800" height="450"></a></div>
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/c3.jpg"><img src="https://example.com/c3_thumb.jpg" alt="片 3" width="800" height="450"></a></div>
</div>
''',
    notes: r'''d-image-grid--carousel + data-mode=carousel。
子包 fallback 渲染:单列大图垂直叠(主项目可 override 实现真 carousel)。''',
    source: r'''https://example.com/t/sample/1/grid3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image_grid/skip_emoji_avatar.html''',
    html: r'''<div class="d-image-grid" data-columns="2">
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full1.jpg"><img src="https://example.com/thumb1.jpg" alt="正常图" width="600" height="400"></a></div>
<img class="emoji" src=":heart:" alt="emoji 不计入">
<img class="avatar" src="https://example.com/avatar.png" alt="头像 不计入">
<img class="thumbnail" src="https://example.com/yt_thumb.jpg" alt="yt 缩略 不计入">
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full2.jpg"><img src="https://example.com/thumb2.jpg" alt="另一张正常图" width="600" height="400"></a></div>
</div>
''',
    notes: r'''跳过 emoji/avatar/thumbnail 类 img,只保留 2 张正常图。
对齐 legacy extractGridImages skip list。''',
    source: r'''https://example.com/t/sample/1/grid4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image_grid/three_columns_bare_img.html''',
    html: r'''<div class="d-image-grid" data-columns="3">
<img src="https://example.com/a.jpg" alt="A" width="300" height="200">
<img src="https://example.com/b.jpg" alt="B" width="300" height="200">
<img src="https://example.com/c.jpg" alt="C" width="300" height="200">
<img src="https://example.com/d.jpg" alt="D" width="300" height="200">
<img src="https://example.com/e.jpg" alt="E" width="300" height="200">
<img src="https://example.com/f.jpg" alt="F" width="300" height="200">
</div>
''',
    notes: r'''d-image-grid data-columns=3,6 张裸 img 无 lightbox-wrapper。
渲染:Wrap 三列,每张无 lightboxUrl(走 imageContentBuilder 默认行为)。''',
    source: r'''https://example.com/t/sample/1/grid2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''image_grid/two_columns_lightbox.html''',
    html: r'''<div class="d-image-grid" data-columns="2">
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full1.jpg"><img src="https://example.com/thumb1.jpg" alt="图 1" width="600" height="400"></a></div>
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full2.jpg"><img src="https://example.com/thumb2.jpg" alt="图 2" width="600" height="400"></a></div>
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full3.jpg"><img src="https://example.com/thumb3.jpg" alt="图 3" width="600" height="600"></a></div>
<div class="lightbox-wrapper"><a class="lightbox" href="https://example.com/full4.jpg"><img src="https://example.com/thumb4.jpg" alt="图 4" width="600" height="400"></a></div>
</div>
''',
    notes: r'''d-image-grid data-columns=2,4 张图,每张被 lightbox-wrapper 包裹。
渲染:Wrap 两列,每瓦片有 lightboxUrl(可点查看大图)。''',
    source: r'''https://example.com/t/sample/1/grid1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/inside_link.html''',
    html: r'''<p>查看 <a href="https://api.flutter.dev/flutter/widgets/RichText-class.html"><code>RichText</code> 文档</a> 了解细节。</p>
''',
    notes: r'''Inline code 嵌套在 link 内 — 验证 LinkRun.children 含 InlineCodeRun 时
正常渲染:tap 区域含 code 文本,code 仍是 monospace + 灰底,link 下划线
覆盖 code 文本。''',
    source: r'''https://example.com/t/sample/1/inline_code5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/long_breaking.html''',
    html: r'''<p>长命令示例:<code>flutter run -d macos --dart-define=FLAVOR=staging --observatory-port=9100</code> 在终端里换行也要正常显示。</p>
''',
    notes: r'''超长 inline code,会强制跨行。当前阶段灰底用 TextStyle.background
(矩形),跨行会出现两行各自带矩形(不会合并)。这是已知缺陷,
阶段 5 自研 paint 时补齐(对应 InlineCodePainter 跨行 RRect 合并)。''',
    source: r'''https://example.com/t/sample/1/inline_code4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/multiple.html''',
    html: r'''<p>常用命令有 <code>git status</code>、<code>git diff</code> 和 <code>git log</code>,各自查看不同信息。</p>
''',
    notes: r'''一段里多个 InlineCodeRun 紧邻,验证灰底不要错位、相邻代码段之间正常
断字。''',
    source: r'''https://example.com/t/sample/1/inline_code2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/simple.html''',
    html: r'''<p>使用 <code>flutter pub get</code> 拉取依赖。</p>
''',
    notes: r'''最简单的行内代码:中文段落里夹一段命令。验证 InlineCodeRun 基础渲染
(monospace + 灰底)。''',
    source: r'''https://example.com/t/sample/1/inline_code1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/special_chars.html''',
    html: r'''<p>注意 HTML 实体:<code>&lt;div class="foo"&gt;</code> 在源码里是字面值。</p>
''',
    notes: r'''代码内含 HTML 实体(&lt; &gt; &amp; &quot;),package:html 应自动反转义
成 < > & ",InlineCodeRun.text 应是字面值。''',
    source: r'''https://example.com/t/sample/1/inline_code3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''inline_code/strong_code_mix.html''',
    html: r'''<p>asdfas<strong>dfasdf</strong>asdf<code>asdf</code>as<strong>dfasdf</strong><code>codex Sign-in failed: {"code":-32603...(os error 10013)"}</code></p>
''',
    notes: r'''strong 与 inline code 紧邻混排 + 长 code。复现 #16(spoiler 内)inline code
灰底背景错位/溢出到相邻文字的场景,此处去掉 spoiler 容器以隔离变量。''',
    source: r'''https://example.com/t/sample/1/inline_code_strong_mix''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''lazy_video/tiktok_no_title.html''',
    html: r'''<div class="lazy-video-container" data-video-id="7234567890123456789" data-video-title="" data-video-start-time="" data-provider-name="tiktok">
<a class="title-link" href="https://www.tiktok.com/@user/video/7234567890123456789">
<img src="https://example.com/tt-thumb.jpg" alt="">
</a>
</div>
''',
    notes: r'''TikTok 无标题(标题栏不渲染),验证空 title 边界。
品牌色近黑(#010101)。''',
    source: r'''https://example.com/t/sample/1/lv3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''lazy_video/vimeo_with_start_time.html''',
    html: r'''<div class="lazy-video-container" data-video-id="123456789" data-video-title="A Vimeo Sample" data-video-start-time="1m30s" data-provider-name="vimeo">
<a class="title-link" href="https://vimeo.com/123456789">
<img src="https://i.vimeocdn.com/video/123456789.jpg" alt="缩略图">
</a>
</div>
''',
    notes: r'''Vimeo 视频 + start-time "1m30s" 偏移。
品牌色蓝青(#1AB7EA)。''',
    source: r'''https://example.com/t/sample/1/lv2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''lazy_video/youtube_basic.html''',
    html: r'''<div class="lazy-video-container" data-video-id="dQw4w9WgXcQ" data-video-title="Sample YouTube Video" data-video-start-time="0" data-provider-name="youtube">
<a class="title-link" href="https://www.youtube.com/watch?v=dQw4w9WgXcQ">
<img src="https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg" alt="缩略图">
</a>
</div>
''',
    notes: r'''YouTube 懒加载视频(无 start-time)。
渲染:16:9 缩略图 + 红色播放按钮 + 标题栏(可点跳 youtube url)。''',
    source: r'''https://example.com/t/sample/1/lv1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''lightbox/bare_anchor.html''',
    html: r'''<p>手工构造的裸 lightbox 链接:<a class="lightbox" href="https://example.com/uploads/original/artwork.png" title="artwork.png" rel="noopener nofollow ugc"><img src="https://example.com/uploads/optimized/artwork_600x400.png" alt="artwork" width="600" height="400"></a> 点开进 gallery。</p>
''',
    notes: r'''裸 a.lightbox(无 div.lightbox-wrapper 包裹)包 img:Discourse Web 端
gallery(Photoswipe)的数据源口径是 DOM 的 a.lightbox,不依赖 wrapper
(见 collectLightboxImageRuns)。Parser 应提缩略图 src + a[href] 填
lightboxUrl。与 image/inside_link(普通 <a> 包 img,无 lightbox class,
不产 lightboxUrl)区分。手工构造(NodeKind.lightbox 此前无 fixture 目录,
空目录不进 git,node_kind_alignment_test 在新 checkout 上必红)。''',
    source: r'''https://example.com/t/sample/1/2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''list/block_children_faq.html''',
    html: r'''<ul>
<li>
<h4>Q: 这是问题标题</h4>
<p>A: 这是回答正文,应当与问题分行显示。</p>
<ul>
<li>子要点 A</li>
<li>子要点 B</li>
</ul>
</li>
<li>普通的纯文本列表项(走 inline 快路径)</li>
</ul>
''',
    notes: r'''列表项含块级子节点(FAQ 式):<li> 内 <h4> 问题 + <p> 回答 + 嵌套 ul。
ListItem.blocks → marker + Column(块级),Q/A 分行;末项纯文本走 inline 快路径。''',
    source: r'''https://example.com/t/sample/1/faqlist''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''list/block_li_nested_ol_start.html''',
    html: r'''<ul>
<li>
<h4>Q: 官网 / 中转站 接入区别</h4>
<p>A:</p>
<ul>
<li>
<ol>
<li>官网：设定 <code>HTTP_PROXY</code> 环境变量正常登录即可</li>
</ol>
<ul>
<li>有使用Claude code的大佬吗</li>
<li>使用claude code 提示offline</li>
</ul>
</li>
</ul>
<hr>
<ul>
<li>
<ol start="2">
<li>中转站：使用其提供的api端点地址和key设定即可</li>
</ol>
<ul>
<li><code>ANTHROPIC_BASE_URL</code> (需是 Anthropic 形式接口)</li>
<li><code>ANTHROPIC_AUTH_TOKEN</code> (有极高概率是此项)
<ul>
<li><mark>二选一而非可以共存</mark><br>
<br></li>
</ul>
</li>
</ul>
</li>
</ul>
<hr>
<ul>
<li>
<ol start="3">
<li>自定义 Anthropic 兼容接口接入</li>
</ol>
<ul>
<li>同中转站 但KEY处可置空</li>
</ul>
</li>
</ul>
</li>
</ul>
''',
    notes: r'''真实语料(《Claude Code 终极版 FAQ 指南》官网/中转站 Q&A)。守护两个真机 bug:
1. 外层 <li> 仅含嵌套 <ol>+<ul>(无直接文本)→ 不能渲染成空 bullet 独占一行,
   直接渲染嵌套子列表(marker 与嵌套首行合并)。
2. <ol start="2">/<ol start="3"> 续接序号 → marker 必须是 2./3.(不是都 1.)。
另含 Q(h4)/A(p)块级 li、嵌套 ul、mark 高亮。''',
    source: r'''https://linux.do/t/topic/7365217''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''list/nested_ul_ol.html''',
    html: r'''<ul>
<li>外层第一项
<ul>
<li>嵌套 A</li>
<li>嵌套 B</li>
</ul>
</li>
<li>外层第二项
<ol>
<li>嵌套有序 1</li>
<li>嵌套有序 2</li>
</ol>
</li>
</ul>
''',
    notes: r'''嵌套混合(外层 ul 含 li 内 ul 和 li 内 ol)。验证 parser 递归 +
ListItem.children + depth 递增 + renderer 递归 buildList。''',
    source: r'''https://example.com/t/sample/1/list4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''list/ol_simple.html''',
    html: r'''<ol>
<li>第一步:打开终端</li>
<li>第二步:运行命令</li>
<li>第三步:查看结果</li>
</ol>
''',
    notes: r'''最基础有序列表(ol + 3 li)。验证数字 marker (1. 2. 3.) +
ordered = true。''',
    source: r'''https://example.com/t/sample/1/list2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''list/ol_two_digit.html''',
    html: r'''<ol>
<li>第一项</li>
<li>第二项</li>
<li>第三项</li>
<li>第四项</li>
<li>第五项</li>
<li>第六项</li>
<li>第七项</li>
<li>第八项</li>
<li>第九项</li>
<li>第十项</li>
</ol>
''',
    notes: r'''10 项有序列表,验证 "9." 和 "10." 数字 marker 对齐(FontFeature
tabularFigures 等宽数字)。如果没启用等宽特性,9 比 10 窄,文本
起始位置会左移。''',
    source: r'''https://example.com/t/sample/1/list5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''list/ul_simple.html''',
    html: r'''<ul>
<li>苹果</li>
<li>香蕉</li>
<li>橙子</li>
</ul>
''',
    notes: r'''最基础无序列表(ul + 3 li 纯文本)。验证 ListNode/ListItem 解析 +
bullet marker (•) + padding-left 20。''',
    source: r'''https://example.com/t/sample/1/list1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''list/with_inline_mix.html''',
    html: r'''<ul>
<li>第一项 含 <strong>粗体</strong> 和 <a href="https://example.com">链接</a></li>
<li>第二项 含 <code>inline code</code> 和 <em>斜体</em></li>
<li>第三项 含 <img src="https://example.com/images/emoji/twitter/heart.png" alt=":heart:" class="emoji" title=":heart:"> emoji</li>
</ul>
''',
    notes: r'''list 项内含 inline 混排:strong + link + code + em + emoji。
验证 InlineSpanText 在 list item 内正常复用,所有 inline 节点
都能在 li 内正确渲染(包括 LinkRun recognizer + EmojiRun WidgetSpan)。''',
    source: r'''https://example.com/t/sample/1/list3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''local_date/countdown.html''',
    html: r'''<p>距离开抢还有 <span class="discourse-local-date" data-date="2026-10-01" data-time="00:00" data-timezone="Asia/Shanghai" data-countdown="true">3 小时</span>!</p>
''',
    notes: r'''倒计时 chip(data-countdown 属性存在)。
fallback 渲染:时钟图标(schedule_rounded)+ 服务端预渲染 "3 小时"。''',
    source: r'''https://example.com/t/sample/1/ld3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''local_date/date_only.html''',
    html: r'''<p>仅日期:<span class="discourse-local-date" data-date="2026-12-25" data-format="LL">2026年12月25日</span> 圣诞节。</p>
''',
    notes: r'''仅日期 chip(无 data-time,format=LL)。
fallback 渲染:服务端文本 "2026年12月25日"。''',
    source: r'''https://example.com/t/sample/1/ld2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''local_date/meeting_with_timezones.html''',
    html: r'''<p>会议时间:<span class="discourse-local-date" data-date="2026-08-15" data-time="14:30" data-timezone="Asia/Shanghai" data-timezones="Europe/Paris|America/Los_Angeles" data-format="LLL">2026年8月15日 下午2:30</span>,请提前 10 分钟到场。</p>
''',
    notes: r'''会议时间 chip(带时区 + 多时区预览 + LLL 格式)。
子包 fallback:服务端预渲染文本 + 时钟图标。
主项目接入 localDateBuilder 后会换成虚线下划线 + popover 多时区。''',
    source: r'''https://example.com/t/sample/1/ld1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''math/block_quadratic.html''',
    html: r'''<div class="math">x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}</div>
''',
    notes: r'''块级数学公式:经典求根公式。
子包 fallback:monospace 显示 "$x = \frac{...}$" 原文。
主项目接 mathBlockBuilder 后会用 flutter_math_fork 渲染真公式。''',
    source: r'''https://example.com/t/sample/1/mh1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''math/inline_in_paragraph.html''',
    html: r'''<p>欧拉恒等式 <span class="math">e^{i\pi} + 1 = 0</span> 是数学中最美的公式之一。</p>
''',
    notes: r'''行内数学公式:欧拉恒等式嵌在段落中。
子包 fallback:WidgetSpan + monospace "$e^{...}$" 原文。''',
    source: r'''https://example.com/t/sample/1/mh2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''math/mixed_block_inline.html''',
    html: r'''<p>勾股定理:对任意直角三角形,<span class="math">a^2 + b^2 = c^2</span>。</p>
<div class="math">\sum_{i=1}^{n} i = \frac{n(n+1)}{2}</div>
<p>求和公式上面已展示。</p>
''',
    notes: r'''混合 inline + block math 在同一帖子。
验证两种节点都能正确识别 + 段间隔合理。''',
    source: r'''https://example.com/t/sample/1/mh3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''mention/group_mention.html''',
    html: r'''<p>问题反馈给 <a class="mention" href="/u/team_support">@team_support</a> 组,而不是个人。</p>
''',
    notes: r'''group mention(`@team_support`)用法跟单人 mention 完全一致,
主项目用户卡跳转时按 username 自动区分 user / group。这条 fixture
确保 parser 不对 username 形态(下划线 / 短横线)做特殊处理。''',
    source: r'''https://example.com/t/sample/1/mention4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''mention/multiple.html''',
    html: r'''<p>多人 <a class="mention" href="/u/alice">@alice</a> <a class="mention" href="/u/bob">@bob</a> <a class="mention" href="/u/charlie">@charlie</a> 同时参与。</p>
''',
    notes: r'''一段里多个 mention 紧邻,验证 chip 之间不互相错位 + 字间距合理。''',
    source: r'''https://example.com/t/sample/1/mention2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''mention/non_mention_user_link.html''',
    html: r'''<p>普通用户链接 <a href="/u/bob">@bob</a> 没有 class=mention,应该走普通 LinkRun。这种形态由主项目 mentionedUsers 列表识别后追加 class,parser 阶段不该主动猜。</p>
''',
    notes: r'''反例:`<a href="/u/bob">@bob</a>` 没有 class="mention",应该解析为
普通 LinkRun(不带 chip 样式)。验证 parser 只在 class=mention 时
走 MentionRun 分支,主项目若想识别为 mention,应在 cooked HTML
预处理阶段加 class(legacy 是这么做的)。''',
    source: r'''https://example.com/t/sample/1/mention5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''mention/simple.html''',
    html: r'''<p>欢迎 <a class="mention" href="/u/alice">@alice</a> 加入。</p>
''',
    notes: r'''最基础形态:段落内一个 @alice mention。验证 MentionRun 解析 +
chip 样式渲染(灰底圆角 + primary 字 + 0.82em)。''',
    source: r'''https://example.com/t/sample/1/mention1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''mention/with_status_emoji.html''',
    html: r'''<p>状态用户 <a class="mention" href="/u/alice">@alice<img src="https://example.com/images/emoji/twitter/fire.png?v=12" class="emoji mention-status" alt=":fire:" title=":fire:" style="width:14px;height:14px;vertical-align:middle;margin-left:2px"></a> 在线。</p>
''',
    notes: r'''含状态 emoji 的 mention(Discourse 主项目通过 _preprocessHtml 注入
`<img class="emoji mention-status">`,parser 把它从 a 子树挑出来
填到 MentionRun.statusEmoji)。验证 chip 内 emoji 在用户名右侧 +
size 跟父 chip 字号 * 1.2。''',
    source: r'''https://example.com/t/sample/1/mention3''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''onebox/default_with_thumbnail.html''',
    html: r'''<aside class="onebox allowlistedgeneric" data-onebox-src="https://example.com/article">
<header class="source">
<img src="https://example.com/favicon.ico" class="site-icon" data-dominant-color="3a3a3a" width="32" height="32">
<a href="https://example.com/article" target="_blank" rel="noopener nofollow ugc">example.com</a>
</header>
<article class="onebox-body">
<div class="aspect-image">
<img src="https://example.com/thumb.jpg" class="thumbnail" data-dominant-color="888888" width="690" height="345">
</div>
<h3><a href="https://example.com/article" target="_blank" rel="noopener nofollow ugc">A Generic Article Title</a></h3>
<p>This is the article description shown in the onebox preview card,
providing a few lines of summary so the reader gets context before
clicking through to the actual page.</p>
</article>
</aside>
''',
    notes: r'''Discourse 默认 onebox 形态(allowlistedgeneric):header.source 含
favicon + 站点名,article 含 thumbnail + h3 标题 + p 描述。
应识别为 OneboxKind.defaultKind。''',
    source: r'''https://example.com/t/sample/1/onebox1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''onebox/github_pr.html''',
    html: r'''<aside class="onebox githubpullrequest" data-onebox-src="https://github.com/owner/repo/pull/123">
<header class="source">
<img src="https://github.com/favicon.ico" class="site-icon" width="32" height="32">
<a href="https://github.com/owner/repo/pull/123" target="_blank" rel="noopener nofollow ugc">github.com</a>
</header>
<article class="onebox-body">
<h4><a href="https://github.com/owner/repo/pull/123" target="_blank">Add feature X to handle Y</a></h4>
<div class="github-row">
<div class="user">
<img alt="" src="https://avatars.githubusercontent.com/u/12345" class="thumbnail onebox-avatar-inline" width="20" height="20">
<a href="https://github.com/somebody" target="_blank">somebody</a>
</div>
</div>
<p>This PR refactors the X module to support Y. Closes #100, fixes the issue
where users couldn't do Z.</p>
</article>
</aside>
''',
    notes: r'''GitHub Pull Request onebox(class="onebox githubpullrequest")。
应识别为 OneboxKind.github。子包通用卡片只显示标题 + 描述 + favicon;
legacy 完整版含作者头像 / 文件统计等,主项目 oneboxBuilder 可接管。''',
    source: r'''https://example.com/t/sample/1/onebox2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''onebox/youtube.html''',
    html: r'''<aside class="onebox youtube-onebox" data-onebox-src="https://www.youtube.com/watch?v=dQw4w9WgXcQ">
<header class="source">
<img src="https://www.youtube.com/favicon.ico" class="site-icon" width="16" height="16">
<a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ" target="_blank" rel="noopener nofollow ugc">www.youtube.com</a>
</header>
<article class="onebox-body">
<div class="aspect-image-full-size">
<img src="https://img.youtube.com/vi/dQw4w9WgXcQ/maxresdefault.jpg" class="thumbnail" data-dominant-color="222222" width="690" height="388">
</div>
<h3><a href="https://www.youtube.com/watch?v=dQw4w9WgXcQ" target="_blank">A YouTube Video Title</a></h3>
<p>Video description provided by Discourse's youtube onebox.</p>
</article>
</aside>
''',
    notes: r'''YouTube 视频 onebox(class="onebox youtube-onebox")。
应识别为 OneboxKind.video。子包通用卡片展示标题 + 缩略图;
legacy 完整版有播放按钮覆盖 + 时长,主项目可在 oneboxBuilder 内
调 video_onebox_builder。''',
    source: r'''https://example.com/t/sample/1/onebox3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/blank_line_spacer.html''',
    html: r'''<p>引言段落。</p>
<blockquote>
<p><em></em></p>
<div align="center"><em>"我当 工有所偿 学有所用,无人欺我无依傍"</em></div>
<p></p>
</blockquote>
<p>结尾段落。</p>
''',
    notes: r'''作者留白空 <p> → BlankLineNode(≈1em SizedBox,不参与选区)。
对齐浏览器/Discourse 的 CSS margin 折叠:blockquote 有 padding(0.75em),
首尾子 <p><em></em></p> / <p></p> 的 margin 不折叠出去 → 框内各显示一行
留白,诗句因此上下居中。顶层/段落间的空 <p> 会被相邻 margin 折叠掉(不
产空行),故本例诗句的两行留白只出现在 blockquote 内首尾。
居中诗句走 <div align="center"> → 段落 textAlign。''',
    source: r'''https://example.com/t/sample/1/blankline''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/inline_color.html''',
    html: r'''<p>行内着色:<span style="color:#e03e2d">红色警告</span>、<span style="color:green">绿色通过</span>、<span style="background-color:#25AAE2">蓝底高亮</span>,以及<span style="color:#ffffff;background-color:#000000">白字黑底</span>组合。</p>
''',
    notes: r'''行内 CSS 着色(对齐 fwfh 默认读取 style 里的 color / background-color;
Discourse 由 [color=…] / [bgcolor=…] BBCode 产出)。覆盖 hex 字色、命名色、
background-color 底色、字色+底色组合 → ColoredRun。守护"红字不显示"那类缺口。''',
    source: r'''https://example.com/t/sample/1/inlinecolor''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/inline_styles.html''',
    html: r'''<p>行内样式合集:<u>下划线</u>、<s>删除线</s>、<del>已删</del>、<ins>新增</ins>、<small>小字</small>、<big>大字</big>、<mark>高亮</mark>、<kbd>Ctrl</kbd>+<kbd>V</kbd>、化学式 H<sub>2</sub>O 与公式 E=mc<sup>2</sup>。</p>
''',
    notes: r'''行内样式标签合集(对齐 fwfh 默认):u/s/del/ins(下划/删除)、small/big
(字号 0.833x / 1.2x)、mark(#ff0 高亮)、kbd(等宽)、sup/sub(上下标)。
覆盖 StyledRun 各 kind,守护 fwfh 对齐。''',
    source: r'''https://example.com/t/sample/1/inlinestyles''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/inline_svg_skip.html''',
    html: r'''<p>含 <svg class="fa d-icon d-icon-far-image svg-icon" aria-hidden="true"><use href="#far-image"></use></svg> 图标的段落,svg 应该完全跳过,不留任何文字噪音。</p>
''',
    notes: r'''inline `<svg>` (Discourse d-icon)应该被 parser 整体跳过。
不跳过会出现 `<use href="#far-image">` 字面值进 textContent
形成噪音。''',
    source: r'''https://example.com/t/sample/1/svg_skip''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/ins_del_diff.html''',
    html: r'''<p>编辑前:这是 <del>旧文本</del> 段落。</p>
<p>编辑后:这是 <ins>新文本</ins> 段落。</p>
<p>合并:这是 <del>旧</del><ins>新</ins> 部分。</p>
''',
    notes: r'''编辑历史 diff 形态:`<ins>` 新增 / `<del>` 删除。
对齐 fwfh:ins → StyledRun.underline(下划线);del/s → StyledRun.lineThrough
(删除线)。Discourse 的 .diff-ins/.diff-del 绿红底是特化,暂简化为下划/删除线。''',
    source: r'''https://example.com/t/sample/1/insdel''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/link_empty_href.html''',
    html: r'''<p>这是 <a href="">空 href 的 a 标签</a>,应该退化为普通文本。</p>
<p>这是 <a>无 href 的 a 标签</a>,同样退化。</p>
''',
    notes: r'''边界 case:空 href / 无 href 属性的 a 标签。parser 应该退化为
普通文本(展平子节点),不该产生 LinkRun。视觉上跟纯文本一致,
无下划线、不可点。''',
    source: r'''https://example.com/t/sample/1/link5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/link_internal.html''',
    html: r'''<p>内部链接示例:<a href="/t/topic/12345/3">某个话题</a> 和 <a href="/u/alice">某个用户</a>。</p>
''',
    notes: r'''内部链接(/t/topic/.../post 和 /u/username),主项目侧 LinkHandler
应该走 launchContentLink 路由到 TopicDetailPage / UserProfilePage。
子包侧只验证 LinkRun 携带的 href 字符串原值。''',
    source: r'''https://example.com/t/sample/1/link2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/link_multiple.html''',
    html: r'''<p>段落 1 含 <a href="https://example.com/1">链接 1</a>。</p>
<p>段落 2 含 <a href="https://example.com/2">链接 2</a>。</p>
<p>段落 3 含 <a href="https://example.com/3">链接 3</a>。</p>
''',
    notes: r'''多段落 + 每段一个链接,验证多 LinkRun 的 recognizer 全部正确管理
(没有 widget dispose 时 leak)。''',
    source: r'''https://example.com/t/sample/1/link3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/link_simple_external.html''',
    html: r'''<p>这是含 <a href="https://example.com">外部链接</a> 的段落。</p>
''',
    notes: r'''段落内含一个外部 https 链接。验证 LinkRun(InlineNode)基础渲染
(下划线 + 可点击)。link 不是 NodeKind,fixture 归属 paragraph。''',
    source: r'''https://example.com/t/sample/1/link1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/link_with_inline_style.html''',
    html: r'''<p>包含 <a href="https://example.com"><strong>粗体</strong> 和 <em>斜体</em></a> 的链接。</p>
''',
    notes: r'''链接内嵌 <strong> + <em>,验证 link span 内部嵌套样式合并:
bold + italic 样式应该被保留,link 的下划线也应该有。''',
    source: r'''https://example.com/t/sample/1/link4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/multi_p.html''',
    html: r'''<p>第一段内容,普通段落。</p>
<p>第二段,跟第一段之间隔了一个段落边界。</p>
<p>第三段,验证多段渲染顺序与间距。</p>
''',
    notes: r'''三个相邻 <p>,验证多段渲染顺序与垂直间距。''',
    source: r'''https://example.com/t/sample/1/p3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/nested_emphasis.html''',
    html: r'''<p>外层 <em>外层斜体 <strong>嵌套粗体 <em>双重斜体</em> 后续</strong> 后续</em> 收尾</p>
''',
    notes: r'''em / strong 三层嵌套,验证 InlineFlattener 嵌套样式合并。
历史上 fwfh 在深嵌套场景下偶尔丢中间层样式。''',
    source: r'''https://example.com/t/sample/1/p4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/plain_text.html''',
    html: r'''<p>这是一段最简单的纯文本段落,没有任何行内样式。</p>
''',
    notes: r'''最简形态:单个 <p> 内只有纯文本,无任何行内样式。
阶段 1.1 的"基础渲染"用例。''',
    source: r'''https://example.com/t/sample/1/p1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/simple_with_em_strong.html''',
    html: r'''<p>这是一段最简单的段落,含 <em>斜体</em> 与 <strong>粗体</strong>。</p>
''',
    notes: r'''最简形态:一个 <p> 内含 <em> + <strong>。
用于验证段落 + 行内基础样式渲染。''',
    source: r'''https://example.com/t/sample/1/1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/text_align.html''',
    html: r'''<div align="center">居中的一段文字<br>第二行也居中</div>
<p style="text-align:right">右对齐段落</p>
<center>center 标签也居中</center>
''',
    notes: r'''块级对齐:<div align="center"> / <p style="text-align:right"> / <center>。
→ ParagraphNode.textAlign,渲染走 InlineSpanText.textAlign。''',
    source: r'''https://example.com/t/sample/1/textalign''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''paragraph/with_br.html''',
    html: r'''<p>line 1 内容<br>line 2 在 br 之后<br>line 3</p>
''',
    notes: r'''单个段落内含多个 <br> 强制换行,用于验证 LineBreakRun 渲染。''',
    source: r'''https://example.com/t/sample/1/p2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''policy/custom_labels.html''',
    html: r'''<div class="policy" data-version="2" data-groups="trust_level_1,staff" data-accept="我已阅读并同意" data-revoke="我反悔了" data-renewal-days="90" data-reminder="weekly">
<div class="policy-body">
<p>这是一份带自定义按钮文案、续约设置的 policy。</p>
<blockquote>
<p>引用块也能正常嵌套渲染。</p>
</blockquote>
</div>
</div>
''',
    notes: r'''自定义按钮文案 + .policy-body 内层包裹 + 多种属性
(renewal-days, reminder, 多 groups)。
验证 parser 剥 .policy-body + 全 data-* 字段。''',
    source: r'''https://example.com/t/sample/1/pl2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''policy/simple_with_list.html''',
    html: r'''<div class="policy" data-version="1" data-groups="staff">
<p>请仔细阅读以下规则后再接受:</p>
<ul>
<li>禁止恶意刷帖</li>
<li>禁止灌水</li>
<li>禁止人身攻击</li>
</ul>
</div>
''',
    notes: r'''最简 policy:含 paragraph + ul 列表正文。
渲染:边框卡 + body + 静态 footer(默认 "接受" 按钮)。
主项目接 policyBuilder 后会替换为带后端 API 的真实交互。''',
    source: r'''https://example.com/t/sample/1/pl1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''poll/poll_with_title.html''',
    html: r'''<div class="poll" data-poll-name="favorite" data-poll-question="你最喜欢哪个?" data-poll-type="multiple">
<div class="poll-container">
<div class="poll-title">你最喜欢哪个?</div>
<ul>
<li data-poll-option-id="x">Flutter</li>
<li data-poll-option-id="y">React Native</li>
</ul>
</div>
</div>
''',
    notes: r'''带标题 poll(data-poll-question + .poll-title + data-poll-name=favorite)。
验证 parser 标题提取优先级 + 自定义 pollName。''',
    source: r'''https://example.com/t/sample/1/pl-poll2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''poll/regular_poll.html''',
    html: r'''<div class="poll" data-poll-name="poll" data-poll-type="regular" data-poll-status="open">
<div class="poll-container">
<ul>
<li data-poll-option-id="aaa">选项 A</li>
<li data-poll-option-id="bbb">选项 B</li>
<li data-poll-option-id="ccc">选项 C</li>
</ul>
</div>
<div class="poll-info">
<p><span class="info-number">12</span> 人投票</p>
</div>
</div>
''',
    notes: r'''最简 regular poll(data-poll-name=poll)。poll 数据全在 API,
子包只提 pollName + rawHtml,fallback 占位卡显示。
主项目接 pollBuilder 后 legacy buildPoll 从 post.polls 渲染真实选项/票数。''',
    source: r'''https://example.com/t/sample/1/pl-poll1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/nested_quote.html''',
    html: r'''<aside class="quote" data-username="outer_user" data-post="2" data-topic="111">
<div class="title">
<img alt="" src="https://example.com/avatar/outer/40.png" class="avatar">
outer_user:
</div>
<blockquote>
<p>外层引用包了一个内层引用:</p>
<aside class="quote" data-username="inner_user" data-post="1" data-topic="111">
<div class="title">
<img alt="" src="https://example.com/avatar/inner/40.png" class="avatar">
inner_user:
</div>
<blockquote>
<p>这是最内层的引用内容。</p>
</blockquote>
</aside>
<p>外层的回应。</p>
</blockquote>
</aside>
''',
    notes: r'''双层嵌套引用(quote 内含 quote)。验证 parser 递归 + renderer 内递归
build,每层都有自己的灰底 + 头像。''',
    source: r'''https://example.com/t/sample/1/qc4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/no_title_block.html''',
    html: r'''<aside class="quote" data-username="dave" data-post="7" data-topic="999">
<blockquote>
<p>没有标题块,只有 data-username 和正文。</p>
</blockquote>
</aside>
''',
    notes: r'''反例:无 .title 块的 quote(罕见,但 Discourse 某些 plugin 输出会缺)。
验证 parser 容错:avatarUrl/titleText/titleHref 均为 null,头像走
首字母 chip fallback。''',
    source: r'''https://example.com/t/sample/1/qc5''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/single_layer_simple.html''',
    html: r'''<aside class="quote no-group" data-username="alice" data-post="1" data-topic="999">
<div class="title">
<div class="quote-controls"></div>
<img alt="" width="20" height="20" src="https://example.com/avatar/alice/40.png" class="avatar"> alice:</div>
<blockquote>
<p>这是一段被引用的内容。</p>
</blockquote>
</aside>
<p>这是回复正文。</p>
''',
    notes: r'''单层引用卡(aside.quote)含用户头像 + 用户名 + 引用正文,后跟回复段落。
这是 Discourse 最常见的"@回复"形态。''',
    source: r'''https://example.com/t/sample/1/4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/with_category_badge.html''',
    html: r'''<aside class="quote quote-modified" data-post="1" data-topic="2369360">
<div class="title">
<div class="quote-controls"></div>
<img alt="" width="24" height="24" src="https://cdn.ldstatic.com/user_avatar/linux.do/xuanaixuan/48/2026331_2.png" class="avatar">
<div class="quote-title__text-content">
<a href="https://linux.do/t/topic/2369360">【APP 汇总】LinuxDO第三方客户端 <img width="20" height="20" src="https://cdn.ldstatic.com/images/emoji/twemoji/thought_balloon.png?v=15" title="thought_balloon" alt="thought_balloon" class="emoji"></a> <a class="badge-category__wrapper " href="/c/gossip/11"><span data-category-id="11" style="--category-badge-color: #3AB54A; --category-badge-text-color: #000000;" class="badge-category --style-icon "><span class="badge-category__name">搞七捻三</span></span></a>
</div>
</div>
<blockquote>
<p>诸位佬友好呀!</p>
</blockquote>
</aside>
''',
    notes: r'''引用卡:标题含 emoji + 分类徽章(badge-category 彩色标签)。验证 titleInlines
保留标题 emoji/链接、category 结构化提取(名称/底色/文字色/链接),对齐 legacy。''',
    source: r'''https://linux.do/t/topic/2369360''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/with_rich_content.html''',
    html: r'''<aside class="quote" data-username="charlie" data-post="5" data-topic="999">
<div class="title">
<img alt="" src="https://example.com/avatar/charlie/40.png" class="avatar">
charlie:
</div>
<blockquote>
<p>第一段引用,含 <strong>粗体</strong>。</p>
<p>第二段引用,含 <a href="https://example.com">链接</a> 和 <code>code</code>。</p>
<ul>
<li>列表项 1</li>
<li>列表项 2</li>
</ul>
</blockquote>
</aside>
''',
    notes: r'''引用正文含 inline 混排(strong/code/link)+ list,验证 _parseBlocks
在 blockquote 内递归正常,所有 inline + block 都能在 quote 内显示。''',
    source: r'''https://example.com/t/sample/1/qc3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''quote_card/with_title.html''',
    html: r'''<aside class="quote" data-username="bob" data-post="3" data-topic="999">
<div class="title">
<div class="quote-controls"></div>
<img alt="" width="20" height="20" src="https://example.com/avatar/bob/40.png" class="avatar">
<a href="/t/topic-slug/999/3">原帖标题(新版格式)</a>
</div>
<blockquote>
<p>带标题的引用,标题应该是主色可点。</p>
</blockquote>
</aside>
''',
    notes: r'''含标题(.title 内 a 标签)的引用,验证 titleText/titleHref 解析 +
标题主色可点 + linkHandler 路由跳原帖。''',
    source: r'''https://example.com/t/sample/1/qc2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''spoiler/block_simple.html''',
    html: r'''<div class="spoiler">
<p>这是一段块级剧透内容。</p>
<p>包含两段,默认遮蔽,点击展开。</p>
</div>
''',
    notes: r'''块级 div.spoiler,默认显示 "剧透内容,点击显示" 占位,点击后
展开为两段段落。再点收回。''',
    source: r'''https://example.com/t/sample/1/sp2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''spoiler/block_with_rich_content.html''',
    html: r'''<div class="spoiler">
<p>块级剧透,内部含列表和代码:</p>
<ul>
<li>项 1</li>
<li>项 2:<code>flutter run</code></li>
</ul>
<p>结束。</p>
</div>
''',
    notes: r'''块级 spoiler 含 p + ul + code 等混合内容,验证 SpoilerBlockNode.children
是 BlockNode 序列(走 _parseBlocks 递归);揭示后内嵌内容完整展示。''',
    source: r'''https://example.com/t/sample/1/sp4''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''spoiler/inline_simple.html''',
    html: r'''<p>答案是 <span class="spoiler">42</span>,你猜对了吗?</p>
''',
    notes: r'''最基础形态:span.spoiler 行内剧透。默认遮蔽为黑色块,点击展开
显示 "42"。''',
    source: r'''https://example.com/t/sample/1/sp1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''spoiler/inline_with_nested.html''',
    html: r'''<p>含 <span class="spoiler">关键 <strong>剧情</strong></span> 和 <span class="spoiler"><a href="https://example.com">线索链接</a></span> 的句子。</p>
''',
    notes: r'''行内 spoiler 含嵌套样式(strong)和 link。验证 SpoilerRun.children
可以承载任意 inline 节点;揭示后嵌套样式 + 链接全部生效(link 可点)。''',
    source: r'''https://example.com/t/sample/1/sp3''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''svg/d_icon_skipped.html''',
    html: r'''<p>含图标 <svg class="fa d-icon d-icon-far-image svg-icon" aria-hidden="true"><use href="#far-image"></use></svg> 的段落,d-icon 应被跳过不产 SvgNode。</p>
''',
    notes: r'''Discourse d-icon UI 图标(inline,在 <p> 内):应被 _isSkipElement 跳过,
不产 SvgNode、不留文字噪音。验证『内容 svg vs 图标 svg』判定边界。''',
    source: r'''https://example.com/t/sample/1/svg3''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''svg/explicit_size_no_viewbox.html''',
    html: r'''<svg width="160" height="90" xmlns="http://www.w3.org/2000/svg">
  <rect width="160" height="90" fill="#34a853"/>
</svg>
''',
    notes: r'''有显式 width/height 但无 viewBox 的内容 svg:仍应产 SvgNode(对齐 legacy
_buildInlineSvg:viewBox/width/height 任一存在即视为内容 svg)。''',
    source: r'''https://example.com/t/sample/1/svg2''',
    edgeCase: true,
  ),
  FixtureEntry(
    relativePath: r'''svg/inline_viewbox.html''',
    html: r'''<svg viewBox="0 0 200 100" xmlns="http://www.w3.org/2000/svg">
  <rect x="0" y="0" width="200" height="100" fill="#4c8bf5"/>
  <circle cx="100" cy="50" r="30" fill="#ffffff"/>
</svg>
''',
    notes: r'''内容型内联 svg(有 viewBox 的矢量图):应产 SvgNode,携带 outerHtml 源串。
子包 fallback 画占位框;主项目接 svgBuilder 后用 jovial_svg 等比铺满列宽渲染。''',
    source: r'''https://example.com/t/sample/1/svg1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''table/md_table_wrapper.html''',
    html: r'''<div class="md-table">
<table>
<thead>
<tr><th>序号</th><th>名称</th></tr>
</thead>
<tbody>
<tr><td>1</td><td>GitHub 学生包</td></tr>
<tr><td>2</td><td>Azure for Students</td></tr>
</tbody>
</table>
</div>
''',
    notes: r'''Discourse markdown 真实 cooked 形态:<div class="md-table"><table>。
parser 必须透明拆壳 md-table 包裹层,否则整表被展平成纯文本。
(这是实机 dogfood 发现的 bug:EDU 邮箱长帖表格被展平。)''',
    source: r'''https://example.com/t/sample/1/tb5''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''table/no_thead_bare_tr.html''',
    html: r'''<table>
<tr><td>无表头</td><td>所有行都是 body</td></tr>
<tr><td>第二行</td><td>简形态</td></tr>
</table>
''',
    notes: r'''无 thead/tbody,裸 tr。验证 parser fallback:全部行当 body。
hasHeader=false。''',
    source: r'''https://example.com/t/sample/1/tb3''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''table/rich_inline_cells.html''',
    html: r'''<table>
<thead>
<tr><th>项目</th><th>说明</th><th>链接</th></tr>
</thead>
<tbody>
<tr><td><strong>加粗</strong>项</td><td>含 <em>斜体</em> 和 <code>code</code></td><td><a href="https://example.com">点这里</a></td></tr>
<tr><td>普通文本</td><td>包含 <a href="/mention">@user</a> 引用</td><td>无</td></tr>
</tbody>
</table>
''',
    notes: r'''cell 含 strong/em/code/link 富 inline 内容。
验证 cell.children 递归 _parseBlocks 保留全部样式。''',
    source: r'''https://example.com/t/sample/1/tb2''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''table/simple_2col.html''',
    html: r'''<table>
<thead>
<tr><th>列名 A</th><th>列名 B</th></tr>
</thead>
<tbody>
<tr><td>值 1</td><td>值 2</td></tr>
<tr><td>值 3</td><td>值 4</td></tr>
</tbody>
</table>
''',
    notes: r'''最简 2 列 2 行表格,thead + tbody。
渲染:灰底表头加粗 + 边框 + 圆角。''',
    source: r'''https://example.com/t/sample/1/tb1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''table/uneven_columns.html''',
    html: r'''<table>
<thead>
<tr><th>姓名</th><th>年龄</th></tr>
</thead>
<tbody>
<tr><td>张三</td><td>30</td></tr>
<tr><td>李四</td></tr>
<tr><td>王五</td><td>25</td><td>额外列</td></tr>
</tbody>
</table>
''',
    notes: r'''行列数不齐:header 2 列,row1 2 列,row2 1 列(缺),row3 3 列(多)。
columnCount = max = 3;缺列补空,多列正常显示。''',
    source: r'''https://example.com/t/sample/1/tb4''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''video/upload_placeholder.html''',
    html: r'''<p><div class="video-placeholder-container" data-video-src="/uploads/default/original/1X/abcdef1234567890.mp4" data-thumbnail-src="/uploads/default/optimized/1X/abcdef_thumb.png" data-orig-src="upload://eyPnj7UzkU0AkGkx2dx8G4YM1Jx.mp4">
</div></p>
''',
    notes: r'''Discourse 上传视频的主形态(linux.do):cooked 里只有空 div.video-placeholder-container
+ data-video-src(源)+ data-thumbnail-src(封面)+ data-orig-src(upload:// 短链)。
真 <video> 是 web 端运行时注入,App 拿原始 cooked,所以这是最常见形态。
渲染:子包占位卡(有封面 → 16:9 黑底封面 + 播放钮;无 builder)。
主项目接 videoBuilder 后替换为 DiscourseVideoPlayer(chewie)。''',
    source: r'''https://linux.do/t/sample/1/vd1''',
    edgeCase: false,
  ),
  FixtureEntry(
    relativePath: r'''video/video_onebox.html''',
    html: r'''<div class="onebox video-onebox">
  <video controlslist="nodownload" width="100%" height="100%" controls="">
    <source src="https://example.com/uploads/running.mp4" type="video/mp4">
    <a href="https://example.com/uploads/running.mp4">https://example.com/uploads/running.mp4</a>
  </video>
</div>
''',
    notes: r'''旧式/直链视频形态:div.onebox.video-onebox 内含真 <video controls> + <source>。
legacy 这种走 fwfh_chewie(DiscourseVideoPlayer)。width/height=100% 非数字 → 16:9。
渲染:子包占位卡(无封面 → 横条卡)。主项目接 videoBuilder 后用 chewie 播放。''',
    source: r'''https://linux.do/t/sample/1/vd2''',
    edgeCase: false,
  ),
];
