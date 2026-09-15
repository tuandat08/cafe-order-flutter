import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../models/table_model.dart';
import '../../services/table_service.dart';

class TablesScreen extends StatelessWidget {
  const TablesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final tableService = TableService();

    void openForm([TableModel? table]) {
      final idCtrl = TextEditingController(text: table?.id);
      final nameCtrl = TextEditingController(text: table?.name);
      final capacityCtrl =
          TextEditingController(text: table?.capacity.toString() ?? '4');

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => Padding(
          padding: EdgeInsets.fromLTRB(
            16, 16, 16, MediaQuery.of(ctx).viewInsets.bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                table == null ? 'Thêm bàn mới' : 'Chỉnh sửa bàn',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: idCtrl,
                      decoration: const InputDecoration(labelText: 'Số bàn / ID'),
                      readOnly: table != null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: capacityCtrl,
                      decoration: const InputDecoration(labelText: 'Sức chứa'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên bàn (tuỳ chọn)'),
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () async {
                  final id = idCtrl.text.trim();
                  if (id.isEmpty) return;
                  final t = TableModel(
                    id: id,
                    name: nameCtrl.text.trim().isNotEmpty
                        ? nameCtrl.text.trim()
                        : 'Bàn $id',
                    capacity:
                        int.tryParse(capacityCtrl.text.trim()) ?? 4,
                    status: table?.status ?? 'available',
                  );
                  await tableService.saveTable(t);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                child: Text(table == null ? 'Thêm bàn' : 'Lưu thay đổi'),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quản lý Bàn'),
        automaticallyImplyLeading: false,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openForm(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: StreamBuilder<List<TableModel>>(
        stream: tableService.streamTables(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final tables = snapshot.data!;
          if (tables.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.table_bar_outlined,
                      size: 64, color: AppColors.divider),
                  const SizedBox(height: 12),
                  const Text('Chưa có bàn nào'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => openForm(),
                    child: const Text('Thêm bàn đầu tiên'),
                  ),
                ],
              ),
            );
          }

          return GridView.builder(
            padding: const EdgeInsets.all(16),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 1,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: tables.length,
            itemBuilder: (_, i) {
              final t = tables[i];
              return _TableCard(
                table: t,
                onEdit: () => openForm(t),
                onDelete: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Xóa bàn'),
                      content: Text('Xóa "${t.name}"?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(ctx, false),
                          child: const Text('Huỷ'),
                        ),
                        ElevatedButton(
                          onPressed: () => Navigator.pop(ctx, true),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.error,
                          ),
                          child: const Text('Xóa'),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) await tableService.deleteTable(t.id);
                },
                onToggleStatus: () async {
                  final next = t.isAvailable ? 'occupied' : 'available';
                  await tableService.updateStatus(t.id, next);
                },
              );
            },
          );
        },
      ),
    );
  }
}

class _TableCard extends StatelessWidget {
  final TableModel table;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onToggleStatus;

  const _TableCard({
    required this.table,
    required this.onEdit,
    required this.onDelete,
    required this.onToggleStatus,
  });

  Color get _statusColor {
    switch (table.status) {
      case 'occupied': return AppColors.error;
      case 'reserved': return AppColors.warning;
      default: return AppColors.success;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onToggleStatus,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Sửa')),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Xóa', style: TextStyle(color: AppColors.error)),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'edit') onEdit();
                      if (v == 'delete') onDelete();
                    },
                  ),
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: _statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Icon(
                Icons.table_bar,
                size: 40,
                color: table.isAvailable
                    ? AppColors.primary
                    : AppColors.textSecondary,
              ),
              const SizedBox(height: 8),
              Text(
                table.name,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                ),
              ),
              Text(
                table.statusLabel,
                style: TextStyle(
                  color: _statusColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              Text(
                '${table.capacity} chỗ',
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
