import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/order_model.dart' show OrderChannel;
import '../../services/invoice_service.dart';

/// 1 hóa đơn đã tính doanh thu (đọc từ collection invoices — cùng nguồn với Kiểm ca).
class _Sale {
  final DateTime? at;
  final double amount;
  final double net;     // tiền quán thực nhận (đơn app: sau chiết khấu app)
  final String channel; // OrderChannel.dineIn | grab | shopee
  final List<({String name, int qty})> items;
  const _Sale(this.at, this.amount, this.net, this.channel, this.items);

  static _Sale fromInvoice(Map<String, dynamic> inv) {
    final ts = inv['createdAt'];
    final items = <({String name, int qty})>[];
    for (final raw in (inv['items'] as List<dynamic>? ?? [])) {
      if (raw is! Map) continue;
      final n = raw['name'];
      final name = n is Map ? '${n['vi'] ?? n['en'] ?? ''}' : '${n ?? ''}';
      final q = raw['qty'] ?? raw['quantity'];
      items.add((name: name, qty: q is num ? q.toInt() : int.tryParse('$q') ?? 1));
    }
    final amount = double.tryParse('${inv['totalAmount'] ?? 0}') ?? 0;
    return _Sale(
      ts is Timestamp ? ts.toDate() : null,
      amount,
      double.tryParse('${inv['netAmount'] ?? ''}') ?? amount,
      OrderChannel.channelOfInvoice(inv),
      items,
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  final _invoiceService = InvoiceService();
  DateTime _from = DateTime.now().subtract(const Duration(days: 6));
  DateTime _to = DateTime.now();
  List<_Sale>? _orders;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final from = DateTime(_from.year, _from.month, _from.day);
    final to = DateTime(_to.year, _to.month, _to.day + 1);
    // Doanh thu = hóa đơn đã ghi nhận (bỏ bản in lại bị thay thế / bill không tính doanh thu)
    List<_Sale> sales = const [];
    try {
      final invoices = await _invoiceService.getInvoicesByDateRange(from, to);
      sales = invoices
          .where((i) => i['status'] != 'superseded' && i['status'] != 'excluded')
          .map(_Sale.fromInvoice)
          .toList();
    } catch (e) {
      debugPrint('[Reports] load invoices error: $e');
    }
    if (!mounted) return;
    setState(() {
      _orders = sales;
      _loading = false;
    });
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _from, end: _to),
      builder: (context, child) => Theme(
        data: ThemeData.light().copyWith(
          colorScheme: const ColorScheme.light(primary: AppColors.primary),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _from = picked.start;
        _to = picked.end;
      });
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,###', 'vi_VN');
    final dateFmt = DateFormat('dd/MM');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Báo cáo doanh thu'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.date_range, color: Colors.white),
            onPressed: _pickDateRange,
            tooltip: 'Chọn khoảng thời gian',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _orders == null
              ? const SizedBox()
              : _buildContent(fmt, dateFmt),
    );
  }

  Widget _buildContent(NumberFormat fmt, DateFormat dateFmt) {
    final orders = _orders!;
    final totalRevenue = orders.fold(0.0, (s, o) => s + o.amount);

    // Doanh thu theo kênh bán
    const channels = [OrderChannel.dineIn, OrderChannel.grab, OrderChannel.shopee];
    final byChannel = {for (final c in channels) c: (amount: 0.0, net: 0.0, count: 0)};
    for (final o in orders) {
      final cur = byChannel[o.channel] ?? (amount: 0.0, net: 0.0, count: 0);
      byChannel[o.channel] = (amount: cur.amount + o.amount, net: cur.net + o.net, count: cur.count + 1);
    }
    final totalNet = orders.fold(0.0, (s, o) => s + o.net);
    final avgOrder = orders.isEmpty ? 0.0 : totalRevenue / orders.length;

    // Group by day
    final Map<String, double> dailyRevenue = {};
    for (var d = _from; !d.isAfter(_to); d = d.add(const Duration(days: 1))) {
      dailyRevenue[dateFmt.format(d)] = 0;
    }
    for (final o in orders) {
      if (o.at != null) {
        final key = dateFmt.format(o.at!);
        dailyRevenue[key] = (dailyRevenue[key] ?? 0) + o.amount;
      }
    }

    // Best selling items
    final Map<String, int> itemCount = {};
    for (final o in orders) {
      for (final item in o.items) {
        itemCount[item.name] = (itemCount[item.name] ?? 0) + item.qty;
      }
    }
    final topItems = itemCount.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return RefreshIndicator(
      onRefresh: _load,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Date range
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border:
                    Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today,
                      size: 16, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    '${DateFormat('dd/MM/yyyy').format(_from)} – ${DateFormat('dd/MM/yyyy').format(_to)}',
                    style: const TextStyle(
                      color: AppColors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _pickDateRange,
                    child: const Text(
                      'Thay đổi',
                      style: TextStyle(
                        color: AppColors.primary,
                        decoration: TextDecoration.underline,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Summary cards
            Row(
              children: [
                Expanded(
                  child: _SummaryCard(
                    title: 'Tổng doanh thu',
                    value: '${fmt.format(totalRevenue)}đ',
                    icon: Icons.attach_money,
                    color: AppColors.success,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SummaryCard(
                    title: 'Số đơn',
                    value: '${orders.length}',
                    icon: Icons.receipt_long,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _SummaryCard(
                    title: 'TB/đơn',
                    value: '${fmt.format(avgOrder)}đ',
                    icon: Icons.trending_up,
                    color: AppColors.info,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Doanh thu theo kênh bán (tại quán / Grab / ShopeeFood)
            const Text(
              'Doanh thu theo kênh',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            Row(children: [
              for (final c in channels) ...[
                if (c != channels.first) const SizedBox(width: 10),
                Expanded(
                  child: _ChannelCard(
                    title: c == OrderChannel.dineIn ? 'Tại quán / mang về' : c == OrderChannel.grab ? 'Grab' : 'ShopeeFood',
                    amount: byChannel[c]!.amount,
                    net: byChannel[c]!.net,
                    count: byChannel[c]!.count,
                    share: totalRevenue > 0 ? byChannel[c]!.amount / totalRevenue : 0,
                    color: c == OrderChannel.dineIn
                        ? AppColors.primary
                        : c == OrderChannel.grab ? const Color(0xFF00B14F) : const Color(0xFFEE4D2D),
                    fmt: fmt,
                  ),
                ),
              ],
            ]),
            const SizedBox(height: 6),
            Text(
              totalNet < totalRevenue
                  ? 'Quán thực nhận sau chiết khấu app: ${fmt.format(totalNet)}đ '
                      '(app giữ ${fmt.format(totalRevenue - totalNet)}đ).'
                  : 'Chưa có chiết khấu app nào được ghi — cài % chiết khấu ở POS (nút Giá & chiết khấu app).',
              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 24),

            // Daily chart (simple bar)
            const Text(
              'Doanh thu theo ngày',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            _DailyBarChart(dailyRevenue: dailyRevenue, fmt: fmt),
            const SizedBox(height: 24),

            // Top items
            const Text(
              'Top món bán chạy',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 12),
            if (topItems.isEmpty)
              const Text('Chưa có dữ liệu',
                  style: TextStyle(color: AppColors.textSecondary))
            else
              ...topItems.take(10).map((e) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                        Expanded(child: Text(e.key)),
                        Text(
                          '${e.value} ly',
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  )),
          ],
        ),
      ),
    );
  }
}

class _ChannelCard extends StatelessWidget {
  final String title;
  final double amount;
  final double net;
  final int count;
  final double share; // 0..1
  final Color color;
  final NumberFormat fmt;

  const _ChannelCard({
    required this.title,
    required this.amount,
    required this.net,
    required this.count,
    required this.share,
    required this.color,
    required this.fmt,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 8),
          Text('${fmt.format(amount)}đ',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: color)),
          Text('$count đơn · ${(share * 100).toStringAsFixed(0)}%',
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
          if (net < amount)
            Text('Thực nhận ≈ ${fmt.format(net)}đ',
                style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: share.clamp(0.0, 1.0).toDouble(),
              minHeight: 6,
              color: color,
              backgroundColor: color.withValues(alpha: 0.12),
            ),
          ),
        ]),
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
                color: color,
              ),
            ),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DailyBarChart extends StatelessWidget {
  final Map<String, double> dailyRevenue;
  final NumberFormat fmt;

  const _DailyBarChart({required this.dailyRevenue, required this.fmt});

  @override
  Widget build(BuildContext context) {
    if (dailyRevenue.isEmpty) return const SizedBox();
    final maxVal = dailyRevenue.values.fold(0.0, (a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          height: 160,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: dailyRevenue.entries.map((e) {
              final ratio = maxVal > 0 ? e.value / maxVal : 0.0;
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (e.value > 0)
                        Text(
                          '${(e.value / 1000).toStringAsFixed(0)}k',
                          style: const TextStyle(
                            fontSize: 9,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      const SizedBox(height: 2),
                      Flexible(
                        child: FractionallySizedBox(
                          heightFactor: ratio.clamp(0.05, 1.0),
                          child: Container(
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        e.key,
                        style: const TextStyle(
                          fontSize: 9,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
