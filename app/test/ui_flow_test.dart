import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tamween_pda/data/app_state.dart';
import 'package:tamween_pda/data/db.dart';
import 'package:tamween_pda/main.dart';
import 'package:tamween_pda/ui/widgets.dart';
import 'package:tamween_pda/util/pin_hash.dart';

const keys = {
  '0': LogicalKeyboardKey.digit0,
  '1': LogicalKeyboardKey.digit1,
  '2': LogicalKeyboardKey.digit2,
  '3': LogicalKeyboardKey.digit3,
  '4': LogicalKeyboardKey.digit4,
  '5': LogicalKeyboardKey.digit5,
  '6': LogicalKeyboardKey.digit6,
  '7': LogicalKeyboardKey.digit7,
  '8': LogicalKeyboardKey.digit8,
  '9': LogicalKeyboardKey.digit9,
};

Future<LocalDb> seededDb() async {
  sqfliteFfiInit();
  // A fresh file per test: in-memory databases can be shared between tests in one process.
  final path = '${Directory.systemTemp.createTempSync('tamween_test').path}/t.db';
  final db = await LocalDb.open(path: path, factory: databaseFactoryFfi);
  const salt = 's1';
  await db.applyPull({
    'version': 10,
    'full': true,
    'products': [
      {
        'id': 1,
        'barcode': '6281000123456',
        'barcodes': [
          {'code': '16281000123453', 'mode': 'carton'},
          {'code': '6281000123999', 'mode': 'piece'},
        ],
        'name': 'أرز بسمتي ٥ كجم',
        'unit': 'piece',
        'price': '2.450',
        'carton': 6,
        'stock': '48',
        'active': true,
      },
      {
        'id': 3,
        'barcode': '6281000999999',
        'name': 'زيت زيتون إسباني بكر ممتاز معصور على البارد عبوة زجاجية ٧٥٠ مل',
        'unit': 'piece',
        'price': '12.750',
        'cost': '10.100',
        'carton': 12,
        'stock': '1250',
        'active': true,
      },
      {
        'id': 2,
        'barcode': '2100000012345',
        'name': 'سكر أبيض (بالكيلو)',
        'unit': 'kg',
        'price': '0.350',
        'carton': 0,
        'stock': '125',
        'active': true,
      },
    ],
    'employees': [
      {'id': 1, 'name': 'أحمد', 'role': 'cashier', 'pin_salt': salt, 'pin_hash': hashPin('2222', salt), 'active': true},
      {'id': 2, 'name': 'محمود', 'role': 'storekeeper', 'pin_salt': salt, 'pin_hash': hashPin('3333', salt), 'active': true},
    ],
    'suppliers': [
      {'id': 4, 'name': 'شركة المواد الغذائية'},
    ],
    'receipts': [
      {
        'id': 7,
        'supplier': 'شركة المواد الغذائية',
        'status': 'open',
        'note': '',
        'created_at': '2026-11-01T10:00:00Z',
        'lines': [
          {'product_id': 1, 'mode': 'carton', 'ordered': '10'},
        ],
      },
    ],
  });
  return db;
}

/// Waits until the confirmation bar at the bottom has gone (it covers the lowest rows).
Future<void> noToast(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 7));
  await tester.pumpAndSettle();
}

Future<void> scan(WidgetTester tester, String code) async {
  for (final ch in code.split('')) {
    await tester.sendKeyEvent(keys[ch]!);
  }
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
}

/// Waits (in real time) until [f] shows up; screens load from the database asynchronously.
Future<void> waitFor(WidgetTester tester, Finder f) async {
  for (var i = 0; i < 50 && f.evaluate().isEmpty; i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }
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
    expect(find.widgetWithText(QtyStepper, '2 حبة'), findsOneWidget);
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
    expect(find.text('الصنف غير مسجل على الجهاز'), findsOneWidget);
    await tester.tap(find.text('حسناً'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('إنهاء البيع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تم الدفع'));
    await settle(tester, 800);
    expect(find.text('تم تسجيل البيع'), findsOneWidget);
    expect(find.text(W.savedLocal), findsOneWidget, reason: 'offline: saved on the device, not claimed as sent');
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
    expect(find.text('معدود قبل كده: 12 حبة (2 كرتون)'), findsOneWidget);
    await tester.tap(find.text('زوّد على نفس البند'));
    await settle(tester);
    await tester.tap(find.text('5').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.textContaining('17 حبة (2 كرتون و 5 حبة)', findRichText: true), findsOneWidget);
    await tester.tap(find.textContaining('إنهاء الجرد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نعم، إنهاء'));
    await settle(tester, 800);
    expect(find.text('تم حفظ الجرد'), findsOneWidget);
    await tester.tap(find.text('الرئيسية'));
    await settle(tester);

    await tester.tap(find.text('استلام'));
    await settle(tester);
    await tester.tap(find.text('شركة المواد الغذائية'));
    await settle(tester);
    await tester.tap(find.text('تأكيد الاستلام'));
    await settle(tester);
    expect(find.text('باقي 1 أصناف ماتراجعتش'), findsOneWidget);
    await tester.tap(find.text('حسناً'));
    await tester.pumpAndSettle();
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('مسح الكل'));
    await tester.tap(find.text('9').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    // The screen moved to the "not reviewed" filter, so the reviewed item left the list.
    expect(find.text('ناقص 1 كرتون'), findsNothing);
    await tester.tap(find.textContaining('فيه فرق'));
    await settle(tester);
    expect(find.text('ناقص 1 كرتون'), findsOneWidget);
    await tester.tap(find.text('تأكيد الاستلام'));
    await tester.pumpAndSettle();
    expect(find.textContaining('فيه فروقات في 1 من 1 صنف'), findsOneWidget);
    await tester.tap(find.text('نعم، تأكيد'));
    await settle(tester, 800);
    final kinds = (await tester.runAsync(() => app.db.pendingOutbox()))!.map((r) => r['kind']).toList();
    expect(kinds, containsAll(['counts', 'receipts']));
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('scanner that injects text, and a scanner with no Enter suffix', (tester) async {
    await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);

    // Mode 1: the wedge writes the code into the focused field and presses Enter.
    final field = find.byKey(const Key('scanner-input'));
    expect(field, findsOneWidget);
    // The input connection is open (needed for injected text), but with type "none",
    // so Android never shows the on-screen keyboard.
    expect(tester.testTextInput.setClientArgs!['inputType']['name'], 'TextInputType.none');
    tester.testTextInput.enterText('6281000123456');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('أرز بسمتي ٥ كجم'), findsOneWidget);
    expect(find.widgetWithText(QtyStepper, '1 حبة'), findsOneWidget);

    // Mode 2: key events at scanner speed with no Enter at the end.
    for (final ch in '6281000123456'.split('')) {
      await tester.sendKeyEvent(keys[ch]!);
    }
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '2 حبة'), findsOneWidget);

    // Slow typing (a person on a hardware keypad) is not taken as a scan without Enter.
    // The app measures real time between characters, so wait in real time here.
    for (final ch in '62810001'.split('')) {
      await tester.sendKeyEvent(keys[ch]!);
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 150)));
    }
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(find.text('الصنف غير مسجل على الجهاز'), findsNothing);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('scanner works in the search box, the number pad and the receipt list', (tester) async {
    await startApp(tester);
    await login(tester, 'محمود', '3333');

    // Receipt list: scanning opens the voucher with that item and asks its quantity.
    await tester.tap(find.text('استلام'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await waitFor(tester, find.textContaining('المطلوب: 10 كرتون — اكتب اللي وصل'));
    expect(find.textContaining('المطلوب: 10 كرتون — اكتب اللي وصل'), findsOneWidget);

    // Number pad, text-injecting scanner: a new scan closes the pad and is handled as a scan.
    tester.testTextInput.enterText('6281000123456');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump(const Duration(milliseconds: 500));
    await waitFor(tester, find.textContaining('المطلوب: 10 كرتون — اكتب اللي وصل'));
    expect(find.textContaining('المطلوب: 10 كرتون — اكتب اللي وصل'), findsOneWidget, reason: 'reopened for the scanned item');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('scanning while the name search is open picks the product', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'محمود', '3333');
    await tester.tap(find.text('جرد'));
    await settle(tester);
    await tester.tap(find.text('ابحث بالاسم'));
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, '2100000012345');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('سكر أبيض (بالكيلو)'), findsWidgets);
    expect(find.text('اكتب العدد الموجود على الرف'), findsOneWidget);
    expect(app.employee?.name, 'محمود');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('large Android font and a very long name still fit on a 360 x 640 screen', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);
    for (var i = 0; i < 3; i++) {
      await scan(tester, '6281000999999');
      await settle(tester);
    }
    await scan(tester, '6281000123456');
    await settle(tester);
    await noToast(tester);
    expect(find.widgetWithText(QtyStepper, '3 حبة'), findsOneWidget);
    expect(find.text('38.250'), findsOneWidget); // 3 x 12.750, kept whole next to the long name
    // Details sheet shows the purchase price.
    await tester.tap(find.textContaining('زيت زيتون'));
    await settle(tester);
    expect(find.text('12.750 / 10.100 د.ك للحبة'), findsOneWidget);
    await tester.tap(find.text('تعديل الكمية'));
    await settle(tester);
    await tester.tap(find.text('كرتون'));
    await tester.pump();
    expect(find.text('الكرتون = 12 حبة'), findsOneWidget);
    await tester.tap(find.text('إلغاء'));
    await settle(tester);
    // Other screens at this size: any overflow fails the test.
    await tester.tap(find.text('رجوع'));
    await settle(tester);
    await tester.tap(find.text('سعر صنف'));
    await settle(tester);
    await scan(tester, '6281000999999');
    await settle(tester);
    expect(find.text('سعر الشراء'), findsOneWidget);
    await tester.tap(find.byType(SyncIndicator).first);
    await settle(tester);
    expect(find.text('مزامنة الآن'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('a carton barcode sells a carton; a second piece barcode sells a piece', (tester) async {
    await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);
    await scan(tester, '16281000123453');
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '1 كرتون'), findsOneWidget);
    expect(find.text('14.700'), findsWidgets); // 6 x 2.450
    // Same product, other unit: the app asks.
    await scan(tester, '6281000123999');
    await settle(tester);
    expect(find.text('موجود في الفاتورة: 1 كرتون\nالمسح ده: 1 حبة'), findsOneWidget);
    await tester.tap(find.text('اعمله بند جديد'));
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '1 حبة'), findsOneWidget);
    expect(find.widgetWithText(QtyStepper, '1 كرتون'), findsOneWidget);
    expect(find.text('17.150'), findsOneWidget); // 14.700 + 2.450
    // Same unit as an existing line goes straight onto it.
    await scan(tester, '16281000123453');
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '2 كرتون'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('other unit, added to the old line: 1 piece + 1 carton = 7 pieces', (tester) async {
    await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await scan(tester, '16281000123453');
    await settle(tester);
    expect(find.text('موجود في الفاتورة: 1 حبة\nالمسح ده: 1 كرتون'), findsOneWidget);
    await tester.tap(find.text('زوّد على البند القديم'));
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '7 حبة'), findsOneWidget);
    expect(find.text('17.150'), findsWidgets);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('counting with a carton barcode starts the pad on cartons', (tester) async {
    await startApp(tester);
    await login(tester, 'محمود', '3333');
    await tester.tap(find.text('جرد'));
    await settle(tester);
    await scan(tester, '16281000123453');
    await settle(tester);
    await tester.tap(find.text('2').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.textContaining('12 حبة (2 كرتون)', findRichText: true), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('same unit twice: added to the line, with a "separate line" option', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    expect(find.widgetWithText(QtyStepper, '2 حبة'), findsOneWidget);
    await tester.tap(find.text('بند منفصل'));
    await settle(tester);
    await noToast(tester);
    expect(find.widgetWithText(QtyStepper, '1 حبة'), findsNWidgets(2));
    // Finish and find it in the device's invoice history.
    await tester.tap(find.text('إنهاء البيع'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تم الدفع'));
    await settle(tester, 800);
    final out = (await tester.runAsync(() => app.db.pendingOutbox()))!;
    expect(out.single['payload'].toString().split('product_id').length - 1, 2, reason: 'two separate lines are sent');
    await tester.tap(find.text('سجل الفواتير'));
    await settle(tester);
    expect(find.text('4.900'), findsOneWidget);
    expect(find.text('على الجهاز'), findsOneWidget, reason: 'not sent yet: offline');
    await tester.tap(find.text('4.900'));
    await settle(tester);
    expect(find.text('أرز بسمتي ٥ كجم'), findsNWidgets(2));
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('count: a second shelf is a separate entry, sent as one total per product', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'محمود', '3333');
    await tester.tap(find.text('جرد'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('4').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    await scan(tester, '6281000123456');
    await settle(tester);
    await tester.tap(find.text('بند جديد (رف أو مكان تاني)'));
    await settle(tester);
    await tester.tap(find.text('3').last);
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.textContaining('العدد', findRichText: true), findsNothing);
    expect(find.textContaining('4 حبة', findRichText: true), findsOneWidget);
    expect(find.textContaining('3 حبة', findRichText: true), findsOneWidget);
    expect(find.text('1 صنف معدود'), findsOneWidget);
    await tester.tap(find.textContaining('إنهاء الجرد'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نعم، إنهاء'));
    await settle(tester, 800);
    final out = (await tester.runAsync(() => app.db.pendingOutbox()))!;
    expect(out.single['payload'].toString(), contains('"counted":"7.000"'));
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('receiving: a note on one item is sent and kept in the history', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'محمود', '3333');
    await tester.tap(find.text('استلام'));
    await settle(tester);
    await tester.tap(find.text('شركة المواد الغذائية'));
    await settle(tester);
    await tester.tap(find.text('كامل'));
    await settle(tester);
    await tester.tap(find.bySemanticsLabel('ملاحظة على الصنف'));
    await settle(tester);
    await tester.tap(find.widgetWithText(ActionChip, 'كرتون تالف'));
    await tester.pump();
    await tester.tap(find.text('حفظ'));
    await settle(tester);
    expect(find.textContaining('ملاحظة: كرتون تالف', findRichText: true), findsOneWidget);
    await tester.tap(find.text('تأكيد الاستلام'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نعم، تأكيد'));
    await settle(tester, 800);
    final out = (await tester.runAsync(() => app.db.pendingOutbox()))!;
    expect(out.single['payload'].toString(), contains('"note":"كرتون تالف"'));
    final hist = (await tester.runAsync(() => app.db.history('receipts')))!;
    expect(hist.single.data['lines'][0]['note'], 'كرتون تالف');
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('the scan box says the device is listening and shows the last code', (tester) async {
    await startApp(tester);
    await login(tester, 'أحمد', '2222');
    await tester.tap(find.text('بيع'));
    await settle(tester);
    expect(find.textContaining('جاهز —'), findsOneWidget);
    await scan(tester, '6281000123456');
    await settle(tester);
    expect(find.text('آخر باركود: 6281000123456'), findsOneWidget);
    await tester.pump(const Duration(seconds: 30));
  });

  testWidgets('receiving without a voucher: new supplier, scan, note, confirm', (tester) async {
    final app = await startApp(tester);
    await login(tester, 'محمود', '3333');
    await tester.tap(find.text('استلام'));
    await settle(tester);
    await tester.tap(find.text('استلام من غير سند'));
    await settle(tester);
    await waitFor(tester, find.text('شركة المواد الغذائية'));
    await tester.pumpAndSettle(); // let the sheet finish sliding up
    // The supplier list opens first.
    expect(find.text('شركة المواد الغذائية'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'مورد جديد');
    await tester.pump();
    await tester.tap(find.text('مورد جديد: مورد جديد'));
    await settle(tester);
    expect(find.text('مورد جديد — هيتضاف للوحة التحكم'), findsOneWidget);
    // A carton barcode starts the pad on cartons.
    await scan(tester, '16281000123453');
    await settle(tester);
    await tester.tap(find.text('3').last);
    await tester.tap(find.text('إضافة'));
    await settle(tester);
    expect(find.textContaining('مستلم 3 كرتون', findRichText: true), findsOneWidget);
    await tester.tap(find.textContaining('تأكيد الاستلام'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('نعم، تأكيد'));
    await settle(tester, 800);
    expect(find.text('تم تسجيل الاستلام'), findsOneWidget);
    expect(find.textContaining('مستني موافقة المشرف'), findsOneWidget);
    final rice = (await tester.runAsync(() => app.db.productByBarcode('6281000123456')))!;
    expect(rice.stock, 48000, reason: 'device stock waits for the supervisor too');
    final out = (await tester.runAsync(() => app.db.pendingOutbox()))!;
    expect(out.single['kind'], 'new_receipts');
    expect(out.single['payload'].toString(), contains('"supplier_name":"مورد جديد"'));
    expect(out.single['payload'].toString(), contains('"mode":"carton","qty":"3.000"'));
    final hist = (await tester.runAsync(() => app.db.history('receipts')))!;
    expect(hist.single.kind, 'new_receipts');
    expect(await tester.runAsync(() => app.db.getJson('draft_new_receipt')), isNull);
    await tester.pump(const Duration(seconds: 30));
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 300)));
    await tester.pump(const Duration(seconds: 30));
  });
}
