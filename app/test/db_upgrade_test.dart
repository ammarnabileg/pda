import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamween_pda/data/db.dart';

void main() {
  test('a device database from version 1 upgrades: cost column added, full download forced', () async {
    sqfliteFfiInit();
    final path = '${Directory.systemTemp.createTempSync('tamween_upgrade').path}/t.db';
    // Version 1 schema exactly as the first release created it.
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, v) async {
          await db.execute('''CREATE TABLE products(id INTEGER PRIMARY KEY, barcode TEXT NOT NULL, name TEXT NOT NULL,
            unit TEXT NOT NULL, price INTEGER NOT NULL, carton INTEGER NOT NULL, stock INTEGER NOT NULL, active INTEGER NOT NULL)''');
          await db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
          await db.execute(
            'CREATE TABLE outbox(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL, state TEXT NOT NULL DEFAULT \'pending\', error TEXT)',
          );
        },
      ),
    );
    await old.insert('products', {
      'id': 1,
      'barcode': '1',
      'name': 'x',
      'unit': 'piece',
      'price': 100,
      'carton': 0,
      'stock': 0,
      'active': 1,
    });
    await old.insert('kv', {'key': 'version', 'value': '57'});
    await old.insert('outbox', {'id': 'sales:a', 'kind': 'sales', 'payload': '{}', 'created_at': 'now'});
    await old.close();

    final db = await LocalDb.open(path: path, factory: databaseFactoryFfi);
    final p = await db.productById(1);
    expect(p!.cost, 0);
    expect(await db.get('version'), '0', reason: 'next sync downloads everything, including purchase prices');
    expect(await db.countOutbox('pending'), 1, reason: 'sales not yet sent survive the upgrade');
    expect(await db.lookup('nothing'), isNull, reason: 'barcodes table exists after the upgrade');
    expect(await db.suppliers(), isEmpty, reason: 'suppliers table exists after the upgrade');
    expect(await db.history('sales'), isEmpty, reason: 'history table exists after the upgrade');
  });

  test('version 5 upgrades to 6: employees keep working on the old fixed roles until the next full download', () async {
    sqfliteFfiInit();
    final path = '${Directory.systemTemp.createTempSync('tamween_upgrade6').path}/t.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, v) async {
          await db.execute('''CREATE TABLE employees(id INTEGER PRIMARY KEY, name TEXT NOT NULL, role TEXT NOT NULL,
            pin_salt TEXT NOT NULL, pin_hash TEXT NOT NULL, active INTEGER NOT NULL)''');
          await db.execute('CREATE TABLE kv(key TEXT PRIMARY KEY, value TEXT NOT NULL)');
        },
      ),
    );
    await old.insert('employees', {'id': 1, 'name': 'أحمد', 'role': 'cashier', 'pin_salt': 's', 'pin_hash': 'h', 'active': 1});
    await old.insert('kv', {'key': 'version', 'value': '90'});
    await old.close();

    final db = await LocalDb.open(path: path, factory: databaseFactoryFfi);
    final e = (await db.employeeById(1))!;
    expect(e.permissions, isNull);
    expect(e.can('sale'), isTrue);
    expect(e.can('count'), isFalse);
    expect(e.roleName, 'كاشير');
    expect(await db.get('version'), '0', reason: 'next sync downloads the real permissions');
  });
}
