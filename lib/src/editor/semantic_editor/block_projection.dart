part of 'semantic_editor.dart';

/// 块模型只是局部视图；回写始终更新原节点，保留未编辑属性。
BlockNode? _projectSemanticBlock(SemanticNode n, String id) {
  switch (n.type) {
    case 'code_block':
    case 'html_block':
      return CodeBlockNode(
        id: id,
        code: n.textContent,
        language: n.attrs['params'] as String? ?? '',
        rawHtml: n.type == 'html_block',
      );
    case 'math_block':
      return MathBlockNode(id: id, latex: n.textContent);
    case 'horizontal_rule':
      return HorizontalRuleNode(id: id);
    case 'footnote_block':
      return FootnotesSectionNode(
        id: id,
        entries: [
          for (final entry in n.content)
            FootnoteEntry(
              id: 'fn:${(entry.attrs['id'] as int) + 1}',
              number: '${(entry.attrs['id'] as int) + 1}',
              markdownLabel: entry.attrs['label'] as String?,
              inlines:
                  entry.content.length == 1 &&
                      entry.content.single.type == 'paragraph'
                  ? (SemanticEditorProjection._inline(entry.content.single) ??
                            (throw const SemanticEditorUnsupported('脚注内容无法投影')))
                        .toInlines()
                  : throw const SemanticEditorUnsupported('脚注多块编辑需要结构适配'),
            ),
        ],
      );
    case 'poll':
      return PollNode(
        id: id,
        pollName: n.attrs['pollName'] as String? ?? 'poll',
        title: n.attrs['title'] as String?,
        rawHtml: n.attrs['rawHtml'] as String,
      );
    case 'table':
      final rows = _semanticRows(n);
      return TableNode(
        id: id,
        columnCount: rows.fold<int>(
          0,
          (v, r) => r.content.length > v ? r.content.length : v,
        ),
        hasHeader:
            rows.isNotEmpty &&
            rows.first.content.every((c) => c.attrs['header'] == true),
        rowSourceIds: [for (var r = 0; r < rows.length; r++) "$id-row-$r"],
        rows: [
          for (final (r, row) in rows.indexed)
            [
              for (final (c, cell) in row.content.indexed)
                TableCellData(
                  sourceId: "$id-row-$r-cell-$c",
                  isHeader: cell.attrs['header'] == true,
                  alignment: _cellAlignment(cell),
                  children: [
                    ParagraphNode(
                      id: '$id-cell',
                      inlines:
                          (SemanticEditorProjection._inline(cell) ??
                                  (throw const SemanticEditorUnsupported(
                                    '表格行内无法投影',
                                  )))
                              .toInlines(),
                    ),
                  ],
                ),
            ],
        ],
      );
    case 'image_grid':
      final images = <ImageRun>[];
      for (final paragraph in n.content) {
        final inline = SemanticEditorProjection._inline(paragraph);
        if (inline == null) throw const SemanticEditorUnsupported('网格行内无法投影');
        for (final run in inline.toInlines()) {
          if (run is ImageRun) {
            images.add(run);
          } else if (run is! LineBreakRun &&
              !(run is TextRun && run.text.trim().isEmpty)) {
            throw const SemanticEditorUnsupported('网格包含非图片');
          }
        }
      }
      return ImageGridNode(
        id: id,
        images: images,
        mode: n.attrs['data-mode'] == 'carousel'
            ? ImageGridMode.carousel
            : ImageGridMode.grid,
      );
  }
  return null;
}

List<SemanticNode> _semanticRows(SemanticNode n) => [
  for (final child in n.content)
    if (child.type == 'table_row') child else ...child.content,
];
TextAlign? _cellAlignment(SemanticNode cell) => switch (cell.attrs['style']) {
  'text-align:left' || 'text-align:left;' => TextAlign.left,
  'text-align:right' || 'text-align:right;' => TextAlign.right,
  'text-align:center' || 'text-align:center;' => TextAlign.center,
  _ => null,
};
SemanticNode _replaceBlockText(SemanticNode source, String text) => source.copy(
  content: text.isEmpty
      ? []
      : [
          source.content.isNotEmpty
              ? source.content.first.copy(text: text)
              : SemanticNode('text', text: text),
        ],
);

SemanticNode? _synchronizeSemanticBlock(
  SemanticNode source,
  BlockNode old,
  BlockNode next,
) {
  if (old.runtimeType != next.runtimeType) return null;
  if (old is CodeBlockNode && next is CodeBlockNode) {
    if (old.rawHtml != next.rawHtml) {
      throw const SemanticEditorUnsupported('不能隐式切换 HTML 代码类型');
    }
    return _replaceBlockText(source, next.code).copy(
      attrs: {
        ...source.attrs,
        if (old.language != next.language) 'params': next.language,
      },
    );
  }
  if (next is MathBlockNode) return _replaceBlockText(source, next.latex);
  if (next is PollNode) {
    return source.copy(
      attrs: {
        ...source.attrs,
        'pollName': next.pollName,
        'title': next.title,
        'rawHtml': next.rawHtml,
      },
    );
  }
  if (old is FootnotesSectionNode && next is FootnotesSectionNode) {
    if (old.entries.length != next.entries.length) {
      throw const SemanticEditorUnsupported('脚注增删需要同步引用');
    }
    return source.copy(
      content: [
        for (var i = 0; i < next.entries.length; i++)
          source.content[i].copy(
            attrs: {
              ...source.content[i].attrs,
              if (old.entries[i].markdownLabel != next.entries[i].markdownLabel)
                'label': next.entries[i].markdownLabel,
            },
            content: [
              source.content[i].content.single.copy(
                content: SemanticEditorProjection._rewrite(
                  source.content[i].content.single,
                  EditableTextContent.fromInlines(old.entries[i].inlines),
                  EditableTextContent.fromInlines(next.entries[i].inlines),
                ),
              ),
            ],
          ),
      ],
    );
  }
  if (old is ImageGridNode && next is ImageGridNode) {
    final origins = <SemanticNode>[];
    void collect(SemanticNode n) {
      if (n.type == 'image') origins.add(n);
      for (final child in n.content) {
        collect(child);
      }
    }

    collect(source);
    final used = <int>{};
    final images = <SemanticNode>[];
    for (var i = 0; i < next.images.length; i++) {
      final image = next.images[i];
      var origin = old.images.indexWhere(
        (oldImage) => identical(oldImage, image),
      );
      if (origin < 0 || used.contains(origin)) {
        origin = -1;
        for (var j = 0; j < old.images.length; j++) {
          if (!used.contains(j) && old.images[j] == image) {
            origin = j;
            break;
          }
        }
      }
      if (origin < 0 &&
          old.images.length == next.images.length &&
          !used.contains(i)) {
        origin = i;
      }
      if (origin >= 0) {
        used.add(origin);
        images.add(_rewriteSemanticAtom(origins[origin], image));
      } else {
        images.add(_newSemanticAtom(image));
      }
    }
    // 重排、增删跟随图片来源，保留每张图片及段落的未知属性和空白。
    var cursor = 0;
    List<SemanticNode> rewriteChildren(List<SemanticNode> children) => [
      for (final child in children)
        if (child.type == 'image') ...[
          if (cursor < images.length) images[cursor++],
        ] else
          child.copy(content: rewriteChildren(child.content)),
    ];
    final paragraphs = rewriteChildren(source.content);
    if (cursor < images.length) {
      if (paragraphs.isEmpty) paragraphs.add(SemanticNode('paragraph'));
      paragraphs[paragraphs.length - 1] = paragraphs.last.copy(
        content: [...paragraphs.last.content, ...images.skip(cursor)],
      );
    }
    return source
        .copy(content: paragraphs)
        .copy(
          attrs: {
            ...source.attrs,
            if (old.mode != next.mode)
              'data-mode': next.mode == ImageGridMode.carousel
                  ? 'carousel'
                  : 'grid',
          },
        );
  }
  if (old is TableNode && next is TableNode) {
    final rows = _semanticRows(source);
    if (next.rowSourceIds.isEmpty &&
        (old.rows.length != next.rows.length ||
            old.rows.indexed.any(
              (r) => r.$2.length != next.rows[r.$1].length,
            ))) {
      throw const SemanticEditorUnsupported('表格结构操作缺少行和单元格来源');
    }
    final usedRows = <int>{};
    final result = <SemanticNode>[];
    final parents = <SemanticNode?>[
      for (final child in source.content)
        if (child.type == 'table_row')
          null
        else
          for (final _ in child.content) child,
    ];
    SemanticNode? activeParent;
    final groupRows = <SemanticNode>[];
    void flush() {
      if (groupRows.isEmpty) return;
      if (activeParent == null) {
        result.addAll(groupRows);
      } else {
        result.add(activeParent.copy(content: List.of(groupRows)));
      }
      groupRows.clear();
    }

    for (var r = 0; r < next.rows.length; r++) {
      final cells = next.rows[r];
      final id = r < next.rowSourceIds.length ? next.rowSourceIds[r] : null;
      var origin = id == null ? -1 : old.rowSourceIds.indexOf(id);
      if (id != null && origin < 0) {
        throw const SemanticEditorUnsupported('表格行来源已失效');
      }
      if (origin < 0) {
        origin = old.rows.indexWhere((row) => identical(row, cells));
      }
      // 文本 codec 回写不携带行 ID，但后续网格结构操作会保留原
      // 单元格对象。仅用对象身份找回唯一来源行，不按内容猜测归属。
      if (origin < 0 && id == null && old.rowSourceIds.isEmpty) {
        final matches = [
          for (var i = 0; i < old.rows.length; i++)
            if (cells.any((cell) =>
                old.rows[i].any((previous) => identical(previous, cell))))
              i,
        ];
        if (matches.length == 1) origin = matches.single;
      }
      // 无来源的旧文本回调仅允许同尺寸原位编辑；结构操作必须携带来源。
      if (origin < 0 &&
          next.rowSourceIds.isEmpty &&
          old.rows.length == next.rows.length &&
          old.rows[r].length == cells.length) {
        origin = r;
      }
      if (origin >= 0 && !usedRows.add(origin)) {
        throw const SemanticEditorUnsupported('表格行来源重复');
      }
      final parent = origin < 0 ? activeParent : parents[origin];
      if (!identical(parent, activeParent)) {
        flush();
        activeParent = parent;
      }
      final usedCells = <int>{};
      final content = <SemanticNode>[];
      for (var c = 0; c < cells.length; c++) {
        final cell = cells[c];
        var oc = origin < 0
            ? -1
            : old.rows[origin].indexWhere(
                (v) => cell.sourceId != null
                    ? v.sourceId == cell.sourceId
                    : identical(v, cell),
              );
        if (oc < 0 && cell.sourceId != null) {
          throw const SemanticEditorUnsupported('表格单元格来源已失效');
        }
        if (oc < 0 &&
            origin >= 0 &&
            next.rowSourceIds.isEmpty &&
            old.rows[origin].length == cells.length) {
          oc = c;
        }
        if (oc >= 0) {
          if (!usedCells.add(oc)) {
            throw const SemanticEditorUnsupported('表格单元格来源重复');
          }
          content.add(
            _syncCell(rows[origin].content[oc], old.rows[origin][oc], cell),
          );
        } else {
          content.add(
            _semanticNodeFromBlock(
              TableNode(
                id: next.id,
                rows: [
                  [cell],
                ],
                columnCount: 1,
              ),
            ).content.single.content.single,
          );
        }
      }
      groupRows.add(
        origin < 0
            ? SemanticNode('table_row', content: content)
            : rows[origin].copy(content: content),
      );
    }
    flush();
    return source.copy(content: result);
  }
  return null;
}

SemanticNode _syncCell(
  SemanticNode source,
  TableCellData old,
  TableCellData next,
) {
  if (next.children.length != 1 || next.children.single is! ParagraphNode) {
    throw const SemanticEditorUnsupported('表格单元格块结构不支持');
  }
  final before = SemanticEditorProjection._inline(source)!;
  final after = EditableTextContent.fromInlines(
    (next.children.single as ParagraphNode).inlines,
  );
  return source.copy(
    attrs: {
      ...source.attrs,
      if (old.isHeader != next.isHeader) 'header': next.isHeader,
      if (old.alignment != next.alignment)
        'style': next.alignment == null
            ? null
            : 'text-align:${next.alignment!.name}',
    },
    content: before == after
        ? source.content
        : SemanticEditorProjection._rewrite(source, before, after),
  );
}

/// 可信 UI 新建块的直接转换；不经过 Markdown 或 token 重解析。
SemanticNode _semanticNodeFromBlock(BlockNode block) {
  List<SemanticNode> inline(List<InlineNode> runs) =>
      SemanticEditorProjection._rewrite(
        SemanticNode('paragraph'),
        EditableTextContent.empty,
        EditableTextContent.fromInlines(runs),
        allowNewAtoms: true,
      );
  List<SemanticNode> text(String value) =>
      value.isEmpty ? [] : [SemanticNode('text', text: value)];
  if (block is CodeBlockNode) {
    return SemanticNode(
      block.rawHtml ? 'html_block' : 'code_block',
      attrs: {'params': block.language},
      content: text(block.code),
    );
  }
  if (block is MathBlockNode) {
    return SemanticNode('math_block', content: text(block.latex));
  }
  if (block is HorizontalRuleNode) return SemanticNode('horizontal_rule');
  if (block is ParagraphNode) {
    return SemanticNode('paragraph', content: inline(block.inlines));
  }
  if (block is PollNode) {
    return SemanticNode(
      'poll',
      attrs: {
        'pollName': block.pollName,
        'title': block.title,
        'rawHtml': block.rawHtml,
      },
    );
  }
  if (block is ImageGridNode) {
    return SemanticNode(
      'image_grid',
      attrs: {
        'data-mode': block.mode == ImageGridMode.carousel ? 'carousel' : 'grid',
      },
      content: [SemanticNode('paragraph', content: inline(block.images))],
    );
  }
  if (block is TableNode) {
    return SemanticNode(
      'table',
      content: [
        for (final row in block.rows)
          SemanticNode(
            'table_row',
            content: [
              for (final cell in row)
                SemanticNode(
                  'table_cell',
                  attrs: {
                    'header': cell.isHeader,
                    if (cell.alignment != null)
                      'style': 'text-align:${cell.alignment!.name}',
                  },
                  content: inline([
                    for (final child in cell.children)
                      if (child is ParagraphNode)
                        ...child.inlines
                      else
                        throw const SemanticEditorUnsupported('新表格单元格只支持段落'),
                  ]),
                ),
            ],
          ),
      ],
    );
  }
  if (block is VideoNode || block is AudioNode) {
    final raw = serializeRawMediaHtml(block);
    if (raw != null) return SemanticNode('html_block', content: text(raw));
  }
  throw SemanticEditorUnsupported('新增块尚无直接适配：${block.runtimeType}');
}
