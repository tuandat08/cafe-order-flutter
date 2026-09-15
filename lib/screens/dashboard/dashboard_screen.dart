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
      appBar: AppBar(
        title: const Text('Dashboard'),
        automaticallyImplyLeading: false,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where(
              'createdAt',
              isGreaterThanOrEqualTo: Timestamp.fromDate(
                DateTime.now().subtract(const Duration(hours: 24)),
              ),
            )
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final orders = snapshot.data!.docs
              .map((d) => OrderModel.fromDoc(d))
              .toList();

          final paid = orders.where((o) => o.status == 'paid').toList();
          final active = orders
              .where((o) => ['pending', 'preparing', 'ready'].contains(o.status))
              .toList();
          final revenue = paid.fold(0.0, (s, o) => s + o.totalPrice);

          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Hôm nay, ${DateFormat('dd/MM/yyyy').format(DateTime.now())}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 16),

                // Stats row
                _StatsGrid(
                  revenue: revenue,
                  paidCount: paid.length,
                  activeCount: active.length,
                  totalCount: orders.length,
                ),
                const SizedBox(height: 24),

                // Active orders
                Text(
                  'Đơn đang xử lý (${active.length})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 12),
                if (active.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Center(
                        child: Column(
                          children: [
                            Icon(Icons.check_circle_outline,
                                color: AppColors.success, size: 48),
                            const SizedBox(height: 8),
                            const Text('Không có đơn nào đang chờ'),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  ...active.take(5).map((o) => _ActiveOrderCard(order: o)),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  final double revenue;
  final int paidCount;
  final int activeCount;
  final int totalCount;

  const _StatsGrid({
    required this.revenue,
    required this.paidCount,
    required this.activeCount,
    required this.totalCount,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,###', 'vi_VN');
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossCount = constraints.maxWidth > 600 ? 4 : 2;
        return GridView.count(
          crossAxisCount: crossCount,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          childAspectRatio: 1.4,
          children: [
            _StatCard(
              title: 'Doanh thu',
              value: '${fmt.format(revenue)}đ',
              icon: Icons.attach_money,
              color: AppColors.success,
            ),
            _StatCard(
              title: 'Đã thanh toán',
              value: '$paidCount đơn',
              icon: Icons.receipt_long,
              color: AppColors.primary,
            ),
            _StatCard(
              title: 'Đang xử lý',
              value: '$activeCount đơn',
              icon: Icons.pending_actions,
              color: AppColors.warning,
            ),
            _StatCard(
              title: 'Tổng đơn hôm nay',
              value: '$totalCount đơn',
              icon: Icons.bar_chart,
              color: AppColors.info,
            ),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.title,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: color.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: color, size: 20),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                Text(
                  title,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActiveOrderCard extends StatelessWidget {
  final OrderModel order;

  const _ActiveOrderCard({required this.order});

  Color _statusColor(String status) {
    switch (status) {
      case 'pending': return AppColors.statusPending;
      case 'preparing': return AppColors.statusPreparing;
      case 'ready': return AppColors.statusReady;
      default: return AppColors.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,###', 'vi_VN');
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppColors.primary.withOpacity(0.1),
          child: Text(
            'B${order.tableId}',
            style: const TextStyle(
              color: AppColors.primary,
              fontWeight: FontWeight.bold,
              fontSize: 12,
            ),
          ),
        ),
        title: Text('${order.items.length} món - ${fmt.format(order.totalPrice)}đ'),
        subtitle: Text(
          order.items.take(2).map((i) => i.name).join(', ') +
              (order.items.length > 2 ? '...' : ''),
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: _statusColor(order.status).withOpacity(0.1),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: _statusColor(order.status).withOpacity(0.4)),
          ),
          child: Text(
            order.statusLabel,
            style: TextStyle(
              color: _statusColor(order.status),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
