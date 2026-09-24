import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/account_model.dart';
import '../providers/auth_provider.dart';
import '../services/auth_service.dart';

/// Yêu cầu QUẢN LÝ (tài khoản admin) duyệt 1 thao tác nhạy cảm.
///
/// - Người đang đăng nhập là admin → coi như tự duyệt, không hỏi lại.
/// - Ngược lại → hiện hộp thoại nhập mật khẩu của 1 tài khoản admin bất kỳ.
///
/// Trả về tài khoản admin đã duyệt, hoặc null nếu bị hủy.
Future<AccountModel?> requestManagerApproval(
  BuildContext context, {
  required String action,
}) async {
  final auth = context.read<AuthProvider>();
  if (auth.isAdmin) return auth.currentUser;
  return showDialog<AccountModel>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ManagerApprovalDialog(action: action),
  );
}

class _ManagerApprovalDialog extends StatefulWidget {
  final String action;
  const _ManagerApprovalDialog({required this.action});

  @override
  State<_ManagerApprovalDialog> createState() => _ManagerApprovalDialogState();
}

class _ManagerApprovalDialogState extends State<_ManagerApprovalDialog> {
  final _ctrl = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final pw = _ctrl.text;
    if (pw.isEmpty || _checking) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    AccountModel? manager;
    try {
      manager = await AuthService().verifyManagerPassword(pw);
    } catch (_) {
      if (mounted) {
        setState(() {
          _checking = false;
          _error = 'Không kiểm tra được, vui lòng thử lại';
        });
      }
      return;
    }
    if (!mounted) return;
    if (manager == null) {
      setState(() {
        _checking = false;
        _error = 'Mật khẩu quản lý không đúng';
      });
      _ctrl.clear();
      return;
    }
    Navigator.pop(context, manager);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Cần quản lý duyệt'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.action,
              style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            obscureText: true,
            autofocus: true,
            enabled: !_checking,
            decoration: InputDecoration(
              labelText: 'Mật khẩu tài khoản quản lý',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.pop(context),
          child: const Text('Hủy'),
        ),
        ElevatedButton(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Duyệt'),
        ),
      ],
    );
  }
}

/// Hỏi lý do (bắt buộc) cho thao tác hủy/bớt món. Trả về null nếu bị hủy.
Future<String?> promptRequiredReason(
  BuildContext context, {
  required String title,
  required String message,
  String hint = 'VD: Khách đổi món, pha sai, khách hủy...',
}) {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setSB) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message,
                style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              maxLines: 2,
              onChanged: (_) => setSB(() {}),
              decoration: InputDecoration(
                hintText: hint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Hủy')),
          ElevatedButton(
            onPressed: ctrl.text.trim().isEmpty
                ? null
                : () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Tiếp tục'),
          ),
        ],
      ),
    ),
  );
}
