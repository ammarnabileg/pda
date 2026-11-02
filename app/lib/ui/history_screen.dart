import 'package:flutter/material.dart';

import '../data/db.dart';
import '../data/models.dart';
import '../util/format.dart';
import 'scope.dart';
import 'widgets.dart';

const _titles = {'sales': 'سجل الفواتير', 'receipts': 'سجل الاستلام', 'counts': 'سجل الجرد'};

String _time(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
String _day(DateTime t) {
  final now = DateTime.now();
  final d = DateTime(t.year, t.month, t.day);
  final today = DateTime(now.year, now.month, now.day);
  if (d == today) return 'النهارده';
  if (d == today.subtract(const Duration(days: 1))) return 'امبارح';
  return '${t.day}/${t.month}/${t.year}';
}

/// What this device did, kept for [LocalDb.historyDays] days, with the real send state.
class HistoryScreen extends StatefulWidget {
  final String kind; // sales | receipts | counts
  const HistoryScreen({super.key, required this.kind});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryEntry>? items;
  bool todayOnly = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  Future<void> _load() async {
    final now = DateTime.now();
    final r = await AppScope.read(context).db.history(widget.kind, since: todayOnly ? DateTime(now.year, now.month, now.day) : null);
    if (mounted) setState(() => items = r);
  }

  @override
  Widget build(BuildContext context) {
    final list = items;
    final salesTotal = widget.kind == 'sales' && list != null
        ? list.fold<int>(0, (a, e) => a + ((e.data['total'] as num?)?.toInt() ?? 0))
        : 0;
    return WorkScaffold(
      title: _titles[widget.kind]!,
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(S.edge),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.kind == 'sales' ? '${list.length} فاتورة · ${money(salesTotal)} ${W.currency}' : '${list.length}',
                        style: T.subStrong,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () {
                        setState(() => todayOnly = !todayOnly);
                        _load();
                      },
                      icon: const Icon(Icons.calendar_today_outlined, size: 18),
                      label: Text(todayOnly ? 'النهارده' : 'آخر ${LocalDb.historyDays} يوم', style: T.label),
                    ),
                  ],
                ),
                const Text('اللي اتعمل على الجهاز ده بس. الكل موجود في لوحة التحكم.', style: T.sub),
                const SizedBox(height: S.s),
                if (list.isEmpty)
                  StateMessage(
                    icon: Icons.history,
                    title: todayOnly ? 'مفيش حاجة النهارده' : 'السجل فاضي',
                    sub: todayOnly ? 'اضغط «النهارده» لعرض الأيام اللي فاتت' : null,
                  ),
                for (final e in list) _row(e),
              ],
            ),
    );
  }

  Widget _row(HistoryEntry e) {
    final d = e.data;
    final lines = (d['lines'] as List?) ?? const [];
    final (String title, String? amount, String details) = switch (e.kind) {
      'sales' => ('فاتورة ${e.id.substring(0, 8)}', money((d['total'] as num).toInt()), '${lines.length} صنف · ${d['employee'] ?? ''}'),
      'new_receipts' => ('${d['supplier']} · من غير سند', null, '${lines.length} صنف · مستني موافقة المشرف'),
      'receipts' => (
        '${d['supplier']} · سند ${e.id}',
        null,
        '${lines.length} صنف · ${(d['diffs'] as num? ?? 0) == 0 ? 'كله مطابق' : 'فروقات في ${d['diffs']} صنف'}',
      ),
      _ => ('جرد ${lines.length} صنف', null, '${d['employee'] ?? ''}'),
    };
    return ItemRow(
      title: title,
      amount: amount,
      details: Text('${_day(e.at)} ${_time(e.at)} · $details'),
      controls: _SendBadge(outboxKey: e.outboxKey),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => _HistoryDetail(entry: e))),
    );
  }
}

/// Small send state for a history row.
class _SendBadge extends StatefulWidget {
  final String outboxKey;
  const _SendBadge({required this.outboxKey});
  @override
  State<_SendBadge> createState() => _SendBadgeState();
}

class _SendBadgeState extends State<_SendBadge> {
  String state = 'waiting';
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    () async {
      final rejected = (await app.db.rejectedOutbox()).any((r) => r['id'] == widget.outboxKey);
      final waiting = await app.db.inOutbox(widget.outboxKey);
      final s = rejected ? 'rejected' : (waiting ? 'waiting' : 'sent');
      if (mounted && s != state) setState(() => state = s);
    }();
  }

  @override
  Widget build(BuildContext context) => switch (state) {
    'sent' => const Pill('اتبعت', fg: cGreen, bg: cGreen2, icon: Icons.cloud_done_outlined),
    'rejected' => const Pill('مرفوض', fg: cRed, bg: cRed2, icon: Icons.error_outline),
    _ => const Pill('على الجهاز', fg: cOrange, bg: cOrange2, icon: Icons.save_outlined),
  };
}

class _HistoryDetail extends StatelessWidget {
  final HistoryEntry entry;
  const _HistoryDetail({required this.entry});

  @override
  Widget build(BuildContext context) {
    final d = entry.data;
    final lines = ((d['lines'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final title = switch (entry.kind) {
      'sales' => 'فاتورة ${entry.id.substring(0, 8)}',
      'receipts' => 'سند ${entry.id}',
      'new_receipts' => 'استلام من غير سند',
      _ => 'جرد',
    };
    return WorkScaffold(
      title: title,
      body: ListView(
        padding: const EdgeInsets.all(S.edge),
        children: [
          CardBox(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (entry.kind == 'receipts' || entry.kind == 'new_receipts') Text('${d['supplier']}', style: T.item),
                Text('${_day(entry.at)} ${_time(entry.at)}${d['employee'] != null ? ' · ${d['employee']}' : ''}', style: T.sub),
                if (entry.kind == 'sales') Text('${money((d['total'] as num).toInt())} ${W.currency}', style: T.total),
                if ((d['notes'] as String?)?.isNotEmpty == true) Text('ملاحظات: ${d['notes']}', style: T.sub),
                const SizedBox(height: S.s),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: SendStatus(outboxKey: entry.outboxKey),
                ),
              ],
            ),
          ),
          for (final l in lines)
            switch (entry.kind) {
              'sales' => ItemRow(
                title: '${l['name']}',
                amount: money((l['total'] as num).toInt()),
                details: Text('${money((l['price'] as num).toInt())} × ${qtyText((l['qty'] as num).toInt(), l['mode'] as String)}'),
              ),
              'receipts' || 'new_receipts' => ItemRow(
                title: '${l['name']}',
                badge: Pill(
                  '${l['status']}',
                  fg: l['status'] == 'مطابق' ? cGreen : cOrange,
                  bg: l['status'] == 'مطابق' ? cGreen2 : cOrange2,
                ),
                details: Text(
                  [
                    if (l['ordered'] != null) 'مطلوب ${l['ordered']}',
                    'مستلم ${l['received']}',
                    if ((l['note'] as String?)?.isNotEmpty == true) 'ملاحظة: ${l['note']}',
                  ].join(' · '),
                ),
              ),
              _ => ItemRow(title: '${l['name']}', details: Text('المعدود: ${l['counted']}')),
            },
        ],
      ),
    );
  }
}
