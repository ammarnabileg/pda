import 'package:flutter_test/flutter_test.dart';
import 'package:tamween_pda/data/api.dart';
import 'package:tamween_pda/data/models.dart';
import 'package:tamween_pda/util/format.dart';
import 'package:tamween_pda/util/ids.dart';
import 'package:tamween_pda/util/pin_hash.dart';

void main() {
  test('PIN hash matches the server (server/app/security.py)', () {
    expect(hashPin('2468', 'abc123salt'), 'a2dd4e9b04ad158f9a1f098c45df05f75a2d6ffa7fc02519f0dc8caef4f4fb3a');
    expect(verifyPinArgs(['2468', 'abc123salt', 'a2dd4e9b04ad158f9a1f098c45df05f75a2d6ffa7fc02519f0dc8caef4f4fb3a']), isTrue);
    expect(verifyPinArgs(['2469', 'abc123salt', 'a2dd4e9b04ad158f9a1f098c45df05f75a2d6ffa7fc02519f0dc8caef4f4fb3a']), isFalse);
  });

  test('money and quantities use exact integers', () {
    expect(money(2450), '2.450');
    expect(money(5), '0.005');
    expect(money(-1200), '-1.200');
    expect(parseMilli('2.45'), 2450);
    expect(parseMilli('1.2509'), 1250);
    expect(parseMilli('10'), 10000);
    expect(parseMilli('abc'), isNull);
    expect(lineTotal(350, 1250), 438); // 0.4375 rounds half up
    expect(lineTotal(2450, 2000), 4900);
    expect(qtyText(1250, 'kg'), '1.250 كجم');
    expect(qtyText(3000, 'carton'), '3 كرتون');
  });

  test('product conversions', () {
    const p = Product(id: 1, barcode: 'x', name: 'أرز', unit: 'piece', price: 2450, carton: 6, stock: 48000, active: true);
    expect(p.unitPrice('carton'), 14700);
    expect(p.toBase(2000, 'carton'), 12000);
    expect(p.baseText(29000), '29 حبة (4 كرتون و 5 حبة)');
    expect(p.modes, ['piece', 'carton']);
  });

  test('server address is normalised', () {
    expect(Api.normalize('192.168.1.20'), 'http://192.168.1.20:9001');
    expect(Api.normalize('192.168.1.20:8000/'), 'http://192.168.1.20:8000');
    expect(Api.normalize('https://pos.local'), 'https://pos.local:9001');
  });

  test('uuid4 format', () {
    expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(uuid4()), isTrue);
  });

  test('employee permissions come from the server; old data falls back to the fixed roles', () {
    final custom = Employee.fromApi({
      'id': 3,
      'name': 'سعاد',
      'role': 'r1a2b3c4',
      'role_name': 'مراجعة جرد',
      'permissions': ['count', 'price'],
      'pin_salt': 's',
      'pin_hash': 'h',
      'active': true,
    });
    expect(custom.can('count'), isTrue);
    expect(custom.can('sale'), isFalse);
    expect(custom.can('see_cost'), isFalse);
    expect(custom.roleName, 'مراجعة جرد');
    final back = Employee.fromRow(custom.toRow());
    expect(back.permissions, {'count', 'price'});
    expect(back.roleName, 'مراجعة جرد');

    final none = Employee.fromRow(
      Employee.fromApi({'id': 4, 'name': 'x', 'role': 'r9', 'permissions': <String>[], 'pin_salt': 's', 'pin_hash': 'h', 'active': true})
          .toRow(),
    );
    expect(none.permissions, isEmpty, reason: 'a role with nothing ticked stays empty, not the defaults');
    expect(none.can('price'), isFalse);

    final old = Employee.fromApi({'id': 5, 'name': 'y', 'role': 'storekeeper', 'pin_salt': 's', 'pin_hash': 'h', 'active': true});
    expect(old.can('count'), isTrue);
    expect(old.can('sale'), isFalse);
  });

  test('Kuwaiti dinar: fils exact, line totals round half up like the server', () {
    expect(money(28296), '28.296');
    expect(parseMilli('28.296'), 28296);
    expect(lineTotal(350, 1250), 438, reason: '0.350 x 1.250 kg = 0.4375 -> 0.438');
    expect(lineTotal(68, 24000), 1632);
    expect(money(-5), '-0.005');
  });
}
