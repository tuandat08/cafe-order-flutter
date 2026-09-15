import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/discount_model.dart';
import '../../services/discount_service.dart';

class DiscountsScreen extends StatelessWidget {
  const DiscountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final service = DiscountService();

    void openForm([DiscountModel? d]) {
      final codeCtrl = TextEditingController(text: d?.code);
      final valueCtrl = TextEditingController(
          text: d?.value.toStringAsFixed(0) ?? '');
      final maxCtrl = TextEditingController(
          text: d?.maxDiscount.toStringAsFixed(0) ?? '0');
      String type = d?.type ?? 'percent';
      bool active = d?.active ?? true;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSt) => Padding(
            padding: EdgeInsets.fromLTRB(
              16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    d == null ? 'Thêm mã giảm giá' : 'Chỉnh sửa mã',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: codeCtrl,
                    decoration: const InputDecoration(labelText: 'Mã code *'),
                    textCapitalization: TextCapitalization.characters,
                  ),
                  const SizedBox(height: 12),
                  // Type selector
                  Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<String>(
                          segments: const [
                            ButtonSegment(value: 'percent', label: Text('% Phần trăm')),
                            ButtonSegment(value: 'fixed', label: Text('đ Cố định')),
                          ],
                          selected: {type},
                          onSelectionChanged: (s) => setSt(() => type = s.first),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: valueCtrl,
                          decoration: InputDecoration(
                            labelText: type == 'percent' ? 'Giá trị (%)' : 'Giá trị (đ)',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: maxCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Giảm tối đa (đ)',
                            helperText: '0 = không giới hạn',
                          ),
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile.adaptive(
                    title: const Text('Đang hoạt động'),
                    value: active,
                    onChanged: (v) => setSt(() => active = v),
                    activeColor: AppColors.primary,
                    contentPadding: EdgeInsets.zero,
                  ),
                  const SizedBox(height: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final code = codeCtrl.text.trim();
                      if (code.isEmpty) return;
                      final discount = DiscountModel(
                        id: d?.id ?? '',
                        code: code,
                        type: type,
                        value: double.tryParse(valueCtrl.text.trim()) ?? 0,
                        maxDiscount: double.tryParse(maxCtrl.text.trim()) ?? 0,
                        usedCount: d?.usedCount ?? 0,
                        active: active,
                      );
                      await service.save(discount);
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: Text(d == null ? 'Thêm mã' : 'Lưu thay đổi'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Khuyến mãi'),
        automaticallyImplyLeading: false,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openForm(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: StreamBuilder<List<DiscountModel>>(
        stream: service.streamDiscounts(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final discounts = snapshot.data!;
          if (discounts.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.local_offer_outlined, size: 64, color: AppColors.divider),
                  const SizedBox(height: 12),
                  const Text('Chưa có mã giảm giá'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => openForm(),
                    child: const Text('Tạo mã đầu tiên'),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: discounts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final d = discounts[i];
              return Card(
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.local_offer,
                        color: AppColors.accent, size: 20),
                  ),
                  title: Row(
                    children: [
                      Text(
                        d.code,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                          letterSpacing: 1,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          d.typeLabel,
                          style: const TextStyle(
                            color: AppColors.primary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: Text('Đã dùng: ${d.usedCount} lần'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Switch.adaptive(
                        value: d.active,
                        onChanged: (v) => service.toggle(d.id, v),
                        activeColor: AppColors.primary,
                      ),
                      PopupMenuButton<String>(
                        itemBuilder: (_) => [
                          const PopupMenuItem(value: 'edit', child: Text('Sửa')),
                          const PopupMenuItem(
                            value: 'delete',
                            child: Text('Xóa',
                                style: TextStyle(color: AppColors.error)),
                          ),
                        ],
                        onSelected: (v) {
                          if (v == 'edit') openForm(d);
                          if (v == 'delete') service.delete(d.id);
                        },
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
