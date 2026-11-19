/// flatten 产物全局 LRU 缓存(跨挂载复用 span/recognizers/projection)。
///
/// ## 为什么要全局
///
/// flatten 产物此前缓存在 InlineSpanText 的 State 里,sliver 回收(滚出
/// cacheExtent)即销毁,来回滚动反复重 flatten;正文布局缓存/idle 预热
/// 都需要一个"State 死了产物还在"的家 —— 与 RenderParseCache(解析层)
/// 同构,这里是 flatten 层。
///
/// ## key 设计(handler 不进 key)
///
/// key = (inlines 身份, baseStyle, theme 身份, totalImagesInPost,
/// flattener 身份)。**handlers 刻意不进 key**:
/// - inlines 实例来自解析产物(RenderParseCache 按内容签名缓存),
///   内容(含 linkCounts/mentionedUsers)一变 → 签名变 → 重解析 →
///   新 inlines 身份 → 本缓存 miss → 用新 handler 重 flatten;
/// - 内容不变时 handler 的语义输入(post.id/topicId/heroNamespace)
///   也不变,冻结旧闭包行为等价;
/// - 点击 context 经 [SpanMountContext] 挂载时现取,不受闭包创建时机影响。
///
/// theme 用身份比对(与 InlineSpanText 旧行为一致):flatten 同步读色
/// 共 3 处(link primary / inline-code onSurfaceVariant / mention primary),
/// 产物带色,主题切换必须 miss。
///
/// ## recognizer 生命周期(引用计数 + 死缓延迟释放)
///
/// recognizer 随缓存条目走,不再随 State 走:
/// - [acquire] refs+1,State dispose 时 [release] refs-1;
/// - LRU 逐出时:无人引用 → 立即 dispose recognizers;仍被挂载引用 →
///   标记 dead,最后一个 release 时 dispose(在屏 span 的点击不会打到
///   已 dispose 的 recognizer);
/// - [evictAll](hot reload / 主题级失效)同规则。
///
/// 编辑器路径(EditableParagraph)不走本缓存(内容逐击键变化,缓存无意义),
/// 仍直接 flatten 并自持 recognizers —— [release] 对非缓存产物安全 no-op。
library;

import 'dart:collection';

import 'package:material_ui/material_ui.dart';

import '../node/inline_node.dart';
import 'inline_flattener.dart';

class FlattenCache {
  FlattenCache._();

  /// 条目上限。单条 ≈ 一个段落的 span 树 + projection(数 KB 级),
  /// 1024 条覆盖若干长帖的全部段落,量级几 MB。
  static const int _cap = 1024;

  static final LinkedHashMap<_FlattenKey, _FlattenEntry> _entries =
      LinkedHashMap();

  /// result → entry 反查(release 用)。dead 且未释放完的条目也在,
  /// 随最后一次 release 移除,有界于活跃挂载数。
  static final Map<FlattenResult, _FlattenEntry> _byResult = {};

  /// 命中统计(诊断用)。
  static int hits = 0;
  static int misses = 0;
  static int get length => _entries.length;

  /// miss 时的 flatten 计时上报钩子(主项目接 FrameJankMonitor.noteSpan;
  /// 不设则零成本)。
  static void Function(int micros)? profileHook;

  /// 取(或建)flatten 产物,refs+1。调用方(挂载 State)必须在 dispose
  /// 时 [release] 同一个 result。
  static FlattenResult acquire({
    required List<InlineNode> inlines,
    required TextStyle baseStyle,
    required ThemeData theme,
    required int totalImagesInPost,
    required InlineFlattener flattener,
    required FlattenResult Function() create,
  }) {
    final key = _FlattenKey(
      inlines,
      baseStyle,
      theme,
      totalImagesInPost,
      flattener,
    );
    final existing = _entries.remove(key);
    if (existing != null) {
      _entries[key] = existing; // LRU touch:重插到尾部
      existing.refs++;
      hits++;
      return existing.result;
    }
    misses++;
    final hook = profileHook;
    final sw = hook == null ? null : (Stopwatch()..start());
    final result = create();
    if (sw != null && hook != null) {
      sw.stop();
      hook(sw.elapsedMicroseconds);
    }
    final entry = _FlattenEntry(result)..refs = 1;
    _entries[key] = entry;
    _byResult[result] = entry;
    _evictOverflow();
    return result;
  }

  /// 归还引用。非本缓存的产物(编辑器直接 flatten 的)安全 no-op。
  static void release(FlattenResult result) {
    final entry = _byResult[result];
    if (entry == null) return;
    entry.refs--;
    if (entry.refs <= 0 && entry.dead) {
      _disposeEntry(entry);
    }
  }

  /// 全清(hot reload / 环境级失效):空闲条目立即释放,在用条目标记
  /// dead 待最后一次 release 释放。
  static void evictAll() {
    for (final entry in _entries.values) {
      if (entry.refs <= 0) {
        _disposeEntry(entry);
      } else {
        entry.dead = true;
      }
    }
    _entries.clear();
  }

  static void _evictOverflow() {
    while (_entries.length > _cap) {
      final oldestKey = _entries.keys.first;
      final entry = _entries.remove(oldestKey)!;
      if (entry.refs <= 0) {
        _disposeEntry(entry);
      } else {
        // 仍被挂载引用:延迟到最后一个 release 再 dispose,
        // 保证在屏 span 的 recognizer 始终可用。
        entry.dead = true;
      }
    }
  }

  static void _disposeEntry(_FlattenEntry entry) {
    for (final rec in entry.result.recognizers) {
      rec.dispose();
    }
    _byResult.remove(entry.result);
  }
}

class _FlattenEntry {
  _FlattenEntry(this.result);
  final FlattenResult result;
  int refs = 0;

  /// 已被逐出但仍有引用:最后一个 release 负责 dispose。
  bool dead = false;
}

class _FlattenKey {
  _FlattenKey(
    this.inlines,
    this.baseStyle,
    this.theme,
    this.totalImagesInPost,
    this.flattener,
  );

  final List<InlineNode> inlines;
  final TextStyle baseStyle;
  final ThemeData theme;
  final int totalImagesInPost;
  final InlineFlattener flattener;

  @override
  bool operator ==(Object other) =>
      other is _FlattenKey &&
      identical(other.inlines, inlines) &&
      other.baseStyle == baseStyle &&
      identical(other.theme, theme) &&
      other.totalImagesInPost == totalImagesInPost &&
      identical(other.flattener, flattener);

  @override
  int get hashCode => Object.hash(
        identityHashCode(inlines),
        baseStyle,
        identityHashCode(theme),
        totalImagesInPost,
        identityHashCode(flattener),
      );
}
