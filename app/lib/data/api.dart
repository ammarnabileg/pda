import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  final String code; // offline | unpaired | bad_code | server | not_tamween
  ApiException(this.code);
  @override
  String toString() => 'ApiException($code)';
}

class Api {
  final String baseUrl;
  final String? token;
  final http.Client _client;
  Api(this.baseUrl, {this.token, http.Client? client}) : _client = client ?? http.Client();

  /// Accepts "192.168.1.20", "192.168.1.20:9001" or a full URL.
  static String normalize(String input) {
    var s = input.trim().replaceAll(RegExp(r'/+$'), '');
    if (!s.startsWith('http://') && !s.startsWith('https://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) return s;
    return u.hasPort ? '${u.scheme}://${u.host}:${u.port}' : '${u.scheme}://${u.host}:9001';
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Future<Map<String, dynamic>> _send(Future<http.Response> Function() call, {Duration timeout = const Duration(seconds: 15)}) async {
    http.Response r;
    try {
      r = await call().timeout(timeout);
    } on TimeoutException {
      throw ApiException('offline');
    } on SocketException {
      throw ApiException('offline');
    } on http.ClientException {
      throw ApiException('offline');
    }
    if (r.statusCode == 401) throw ApiException('unpaired');
    if (r.statusCode == 400) {
      try {
        throw ApiException((jsonDecode(utf8.decode(r.bodyBytes))['detail'] ?? 'server').toString());
      } on FormatException {
        throw ApiException('server');
      }
    }
    if (r.statusCode != 200) throw ApiException('server');
    try {
      return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException('not_tamween');
    }
  }

  Future<void> ping() async {
    final r = await _send(() => _client.get(Uri.parse('$baseUrl/api/v1/ping')), timeout: const Duration(seconds: 6));
    if (r['app'] != 'tamween') throw ApiException('not_tamween');
  }

  Future<Map<String, dynamic>> pair(String code, String appVersion) => _send(() => _client.post(
      Uri.parse('$baseUrl/api/v1/pair'),
      headers: _headers,
      body: jsonEncode({'code': code, 'app_version': appVersion})));

  Future<Map<String, dynamic>> pull(int since) =>
      _send(() => _client.get(Uri.parse('$baseUrl/api/v1/sync/pull?since=$since'), headers: _headers),
          timeout: const Duration(seconds: 60));

  Future<Map<String, dynamic>> push(Map<String, Object?> payload) => _send(
      () => _client.post(Uri.parse('$baseUrl/api/v1/sync/push'), headers: _headers, body: jsonEncode(payload)),
      timeout: const Duration(seconds: 60));
}
