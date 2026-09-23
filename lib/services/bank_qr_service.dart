import 'package:shared_preferences/shared_preferences.dart';

/// Danh sách ngân hàng phổ biến ở VN kèm mã BIN (theo chuẩn Napas/VietQR).
/// Dùng cho dropdown chọn ngân hàng ở màn Cài đặt QR chuyển khoản.
const Map<String, String> kVietQrBanks = {
  'Vietcombank': '970436',
  'Techcombank': '970407',
  'MB Bank (Quân đội)': '970422',
  'VietinBank': '970415',
  'BIDV': '970418',
  'Agribank': '970405',
  'ACB': '970416',
  'TPBank': '970423',
  'VPBank': '970432',
  'Sacombank': '970403',
  'HDBank': '970437',
  'SHB': '970443',
  'Eximbank': '970431',
  'MSB': '970426',
  'VIB': '970441',
  'OCB': '970448',
  'SeABank': '970440',
  'SCB': '970429',
  'LienVietPostBank': '970449',
  'Nam A Bank': '970428',
};

/// Quản lý cấu hình mã QR chuyển khoản ngân hàng (chuẩn VietQR) in ở cuối
/// hóa đơn để khách quét chuyển tiền. Cấu hình được lưu lại trên máy
/// (SharedPreferences), tương tự [PrinterService] — chỉ cần thiết lập 1 lần.
class BankQrService {
  BankQrService._();
  static final BankQrService instance = BankQrService._();

  static const _kEnabled = 'bankqr_enabled';
  static const _kBankName = 'bankqr_bank_name';
  static const _kBankBin = 'bankqr_bank_bin';
  static const _kAccountNumber = 'bankqr_account_number';
  static const _kAccountName = 'bankqr_account_name';

  bool enabled = false;
  String bankName = '';
  String bankBin = '';
  String accountNumber = '';
  String accountName = '';

  bool _loaded = false;

  /// Đủ thông tin để tạo mã QR (mã ngân hàng + số tài khoản).
  bool get isConfigured => bankBin.isNotEmpty && accountNumber.isNotEmpty;

  /// Có nên in QR lên hóa đơn hay không (đã bật + đủ thông tin).
  bool get shouldPrint => enabled && isConfigured;

  // Giá trị mặc định ban đầu (quán đã cung cấp) — chỉ áp dụng khi máy chưa
  // từng lưu cấu hình nào (lần in đầu tiên); sau khi đã lưu 1 lần thì luôn
  // ưu tiên dữ liệu đã lưu trong SharedPreferences.
  static const _defaultBankName = 'MB Bank (Quân đội)';
  static const _defaultAccountNumber = '0342619457';
  static const _defaultAccountName = 'LUU THI GAI';

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    final hasSaved = sp.containsKey(_kAccountNumber);
    enabled = sp.getBool(_kEnabled) ?? true;
    bankName = sp.getString(_kBankName) ?? _defaultBankName;
    bankBin = sp.getString(_kBankBin) ?? (kVietQrBanks[_defaultBankName] ?? '');
    accountNumber = sp.getString(_kAccountNumber) ?? _defaultAccountNumber;
    accountName = sp.getString(_kAccountName) ?? _defaultAccountName;
    _loaded = true;
    if (!hasSaved) {
      // Lần đầu chạy trên máy này — lưu lại mặc định để lần sau đọc thẳng
      // từ SharedPreferences, và để màn Cài đặt hiển thị đúng ngay khi mở.
      await save(
        enabled: enabled,
        bankName: bankName,
        bankBin: bankBin,
        accountNumber: accountNumber,
        accountName: accountName,
      );
    }
  }

  Future<void> reload() async {
    _loaded = false;
    await load();
  }

  Future<void> save({
    required bool enabled,
    required String bankName,
    required String bankBin,
    required String accountNumber,
    required String accountName,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kEnabled, enabled);
    await sp.setString(_kBankName, bankName);
    await sp.setString(_kBankBin, bankBin);
    await sp.setString(_kAccountNumber, accountNumber);
    await sp.setString(_kAccountName, accountName);
    this.enabled = enabled;
    this.bankName = bankName;
    this.bankBin = bankBin;
    this.accountNumber = accountNumber;
    this.accountName = accountName;
    _loaded = true;
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kEnabled);
    await sp.remove(_kBankName);
    await sp.remove(_kBankBin);
    await sp.remove(_kAccountNumber);
    await sp.remove(_kAccountName);
    enabled = false;
    bankName = '';
    bankBin = '';
    accountNumber = '';
    accountName = '';
  }

  /// URL ảnh QR chuẩn VietQR (dịch vụ công khai của Napas/VietQR, được hầu
  /// hết app ngân hàng, MoMo, ZaloPay hỗ trợ quét). Template `qr_only` chỉ
  /// trả về đúng mã QR (không kèm logo/khung thông tin) vì hóa đơn đã tự in
  /// sẵn tên ngân hàng/chủ tài khoản bằng chữ.
  /// [amount]: số tiền điền sẵn (VNĐ, làm tròn). [content]: nội dung chuyển
  /// khoản (vd: mã hóa đơn) để đối soát cho dễ.
  String imageUrl({required num amount, String content = ''}) {
    return staticImageUrl(
      bankBin: bankBin,
      accountNumber: accountNumber,
      accountName: accountName,
      amount: amount,
      content: content,
    );
  }

  /// Bản tĩnh của [imageUrl], không phụ thuộc cấu hình đã lưu — dùng để xem
  /// trước QR ngay khi đang nhập ở màn Cài đặt, trước khi bấm Lưu.
  static String staticImageUrl({
    required String bankBin,
    required String accountNumber,
    required String accountName,
    required num amount,
    String content = '',
  }) {
    final amt = amount.round();
    final info = Uri.encodeQueryComponent(content);
    final name = Uri.encodeQueryComponent(accountName);
    return 'https://img.vietqr.io/image/$bankBin-$accountNumber-qr_only.png'
        '?amount=$amt&addInfo=$info&accountName=$name';
  }
}
