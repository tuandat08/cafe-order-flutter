import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../services/bank_qr_service.dart';

/// Màn hình cấu hình mã QR chuyển khoản ngân hàng (chuẩn VietQR) in ở cuối
/// hóa đơn để khách quét chuyển tiền. Cấu hình được lưu lại trên máy, dùng
/// chung cho toàn bộ chức năng in hóa đơn (preview, in nhiệt, in PDF).
class BankQrSettingsScreen extends StatefulWidget {
  const BankQrSettingsScreen({super.key});

  @override
  State<BankQrSettingsScreen> createState() => _BankQrSettingsScreenState();
}

class _BankQrSettingsScreenState extends State<BankQrSettingsScreen> {
  final _accountNumberCtrl = TextEditingController();
  final _accountNameCtrl = TextEditingController();
  final _customBinCtrl = TextEditingController();

  bool _enabled = false;
  String? _bankName; // key trong kVietQrBanks, null = "Ngân hàng khác"
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _accountNumberCtrl.dispose();
    _accountNameCtrl.dispose();
    _customBinCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await BankQrService.instance.load();
    final s = BankQrService.instance;
    setState(() {
      _enabled = s.enabled;
      _accountNumberCtrl.text = s.accountNumber;
      _accountNameCtrl.text = s.accountName;
      if (s.bankName.isNotEmpty && kVietQrBanks.containsKey(s.bankName)) {
        _bankName = s.bankName;
      } else if (s.bankBin.isNotEmpty) {
        _bankName = null; // ngân hàng khác — điền BIN thủ công
        _customBinCtrl.text = s.bankBin;
      }
    });
  }

  void _setStatus(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusIsError = isError;
    });
  }

  String get _resolvedBin =>
      _bankName != null ? (kVietQrBanks[_bankName!] ?? '') : _customBinCtrl.text.trim();

  Future<void> _save() async {
    final accountNumber = _accountNumberCtrl.text.trim();
    final accountName = _accountNameCtrl.text.trim().toUpperCase();
    final bin = _resolvedBin;
    if (accountNumber.isEmpty || bin.isEmpty) {
      _setStatus('Vui lòng chọn ngân hàng và nhập số tài khoản', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await BankQrService.instance.save(
        enabled: _enabled,
        bankName: _bankName ?? 'Ngân hàng khác',
        bankBin: bin,
        accountNumber: accountNumber,
        accountName: accountName,
      );
      _setStatus('Đã lưu cấu hình QR chuyển khoản');
      setState(() {}); // cập nhật ảnh xem trước theo dữ liệu vừa lưu
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Bật/tắt in QR được lưu NGAY khi gạt công tắc — không phải chờ bấm nút
  /// "Lưu cấu hình" (nút đó chỉ dành cho các trường ngân hàng/số TK/tên).
  Future<void> _toggleEnabled(bool v) async {
    setState(() => _enabled = v);
    await BankQrService.instance.save(
      enabled: v,
      bankName: _bankName ?? BankQrService.instance.bankName,
      bankBin: _resolvedBin.isNotEmpty ? _resolvedBin : BankQrService.instance.bankBin,
      accountNumber: _accountNumberCtrl.text.trim().isNotEmpty
          ? _accountNumberCtrl.text.trim()
          : BankQrService.instance.accountNumber,
      accountName: _accountNameCtrl.text.trim().isNotEmpty
          ? _accountNameCtrl.text.trim().toUpperCase()
          : BankQrService.instance.accountName,
    );
    _setStatus(v ? 'Đã bật in QR chuyển khoản' : 'Đã tắt in QR chuyển khoản');
  }

  @override
  Widget build(BuildContext context) {
    final bin = _resolvedBin;
    final accountNumber = _accountNumberCtrl.text.trim();
    final canPreview = bin.isNotEmpty && accountNumber.isNotEmpty;
    final previewUrl = canPreview
        ? BankQrService.staticImageUrl(
            bankBin: bin,
            accountNumber: accountNumber,
            accountName: _accountNameCtrl.text.trim().toUpperCase(),
            amount: 50000,
            content: 'Xem thu QR',
          )
        : null;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Cài đặt QR chuyển khoản'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Đóng',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Thiết lập tài khoản ngân hàng nhận tiền để in mã QR chuyển khoản (chuẩn VietQR) ở cuối hóa đơn — khách quét là ra sẵn số tiền cần chuyển.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('In mã QR chuyển khoản trên hóa đơn', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                          value: _enabled,
                          onChanged: _toggleEnabled,
                        ),
                        const Divider(height: 24),
                        Text('Ngân hàng', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        DropdownButtonFormField<String?>(
                          initialValue: _bankName,
                          decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                          items: [
                            ...kVietQrBanks.keys.map((n) => DropdownMenuItem(value: n, child: Text(n))),
                            const DropdownMenuItem(value: null, child: Text('Ngân hàng khác...')),
                          ],
                          onChanged: (v) => setState(() => _bankName = v),
                        ),
                        if (_bankName == null) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _customBinCtrl,
                            decoration: const InputDecoration(labelText: 'Mã BIN ngân hàng (VD: 970422)', border: OutlineInputBorder()),
                            keyboardType: TextInputType.number,
                            onChanged: (_) => setState(() {}),
                          ),
                        ],
                        const SizedBox(height: 16),
                        TextField(
                          controller: _accountNumberCtrl,
                          decoration: const InputDecoration(labelText: 'Số tài khoản', border: OutlineInputBorder()),
                          keyboardType: TextInputType.number,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _accountNameCtrl,
                          decoration: const InputDecoration(labelText: 'Tên chủ tài khoản (không dấu, in hoa)', hintText: 'VD: NGUYEN VAN A', border: OutlineInputBorder()),
                          textCapitalization: TextCapitalization.characters,
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          height: 44,
                          child: ElevatedButton.icon(
                            onPressed: _busy ? null : _save,
                            icon: _busy
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                : const Icon(Icons.save_outlined),
                            label: const Text('Lưu cấu hình'),
                          ),
                        ),
                        if (_status != null) ...[
                          const SizedBox(height: 12),
                          Text(_status!, style: TextStyle(color: _statusIsError ? AppColors.error : const Color(0xFF059669), fontWeight: FontWeight.w600)),
                        ],
                      ],
                    ),
                  ),
                ),
                if (previewUrl != null) ...[
                  const SizedBox(height: 20),
                  Text('Xem thử mã QR (số tiền minh họa 50.000đ)', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(border: Border.all(color: AppColors.divider), borderRadius: BorderRadius.circular(12)),
                      child: Image.network(
                        previewUrl,
                        width: 220,
                        height: 220,
                        errorBuilder: (_, __, ___) => const SizedBox(
                          width: 220,
                          height: 220,
                          child: Center(child: Text('Không tạo được QR xem thử — kiểm tra lại số tài khoản', textAlign: TextAlign.center)),
                        ),
                        loadingBuilder: (ctx, child, progress) => progress == null
                            ? child
                            : const SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator())),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  'Mã QR dùng chuẩn VietQR — quét được bằng hầu hết app ngân hàng, MoMo, ZaloPay. Số tiền sẽ tự điền đúng theo tổng hóa đơn khi in thật.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
