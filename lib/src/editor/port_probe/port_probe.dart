/// 受限官方编辑语义移植验证入口，不导出到生产包入口。
library;

import 'model.dart';
import 'parser.dart';
import 'serializer.dart';
export 'model.dart';

class ProbeCodec {
  ProbeNode parseTokens(List<dynamic> tokens) =>
      ProbeTokenParser().parseTokens(tokens);
  String serialize(ProbeNode doc) {
    ProbeSchema().check(doc);
    return serializeProbe(doc);
  }

  ProbeNode applyEdit(ProbeNode doc, Map<String, dynamic> edit) =>
      applyProbeEdit(doc, edit);
}
