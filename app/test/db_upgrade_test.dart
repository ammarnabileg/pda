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
          await db.execute('CREATE TABLE outbox(id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL, state TEXT NOT NULL DEFAULT \'pending\', error TEXT)');
        },
      ),
    );
    await old.insert('products', {'id': 1, 'barcode': '1', 'name': 'x', 'unit': 'piece', 'price': 100, 'carton': 0, 'stock': 0, 'active': 1});
    await old.insert('kv', {'key': 'version', 'value': '57'});
    await old.insert('outbox', {'id': 'sales:a', 'kind': 'sales', 'payload': '{}', 'created_at': 'now'});
    await old.close();

    final db = await LocalDb.open(path: path, factory: databaseFactoryFfi);
    final p = await db.productById(1);
    expect(p!.cost, 0);
    expect(await db.get('version'), '0', reason: 'next sync downloads everything, including purchase prices');
    expect(await db.countOutbox('pending'), 1, reason: 'sales not yet sent survive the upgrade');
  });
}
