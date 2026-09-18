/// 语义树的保守可逆编辑适配；不经过 Markdown 或阅读端反向转换。
library;

import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'dart:ui' show TextAlign;
import '../../node/node.dart';
import '../model/editable_text_content.dart';
import '../model/editor_state.dart';
import '../model/raw_media_html.dart';
import '../model/inline_spin.dart';
import 'document.dart';
import 'document_codec.dart';

export 'document.dart';

part 'structural_projection.dart';
part 'operation_adapters.dart';
part 'fragment_operations.dart';
part 'transient_operations.dart';
part 'inline_projection.dart';
part 'media_projection.dart';
part 'block_projection.dart';
part 'export_operations.dart';

const _semanticMarkOrder = [
  'em',
  'strong',
  'underline',
  'strikethrough',
  'spoiler',
  'link',
  'code',
];

class SemanticEditorUnsupported implements Exception {
  const SemanticEditorUnsupported(this.message);
  final String message;
  @override
  String toString() => 'SemanticEditorUnsupported: $message';
}

const _kinds = {
  'em': MarkKind.em,
  'strong': MarkKind.strong,
  'code': MarkKind.inlineCode,
  'link': MarkKind.link,
  'underline': MarkKind.underline,
  'strikethrough': MarkKind.lineThrough,
  'spoiler': MarkKind.spoilerInline,
};

/// 原树是唯一事实来源；投影块 id 只在本实例内稳定。
/// 未支持的结构操作显式失败，不从扁平块猜测丢失的容器边界。
class SemanticEditorProjection {
  SemanticEditorProjection._(this.source);
  final SemanticNode source;
  final List<EditorBlock> _blocks = [];
  final Map<String, SemanticNode> _sources = {};
  final Map<String, String> _paths = {};
  // token 绑定稳定块来源，不用节点值相等判断身份。
  final Map<Object, List<String>> _transients = {};
  List<EditorBlock> get blocks => List.unmodifiable(_blocks);
  Map<String, SemanticNode> get sources => Map.unmodifiable(_sources);

  factory SemanticEditorProjection.project(SemanticNode source) {
    if (source.type != 'doc') {
      throw const SemanticEditorUnsupported('根节点必须是 doc');
    }
    final result = SemanticEditorProjection._(source);
    result._walk(source, '', const [], null, 0);
    if (!result._blocks.any((b) => b is TextBlock)) {
      result._blocks.add(
        TextBlock(id: 'semantic_pad', content: EditableTextContent.empty),
      );
    }
    return result;
  }

  void _walk(
    SemanticNode n,
    String path,
    List<ContainerFrame> frames,
    SemanticNode? list,
    int depth,
  ) {
    final id = 'semantic_${_blocks.length}';
    final inline = _inline(n);
    if ({'paragraph', 'heading'}.contains(n.type) &&
        inline != null &&
        (n.type != 'heading' ||
            (n.attrs['level'] is int &&
                n.attrs['level'] >= 1 &&
                n.attrs['level'] <= 6))) {
      _add(
        path,
        n,
        TextBlock(
          id: id,
          content: inline,
          kind: n.type == 'heading'
              ? TextBlockKind.heading
              : list != null
              ? TextBlockKind.listItem
              : TextBlockKind.paragraph,
          headingLevel: n.type == 'heading' ? n.attrs['level'] as int : 1,
          containers: frames,
          depth: depth,
          ordered: list?.type == 'ordered_list',
          listStart: list?.attrs['order'] is int
              ? list!.attrs['order'] as int
              : 1,
          listLoose: list != null && list.attrs['tight'] == false,
        ),
      );
      return;
    }
    final media = _projectMedia(n, id);
    if (media != null) {
      // IslandBlock 无 frames；容器归属由原树路径保留。
      _add(path, n, IslandBlock(id: id, node: media));
      return;
    }
    final block = _projectSemanticBlock(n, id);
    if (block != null) {
      _add(path, n, IslandBlock(id: id, node: block));
      return;
    }
    var nextFrames = frames;
    var children = n.content;
    var skip = 0;
    if (n.type == 'callout') {
      nextFrames = [
        ...frames,
        CalloutFrame(
          kind: CalloutKind.fromType(n.attrs['typeRaw'] as String? ?? 'note'),
          groupId: 'semantic_frame_$path',
          typeRaw: n.attrs['typeRaw'] as String? ?? 'note',
          title: n.attrs['title'] as String?,
          foldable: n.attrs['foldable'] as bool?,
        ),
      ];
    } else if (n.type == 'wrap') {
      // wrap 无额外显示 frame；嵌套归属与属性由来源路径保留。
      nextFrames = frames;
    } else if (n.type == 'spoiler') {
      nextFrames = [...frames, SpoilerFrame(groupId: 'semantic_frame_$path')];
    } else if (n.type == 'blockquote') {
      nextFrames = [...frames, QuoteFrame(groupId: 'semantic_frame_$path')];
    } else if (n.type == 'quote') {
      nextFrames = [
        ...frames,
        QuoteCardFrame(
          groupId: 'semantic_frame_$path',
          username: '${n.attrs['username'] ?? ''}',
          displayName: n.attrs['displayName']?.toString(),
          postNumber: int.tryParse('${n.attrs['postNumber']}'),
          topicId: int.tryParse('${n.attrs['topicId']}'),
          full: n.attrs['full'] == true,
        ),
      ];
    } else if (n.type == 'details' &&
        children.isNotEmpty &&
        children.first.type == 'summary') {
      nextFrames = [
        ...frames,
        DetailsFrame(
          groupId: 'semantic_frame_$path',
          summary: children.first.textContent,
          open: n.attrs['open'] == true,
        ),
      ];
      skip = 1; // summary 原树保留，当前仅编辑正文。
    } else if (!{
      'doc',
      'list_item',
      'ordered_list',
      'bullet_list',
    }.contains(n.type)) {
      _opaque(path, n, id);
      return;
    }
    if (children.length == skip && n.type != 'doc') {
      _opaque(path, n, id); // 空容器不可虚构正文，整体保留。
      return;
    }
    final isList = {'ordered_list', 'bullet_list'}.contains(n.type);
    for (var i = skip; i < children.length; i++) {
      _walk(
        children[i],
        '$path/$i',
        nextFrames,
        isList ? n : list,
        isList && list != null ? depth + 1 : depth,
      );
    }
  }

  void _add(String path, SemanticNode n, EditorBlock block) {
    _blocks.add(block);
    _sources[block.id] = n;
    _paths[block.id] = path;
  }

  void _opaque(String path, SemanticNode n, String id) {
    // 仅占位，不将 JSON 冒充可提交的 rawMarkdown；宿主尚未接入此适配。
    _add(
      path,
      n,
      IslandBlock(
        id: id,
        node: CodeBlockNode(id: id, code: '不透明语义节点：${n.type}'),
      ),
    );
  }

  static EditableTextContent? _inline(SemanticNode n) {
    final text = StringBuffer();
    final marks = <MarkSpan>[];
    final atoms = <int, InlineNode>{};
    final softBreaks = <int>{};
    for (final c in n.content) {
      if (c.type == 'check') {
        if (!_validSemanticAttrs(c.attrs, booleans: {'checked', 'permanent'})) return null;
        final projected = _inline(SemanticNode('paragraph', content: [
          SemanticNode('text', text: c.attrs['permanent'] == true ? '[X]' :
            c.attrs['checked'] == true ? '[x]' : '[ ]', marks: c.marks),
        ]));
        if (projected == null) return null;
        final start = text.length;
        text.write(projected.text);
        marks.addAll(projected.marks.map((m) => m.copyWith(
          start: start + m.start, end: start + m.end)));
        continue;
      }
      if (c.type == 'html_inline') {
        final nested = _projectSemanticHtml(c);
        if (nested == null) return null;
        final start = text.length;
        text.write(nested.text);
        marks.addAll(
          nested.marks.map(
            (m) => m.copyWith(start: m.start + start, end: m.end + start),
          ),
        );
        atoms.addAll(nested.atoms.map((k, v) => MapEntry(k + start, v)));
        softBreaks.addAll(nested.softBreaks.map((v) => v + start));
        continue;
      }
      final atom = _semanticInlineAtom(c);
      if (atom != null) {
        final start = text.length;
        atoms[start] = atom;
        text.write(kAtomChar);
        for (final mark in c.marks) {
          // 特殊链接已由 LinkRun 承载，不再叠加同一 link。
          if (atom is LinkRun && mark.type == 'link') continue;
          marks.add(
            MarkSpan(
              start: start,
              end: text.length,
              kind: _kinds[mark.type]!,
              attr: mark.type == 'link' ? mark.attrs['href'] as String : null,
              isAutoLink: mark.type == 'link' ? false : null,
            ),
          );
        }
        continue;
      }
      final isBreak = _semanticInlineBreak(c);
      if ((!isBreak &&
              (c.type != 'text' ||
                  c.text == null ||
                  c.text!.isEmpty ||
                  c.content.isNotEmpty)) ||
          !_validSemanticInlineMarks(c) ||
          c.marks.any(
            (m) =>
                !_kinds.containsKey(m.type) ||
                (m.type == 'link' &&
                    (!_validSemanticLinkAttrs(m.attrs) ||
                        m.attrs['href'] is! String ||
                        m.attrs['attachment'] == true ||
                        m.attrs['markup'] != null)),
          )) {
        return null;
      }
      final start = text.length;
      if (isBreak && c.attrs['soft'] == true) softBreaks.add(start);
      text.write(isBreak ? '\n' : c.text);
      for (final m in c.marks) {
        marks.add(
          MarkSpan(
            start: start,
            end: text.length,
            kind: _kinds[m.type]!,
            attr: m.type == 'link' ? m.attrs['href'] as String : null,
            isAutoLink: m.type == 'link' ? false : null,
          ),
        );
      }
    }
    return EditableTextContent(
      text: text.toString(),
      marks: marks,
      atoms: atoms,
      softBreaks: softBreaks,
    );
  }

  /// 已批准树与稳定块 id 一起成为下一次同步的不可变来源快照。
  SemanticEditorProjection synchronizeSnapshot(
    List<EditorBlock> current, {
    EditorStructureIntent? intent,
  }) {
    _validateTransients(this, current);
    final tree = intent == null
        ? synchronize(current)
        : _applyStructureIntent(this, current, intent);
    final projected = SemanticEditorProjection.project(tree);
    if (projected._blocks.length != current.length) {
      throw const SemanticEditorUnsupported('结构投影块数不一致');
    }
    final result = SemanticEditorProjection._(tree);
    result._transients.addAll(_transients);
    for (var i = 0; i < current.length; i++) {
      final generated = projected._blocks[i];
      final actual = current[i];
      if (generated is TextBlock && actual is TextBlock) {
        if (generated.content != actual.content ||
            generated.kind != actual.kind ||
            generated.depth != actual.depth ||
            (actual.isListItem && (generated.ordered != actual.ordered ||
                generated.listStart != actual.listStart ||
                generated.listLoose != actual.listLoose)) ||
            generated.headingLevel != actual.headingLevel ||
            generated.containers.length != actual.containers.length) {
          throw const SemanticEditorUnsupported('结构投影语义不一致');
        }
      } else if (generated is! IslandBlock || actual is! IslandBlock) {
        throw const SemanticEditorUnsupported('结构投影不透明边界不一致');
      }
      result._blocks.add(actual);
      final node = projected._sources[generated.id];
      if (node != null) {
        result._sources[actual.id] = node;
        result._paths[actual.id] = projected._paths[generated.id]!;
      }
    }
    return result;
  }

  SemanticNode synchronize(List<EditorBlock> current, {bool allowNewAtoms = false}) {
    if (current.length != _blocks.length ||
        !listEquals(
          current.map((b) => b.id).toList(),
          _blocks.map((b) => b.id).toList(),
        )) {
      return _synchronizeStructure(this, current);
    }
    final changes = <String, SemanticNode>{};
    for (var i = 0; i < current.length; i++) {
      final old = _blocks[i], next = current[i];
      final reorderedGrid = old is IslandBlock && next is IslandBlock &&
          old.node is ImageGridNode && next.node is ImageGridNode &&
          !identical(old.node, next.node);
      if (old == next && !reorderedGrid) continue;
      final node = _sources[old.id];
      if (old is IslandBlock && next is IslandBlock && node != null) {
        final media =
            _synchronizeMedia(node, old.node, next.node) ??
            _synchronizeSemanticBlock(node, old.node, next.node);
        if (media != null) {
          changes[_paths[old.id]!] = media;
          continue;
        }
      }
      if (old is! TextBlock || next is! TextBlock || node == null) {
        throw const SemanticEditorUnsupported('不透明节点或虚拟落点不能编辑');
      }
      if (old.copyWith(
                content: next.content,
                headingLevel: next.headingLevel,
              ) !=
              next ||
          (!old.isHeading && old.headingLevel != next.headingLevel)) {
        throw const SemanticEditorUnsupported('容器、列表、块类型结构变化尚不支持');
      }
      changes[_paths[old.id]!] = node.copy(
        attrs: old.headingLevel == next.headingLevel
            ? null
            : {...node.attrs, 'level': next.headingLevel},
        content: old.content == next.content
            ? null
            : _rewrite(node, old.content, next.content, allowNewAtoms: allowNewAtoms),
      );
    }
    SemanticNode visit(SemanticNode n, String path) {
      if (changes.containsKey(path)) return changes[path]!;
      final children = [
        for (var i = 0; i < n.content.length; i++)
          visit(n.content[i], '$path/$i'),
      ];
      return listEquals(children, n.content) ? n : n.copy(content: children);
    }

    return visit(source, '');
  }

  /// 单一连续替换的来源归属；无法唯一归属 attrs 的跨段替换必须拒绝。
  static List<SemanticNode> _rewrite(
    SemanticNode parent,
    EditableTextContent old,
    EditableTextContent next, {
    bool allowNewAtoms = false,
  }) {
    if (parent.content.any((n) => n.type == 'html_inline' || n.type == 'check')) {
      return _rewriteSemanticNested(parent, old, next, allowNewAtoms: allowNewAtoms);
    }
    if (next.softBreaks.any(
      (offset) =>
          offset < 0 || offset >= next.length || next.text[offset] != '\n',
    )) {
      throw const SemanticEditorUnsupported('软换行坐标与文本不一致');
    }
    // 文本变化时不能把相邻的 FFFC 当作同一个来源；优先匹配保留的实例。
    bool sameUnit(int a, int b) {
      if (old.text[a] != next.text[b]) return false;
      if (old.text == next.text || !old.atoms.containsKey(a)) return true;
      final atom = next.atoms[b];
      if (old.atoms.values.any((value) => identical(value, atom))) {
        return identical(old.atoms[a], atom);
      }
      return old.atoms[a] == atom;
    }

    var prefix = 0, suffix = 0;
    while (prefix < old.length &&
        prefix < next.length &&
        sameUnit(prefix, prefix)) {
      prefix++;
    }
    while (suffix < old.length - prefix &&
        suffix < next.length - prefix &&
        sameUnit(old.length - suffix - 1, next.length - suffix - 1)) {
      suffix++;
    }
    final origins = <SemanticNode>[];
    for (final n in parent.content) {
      origins.addAll(List.filled(_semanticInlineLength(n), n));
    }
    SemanticNode? insertedOrigin;
    final affected = origins
        .sublist(prefix, old.length - suffix)
        .where((n) => n.type == 'text' && _semanticInlineAtom(n) == null)
        .toList();
    if (affected.isNotEmpty) {
      insertedOrigin = affected.first;
      if (affected.any((n) => !mapEquals(n.attrs, insertedOrigin!.attrs))) {
        throw const SemanticEditorUnsupported('跨不同 text attrs 的替换归属不明确');
      }
    } else if (origins.isNotEmpty) {
      final nearby = origins[prefix == 0 ? 0 : prefix - 1];
      insertedOrigin =
          nearby.type == 'text' && _semanticInlineAtom(nearby) == null
          ? nearby
          : null;
    }
    final mapped = <SemanticNode?>[
      ...origins.take(prefix),
      ...List<SemanticNode?>.filled(
        next.length - prefix - suffix,
        insertedOrigin,
      ),
      ...origins.skip(old.length - suffix),
    ];
    if (allowNewAtoms) {
      for (final entry in next.atoms.entries) {
        if (mapped[entry.key] == null || _semanticInlineAtom(mapped[entry.key]!) == null) {
          mapped[entry.key] = _newSemanticAtom(entry.value);
        }
      }
    }
    _validateSemanticAtomEdit(old, next);
    final result = <SemanticNode>[];
    for (var i = 0; i < next.length; i++) {
      final atom = next.atoms[i];
      if (atom != null) {
        final origin = mapped[i];
        if (origin == null || _semanticInlineAtom(origin) == null) {
          throw const SemanticEditorUnsupported('新增或移动 atom 来源不明确');
        }
        if (old.text != next.text && _semanticInlineAtom(origin) != atom) {
          throw const SemanticEditorUnsupported('文本与 atom 同时变化的来源有歧义');
        }
      }
      final marks = <SemanticMark>[];
      for (final span in next.marks.where((m) => m.start <= i && i < m.end)) {
        final type = _kinds.entries
            .where((e) => e.value == span.kind)
            .firstOrNull
            ?.key;
        if (type == null) throw const SemanticEditorUnsupported('新增 mark 尚未适配');
        final candidates = parent.content
            .expand((n) => n.marks)
            .where(
              (m) =>
                  m.type == type &&
                  (type != 'link' || m.attrs['href'] == span.attr),
            )
            .toList();
        final originMark = mapped[i]?.marks
            .where((m) => m.type == type)
            .firstOrNull;
        final local = originMark == null
            ? null
            : type == 'link' && originMark.attrs['href'] != span.attr
            ? SemanticMark(type, {
                ...originMark.attrs,
                'href': span.attr,
                if (originMark.attrs['data-orig-href'] != null)
                  'data-orig-href': span.attr,
              })
            : originMark;
        if (local == null &&
            candidates.any(
              (m) => !sameSemanticMarks([m], [candidates.first]),
            )) {
          throw const SemanticEditorUnsupported('mark 未知属性来源有歧义');
        }
        marks.add(
          local ??
              candidates.firstOrNull ??
              SemanticMark(
                type,
                type == 'link' ? {'href': span.attr} : const {},
              ),
        );
      }
      marks.sort(
        (a, b) => _semanticMarkOrder
            .indexOf(a.type)
            .compareTo(_semanticMarkOrder.indexOf(b.type)),
      );
      if (atom != null) {
        final rewritten = _rewriteSemanticAtom(mapped[i]!, atom);
        if (atom is LinkRun && rewritten.type != 'hashtag') {
          marks.add(rewritten.marks.firstWhere((m) => m.type == 'link'));
        }
        // 原来源的 mark 顺序和未知属性完整保留；新格式才追加。
        final ordered = <SemanticMark>[
          for (final original in rewritten.marks)
            ...marks.where((m) => m.type == original.type),
          ...marks.where(
            (m) => !rewritten.marks.any((original) => original.type == m.type),
          ),
        ];
        final marked = sameSemanticMarks(rewritten.marks, ordered)
            ? rewritten
            : rewritten.copy(marks: ordered);
        if (_semanticInlineAtom(marked) == null) {
          throw const SemanticEditorUnsupported('atom 格式来源无法无损表达');
        }
        result.add(marked);
        continue;
      }
      final textOrigin = mapped[i];
      if (next.text[i] == '\n') {
        final origin = textOrigin != null && _semanticInlineBreak(textOrigin)
            ? textOrigin
            : null;
        final soft = next.softBreaks.contains(i);
        result.add(
          SemanticNode(
            'hard_break',
            attrs: {
              ...?origin?.attrs,
              if (origin == null || (origin.attrs['soft'] == true) != soft)
                'soft': soft,
            },
            marks: marks,
          ),
        );
        continue;
      }
      final attrs =
          textOrigin == null ||
              textOrigin.type != 'text' ||
              _semanticInlineAtom(textOrigin) != null
          ? const <String, dynamic>{}
          : textOrigin.attrs;
      if (result.isNotEmpty &&
          result.last.type == 'text' &&
          _semanticInlineAtom(result.last) == null &&
          mapEquals(result.last.attrs, attrs) &&
          sameSemanticMarks(result.last.marks, marks) &&
          i > 0 &&
          identical(mapped[i], mapped[i - 1])) {
        result[result.length - 1] = result.last.copy(
          text: '${result.last.text}${next.text[i]}',
        );
      } else {
        result.add(
          SemanticNode('text', text: next.text[i], attrs: attrs, marks: marks),
        );
      }
    }
    // 完全未改动的 inline 也尽量复用原对象，而非规范化原始分段。
    return [
      for (final node in result)
        parent.content
                .where(
                  (oldNode) =>
                      oldNode.type == node.type &&
                      listEquals(oldNode.content, node.content) &&
                      oldNode.text == node.text &&
                      mapEquals(oldNode.attrs, node.attrs) &&
                      sameSemanticMarks(oldNode.marks, node.marks),
                )
                .firstOrNull ??
            node,
    ];
  }
}

/// 在 EditorState 提交前计算树快照；失败不会进入正文和历史。
class _SemanticBinding
    implements
        EditorDocumentBinding,
        EditorDocumentHistoryBinding,
        EditorDocumentIntentBinding,
        EditorDocumentExportBinding {
  @override
  String exportDocument(Object state, {List<EditorBlock>? fragment}) =>
      _exportSemanticDocument(state as SemanticEditorProjection, fragment);

  @override
  String exportSelection(Object state, EditorSelection selection,
      {required List<EditorBlock> blocks}) {
    final snapshot = state as SemanticEditorProjection;
    return _exportSemanticSelection(snapshot, selection, liveBlocks: blocks);
  }

  @override
  EditorDocumentHistorySnapshot remapHistory(
    EditorDocumentHistorySnapshot snapshot,
    Object operation,
  ) => _remapTransientHistory(snapshot, operation);
  _SemanticBinding(this.projection);
  final SemanticEditorProjection projection;
  SemanticEditorProjection? trustedPlan;
  @override
  Object prepareWithIntent(
    Object? previousState,
    List<EditorBlock> blocks,
    EditorStructureIntent intent,
  ) {
    if (trustedPlan != null) return prepare(previousState, blocks);
    try {
      return (previousState as SemanticEditorProjection? ?? projection)
          .synchronizeSnapshot(blocks, intent: intent);
    } on SemanticEditorUnsupported catch (error) {
      throw EditorDocumentRejection(
        error.message,
        code: 'semantic_unsupported',
      );
    }
  }

  @override
  Object prepare(Object? previousState, List<EditorBlock> normalizedBlocks) {
    try {
      final plan = trustedPlan;
      if (plan != null) {
        // 提交前一次性消费，通知监听器不能复用此操作的授权。
        trustedPlan = null;
        if (!listEquals(plan.blocks, normalizedBlocks)) {
          throw const SemanticEditorUnsupported('显式片段计划与提交块不一致');
        }
        return plan;
      }
      final previous = previousState as SemanticEditorProjection?;
      return (previous ?? projection).synchronizeSnapshot(normalizedBlocks);
    } on SemanticEditorUnsupported catch (error) {
      throw EditorDocumentRejection(
        error.message,
        code: 'semantic_unsupported',
      );
    }
  }
}

/// 真实 EditorState 的语义绑定；IR 使用只读归一化块，不经过 Markdown。
/// undo/redo 与正文同时恢复已批准的树快照，不额外维护一套历史。
class SemanticEditorSession extends ChangeNotifier {
  SemanticEditorSession(SemanticNode source)
    : projection = SemanticEditorProjection.project(source) {
    _binding = _SemanticBinding(projection);
    editor = EditorState(blocks: projection.blocks, documentBinding: _binding);
    editor.addListener(notifyListeners);
  }
  final SemanticEditorProjection projection;
  late final EditorState editor;
  late final _SemanticBinding _binding;
  final Set<Object> _usedTransientTokens = {};
  SemanticNode get tree =>
      (editor.documentBindingState as SemanticEditorProjection).source;
  @override
  void dispose() {
    editor.removeListener(notifyListeners);
    editor.dispose();
    super.dispose();
  }
}
