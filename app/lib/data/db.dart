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
    final db = await f.openDatabase(
      file,
      options: OpenDatabaseOptions(version: 6, onCreate: _create, onUpgrade: _upgrade),
    );
    return LocalDb(db);
  }

  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      await db.execute('ALTER TABLE products ADD COLUMN cost INTEGER NOT NULL DEFAULT 0');
      // Purchase prices only arrive with a full download.
      await db.insert('kv', {'key': 'version', 'value': '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (from < 4) await _createHistory(db);
    if (from < 5) await _createSuppliers(db);
    if (from < 6) {
      final cols = (await db.rawQuery('PRAGMA table_info(employees)')).map((c) => c['name']).toSet();
      if (cols.isEmpty) {
        await _createEmployees(db);
      } else {
        if (!cols.contains('role_name')) await db.execute('ALTER TABLE employees ADD COLUMN role_name TEXT');
        if (!cols.contains('permissions')) await db.execute('ALTER TABLE employees ADD COLUMN permissions TEXT');
      }
      // Permissions only arrive with a full download; until then the old fixed roles apply.
      await db.insert('kv', {'key': 'version', 'value': '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (from < 3) {
      await _createBarcodes(db);
      // Extra barcodes only arrive with a full download.
      await db.insert('kv', {'key': 'version', 'value': '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> _createEmployees(Database db) =>
      db.execute('''CREATE TABLE IF NOT EXISTS employees(id INTEGER PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
      role_name TEXT, permissions TEXT, pin_salt TEXT NOT NULL, pin_hash TEXT NOT NULL, active INTEGER NOT NULL)''');

  static Future<void> _createSuppliers(Database db) =>
      db.execute('CREATE TABLE IF NOT EXISTS suppliers(id INTEGER PRIMARY KEY, name TEXT NOT NULL)');

  /// Finished work on this device (sales, received vouchers, counts), newest first.
  static Future<void> _createHistory(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS history(id TEXT PRIMARY KEY, kind TEXT NOT NULL, at TEXT NOT NULL, data TEXT NOT NULL)');
    await db.execute('CREATE INDEX IF NOT EXISTS history_kind_at ON history(kind, at)');
  }

  /// More barcodes per product (another piece barcode, or the carton's own).
  static Future<void> _createBarcodes(Database db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS barcodes(code TEXT PRIMARY KEY, product_id INTEGER NOT NULL, mode TEXT NOT NULL)');
    await db.execute('CREATE INDEX IF NOT EXISTS barcodes_product ON barcodes(product_id)');
  }

  static Future<void> _create(Database db, int version) async {
    await db.execute(
      '''CREATE TABLE products(id INTEGER PRIMARY KEY, barcode TEXT NOT NULL, name TEXT NOT NULL,
      unit TEXT NOT NULL, price INTEGER NOT NULL, cost INTEGER NOT NULL DEFAULT 0, carton INTEGER NOT NULL, stock INTEGER NOT NULL, active INTEGER NOT NULL)''',
    );
    await db.execute('CREATE INDEX products_barcode ON products(barcode)');
    await _createBarcodes(db);
    await _createHistory(db);
    await _createSuppliers(db);
    await _createEmployees(db);
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
    final r = await db.query(
      'products',
      where: 'active = 1 AND barcode IN (${List.filled(variants.length, '?').join(',')})',
      whereArgs: variants,
    );
    if (r.isEmpty) return null;
    final exact = r.where((x) => x['barcode'] == code);
    return Product.fromRow(exact.isNotEmpty ? exact.first : r.first);
  }

  /// Any barcode: the main one (piece / kg) or an extra one with its own unit.
  Future<ScanHit?> lookup(String code) async {
    final p = await productByBarcode(code);
    if (p != null) return ScanHit(p, p.isKg ? 'kg' : 'piece');
    code = code.trim();
    if (code.isEmpty) return null;
    final variants = {code, '0$code', if (code.startsWith('0')) code.substring(1)}.toList();
    final r = await db.rawQuery(
      'SELECT p.*, b.mode AS scan_mode FROM barcodes b JOIN products p ON p.id = b.product_id '
      'WHERE p.active = 1 AND b.code IN (${List.filled(variants.length, '?').join(',')})',
      variants,
    );
    if (r.isEmpty) return null;
    return ScanHit(Product.fromRow(r.first), r.first['scan_mode'] as String);
  }

  Future<List<String>> barcodesOf(int productId) async {
    final r = await db.query('barcodes', columns: ['code', 'mode'], where: 'product_id = ?', whereArgs: [productId]);
    return [for (final x in r) '${x['code']} (${x['mode'] == 'carton' ? 'كرتون' : (x['mode'] == 'kg' ? 'كيلو' : 'حبة')})'];
  }

  Future<List<Product>> searchProducts(String q, {int limit = 40}) async {
    q = q.trim();
    final r = await db.query(
      'products',
      where: q.isEmpty
          ? 'active = 1'
          : 'active = 1 AND (name LIKE ? OR barcode LIKE ? OR id IN (SELECT product_id FROM barcodes WHERE code LIKE ?))',
      whereArgs: q.isEmpty ? null : ['%$q%', '%$q%', '%$q%'],
      orderBy: 'name',
      limit: limit,
    );
    return r.map(Product.fromRow).toList();
  }

  Future<Map<int, Product>> productsByIds(Iterable<int> ids) async {
    final list = ids.toSet().toList();
    if (list.isEmpty) return {};
    final r = await db.query('products', where: 'id IN (${List.filled(list.length, '?').join(',')})', whereArgs: list);
    return {for (final row in r) row['id'] as int: Product.fromRow(row)};
  }

  Future<int> productCount() async => Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM products WHERE active = 1')) ?? 0;

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
      lines: lines,
    );
  }

  Future<void> markReceiptSent(int id) => db.update('receipts', {'status': 'sent'}, where: 'id = ?', whereArgs: [id]);

  // ---------- server pull ----------

  Future<void> applyPull(Map<String, dynamic> data) async {
    await db.transaction((txn) async {
      final batch = txn.batch();
      if (data['full'] == true) {
        // A full pull is the server's complete picture: drop what it no longer has.
        batch.delete('products');
        batch.delete('barcodes');
        batch.delete('employees');
        batch.delete('receipts', where: "status != 'sent'");
      }
      for (final j in (data['products'] as List)) {
        batch.insert('products', Product.fromApi(j).toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
        batch.delete('barcodes', where: 'product_id = ?', whereArgs: [j['id']]);
        for (final b in (j['barcodes'] as List?) ?? const []) {
          batch.insert('barcodes', {
            'code': b['code'],
            'product_id': j['id'],
            'mode': b['mode'],
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      for (final j in (data['employees'] as List)) {
        batch.insert('employees', Employee.fromApi(j).toRow(), conflictAlgorithm: ConflictAlgorithm.replace);
      }
      if (data['suppliers'] is List) {
        batch.delete('suppliers');
        for (final x in data['suppliers'] as List) {
          batch.insert('suppliers', {'id': x['id'], 'name': x['name']});
        }
      }
      await batch.commit(noResult: true);
      for (final j in (data['receipts'] as List)) {
        final existing = await txn.query('receipts', columns: ['status'], where: 'id = ?', whereArgs: [j['id']]);
        final sentHere = existing.isNotEmpty && existing.first['status'] == 'sent';
        // Keep "sent" while our upload is pending, so a stale "open" does not bring it back.
        final status = (sentHere && j['status'] == 'open') ? 'sent' : j['status'] as String;
        await txn.insert('receipts', {
          'id': j['id'],
          'supplier': j['supplier'],
          'status': status,
          'note': j['note'] ?? '',
          'created_at': j['created_at'],
          'lines': jsonEncode(j['lines']),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      // Supervisor's answer on vouchers made here: kept on the history entry.
      final unseen = <String>{
        ...((jsonDecode((await txn.query('kv', where: "key = 'unseen_decisions'")).firstOrNull?['value'] as String? ?? '[]') as List)
            .cast<String>()),
      };
      for (final d in (data['decisions'] as List?) ?? const []) {
        final rows = await txn.query('history', where: "kind = 'new_receipts' AND id = ?", whereArgs: [d['id']]);
        if (rows.isEmpty) continue;
        final h = jsonDecode(rows.first['data'] as String) as Map<String, dynamic>;
        final before = (h['decision'] as Map?)?['status'];
        if (before == d['status']) continue;
        h['decision'] = d;
        await txn.update('history', {'data': jsonEncode(h)}, where: 'id = ?', whereArgs: [d['id']]);
        if (d['status'] != 'pending') unseen.add(d['id'] as String);
      }
      await txn.insert('kv', {
        'key': 'unseen_decisions',
        'value': jsonEncode(unseen.toList()),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('kv', {'key': 'version', 'value': '${data['version']}'}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  /// Vouchers the supervisor answered that nobody has looked at on this device yet.
  Future<int> unseenDecisions() async => ((await getJson('unseen_decisions') as List?) ?? const []).length;
  Future<void> clearUnseenDecisions() => setJson('unseen_decisions', <String>[]);

  Future<List<(int, String)>> suppliers() async {
    final r = await db.query('suppliers', orderBy: 'name');
    return [for (final x in r) (x['id'] as int, x['name'] as String)];
  }

  // ---------- history ----------

  static const historyDays = 60;

  Future<void> addHistory(String kind, String id, Map<String, Object?> data) async {
    await db.insert('history', {
      'id': id,
      'kind': kind,
      'at': DateTime.now().toIso8601String(),
      'data': jsonEncode(data),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    final cutoff = DateTime.now().subtract(const Duration(days: historyDays)).toIso8601String();
    await db.delete('history', where: 'at < ?', whereArgs: [cutoff]);
  }

  /// [kind] "receipts" also lists vouchers made on the device ("new_receipts").
  Future<List<HistoryEntry>> history(String kind, {DateTime? since, int limit = 300}) async {
    final kinds = kind == 'receipts' ? ['receipts', 'new_receipts'] : [kind];
    final r = await db.query(
      'history',
      where: 'kind IN (${List.filled(kinds.length, '?').join(',')})${since == null ? '' : ' AND at >= ?'}',
      whereArgs: [...kinds, if (since != null) since.toIso8601String()],
      orderBy: 'at DESC',
      limit: limit,
    );
    return [
      for (final x in r)
        HistoryEntry(
          x['id'] as String,
          x['kind'] as String,
          DateTime.parse(x['at'] as String),
          jsonDecode(x['data'] as String) as Map<String, dynamic>,
        ),
    ];
  }

  // ---------- outbox ----------

  Future<void> enqueue(String kind, String id, Map<String, Object?> payload) => db.insert('outbox', {
    'id': '$kind:$id',
    'kind': kind,
    'payload': jsonEncode(payload),
    'created_at': DateTime.now().toIso8601String(),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<List<Map<String, Object?>>> pendingOutbox({int limit = 100}) =>
      db.query('outbox', where: "state = 'pending'", orderBy: 'created_at', limit: limit);

  Future<bool> inOutbox(String key) async => (await db.query('outbox', columns: ['id'], where: 'id = ?', whereArgs: [key])).isNotEmpty;

  Future<Map<String, int>> pendingByKind() async {
    final r = await db.rawQuery("SELECT kind, COUNT(*) AS n FROM outbox WHERE state = 'pending' GROUP BY kind");
    return {for (final x in r) x['kind'] as String: x['n'] as int};
  }

  Future<int> countOutbox(String state) async =>
      Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM outbox WHERE state = ?', [state])) ?? 0;

  Future<List<Map<String, Object?>>> rejectedOutbox() => db.query('outbox', where: "state = 'rejected'", orderBy: 'created_at DESC');

  Future<void> removeOutbox(String id) => db.delete('outbox', where: 'id = ?', whereArgs: [id]);

  Future<void> rejectOutbox(String id, String reason) =>
      db.update('outbox', {'state': 'rejected', 'error': reason}, where: 'id = ?', whereArgs: [id]);
}
