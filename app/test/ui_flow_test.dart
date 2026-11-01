import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamween_pda/data/app_state.dart';
import 'package:tamween_pda/data/db.dart';
import 'package:tamween_pda/main.dart';
import 'package:tamween_pda/util/pin_hash.dart';

const keys = {
  '0': LogicalKeyboardKey.digit0, '1': LogicalKeyboardKey.digit1, '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3, '4': LogicalKeyboardKey.digit4, '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6, '7': LogicalKeyboardKey.digit7, '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
};

Future<LocalDb> seededDb() async {
  sqfliteFfiInit();
  final db = await LocalDb.open(path: inMemoryDatabasePath, factory: databaseFactoryFfi);
  const salt = 's1';
  await db.applyPull({
    'version': 10,
    'full': true,
    'products': [
      {'id': 1, 'barcode': '6281000123456', 'name': 'أرز بسمتي ٥ كجم', 'unit': 'piece', 'price': '2.450', 'carton': 6, 'stock': '48', 'active': true},
      {'id': 2, 'barcode': '2100000012345', 'name': 'سكر أبيض (بالكيلو)', 'unit': 'kg', 'price': '0.350', 'carton': 0, 'stock': '125', 'active': true},
    ],
    'employees': [
      {'id': 1, 'name': 'أحمد', 'role': 'cashier', 'pin_salt': salt, 'pin_hash': hashPin('2222', salt), 'active': true},
      {'id': 2, 'name': 'محمود', 'role': 'storekeeper', 'pin_salt': salt, 'pin_hash': hashPin('3333', salt), 'active': true},
    ],
    'receipts': [
      {'id': 7, 'supplier': 'شركة المواد الغذائية', 'status': 'open', 'note': '', 'created_at': '2026-11-01T10:00:00Z',
        'lines': [{'product_id': 1, 'mode': 'carton', 'ordered': '10'}]},
    ],
  });
  return db;
}

Future<void> scan(WidgetTester tester, String code) async {
  for (final ch in code.split('')) {
    await tester.sendKeyEvent(keys[ch]!);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

/// Lets real async work (database, PIN hashing) finish, then redraws.
Future<void> settle(WidgetTester tester, [int ms = 150]) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future.delayed(Duration(milliseconds: ms)));
    await tester.pump(const Duration(milliseconds: 50));
    if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}

Future<AppState> startApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(720, 1280);
  tester.view.devicePixelRatio = 2.0; // 360 x 640, a common PDA screen
  addTearDown(tester.view.reset);
  late AppState app;
  await tester.runAsync(() async {
    app = AppState(await seededDb())
      ..serverUrl = 'http://127.0.0.1:1'
      ..token = 't';
    await app.recordSavedCountsOnly();
  });
  await tester.pumpWidget(TamweenApp(app: app));
  await settle(tester);
  return app;
}

Future<void> login(WidgetTester tester, String name, String pin) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  for (final d in pin.split('')) {
    await tester.tap(find.text(d).last);
    await tester.pump();
  }
  await tester.tap(find.text('دخول'));
  // PIN hashing runs in a background isolate; wait for it in real time.
  for (var i = 0; i < 40 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty || i == 0; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 250)));
    await tester.pump();
  }
  await settle(tester);
}

void main() {
  testWidgets('cashier: login, scan to sell, weighed item, finish', (tester) async {
    final app = await startApp(tester);
    expect(find.text('اضغط على اسمك'), findsOneWidget);

    await login(tester, 'أحمد', '1234');
    expect(find.text('الرقم السري غلط'), findsOneWidget);
    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();
    await login(tester, 'أحمد', '2222');
    expect(find.text('بيع'), findsOneWidget);
    expect(find.text('جرد'), findsNothing, reason: 'cashiers do not count stock');

    await tester.tap(find.text('بيع'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    expect(find.text('أرز بسمتي ٥ كجم'), findsOneWidget);
    await scan(tester, '6281000123456');
    await settle(tester);
    expect(find.text('2 حبة'), findsOneWidget);
    expect(find.text('4.900'), findsWidgets);

    // Weighed item opens the pad; type 1.25 on it.
    await scan(tester, '2100000012345');
    await settle(tester);
    expect(find.textContaining('اكتب الوزن'), findsOneWidget);
    for (final k in ['1', '.', '2', '5']) {
      await tester.tap(find.text(k).last);
      await tester.pump();
    }
    await tester.tap(find.text('إضافة'));
    await settle(tester);
    expect(find.text('5.338'), findsOneWidget); // 4.900 + 0.4375 rounded

    // Unknown barcode shows the red message.
    await scan(tester, '9999999');
    await settle(tester);
    expect(find.text('الصنف غير مسجل'), findsOneWidget);
    await tester.tap(find.text('حسناً'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنهاء البيع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تم الدفع'));
    await settle(tester, 800);
    expect(find.text('تم البيع'), findsOneWidget);
    final out = await tester.runAsync(() => app.db.pendingOutbox());
    expect(out!.length, 1);
    expect(out.first['kind'], 'sales');
    expect(await tester.runAsync(() => app.db.getJson('draft_sale')), isNull);
    await tester.pump(const Duration(seconds: 30)); // let message timers finish
  });

  testWidgets('storekeeper: count merges cartons and pieces; receipt needs every line', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'محمود', '3333');
    expect(find.text('بيع'), findsNothing);

    await tester.tap(find.text('جرد'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('كرتون'));
    await tester.pump();
    await tester.tap(find.text('2').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('5').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.text('العدد: 17 حبة (2 كرتون و 5 حبة)'), findsOneWidget);
    await tester.tap(find.textContaining('إنهاء الجرد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نعم، إنهاء'));
    await settle(tester, 800);
    expect(find.text('تم حفظ الجرد'), findsOneWidget);
    await tester.tap(find.text('الرئيسية'));
    await settle(tester);

    await tester.tap(find.text('استلام بضاعة'));
    await settle(tester);
    await tester.tap(find.text('شركة المواد الغذائية'));
    await settle(tester);
    await tester.tap(find.text('تأكيد الاستلام'));
    await settle(tester);
    expect(find.text('باقي 1 أصناف لم تراجع'), findsOneWidget);
    await tester.tap(find.text('حسناً'));
    await tester.pumpAndSettle();
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('مسح الكل'));
    await tester.tap(find.text('9').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.text('ناقص 1 كرتون'), findsOneWidget);
    await tester.tap(find.text('تأكيد الاستلام'));
    await tester.pumpAndSettle();
    expect(find.textContaining('فيه فروقات في 1 صنف'), findsOneWidget);
    await tester.tap(find.text('نعم، تأكيد'));
    await settle(tester, 800);
    final kinds = (await tester.runAsync(() => app.db.pendingOutbox()))!.map((r) => r['kind']).toList();
    expect(kinds, containsAll(['counts', 'receipts']));
    await tester.pump(const Duration(seconds: 30));
  });
}
