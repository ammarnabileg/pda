import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../util/pin_hash.dart';
import 'api.dart';
import 'db.dart';
import 'models.dart';

const appVersion = '1.0.0';

enum SyncStatus { idle, syncing, ok, offline, unpaired, error }

/// Holds pairing, the logged-in employee and the sync loop.
class AppState extends ChangeNotifier {
  final LocalDb db;
  AppState(this.db);

  String? serverUrl;
  String? token;
  String? deviceName;
  Employee? employee;

  SyncStatus status = SyncStatus.idle;
  DateTime? lastSync;
  int pending = 0;
  int rejected = 0;
  int productCount = 0;

  Timer? _timer;
  Future<String?>? _current;
  DateTime? _lastFull;

  bool get paired => serverUrl != null && token != null;
  Api get api => Api(serverUrl!, token: token);

  Future<void> load() async {
    serverUrl = await db.get('server_url');
    token = await db.get('token');
    deviceName = await db.get('device_name');
    final empId = int.tryParse(await db.get('employee_id') ?? '');
    if (empId != null) {
      final e = await db.employeeById(empId);
      employee = (e != null && e.active) ? e : null;
    }
    await _refreshCounts();
    if (paired) start();
  }

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => sync());
    sync(full: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  // ---------- pairing ----------

  /// Returns null on success or an Arabic error message.
  Future<String?> pair(String address, String code) async {
    final url = Api.normalize(address);
    final a = Api(url);
    try {
      await a.ping();
    } on ApiException catch (e) {
      return e.code == 'not_tamween'
          ? 'العنوان ده مش سيرفر تموين. راجع الرقم.'
          : 'مش قادر أوصل للسيرفر على $url\nتأكد إن الجهاز على نفس الواي فاي وإن السيرفر شغال.';
    }
    try {
      final r = await a.pair(code.trim(), appVersion);
      serverUrl = url;
      token = r['token'] as String;
      deviceName = r['device_name'] as String;
      await db.set('server_url', serverUrl);
      await db.set('token', token);
      await db.set('device_name', deviceName);
      await db.set('version', '0');
      notifyListeners();
      final err = await sync(full: true);
      if (err != null) return 'تم الربط، لكن تحميل البيانات فشل. هيحاول تاني لوحده.';
      start();
      return null;
    } on ApiException catch (e) {
      if (e.code == 'bad_code') return 'الكود غلط أو انتهت صلاحيته. اطلب كود جديد من لوحة التحكم.';
      return 'حصلت مشكلة في الاتصال. جرّب تاني.';
    }
  }

  // ---------- login ----------

  Future<bool> login(Employee e, String pin) async {
    final ok = await compute(verifyPinArgs, [pin, e.pinSalt, e.pinHash]);
    if (!ok) return false;
    employee = e;
    await db.set('employee_id', '${e.id}');
    notifyListeners();
    return true;
  }

  Future<void> logout() async {
    employee = null;
    await db.set('employee_id', null);
    notifyListeners();
  }

  // ---------- sync ----------

  Future<void> _refreshCounts() async {
    pending = await db.countOutbox('pending');
    rejected = await db.countOutbox('rejected');
    productCount = await db.productCount();
  }

  @visibleForTesting
  Future<void> recordSavedCountsOnly() => _refreshCounts();

  /// Called after the device saves a sale, count or receipt.
  Future<void> recordSaved() async {
    await _refreshCounts();
    notifyListeners();
    unawaited(sync());
  }

  /// Uploads waiting records, then downloads changes. Returns an error code or null.
  /// If a sync is already running, waits for it and then runs again, so callers
  /// always get a sync that started after their records were saved.
  Future<String?> sync({bool full = false}) async {
    while (_current != null) {
      await _current;
    }
    if (!paired) return null;
    final run = _sync(full);
    _current = run;
    try {
      return await run;
    } finally {
      _current = null;
    }
  }

  Future<String?> _sync(bool full) async {
    status = SyncStatus.syncing;
    notifyListeners();
    String? error;
    try {
      await _push();
      final hourly = _lastFull == null || DateTime.now().difference(_lastFull!) > const Duration(hours: 1);
      final since = (full || hourly) ? 0 : int.tryParse(await db.get('version') ?? '0') ?? 0;
      final data = await api.pull(since);
      await db.applyPull(data);
      if (since == 0) _lastFull = DateTime.now();
      lastSync = DateTime.now();
      status = SyncStatus.ok;
      await _checkEmployee();
    } on ApiException catch (e) {
      error = e.code;
      status = e.code == 'offline'
          ? SyncStatus.offline
          : e.code == 'unpaired'
              ? SyncStatus.unpaired
              : SyncStatus.error;
    } catch (e) {
      error = 'error';
      status = SyncStatus.error;
    } finally {
      await _refreshCounts();
      notifyListeners();
    }
    return error;
  }

  Future<void> _push() async {
    while (true) {
      final rows = await db.pendingOutbox(limit: 50);
      if (rows.isEmpty) return;
      final payload = <String, List<Object?>>{'sales': [], 'counts': [], 'receipts': []};
      final keyOf = <String, String>{};
      for (final r in rows) {
        final kind = r['kind'] as String;
        final body = jsonDecode(r['payload'] as String) as Map<String, dynamic>;
        payload[kind]!.add(body);
        keyOf['$kind:${kind == 'receipts' ? body['receipt_id'] : body['id']}'] = r['id'] as String;
      }
      final res = await api.push(payload);
      final accepted = res['accepted'] as Map<String, dynamic>;
      for (final kind in accepted.keys) {
        for (final id in accepted[kind] as List) {
          final key = keyOf['$kind:$id'];
          if (key != null) await db.removeOutbox(key);
          if (kind == 'receipts') await db.db.delete('receipts', where: 'id = ?', whereArgs: [id]);
        }
      }
      for (final r in res['rejected'] as List) {
        final key = keyOf['${r['type']}:${r['id']}'];
        if (key != null) await db.rejectOutbox(key, r['reason'].toString());
        if (r['type'] == 'receipts') await db.db.delete('receipts', where: 'id = ?', whereArgs: [r['id']]);
      }
      if (rows.length < 50) return;
    }
  }

  /// A stopped employee is logged out at the next sync.
  Future<void> _checkEmployee() async {
    if (employee == null) return;
    final e = await db.employeeById(employee!.id);
    if (e == null || !e.active) {
      await logout();
    } else {
      employee = e;
    }
  }

  /// Supervisor action: forget the server (records still waiting are kept).
  Future<void> unpair() async {
    _timer?.cancel();
    serverUrl = null;
    token = null;
    await db.set('server_url', null);
    await db.set('token', null);
    status = SyncStatus.idle;
    notifyListeners();
  }
}
