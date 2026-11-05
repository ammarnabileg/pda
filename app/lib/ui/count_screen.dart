import 'package:flutter/material.dart';

import '../data/models.dart';
import '../util/format.dart';
import '../util/ids.dart';
import 'scan_helpers.dart';
import 'scope.dart';
import 'widgets.dart';

int _seq = 0;

/// One counted entry. The same product can have several (e.g. two shelves);
/// they are added together per product when the count is sent.
class _CountLine {
  final String id;
  final int productId;
  int base; // thousandths of the base unit
  int scans; // how many times it was counted (added to)
  _CountLine(this.productId, this.base, [this.scans = 1, String? id]) : id = id ?? '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
}

enum _Sort { recent, name }

/// Blind count: staff see what they counted, not what the system expects.
/// Differences are reviewed and approved by a supervisor in the dashboard.
class CountScreen extends StatefulWidget {
  const CountScreen({super.key});
  @override
  State<CountScreen> createState() => _CountScreenState();
}

class _CountScreenState extends State<CountScreen> {
  final lines = <_CountLine>[];
  final products = <int, Product>{};
  String? id, startedAt;
  // The stocktake this count belongs to: same date on several devices = one stocktake, one committee per device.
  String? countDate, committee;
  bool loaded = false;
  String? lastId;
  String? lastNote;
  String filter = '';
  _Sort sort = _Sort.recent;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = AppScope.read(context).db;
    final d = await db.getJson('draft_count');
    if (d is Map) {
      id = d['id'] as String?;
      startedAt = d['started_at'] as String?;
      countDate = d['count_date'] as String?;
      committee = d['committee'] as String?;
      for (final j in d['lines'] as List) {
        lines.add(_CountLine(j['p'] as int, j['b'] as int, (j['n'] as int?) ?? 1, j['i'] as String?));
      }
    }
    products.addAll(await db.productsByIds(lines.map((l) => l.productId)));
    lines.removeWhere((l) => !products.containsKey(l.productId));
    if (mounted) setState(() => loaded = true);
    if (committee == null && mounted) await _askHeader();
  }

  /// Date and committee number, asked once when a new count starts (and changeable from the header).
  Future<bool> _askHeader() async {
    final r = await showAppSheet<(String, String)>(context, _CountHeaderSheet(date: countDate ?? _today(), committee: committee ?? ''));
    if (r == null || !mounted) return committee != null;
    setState(() {
      countDate = r.$1;
      committee = r.$2;
    });
    await _save();
    return true;
  }

  static String _today() => DateTime.now().toIso8601String().substring(0, 10);

  Future<void> _save() {
    id ??= uuid4();
    startedAt ??= DateTime.now().toUtc().toIso8601String();
    return AppScope.read(context).db.setJson(
      'draft_count',
      lines.isEmpty && committee == null
          ? null
          : {
              'id': id,
              'started_at': startedAt,
              'count_date': countDate,
              'committee': committee,
              'lines': [
                for (final l in lines) {'i': l.id, 'p': l.productId, 'b': l.base, 'n': l.scans},
              ],
            },
    );
  }

  Future<void> _onProduct(ScanHit? h) async {
    if (h == null || !mounted) return;
    if (committee == null && !await _askHeader()) return;
    if (!mounted) return;
    final p = h.product;
    products[p.id] = p;
    var i = lines.lastIndexWhere((l) => l.productId == p.id);
    if (i >= 0) {
      // Already counted: add to that entry, or keep a separate one (another shelf).
      final total = lines.where((l) => l.productId == p.id).fold<int>(0, (a, l) => a + l.base);
      final choice = await showAppSheet<String>(
        context,
        Builder(
          builder: (ctx) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(p.name, style: T.heading),
              const SizedBox(height: S.xs),
              Text('معدود قبل كده: ${p.baseText(total)}', style: T.label),
              const SizedBox(height: S.m),
              BigButton('زوّد على نفس البند', icon: Icons.add, onPressed: () => Navigator.pop(ctx, 'merge')),
              const SizedBox(height: S.s),
              BigButton.light('بند جديد (رف أو مكان تاني)', icon: Icons.playlist_add, onPressed: () => Navigator.pop(ctx, 'new')),
            ],
          ),
        ),
      );
      if (choice == null || !mounted) return;
      if (choice == 'new') i = -1;
    }
    final prev = i >= 0 ? lines[i].base : 0;
    final r = await numberPad(
      context,
      title: p.name,
      pieceName: p.pieceName,
      hint: prev > 0 ? 'معدود قبل كده: ${p.baseText(prev)} — العدد الجديد هيتجمع عليه' : 'اكتب العدد الموجود على الرف',
      modes: p.modes,
      mode: h.mode == 'carton' && p.carton > 0 ? 'carton' : null, // carton barcode: counting cartons
      carton: p.carton,
      preview: prev > 0
          ? (q, m) => 'المجموع هيبقى: ${p.baseText(prev + p.toBase(q, m))}'
          : (q, m) => m == 'carton' ? '= ${p.baseText(p.toBase(q, m))}' : null,
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null || !mounted) return;
    final add = p.toBase(r.qty, r.mode);
    _CountLine line;
    if (i >= 0) {
      line = lines.removeAt(i)
        ..base += add
        ..scans += 1;
    } else {
      line = _CountLine(p.id, add);
    }
    setState(() {
      lines.add(line);
      lastId = line.id;
      lastNote = i >= 0 ? '+${p.baseText(add)}' : null;
      filter = '';
    });
    _save();
  }

  Map<int, int> _perProduct() {
    final m = <int, int>{};
    for (final l in lines) {
      m[l.productId] = (m[l.productId] ?? 0) + l.base;
    }
    return m;
  }

  Future<void> _onScan(String code) async => _onProduct(await findScanned(context, AppScope.read(context), code));

  Future<void> _edit(_CountLine l) async {
    final p = products[l.productId]!;
    final r = await numberPad(
      context,
      title: p.name,
      pieceName: p.pieceName,
      hint: 'العدد الحالي: ${p.baseText(l.base)} — العدد الجديد هيحل محله',
      modes: p.modes,
      mode: p.isKg ? 'kg' : 'piece',
      initial: l.base,
      carton: p.carton,
      preview: (q, m) => 'العدد هيبقى: ${p.baseText(p.toBase(q, m))}',
    );
    if (r?.scanned != null) return _onScan(r!.scanned!);
    if (r == null) return;
    setState(() => l.base = p.toBase(r.qty, r.mode));
    _save();
  }

  void _delete(_CountLine l) {
    final i = lines.indexOf(l);
    setState(() => lines.removeAt(i));
    _save();
    toast(
      context,
      'تم حذف ${products[l.productId]!.name}',
      undo: () {
        if (!mounted) return;
        setState(() => lines.insert(i.clamp(0, lines.length), l));
        _save();
      },
    );
  }

  Future<void> _actions(_CountLine l) async {
    final p = products[l.productId]!;
    final a = await showAppSheet<String>(
      context,
      Builder(
        builder: (ctx) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(p.name, style: T.heading),
            Text('المعدود: ${p.baseText(l.base)}${l.scans > 1 ? ' (على ${l.scans} مرات)' : ''}', style: T.sub),
            const SizedBox(height: S.m),
            BigButton.light('تعديل العدد', icon: Icons.edit_outlined, onPressed: () => Navigator.pop(ctx, 'edit')),
            const SizedBox(height: S.s),
            BigButton.danger('حذف من الجرد', icon: Icons.delete_outline, onPressed: () => Navigator.pop(ctx, 'delete')),
          ],
        ),
      ),
    );
    if (a == 'edit') await _edit(l);
    if (a == 'delete') _delete(l);
  }

  Future<void> _finish() async {
    final ok = await confirmSheet(
      context,
      title: 'إنهاء الجرد؟',
      body: Text('تم عدّ ${_perProduct().length} صنف.\nبعد الإنهاء الجرد بيتقفل، ومش هتقدر تعدّل فيه من الجهاز.'),
      yes: 'نعم، إنهاء',
    );
    if (!ok || !mounted) return;
    final app = AppScope.read(context);
    await _save();
    final countId = id!;
    final no = await app.db.nextSerial('counts');
    await app.db.enqueue('counts', countId, {
      'id': countId,
      'device_no': no,
      'count_date': countDate ?? _today(),
      'committee': committee,
      'employee_id': app.employee?.id,
      'started_at': startedAt,
      'finished_at': DateTime.now().toUtc().toIso8601String(),
      'lines': [
        // One line per product: entries from several shelves are added together.
        for (final e in _perProduct().entries) {'product_id': e.key, 'counted': money(e.value)},
      ],
    });
    final n = _perProduct().length;
    await app.db.addHistory('counts', countId, {
      'no': no,
      'count_date': countDate ?? _today(),
      'committee': committee,
      'employee': app.employee?.name,
      'lines': [
        for (final e in _perProduct().entries) {'name': products[e.key]!.name, 'counted': products[e.key]!.baseText(e.value)},
      ],
    });
    final doneCommittee = committee;
    lines.clear();
    id = null;
    startedAt = null;
    countDate = null;
    committee = null;
    await app.db.set('draft_count', null);
    await app.recordSaved();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => _CountDone(count: n, id: countId, no: no, committee: doneCommittee),
      ),
    );
  }

  Widget _header() => Material(
    color: committee == null ? cOrange2 : cBlue2,
    borderRadius: BorderRadius.circular(S.radius),
    child: InkWell(
      borderRadius: BorderRadius.circular(S.radius),
      onTap: _askHeader,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: S.m, vertical: S.s),
        child: Row(
          children: [
            Icon(Icons.groups_outlined, color: committee == null ? cOrange : cBlue),
            const SizedBox(width: S.s),
            Expanded(
              child: Text(
                committee == null ? 'اكتب رقم اللجنة وتاريخ الجرد' : 'لجنة $committee · جرد يوم ${countDate ?? _today()}',
                style: T.label.copyWith(color: committee == null ? cOrange : cBlue),
              ),
            ),
            Text('تغيير', style: T.label.copyWith(color: committee == null ? cOrange : cBlue)),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = AppScope.read(context);
    Future<void> type() async => _onProduct(await typeAndFind(context, app));
    Future<void> search() async => _onProduct(await searchAndPick(context, app));
    var shown = lines.reversed.where((l) => filter.isEmpty || products[l.productId]!.name.contains(filter)).toList();
    if (sort == _Sort.name) shown.sort((a, b) => products[a.productId]!.name.compareTo(products[b.productId]!.name));
    return WorkScaffold(
      title: 'جرد',
      onScan: _onScan,
      body: !loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                _header(),
                const SizedBox(height: S.s),
                if (lines.isEmpty)
                  ScanPrompt(title: 'امسح أول صنف لبدء الجرد', sub: 'بعدها اكتب العدد الموجود على الرف', onType: type, onSearch: search)
                else ...[
                  ScanBar(text: 'امسح الصنف التالي', onType: type, onSearch: search),
                  Row(
                    children: [
                      Text('${_perProduct().length} صنف معدود', style: T.subStrong),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () => setState(() => sort = sort == _Sort.recent ? _Sort.name : _Sort.recent),
                        icon: const Icon(Icons.swap_vert, size: 20),
                        label: Text(sort == _Sort.recent ? 'الأحدث' : 'بالاسم', style: T.label),
                      ),
                    ],
                  ),
                  const SizedBox(height: S.s),
                  if (lines.length >= 8)
                    Padding(
                      padding: const EdgeInsets.only(bottom: S.s),
                      child: TextField(
                        onChanged: (v) => setState(() => filter = v.trim()),
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => hideKeyboard(),
                        onTapOutside: (_) => hideKeyboard(),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon: const Icon(Icons.search),
                          hintText: 'دوّر في الجرد',
                          filled: true,
                          fillColor: cSurface,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(S.radius),
                            borderSide: const BorderSide(color: cLine),
                          ),
                        ),
                      ),
                    ),
                ],
                for (final l in shown) _row(l),
              ],
            ),
      footer: Footer(
        children: [BigButton('إنهاء الجرد (${_perProduct().length} صنف)', icon: Icons.check, onPressed: lines.isEmpty ? null : _finish)],
      ),
    );
  }

  Widget _row(_CountLine l) {
    final p = products[l.productId]!;
    final isLast = l.id == lastId;
    return ItemRow(
      key: ValueKey(l.id),
      title: p.name,
      highlight: isLast,
      onTap: () => _actions(l),
      badge: isLast && lastNote != null ? Pill('اتضاف $lastNote', fg: cGreen, bg: cSurface, icon: Icons.add) : null,
      details: Text.rich(
        TextSpan(
          children: [
            const TextSpan(text: 'المعدود: '),
            TextSpan(text: p.baseText(l.base), style: T.subStrong),
          ],
        ),
      ),
      controls: IconBox(Icons.edit_outlined, label: 'تعديل العدد', onPressed: () => _edit(l)),
    );
  }
}

class _CountDone extends StatelessWidget {
  final int count, no;
  final String id;
  final String? committee;
  const _CountDone({required this.count, required this.id, required this.no, this.committee});
  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    return WorkScaffold(
      title: 'جرد',
      body: ListView(
        padding: const EdgeInsets.all(S.l),
        children: [
          const SizedBox(height: S.m),
          const CircleAvatar(
            radius: 40,
            backgroundColor: cGreen,
            child: Icon(Icons.check, size: 48, color: Colors.white),
          ),
          const SizedBox(height: S.m),
          const Text('تم حفظ الجرد', textAlign: TextAlign.center, style: T.heading),
          Text('جرد رقم $no${committee != null ? ' · لجنة $committee' : ''}', textAlign: TextAlign.center, style: T.subStrong),
          Text(
            '$count صنف · الساعة ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
            textAlign: TextAlign.center,
            style: T.sub,
          ),
          const SizedBox(height: S.m),
          Center(child: SendStatus(outboxKey: 'counts:$id')),
          const SizedBox(height: S.xs),
          const Text('بعد ما يتبعت، المشرف بيراجعه ويعتمده من لوحة التحكم.', textAlign: TextAlign.center, style: T.sub),
          const SizedBox(height: S.l),
          BigButton.light('الرئيسية', onPressed: () => Navigator.of(context).pop()),
        ],
      ),
    );
  }
}

class _CountHeaderSheet extends StatefulWidget {
  final String date, committee;
  const _CountHeaderSheet({required this.date, required this.committee});
  @override
  State<_CountHeaderSheet> createState() => _CountHeaderSheetState();
}

class _CountHeaderSheetState extends State<_CountHeaderSheet> {
  late final ctl = TextEditingController(text: widget.committee);
  late String date = widget.date;
  String? error;

  @override
  void dispose() {
    ctl.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: DateTime.tryParse(date) ?? now,
      firstDate: now.subtract(const Duration(days: 30)),
      lastDate: now.add(const Duration(days: 7)),
    );
    if (d != null) setState(() => date = d.toIso8601String().substring(0, 10));
  }

  void _ok() {
    final c = ctl.text.trim();
    if (c.isEmpty) {
      setState(() => error = 'رقم اللجنة مطلوب');
      return;
    }
    // A barcode scanned by mistake lands here as a long number.
    if (c.length > 4 || int.tryParse(c) == null) {
      ctl.clear();
      setState(() => error = 'ده شكله باركود. اكتب رقم اللجنة (مثلاً 1 أو 2)');
      return;
    }
    Navigator.pop(context, (date, c));
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('بيانات الجرد', style: T.heading),
      const Text('كل الأجهزة اللي بتجرد في نفس اليوم تكتب نفس التاريخ، وكل جهاز رقم لجنة مختلف.', style: T.sub),
      const SizedBox(height: S.m),
      Row(
        children: [
          const Text('تاريخ الجرد: ', style: T.label),
          Expanded(
            child: Text(date, style: T.subStrong, textDirection: TextDirection.ltr, textAlign: TextAlign.right),
          ),
          TextButton.icon(
            onPressed: _pickDate,
            icon: const Icon(Icons.event),
            label: const Text('تغيير', style: T.label),
          ),
        ],
      ),
      const SizedBox(height: S.s),
      TextField(
        key: const Key('committee'),
        controller: ctl,
        autofocus: true,
        keyboardType: TextInputType.number,
        maxLength: 20,
        style: T.heading,
        textInputAction: TextInputAction.done,
        onTapOutside: (_) => hideKeyboard(),
        onSubmitted: (_) {
          hideKeyboard();
          _ok();
        },
        decoration: InputDecoration(labelText: 'رقم اللجنة', errorText: error, counterText: ''),
      ),
      const SizedBox(height: S.s),
      BigButton('ابدأ الجرد', icon: Icons.play_arrow, onPressed: _ok),
    ],
  );
}
