import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/order_model.dart';

class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: _DashboardBody(),
    );
  }
}

class _DashboardBody extends StatelessWidget {
  final _now = DateTime.now();

  _DashboardBody();

  @override
  Widget build(BuildContext context) {
    final since = Timestamp.fromDate(
      DateTime(_now.year, _now.month, _now.day),
    );

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('orders')
          .where('createdAt', isGreaterThan: since)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline_rounded, size: 48, color: AppColors.error),
                const SizedBox(height: 12),
                Text('Lỗi tải dữ liệu', style: TextStyle(color: AppColors.error, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('${snapshot.error}', style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          );
        }

        final orders = snapshot.hasData
            ? snapshot.data!.docs
                .map((d) {
                  try { return OrderModel.fromDoc(d); } catch (_) { return null; }
                })
                .whereType<OrderModel>()
                .toList()
            : <OrderModel>[];

        final paidOrders = orders.where((o) => o.status == 'paid').toList();
        final activeOrders = orders.where((o) =>
          o.status != 'paid' && o.status != 'cancelled').toList();
        final totalRevenue = paidOrders.fold<double>(0, (s, o) => s + o.totalPrice);
        final currency = NumberFormat.currency(locale: 'vi_VN', symbol: '₫');

        return RefreshIndicator(
          onRefresh: () async {},
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  child: _DayHeader(now: _now, totalRevenue: totalRevenue, currency: currency),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
                  child: _StatsRow(
                    revenue: totalRevenue,
                    paidCount: paidOrders.length,
                    activeCount: activeOrders.length,
                    totalCount: orders.length,
                    currency: currency,
                    isLoading: snapshot.connectionState == ConnectionState.waiting,
                  ),
                ),
              ),
              if (activeOrders.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 28, 24, 12),
                    child: Row(
                      children: [
                        Text('Đơn đang xử lý',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                        const SizedBox(width: 8),
                        _Badge(count: activeOrders.length),
                      ],
                    ),
                  ),
                ),
                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) => Padding(
                      padding: EdgeInsets.fromLTRB(24, 0, 24, i == activeOrders.length - 1 ? 24 : 8),
                      child: _OrderCard(order: activeOrders[i], currency: currency),
                    ),
                    childCount: activeOrders.length,
                  ),
                ),
              ] else ...[
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 80,
                          height: 80,
                          decoration: BoxDecoration(
                            color: AppColors.surfaceVariant,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.coffee_rounded, size: 38, color: AppColors.primary.withValues(alpha: 0.5)),
                        ),
                        const SizedBox(height: 16),
                        Text('Không có đơn đang xử lý',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        const SizedBox(height: 4),
                        Text('Các đơn mới sẽ hiển thị ở đây',
                          style: TextStyle(fontSize: 13, color: AppColors.textHint)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class _DayHeader extends StatelessWidget {
  final DateTime now;
  final double totalRevenue;
  final NumberFormat currency;
  const _DayHeader({required this.now, required this.totalRevenue, required this.currency});

  @override
  Widget build(BuildContext context) {
    final greeting = now.hour < 12 ? 'Chào buổi sáng' : now.hour < 17 ? 'Chào buổi chiều' : 'Chào buổi tối';
    final dateStr = DateFormat('EEEE, dd/MM/yyyy', 'vi').format(now);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$greeting! 👋',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              const SizedBox(height: 4),
              Text(dateStr,
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ],
          ),
        ),
        // Live revenue pill
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.trending_up_rounded, size: 16, color: Colors.white),
              const SizedBox(width: 6),
              Text(currency.format(totalRevenue),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatsRow extends StatelessWidget {
  final double revenue;
  final int paidCount, activeCount, totalCount;
  final NumberFormat currency;
  final bool isLoading;

  const _StatsRow({
    required this.revenue, required this.paidCount, required this.activeCount,
    required this.totalCount, required this.currency, required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (ctx, constraints) {
      final isWide = constraints.maxWidth > 600;
      final stats = [
        _StatData(
          label: 'Doanh thu hôm nay',
          value: currency.format(revenue),
          icon: Icons.payments_rounded,
          color: AppColors.primary,
          bg: AppColors.primarySurface,
        ),
        _StatData(
          label: 'Đơn đã thanh toán',
          value: '$paidCount',
          icon: Icons.check_circle_outline_rounded,
          color: AppColors.success,
          bg: const Color(0xFFECFDF5),
        ),
        _StatData(
          label: 'Đang xử lý',
          value: '$activeCount',
          icon: Icons.pending_actions_rounded,
          color: AppColors.warning,
          bg: const Color(0xFFFFFBEB),
        ),
        _StatData(
          label: 'Tổng đơn hôm nay',
          value: '$totalCount',
          icon: Icons.receipt_long_rounded,
          color: AppColors.info,
          bg: const Color(0xFFEFF6FF),
        ),
      ];

      if (isWide) {
        return Row(
          children: stats.map((s) => Expanded(
            child: Padding(
              padding: EdgeInsets.only(right: s == stats.last ? 0 : 12),
              child: _StatCard(data: s, isLoading: isLoading),
            ),
          )).toList(),
        );
      } else {
        return GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          childAspectRatio: 1.5,
          children: stats.map((s) => _StatCard(data: s, isLoading: isLoading)).toList(),
        );
      }
    });
  }
}

class _StatData {
  final String label, value;
  final IconData icon;
  final Color color, bg;
  const _StatData({required this.label, required this.value, required this.icon, required this.color, required this.bg});
}

class _StatCard extends StatelessWidget {
  final _StatData data;
  final bool isLoading;
  const _StatCard({required this.data, required this.isLoading});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEDE8E3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: data.bg,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(data.icon, size: 18, color: data.color),
              ),
              const Spacer(),
            ],
          ),
          const SizedBox(height: 12),
          if (isLoading)
            Container(height: 22, width: 80, decoration: BoxDecoration(
              color: AppColors.surfaceVariant, borderRadius: BorderRadius.circular(4)))
          else
            Text(data.value,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
          const SizedBox(height: 3),
          Text(data.label,
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w400)),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  final int count;
  const _Badge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.primary,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text('$count', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
    );
  }
}

class _OrderCard extends StatelessWidget {
  final OrderModel order;
  final NumberFormat currency;
  const _OrderCard({required this.order, required this.currency});

  static const _statusConfig = {
    'pending':   ('Chờ xác nhận', AppColors.statusPending),
    'confirmed': ('Đã xác nhận', AppColors.statusPreparing),
    'preparing': ('Đang pha chế', AppColors.statusPreparing),
    'ready':     ('Sẵn sàng', AppColors.statusReady),
    'served':    ('Đã phục vụ', AppColors.statusServed),
    'paid':      ('Đã thanh toán', AppColors.statusPaid),
    'cancelled': ('Đã huỷ', AppColors.statusCancelled),
  };

  @override
  Widget build(BuildContext context) {
    final cfg = _statusConfig[order.status] ?? ('Không rõ', AppColors.textHint);
    final label = cfg.$1;
    final color = cfg.$2;
    final timeStr = order.createdAt != null
        ? DateFormat('HH:mm').format(order.createdAt!)
        : '--:--';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEDE8E3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppColors.primarySurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Center(
                  child: Text(
                    'B${order.tableId}',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Đơn #${order.id.substring(0, 6).toUpperCase()}',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
                    Text(timeStr,
                      style: TextStyle(fontSize: 12, color: AppColors.textHint)),
                  ],
                ),
              ),
              _StatusChip(label: label, color: color),
            ],
          ),
          // Items
          if (order.items.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(height: 1),
            const SizedBox(height: 10),
            ...order.items.take(3).map((item) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('${item.quantity}× ${item.name}',
                      style: TextStyle(fontSize: 13, color: AppColors.textPrimary)),
                  ),
                  Text(currency.format(item.price * item.quantity),
                    style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                ],
              ),
            )),
            if (order.items.length > 3)
              Text('+${order.items.length - 3} món khác',
                style: TextStyle(fontSize: 12, color: AppColors.textHint)),
          ],
          // Total
          const SizedBox(height: 10),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Tổng cộng',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              Text(currency.format(order.totalPrice),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.primary)),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const _StatusChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
    );
  }
}
