import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../util/format.dart';
import 'models.dart';

/// The device's own database. Everything the screens need is here, so the app
/// keeps working when the server or the network is down.
class LocalDb {
  final Database db;
  LocalDb(this.db);

  static Future<LocalDb> open({String? path, DatabaseFactory? factory}) async {
    final f = factory ?? databaseFactory;
    final file = path ?? p.join(await f.getDatabasesPath(), 'tamween.db');
    final db = await f.openDatabase(file, options: OpenDatabaseOptions(version: 1, onCreate: _create));
    return LocalDb(db);
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute('''CREATE TABLE products(id INTEGER PRIMARY KEY, barcode TEXT NOT NULL, name TEXT NOT NULL,
      unit TEXT NOT NULL, price INTEGER NOT NULL, carton INTEGER NOT NULL, stock INTEGER NOT NULL, active INTEGER NOT NULL)''');
    await db.execute('CREATE INDEX products_barcode ON products(barcode)');
    await db.execute('''CREATE TABLE employees(id INTEGER PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
      pin_salt TEXT NOT NULL, pin_hash TEXT NOT NULL, active INTEGER NOT NULL)''');
    await db.execute('''CREATE TABLE receipts(id INTEGER PRIMARY KEY, supplier TEXT NOT NULL, status TEXT NOT NULL,
      note TEXT NOT NULL, created_at TEXT NOT NULL, lines TEXT NOT NULL)''');
    // Records waiting to be uploaded. state: pending | rejected
    await db.execute('''CREATE TABLE outbox(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL,
      created_at TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', error TEXT)''');
    await db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
  }

  // ---------- settings / drafts ----------

  Future<String?> get(String key) async {
    final r = await db.query('kv', where: 'key = ?', whereArgs: [key]);
    return r.isEmpty ? null : r.first['value'] as String;
  }

  Future<void> set(String key, String? value) async {
    if (value == null) {
      await db.delete('kv', where: 'key = ?', whereArgs: [key]);
    } else {
      await db.insert('kv', {'key': key, 'value': value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<dynamic> getJson(String key) async {
    final v = await get(key);
    return v == null ? null : jsonDecode(v);
  }

  Future<void> setJson(String key, Object? value) => set(key, value == null ? null : jsonEncode(value));

  // ---------- products ----------

  Future<Product?> productById(int id) async {
    final r = await db.query('products', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Product.fromRow(r.first);
  }

  /// Scanners sometimes add or drop a leading zero (UPC-A vs EAN-13); try both.
  Future<Product?> productByBarcode(String code) async {
    code = code.trim();
    if (code.isEmpty) return null;
    final variants = {code, '0$code', if (code.startsWith('0')) code.substring(1)}.toList();
    final r = await db.query('products',
        where: 'active = 1 AND barcode IN (${List.filled(variants.length, '?').join(',')})', whereArgs: variants);
    if (r.isEmpty) return null;
    final exact = r.where((x) => x['barcode'] == code);
    return Product.fromRow(exact.isNotEmpty ? exact.first : r.first);
  }

  Future<List<Product>> searchProducts(String q, {int limit = 40}) async {
    q = q.trim();
    final r = await db.query('products',
        where: q.isEmpty ? 'active = 1' : 'active = 1 AND (name LIKE ? OR barcode LIKE ?)',
        whereArgs: q.isEmpty ? null : ['%$q%', '%$q%'],
        orderBy: 'name',
        limit: limit);
    return r.map(Product.fromRow).toList();
  }

  Future<Map<int, Product>> productsByIds(Iterable<int> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return {};
    final r = await db.query('products', where: 'id IN (${List.filled(list.length, '?').join(',')})', whereArgs: list);
    return {for (final row in r) row['id'] as int: Product.fromRow(row)};
  }

  Future<int> productCount() async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM products WHERE active = 1')) ?? 0;

  /// Local stock estimate until the next sync brings the server's number.
  Future<void> adjustStock(int productId, int deltaMilli) =>
      db.rawUpdate('UPDATE products SET stock = stock + ? WHERE id = ?', [deltaMilli, productId]);

  // ---------- employees ----------

  Future<List<Employee>> activeEmployees() async {
    final r = await db.query('employees', where: 'active = 1', orderBy: 'name');
    return r.map(Employee.fromRow).toList();
  }

  Future<Employee?> employeeById(int id) async {
    final r = await db.query('employees', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Employee.fromRow(r.first);
  }

  // ---------- receipts ----------

  Future<List<ReceiptDoc>> openReceipts() async {
    final r = await db.query('receipts', where: "status = 'open'", orderBy: 'created_at');
    return r.map(_receipt).toList();
  }

  Future<ReceiptDoc?> receiptById(int id) async {
    final r = await db.query('receipts', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : _receipt(r.first);
  }

  ReceiptDoc _receipt(Map<String, Object?> r) {
    final lines = (jsonDecode(r['lines'] as String) as List)
        .map((l) => ReceiptLine(l['product_id'] as int, l['mode'] as String, parseMilli(l['ordered'].toString()) ?? 0))
        .toList();
    return ReceiptDoc(
        id: r['id'] as int,
        supplier: r['supplier'] as String,
        status: r['status'] as String,
        note: r['note'] as String,
        createdAt: r['created_at'] as String,
        lines: lines);
  }

  Future<void> markReceiptSent(int id) =>
      db.update('receipts', {'status': 'sent'}, where: 'id = ?', whereArgs: [id]);

  // ---------- server pull ----------

  Future<void> applyPull(Map<String, dynamic> data) async {
    await db.transaction((txn) async {
      final batch = txn.batch();
      if (data['full'] == true) {
        // A full pull is the server's complete picture: drop what it no longer has.
        batch.delete('products');
        batch.delete('employees');
        batch.delete('receipts', where: "status != 'sent'");
      }
      for (final j in (data['products'] as List)) {
        batch.insert('products', Product.fromApi(j).toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final j in (data['employees'] as List)) {
        batch.insert('employees', Employee.fromApi(j).toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
      for (final j in (data['receipts'] as List)) {
        final existing = await txn.query('receipts', columns: ['status'], where: 'id = ?', whereArgs: [j['id']]);
        final sentHere = existing.isNotEmpty && existing.first['status'] == 'sent';
        // Keep "sent" while our upload is pending, so a stale "open" does not bring it back.
        final status = (sentHere && j['status'] == 'open') ? 'sent' : j['status'] as String;
        await txn.insert(
            'receipts',
            {
              'id': j['id'], 'supplier': j['supplier'], 'status': status, 'note': j['note'] ?? '',
              'created_at': j['created_at'], 'lines': jsonEncode(j['lines']),
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await txn.insert('kv', {'key': 'version', 'value': '${data['version']}'},
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // ---------- outbox ----------

  Future<void> enqueue(String kind, String id, Map<String, Object?> payload) => db.insert(
      'outbox', {'id': '$kind:$id', 'kind': kind, 'payload': jsonEncode(payload), 'created_at': DateTime.now().toIso8601String()},
      conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Map<String, Object?>>> pendingOutbox({int limit = 100}) =>
      db.query('outbox', where: "state = 'pending'", orderBy: 'created_at', limit: limit);

  Future<int> countOutbox(String state) async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM outbox WHERE state = ?', [state])) ?? 0;

  Future<List<Map<String, Object?>>> rejectedOutbox() =>
      db.query('outbox', where: "state = 'rejected'", orderBy: 'created_at DESC');

  Future<void> removeOutbox(String id) => db.delete('outbox', where: 'id = ?', whereArgs: [id]);

  Future<void> rejectOutbox(String id, String reason) =>
      db.update('outbox', {'state': 'rejected', 'error': reason}, where: 'id = ?', whereArgs: [id]);
}
