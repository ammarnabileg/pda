// End-to-end check against a real server. Run from the repo root with:
//   ./scripts/e2e.sh
// It is skipped when TAMWEEN_SERVER / TAMWEEN_CODE are not set.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamween_pda/data/app_state.dart';
import 'package:tamween_pda/data/db.dart';
import 'package:tamween_pda/util/format.dart';
import 'package:tamween_pda/util/ids.dart';

void main() {
  final server = Platform.environment['TAMWEEN_SERVER'];
  final code = Platform.environment['TAMWEEN_CODE'];
  final skip = server == null || code == null ? 'TAMWEEN_SERVER / TAMWEEN_CODE not set' : null;

  test('pair, pull, push a sale, a count and a receipt, offline queue', () async {
    sqfliteFfiInit();
    final db = await LocalDb.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
    final app = AppState(db);

    expect(await app.pair('127.0.0.1:1', code!), contains('مش قادر أوصل'));
    expect(await app.pair(server!, '999999'), contains('الكود غلط'));
    expect(await app.pair(server, code), isNull);
    expect(app.productCount, 6);

    final staff = await db.activeEmployees();
    expect(staff.length, 3);
    final ahmad = staff.firstWhere((e) => e.name == 'أحمد');
    expect(await app.login(ahmad, '9999'), isFalse);
    expect(await app.login(ahmad, '2222'), isTrue);

    final rice = (await db.productByBarcode('6281000123456'))!;
    final sugar = (await db.productByBarcode('2100000012345'))!;
    expect(rice.stock, 48000);

    // Sale: 1 carton of rice + 1.250 kg sugar.
    final saleId = uuid4();
    await db.enqueue('sales', saleId, {
      'id': saleId,
      'employee_id': ahmad.id,
      'created_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        {'product_id': rice.id, 'mode': 'carton', 'qty': '1.000', 'unit_price': money(rice.unitPrice('carton'))},
        {'product_id': sugar.id, 'mode': 'kg', 'qty': '1.250', 'unit_price': money(sugar.price)},
      ],
    });
    // Count and receipt.
    final countId = uuid4();
    await db.enqueue('counts', countId, {
      'id': countId, 'employee_id': ahmad.id, 'finished_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [{'product_id': rice.id, 'counted': '40.000'}],
    });
    final receipts = await db.openReceipts();
    expect(receipts.length, 2);
    final r = receipts.first;
    await db.enqueue('receipts', '${r.id}', {
      'receipt_id': r.id, 'employee_id': ahmad.id, 'notes': 'كرتون تالف',
      'lines': [for (final l in r.lines) {'product_id': l.productId, 'mode': l.mode, 'qty': money(l.ordered)}],
    });
    await db.markReceiptSent(r.id);
    await app.recordSaved();
    await app.sync();
    expect(app.status, SyncStatus.ok);
    expect(app.pending, 0);
    expect(app.rejected, 0);

    // Server stock after the sale (-6) and the receipt (+60) came back down.
    final rice2 = (await db.productByBarcode('6281000123456'))!;
    expect(rice2.stock, (48 - 6 + 60) * 1000);
    expect((await db.openReceipts()).length, 1);

    // The same receipt again is now rejected: it was already received.
    await db.enqueue('receipts', '${r.id}', {'receipt_id': r.id, 'lines': []});
    await app.sync();
    expect(app.rejected, 0, reason: 'same device resending is treated as a duplicate');

    // Offline: records stay queued, nothing is lost.
    final offline = AppState(db)
      ..serverUrl = 'http://127.0.0.1:1'
      ..token = 'x';
    final id2 = uuid4();
    await db.enqueue('sales', id2, {
      'id': id2, 'lines': [{'product_id': rice.id, 'mode': 'piece', 'qty': '1.000', 'unit_price': '2.450'}],
    });
    await offline.sync();
    expect(offline.status, SyncStatus.offline);
    expect(offline.pending, 1);
    await app.sync();
    expect(app.pending, 0);
    app.dispose();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));
}
