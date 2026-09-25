import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class SgfUrlFetchException implements Exception {
  const SgfUrlFetchException(this.code, [this.details]);

  /// Machine-readable reason: `invalid_url`, `https_required`, `http_status`,
  /// `too_large`, `timeout`, `empty`.
  final String code;
  final String? details;

  @override
  String toString() {
    if (details == null || details!.isEmpty) {
      return code;
    }
    return '$code: $details';
  }
}

/// HTTPS-only SGF download with timeout and size cap.
class SgfUrlFetcher {
  SgfUrlFetcher({
    http.Client? client,
    this.maxBytes = defaultMaxBytes,
    this.timeout = defaultTimeout,
  }) : _client = client;

  static const int defaultMaxBytes = 2 * 1024 * 1024;
  static const Duration defaultTimeout = Duration(seconds: 20);

  final http.Client? _client;
  final int maxBytes;
  final Duration timeout;

  Future<String> fetch(String url) async {
    final Uri? uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty || !uri.hasScheme) {
      throw const SgfUrlFetchException('invalid_url');
    }
    if (uri.scheme.toLowerCase() != 'https') {
      throw const SgfUrlFetchException('https_required');
    }

    final http.Client client = _client ?? http.Client();
    final bool owned = _client == null;
    try {
      Uri current = uri;
      for (int hop = 0; hop < 5; hop++) {
        _requireHttps(current);
        final http.Request request = http.Request('GET', current)
          ..followRedirects = false;
        final http.StreamedResponse response = await client
            .send(request)
            .timeout(timeout);
        if (_isRedirect(response.statusCode)) {
          final String? location = response.headers['location'];
          await response.stream.drain<void>();
          if (location == null || location.isEmpty) {
            throw const SgfUrlFetchException('invalid_url');
          }
          current = current.resolve(location);
          continue;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          await response.stream.drain<void>();
          throw SgfUrlFetchException('http_status', '${response.statusCode}');
        }
        final String body = await _readCapped(response);
        if (body.trim().isEmpty) {
          throw const SgfUrlFetchException('empty');
        }
        return body;
      }
      throw const SgfUrlFetchException('invalid_url');
    } on SgfUrlFetchException {
      rethrow;
    } on TimeoutException {
      throw const SgfUrlFetchException('timeout');
    } on Exception {
      throw const SgfUrlFetchException('invalid_url');
    } finally {
      if (owned) {
        client.close();
      }
    }
  }

  void _requireHttps(Uri uri) {
    if (uri.scheme.toLowerCase() != 'https') {
      throw const SgfUrlFetchException('https_required');
    }
  }

  bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  Future<String> _readCapped(http.StreamedResponse response) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in response.stream.timeout(timeout)) {
      if (bytes.length + chunk.length > maxBytes) {
        throw SgfUrlFetchException('too_large', '${bytes.length + chunk.length}');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
