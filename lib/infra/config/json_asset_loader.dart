import 'dart:convert';

import 'package:flutter/services.dart';

class JsonAssetLoader {
  const JsonAssetLoader();

  Future<Map<String, dynamic>> loadMap(String path) async {
    final String content = await rootBundle.loadString(path);
    final Object decoded = jsonDecode(content);
    return decoded as Map<String, dynamic>;
  }
}
