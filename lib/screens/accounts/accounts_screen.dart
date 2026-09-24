import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../models/account_model.dart';
import '../../services/auth_service.dart';

class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final authService = AuthService();

    void openForm([AccountModel? acc]) {
      final usernameCtrl = TextEditingController(text: acc?.username);
      final nameCtrl = TextEditingController(text: acc?.fullName);
      final passCtrl = TextEditingController();
      String role = acc?.role ?? 'staff';
      bool active = acc?.active ?? true;

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSt) => Padding(
            padding: EdgeInsets.fromLTRB(
              16,
              16,
              16,
              MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    acc == null ? 'Thêm tài khoản' : 'Chỉnh sửa tài khoản',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: usernameCtrl,
                    decoration:
                        const InputDecoration(labelText: 'Tên đăng nhập *'),
                    readOnly: acc != null,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: nameCtrl,
                    decoration: const InputDecoration(labelText: 'Họ tên *'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: passCtrl,
                    decoration: InputDecoration(
                      labelText: acc == null
                          ? 'Mật khẩu *'
                          : 'Mật khẩu mới (để trống = giữ nguyên)',
                    ),
                    obscureText: true,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: role,
                    decoration: const InputDecoration(labelText: 'Vai trò'),
                    items: const [
                      DropdownMenuItem(value: 'admin', child: Text('Quản lý')),
                      DropdownMenuItem(
                          value: 'staff', child: Text('Nhân viên')),
                      DropdownMenuItem(value: 'kitchen', child: Text('Bếp')),
                    ],
                    onChanged: (v) => setSt(() => role = v ?? 'staff'),
                  ),
                  const SizedBox(height: 4),
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
                      final username = usernameCtrl.text.trim();
                      final name = nameCtrl.text.trim();
                      if (username.isEmpty || name.isEmpty) return;

                      if (acc == null) {
                        // Create new
                        if (passCtrl.text.isEmpty) return;
                        try {
                          await authService.createAccount(
                            username: username,
                            password: passCtrl.text,
                            fullName: name,
                            role: role,
                          );
                        } catch (e) {
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                              content: Text(e is AuthApiException ? e.message : 'Tạo tài khoản thất bại: $e'),
                              backgroundColor: Colors.red,
                            ));
                          }
                          return;
                        }
                      } else {
                        // Update existing
                        await authService.updateAccount(acc.id, {
                          'fullName': name,
                          'role': role,
                          'active': active,
                        });
                        if (passCtrl.text.isNotEmpty) {
                          await authService.updatePassword(
                              acc.id, passCtrl.text);
                        }
                      }
                      if (ctx.mounted) Navigator.pop(ctx);
                    },
                    child: Text(acc == null ? 'Tạo tài khoản' : 'Lưu thay đổi'),
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
        title: const Text('Quản lý tài khoản'),
        automaticallyImplyLeading: false,
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openForm(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.person_add, color: Colors.white),
      ),
      body: StreamBuilder<List<AccountModel>>(
        stream: authService.streamAccounts(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final accounts = snapshot.data!;

          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: accounts.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              final a = accounts[i];
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: _roleColor(a.role).withValues(alpha: 0.15),
                    child: Text(
                      (a.fullName.isNotEmpty ? a.fullName : 'A')[0]
                          .toUpperCase(),
                      style: TextStyle(
                        color: _roleColor(a.role),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    a.fullName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Row(
                    children: [
                      Text('@${a.username}'),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: _roleColor(a.role).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          a.roleLabel,
                          style: TextStyle(
                            color: _roleColor(a.role),
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: a.active ? AppColors.success : AppColors.error,
                          shape: BoxShape.circle,
                        ),
                      ),
                      PopupMenuButton<String>(
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                              value: 'edit', child: Text('Sửa')),
                          PopupMenuItem(
                            value: 'toggle',
                            child: Text(a.active ? 'Vô hiệu hóa' : 'Kích hoạt'),
                          ),
                        ],
                        onSelected: (v) {
                          if (v == 'edit') openForm(a);
                          if (v == 'toggle') {
                            authService
                                .updateAccount(a.id, {'active': !a.active});
                          }
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

  Color _roleColor(String role) {
    switch (role) {
      case 'admin':
        return AppColors.primary;
      case 'kitchen':
        return AppColors.info;
      default:
        return AppColors.accent;
    }
  }
}
