import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mastergo/infra/sgf/sgf_url_fetcher.dart';

void main() {
  test('rejects non-https URLs', () async {
    final SgfUrlFetcher fetcher = SgfUrlFetcher(client: _unusedClient());
    expect(
      () => fetcher.fetch('http://example.com/a.sgf'),
      throwsA(
        isA<SgfUrlFetchException>().having(
          (SgfUrlFetchException e) => e.code,
          'code',
          'https_required',
        ),
      ),
    );
  });

  test('rejects oversized payloads', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response(utf8.decode(List<int>.filled(64, 65)), 200);
    });
    final SgfUrlFetcher fetcher = SgfUrlFetcher(client: client, maxBytes: 8);
    expect(
      () => fetcher.fetch('https://example.com/a.sgf'),
      throwsA(
        isA<SgfUrlFetchException>().having(
          (SgfUrlFetchException e) => e.code,
          'code',
          'too_large',
        ),
      ),
    );
  });

  test('rejects an https link that redirects to http', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response(
        '',
        302,
        headers: <String, String>{'location': 'http://example.com/a.sgf'},
      );
    });
    expect(
      () => SgfUrlFetcher(client: client).fetch('https://example.com/start.sgf'),
      throwsA(
        isA<SgfUrlFetchException>().having(
          (SgfUrlFetchException e) => e.code,
          'code',
          'https_required',
        ),
      ),
    );
  });

  test('returns body on success', () async {
    final MockClient client = MockClient((http.Request request) async {
      return http.Response('(;GM[1]SZ[19];B[dd])', 200);
    });
    final String body = await SgfUrlFetcher(client: client).fetch(
      'https://example.com/a.sgf',
    );
    expect(body, contains('SZ[19]'));
  });
}

http.Client _unusedClient() {
  return MockClient((http.Request request) async {
    fail('HTTP client should not be called');
  });
}
