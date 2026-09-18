/// 自研选区对外暴露的类型与回调。
///
/// 子包只产出 plainText + 选区矩形 + 可选代码块语言,**不依赖主项目的
/// HtmlTextMapper / 引用 UI**。复制/引用的接线:
/// - 复制:子包自带 toolbar 内部用 `Clipboard.setData`,选区覆盖完整代码块时带 ```lang 包裹。
/// - 引用:子包 toolbar 调 [QuoteRequestCallback] 把 plainText 交回主项目,
///   主项目用现有 QuoteSelectionHelper → HtmlTextMapper → QuoteBuilder 转引用。
library;

import 'package:flutter/widgets.dart';

/// 选区恰好覆盖单个代码块**全部内容**时携带的上下文(复制时包 ```lang);
/// 只选中块内部分文本时为 null。
@immutable
class CodeSelectionInfo {
  const CodeSelectionInfo({this.language});

  /// 代码块语言(CodeBlockNode.language),null = 无语言标注。
  final String? language;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CodeSelectionInfo &&
          runtimeType == other.runtimeType &&
          language == other.language;

  @override
  int get hashCode => language.hashCode;

  @override
  String toString() => 'CodeSelectionInfo(language: $language)';
}

/// 一次选区的完整快照,交给主项目 / toolbar。
@immutable
class SelectionData {
  const SelectionData({
    required this.plainText,
    required this.globalBounds,
    required this.globalRects,
    this.code,
    this.copyText,
  });

  /// 已按投影规则拼好的纯文本(emoji→`:name:`、块间 `\n`、clickCount 排除)。
  /// 直接喂主项目 HtmlTextMapper.extractHtml(post.cooked, plainText)。
  final String plainText;

  final String? copyText;
  String get clipboardText => copyText ?? plainText;

  /// 选区所有高亮矩形的外接框(全局坐标),给 toolbar 定位。
  final Rect globalBounds;

  /// 各高亮矩形(全局坐标),可用于精细定位或调试。
  final List<Rect> globalRects;

  /// 选区恰好覆盖单个代码块全部内容时非 null(部分选中为 null)。
  final CodeSelectionInfo? code;

  @override
  String toString() =>
      'SelectionData("${plainText.length} chars", bounds=$globalBounds'
      '${code == null ? "" : ", $code"})';
}

/// 选区变化回调(选区稳定/清除时触发,null = 清除)。
/// [fromTouch] = 本次选区是否由触摸产生(决定是否显示移动端拖拽手柄)。
typedef SelectionResultCallback =
    void Function(SelectionData? data, {bool fromTouch});

/// 引用请求回调 —— toolbar 点「引用」时调,把选区 plainText 交回主项目。
typedef QuoteRequestCallback = void Function(String plainText);

/// 复制完成回调 —— 子包复制到剪贴板后通知主项目弹 toast(可选)。
typedef CopyToastCallback = void Function();

/// 解密请求回调 —— toolbar 点「解密」时调,把选区 plainText 交回主项目。
typedef DecryptRequestCallback = void Function(String plainText);

/// 密文特征判定 —— 由主项目注入(与主项目 crypto 引擎同源的嗅探逻辑),
/// 决定「解密」按钮是否对当前选区显示。
/// [codeLanguage] 为选区所在代码块的 fence 语言标记(如 ```enc),
/// 主项目可据此把整块标记内容视为可解密(哪怕只选中了片段)。
typedef DecryptTextDetector =
    bool Function(String plainText, {String? codeLanguage});
