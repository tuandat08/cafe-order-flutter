import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/theme/app_theme.dart';
import '../../models/menu_item_model.dart';
import '../../services/menu_service.dart';

class MenuScreen extends StatefulWidget {
  const MenuScreen({super.key});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  final _menuService = MenuService();
  String _selectedCategory = 'all';

  void _openForm([MenuItemModel? item]) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _MenuItemForm(
        item: item,
        onSave: (data) async {
          if (item == null) {
            await _menuService.addItem(MenuItemModel(
              id: '',
              name: data['name'],
              price: data['price'],
              category: data['category'],
              imageUrl: data['imageUrl'],
              description: data['description'],
            ));
          } else {
            await _menuService.updateItem(item.id, data);
          }
          if (ctx.mounted) Navigator.pop(ctx);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(

      body: StreamBuilder<List<MenuItemModel>>(
        stream: _menuService.streamMenuItems(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Lỗi: ${snapshot.error}', style: const TextStyle(color: Colors.red)));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snapshot.data!;
          final categories = [
            'all',
            ...items.map((i) => i.category).toSet().toList()..sort()
          ];
          final filtered = _selectedCategory == 'all'
              ? items
              : items.where((i) => i.category == _selectedCategory).toList();

          return Column(
            children: [
              // Category filter
              SizedBox(
                height: 52,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  children: categories.map((cat) {
                    final selected = cat == _selectedCategory;
                    return Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text(cat == 'all' ? 'Tất cả' : cat),
                        selected: selected,
                        onSelected: (_) =>
                            setState(() => _selectedCategory = cat),
                        selectedColor:
                            AppColors.primary.withValues(alpha: 0.15),
                        checkmarkColor: AppColors.primary,
                        labelStyle: TextStyle(
                          color: selected
                              ? AppColors.primary
                              : AppColors.textSecondary,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    );
                  }).toList(),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.restaurant_menu_rounded,
                                size: 64, color: AppColors.divider),
                            const SizedBox(height: 16),
                            Text('Chưa có món nào',
                              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                            const SizedBox(height: 4),
                            Text('Nhấn + để thêm món mới',
                              style: TextStyle(fontSize: 13, color: AppColors.textHint)),
                          ],
                        ),
                      )
                    : GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 300,
                          childAspectRatio: 0.85,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: filtered.length,
                        itemBuilder: (_, i) => _MenuItemCard(
                          item: filtered[i],
                          onEdit: () => _openForm(filtered[i]),
                          onDelete: () => _confirmDelete(filtered[i]),
                          onToggle: (val) =>
                              _menuService.toggleAvailable(filtered[i].id, val),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openForm(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Future<void> _confirmDelete(MenuItemModel item) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xóa món'),
        content: Text('Xóa "${item.name}" khỏi menu?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Huỷ')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.error),
            child: const Text('Xóa'),
          ),
        ],
      ),
    );
    if (confirm == true) await _menuService.deleteItem(item.id);
  }
}

class _MenuItemCard extends StatelessWidget {
  final MenuItemModel item;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final ValueChanged<bool> onToggle;

  const _MenuItemCard({
    required this.item,
    required this.onEdit,
    required this.onDelete,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat('#,###', 'vi_VN');
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFEDE8E3)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                item.imageUrl != null && item.imageUrl!.isNotEmpty
                    ? Image.network(
                        item.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          color: AppColors.background,
                          child: const Icon(Icons.coffee_rounded,
                              size: 48, color: AppColors.divider),
                        ),
                      )
                    : Container(
                        color: AppColors.background,
                        child: const Icon(Icons.coffee_rounded,
                            size: 48, color: AppColors.divider),
                      ),
                if (!item.available)
                  Container(
                    color: Colors.black45,
                    child: const Center(
                      child: Text(
                        'Hết hàng',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                // Actions
                Positioned(
                  top: 4,
                  right: 4,
                  child: Row(
                    children: [
                      _IconAction(
                          icon: Icons.edit_rounded,
                          onTap: onEdit,
                          color: AppColors.info),
                      const SizedBox(width: 4),
                      _IconAction(
                          icon: Icons.delete_rounded,
                          onTap: onDelete,
                          color: AppColors.error),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // Info
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${fmt.format(item.price)}đ',
                        style: const TextStyle(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Switch.adaptive(
                      value: item.available,
                      onChanged: onToggle,
                      activeColor: AppColors.primary,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _IconAction(
      {required this.icon, required this.onTap, required this.color});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

class _MenuItemForm extends StatefulWidget {
  final MenuItemModel? item;
  final Future<void> Function(Map<String, dynamic>) onSave;

  const _MenuItemForm({this.item, required this.onSave});

  @override
  State<_MenuItemForm> createState() => _MenuItemFormState();
}

class _MenuItemFormState extends State<_MenuItemForm> {
  final _formKey = GlobalKey<FormState>();
  late final _nameCtrl = TextEditingController(text: widget.item?.name);
  late final _priceCtrl = TextEditingController(
    text: widget.item?.price.toStringAsFixed(0) ?? '',
  );
  late final _categoryCtrl = TextEditingController(text: widget.item?.category);
  late final _imageCtrl = TextEditingController(text: widget.item?.imageUrl);
  late final _descCtrl = TextEditingController(text: widget.item?.description);
  bool _saving = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _priceCtrl.dispose();
    _categoryCtrl.dispose();
    _imageCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.item == null ? 'Thêm món mới' : 'Chỉnh sửa món',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameCtrl,
                decoration: const InputDecoration(labelText: 'Tên món *'),
                validator: (v) =>
                    v?.trim().isEmpty ?? true ? 'Nhập tên món' : null,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _priceCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Giá (đ) *',
                        prefixText: '₫ ',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        if (v?.trim().isEmpty ?? true) return 'Nhập giá';
                        if (double.tryParse(v!.trim()) == null)
                          return 'Số không hợp lệ';
                        return null;
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _categoryCtrl,
                      decoration:
                          const InputDecoration(labelText: 'Danh mục *'),
                      validator: (v) =>
                          v?.trim().isEmpty ?? true ? 'Nhập danh mục' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _imageCtrl,
                decoration:
                    const InputDecoration(labelText: 'URL ảnh (tuỳ chọn)'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descCtrl,
                decoration:
                    const InputDecoration(labelText: 'Mô tả (tuỳ chọn)'),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _saving
                    ? null
                    : () async {
                        if (!_formKey.currentState!.validate()) return;
                        setState(() => _saving = true);
                        await widget.onSave({
                          'name': _nameCtrl.text.trim(),
                          'price': double.parse(_priceCtrl.text.trim()),
                          'category': _categoryCtrl.text.trim(),
                          'imageUrl': _imageCtrl.text.trim(),
                          'description': _descCtrl.text.trim(),
                          'available': widget.item?.available ?? true,
                        });
                      },
                child: _saving
                    ? const SizedBox(
                        height: 18,
                        width: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(widget.item == null ? 'Thêm món' : 'Lưu thay đổi'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
