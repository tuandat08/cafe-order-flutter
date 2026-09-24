import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/theme/app_theme.dart';
import '../../models/shift_model.dart';
import '../../providers/auth_provider.dart';
import '../../services/shift_service.dart';


final _vndFmt = NumberFormat('#,###', 'vi_VN');

/// Hộp thoại xác nhận lại số tiền trước khi thực sự mở/đóng ca — bắt buộc
/// người dùng bấm "Xác nhận đúng" một lần nữa sau khi xem lại số tiền đã
/// nhập, tránh bấm nhầm/gõ nhầm số tiền dẫn tới sai lệch dữ liệu ca.
Future<bool> _confirmMoneyDialog(
  BuildContext context, {
  required String title,
  required String amountLabel,
  required String amountText,
  Widget? extra,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Vui lòng kiểm tra lại số tiền đã nhập trước khi xác nhận:',
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  amountLabel,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text(
                  amountText,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ),
          if (extra != null) ...[const SizedBox(height: 10), extra],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Kiểm tra lại'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Xác nhận đúng'),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Màn hình "Kiểm ca" — mở ca (ghi nhận tiền mặt đầu ca), theo dõi doanh thu
/// trong ca, và đóng ca (đếm tiền mặt thực tế, đối chiếu với hệ thống) để
/// phát hiện chênh lệch/thất thoát ngay cuối mỗi ca làm việc.
class ShiftScreen extends StatefulWidget {
  // Gọi (true) ngay TRƯỚC khi mở dialog đóng ca do người dùng chủ động bấm
  // "Đóng ca" (không phải luồng bị ép đóng ca khi đăng xuất — luồng đó do
  // MainShell tự xử lý). MainShell dùng cờ này để tạm ẩn cổng "cần mở ca"
  // phản ứng theo stream, tránh nó chớp qua màn hình trong lúc dialog đang mở
  // (vì ngay khi đóng ca xong, Firestore báo hết ca mở gần như tức thì, sớm
  // hơn nhiều so với lúc dialog thật sự đóng lại trên giao diện).
  // Gọi lại (false) nếu người dùng hủy đóng ca giữa chừng.
  final ValueChanged<bool>? onLoggingOutChanged;

  const ShiftScreen({super.key, this.onLoggingOutChanged});

  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  final _shiftService = ShiftService();
  final _fmt = NumberFormat('#,###', 'vi_VN');
  final _dateFmt = DateFormat('HH:mm dd/MM/yyyy');

  // Cache 1 lần — không tạo stream mới mỗi lần build() (vd: khi kéo refresh)
  // để tránh mở/đóng liên tục kết nối Firestore.
  Stream<ShiftModel?>? _openShiftStream;

  @override
  Widget build(BuildContext context) {
    final staff = context.watch<AuthProvider>().currentUser;
    if (staff == null) return const SizedBox();
    final isAdmin = staff.role == 'admin';
    _openShiftStream ??= _shiftService.watchOpenShift(staff.id);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kiểm ca'),
        automaticallyImplyLeading: false,
      ),
      body: StreamBuilder<ShiftModel?>(
        stream: _openShiftStream,
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          final openShift = snap.data;
          return RefreshIndicator(
            onRefresh: () async => setState(() {}),
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (openShift == null)
                    _OpenShiftCard(
                      staffId: staff.id,
                      staffName: staff.fullName,
                      shiftService: _shiftService,
                      fmt: _fmt,
                    )
                  else
                    _OpenShiftStatusCard(
                      shift: openShift,
                      shiftService: _shiftService,
                      fmt: _fmt,
                      dateFmt: _dateFmt,
                      onLoggingOutChanged: widget.onLoggingOutChanged,
                    ),
                  // Chỉ admin mới xem được lịch sử ca đã đóng của mọi nhân viên.
                  if (isAdmin) ...[
                    const SizedBox(height: 24),
                    const Text(
                      'Lịch sử ca đã đóng hôm nay',
                      style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 12),
                    _ShiftHistoryList(
                      shiftService: _shiftService,
                      fmt: _fmt,
                      dateFmt: _dateFmt,
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Chưa có ca mở — form nhập tiền mặt đầu ca.
/// Tự động chèn dấu phẩy ngăn cách hàng nghìn khi gõ số tiền (vd: 150000 -> 150,000).
/// Bàn phím số tùy chỉnh ngay trong app cho các ô nhập tiền — không dùng bàn
/// phím hệ thống của thiết bị (tránh trường hợp bàn phím nổi/floating trên
/// iPad hiện lệch, che nội dung). Tự định dạng dấu phẩy ngăn cách hàng nghìn.
class _MoneyKeypad extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String>? onChanged;

  const _MoneyKeypad({required this.controller, this.onChanged});

  String get _digitsOnly => controller.text.replaceAll(RegExp(r'[^0-9]'), '');

  void _apply(String digitsOnly) {
    final formatted = _formatThousands(digitsOnly);
    controller.value = TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
    onChanged?.call(formatted);
  }

  static String _formatThousands(String digitsOnly) {
    if (digitsOnly.isEmpty) return '';
    final buffer = StringBuffer();
    for (int i = 0; i < digitsOnly.length; i++) {
      final posFromEnd = digitsOnly.length - i;
      buffer.write(digitsOnly[i]);
      if (posFromEnd > 1 && posFromEnd % 3 == 1) {
        buffer.write(',');
      }
    }
    return buffer.toString();
  }

  // Giới hạn số tiền tối đa 100 triệu VNĐ cho các ô nhập ở màn Kiểm ca.
  static const int _maxAmount = 100000000;

  bool _exceedsMax(String candidate) {
    if (candidate.length > 9) return true; // 100,000,000 có 9 chữ số
    final v = int.tryParse(candidate);
    return v != null && v > _maxAmount;
  }

  void _tapDigit(String d) {
    final current = _digitsOnly;
    if (current.isEmpty && d == '0') return; // không cho số 0 đứng đầu
    final candidate = current + d;
    if (_exceedsMax(candidate)) return; // không cho vượt quá 100 triệu
    _apply(candidate);
  }

  void _tap000() {
    final current = _digitsOnly;
    if (current.isEmpty) return; // tránh gõ "000" khi ô đang trống (cũng chặn luôn số 0 đứng đầu)
    final candidate = '${current}000';
    if (_exceedsMax(candidate)) return;
    _apply(candidate);
  }

  void _backspace() {
    final d = _digitsOnly;
    if (d.isEmpty) return;
    _apply(d.substring(0, d.length - 1));
  }

  Widget _key(BuildContext context, {String? label, IconData? icon, required VoidCallback onTap}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Material(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: onTap,
            child: SizedBox(
              height: 48,
              child: Center(
                child: icon != null
                    ? Icon(icon, size: 20, color: AppColors.textPrimary)
                    : Text(
                        label ?? '',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(children: [
          _key(context, label: '1', onTap: () => _tapDigit('1')),
          _key(context, label: '2', onTap: () => _tapDigit('2')),
          _key(context, label: '3', onTap: () => _tapDigit('3')),
        ]),
        Row(children: [
          _key(context, label: '4', onTap: () => _tapDigit('4')),
          _key(context, label: '5', onTap: () => _tapDigit('5')),
          _key(context, label: '6', onTap: () => _tapDigit('6')),
        ]),
        Row(children: [
          _key(context, label: '7', onTap: () => _tapDigit('7')),
          _key(context, label: '8', onTap: () => _tapDigit('8')),
          _key(context, label: '9', onTap: () => _tapDigit('9')),
        ]),
        Row(children: [
          _key(context, label: '000', onTap: _tap000),
          _key(context, label: '0', onTap: () => _tapDigit('0')),
          _key(context, icon: Icons.backspace_outlined, onTap: _backspace),
        ]),
      ],
    );
  }
}

/// Màn hình CHẶN TOÀN BỘ app khi tài khoản (admin/staff) chưa mở ca — hiển
/// thay cho MainShell cho tới khi mở ca xong, để bắt buộc phải "vào ca" trước
/// khi thao tác bất kỳ chức năng nào khác (đơn hàng, menu, báo cáo...).
class OpenShiftGateScreen extends StatefulWidget {
  final String staffId;
  final String staffName;
  final ShiftService shiftService;

  const OpenShiftGateScreen({
    super.key,
    required this.staffId,
    required this.staffName,
    required this.shiftService,
  });

  @override
  State<OpenShiftGateScreen> createState() => _OpenShiftGateScreenState();
}

class _OpenShiftGateScreenState extends State<OpenShiftGateScreen> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final value = double.tryParse(_ctrl.text.replaceAll(',', '').replaceAll('.', '')) ?? 0;
    final confirmed = await _confirmMoneyDialog(
      context,
      title: 'Xác nhận mở ca',
      amountLabel: 'Tiền mặt đầu ca',
      amountText: '${_vndFmt.format(value)}đ',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    await widget.shiftService.openShift(
      staffId: widget.staffId,
      staffName: widget.staffName,
      openingCash: value,
    );
    // Không cần tự tắt _busy / điều hướng ở đây — màn hình này sẽ tự động bị
    // thay thế bởi MainShell ngay khi stream watchOpenShift() nhận ca vừa mở.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.savings_rounded, color: AppColors.primary, size: 40),
                      const SizedBox(height: 12),
                      Text('Chào ${widget.staffName},',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      const Text(
                        'Bạn cần mở ca làm việc trước khi bắt đầu. Hãy đếm và nhập số tiền mặt hiện có trong ngăn kéo.',
                        style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 20),
                      TextField(
                        controller: _ctrl,
                        readOnly: true,
                        showCursor: true,
                        textAlign: TextAlign.right,
                        decoration: const InputDecoration(
                          labelText: 'Tiền mặt đầu ca (VNĐ)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.payments_outlined),
                        ),
                      ),
                      const SizedBox(height: 10),
                      _MoneyKeypad(controller: _ctrl),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _busy ? null : _open,
                          icon: _busy
                              ? const SizedBox(
                                  width: 16, height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.play_arrow_rounded),
                          label: const Text('Mở ca làm việc'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppColors.primary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => context.read<AuthProvider>().logout(),
                          child: const Text(
                            'Hủy',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Cong CHAN bat buoc khi phat hien ca lam viec mo tu mot ngay truoc do
/// (staff da tat app kieu vuot-tat/force-kill ma khong dang xuat hay dong ca,
/// hoac quen dong ca). Vi he dieu hanh khong cho ung dung co hoi chay code
/// khi bi buoc tat nhu vay, cach duy nhat kha thi la chan o lan dang nhap/mo
/// app ke tiep: bat buoc dem va nhap tien mat thuc te de dong ca cu truoc,
/// KHONG cho phep bo qua hay tu dong dong ngam - dam bao so lieu ca luon
/// duoc doi soat thuc te boi con nguoi.
class StaleShiftGateScreen extends StatefulWidget {
  final ShiftModel shift;
  final ShiftService shiftService;
  /// false = ca bỏ dở của NGƯỜI KHÁC (tài khoản đăng nhập trước đó chưa đóng ca).
  final bool isOwnShift;

  const StaleShiftGateScreen({
    super.key,
    required this.shift,
    required this.shiftService,
    this.isOwnShift = true,
  });

  @override
  State<StaleShiftGateScreen> createState() => _StaleShiftGateScreenState();
}

class _StaleShiftGateScreenState extends State<StaleShiftGateScreen> {
  final _countedCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  final _dateFmt = DateFormat('HH:mm dd/MM/yyyy', 'vi_VN');
  bool _loadingExpected = true;
  double _expectedCash = 0;
  bool _busy = false;
  bool _success = false;

  double get _counted =>
      double.tryParse(_countedCtrl.text.replaceAll('.', '').replaceAll(',', '')) ?? 0;
  double get _discrepancy => _counted - _expectedCash;

  @override
  void initState() {
    super.initState();
    _loadExpected();
  }

  Future<void> _loadExpected() async {
    final expected = await widget.shiftService.computeExpectedCash(widget.shift);
    if (!mounted) return;
    setState(() {
      _expectedCash = expected;
      _loadingExpected = false;
    });
  }

  @override
  void dispose() {
    _countedCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _onConfirmPressed() async {
    final diff = _discrepancy;
    final diffColor = diff == 0
        ? AppColors.success
        : (diff > 0 ? AppColors.info : AppColors.error);
    final confirmed = await _confirmMoneyDialog(
      context,
      title: 'Xac nhan dong ca cu',
      amountLabel: 'Tien mat dem duoc thuc te',
      amountText: '${_vndFmt.format(_counted)}đ',
      extra: Text(
        diff == 0
            ? 'Khớp — không chênh lệch'
            : diff > 0
                ? 'Dư ${_vndFmt.format(diff)}đ'
                : 'Thiếu ${_vndFmt.format(diff.abs())}đ',
        style: TextStyle(color: diffColor, fontWeight: FontWeight.bold),
      ),
    );
    if (!confirmed || !mounted) return;
    await _confirm();
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await widget.shiftService.closeShift(
        widget.shift,
        closingCashCounted: _counted,
        note: _noteCtrl.text.trim().isEmpty
            ? 'Tu dong phat hien: ca bi bo do tu phien truoc (thoat app khong dang xuat/dong ca), da bat buoc kiem ca thu cong.'
                '${widget.isOwnShift ? '' : ' Nguoi dong ho: ${context.read<AuthProvider>().currentUser?.fullName ?? ''}.'}'
            : _noteCtrl.text.trim(),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đóng ca thất bại, vui lòng thử lại')),
        );
      }
      return;
    }
    if (mounted) setState(() => _success = true);
    await Future.delayed(const Duration(milliseconds: 900));
    // Khong tu dieu huong - man hinh nay se tu dong bi MainShell thay the
    // (chuyen sang man "can mo ca moi") ngay khi stream watchOpenShift()
    // nhan biet ca cu vua duoc dong.
  }

  @override
  Widget build(BuildContext context) {
    final hasInput = _countedCtrl.text.isNotEmpty;
    final diff = _discrepancy;
    final diffColor = diff == 0
        ? AppColors.success
        : (diff > 0 ? AppColors.info : AppColors.error);

    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: AppColors.error, size: 40),
                      const SizedBox(height: 12),
                      const Text('Phát hiện ca làm việc chưa được đóng',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(
                        '${widget.isOwnShift ? 'Ca của bạn (${widget.shift.staffName})' : 'Ca của ${widget.shift.staffName} (tài khoản đăng nhập trước)'} mở lúc '
                        '${_dateFmt.format(widget.shift.openedAt)} vẫn đang ở trạng thái '
                        'mở — có thể do ứng dụng đã bị thoát trước khi đóng ca. '
                        'Vui lòng đếm và nhập tiền mặt thực tế trong ngăn kéo để đóng ca này trước khi tiếp tục sử dụng ứng dụng.',
                        style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      if (_loadingExpected)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                        )
                      else ...[
                        Text(
                          'Tiền mặt dự kiến trong ngăn kéo: ${_vndFmt.format(_expectedCash)}đ',
                          style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 14),
                        TextField(
                          controller: _countedCtrl,
                          readOnly: true,
                          showCursor: true,
                          textAlign: TextAlign.right,
                          decoration: const InputDecoration(
                            labelText: 'Tiền mặt đếm được thực tế (VNĐ)',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.calculate_outlined),
                          ),
                        ),
                        const SizedBox(height: 10),
                        _MoneyKeypad(
                          controller: _countedCtrl,
                          onChanged: (_) => setState(() {}),
                        ),
                        if (hasInput) ...[
                          const SizedBox(height: 10),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: diffColor.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              diff == 0
                                  ? 'Khớp — không chênh lệch'
                                  : diff > 0
                                      ? 'Dư ${_vndFmt.format(diff)}đ'
                                      : 'Thiếu ${_vndFmt.format(diff.abs())}đ',
                              style: TextStyle(color: diffColor, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                        const SizedBox(height: 10),
                        TextField(
                          controller: _noteCtrl,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Ghi chú (không bắt buộc)',
                            hintText: 'Ví dụ: lý do chênh lệch, lý do thoát app đột ngột...',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: (_busy || !hasInput) ? null : _onConfirmPressed,
                            icon: _success
                                ? const Icon(Icons.check_circle_rounded, color: Colors.white)
                                : (_busy
                                    ? const SizedBox(
                                        width: 16, height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Icon(Icons.lock_open_rounded)),
                            label: Text(_success ? 'Đã đóng ca' : 'Xác nhận đóng ca cũ'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _success ? AppColors.success : AppColors.primary,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(vertical: 14),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => context.read<AuthProvider>().logout(),
                          child: const Text(
                            'Đăng xuất',
                            style: TextStyle(color: AppColors.textSecondary),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenShiftCard extends StatefulWidget {
  final String staffId;
  final String staffName;
  final ShiftService shiftService;
  final NumberFormat fmt;

  const _OpenShiftCard({
    required this.staffId,
    required this.staffName,
    required this.shiftService,
    required this.fmt,
  });

  @override
  State<_OpenShiftCard> createState() => _OpenShiftCardState();
}

class _OpenShiftCardState extends State<_OpenShiftCard> {
  final _ctrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    final value = double.tryParse(_ctrl.text.replaceAll('.', '').replaceAll(',', '')) ?? 0;
    final confirmed = await _confirmMoneyDialog(
      context,
      title: 'Xác nhận mở ca',
      amountLabel: 'Tiền mặt đầu ca',
      amountText: '${_vndFmt.format(value)}đ',
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    await widget.shiftService.openShift(
      staffId: widget.staffId,
      staffName: widget.staffName,
      openingCash: value,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.savings_rounded, color: AppColors.primary),
                SizedBox(width: 8),
                Text('Chưa mở ca làm việc',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Nhập số tiền mặt hiện có trong ngăn kéo trước khi bắt đầu ca.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _ctrl,
              readOnly: true,
              showCursor: true,
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                labelText: 'Tiền mặt đầu ca (VNĐ)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.payments_outlined),
              ),
            ),
            const SizedBox(height: 10),
            _MoneyKeypad(controller: _ctrl),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _busy ? null : _open,
                icon: _busy
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('Mở ca làm việc'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Đang có ca mở — hiển thị tổng quan doanh thu tạm thời + nút đóng ca.
class _OpenShiftStatusCard extends StatefulWidget {
  final ShiftModel shift;
  final ShiftService shiftService;
  final NumberFormat fmt;
  final DateFormat dateFmt;
  final ValueChanged<bool>? onLoggingOutChanged;

  const _OpenShiftStatusCard({
    required this.shift,
    required this.shiftService,
    required this.fmt,
    required this.dateFmt,
    this.onLoggingOutChanged,
  });

  @override
  State<_OpenShiftStatusCard> createState() => _OpenShiftStatusCardState();
}

class _OpenShiftStatusCardState extends State<_OpenShiftStatusCard> {
  // Cache 1 lần theo shift.id — stream tự đẩy dữ liệu mới mỗi khi có hóa đơn
  // thanh toán phát sinh, không cần bấm refresh hay gọi lại thủ công.
  late Stream<Map<String, dynamic>> _revenueStream;
  Map<String, dynamic>? _lastRevenue; // giữ lại giá trị mới nhất để dùng khi mở dialog đóng ca

  @override
  void initState() {
    super.initState();
    _revenueStream = widget.shiftService.watchRevenueSince(widget.shift.openedAt);
  }

  @override
  void didUpdateWidget(covariant _OpenShiftStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.shift.id != widget.shift.id) {
      _revenueStream = widget.shiftService.watchRevenueSince(widget.shift.openedAt);
      _lastRevenue = null;
    }
  }

  Future<void> _openCloseDialog() async {
    // Lấy sẵn AuthProvider TRƯỚC khi mở dialog — dùng để đăng xuất SAU khi
    // dialog đã đóng hẳn (chỉ 1 nơi duy nhất quyết định logout, tránh đua lệnh).
    final auth = context.read<AuthProvider>();
    final cash = (_lastRevenue?['cashRevenue'] ?? 0).toDouble();
    final expected = widget.shift.openingCash + cash;

    // Báo cho MainShell tạm ẩn cổng "cần mở ca" phản ứng theo stream — vì
    // Firestore sẽ báo hết ca mở gần như ngay khi closeShift() ghi xong, tức
    // là RẤT LÂU trước khi dialog thật sự đóng trên giao diện (dialog còn
    // đang hiện "Đã đóng ca" ~0.9s). Nếu không chặn, cổng đó sẽ chớp qua
    // ngay phía sau dialog, gây cảm giác 2 màn hình chồng nhau khi dialog đóng.
    widget.onLoggingOutChanged?.call(true);

    final closed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CloseShiftDialog(
        shift: widget.shift,
        expectedCash: expected,
        shiftService: widget.shiftService,
        fmt: widget.fmt,
      ),
    );

    if (closed == true) {
      // showDialog() đã resolve nghĩa là dialog đã được pop khỏi Navigator —
      // chờ thêm chút xíu cho hiệu ứng đóng dialog kết thúc mượt mà (không
      // phải để "chờ xử lý xong", việc đóng ca đã xử lý xong từ trước khi
      // dialog tự pop rồi) rồi mới chuyển màn hình đăng nhập.
      await Future.delayed(const Duration(milliseconds: 200));
      auth.logout();
    } else {
      // Người dùng hủy đóng ca → bỏ cờ chặn, quay lại bình thường.
      widget.onLoggingOutChanged?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Map<String, dynamic>>(
      stream: _revenueStream,
      builder: (context, snap) {
        final revenue = snap.data;
        if (revenue != null) _lastRevenue = revenue;
        final cash = (revenue?['cashRevenue'] ?? 0).toDouble();
        final transfer = (revenue?['transferRevenue'] ?? 0).toDouble();
        final other = (revenue?['otherRevenue'] ?? 0).toDouble();
        final count = (revenue?['invoiceCount'] ?? 0) as int;
        final total = cash + transfer + other;

        return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.success.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text('ĐANG MỞ CA',
                      style: TextStyle(
                          color: AppColors.success, fontWeight: FontWeight.bold, fontSize: 11)),
                ),
                const Spacer(),
                Text(widget.shift.staffName,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ],
            ),
            const SizedBox(height: 4),
            Text('Mở lúc ${widget.dateFmt.format(widget.shift.openedAt)}',
                style: const TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            const SizedBox(height: 16),
            revenue == null
                ? const Center(child: Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ))
                : Column(
                    children: [
                      _statRow('Tiền mặt đầu ca', widget.shift.openingCash, widget.fmt),
                      const Divider(height: 20, color: AppColors.divider),
                      _statRow('Doanh thu tiền mặt', cash, widget.fmt),
                      _statRow('Doanh thu chuyển khoản', transfer, widget.fmt),
                      if (other > 0) _statRow('Khác', other, widget.fmt),
                      _statRow('Số hóa đơn', count.toDouble(), widget.fmt, isCount: true),
                      const Divider(height: 20, color: AppColors.divider),
                      _statRow('Tổng doanh thu ca', total, widget.fmt, bold: true),
                      _statRow('Tiền mặt dự kiến trong ngăn kéo',
                          widget.shift.openingCash + cash, widget.fmt,
                          bold: true, color: AppColors.primary),
                    ],
                  ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openCloseDialog,
                icon: const Icon(Icons.stop_circle_outlined),
                label: const Text('Đóng ca'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.error,
                  side: const BorderSide(color: AppColors.error),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _statRow(String label, double value, NumberFormat fmt,
      {bool bold = false, bool isCount = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                    color: bold ? AppColors.textPrimary : AppColors.textSecondary)),
          ),
          Text(
            isCount ? value.toInt().toString() : '${fmt.format(value)}đ',
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.bold : FontWeight.w600,
              color: color ?? (bold ? AppColors.textPrimary : AppColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

class CloseShiftDialog extends StatefulWidget {
  final ShiftModel shift;
  final double expectedCash;
  final ShiftService shiftService;
  final NumberFormat fmt;

  const CloseShiftDialog({
    required this.shift,
    required this.expectedCash,
    required this.shiftService,
    required this.fmt,
  });

  @override
  State<CloseShiftDialog> createState() => CloseShiftDialogState();
}

class CloseShiftDialogState extends State<CloseShiftDialog> {
  final _countedCtrl = TextEditingController();
  final _noteCtrl = TextEditingController();
  bool _busy = false;
  bool _success = false;

  double get _counted =>
      double.tryParse(_countedCtrl.text.replaceAll('.', '').replaceAll(',', '')) ?? 0;
  double get _discrepancy => _counted - widget.expectedCash;

  @override
  void dispose() {
    _countedCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  // LƯU Ý QUAN TRỌNG: dialog này CHỈ xử lý đóng ca và tự pop(true) khi xong —
  // KHÔNG tự gọi AuthProvider.logout() ở đây. Trước đây cả dialog này lẫn nơi
  // gọi nó (main_shell._logout / _openCloseDialog) đều tự ý logout ngay sau
  // khi showDialog() trả về, khiến 2 lệnh logout chạy đua nhau — có lúc màn
  // hình đăng nhập bật ra trong khi dialog vẫn còn đang animation đóng, gây
  // cảm giác 2 màn hình chồng lên nhau. Nay CHỈ nơi gọi (duy nhất 1 chỗ mỗi
  // lần) mới được quyết định logout, sau khi chắc chắn dialog đã đóng hẳn.
  /// Bấm "Xác nhận đóng ca" → hiện hộp thoại xác nhận LẠI số tiền đã đếm
  /// trước khi thực sự ghi vào hệ thống, tránh đóng ca nhầm số.
  Future<void> _onConfirmPressed() async {
    final diff = _discrepancy;
    final diffColor = diff == 0
        ? AppColors.success
        : (diff > 0 ? AppColors.info : AppColors.error);
    final confirmed = await _confirmMoneyDialog(
      context,
      title: 'Xác nhận đóng ca',
      amountLabel: 'Tiền mặt đếm được thực tế',
      amountText: '${widget.fmt.format(_counted)}đ',
      extra: Text(
        diff == 0
            ? 'Khớp — không chênh lệch'
            : diff > 0
                ? 'Dư ${widget.fmt.format(diff)}đ'
                : 'Thiếu ${widget.fmt.format(diff.abs())}đ',
        style: TextStyle(color: diffColor, fontWeight: FontWeight.bold),
      ),
    );
    if (!confirmed || !mounted) return;
    await _confirm();
  }

  Future<void> _confirm() async {
    setState(() => _busy = true);
    try {
      await widget.shiftService.closeShift(
        widget.shift,
        closingCashCounted: _counted,
        note: _noteCtrl.text.trim(),
      );
    } catch (e) {
      // Xử lý đóng ca thất bại (vd: mất mạng) → không thoát, cho thử lại.
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Đóng ca thất bại, vui lòng thử lại')),
        );
      }
      return;
    }
    // Đóng ca thành công — giữ trạng thái loading thêm 1 chút để người dùng
    // thấy rõ đã xử lý xong, rồi mới đóng dialog. Trả về true cho nơi gọi để
    // họ tự quyết định bước tiếp theo (đăng xuất).
    if (mounted) setState(() => _success = true);
    await Future.delayed(const Duration(milliseconds: 900));
    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final hasInput = _countedCtrl.text.isNotEmpty;
    final diff = _discrepancy;
    final diffColor = diff == 0
        ? AppColors.success
        : (diff > 0 ? AppColors.info : AppColors.error);

    return AlertDialog(
      title: const Text('Đóng ca làm việc'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tiền mặt dự kiến trong ngăn kéo: ${widget.fmt.format(widget.expectedCash)}đ',
              style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _countedCtrl,
              readOnly: true,
              showCursor: true,
              textAlign: TextAlign.right,
              decoration: const InputDecoration(
                labelText: 'Tiền mặt đếm được thực tế (VNĐ)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.calculate_outlined),
              ),
            ),
            const SizedBox(height: 10),
            _MoneyKeypad(
              controller: _countedCtrl,
              onChanged: (_) => setState(() {}),
            ),
            if (hasInput) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: diffColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  diff == 0
                      ? 'Khớp — không chênh lệch'
                      : diff > 0
                          ? 'Dư ${widget.fmt.format(diff)}đ'
                          : 'Thiếu ${widget.fmt.format(diff.abs())}đ',
                  style: TextStyle(color: diffColor, fontWeight: FontWeight.bold),
                ),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: _noteCtrl,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Ghi chú (không bắt buộc)',
                hintText: 'Ví dụ: lý do chênh lệch...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Hủy'),
        ),
        ElevatedButton(
          onPressed: _busy || !hasInput ? null : _onConfirmPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: _success ? AppColors.success : AppColors.primary,
            foregroundColor: Colors.white,
          ),
          child: _success
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_rounded, size: 18, color: Colors.white),
                    SizedBox(width: 6),
                    Text('Đã đóng ca'),
                  ],
                )
              : _busy
                  ? const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Xác nhận đóng ca'),
        ),
      ],
    );
  }
}

class _ShiftHistoryList extends StatelessWidget {
  final ShiftService shiftService;
  final NumberFormat fmt;
  final DateFormat dateFmt;

  const _ShiftHistoryList({
    required this.shiftService,
    required this.fmt,
    required this.dateFmt,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<ShiftModel>>(
      stream: shiftService.streamClosedShifts(),
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(
              child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final shifts = snap.data ?? [];
        if (shifts.isEmpty) {
          return const Text('Chưa có ca nào được đóng hôm nay',
              style: TextStyle(color: AppColors.textSecondary));
        }
        return Column(
          children: shifts.map((s) => _ShiftHistoryTile(shift: s, fmt: fmt, dateFmt: dateFmt)).toList(),
        );
      },
    );
  }
}

class _ShiftHistoryTile extends StatelessWidget {
  final ShiftModel shift;
  final NumberFormat fmt;
  final DateFormat dateFmt;

  const _ShiftHistoryTile({required this.shift, required this.fmt, required this.dateFmt});

  @override
  Widget build(BuildContext context) {
    final diff = shift.discrepancy ?? 0;
    final diffColor = diff == 0
        ? AppColors.success
        : (diff > 0 ? AppColors.info : AppColors.error);
    final diffLabel = diff == 0
        ? 'Khớp'
        : diff > 0
            ? 'Dư ${fmt.format(diff)}đ'
            : 'Thiếu ${fmt.format(diff.abs())}đ';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 14),
        title: Row(
          children: [
            Expanded(
              child: Text(shift.staffName,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: diffColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(diffLabel,
                  style: TextStyle(color: diffColor, fontWeight: FontWeight.bold, fontSize: 11)),
            ),
          ],
        ),
        subtitle: Text(
          '${dateFmt.format(shift.openedAt)} → ${shift.closedAt != null ? dateFmt.format(shift.closedAt!) : '-'}',
          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            child: Column(
              children: [
                _row('Tiền mặt đầu ca', '${fmt.format(shift.openingCash)}đ'),
                _row('Doanh thu tiền mặt', '${fmt.format(shift.cashRevenue)}đ'),
                _row('Doanh thu chuyển khoản', '${fmt.format(shift.transferRevenue)}đ'),
                if (shift.otherRevenue > 0) _row('Khác', '${fmt.format(shift.otherRevenue)}đ'),
                _row('Tổng doanh thu', '${fmt.format(shift.totalRevenue)}đ'),
                _row('Số hóa đơn', '${shift.invoiceCount}'),
                const Divider(height: 18, color: AppColors.divider),
                _row('Tiền mặt dự kiến', '${fmt.format(shift.expectedCash)}đ'),
                _row('Tiền mặt đếm được', '${fmt.format(shift.closingCashCounted ?? 0)}đ'),
                if (shift.note != null && shift.note!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Ghi chú: ${shift.note}',
                        style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic, color: AppColors.textSecondary)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          Text(value, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
