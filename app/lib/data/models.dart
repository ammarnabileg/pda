import '../util/format.dart';

class Product {
  final int id;
  final String barcode;
  final String name;
  final String unit; // piece | kg
  final int price; // fils per piece or per kg
  final int cost; // purchase price, fils per piece or per kg
  final int carton; // pieces per carton, 0 = none
  final int stock; // thousandths of the base unit
  final bool active;
  final String pieceName; // what one piece is called: حبة, علبة, كيس ... (set in the dashboard)
  final String? code; // product number (رقم الصنف), can be typed instead of a barcode

  const Product({
    required this.id,
    required this.barcode,
    required this.name,
    required this.unit,
    required this.price,
    this.cost = 0,
    required this.carton,
    required this.stock,
    required this.active,
    this.pieceName = 'حبة',
    this.code,
  });

  /// كرتون / كجم / this product's piece name.
  String unitName(String mode) => mode == 'piece' ? pieceName : unitNames[mode]!;
  String qtyOf(int milli, String mode) => qtyText(milli, mode, pieceName);

  bool get isKg => unit == 'kg';
  List<String> get modes => isKg ? ['kg'] : (carton > 0 ? ['piece', 'carton'] : ['piece']);
  int unitPrice(String mode) => mode == 'carton' ? price * carton : price;
  int unitCost(String mode) => mode == 'carton' ? cost * carton : cost;

  /// Quantity in a mode (thousandths) -> base unit thousandths.
  int toBase(int qtyMilli, String mode) => mode == 'carton' ? qtyMilli * carton : qtyMilli;

  String baseText(int milli) {
    if (isKg) return '${money(milli)} كجم';
    final pieces = milli ~/ 1000;
    var t = '${qty(milli, 'piece')} $pieceName';
    if (carton > 0 && milli % 1000 == 0 && pieces.abs() >= carton) {
      final c = pieces.abs() ~/ carton, r = pieces.abs() % carton;
      t += ' ($c كرتون${r > 0 ? ' و $r $pieceName' : ''})';
    }
    return t;
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'barcode': barcode,
    'name': name,
    'unit': unit,
    'price': price,
    'cost': cost,
    'carton': carton,
    'stock': stock,
    'active': active ? 1 : 0,
    'piece_name': pieceName,
    'code': code,
  };

  factory Product.fromRow(Map<String, Object?> r) => Product(
    id: r['id'] as int,
    barcode: r['barcode'] as String,
    name: r['name'] as String,
    unit: r['unit'] as String,
    price: r['price'] as int,
    cost: (r['cost'] as int?) ?? 0,
    carton: r['carton'] as int,
    stock: r['stock'] as int,
    active: (r['active'] as int) == 1,
    pieceName: (r['piece_name'] as String?) ?? 'حبة',
    code: r['code'] as String?,
  );

  factory Product.fromApi(Map<String, dynamic> j) => Product(
    id: j['id'] as int,
    barcode: j['barcode'] as String,
    name: j['name'] as String,
    unit: j['unit'] as String,
    price: parseMilli(j['price'].toString()) ?? 0,
    cost: parseMilli((j['cost'] ?? '0').toString()) ?? 0,
    carton: j['carton'] as int,
    stock: parseMilli(j['stock'].toString()) ?? 0,
    active: j['active'] as bool,
    pieceName: (j['piece_name'] as String?) ?? 'حبة',
    code: j['code'] as String?,
  );
}

/// A product found by a barcode, with the unit that barcode stands for
/// (a carton barcode gives "carton"). [mode] is null when picked by name.
class ScanHit {
  final Product product;
  final String? mode;
  const ScanHit(this.product, [this.mode]);
}

class Employee {
  final int id;
  final String name;
  final String role; // role key; roles and their permissions are set in the dashboard
  final String? roleLabel;
  final String pinSalt;
  final String pinHash;
  final bool active;

  /// Null only for data from a server older than editable roles; then [defaultPermissions] applies.
  final Set<String>? permissions;

  const Employee({
    required this.id,
    required this.name,
    required this.role,
    required this.pinSalt,
    required this.pinHash,
    required this.active,
    this.roleLabel,
    this.permissions,
  });

  /// The starting roles, used until the server sends real permissions.
  static const defaultPermissions = {
    'cashier': {'sale', 'price', 'see_cost'},
    'storekeeper': {'price', 'see_cost', 'count', 'receive', 'new_receipt'},
    'supervisor': {'sale', 'price', 'see_cost', 'count', 'receive', 'new_receipt', 'device_admin'},
    'admin': {'sale', 'price', 'see_cost', 'count', 'receive', 'new_receipt', 'device_admin'},
  };
  static const defaultNames = {'cashier': 'كاشير', 'storekeeper': 'أمين مخزن', 'supervisor': 'مشرف', 'admin': 'مدير'};

  bool can(String perm) => (permissions ?? defaultPermissions[role] ?? const <String>{}).contains(perm);
  String get roleName => roleLabel ?? defaultNames[role] ?? role;

  Map<String, Object?> toRow() => {
    'id': id,
    'name': name,
    'role': role,
    'role_name': roleLabel,
    'permissions': permissions == null ? null : (permissions!.toList()..sort()).join(','),
    'pin_salt': pinSalt,
    'pin_hash': pinHash,
    'active': active ? 1 : 0,
  };

  factory Employee.fromRow(Map<String, Object?> r) {
    final perms = r['permissions'] as String?;
    return Employee(
      id: r['id'] as int,
      name: r['name'] as String,
      role: r['role'] as String,
      roleLabel: r['role_name'] as String?,
      permissions: perms?.split(',').where((p) => p.isNotEmpty).toSet(),
      pinSalt: r['pin_salt'] as String,
      pinHash: r['pin_hash'] as String,
      active: (r['active'] as int) == 1,
    );
  }

  factory Employee.fromApi(Map<String, dynamic> j) => Employee(
    id: j['id'] as int,
    name: j['name'] as String,
    role: j['role'] as String,
    roleLabel: j['role_name'] as String?,
    permissions: (j['permissions'] as List?)?.cast<String>().toSet(),
    pinSalt: j['pin_salt'] as String,
    pinHash: j['pin_hash'] as String,
    active: j['active'] as bool,
  );
}

class ReceiptLine {
  final int productId;
  final String mode;
  final int ordered; // thousandths in [mode]
  const ReceiptLine(this.productId, this.mode, this.ordered);
}

class ReceiptDoc {
  final int id;
  final String supplier;
  final String status; // open | received | cancelled | sent (sent = confirmed here, upload pending)
  final String note;
  final String createdAt;
  final List<ReceiptLine> lines;

  const ReceiptDoc({
    required this.id,
    required this.supplier,
    required this.status,
    required this.note,
    required this.createdAt,
    required this.lines,
  });
}

/// A line in the current sale.
int _lineSeq = 0;

/// A line in the current sale. The same product can be on several lines.
class SaleLine {
  final String id;
  final int productId;
  String mode;
  int qty; // thousandths
  SaleLine(this.productId, this.mode, this.qty, {String? id}) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_lineSeq++}';

  Map<String, Object?> toJson() => {'i': id, 'p': productId, 'm': mode, 'q': qty};
  factory SaleLine.fromJson(Map<String, dynamic> j) => SaleLine(j['p'] as int, j['m'] as String, j['q'] as int, id: j['i'] as String?);
}

/// A finished sale, received voucher or count kept on this device for its history.
class HistoryEntry {
  final String id;
  final String kind; // sales | receipts | counts
  final DateTime at;
  final Map<String, dynamic> data;
  const HistoryEntry(this.id, this.kind, this.at, this.data);
  String get outboxKey => '$kind:$id';
}
