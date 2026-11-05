import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart' show MediaType;

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

  Map<String, String> get _headers => {'Content-Type': 'application/json', if (token != null) 'Authorization': 'Bearer $token'};

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
    if (r.statusCode == 403) throw ApiException('forbidden');
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

  Future<Map<String, dynamic>> pair(String code, String appVersion) => _send(
    () => _client.post(Uri.parse('$baseUrl/api/v1/pair'), headers: _headers, body: jsonEncode({'code': code, 'app_version': appVersion})),
  );

  Future<Map<String, dynamic>> pull(int since) => _send(
    () => _client.get(Uri.parse('$baseUrl/api/v1/sync/pull?since=$since'), headers: _headers),
    timeout: const Duration(seconds: 60),
  );

  /// Photo of a supplier invoice for a voucher made on this device. Returns false while the server does not
  /// know the voucher yet (it was not uploaded yet); throws 'rejected:file' if the server refuses the file.
  Future<bool> uploadReceiptFile(String receiptClientId, String fileId, List<int> bytes, String contentType) =>
      _upload('receipt-file', {'receipt_client_id': receiptClientId, 'file_id': fileId}, fileId, bytes, contentType);

  /// Photo of the original ministry invoice, after its sale. false = the sale has not reached the server yet.
  Future<bool> uploadSaleFile(String saleId, String fileId, List<int> bytes, String contentType) =>
      _upload('sale-file', {'sale_id': saleId, 'file_id': fileId}, fileId, bytes, contentType);

  Future<bool> _upload(String path, Map<String, String> fields, String fileId, List<int> bytes, String contentType) async {
    final req = http.MultipartRequest('POST', Uri.parse('$baseUrl/api/v1/$path'))
      ..headers.addAll({if (token != null) 'Authorization': 'Bearer $token'})
      ..fields.addAll(fields)
      ..files.add(http.MultipartFile.fromBytes('file', bytes, filename: '$fileId.jpg', contentType: _mediaType(contentType)));
    http.Response r;
    try {
      r = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 60)));
    } on TimeoutException {
      throw ApiException('offline');
    } on SocketException {
      throw ApiException('offline');
    } on http.ClientException {
      throw ApiException('offline');
    }
    if (r.statusCode == 401) throw ApiException('unpaired');
    if (r.statusCode == 404) return false;
    if (r.statusCode == 422) throw ApiException('rejected:file');
    if (r.statusCode != 200) throw ApiException('server');
    return true;
  }

  static MediaType _mediaType(String ct) {
    final parts = ct.split('/');
    return MediaType(parts.first, parts.length > 1 ? parts[1] : 'octet-stream');
  }

  /// Barcodes screen (admin only): applied on the server at once. Returns {ok, msg | error, product}.
  Future<Map<String, dynamic>> barcodeAction(int productId, Map<String, Object?> body) =>
      _send(() => _client.post(Uri.parse('$baseUrl/api/v1/products/$productId/barcodes'), headers: _headers, body: jsonEncode(body)));

  Future<Map<String, dynamic>> push(Map<String, Object?> payload) => _send(
    () => _client.post(Uri.parse('$baseUrl/api/v1/sync/push'), headers: _headers, body: jsonEncode(payload)),
    timeout: const Duration(seconds: 60),
  );
}
