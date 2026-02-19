import 'dart:io' show Platform;

import 'package:flutter/services.dart';

/// 通过「用本应用打开」传入的 SGF 文件内容与文件名（Android / iOS 关联 .sgf 后由原生读取）。
class OpenedSgfResult {
  const OpenedSgfResult({required this.content, required this.fileName});

  final String content;
  final String fileName;
}

/// 获取启动时或「打开方式」传入的 SGF 内容；无则返回 null。
Future<OpenedSgfResult?> getInitialOpenedSgf() async {
  if (!Platform.isAndroid && !Platform.isIOS) {
    return null;
  }
  const MethodChannel channel = MethodChannel('mastergo/file_opener');
  try {
    final dynamic raw = await channel.invokeMethod<dynamic>('getInitialOpenedSgf');
    if (raw is! Map<Object?, Object?>) {
      return null;
    }
    final String? content = raw['content'] as String?;
    final String fileName = raw['fileName'] as String? ?? 'opened.sgf';
    if (content == null || content.isEmpty) {
      return null;
    }
    return OpenedSgfResult(content: content, fileName: fileName);
  } on PlatformException {
    return null;
  }
}
