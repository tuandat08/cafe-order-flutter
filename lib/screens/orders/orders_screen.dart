import 'dart:async';
import 'dart:typed_data';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../services/notification_sound_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:provider/provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_image_builder.dart';
import '../../services/bank_qr_service.dart';
import 'package:http/http.dart' as http;
import '../settings/printer_settings_screen.dart';
import '../settings/voice_settings_screen.dart';
import '../settings/bank_qr_settings_screen.dart';
import '../../services/azure_tts_service.dart';
import '../../services/free_tts_service.dart';
import '../../core/theme/app_theme.dart';
import '../../models/menu_item_model.dart';
import '../../models/order_model.dart';
import '../../models/table_model.dart';
import '../../models/discount_model.dart';
import '../../services/menu_service.dart';
import '../../services/order_service.dart';
import '../../services/table_service.dart';
import '../../widgets/floor_plan_board.dart';
import '../../services/discount_service.dart';
import '../../services/invoice_service.dart';
import '../../services/audit_service.dart';
import '../../models/account_model.dart';
import '../../widgets/manager_approval.dart';

// Chuẩn hoá id bàn để gom nhóm: "T3" / "3" / "03" → "03" (khớp format tables "01".."11").
// Giữ nguyên chuỗi không phải bàn số (vd "Mang về"); rỗng → "Bàn chưa xác định".
String _canonTableId(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return 'Bàn chưa xác định';
  final digits = RegExp(r'\d+').firstMatch(s)?.group(0);
  // Chỉ coi là "bàn số" khi id ngắn (vd T3, 3, 03) — tránh đụng "Mang về"
  if (digits != null && s.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').length <= 3) {
    final n = int.tryParse(digits);
    if (n != null && n > 0) return n.toString().padLeft(2, '0');
  }
  return s;
}

// ─── Giỏ hàng POS ─────────────────────────────────────────────────────────────
class _CartEntry {
  final MenuItemModel item;
  int qty;
  String note;
  _CartEntry({required this.item, this.qty = 1, this.note = ''});
  double get subtotal => item.price * qty;
}

// ─── Trạng thái active — giống web: hiện tất cả trừ 'closed' ───────────────────
// Web: orders.filter(o => o.status !== 'closed'); lifecycle: pending → completed → closed
// Bao gồm cả status Flutter (preparing/ready/served) lẫn web (completed) để tương thích
const Set<String> _kActive = {'pending', 'preparing', 'ready', 'served', 'completed'};

// Đơn được coi là "đã xong" — web: 'completed', Flutter: 'served'
bool _isDone(String status) => status == 'completed' || status == 'served';

// Viết hoa chữ cái đầu mỗi từ (giữ nguyên phần còn lại) — dùng cho tiêu đề,
// ví dụ "Chi tiết bàn Mang về" -> "Chi Tiết Bàn Mang Về".
String _titleCase(String s) => s
    .split(' ')
    .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
    .join(' ');

// ─── Màu timer — giống web getTimerColor ──────────────────────────────────────
Color _timerColor(int minutes) {
  if (minutes < 5)  return const Color(0xFF16A34A); // green-600
  if (minutes < 10) return const Color(0xFFD97706); // amber-600
  return const Color(0xFFDC2626);                    // red-600
}

int _elapsedMinutes(DateTime? createdAt) {
  if (createdAt == null) return 0;
  return DateTime.now().difference(createdAt).inMinutes;
}

// Định dạng số phút đã trôi qua: <60 → "N phút", >=60 → "Xh" hoặc "XhYY"
String _fmtElapsed(int minutes) {
  if (minutes < 60) return '$minutes phút';
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (m == 0) return '${h}h';
  return '${h}h${m.toString().padLeft(2, '0')}';
}

// Tính tiền giảm — giống web calcDiscount(discount, total)
double _calcDiscount(Map<String, dynamic>? discount, double total) {
  if (discount == null || total <= 0) return 0;
  double amount;
  final type = discount['type']?.toString();
  final value = double.tryParse('${discount['value'] ?? 0}') ?? 0;
  if (type == 'percent') {
    amount = (total * (value / 100)).roundToDouble();
    final maxD = double.tryParse('${discount['maxDiscount'] ?? 0}') ?? 0;
    if (maxD > 0) amount = amount < maxD ? amount : maxD;
  } else {
    amount = value;
  }
  return amount < total ? amount : total;
}

// Lấy ảnh cho 1 món trong đơn: item.image → menu theo id → menu theo tên
String? _resolveItemImage(OrderItem item, Map<String, MenuItemModel> cache) {
  if (item.image != null && item.image!.isNotEmpty) return item.image;
  final byId = cache[item.id];
  if (byId?.imageUrl != null && byId!.imageUrl!.isNotEmpty) return byId.imageUrl;
  for (final m in cache.values) {
    if (m.name == item.name && m.imageUrl != null && m.imageUrl!.isNotEmpty) {
      return m.imageUrl;
    }
  }
  return null;
}

// Dòng label/giá trị trong hóa đơn PDF
pw.Widget _pdfRow(String label, String value) => pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
        pw.Text(value, style: const pw.TextStyle(fontSize: 9)),
      ],
    );

final _vndFmt = NumberFormat('#,###', 'vi_VN');

/// Bàn [t] đã xuất bill cho TẤT CẢ [orders] đang hiện hay chưa.
/// - [localIds]: mã đơn trong bill vừa in trên máy này (chưa kịp đồng bộ).
/// - Bill in từ bản mới lưu `lastBilledOrderIds` → so đúng từng mã đơn.
/// - Bill cũ (chỉ có `lastBilledAt`) → đơn tạo sau lúc in bill (cho sai lệch
///   đồng hồ 60 giây) không thuộc bill.
bool _tableBilledFor(TableModel? t, Set<String>? localIds, List<OrderModel> orders) {
  if (orders.isEmpty) return false;
  if (localIds != null) return orders.every((o) => localIds.contains(o.id));
  final billedAt = t?.lastBilledAt;
  if (t == null || billedAt == null) return false;
  final cleared = t.clearedAt;
  if (cleared != null && !billedAt.isAfter(cleared)) return false; // đã dọn sau lần bill cuối
  final ids = t.lastBilledOrderIds;
  if (ids != null) return orders.every((o) => ids.contains(o.id));
  final limit = billedAt.add(const Duration(seconds: 60));
  return orders.every((o) => o.createdAt != null && !o.createdAt!.isAfter(limit));
}

// Font in hóa đơn PDF — đóng gói sẵn trong app (assets/fonts, Roboto đủ dấu tiếng
// Việt). Trước đây tải từ Google Fonts MỖI LẦN IN → mất mạng thì chữ có dấu bị lỗi.
// Nạp 1 lần rồi dùng lại.
Future<pw.ThemeData>? _receiptPdfThemeFuture;
Future<pw.ThemeData> _receiptPdfTheme() => _receiptPdfThemeFuture ??= () async {
      final regular = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      final bold = pw.Font.ttf(await rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      return pw.ThemeData.withFont(base: regular, bold: bold);
    }();

// ═══════════════════════════════════════════════════════
//  ENTRY POINT
// ═══════════════════════════════════════════════════════
class OrdersScreen extends StatefulWidget {
  final VoidCallback? onToggleSidebar; // ☰ ẩn/hiện sidebar (đặt cạnh tab POS)
  const OrdersScreen({super.key, this.onToggleSidebar});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 3, vsync: this, initialIndex: 2);
  int _tabIndex = 2; // mặc định mở tab "Bàn (POS)" (đã ẩn tab "Đơn hàng")
  bool _floorPlanOpen = false; // đang mở sơ đồ bàn → nút "Sơ đồ bàn" sáng thay cho tab
  bool _soundEnabled = true; // bật/tắt âm thanh thông báo — icon chuông trên top bar
  final _posTabKey = GlobalKey<_POSTabState>(); // để nút "Sơ đồ bàn" ở top bar gọi chọn bàn vào tab POS

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (_tab.indexIsChanging || _tabIndex != _tab.index) {
        setState(() => _tabIndex = _tab.index);
      }
    });
    NotificationSoundService.instance.load().then((_) {
      if (mounted) setState(() => _soundEnabled = NotificationSoundService.instance.enabled);
    });
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: Column(children: [
          _buildTopBar(),
          Expanded(
            child: IndexedStack(
              index: _tabIndex,
              children: [_POSTab(key: _posTabKey), const _KDSTab(), const _TableBoardTab()],
            ),
          ),
        ]),
      ),
    );
  }

  Widget _buildTopBar() {
    final showToggle = widget.onToggleSidebar != null;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        // ☰ ẩn/hiện sidebar (đặt cạnh POS - Tạo đơn)
        if (showToggle) ...[
          IconButton(
            icon: const Icon(Icons.menu_rounded, size: 22),
            color: AppColors.textSecondary,
            onPressed: widget.onToggleSidebar,
          ),
          const SizedBox(width: 2),
        ],
        _tabBtn(2, Icons.table_restaurant_rounded, 'Bàn (POS)'),
        const SizedBox(width: 8),
        _tabBtn(0, Icons.point_of_sale_rounded, 'POS - Tạo đơn'),
        const SizedBox(width: 8),
        _floorPlanBtn(),
        const Spacer(),
        // 🖨️ cài đặt máy in nhiệt (ESC/POS)
        IconButton(
          icon: const Icon(Icons.print_outlined, size: 20),
          color: AppColors.textSecondary,
          tooltip: 'Cài đặt máy in',
          onPressed: () {
            // Mở dạng panel hẹp bên phải (không chiếm toàn màn hình) — vừa đủ cho phần cài đặt.
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: 'Cài đặt máy in',
              barrierColor: Colors.black.withOpacity(0.35),
              transitionDuration: const Duration(milliseconds: 220),
              pageBuilder: (ctx, anim1, anim2) {
                final screenWidth = MediaQuery.of(ctx).size.width;
                final panelWidth = screenWidth < 700
                    ? screenWidth
                    : (screenWidth * 0.5).clamp(420.0, 560.0);
                return Align(
                  alignment: Alignment.centerRight,
                  child: Material(
                    elevation: 8,
                    child: SizedBox(
                      width: panelWidth,
                      height: double.infinity,
                      child: const PrinterSettingsScreen(),
                    ),
                  ),
                );
              },
              transitionBuilder: (ctx, anim, secondaryAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                  child: child,
                );
              },
            );
          },
        ),
        // 🗣️ cấu hình giọng đọc AI (tuỳ chọn) — cùng kiểu panel hẹp bên phải
        IconButton(
          icon: const Icon(Icons.record_voice_over_outlined, size: 20),
          color: AppColors.textSecondary,
          tooltip: 'Giọng đọc AI',
          onPressed: () {
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: 'Giọng đọc AI',
              barrierColor: Colors.black.withOpacity(0.35),
              transitionDuration: const Duration(milliseconds: 220),
              pageBuilder: (ctx, anim1, anim2) {
                final screenWidth = MediaQuery.of(ctx).size.width;
                final panelWidth = screenWidth < 700
                    ? screenWidth
                    : (screenWidth * 0.5).clamp(420.0, 560.0);
                return Align(
                  alignment: Alignment.centerRight,
                  child: Material(
                    elevation: 8,
                    child: SizedBox(
                      width: panelWidth,
                      height: double.infinity,
                      child: const VoiceSettingsScreen(),
                    ),
                  ),
                );
              },
              transitionBuilder: (ctx, anim, secondaryAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                  child: child,
                );
              },
            );
          },
        ),
        // 🏦 cài đặt QR chuyển khoản ngân hàng (VietQR) in cuối hóa đơn
        IconButton(
          icon: const Icon(Icons.qr_code_2_outlined, size: 20),
          color: AppColors.textSecondary,
          tooltip: 'Cài đặt QR chuyển khoản',
          onPressed: () {
            showGeneralDialog(
              context: context,
              barrierDismissible: true,
              barrierLabel: 'Cài đặt QR chuyển khoản',
              barrierColor: Colors.black.withOpacity(0.35),
              transitionDuration: const Duration(milliseconds: 220),
              pageBuilder: (ctx, anim1, anim2) {
                final screenWidth = MediaQuery.of(ctx).size.width;
                final panelWidth = screenWidth < 700
                    ? screenWidth
                    : (screenWidth * 0.5).clamp(420.0, 560.0);
                return Align(
                  alignment: Alignment.centerRight,
                  child: Material(
                    elevation: 8,
                    child: SizedBox(
                      width: panelWidth,
                      height: double.infinity,
                      child: const BankQrSettingsScreen(),
                    ),
                  ),
                );
              },
              transitionBuilder: (ctx, anim, secondaryAnim, child) {
                return SlideTransition(
                  position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
                      .animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
                  child: child,
                );
              },
            );
          },
        ),
        // 🔔 bật/tắt âm thanh thông báo (chuông "ting" khi có đơn mới / gọi phục vụ / trễ món)
        IconButton(
          icon: Icon(_soundEnabled ? Icons.notifications_active_outlined : Icons.notifications_off_outlined, size: 20),
          color: _soundEnabled ? AppColors.textSecondary : AppColors.error,
          tooltip: _soundEnabled ? 'Tắt âm thanh thông báo' : 'Bật âm thanh thông báo',
          onPressed: () async {
            final next = !_soundEnabled;
            await NotificationSoundService.instance.setEnabled(next);
            if (mounted) setState(() => _soundEnabled = next);
          },
        ),
      ]),
    );
  }

  Widget _tabBtn(int idx, IconData icon, String label) {
    return _headerTabButton(
      icon: icon,
      label: label,
      active: _tabIndex == idx && !_floorPlanOpen,
      onTap: () {
        _tab.animateTo(idx);
        setState(() => _tabIndex = idx);
      },
    );
  }

  /// Kiểu nút chung của thanh trên (Bàn (POS) · POS - Tạo đơn · Sơ đồ bàn):
  /// đang chọn → nền nâu chữ trắng; không chọn → chữ xám nền trong suốt.
  Widget _headerTabButton({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? AppColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(children: [
          Icon(icon, size: 16,
              color: active ? Colors.white : AppColors.textSecondary),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(
            color: active ? Colors.white : AppColors.textSecondary,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            fontSize: 13,
          )),
        ]),
      ),
    );
  }

  // Nút mở sơ đồ bàn trực quan (đúng bố cục đã setting ở web) — đặt cạnh nút
  // "POS - Tạo đơn". Bấm vào 1 bàn trên sơ đồ sẽ chuyển sang tab POS và chọn
  // luôn bàn đó cho đơn đang tạo.
  Widget _floorPlanBtn() {
    return _headerTabButton(
      icon: Icons.map_rounded,
      label: 'Sơ đồ bàn',
      active: _floorPlanOpen,
      onTap: () async {
        _tab.animateTo(0);
        setState(() {
          _tabIndex = 0;
          _floorPlanOpen = true;
        });
        final selected = await showDialog<String>(
          context: context,
          builder: (ctx) => const FloorPlanPickerDialog(),
        );
        if (!mounted) return;
        setState(() => _floorPlanOpen = false);
        if (selected != null && selected.isNotEmpty) {
          _posTabKey.currentState?.selectTableFromFloorPlan(selected);
        }
      },
    );
  }

}

// ═══════════════════════════════════════════════════════
//  POS TAB
// ═══════════════════════════════════════════════════════
class _POSTab extends StatefulWidget {
  const _POSTab({super.key});
  @override
  State<_POSTab> createState() => _POSTabState();
}

class _POSTabState extends State<_POSTab> {
  final _menuService  = MenuService();
  final _orderService = OrderService();
  final _tableService = TableService();

  final List<_CartEntry> _cart = [];
  // Danh sách bàn lấy TRỰC TIẾP từ collection tables (gồm cả bàn "Mang về" tạo ở web).
  // Dùng đúng id bàn để đơn POS gộp chung thẻ với đơn khách/thêm món.
  List<TableModel> _posTables = [];
  String _tableId = '';
  bool _tablePicked = false; // user đã tự chọn bàn hay chưa (để không ghi đè)
  String _catFilter = 'Tất cả';
  String _search = '';
  bool _submitting = false;
  double _cartWidth = 300; // độ rộng cột giỏ hàng — kéo thanh ngăn cách để chỉnh

  // Bàn nào đang có đơn active (chưa hoàn thành) → tô màu trong bộ chọn bàn
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ordersSub;
  Set<String> _occupiedTableIds = {};

  @override
  void initState() {
    super.initState();
    _ordersSub = activeOrdersQuery().snapshots().listen((snap) {
      final occ = <String>{};
      for (final d in snap.docs) {
        final data = d.data();
        final status = data['status']?.toString() ?? '';
        if (_kActive.contains(status)) {
          final tid = data['tableId']?.toString() ?? '';
          if (tid.isNotEmpty) occ.add(tid);
        }
      }
      if (mounted) setState(() => _occupiedTableIds = occ);
    });
  }

  @override
  void dispose() {
    _ordersSub?.cancel();
    super.dispose();
  }

  double get _total => _cart.fold(0, (s, e) => s + e.subtotal);

  // Nhãn hiển thị trên nút chọn bàn / giỏ hàng (lấy tên bàn từ doc)
  String _tableLabel(String id) {
    if (id.isEmpty) return '';
    final t = _posTables.where((x) => x.id == id).firstOrNull;
    return t?.name ?? 'Bàn $id';
  }

  Future<void> _openTablePicker() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => _TablePickerDialog(
        tables: _posTables,
        selectedId: _tableId,
        occupiedIds: _occupiedTableIds,
      ),
    );
    if (selected != null && selected.isNotEmpty && mounted) {
      setState(() { _tableId = selected; _tablePicked = true; });
    }
  }

  // Chọn bàn trực tiếp từ sơ đồ mở bên ngoài (nút trên thanh tab) — gọi qua
  // GlobalKey (xem _posTabKey ở _OrdersScreenState).
  void selectTableFromFloorPlan(String tableId) {
    if (!mounted) return;
    setState(() { _tableId = tableId; _tablePicked = true; });
  }

  void _addItem(MenuItemModel item) {
    setState(() {
      final existing = _cart.where((e) => e.item.id == item.id).firstOrNull;
      if (existing != null) {
        existing.qty++;
      } else {
        _cart.add(_CartEntry(item: item));
      }
    });
  }

  void _removeItem(int idx) => setState(() => _cart.removeAt(idx));

  void _changeQty(int idx, int delta) {
    setState(() {
      _cart[idx].qty += delta;
      if (_cart[idx].qty <= 0) _cart.removeAt(idx);
    });
  }

  Future<void> _submit() async {
    if (_cart.isEmpty) return;
    setState(() => _submitting = true);
    try {
      final items = _cart.map((e) => OrderItem(
        id: e.item.id,
        name: e.item.name,
        quantity: e.qty,
        price: e.item.price,
        note: e.note.isEmpty ? null : e.note,
        image: e.item.imageUrl,
      )).toList();
      await _orderService.createOrder(tableId: _tableId, items: items);
      setState(() { _cart.clear(); _submitting = false; });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Đã tạo đơn thành công'),
          backgroundColor: AppColors.success,
          duration: Duration(seconds: 2),
        ));
      }
    } catch (e) {
      setState(() => _submitting = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().contains('permission')
              ? 'Firestore từ chối - kiểm tra Security Rules'
              : 'Lỗi: $e'),
          backgroundColor: AppColors.error,
          duration: const Duration(seconds: 4),
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(
        child: Column(children: [
          // Chọn bàn
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: AppColors.surface,
            child: Row(children: [
              const Text('Bàn: ', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(width: 8),
              StreamBuilder<List<TableModel>>(
                stream: _tableService.streamTables(),
                builder: (ctx, snap) {
                  // Cập nhật cache bàn (dùng cho nhãn + submit)
                  final tables = snap.data ?? _posTables;
                  if (tables.isNotEmpty) {
                    tables.sort((a, b) {
                      final na = int.tryParse(a.id) ?? 9999;
                      final nb = int.tryParse(b.id) ?? 9999;
                      return na != nb ? na.compareTo(nb) : a.id.compareTo(b.id);
                    });
                    _posTables = tables;
                    // Mặc định chọn bàn đầu tiên nếu user chưa tự chọn
                    if (!_tablePicked && _tableId.isEmpty) {
                      _tableId = tables.first.id;
                    }
                  }
                  final occupied = _occupiedTableIds.contains(_tableId);
                  final curTable = tables.where((t) => t.id == _tableId).firstOrNull;
                  final service = curTable?.serviceRequest != null;
                  final bill = curTable?.isBillRequest ?? false;
                  // Nền + viền + chữ của chip cũng đổi theo trạng thái (không chỉ chấm tròn),
                  // giống hệt 3 trạng thái ở dialog "Chọn bàn": xám trống / xanh đang phục vụ / vàng gọi phục vụ.
                  final Color dot;
                  final Color chipBg;
                  final Color chipBorder;
                  final Color chipText;
                  if (bill) {
                    dot = const Color(0xFF2563EB);
                    chipBg = const Color(0xFFDBEAFE);
                    chipBorder = const Color(0xFF2563EB);
                    chipText = const Color(0xFF1D4ED8);
                  } else if (service) {
                    dot = const Color(0xFFF59E0B);
                    chipBg = const Color(0xFFFEF3C7);
                    chipBorder = const Color(0xFFF59E0B);
                    chipText = const Color(0xFFB45309);
                  } else if (occupied) {
                    dot = AppColors.success;
                    chipBg = const Color(0xFFDCFCE7);
                    chipBorder = AppColors.success;
                    chipText = const Color(0xFF15803D);
                  } else {
                    dot = const Color(0xFF94A3B8);
                    chipBg = AppColors.background;
                    chipBorder = AppColors.divider;
                    chipText = AppColors.textPrimary;
                  }
                  return GestureDetector(
                    onTap: _openTablePicker,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: chipBg,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: chipBorder),
                      ),
                      child: Row(mainAxisSize: MainAxisSize.min, children: [
                        Container(
                          width: 9, height: 9,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _tableLabel(_tableId).isEmpty ? 'Chọn bàn' : _tableLabel(_tableId),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: chipText),
                        ),
                        const SizedBox(width: 6),
                        Icon(Icons.expand_more_rounded, size: 18, color: chipText.withOpacity(0.7)),
                      ]),
                    ),
                  );
                },
              ),
              const SizedBox(width: 12),
              const Text('Chạm để đổi bàn', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            ]),
          ),
          const Divider(height: 1),
          // Menu
          Expanded(
            child: StreamBuilder<List<MenuItemModel>>(
              stream: _menuService.streamMenuItems(),
              builder: (ctx, snap) {
                if (snap.hasError) return Center(
                    child: Text('Lỗi menu: ${snap.error}', style: const TextStyle(color: AppColors.error)));
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final all = snap.data!.where((m) => m.available).toList();
                final cats = ['Tất cả', ...all.map((m) => m.category).toSet().toList()..sort()];
                final byCat = _catFilter == 'Tất cả'
                    ? all : all.where((m) => m.category == _catFilter).toList();
                final filtered = _search.isEmpty
                    ? byCat
                    : byCat.where((m) => m.name.toLowerCase().contains(_search.toLowerCase())).toList();
                return Column(children: [
                  // Tìm món — giống ô tìm kiếm trong dialog "Thêm món"
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: TextField(
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        hintText: 'Tìm món...', isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF94A3B8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: AppColors.primary)),
                      ),
                    ),
                  ),
                  SizedBox(
                    height: 44,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      itemCount: cats.length,
                      itemBuilder: (_, i) {
                        final cat = cats[i];
                        final sel = _catFilter == cat;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => setState(() => _catFilter = cat),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 120),
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: sel ? AppColors.primary : AppColors.surface,
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(color: sel ? AppColors.primary : AppColors.divider),
                              ),
                              child: Text(cat, style: TextStyle(
                                color: sel ? Colors.white : AppColors.textSecondary,
                                fontSize: 12, fontWeight: sel ? FontWeight.w600 : FontWeight.w400,
                              )),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 160, childAspectRatio: 0.85,
                        crossAxisSpacing: 8, mainAxisSpacing: 8,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final it = filtered[i];
                        final qty = _cart
                            .where((e) => e.item.id == it.id)
                            .fold<int>(0, (s, e) => s + e.qty);
                        return _MenuCard(
                          item: it,
                          qtyInCart: qty,
                          onTap: () => _addItem(it),
                        );
                      },
                    ),
                  ),
                ]);
              },
            ),
          ),
        ]),
      ),
      // Thanh ngăn cách kéo được để chỉnh độ rộng menu/giỏ hàng
      MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) => setState(() {
            _cartWidth = (_cartWidth - d.delta.dx).clamp(240.0, 600.0);
          }),
          child: Container(
            width: 10,
            color: Colors.transparent,
            alignment: Alignment.center,
            child: Container(width: 1, color: AppColors.divider),
          ),
        ),
      ),
      // Giỏ hàng
      SizedBox(
        width: _cartWidth,
        child: Column(children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: AppColors.surface,
            child: Row(children: [
              const Icon(Icons.shopping_cart_outlined, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              const Text('Giỏ hàng', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const Spacer(),
              Text(_tableLabel(_tableId), style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: _cart.isEmpty
                ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.shopping_cart_outlined, size: 40, color: AppColors.divider),
                    SizedBox(height: 8),
                    Text('Chưa có món', style: TextStyle(color: AppColors.textHint)),
                  ]))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: _cart.length,
                    separatorBuilder: (_, __) => const Divider(height: 12),
                    // Vuốt ngang (trái hoặc phải) để xóa nhanh 1 món khỏi giỏ hàng.
                    itemBuilder: (_, i) => Dismissible(
                      key: ValueKey(_cart[i]),
                      direction: DismissDirection.horizontal,
                      // Chỉ cần kéo khoảng 1/3 chiều rộng là xóa được ngay (nhẹ tay hơn hẳn
                      // mặc định của Flutter là 40%, để chắc chắn kéo "phân nửa" luôn đủ để xóa).
                      dismissThresholds: const {
                        DismissDirection.startToEnd: 0.3,
                        DismissDirection.endToStart: 0.3,
                      },
                      // Chỉ hiện mảng đỏ trong phạm vi 30% chiều rộng (khớp ngưỡng xóa
                      // dismissThresholds bên dưới), không tô đỏ tràn hết cả dòng khi kéo.
                      background: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: 0.3,
                          child: Container(
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(left: 16),
                            decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                          ),
                        ),
                      ),
                      secondaryBackground: Align(
                        alignment: Alignment.centerRight,
                        child: FractionallySizedBox(
                          widthFactor: 0.3,
                          child: Container(
                            alignment: Alignment.centerRight,
                            padding: const EdgeInsets.only(right: 16),
                            decoration: BoxDecoration(color: AppColors.error, borderRadius: BorderRadius.circular(10)),
                            child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                          ),
                        ),
                      ),
                      onDismissed: (_) => _removeItem(i),
                      child: _CartRow(
                        entry: _cart[i],
                        onRemove: () => _removeItem(i),
                        onQtyChange: (d) => _changeQty(i, d),
                      ),
                    ),
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Tổng cộng', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: AppColors.textPrimary)),
                Text('${_vndFmt.format(_total)}đ', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: AppColors.primary)),
              ]),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _cart.isEmpty || _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send_rounded, size: 16),
                  label: Text(_submitting ? 'Đang gửi...' : 'Gửi đơn'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    ]);
  }
}

// ── Dialog chọn bàn (lưới, tô màu theo trạng thái) ──────────────────────────
class _TablePickerDialog extends StatefulWidget {
  final List<TableModel> tables;
  final String selectedId;
  final Set<String> occupiedIds;
  const _TablePickerDialog({
    required this.tables,
    required this.selectedId,
    required this.occupiedIds,
  });

  @override
  State<_TablePickerDialog> createState() => _TablePickerDialogState();
}

class _TablePickerDialogState extends State<_TablePickerDialog> {
  String _query = '';

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ]);

  @override
  Widget build(BuildContext context) {
    final filtered = widget.tables.where((t) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return t.id.toLowerCase().contains(q) || t.name.toLowerCase().contains(q);
    }).toList();

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.table_bar_rounded, color: AppColors.primary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Chọn bàn', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
            ]),
            const SizedBox(height: 8),
            TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Tìm số bàn...',
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 18),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: AppColors.primary),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(children: [
              _legendDot(const Color(0xFF94A3B8), 'Trống'),
              const SizedBox(width: 14),
              _legendDot(AppColors.success, 'Đang phục vụ'),
              const SizedBox(width: 14),
              _legendDot(const Color(0xFFF59E0B), 'Gọi phục vụ'),
              const SizedBox(width: 14),
              _legendDot(const Color(0xFF2563EB), 'Gọi tính tiền'),
            ]),
            const SizedBox(height: 12),
            Flexible(
              child: filtered.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('Không tìm thấy bàn nào', style: TextStyle(color: AppColors.textSecondary)),
                    )
                  : GridView.builder(
                      shrinkWrap: true,
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 100,
                        childAspectRatio: 1,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final t = filtered[i];
                        final occupied = widget.occupiedIds.contains(t.id);
                        final service = t.serviceRequest != null;
                        final bill = t.isBillRequest;
                        final selected = t.id == widget.selectedId;
                        final Color dot = bill
                            ? const Color(0xFF2563EB) // gọi tính tiền — xanh dương
                            : service
                            ? const Color(0xFFF59E0B) // gọi phục vụ — vàng
                            : (occupied ? AppColors.success : const Color(0xFF94A3B8)); // đang phục vụ — xanh / trống — xám
                        final Color tileBg = bill
                            ? const Color(0xFFDBEAFE) // nền xanh dương nhạt — gọi tính tiền
                            : service
                            ? const Color(0xFFFEF3C7) // nền vàng nhạt — gọi phục vụ
                            : (occupied
                                ? const Color(0xFFDCFCE7) // nền xanh nhạt — đang phục vụ
                                : AppColors.background);
                        return GestureDetector(
                          onTap: () => Navigator.of(context).pop(t.id),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 120),
                            decoration: BoxDecoration(
                              color: tileBg,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: dot, width: 1.5),
                            ),
                            child: Stack(children: [
                              Center(
                                child: Text(
                                  t.name,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: selected ? AppColors.primary : AppColors.textPrimary,
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  width: 8, height: 8,
                                  decoration: BoxDecoration(shape: BoxShape.circle, color: dot),
                                ),
                              ),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

// ── Menu Card ─────────────────────────────────────────────────────────────────
class _MenuCard extends StatelessWidget {
  final MenuItemModel item;
  final VoidCallback onTap;
  final int qtyInCart;
  const _MenuCard({required this.item, required this.onTap, this.qtyInCart = 0});

  @override
  Widget build(BuildContext context) {
    final selected = qtyInCart > 0;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          // Đã chọn → nền tô nhẹ + viền màu chủ đạo đậm hơn
          color: selected ? AppColors.primary.withValues(alpha: 0.08) : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : AppColors.divider,
            width: selected ? 2 : 1,
          ),
        ),
        child: Stack(children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(9)),
                child: Container(
                  width: double.infinity,
                  color: Colors.white, // nền trắng khớp ảnh sản phẩm, không lộ mảng màu 2 bên
                  child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                      ? CachedNetworkImage(imageUrl: item.imageUrl!, fit: BoxFit.contain,
                          width: double.infinity,
                          errorWidget: (_, __, ___) => const Center(
                              child: Icon(Icons.coffee_rounded, size: 36, color: AppColors.primary)))
                      : const Center(child: Icon(Icons.coffee_rounded, size: 36, color: AppColors.primary)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600,
                        color: selected ? AppColors.primary : AppColors.textPrimary)),
                const SizedBox(height: 2),
                Text('${_vndFmt.format(item.price)}đ',
                    style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w700)),
              ]),
            ),
          ]),
          // Badge số lượng đã chọn (góc trên phải)
          if (selected)
            Positioned(
              top: 6, right: 6,
              child: Container(
                padding: const EdgeInsets.all(4),
                constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  shape: BoxShape.circle,
                  boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 3, offset: Offset(0, 1))],
                ),
                alignment: Alignment.center,
                child: Text('$qtyInCart',
                    style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ── Cart Row ──────────────────────────────────────────────────────────────────
class _CartRow extends StatelessWidget {
  final _CartEntry entry;
  final VoidCallback onRemove;
  final void Function(int delta) onQtyChange;
  const _CartRow({required this.entry, required this.onRemove, required this.onQtyChange});

  @override
  Widget build(BuildContext context) {
    final img = entry.item.imageUrl;
    return Row(children: [
      // Ảnh sản phẩm
      Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: AppColors.background,
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: (img != null && img.isNotEmpty)
            ? CachedNetworkImage(imageUrl: img, fit: BoxFit.cover,
                errorWidget: (_, __, ___) => const Icon(Icons.coffee_rounded, size: 18, color: AppColors.primary))
            : const Icon(Icons.coffee_rounded, size: 18, color: AppColors.primary),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(entry.item.name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppColors.textPrimary),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        Text('${_vndFmt.format(entry.subtotal)}đ', style: const TextStyle(color: AppColors.primary, fontSize: 12)),
      ])),
      _QtyBtn(icon: Icons.remove, onTap: () => onQtyChange(-1)),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text('${entry.qty}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
      ),
      _QtyBtn(icon: Icons.add, onTap: () => onQtyChange(1)),
      const SizedBox(width: 4),
      GestureDetector(onTap: onRemove, child: const Icon(Icons.close, size: 16, color: AppColors.error)),
    ]);
  }
}

class _QtyBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _QtyBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24, height: 24,
        decoration: BoxDecoration(
          border: Border.all(color: AppColors.divider),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 14, color: AppColors.textSecondary),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  KDS TAB — giống 100% KitchenPage.jsx
// ═══════════════════════════════════════════════════════
class _KDSTab extends StatefulWidget {
  const _KDSTab();
  @override
  State<_KDSTab> createState() => _KDSTabState();
}

class _KDSTabState extends State<_KDSTab> {
  final _orderService    = OrderService();
  final _menuService     = MenuService();
  final _tableService    = TableService();
  final _discountService = DiscountService();
  final _invoiceService  = InvoiceService();
  Timer? _ticker;
  StreamSubscription? _menuSub;
  StreamSubscription? _tableSub;
  StreamSubscription? _discountSub;
  StreamSubscription? _ordersAudioSub;

  // Cache menu items để lấy ảnh — key = item.id
  Map<String, MenuItemModel> _menuCache = {};
  // Danh sách bàn (để đọc activeDiscount) — giống tables subscription trong web
  List<TableModel> _tables = [];
  // Danh sách mã giảm giá đang hoạt động
  List<DiscountModel> _discounts = [];

  // Bàn đang trong quá trình dọn
  final Set<String> _clearingTableIds = {};

  // Bàn đã xuất bill (giống billedTableIds trong web — local state)
  // Bàn/thẻ vừa xuất bill trên máy này (hiển thị ngay, chưa chờ Firestore):
  // key → mã các đơn nằm trong bill đó.
  final Map<String, Set<String>> _billedOrderIds = {};

  // ── Âm thanh + giọng đọc (giống useAudioNotification web) ──
  final AudioPlayer _notifPlayer = AudioPlayer();
  final AudioPlayer _warnPlayer  = AudioPlayer();
  // Giọng đọc — CHỈ dùng riêng cho cảnh báo "gọi phục vụ" (theo yêu cầu), 2 trường
  // hợp còn lại (đặt món, trễ món) chỉ phát âm thanh, không đọc giọng nói.
  // Ưu tiên giọng AI tự nhiên (Azure, nếu đã cấu hình) — lỗi/mất mạng/chưa cấu
  // hình thì tự rơi về giọng máy (flutter_tts) để không bao giờ bị câm.
  final AudioPlayer _voicePlayer = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  bool _audioUnlocked = true; // desktop: bật sẵn, không cần chạm mở khoá
  bool _audioSeeded = false;
  bool _ordersLoaded = false;
  Set<String> _prevOrderIds = {};
  Set<String> _prevServiceIds = {};
  List<OrderModel> _activeOrders = [];

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('vi-VN');
    // Thang tốc độ của flutter_tts trên iOS là 0.0–1.0, ~0.5 là tốc độ nói
    // bình thường (AVSpeechUtteranceDefaultSpeechRate). 0.9 quá nhanh, 0.42 lại
    // quá chậm nên nghe không tự nhiên — quay về gần mức bình thường.
    _tts.setSpeechRate(0.5);
    _tts.setVolume(1.0);
    _tts.setPitch(1.0);
    // Tự động chọn giọng vi-VN chất lượng cao nhất máy đang có (Enhanced/Premium
    // nghe tự nhiên hơn hẳn giọng Compact mặc định) — nếu máy chưa tải giọng
    // nâng cao thì vẫn dùng giọng mặc định, không lỗi gì.
    _pickBestViVoice();
    AzureTtsService.instance.load();
    FreeTtsService.instance.load();
    // Âm lượng tối đa cho chuông báo
    _notifPlayer.setVolume(1.0);
    _warnPlayer.setVolume(1.0);
    _notifPlayer.setReleaseMode(ReleaseMode.stop);
    _warnPlayer.setReleaseMode(ReleaseMode.stop);
    // Cập nhật timer mỗi phút (giống setInterval 60000 trong web) + cảnh báo đơn trễ
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_audioUnlocked) {
        for (final o in _activeOrders) {
          if (o.status == 'pending' && _elapsedMinutes(o.createdAt) >= 10) {
            _playWarning('Chú ý, bàn số ${o.tableId} đang bị trễ món.', asset: 'sounds/late_order.mp3');
            break;
          }
        }
      }
    });
    // Load menu items để lấy ảnh
    _menuSub = _menuService.streamMenuItems().listen((items) {
      if (mounted) setState(() => _menuCache = { for (final m in items) m.id: m });
    });
    // Load tables để lấy activeDiscount + phát chuông khi có gọi phục vụ mới
    _tableSub = _tableService.streamTables().listen((tables) {
      if (!mounted) return;
      // Khoá = bàn + loại yêu cầu → khách đổi "gọi phục vụ" sang "tính tiền" cũng báo lại
      final requesting = tables.where((t) => t.serviceRequest != null).toList();
      final serviceIds = requesting
          .map((t) => '${t.id}|${t.serviceRequestType}|${t.serviceRequestPayment}').toSet();
      if (_audioUnlocked) {
        for (final t in requesting) {
          if (!_prevServiceIds.contains('${t.id}|${t.serviceRequestType}|${t.serviceRequestPayment}')) {
            _playWarning(t.serviceRequestSpeech(t.id), asset: 'sounds/service_call.mp3', speak: true);
            break;
          }
        }
      }
      _prevServiceIds = serviceIds;
      setState(() => _tables = tables);
    }, onError: (e) {
      debugPrint('[KDS] tables stream error: $e');
    });
    // Load discounts đang hoạt động (giống discountService.subscribe web)
    _discountSub = _discountService.streamDiscounts().listen((discounts) {
      final now = DateTime.now();
      final filtered = discounts.where((d) {
        if (!d.active) return false;
        if (d.expiresAt != null && now.isAfter(d.expiresAt!)) return false;
        if (d.isMaxedOut) return false;
        return true;
      }).toList();
      if (mounted) setState(() => _discounts = filtered);
    }, onError: (e) {
      debugPrint('[KDS] discounts stream error: $e');
    });
    // MỘT listener DUY NHẤT cho orders — vừa dựng UI vừa phát chuông đơn mới
    _ordersAudioSub = activeOrdersQuery().snapshots().listen((snap) {
      final active = <OrderModel>[];
      for (final d in snap.docs) {
        try {
          final o = OrderModel.fromDoc(d);
          if (_kActive.contains(o.status)) active.add(o);
        } catch (_) {}
      }
      final ids = active.map((o) => o.id).toSet();
      // Chuông + giọng đọc khi có đơn mới (bỏ qua lần seed đầu)
      if (_audioSeeded) {
        final newOnes = active.where((o) => !_prevOrderIds.contains(o.id)).toList();
        if (newOnes.isNotEmpty && _audioUnlocked) {
          _safePlay(_notifPlayer, 'sounds/notification.mp3');
        }
      }
      _audioSeeded = true;
      _prevOrderIds = ids;
      if (mounted) setState(() {
        _activeOrders = active;
        _ordersLoaded = true;
      });
    }, onError: (e) {
      debugPrint('[KDS] orders stream error: $e');
      if (mounted) setState(() => _ordersLoaded = true);
    });
  }

  // Chọn giọng vi-VN chất lượng cao nhất đang có trên máy (iOS thường có nhiều
  // bản giọng cùng ngôn ngữ: Compact — robotic, và Enhanced/Premium — tự nhiên
  // hơn nhiều, giống Siri. Người dùng cần tự tải giọng nâng cao trong Settings
  // > Accessibility > Spoken Content > Voices > Vietnamese nếu máy chưa có).
  Future<void> _pickBestViVoice() async {
    try {
      final voices = await _tts.getVoices;
      if (voices is! List) return;
      Map<dynamic, dynamic>? best;
      for (final v in voices) {
        if (v is! Map) continue;
        final locale = (v['locale'] ?? '').toString().toLowerCase();
        if (!locale.startsWith('vi')) continue;
        final name = (v['name'] ?? '').toString().toLowerCase();
        final isHq = name.contains('enhanced') || name.contains('premium') || name.contains('neural');
        best ??= v;
        if (isHq) { best = v; break; }
      }
      if (best != null) {
        await _tts.setVoice({
          'name': best['name'].toString(),
          'locale': best['locale'].toString(),
        });
      }
    } catch (_) {}
  }

  void _safePlay(AudioPlayer p, String asset) {
    if (!NotificationSoundService.instance.enabled) return;
    try { p.play(AssetSource(asset)); } catch (_) {}
  }

  void _playWarning(String msg, {required String asset, bool speak = false}) {
    _safePlay(_warnPlayer, asset);
    if (speak && NotificationSoundService.instance.enabled) {
      _speakBestVoice(msg);
    }
  }

  // Thứ tự ưu tiên giọng đọc: (1) giọng AI miễn phí, không cần đăng ký — mặc
  // định bật sẵn, dùng ngay; (2) Azure nếu người dùng đã tự cấu hình Key riêng
  // (chất lượng cao hơn, có hạn mức riêng); (3) giọng máy (flutter_tts) — luôn
  // có sẵn, dùng khi cả hai bên trên lỗi/mất mạng, để không bao giờ bị câm.
  Future<void> _speakBestVoice(String msg) async {
    final usedFree = await FreeTtsService.instance.speak(msg, onPlayFile: (path) async {
      try { await _voicePlayer.play(DeviceFileSource(path)); } catch (_) {}
    });
    if (usedFree) return;
    final usedAzure = await AzureTtsService.instance.speak(msg, onPlayFile: (path) async {
      try { await _voicePlayer.play(DeviceFileSource(path)); } catch (_) {}
    });
    if (usedAzure) return;
    try { _tts.speak(msg); } catch (_) {}
  }

  void _unlockAudio() {
    // Desktop không cần unlock để phát, nhưng giữ overlay giống web
    _safePlay(_notifPlayer, 'sounds/notification.mp3');
    setState(() => _audioUnlocked = true);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _menuSub?.cancel();
    _tableSub?.cancel();
    _discountSub?.cancel();
    _ordersAudioSub?.cancel();
    _notifPlayer.dispose();
    _warnPlayer.dispose();
    _voicePlayer.dispose();
    _tts.stop();
    super.dispose();
  }

  // Tìm table doc theo id — khớp thô, khớp padStart(2,'0'), và khớp theo số
  // (xử lý "01" ↔ "1" mà web đôi khi bỏ sót)
  TableModel? _findTable(String tableId) {
    final raw = tableId.trim();
    final padded = raw.padLeft(2, '0');
    final numeric = int.tryParse(raw);
    TableModel? match;
    for (final t in _tables) {
      final isMatch = t.id == raw || t.id == padded ||
          (numeric != null && int.tryParse(t.id) == numeric);
      if (isMatch) {
        // Nếu có nhiều doc trùng bàn (vd "02" và "2"), ưu tiên doc ĐANG có mã giảm
        if (t.activeDiscount != null) return t;
        match ??= t;
      }
    }
    return match;
  }

  // Bàn đã xuất bill CHO CÁC ĐƠN ĐANG HIỆN — bill chỉ bao gồm những đơn có lúc
  // in bill; khách gọi thêm đơn SAU đó thì bàn quay lại "chưa xuất bill" (trước
  // đây tính theo cả bàn → đơn mới cũng bị hiện "đã xuất bill").
  bool _isBilled(String tableId, List<OrderModel> orders) =>
      _tableBilledFor(_findTable(tableId), _billedOrderIds[tableId], orders);

  // Bàn đang gọi phục vụ — giống web serviceRequestTableIds
  bool _hasServiceRequest(String tableId) => _findTable(tableId)?.serviceRequest != null;

  // Bàn mang về? (doc tables có type == 'takeaway', hoặc id "Mang về" cho đơn cũ)
  bool _isTakeawayTable(String baseId) {
    final t = _findTable(baseId);
    if (t != null && t.isTakeaway) return true;
    return baseId == 'Mang về';
  }

  // Cập nhật mã giảm giá ngay trên UI (optimistic) — không chờ Firestore round-trip
  void _applyDiscountLocally(String tableId, Map<String, dynamic>? disc) {
    final t = _findTable(tableId);
    setState(() {
      if (t == null) {
        // Bàn chưa có doc (vd "Mang về") — thêm entry tạm để badge hiện ngay
        if (disc != null) {
          _tables = [..._tables, TableModel(
            id: tableId, name: tableId, capacity: 4, status: 'available', activeDiscount: disc,
          )];
        }
      } else {
        _tables = _tables
            .map((x) => x.id == t.id ? x.copyWith(activeDiscount: disc, clearDiscount: disc == null) : x)
            .toList();
      }
    });
  }

  // Tương đương handleUpdateStatus trong web
  void _handleUpdateStatus(String orderId, String status) {
    _orderService.updateStatus(orderId, status);
  }

  // Tương đương handleOpenPayment trong web — mở InvoiceModal (xuất + in hóa đơn)
  // Web: lưu invoice + updateTableLastBilledAt + incrementUsage, KHÔNG đổi status đơn
  void _handleOpenPayment(BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {String? cardKey, bool isTakeaway = false}) {
    final billKey = cardKey ?? tableId;
    // Nhân viên đang đăng nhập (ghi vào hóa đơn để web hiển thị đúng)
    final staff = ctx.read<AuthProvider>().currentUser;
    final staffName = staff?.fullName;
    final staffId = staff?.id;
    final table = _findTable(tableId);
    final clearedAt = table?.clearedAt;
    DateTime? sessionStart;
    for (final o in tableOrders) {
      final t = o.createdAt;
      if (t == null) continue;
      if (sessionStart == null || t.isBefore(sessionStart)) sessionStart = t;
    }
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    // Sinh trước ID hóa đơn để preview hiển thị ĐÚNG mã sẽ in ra (không phải mã giả)
    final previewInvoiceId = _invoiceService.newInvoiceId();
    // Takeaway: mỗi đơn riêng → tra hóa đơn cũ theo ĐÚNG orderId của đơn này,
    // không theo tableId chung "Mang về" (tránh nhầm bill của đơn mang về khác).
    final existingFuture = (isTakeaway && firstOrderId != null)
        ? _invoiceService.getLatestActiveForOrder(firstOrderId)
        : _invoiceService.getLatestActiveForTable(
            tableId, clearedAt: clearedAt, sessionStart: sessionStart);

    showDialog(
      context: ctx,
      builder: (dCtx) => _InvoiceDialog(
        tableId: tableId,
        tableOrders: tableOrders,
        activeDiscount: table?.activeDiscount,
        existingInvoiceFuture: existingFuture,
        staffName: staffName,
        checkInAt: sessionStart,
        previewInvoiceId: previewInvoiceId,
        onPrint: (data) async {
          final act = table?.activeDiscount;
          final invoiceId = data['shouldSave'] == true ? previewInvoiceId : null;
          if (data['shouldSave'] == true) {
            await _invoiceService.saveInvoice({
              'orderId': firstOrderId,
              'tableId': tableId,
              'items': tableOrders.expand((o) => o.items.map((i) => i.toMap())).toList(),
              'subtotal': data['subtotal'],
              'vatPercent': data['vat'],
              'vatAmount': data['vatAmount'],
              'servicePercent': data['serviceCharge'],
              'serviceAmount': data['serviceAmount'],
              'discount': data['discount'],
              'discountCode': data['discountCode'],
              'totalAmount': data['finalTotal'],
            }, reason: data['reason'], previousInvoiceId: data['previousInvoiceId'],
               staffName: staffName, staffId: staffId, invoiceId: previewInvoiceId);
            // Takeaway: KHÔNG ghi lastBilledAt lên bàn chung (tránh mọi thẻ mang về bị "đã bill")
            if (!isTakeaway) {
              await _orderService.updateTableLastBilledAt(tableId,
                  orderIds: tableOrders.map((o) => o.id).toList());
            }
            final actId = act?['id'];
            if (actId != null) {
              await _discountService.incrementUsage(actId.toString());
            }
          }
          if (mounted) setState(() => _billedOrderIds[billKey] = tableOrders.map((o) => o.id).toSet());
          // In hóa đơn (mở hộp thoại in của hệ thống)
          try {
            await _printInvoice(tableId, tableOrders, data,
                staffName: staffName, checkInAt: sessionStart, invoiceId: invoiceId);
          } catch (e) {
            debugPrint('[KDS] print error: $e');
          }
          if (dCtx.mounted) Navigator.pop(dCtx);
          if (mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text(data['isPrint2'] == true ? 'Đã in lại & lưu hóa đơn!' : 'Đã xuất & in hóa đơn!'),
              backgroundColor: const Color(0xFF059669),
              duration: const Duration(seconds: 2),
            ));
            // Sau khi xuất & in hóa đơn xong → mở luôn popup Dọn bàn để nhân viên
            // xử lý tiếp cho nhanh, khỏi phải tự bấm thêm 1 lần nữa.
            _handleCompleteTable(ctx, tableId, tableOrders,
                isBilled: true, cardKey: cardKey, isTakeaway: isTakeaway);
          }
        },
      ),
    );
  }

  // In hóa đơn ra PDF rồi mở hộp thoại in của hệ thống (giống window.print web)
  // In hóa đơn: nếu đã cấu hình máy in nhiệt (ESC/POS qua LAN/Bluetooth, xem màn hình
  // "Cài đặt máy in") thì in thẳng qua máy in nhiệt; nếu chưa cấu hình thì in qua hộp
  // thoại in hệ thống (AirPrint) như trước đây.
  Future<void> _printInvoice(String tableId, List<OrderModel> tableOrders, Map<String, dynamic> data,
      {String? staffName, DateTime? checkInAt, String? invoiceId}) async {
    final items = tableOrders.expand((o) => o.items).toList();
    final subtotal = (data['subtotal'] as num?)?.toDouble() ?? 0;
    final serviceAmount = (data['serviceAmount'] as num?)?.toDouble() ?? 0;
    final discount = (data['discount'] as num?)?.toDouble() ?? 0;
    final total = (data['finalTotal'] as num?)?.toDouble() ?? 0;
    final code = data['discountCode']?.toString();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String fmtDt(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
    final timeStr = fmtDt(now); // Giờ ra — thời điểm xuất/in hóa đơn
    final checkInStr = checkInAt != null ? fmtDt(checkInAt) : null; // Giờ vào — đơn đầu tiên của phiên bàn
    // Mã hóa đơn ngắn để tra cứu — giống web: 8 ký tự cuối của id hóa đơn, viết hoa
    final invoiceCode = (invoiceId != null && invoiceId.length >= 8)
        ? invoiceId.substring(invoiceId.length - 8).toUpperCase()
        : invoiceId?.toUpperCase();

    // Mã QR chuyển khoản (VietQR) — chỉ tải khi đã bật + cấu hình đủ tài khoản.
    await BankQrService.instance.load();
    Uint8List? qrBytes;
    if (BankQrService.instance.shouldPrint) {
      try {
        final qrContent = invoiceCode != null ? 'HD $invoiceCode' : 'Ban $tableId';
        final qrUrl = BankQrService.instance.imageUrl(amount: total, content: qrContent);
        final resp = await http.get(Uri.parse(qrUrl)).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) qrBytes = resp.bodyBytes;
      } catch (e) {
        debugPrint('[QR] Lỗi tải mã QR chuyển khoản, bỏ qua: $e');
      }
    }

    await PrinterService.instance.load();
    if (PrinterService.instance.isConfigured) {
      final lines = <ReceiptLine>[
        ReceiptLine('EM COFFEE', bold: true, fontSize: 34, align: ReceiptAlign.center),
        ReceiptLine('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', fontSize: 20, align: ReceiptAlign.center),
        ReceiptLine('Hotline: 0742-619-457', fontSize: 20, align: ReceiptAlign.center),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        if (invoiceCode != null || checkInStr != null)
          ReceiptLine(
            invoiceCode != null ? 'Số hóa đơn: #$invoiceCode' : '',
            right: checkInStr != null ? 'Giờ vào: $checkInStr' : '',
            fontSize: 18,
          ),
        ReceiptLine('Bàn: $tableId', right: 'Giờ ra: $timeStr', fontSize: 20),
        if (staffName != null && staffName.isNotEmpty)
          ReceiptLine('Thu ngân: $staffName', fontSize: 18),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        ReceiptLine('Tên Món', mid: 'Đơn Giá', right: 'Thành Tiền', fontSize: 18, bold: true),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        ...items.map((it) => ReceiptLine('${it.quantity} x ${it.name}',
            mid: '${_vndFmt.format(it.price)}đ',
            right: '${_vndFmt.format(it.price * it.quantity)}đ', fontSize: 22)),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        if (serviceAmount > 0)
          ReceiptLine('Phí dịch vụ', right: '${_vndFmt.format(serviceAmount)}đ', fontSize: 22),
        if (discount > 0)
          ReceiptLine('Giảm giá${code != null ? ' [$code]' : ''}',
              right: '-${_vndFmt.format(discount)}đ', fontSize: 22),
        ReceiptLine('================================', fontSize: 18, align: ReceiptAlign.center),
        ReceiptLine('TỔNG CỘNG', right: '${_vndFmt.format(total)}đ', fontSize: 28, bold: true),
        ReceiptLine('', fontSize: 12),
        ReceiptLine('CẢM ƠN QUÝ KHÁCH!', bold: true, fontSize: 22, align: ReceiptAlign.center),
        ReceiptLine('HẸN GẶP LẠI', bold: true, fontSize: 22, align: ReceiptAlign.center),
        if (qrBytes != null) ...[
          ReceiptLine('', fontSize: 10),
          ReceiptLine('Quét mã để chuyển khoản', fontSize: 18, align: ReceiptAlign.center),
        ],
      ];
      try {
        final bytes = await ReceiptImageBuilder.buildEscPosBytes(lines: lines, qrImageBytes: qrBytes);
        await PrinterService.instance.sendBytes(bytes);
        return;
      } catch (e) {
        debugPrint('[PRINTER] Lỗi in máy in nhiệt, chuyển sang in AirPrint: $e');
        // rơi xuống nhánh in PDF/AirPrint bên dưới để không mất hóa đơn
      }
    }

    // Chưa cấu hình máy in nhiệt (hoặc in nhiệt lỗi) → in PDF qua hộp thoại hệ thống
    final doc = pw.Document(theme: await _receiptPdfTheme());
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80,
      build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Center(child: pw.Text('EM COFFEE', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', style: const pw.TextStyle(fontSize: 8))),
        pw.Center(child: pw.Text('Hotline: 0742-619-457', style: const pw.TextStyle(fontSize: 8))),
        pw.Divider(thickness: 1),
        if (invoiceCode != null || checkInStr != null)
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(invoiceCode != null ? 'Số hóa đơn: #$invoiceCode' : '', style: const pw.TextStyle(fontSize: 8)),
            pw.Text(checkInStr != null ? 'Giờ vào: $checkInStr' : '', style: const pw.TextStyle(fontSize: 8)),
          ]),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Bàn: $tableId', style: const pw.TextStyle(fontSize: 9)),
          pw.Text('Giờ ra: $timeStr', style: const pw.TextStyle(fontSize: 8)),
        ]),
        if (staffName != null && staffName.isNotEmpty)
          pw.Text('Thu ngân: $staffName', style: const pw.TextStyle(fontSize: 8)),
        pw.Divider(),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(flex: 3, child: pw.Text('Tên Món', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
          pw.Expanded(flex: 2, child: pw.Text('Đơn Giá', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
          pw.Expanded(flex: 2, child: pw.Text('Thành Tiền', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
        ]),
        pw.Divider(),
        ...items.map((it) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(flex: 3, child: pw.Text('${it.quantity} x ${it.name}', style: const pw.TextStyle(fontSize: 9))),
          pw.Expanded(flex: 2, child: pw.Text('${_vndFmt.format(it.price)}đ', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
          pw.Expanded(flex: 2, child: pw.Text('${_vndFmt.format(it.price * it.quantity)}đ', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
        ])),
        pw.Divider(),
        if (serviceAmount > 0) _pdfRow('Phí dịch vụ', '${_vndFmt.format(serviceAmount)}đ'),
        if (discount > 0) _pdfRow('Giảm giá${code != null ? ' [$code]' : ''}', '-${_vndFmt.format(discount)}đ'),
        pw.Divider(thickness: 1),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('TỔNG CỘNG', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text('${_vndFmt.format(total)}đ', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 12),
        pw.Center(child: pw.Text('CẢM ƠN QUÝ KHÁCH!', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('HẸN GẶP LẠI', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        if (qrBytes != null) ...[
          pw.SizedBox(height: 8),
          pw.Center(child: pw.Text('Quét mã để chuyển khoản', style: const pw.TextStyle(fontSize: 8))),
          pw.SizedBox(height: 4),
          pw.Center(child: pw.Image(pw.MemoryImage(qrBytes), width: 90, height: 90)),
        ],
      ]),
    ));
    await Printing.layoutPdf(onLayout: (format) async => doc.save());
  }

  // Tương đương handleCompleteTable + executeClearTable trong web — dọn bàn
  // Web: requireReason: !isBilled (chưa bill → lý do; đã bill → chọn PTTT)
  Future<void> _handleCompleteTable(
      BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {bool isBilled = false, String? cardKey, bool isTakeaway = false}) async {
    final clearKey = cardKey ?? tableId;
    final reasonCtrl = TextEditingController();
    final billOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    _PaymentResult? payment;
    if (isBilled) {
      // Đã xuất bill → bước THU TIỀN: bắt buộc chọn phương thức (không còn mặc
      // định "Tiền mặt"), nhập tiền khách đưa / xác nhận đã nhận chuyển khoản.
      final inv = billOrderId == null
          ? null
          : await _invoiceService.getLatestActiveForOrder(billOrderId);
      if (!mounted || !ctx.mounted) return;
      final billTotal = (inv?['totalAmount'] as num?)?.toDouble() ??
          tableOrders.fold<double>(0.0, (s, o) => s + o.totalPrice);
      payment = await showDialog<_PaymentResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _CollectPaymentDialog(tableId: tableId, total: billTotal),
      );
      if (payment == null || !mounted) return;
    } else {
      // Chưa xuất bill → bắt buộc nhập lý do dọn bàn
      final confirmed = await _askClearReason(ctx, tableId, reasonCtrl);
      if (confirmed != true || !mounted) return;
    }

    final orderIds = tableOrders.where((o) => _kActive.contains(o.status)).map((o) => o.id).toList();
    final totalAmount = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
    final currentUser = context.read<AuthProvider>().currentUser;
    // Dọn bàn CHƯA xuất bill mà bàn có tiền = đơn không vào doanh thu → bắt
    // buộc quản lý duyệt (chống thu tiền khách rồi dọn bàn không ghi bill).
    AccountModel? approver;
    if (!isBilled && totalAmount > 0) {
      approver = await requestManagerApproval(
        context,
        action: 'Dọn bàn $tableId chưa xuất bill — ${_vndFmt.format(totalAmount)}đ '
            'sẽ KHÔNG được tính vào doanh thu.\nLý do: ${reasonCtrl.text.trim()}',
      );
      if (approver == null || !mounted) return;
    }

    setState(() => _clearingTableIds.add(clearKey));
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    try {
      // Giống web: nếu đã bill → ghi PTTT vào hóa đơn TRƯỚC khi clear
      if (isBilled && firstOrderId != null) {
        try {
          await _invoiceService.recordPayment(
            firstOrderId,
            method: payment!.method,
            total: payment.total,
            cashReceived: payment.cashReceived,
            transferConfirmed: payment.transferConfirmed,
            staffId: currentUser?.id,
            staffName: currentUser?.fullName,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Không lưu được thông tin thu tiền, vui lòng thử lại'),
              backgroundColor: Color(0xFFDC2626)));
          }
          return;
        }
      }
      // completeAllOrdersAndFreeTable: đóng orders (closed) + clearedAt + clearLogs (nếu có lý do)
      await _orderService.completeAllOrdersAndFreeTable(
        tableId, orderIds,
        clearReason: isBilled ? null : reasonCtrl.text.trim(),
        totalAmount: totalAmount,
        staffId: currentUser?.id,
        staffName: currentUser?.fullName,
        staffRole: currentUser?.role,
        approvedById: approver?.id,
        approvedByName: approver?.fullName,
      );
      // Takeaway: KHÔNG clearTable (giữ nguyên session/QR cho đợt khách sau).
      // Bàn thường: clearTable → xoá cart + reset sessionToken → QR/URL bàn hết hiệu lực.
      if (!isTakeaway) {
        try {
          await _tableService.clearTable(tableId);
        } catch (e) {
          debugPrint('[KDS] clearTable error: $e');
        }
      }
      if (mounted) setState(() => _billedOrderIds.remove(clearKey));
    } finally {
      if (mounted) setState(() => _clearingTableIds.remove(clearKey));
    }
  }

  // Tương đương OrderDetailsModal trong web
  void _showDetailDialog(BuildContext ctx, String tableId, List<OrderModel> tableOrders) {
    showDialog(
      context: ctx,
      builder: (_) => _OrderDetailDialog(
        tableId: tableId,
        tableOrders: tableOrders,
        menuCache: _menuCache,
      ),
    );
  }

  // Tương đương EditOrderModal trong web — sửa món/số lượng/ghi chú của 1 đơn
  void _showEditOrderDialog(BuildContext ctx, OrderModel order) {
    showDialog(
      context: ctx,
      builder: (_) => _EditOrderDialog(
        order: order,
        menuCache: _menuCache,
        onSave: (items, vnd, usd) async {
          // Xoá hết món → xoá luôn đơn (tránh để lại đơn rỗng trên KDS)
          if (items.isEmpty) {
            await _orderService.deleteOrder(order.id);
          } else {
            await _orderService.updateOrderItems(order.id, items, vnd: vnd, usd: usd);
          }
        },
      ),
    );
  }

  // Tương đương AddProductModal trong web — thêm món vào bàn (tạo đơn mới source=staff_add)
  void _showAddProductDialog(BuildContext ctx, String tableId) {
    showDialog(
      context: ctx,
      builder: (_) => _AddProductDialog(
        tableId: tableId,
        menuCache: _menuCache,
        onConfirm: (items) async {
          // Giống web handleAddProducts → tạo đơn mới cho bàn
          await _orderService.createOrder(tableId: tableId, items: items);
          if (ctx.mounted) {
            final qty = items.fold<int>(0, (s, i) => s + i.quantity);
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('Đã thêm $qty món vào bàn $tableId!'),
              backgroundColor: const Color(0xFF059669),
              duration: const Duration(seconds: 2),
            ));
          }
        },
      ),
    );
  }

  // Tương đương Discount Picker trong web — chọn/gỡ mã giảm giá cho bàn
  void _showDiscountPicker(BuildContext ctx, String tableId, {required double orderTotal}) {
    final table = _findTable(tableId);
    showDialog(
      context: ctx,
      builder: (_) => _DiscountPickerDialog(
        tableId: tableId,
        discounts: _discounts,
        activeDiscountId: table?.activeDiscount?['id']?.toString(),
        orderTotal: orderTotal,
        onApply: (d) async {
          final data = {
            'id': d.id,
            'code': d.code,
            'type': d.type,
            'value': d.value,
            'maxDiscount': d.maxDiscount,
            'description': d.description,
          };
          _applyDiscountLocally(tableId, data);   // đổi UI ngay
          await _tableService.setTableDiscount(tableId, data);
        },
        onRemove: () async {
          _applyDiscountLocally(tableId, null);    // đổi UI ngay
          await _tableService.clearTableDiscount(tableId);
        },
      ),
    );
  }

  // Nhân viên đã xử lý gọi phục vụ (giống web clearServiceRequest)
  Future<void> _handleClearServiceRequest(String tableId) async {
    try {
      await _tableService.clearServiceRequest(tableId);
    } catch (e) {
      debugPrint('[KDS] clearServiceRequest error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Builder(builder: (ctx) {
        if (!_ordersLoaded) {
          return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(height: 16),
            Text('ĐANG CHUẨN BỊ...', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 2)),
          ]));
        }

        // Dùng chung 1 nguồn orders (đã parse+lọc trong listener)
        final allOrders = _activeOrders;

        // Gom theo bàn — giống groupedOrders trong web.
        // Bàn thường: gộp mọi đơn cùng bàn vào 1 thẻ.
        // Bàn MANG VỀ: mỗi đơn là 1 thẻ riêng (nhiều đợt khách không bị trộn đơn).
        final Map<String, List<OrderModel>> groupedOrders = {};
        final Map<String, String> groupBase = {}; // cardKey -> id bàn thật (cho thao tác)
        for (final o in allOrders) {
          final base = _canonTableId(o.tableId);
          final takeaway = _isTakeawayTable(base);
          final key = takeaway ? '$base${o.id}' : base;
          groupedOrders.putIfAbsent(key, () => []).add(o);
          groupBase[key] = base;
        }

        if (groupedOrders.isEmpty) {
          return Center(
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFE2E8F0)),
              ),
              child: const Text(
                'Hiện tại không có đơn hàng nào chờ chế biến.',
                style: TextStyle(color: Color(0xFF94A3B8)),
                textAlign: TextAlign.center,
              ),
            ),
          );
        }

        // Bàn đang gọi phục vụ nhưng CHƯA có đơn (giống web noOrderServiceTables)
        bool tableHasOrders(TableModel t) {
          for (final k in groupedOrders.keys) {
            if (k == t.id || k.trim().padLeft(2, '0') == t.id) return true;
          }
          return false;
        }
        final noOrderServiceTables =
            _tables.where((t) => t.serviceRequest != null && !tableHasOrders(t)).toList();

        // Grid layout — giống grid-cols-1 md:grid-cols-2 xl:grid-cols-3 trong web
        return Padding(
          padding: const EdgeInsets.all(8),
          child: LayoutBuilder(
            builder: (lctx, constraints) {
              final w = constraints.maxWidth;
              final cols = w < 640 ? 1 : w < 1280 ? 2 : 3;
              return SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // Banner: bàn gọi phục vụ chưa đặt món
                  ...noOrderServiceTables.map((t) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFFBEB),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: const Color(0xFFFCD34D), width: 2),
                      ),
                      child: Row(children: [
                        const Icon(Icons.notifications_active, size: 18, color: Color(0xFFB45309)),
                        const SizedBox(width: 8),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('Bàn ${t.id} — ${t.serviceRequestLabel}',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFB45309))),
                          const Text('Khách chưa đặt món', style: TextStyle(fontSize: 11, color: Color(0xFFD97706))),
                        ])),
                        GestureDetector(
                          onTap: () => _handleClearServiceRequest(t.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(color: const Color(0xFFFBBF24), borderRadius: BorderRadius.circular(12)),
                            child: const Text('Đã xử lý', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
                          ),
                        ),
                      ]),
                    ),
                  )),
                  // Lưới thẻ bàn
                  Wrap(
                    spacing: 8, runSpacing: 8,
                    children: groupedOrders.entries.map((entry) {
                      final cardKey     = entry.key;
                      final tableId     = groupBase[cardKey] ?? cardKey; // id bàn thật cho thao tác
                      final tableOrders = entry.value;
                      final takeaway    = _isTakeawayTable(tableId) && cardKey != tableId;
                      final tableTotal  = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
                      final isAllCompleted = tableOrders.every((o) => _isDone(o.status));
                      final isClearing = _clearingTableIds.contains(cardKey);
                      // Takeaway: theo dõi billed theo từng thẻ (đơn); bàn thường: theo bàn
                      final isBilled   = takeaway ? _billedOrderIds.containsKey(cardKey) : _isBilled(tableId, tableOrders);
                      final hasServiceRequest = takeaway ? false : _hasServiceRequest(tableId);
                      // Nhãn thẻ: bàn thường hiện "Bàn: 03"; takeaway hiện "Mang về • #<mã đơn>"
                      final String? displayLabel = takeaway
                          ? 'Mang về • #${tableOrders.first.id.length > 4 ? tableOrders.first.id.substring(tableOrders.first.id.length - 4) : tableOrders.first.id}'
                          : null;

                      return SizedBox(
                        width: (constraints.maxWidth - (cols - 1) * 8) / cols,
                        child: _TableCard(
                          tableId: tableId,
                          displayLabel: displayLabel,
                          tableOrders: tableOrders,
                          tableTotal: tableTotal,
                          isAllCompleted: isAllCompleted,
                          isClearing: isClearing,
                          isBilled: isBilled,
                          hasServiceRequest: hasServiceRequest,
                          serviceRequestMessage: _findTable(tableId)?.serviceRequestMessage ?? 'Khách đang gọi phục vụ!',
                          activeDiscount: takeaway ? null : _findTable(tableId)?.activeDiscount,
                          showDiscount: !takeaway,
                          menuCache: _menuCache,
                          onUpdateStatus: _handleUpdateStatus,
                          onPayment: () => _handleOpenPayment(ctx, tableId, tableOrders, cardKey: cardKey, isTakeaway: takeaway),
                          onClearTable: () => _handleCompleteTable(ctx, tableId, tableOrders, isBilled: isBilled, cardKey: cardKey, isTakeaway: takeaway),
                          onViewDetail: () => _showDetailDialog(ctx, tableId, tableOrders),
                          onAddProduct: () => _showAddProductDialog(ctx, tableId),
                          onEditOrder: (order) => _showEditOrderDialog(ctx, order),
                          onPickDiscount: () => _showDiscountPicker(ctx, tableId, orderTotal: tableTotal),
                          onClearServiceRequest: () => _handleClearServiceRequest(tableId),
                        ),
                      );
                    }).toList(),
                  ),
                ]),
              );
            },
          ),
        );
      }),
      if (!_audioUnlocked) _buildAudioOverlay(),
    ]);
  }

  // Overlay bật âm thanh (giống web) — che toàn màn hình cho tới khi bấm
  Widget _buildAudioOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        onTap: _unlockAudio,
        child: Container(
          color: const Color(0xCC0F172A),
          alignment: Alignment.center,
          child: Container(
            margin: const EdgeInsets.all(24),
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
            decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(24)),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 64, height: 64,
                decoration: const BoxDecoration(color: Color(0xFFFEF3C7), shape: BoxShape.circle),
                child: const Icon(Icons.notifications_active, size: 30, color: Color(0xFFD97706)),
              ),
              const SizedBox(height: 16),
              const Text('Bật âm thanh thông báo',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
              const SizedBox(height: 8),
              const Text('Nhấn để kích hoạt âm thanh cho toàn bộ ca làm việc',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                decoration: BoxDecoration(color: const Color(0xFFFBBF24), borderRadius: BorderRadius.circular(16)),
                child: const Text('Bật âm thanh',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  Table Card
// ═══════════════════════════════════════════════════════
class _TableCard extends StatelessWidget {
  final String tableId;
  final String? displayLabel; // nhãn hiển thị thay cho "Bàn: <id>" (dùng cho takeaway)
  final List<OrderModel> tableOrders;
  final double tableTotal;
  final bool isAllCompleted;
  final bool isClearing;
  final bool isBilled;
  final bool hasServiceRequest;
  final String serviceRequestMessage;
  final Map<String, dynamic>? activeDiscount;
  final bool showDiscount;
  final Map<String, MenuItemModel> menuCache;
  final void Function(String orderId, String status) onUpdateStatus;
  final VoidCallback onPayment;
  final VoidCallback onClearTable;
  final VoidCallback onViewDetail;
  final VoidCallback onAddProduct;
  final void Function(OrderModel order) onEditOrder;
  final VoidCallback onPickDiscount;
  final VoidCallback onClearServiceRequest;

  const _TableCard({
    required this.tableId,
    this.displayLabel,
    required this.tableOrders,
    required this.tableTotal,
    required this.isAllCompleted,
    required this.isClearing,
    required this.isBilled,
    required this.hasServiceRequest,
    this.serviceRequestMessage = 'Khách đang gọi phục vụ!',
    required this.activeDiscount,
    this.showDiscount = true,
    required this.menuCache,
    required this.onUpdateStatus,
    required this.onPayment,
    required this.onClearTable,
    required this.onViewDetail,
    required this.onAddProduct,
    required this.onEditOrder,
    required this.onPickDiscount,
    required this.onClearServiceRequest,
  });

  @override
  Widget build(BuildContext context) {
    // Giống web: hasServiceRequest → amber; isBilled → emerald; ngược lại → slate
    final cardBorderColor = hasServiceRequest
        ? const Color(0xFFFBBF24)
        : isBilled ? const Color(0xFF6EE7B7) : const Color(0xFFE2E8F0);
    final cardBgColor = isBilled ? const Color(0xFFF0FDF4) : Colors.white;

    return Container(
      constraints: const BoxConstraints(maxHeight: 600),
      decoration: BoxDecoration(
        color: cardBgColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cardBorderColor, width: hasServiceRequest ? 2 : 1),
        boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 4, offset: Offset(0, 1))],
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // Banner gọi phục vụ trong thẻ (giống web hasServiceRequest banner)
        if (hasServiceRequest)
          Container(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFBEB),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFFDE68A)),
            ),
            child: Row(children: [
              const Icon(Icons.notifications_active, size: 15, color: Color(0xFFB45309)),
              const SizedBox(width: 6),
              Expanded(child: Text(serviceRequestMessage,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB45309)))),
              GestureDetector(
                onTap: onClearServiceRequest,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(color: const Color(0xFFFBBF24), borderRadius: BorderRadius.circular(8)),
                  child: const Text('Đã xử lý', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
                ),
              ),
            ]),
          ),
        // ── Header ──
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(children: [
            // Hàng 1: icon bàn + tên bàn + 4 nút
            Row(children: [
              // Giống web: Armchair icon màu emerald khi isBilled
              Icon(Icons.chair_rounded, size: 18,
                  color: isBilled ? const Color(0xFF10B981) : const Color(0xFF94A3B8)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(displayLabel ?? 'Bàn: $tableId', style: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w700, color: Color(0xFF1E293B)),
                  overflow: TextOverflow.ellipsis),
              ),
              // Nút Thanh toán (CreditCard) — disabled nếu chưa xong
              _HeaderActionBtn(
                label: !isAllCompleted ? 'Đang pha' : 'Thanh toán',
                icon: Icons.credit_card_rounded,
                enabled: isAllCompleted && !isClearing,
                enabledColor: const Color(0xFF2563EB),
                enabledBg: const Color(0xFFEFF6FF),
                enabledBorder: const Color(0xFFBFDBFE),
                onTap: (isAllCompleted && !isClearing) ? onPayment : null,
              ),
              const SizedBox(width: 6),
              // Nút Dọn bàn (Trash2) — disabled nếu chưa xong
              _HeaderActionBtn(
                label: 'Dọn bàn',
                icon: isClearing ? null : Icons.delete_outline_rounded,
                loading: isClearing,
                enabled: isAllCompleted && !isClearing,
                enabledColor: const Color(0xFFDC2626),
                enabledBg: const Color(0xFFFFF1F2),
                enabledBorder: const Color(0xFFFECACA),
                onTap: (isAllCompleted && !isClearing) ? onClearTable : null,
              ),
              const SizedBox(width: 6),
              // Nút thêm món (+)
              _IconSqBtn(icon: Icons.add_circle_outline_rounded, tooltip: 'Thêm món vào bàn', onTap: onAddProduct),
              const SizedBox(width: 4),
              // Nút xem chi tiết (Eye)
              _IconSqBtn(icon: Icons.visibility_outlined, tooltip: 'Xem chi tiết', onTap: onViewDetail),
            ]),
            const SizedBox(height: 6),
            // Hàng 2: tổng tiền (VND + USD) + badge Mã GG — giống web
            // Có mã → hiện giá gốc gạch ngang + giá sau giảm (cập nhật theo mã)
            Row(children: [
              Expanded(child: Builder(builder: (_) {
                final disc = _calcDiscount(activeDiscount, tableTotal);
                final net = tableTotal - disc;
                if (activeDiscount != null && disc > 0) {
                  return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
                    Text('${_vndFmt.format(tableTotal)}đ',
                        style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8), decoration: TextDecoration.lineThrough)),
                    Text('${_vndFmt.format(net)}đ',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFEA580C))),
                    Text('≈ \$${(net / 26000).toStringAsFixed(2)} USD',
                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w400, color: Color(0xFF94A3B8))),
                  ]);
                }
                return RichText(text: TextSpan(
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEA580C)),
                  children: [
                    TextSpan(text: '${_vndFmt.format(tableTotal)}đ'),
                    TextSpan(
                      text: '  ≈ \$${tableOrders.fold(0.0, (s, o) => s + o.totalUsd).toStringAsFixed(2)} USD',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w400, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ));
              })),
              const SizedBox(width: 8),
              // Mã giảm giá — giống web: có activeDiscount → xanh + code + chevron, chưa có → dashed "Mã GG"
              // Ẩn với thẻ mang về (mỗi đơn riêng, không dùng mã cấp-bàn)
              if (showDiscount) GestureDetector(
                onTap: onPickDiscount,
                child: (activeDiscount != null)
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFD1FAE5),      // emerald-100
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFA7F3D0)),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          const Icon(Icons.local_offer, size: 9, color: Color(0xFF047857)),
                          const SizedBox(width: 3),
                          Text('${activeDiscount!['code'] ?? ''}',
                              style: const TextStyle(fontSize: 10, color: Color(0xFF047857), fontWeight: FontWeight.w800)),
                          const SizedBox(width: 2),
                          const Icon(Icons.keyboard_arrow_down, size: 9, color: Color(0xFF047857)),
                        ]),
                      )
                    : Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: const Color(0xFFCBD5E1)),
                        ),
                        child: const Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(Icons.local_offer_outlined, size: 9, color: Color(0xFF64748B)),
                          SizedBox(width: 3),
                          Text('Mã GG', style: TextStyle(fontSize: 10, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
                        ]),
                      ),
              ),
            ]),
          ]),
        ),
        const Divider(height: 1, thickness: 1, color: Color(0xFFF1F5F9)),

        // ── Danh sách đơn (scrollable) ──
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.all(8),
            itemCount: tableOrders.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => _OrderBlock(
              order: tableOrders[i],
              menuCache: menuCache,
              onUpdateStatus: onUpdateStatus,
              onEdit: () => onEditOrder(tableOrders[i]),
            ),
          ),
        ),

        // Badge "Đã xuất bill" — giống web: isBilled && <span>Đã xuất bill</span>
        if (isBilled)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF10B981),       // bg-emerald-500
                  borderRadius: BorderRadius.circular(20),
                  boxShadow: const [BoxShadow(color: Color(0x33059669), blurRadius: 6, offset: Offset(0, 2))],
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.check_circle_rounded, size: 12, color: Colors.white),
                  SizedBox(width: 5),
                  Text('Đã xuất bill', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.white)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }
}

// ── Header Action Button (Thanh toán / Dọn bàn) ───────────────────────────────
class _HeaderActionBtn extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool enabled;
  final bool loading;
  final Color enabledColor;
  final Color enabledBg;
  final Color enabledBorder;
  final VoidCallback? onTap;

  const _HeaderActionBtn({
    required this.label,
    required this.icon,
    required this.enabled,
    required this.enabledColor,
    required this.enabledBg,
    required this.enabledBorder,
    this.loading = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color  = enabled ? enabledColor         : const Color(0xFF94A3B8);
    final bg     = enabled ? enabledBg            : const Color(0xFFF1F5F9);
    final border = enabled ? enabledBorder        : const Color(0xFFE2E8F0);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (loading)
            SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color))
          else if (icon != null)
            Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
        ]),
      ),
    );
  }
}

// ── Icon square button (+, Eye) ───────────────────────────────────────────────
class _IconSqBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconSqBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE2E8F0)),
          ),
          child: Icon(icon, size: 14, color: const Color(0xFF64748B)),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  Order Block — mỗi đơn trong bàn
// ═══════════════════════════════════════════════════════
class _OrderBlock extends StatelessWidget {
  final OrderModel order;
  final Map<String, MenuItemModel> menuCache;
  final void Function(String orderId, String status) onUpdateStatus;
  final VoidCallback onEdit;

  const _OrderBlock({required this.order, required this.menuCache, required this.onUpdateStatus, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final elapsed = _elapsedMinutes(order.createdAt);
    final tc = _timerColor(elapsed);

    // Status badge: giống web — CHỈ pending = 'đang chờ', mọi status khác = 'hoàn thành'
    // Web: order.status === 'pending' ? 'đang chờ' : 'hoàn thành'
    final isPending   = order.status == 'pending';
    final statusLabel = isPending ? 'đang chờ' : 'hoàn thành';
    final statusBg    = isPending ? const Color(0xFFFEF3C7) : const Color(0xFFD1FAE5);
    final statusText  = isPending ? const Color(0xFFB45309) : const Color(0xFF065F46);

    // Payment badge: giống web — dùng paymentMethod === 'counter'
    // Web-created: paymentMethod = 'counter' | khác. Flutter cũ: fallback paymentType != 'PREPAID'
    final isCounter  = order.paymentMethod != null
        ? order.paymentMethod == 'counter'
        : order.paymentType != 'PREPAID';
    final payLabel   = isCounter ? 'Trả tại quầy' : 'Thanh toán khi nhận';
    final payBg      = isCounter ? const Color(0xFFDBEAFE) : const Color(0xFFF3E8FF); // blue-100 / purple-100
    final payText    = isCounter ? const Color(0xFF1D4ED8) : const Color(0xFF7E22CE); // blue-700 / purple-700

    // Source badge: giống web — source === 'staff_add' → tím "✦ Thêm tại quầy" (thay payment badge)
    final isStaffAdd = order.source == 'staff_add';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFC),        // bg-slate-50
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFF1F5F9)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Timer row (giống web: Clock + elapsed phút)
        Row(children: [
          Icon(Icons.access_time_rounded, size: 12, color: tc),
          const SizedBox(width: 3),
          Text(_fmtElapsed(elapsed), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tc)),
        ]),
        const SizedBox(height: 8),

        // Status + payment badges + nút sửa
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Wrap(spacing: 6, runSpacing: 4, children: [
              _Badge(label: statusLabel, bg: statusBg, textColor: statusText),
              // Giống web: staff_add → "✦ Thêm tại quầy" (tím), ngược lại → payment badge
              if (isStaffAdd)
                _Badge(label: '✦ Thêm tại quầy', bg: const Color(0xFFEDE9FE), textColor: const Color(0xFF6D28D9))
              else
                _Badge(label: payLabel, bg: payBg, textColor: payText),
              // Badge mã giảm trên đơn (giống web: order.discountCode)
              if (order.discountCode != null && order.discountCode!.isNotEmpty)
                _Badge(
                  label: '${order.discountCode} (-${_vndFmt.format(order.discountAmount)}đ)',
                  bg: const Color(0xFFD1FAE5), textColor: const Color(0xFF047857)),
            ]),
          ),
          GestureDetector(
            onTap: onEdit, // Giống web: setEditingOrder(order) → mở EditOrderModal
            child: const Padding(
              padding: EdgeInsets.all(2),
              child: Icon(Icons.edit_outlined, size: 14, color: Color(0xFF94A3B8)),
            ),
          ),
        ]),
        const SizedBox(height: 10),

        // Items list (giống web: order.items.map)
        ...order.items.indexed.map((entry) {
          final itemIdx = entry.$1;
          final item = entry.$2;
          // item.image → menu theo id → menu theo tên
          final imageUrl = _resolveItemImage(item, menuCache);

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // Line ngăn cách rõ ràng giữa các món (trừ món đầu tiên)
              if (itemIdx > 0)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Divider(color: Color(0xFFE2E8F0), height: 1, thickness: 1),
                ),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Ảnh sản phẩm 40×40 (giống web: w-10 h-10)
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (imageUrl != null && imageUrl.isNotEmpty)
                      ? CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)))
                      : const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    // Số lượng + tên món (giống web: qty x name + badge size/sweetness)
                    Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, runSpacing: 2, children: [
                      RichText(
                        text: TextSpan(
                          style: const TextStyle(fontSize: 13, color: Color(0xFF1E293B), fontWeight: FontWeight.w600),
                          children: [
                            TextSpan(
                              text: '${item.quantity}x ',
                              style: const TextStyle(color: Color(0xFFEA580C), fontWeight: FontWeight.w700),
                            ),
                            TextSpan(text: item.name),
                          ],
                        ),
                      ),
                      // Badge size — giống web: bg-orange-100 text-orange-700
                      if (item.size != null && item.size!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFEDD5), borderRadius: BorderRadius.circular(4)),
                          child: Text(item.size!.toUpperCase(),
                              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFC2410C))),
                        ),
                      // Badge sweetness — giống web: bg-amber-100 text-amber-700
                      if (item.sweetness != null && item.sweetness!.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(4)),
                          child: Text(item.sweetness!,
                              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
                        ),
                    ]),
                  ]),
                ),
              ]),
              // Ghi chú (giống web: ml-[52px] red box)
              if (item.note != null && item.note!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 52, top: 4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF1F2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: const Color(0xFFFECACA)),
                    ),
                    child: Text(
                      'Ghi chú: ${item.note}',
                      style: const TextStyle(fontSize: 10, color: Color(0xFFDC2626), fontStyle: FontStyle.italic),
                    ),
                  ),
                ),
            ]),
          );
        }),

        // Tổng đơn — giống web: border-t dashed, text-right, có dòng USD
        const Padding(
          padding: EdgeInsets.only(top: 4),
          child: Divider(color: Color(0xFFE2E8F0), height: 1),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              const Text('Tổng đơn: ', style: TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              Text('${_vndFmt.format(order.totalPrice)}đ',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
            ]),
            // Dòng USD — giống web: ≈ $X.XX USD (đọc từ totalAmount.usd)
            Text(
              '≈ \$${order.totalUsd.toStringAsFixed(2)} USD',
              style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8)),
            ),
          ]),
        ),

        // Nút "Hoàn thành" — giống web: CHỈ hiện khi status === 'pending'
        // Web: order.status === 'pending' && <button onClick={() => handleUpdateStatus(order.id, 'completed')}>Hoàn thành</button>
        if (order.status == 'pending') ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: _HoanThanhBtn(order: order, onUpdateStatus: onUpdateStatus),
          ),
        ],
      ]),
    );
  }
}

// ── Nút Hoàn thành ────────────────────────────────────────────────────────────
class _HoanThanhBtn extends StatefulWidget {
  final OrderModel order;
  final void Function(String orderId, String status) onUpdateStatus;
  const _HoanThanhBtn({required this.order, required this.onUpdateStatus});

  @override
  State<_HoanThanhBtn> createState() => _HoanThanhBtnState();
}

class _HoanThanhBtnState extends State<_HoanThanhBtn> {
  bool _loading = false;

  // Giống web 100%: handleUpdateStatus(order.id, 'completed')
  String get _nextStatus => 'completed';

  // Giống web: label luôn là "Hoàn thành"
  String get _btnLabel => 'Hoàn thành';

  Future<void> _tap() async {
    setState(() => _loading = true);
    try {
      widget.onUpdateStatus(widget.order.id, _nextStatus);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _loading ? null : _tap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF059669),          // emerald-600
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          if (_loading)
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
          else
            const Icon(Icons.check_rounded, size: 14, color: Colors.white),
          const SizedBox(width: 6),
          Text(_btnLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white)),
        ]),
      ),
    );
  }
}

// ─── Badge ────────────────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  final String label;
  final Color bg;
  final Color textColor;
  const _Badge({required this.label, required this.bg, required this.textColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: textColor)),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  Payment Dialog — tương đương InvoiceModal trong web
// ═══════════════════════════════════════════════════════
class _PaymentDialog extends StatefulWidget {
  final String tableId;
  final List<OrderModel> tableOrders;
  final Map<String, dynamic>? activeDiscount;
  final Future<void> Function(String? paymentMethod) onConfirm;
  const _PaymentDialog({required this.tableId, required this.tableOrders, required this.activeDiscount, required this.onConfirm});

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String _paymentMethod = 'Tiền mặt';
  bool _loading = false;

  double get _subtotal => widget.tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
  double get _discount => _calcDiscount(widget.activeDiscount, _subtotal);
  double get _total => _subtotal - _discount;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440, maxHeight: 600),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.all(20),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(children: [
              const Icon(Icons.receipt_long_rounded, color: Color(0xFF2563EB), size: 22),
              const SizedBox(width: 10),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Thanh toán - Bàn ${widget.tableId}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: Color(0xFF1E293B))),
                Text('${widget.tableOrders.length} đơn hàng',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
              ])),
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: const Icon(Icons.close, color: Color(0xFF94A3B8)),
              ),
            ]),
          ),
          // Items
          Flexible(
            child: ListView(padding: const EdgeInsets.all(16), children: [
              ...widget.tableOrders.expand((o) => o.items).toList().indexed.map((entry) {
                final itemIdx = entry.$1;
                final item = entry.$2;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Line ngăn cách rõ ràng giữa các món (trừ món đầu tiên)
                  if (itemIdx > 0)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 8),
                      child: Divider(color: Color(0xFFE2E8F0), height: 1, thickness: 1),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(children: [
                      Container(
                        width: 32, height: 32,
                        decoration: BoxDecoration(
                          color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Icon(Icons.restaurant, size: 14, color: Color(0xFF94A3B8)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${item.quantity}x ${item.name}',
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Color(0xFF1E293B)))),
                      Text('${_vndFmt.format(item.price * item.quantity)}đ',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
                    ]),
                  ),
                ]);
              }),
              const Divider(height: 24),
              // Tạm tính
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Tạm tính', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                Text('${_vndFmt.format(_subtotal)}đ',
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
              ]),
              // Dòng giảm giá — chỉ hiện khi có mã áp dụng (giống web InvoiceModal)
              if (widget.activeDiscount != null && _discount > 0) ...[
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.local_offer, size: 12, color: Color(0xFF059669)),
                    const SizedBox(width: 4),
                    Text('Giảm giá (${widget.activeDiscount!['code'] ?? ''})',
                        style: const TextStyle(fontSize: 13, color: Color(0xFF059669), fontWeight: FontWeight.w600)),
                  ]),
                  Text('-${_vndFmt.format(_discount)}đ',
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF059669))),
                ]),
              ],
              const SizedBox(height: 8),
              // Tổng cộng (sau giảm)
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                const Text('Tổng cộng', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: Color(0xFF1E293B))),
                Text('${_vndFmt.format(_total)}đ',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18, color: Color(0xFF2563EB))),
              ]),
              const SizedBox(height: 16),
              // Phương thức thanh toán
              const Text('Phương thức thanh toán', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: Color(0xFF1E293B))),
              const SizedBox(height: 8),
              ...['Tiền mặt', 'Chuyển khoản'].map((m) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _paymentMethod = m),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: _paymentMethod == m ? const Color(0xFFEFF6FF) : Colors.white,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: _paymentMethod == m ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                        width: _paymentMethod == m ? 2 : 1,
                      ),
                    ),
                    child: Row(children: [
                      Icon(
                        m == 'Tiền mặt' ? Icons.payments_outlined
                            : m == 'Chuyển khoản' ? Icons.account_balance_outlined
                            : Icons.credit_card_rounded,
                        size: 16,
                        color: _paymentMethod == m ? const Color(0xFF2563EB) : const Color(0xFF94A3B8),
                      ),
                      const SizedBox(width: 8),
                      Text(m, style: TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13,
                        color: _paymentMethod == m ? const Color(0xFF2563EB) : const Color(0xFF1E293B),
                      )),
                      const Spacer(),
                      if (_paymentMethod == m)
                        const Icon(Icons.check_circle, size: 18, color: Color(0xFF2563EB)),
                    ]),
                  ),
                ),
              )),
            ]),
          ),
          // Footer
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE2E8F0))),
            ),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _loading ? null : () => Navigator.pop(context),
                  child: const Text('Huỷ'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _loading ? null : () async {
                    setState(() => _loading = true);
                    await widget.onConfirm(_paymentMethod);
                    // onConfirm đã pop dialog → guard mounted tránh setState sau dispose
                    if (mounted) setState(() => _loading = false);
                  },
                  icon: _loading
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.check_rounded, size: 18),
                  label: Text(_loading ? 'Đang xử lý...' : 'Xác nhận thanh toán'),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════
//  Order Detail Dialog — giống 100% OrderDetailsModal (web)
// ═══════════════════════════════════════════════════════
class _OrderDetailDialog extends StatelessWidget {
  final String tableId;
  final List<OrderModel> tableOrders;
  final Map<String, MenuItemModel> menuCache;

  const _OrderDetailDialog({
    required this.tableId,
    required this.tableOrders,
    required this.menuCache,
  });

  @override
  Widget build(BuildContext context) {
    // Gộp items, gán status order cha vào từng item (giống web flatMap)
    final allItems = <_DetailItem>[];
    for (final o in tableOrders) {
      for (final it in o.items) {
        allItems.add(_DetailItem(item: it, status: o.status));
      }
    }
    final totalItems     = allItems.length;
    final completedItems = allItems.where((i) => _isDone(i.status)).length;
    final pendingItems   = totalItems - completedItems;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 720),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 16),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9))),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_titleCase('Chi tiết bàn $tableId'),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                  const SizedBox(height: 2),
                  const Text('Theo dõi tiến độ pha chế',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B), fontWeight: FontWeight.w500)),
                ])),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(width: 36, height: 36, alignment: Alignment.center,
                    child: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8))),
                ),
              ]),
              const SizedBox(height: 16),
              // Dashboard TỔNG / XONG / CHỜ
              Row(children: [
                _statBox('TỔNG', totalItems, const Color(0xFFF1F5F9), const Color(0xFF64748B), const Color(0xFF1E293B), null),
                const SizedBox(width: 8),
                _statBox('XONG', completedItems, const Color(0xFFECFDF5), const Color(0xFF059669), const Color(0xFF059669), const Color(0xFFD1FAE5)),
                const SizedBox(width: 8),
                _statBox('CHỜ', pendingItems, const Color(0xFFFFFBEB), const Color(0xFFD97706), const Color(0xFFD97706), const Color(0xFFFDE68A)),
              ]),
            ]),
          ),
          // Danh sách item
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.all(20),
              itemCount: allItems.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (_, i) {
                final di = allItems[i];
                final item = di.item;
                final isCompleted = _isDone(di.status);
                final imageUrl = _resolveItemImage(item, menuCache);
                return Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isCompleted ? const Color(0xFFECFDF5) : const Color(0xFFF8FAFC),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: isCompleted ? const Color(0xFFD1FAE5) : const Color(0xFFF1F5F9)),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    // Ảnh 56x56
                    Opacity(
                      opacity: isCompleted ? 0.6 : 1.0,
                      child: Container(
                        width: 56, height: 56,
                        decoration: BoxDecoration(color: const Color(0xFFF1F5F9),
                          borderRadius: BorderRadius.circular(12), border: Border.all(color: const Color(0xFFE2E8F0))),
                        clipBehavior: Clip.antiAlias,
                        child: (imageUrl != null && imageUrl.isNotEmpty)
                            ? CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover,
                                errorWidget: (_, __, ___) => const Icon(Icons.restaurant, size: 22, color: Color(0xFF94A3B8)))
                            : const Icon(Icons.restaurant, size: 22, color: Color(0xFF94A3B8)),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(
                          child: Text(item.name, style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w700,
                            color: isCompleted ? const Color(0xFF065F46) : const Color(0xFF1E293B),
                            decoration: isCompleted ? TextDecoration.lineThrough : null,
                            decorationColor: const Color(0xFF6EE7B7),
                          )),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: isCompleted ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                            borderRadius: BorderRadius.circular(20)),
                          child: Text(isCompleted ? 'ĐÃ XONG' : 'ĐANG CHỜ', style: TextStyle(
                            fontSize: 9, fontWeight: FontWeight.w800,
                            color: isCompleted ? Colors.white : const Color(0xFF475569))),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: const Color(0xFFE2E8F0)),
                            boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 2)]),
                          child: Text('x${item.quantity}', style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                        ),
                      ]),
                      if ((item.size != null && item.size!.isNotEmpty) ||
                          (item.note != null && item.note!.isNotEmpty)) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 4, children: [
                          if (item.size != null && item.size!.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: const Color(0xFFF0F9FF),
                                borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFE0F2FE))),
                              child: Text('Size: ${item.size!.toUpperCase()}', style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF0369A1))),
                            ),
                          if (item.note != null && item.note!.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(6), border: Border.all(color: const Color(0xFFFFEDD5))),
                              child: Text('Note: ${item.note}', style: const TextStyle(
                                fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFC2410C))),
                            ),
                        ]),
                      ],
                    ])),
                  ]),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  Widget _statBox(String label, int value, Color bg, Color labelColor, Color valueColor, Color? border) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10),
          border: border != null ? Border.all(color: border) : null),
        child: Column(children: [
          Text(label, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1, color: labelColor)),
          const SizedBox(height: 2),
          Text('$value', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: valueColor)),
        ]),
      ),
    );
  }
}

class _DetailItem {
  final OrderItem item;
  final String status;
  _DetailItem({required this.item, required this.status});
}

// ═══════════════════════════════════════════════════════
//  Edit Order Dialog — giống 100% EditOrderModal (web)
// ═══════════════════════════════════════════════════════
class _EditOrderDialog extends StatefulWidget {
  final OrderModel order;
  final Map<String, MenuItemModel> menuCache;
  final Future<void> Function(List<OrderItem> items, double vnd, double usd) onSave;
  const _EditOrderDialog({required this.order, required this.menuCache, required this.onSave});

  @override
  State<_EditOrderDialog> createState() => _EditOrderDialogState();
}

class _EditOrderDialogState extends State<_EditOrderDialog> {
  late List<_EditItem> _items;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _items = widget.order.items.map((i) => _EditItem(
      id: i.id, name: i.name, price: i.price, qty: i.quantity,
      note: i.note ?? '', image: i.image, size: i.size, sweetness: i.sweetness,
    )).toList();
  }

  @override
  void dispose() {
    for (final it in _items) { it.noteCtrl.dispose(); }
    super.dispose();
  }

  double get _totalVnd => _items.fold(0.0, (s, i) => s + i.price * i.qty);

  void _changeQty(int idx, int delta) =>
      setState(() => _items[idx].qty = (_items[idx].qty + delta).clamp(1, 999));

  void _remove(int idx) {
    _items[idx].noteCtrl.dispose();
    setState(() => _items.removeAt(idx));
  }

  static String _itemKey(String id, String name, String? size, String? sweetness) =>
      '$id|$name|${size ?? ''}|${sweetness ?? ''}';

  /// Các món bị BỚT số lượng hoặc XÓA so với đơn gốc.
  List<Map<String, dynamic>> _reductions() {
    final before = <String, int>{};
    final ref = <String, OrderItem>{};
    for (final i in widget.order.items) {
      final k = _itemKey(i.id, i.name, i.size, i.sweetness);
      before[k] = (before[k] ?? 0) + i.quantity;
      ref[k] = i;
    }
    final after = <String, int>{};
    for (final e in _items) {
      final k = _itemKey(e.id, e.name, e.size, e.sweetness);
      after[k] = (after[k] ?? 0) + e.qty;
    }
    final out = <Map<String, dynamic>>[];
    before.forEach((k, q) {
      final a = after[k] ?? 0;
      if (a < q) {
        final it = ref[k]!;
        out.add({
          'name': it.name,
          if (it.size != null && it.size!.isNotEmpty) 'size': it.size,
          'price': it.price,
          'qtyBefore': q,
          'qtyAfter': a,
        });
      }
    });
    return out;
  }

  /// Đơn đã được xuất bill chưa (bill riêng của đơn, hoặc bill của bàn xuất
  /// SAU khi đơn được tạo — tức bill này đã bao gồm đơn).
  Future<bool> _isBilled() async {
    final inv = InvoiceService();
    final o = widget.order;
    if (await inv.getLatestActiveForOrder(o.id) != null) return true;
    return await inv.getLatestActiveForTable(o.tableId, sessionStart: o.createdAt) != null;
  }

  Future<void> _save() async {
    final staff = context.read<AuthProvider>().currentUser;
    final reductions = _reductions();
    final isDelete = _items.isEmpty;
    String? reason;
    AccountModel? approver;

    // Hủy / bớt món → bắt buộc lý do; nếu đơn ĐÃ xuất bill → thêm quản lý duyệt
    // (bớt món sau khi khách trả tiền là kiểu thất thoát phổ biến nhất).
    if (reductions.isNotEmpty) {
      final desc = reductions
          .map((r) => '• ${r['name']}${r['size'] != null ? ' (${r['size']})' : ''}: '
              '${r['qtyBefore']} → ${r['qtyAfter']}')
          .join('\n');
      reason = await promptRequiredReason(
        context,
        title: isDelete ? 'Xóa đơn' : 'Hủy / bớt món',
        message: 'Nhập lý do cho thay đổi sau:\n$desc',
      );
      if (reason == null || !mounted) return;
      setState(() => _saving = true);
      final billed = await _isBilled();
      if (!mounted) return;
      if (billed) {
        approver = await requestManagerApproval(
          context,
          action: 'Đơn này ĐÃ XUẤT BILL. ${isDelete ? 'Xóa đơn' : 'Hủy / bớt món'} '
              '(${_vndFmt.format(widget.order.totalPrice)}đ → ${_vndFmt.format(_totalVnd)}đ).\n'
              'Lý do: $reason',
        );
        if (!mounted) return;
        if (approver == null) {
          setState(() => _saving = false);
          return;
        }
      }
    }

    setState(() => _saving = true);
    try {
      final items = _items.map((e) => OrderItem(
        id: e.id, name: e.name, quantity: e.qty, price: e.price,
        note: e.note.isEmpty ? null : e.note, image: e.image, size: e.size, sweetness: e.sweetness,
      )).toList();
      final vnd = _totalVnd;
      await widget.onSave(items, vnd, double.parse((vnd / 26000).toStringAsFixed(2)));
      if (reductions.isNotEmpty) {
        await AuditService().log(
          action: isDelete ? AuditService.orderDeleted : AuditService.orderItemsReduced,
          staff: staff,
          approvedBy: approver,
          tableId: widget.order.tableId,
          orderId: widget.order.id,
          reason: reason,
          amountBefore: widget.order.totalPrice,
          amountAfter: vnd,
          details: {
            'afterBill': approver != null,
            'reducedItems': reductions,
            // Đơn bị xóa hẳn khỏi Firestore → giữ lại bản đầy đủ để đối soát.
            if (isDelete) 'deletedItems': widget.order.items.map((i) => i.toMap()).toList(),
          },
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Có lỗi xảy ra, vui lòng thử lại.'), backgroundColor: Color(0xFFDC2626)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.order.id;
    final shortId = id.length > 6 ? id.substring(id.length - 6) : id;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 640),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFE2E8F0)))),
            child: Row(children: [
              Expanded(child: Text('Sửa đơn #$shortId',
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
              GestureDetector(onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, size: 20, color: Color(0xFF64748B))),
            ]),
          ),
          Flexible(
            child: _items.isEmpty
                ? const Padding(padding: EdgeInsets.all(32),
                    child: Text('Đơn không còn món nào', style: TextStyle(color: Color(0xFF94A3B8))))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: _items.length,
                    separatorBuilder: (_, __) => const Divider(height: 20, color: Color(0xFFF1F5F9)),
                    itemBuilder: (_, i) {
                      final it = _items[i];
                      String? imageUrl = (it.image != null && it.image!.isNotEmpty) ? it.image : widget.menuCache[it.id]?.imageUrl;
                      if (imageUrl == null || imageUrl.isEmpty) {
                        for (final m in widget.menuCache.values) {
                          if (m.name == it.name && m.imageUrl != null && m.imageUrl!.isNotEmpty) { imageUrl = m.imageUrl; break; }
                        }
                      }
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE2E8F0))),
                            clipBehavior: Clip.antiAlias,
                            child: (imageUrl != null && imageUrl.isNotEmpty)
                                ? CachedNetworkImage(imageUrl: imageUrl, fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) => const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)))
                                : const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)),
                          ),
                          const SizedBox(width: 12),
                          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(it.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B))),
                            if (it.size != null && it.size!.isNotEmpty) ...[
                              const SizedBox(height: 3),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                decoration: BoxDecoration(color: const Color(0xFFFFEDD5), borderRadius: BorderRadius.circular(4)),
                                child: Text(it.size!.toUpperCase(), style: const TextStyle(
                                  fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFC2410C))),
                              ),
                            ],
                          ])),
                          Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(color: const Color(0xFFF8FAFC), borderRadius: BorderRadius.circular(8)),
                            child: Row(mainAxisSize: MainAxisSize.min, children: [
                              _sqIcon(Icons.remove, () => _changeQty(i, -1)),
                              SizedBox(width: 26, child: Text('${it.qty}', textAlign: TextAlign.center,
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700))),
                              _sqIcon(Icons.add, () => _changeQty(i, 1)),
                              const SizedBox(width: 2),
                              _sqIcon(Icons.delete_outline, () => _remove(i), color: const Color(0xFFDC2626)),
                            ]),
                          ),
                        ]),
                        Padding(
                          padding: const EdgeInsets.only(left: 52, top: 8),
                          child: TextField(
                            controller: it.noteCtrl,
                            onChanged: (v) => it.note = v,
                            style: const TextStyle(fontSize: 12),
                            decoration: InputDecoration(
                              hintText: 'Thêm ghi chú...',
                              hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                              filled: true, fillColor: const Color(0xFFF8FAFC), isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8),
                                borderSide: const BorderSide(color: Color(0xFFF97316))),
                            ),
                          ),
                        ),
                      ]);
                    },
                  ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE2E8F0)))),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  // Rỗng → nút đỏ "Xoá đơn"; còn món → nút xanh "Lưu thay đổi"
                  backgroundColor: _items.isEmpty ? const Color(0xFFDC2626) : const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  disabledBackgroundColor: const Color(0xFF94A3B8),
                ),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Icon(_items.isEmpty ? Icons.delete_outline : Icons.save_outlined, size: 18),
                label: Text(
                  _saving ? 'Đang lưu...' : (_items.isEmpty ? 'Xoá đơn' : 'Lưu thay đổi'),
                  style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _sqIcon(IconData icon, VoidCallback onTap, {Color color = const Color(0xFF475569)}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque, // cả ô 26px đều nhận chạm (kể cả vùng trống)
      onTap: onTap,
      child: Container(width: 26, height: 26, alignment: Alignment.center, child: Icon(icon, size: 16, color: color)));
  }
}

class _EditItem {
  final String id;
  final String name;
  final double price;
  int qty;
  String note;
  final String? image;
  final String? size;
  final String? sweetness;
  late final TextEditingController noteCtrl;
  _EditItem({required this.id, required this.name, required this.price, required this.qty,
      required this.note, this.image, this.size, this.sweetness}) {
    noteCtrl = TextEditingController(text: note);
  }
}

// ═══════════════════════════════════════════════════════
//  Add Product Dialog — giống 100% AddProductModal (web)
// ═══════════════════════════════════════════════════════
const List<String> _kSizes = ['S', 'M', 'L'];
const List<String> _kSweet = ['100%', '70%', '50%', '30%', '0%'];

class _AddProductDialog extends StatefulWidget {
  final String tableId;
  final Map<String, MenuItemModel> menuCache;
  final Future<void> Function(List<OrderItem> items) onConfirm;
  const _AddProductDialog({required this.tableId, required this.menuCache, required this.onConfirm});

  @override
  State<_AddProductDialog> createState() => _AddProductDialogState();
}

class _AddProductDialogState extends State<_AddProductDialog> {
  final _menuService = MenuService();
  List<MenuItemModel> _products = [];
  bool _loading = true;
  String _search = '';
  String _cat = 'Tất cả';
  final List<_AddCartItem> _cart = [];
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    if (widget.menuCache.isNotEmpty) {
      _products = widget.menuCache.values.where((m) => m.available).toList();
      _loading = false;
    }
    _menuService.streamMenuItems().first.then((items) {
      if (mounted) setState(() {
        _products = items.where((m) => m.available).toList();
        _loading = false;
      });
    });
  }

  List<String> get _cats {
    final s = _products.map((p) => p.category).where((c) => c.isNotEmpty).toSet().toList()..sort();
    return ['Tất cả', ...s];
  }

  List<MenuItemModel> get _filtered => _products.where((p) {
    final okSearch = _search.isEmpty || p.name.toLowerCase().contains(_search.toLowerCase());
    final okCat = _cat == 'Tất cả' || p.category == _cat;
    return okSearch && okCat;
  }).toList();

  double get _cartTotal => _cart.fold(0.0, (s, i) => s + i.price * i.qty);
  int get _cartCount => _cart.fold(0, (s, i) => s + i.qty);

  Future<void> _pickAndAdd(MenuItemModel p) async {
    final res = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => _OptionPicker(product: p, initSize: 'L', initSweet: '100%'),
    );
    if (res == null || !mounted) return;
    final size = res['size']; final sweet = res['sweet'];
    final key = '${p.id}_${size}_$sweet';
    setState(() {
      final idx = _cart.indexWhere((i) => i.cartKey == key);
      if (idx >= 0) { _cart[idx].qty++; }
      else { _cart.add(_AddCartItem(item: p, size: size, sweetness: sweet, qty: 1, cartKey: key)); }
    });
  }

  void _updateQty(String key, int delta) {
    setState(() {
      final idx = _cart.indexWhere((i) => i.cartKey == key);
      if (idx < 0) return;
      _cart[idx].qty += delta;
      if (_cart[idx].qty <= 0) _cart.removeAt(idx);
    });
  }

  Future<void> _confirm() async {
    if (_cart.isEmpty || _submitting) return;
    setState(() => _submitting = true);
    try {
      final items = _cart.map((c) => OrderItem(
        id: c.item.id, name: c.item.name, quantity: c.qty, price: c.price,
        image: c.item.imageUrl, size: c.size, sweetness: c.sweetness,
      )).toList();
      await widget.onConfirm(items);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Lỗi khi thêm sản phẩm'), backgroundColor: Color(0xFFDC2626)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 760),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(24, 16, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9)))),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Thêm món — Bàn ${widget.tableId}',
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                const SizedBox(height: 2),
                const Text('Bấm món để chọn size & độ ngọt', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              ])),
              GestureDetector(onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8))),
            ]),
          ),
          Flexible(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: Column(children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(children: [
                    TextField(
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        hintText: 'Tìm món...', isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 18, color: Color(0xFF94A3B8)),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(height: 30, child: ListView(scrollDirection: Axis.horizontal, children: _cats.map((c) {
                      final sel = _cat == c;
                      return Padding(padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(onTap: () => setState(() => _cat = c),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: sel ? const Color(0xFF2563EB) : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(20)),
                            child: Text(c, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                              color: sel ? Colors.white : const Color(0xFF64748B))),
                          )));
                    }).toList())),
                  ]),
                ),
                const Divider(height: 1, color: Color(0xFFF1F5F9)),
                Expanded(
                  child: _loading
                      ? const Center(child: CircularProgressIndicator())
                      : _filtered.isEmpty
                          ? const Center(child: Text('Không tìm thấy món', style: TextStyle(color: Color(0xFF94A3B8))))
                          : GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 150, childAspectRatio: 0.82, crossAxisSpacing: 8, mainAxisSpacing: 8),
                              itemCount: _filtered.length,
                              itemBuilder: (_, i) {
                                final p = _filtered[i];
                                final inCart = _cart.where((c) => c.item.id == p.id).fold(0, (s, c) => s + c.qty);
                                return GestureDetector(
                                  onTap: () => _pickAndAdd(p),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: inCart > 0 ? const Color(0xFFEFF6FF) : Colors.white,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(color: inCart > 0 ? const Color(0xFFBFDBFE) : const Color(0xFFE2E8F0))),
                                    padding: const EdgeInsets.all(8),
                                    child: Stack(children: [
                                      Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                        Container(
                                          width: 54, height: 54,
                                          decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(12)),
                                          clipBehavior: Clip.antiAlias,
                                          child: (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                                              ? CachedNetworkImage(imageUrl: p.imageUrl!, fit: BoxFit.cover,
                                                  errorWidget: (_, __, ___) => const Icon(Icons.coffee, size: 22, color: Color(0xFF94A3B8)))
                                              : const Icon(Icons.coffee, size: 22, color: Color(0xFF94A3B8))),
                                        const SizedBox(height: 6),
                                        Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center,
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                                        const SizedBox(height: 2),
                                        Text('${_vndFmt.format(p.price)}đ',
                                            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFFEA580C))),
                                      ]),
                                      if (inCart > 0)
                                        Positioned(top: 0, right: 0, child: Container(
                                          width: 20, height: 20, alignment: Alignment.center,
                                          decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle),
                                          child: Text('$inCart', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w900, color: Colors.white)))),
                                    ]),
                                  ),
                                );
                              },
                            ),
                ),
              ])),
              Container(width: 220,
                decoration: const BoxDecoration(color: Color(0xFFF8FAFC),
                  border: Border(left: BorderSide(color: Color(0xFFF1F5F9)))),
                child: Column(children: [
                  Padding(padding: const EdgeInsets.all(12),
                    child: Row(children: [
                      const Icon(Icons.shopping_cart_outlined, size: 14, color: Color(0xFF64748B)),
                      const SizedBox(width: 6),
                      Expanded(child: Text('Món đã chọn ($_cartCount)', style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w800, color: Color(0xFF64748B), letterSpacing: 0.5))),
                    ])),
                  const Divider(height: 1, color: Color(0xFFE2E8F0)),
                  Expanded(
                    child: _cart.isEmpty
                        ? const Center(child: Text('Chưa chọn món nào', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))))
                        : ListView.separated(
                            padding: const EdgeInsets.all(10),
                            itemCount: _cart.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final c = _cart[i];
                              return Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: const Color(0xFFE2E8F0))),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text(c.item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF1E293B))),
                                  const SizedBox(height: 5),
                                  Wrap(spacing: 4, children: [
                                    if (c.size != null) Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(color: const Color(0xFFDBEAFE), borderRadius: BorderRadius.circular(4)),
                                      child: Text(c.size!, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Color(0xFF1D4ED8)))),
                                    if (c.sweetness != null) Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                      decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(4)),
                                      child: Text(c.sweetness!, style: const TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Color(0xFFB45309)))),
                                  ]),
                                  const SizedBox(height: 6),
                                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                                    Text('${_vndFmt.format(c.price * c.qty)}đ',
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Color(0xFFEA580C))),
                                    Row(children: [
                                      _roundBtn(Icons.remove, () => _updateQty(c.cartKey, -1)),
                                      SizedBox(width: 20, child: Text('${c.qty}', textAlign: TextAlign.center,
                                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w900))),
                                      _roundBtn(Icons.add, () => _updateQty(c.cartKey, 1)),
                                    ]),
                                  ]),
                                ]),
                              );
                            },
                          ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE2E8F0)))),
                    child: Column(children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text('Tổng thêm', style: TextStyle(fontSize: 12, color: Color(0xFF64748B), fontWeight: FontWeight.w600)),
                        Text('${_vndFmt.format(_cartTotal)}đ', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                      ]),
                      const SizedBox(height: 8),
                      SizedBox(width: double.infinity, child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          disabledBackgroundColor: const Color(0xFFE2E8F0), disabledForegroundColor: const Color(0xFF94A3B8),
                        ),
                        onPressed: (_cart.isEmpty || _submitting) ? null : _confirm,
                        icon: _submitting
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.check, size: 14),
                        label: Text(_cartCount > 0 ? 'Thêm $_cartCount món' : 'Thêm',
                            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                      )),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(onTap: onTap,
      child: Container(width: 22, height: 22, alignment: Alignment.center,
        decoration: const BoxDecoration(color: Color(0xFFF1F5F9), shape: BoxShape.circle),
        child: Icon(icon, size: 12, color: const Color(0xFF475569))));
  }
}

class _AddCartItem {
  final MenuItemModel item;
  final String? size;
  final String? sweetness;
  int qty;
  final String cartKey;
  double get price => item.price;
  _AddCartItem({required this.item, this.size, this.sweetness, required this.qty, required this.cartKey});
}

// ── Option Picker (size + độ ngọt) — giống OptionPicker trong web ─────────────
class _OptionPicker extends StatefulWidget {
  final MenuItemModel product;
  final String initSize;
  final String initSweet;
  const _OptionPicker({required this.product, required this.initSize, required this.initSweet});

  @override
  State<_OptionPicker> createState() => _OptionPickerState();
}

class _OptionPickerState extends State<_OptionPicker> {
  late String _size = widget.initSize;
  late String _sweet = widget.initSweet;

  @override
  Widget build(BuildContext context) {
    final p = widget.product;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 300),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(width: 48, height: 48,
                decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(12)),
                clipBehavior: Clip.antiAlias,
                child: (p.imageUrl != null && p.imageUrl!.isNotEmpty)
                    ? CachedNetworkImage(imageUrl: p.imageUrl!, fit: BoxFit.cover,
                        errorWidget: (_, __, ___) => const Icon(Icons.coffee, size: 18, color: Color(0xFF94A3B8)))
                    : const Icon(Icons.coffee, size: 18, color: Color(0xFF94A3B8))),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, color: Color(0xFF1E293B))),
                Text('${_vndFmt.format(p.price)}đ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEA580C))),
              ])),
            ]),
            const SizedBox(height: 16),
            const Text('SIZE', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Row(children: _kSizes.map((s) {
              final sel = _size == s;
              return Expanded(child: Padding(padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(onTap: () => setState(() => _size = s),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8), alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? const Color(0xFFEFF6FF) : Colors.white, borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: sel ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0), width: sel ? 2 : 1)),
                    child: Text(s, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w900,
                      color: sel ? const Color(0xFF1D4ED8) : const Color(0xFF64748B)))),
                )));
            }).toList()),
            const SizedBox(height: 14),
            const Text('ĐỘ NGỌT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1, color: Color(0xFF94A3B8))),
            const SizedBox(height: 6),
            Row(children: _kSweet.map((sw) {
              final sel = _sweet == sw;
              return Expanded(child: Padding(padding: const EdgeInsets.only(right: 4),
                child: GestureDetector(onTap: () => setState(() => _sweet = sw),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8), alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? const Color(0xFFFFFBEB) : Colors.white, borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: sel ? const Color(0xFFFBBF24) : const Color(0xFFE2E8F0), width: sel ? 2 : 1)),
                    child: Text(sw, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900,
                      color: sel ? const Color(0xFFB45309) : const Color(0xFF64748B)))),
                )));
            }).toList()),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
                onPressed: () => Navigator.pop(context, {'size': _size, 'sweet': _sweet}),
                icon: const Icon(Icons.check, size: 14),
                label: const Text('Thêm'))),
            ]),
          ]),
        ),
      ),
    );
  }
}

// ── Discount Picker Dialog — giống discount picker trong web ──────────────────
class _DiscountPickerDialog extends StatefulWidget {
  final String tableId;
  final List<DiscountModel> discounts;
  final String? activeDiscountId;
  final double orderTotal;
  final Future<void> Function(DiscountModel d) onApply;
  final Future<void> Function() onRemove;
  const _DiscountPickerDialog({required this.tableId, required this.discounts,
    required this.activeDiscountId, required this.orderTotal, required this.onApply, required this.onRemove});

  @override
  State<_DiscountPickerDialog> createState() => _DiscountPickerDialogState();
}

class _DiscountPickerDialogState extends State<_DiscountPickerDialog> {
  String? _applyingId;

  String _valueLabel(DiscountModel d) {
    if (d.type == 'percent') {
      final maxTxt = d.maxDiscount > 0 ? ' (tối đa ${(d.maxDiscount / 1000).toStringAsFixed(0)}k)' : '';
      return 'Giảm ${d.value.toStringAsFixed(0)}%$maxTxt';
    }
    return 'Giảm ${(d.value / 1000).toStringAsFixed(0)}k';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360, maxHeight: 500),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(20, 16, 16, 16),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFFF1F5F9)))),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Áp dụng mã giảm giá', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
                Text('Bàn ${widget.tableId}', style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
              ])),
              GestureDetector(onTap: () => Navigator.pop(context),
                  child: const Icon(Icons.close, size: 18, color: Color(0xFF94A3B8))),
            ]),
          ),
          Flexible(
            child: widget.discounts.isEmpty
                ? const Padding(padding: EdgeInsets.all(28),
                    child: Text('Không có mã giảm giá nào đang hoạt động.',
                        textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: Color(0xFF94A3B8))))
                : ListView.separated(
                    padding: const EdgeInsets.all(16),
                    itemCount: widget.discounts.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final d = widget.discounts[i];
                      final isSel = widget.activeDiscountId == d.id;
                      final isApplying = _applyingId == d.id;
                      // Giống web: mã còn hiện ra nhưng bị khoá nếu đơn chưa đạt tối thiểu.
                      // Mã đang được dùng vẫn cho phép bấm để gỡ, dù đơn không còn đạt điều kiện.
                      final meetsMin = d.minOrder <= 0 || widget.orderTotal >= d.minOrder;
                      final locked = !isSel && !meetsMin;
                      return GestureDetector(
                        onTap: (isApplying || locked) ? null : () async {
                          final messenger = ScaffoldMessenger.of(context);
                          final nav = Navigator.of(context);
                          setState(() => _applyingId = d.id);
                          try {
                            if (isSel) { await widget.onRemove(); } else { await widget.onApply(d); }
                            nav.pop();
                            messenger.showSnackBar(SnackBar(
                              content: Text(isSel ? 'Đã gỡ mã ${d.code}' : 'Đã áp mã ${d.code}'),
                              backgroundColor: const Color(0xFF059669), duration: const Duration(seconds: 2)));
                          } catch (e) {
                            if (mounted) setState(() => _applyingId = null);
                            messenger.showSnackBar(SnackBar(
                              content: Text('Lỗi áp mã: $e'),
                              backgroundColor: const Color(0xFFDC2626), duration: const Duration(seconds: 5)));
                          }
                        },
                        child: Opacity(
                          opacity: locked ? 0.5 : 1,
                          child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFFECFDF5) : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                                color: isSel ? const Color(0xFF10B981) : const Color(0xFFE2E8F0),
                                width: isSel ? 2 : 1,
                                style: locked ? BorderStyle.solid : BorderStyle.solid),
                          ),
                          child: Row(children: [
                            Container(width: 28, height: 28, alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: isSel ? const Color(0xFF10B981) : Colors.white, shape: BoxShape.circle,
                                border: Border.all(color: isSel ? const Color(0xFF10B981) : const Color(0xFFCBD5E1), width: 2)),
                              child: isApplying
                                  ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2))
                                  : Icon(isSel ? Icons.check : Icons.local_offer_outlined, size: 13,
                                      color: isSel ? Colors.white : const Color(0xFF94A3B8))),
                            const SizedBox(width: 10),
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              // Giống web: title = description || valueLabel
                              Text(d.description ?? _valueLabel(d), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800,
                                  color: isSel ? const Color(0xFF065F46) : const Color(0xFF334155))),
                              // subtitle = code · valueLabel (nếu có description) | chỉ code + cảnh báo chưa đạt đơn tối thiểu
                              Text(
                                  (d.description != null ? '${d.code} · ${_valueLabel(d)}' : d.code) +
                                      (!meetsMin ? ' — Đơn tối thiểu ${_vndFmt.format(d.minOrder)}đ' : ''),
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600,
                                      color: !meetsMin ? const Color(0xFFDC2626) : const Color(0xFF94A3B8))),
                            ])),
                            if (isSel)
                              const Text('Đang dùng', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: Color(0xFF059669)))
                            else
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(color: const Color(0xFFF1F5F9), borderRadius: BorderRadius.circular(20)),
                                child: Text(d.type == 'percent' ? '-${d.value.toStringAsFixed(0)}%' : '-${(d.value / 1000).toStringAsFixed(0)}k',
                                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF64748B)))),
                          ]),
                        )),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════
//  Invoice Dialog — port InvoiceModal (web): VAT, phí DV, giảm giá, in lần 2
// ═══════════════════════════════════════════════════════
class _InvoiceDialog extends StatefulWidget {
  final String tableId;
  final List<OrderModel> tableOrders;
  final Map<String, dynamic>? activeDiscount;
  final Future<Map<String, dynamic>?> existingInvoiceFuture;
  final String? staffName;           // Thu ngân — hiện trên preview & bill in ra
  final DateTime? checkInAt;         // Giờ vào — hiện trên preview & bill in ra
  final String? previewInvoiceId;    // Mã hóa đơn sinh trước — preview = mã sẽ in thật
  final Future<void> Function(Map<String, dynamic> data) onPrint;
  const _InvoiceDialog({
    required this.tableId,
    required this.tableOrders,
    required this.activeDiscount,
    required this.existingInvoiceFuture,
    this.staffName,
    this.checkInAt,
    this.previewInvoiceId,
    required this.onPrint,
  });

  @override
  State<_InvoiceDialog> createState() => _InvoiceDialogState();
}

class _InvoiceDialogState extends State<_InvoiceDialog> {
  bool _checking = true;
  Map<String, dynamic>? _existing;
  double _vat = 0;
  double _service = 0;
  double _discount = 0;
  final _reasonCtrl = TextEditingController();
  final _discountCtrl = TextEditingController();
  final _vatCtrl = TextEditingController(text: '0');
  final _serviceCtrl = TextEditingController(text: '0');
  bool _saveRevenue = true;
  AccountModel? _revenueApprover; // admin đã duyệt "không lưu doanh thu"
  bool _printing = false;

  double get _subtotal =>
      widget.tableOrders.fold(0.0, (s, o) => s + o.items.fold(0.0, (a, i) => a + i.price * i.quantity));
  double get _vatAmount => _subtotal * _vat / 100;
  double get _serviceAmount => _subtotal * _service / 100;
  double get _total => _subtotal + _vatAmount + _serviceAmount - _discount;
  bool get _isPrint2 => !_checking && _existing != null;
  String? get _code => widget.activeDiscount?['code']?.toString();

  @override
  void initState() {
    super.initState();
    _discount = _calcDiscount(widget.activeDiscount, _subtotal);
    if (_discount > 0) _discountCtrl.text = _vndFmt.format(_discount);
    widget.existingInvoiceFuture.then((inv) {
      if (mounted) setState(() { _existing = inv; _checking = false; });
    });
    BankQrService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _reasonCtrl.dispose();
    _discountCtrl.dispose();
    _vatCtrl.dispose();
    _serviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _doPrint() async {
    if (_isPrint2 && _reasonCtrl.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Vui lòng nhập lý do in lại hóa đơn!'), backgroundColor: Color(0xFFDC2626)));
      return;
    }
    setState(() => _printing = true);
    if (!_saveRevenue) {
      // In bill nhưng KHÔNG ghi vào doanh thu → luôn để lại dấu vết.
      AuditService().log(
        action: AuditService.invoiceNotSaved,
        staff: context.read<AuthProvider>().currentUser,
        approvedBy: _revenueApprover,
        tableId: widget.tableId,
        orderId: widget.tableOrders.isNotEmpty ? widget.tableOrders.first.id : null,
        amountBefore: _total,
        details: {
          'orderIds': widget.tableOrders.map((o) => o.id).toList(),
          'items': widget.tableOrders
              .expand((o) => o.items)
              .map((i) => i.toMap())
              .toList(),
        },
      );
    }
    await widget.onPrint({
      'vat': _vat,
      'serviceCharge': _service,
      'discount': _discount,
      'shouldSave': _saveRevenue,
      'finalTotal': _total,
      'subtotal': _subtotal,
      'vatAmount': _vatAmount,
      'serviceAmount': _serviceAmount,
      'discountCode': _code,
      'isPrint2': _isPrint2,
      'reason': _isPrint2 ? _reasonCtrl.text.trim() : null,
      'previousInvoiceId': _isPrint2 ? _existing!['id'] : null,
    });
    if (mounted) setState(() => _printing = false);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.tableOrders.expand((o) => o.items).toList();
    final canPrint = !_checking && (!_isPrint2 || _reasonCtrl.text.trim().isNotEmpty) && !_printing;

    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 620),
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          // ── Panel cài đặt ──
          SizedBox(
            width: 260,
            child: Container(
              color: const Color(0xFFF8FAFC),
              child: Column(children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Thiết lập', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
                      const SizedBox(height: 12),
                      if (_checking)
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFE2E8F0))),
                          child: const Row(children: [
                            SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2)),
                            SizedBox(width: 8),
                            Text('Đang kiểm tra hóa đơn...', style: TextStyle(fontSize: 11, color: Color(0xFF64748B))),
                          ]),
                        ),
                      if (_isPrint2) ...[
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFFDE68A))),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: const [
                              Icon(Icons.warning_amber_rounded, size: 14, color: Color(0xFFD97706)),
                              SizedBox(width: 6),
                              Text('In lại hóa đơn', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Color(0xFFB45309))),
                            ]),
                            const SizedBox(height: 4),
                            Text('Bàn này đã in hóa đơn trước đó bởi ${_existing?['staffName'] ?? 'N/A'}. Doanh thu cập nhật theo hóa đơn mới nhất.',
                                style: const TextStyle(fontSize: 10, color: Color(0xFFD97706))),
                          ]),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _label('VAT (%)'),
                      TextField(
                        controller: _vatCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13),
                        decoration: _fieldDeco('0'),
                        onChanged: (v) => setState(() => _vat = double.tryParse(v) ?? 0),
                      ),
                      const SizedBox(height: 10),
                      _label('Phí dịch vụ (%)'),
                      TextField(
                        controller: _serviceCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13),
                        decoration: _fieldDeco('0'),
                        onChanged: (v) => setState(() => _service = double.tryParse(v) ?? 0),
                      ),
                      const SizedBox(height: 10),
                      _label('Giảm giá (VNĐ)'),
                      if (_code != null) Padding(
                        padding: const EdgeInsets.only(top: 4, bottom: 4),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(color: const Color(0xFFECFDF5), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFA7F3D0))),
                          child: Row(children: [
                            const Icon(Icons.local_offer, size: 11, color: Color(0xFF059669)),
                            const SizedBox(width: 4),
                            Text(_code!, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Color(0xFF047857))),
                            const Spacer(),
                            const Text('Khách áp dụng', style: TextStyle(fontSize: 9, color: Color(0xFF10B981))),
                          ]),
                        ),
                      ),
                      TextField(
                        controller: _discountCtrl,
                        keyboardType: TextInputType.number,
                        style: const TextStyle(fontSize: 13),
                        decoration: _fieldDeco('Nhập số tiền...'),
                        onChanged: (v) {
                          final raw = v.replaceAll(RegExp(r'[^0-9]'), '');
                          setState(() => _discount = raw.isEmpty ? 0 : double.parse(raw));
                        },
                      ),
                      if (_isPrint2) ...[
                        const SizedBox(height: 10),
                        _label('Lý do in lại (bắt buộc)', color: const Color(0xFFDC2626)),
                        TextField(
                          controller: _reasonCtrl,
                          maxLines: 2,
                          style: const TextStyle(fontSize: 13),
                          decoration: _fieldDeco('VD: Khách yêu cầu in lại, sai món...'),
                          onChanged: (_) => setState(() {}),
                        ),
                      ],
                      const SizedBox(height: 12),
                      GestureDetector(
                        onTap: _handleToggleSaveRevenue,
                        child: Row(children: [
                          Icon(_saveRevenue ? Icons.check_box : Icons.check_box_outline_blank,
                              size: 18, color: const Color(0xFF2563EB)),
                          const SizedBox(width: 6),
                          const Text('Tự động lưu vào doanh thu', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFF1D4ED8))),
                        ]),
                      ),
                    ]),
                  ),
                ),
                // Nút In (trên) + Đóng (dưới) — xếp dọc để không bị xuống dòng
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE2E8F0)))),
                  child: Column(children: [
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          disabledBackgroundColor: const Color(0xFFE2E8F0)),
                        onPressed: canPrint ? _doPrint : null,
                        icon: _printing
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.print, size: 15),
                        label: Text(_isPrint2 ? 'In lại hóa đơn' : 'In hóa đơn',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700), maxLines: 1),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed: _printing ? null : () => Navigator.pop(context),
                        child: const Text('Đóng', maxLines: 1),
                      ),
                    ),
                  ]),
                ),
              ]),
            ),
          ),
          // ── Preview hóa đơn ──
          Expanded(
            child: Container(
              color: Colors.white,
              padding: const EdgeInsets.all(20),
              child: SingleChildScrollView(
                child: DefaultTextStyle(
                  style: const TextStyle(fontSize: 12, color: Colors.black, fontFamily: 'monospace'),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Center(child: Text('EM COFFEE', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: Colors.black))),
                    const Center(child: Text('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', style: TextStyle(fontSize: 11, color: Colors.black))),
                    const Center(child: Text('Hotline: 0742-619-457', style: TextStyle(fontSize: 11, color: Colors.black))),
                    const Divider(color: Colors.black, thickness: 1.5),
                    const SizedBox(height: 4),
                    // Số hóa đơn chỉ hiện khi thực sự sẽ lưu (khớp đúng logic khi in)
                    if (_saveRevenue && widget.previewInvoiceId != null || widget.checkInAt != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(
                            _saveRevenue && widget.previewInvoiceId != null
                                ? 'Số hóa đơn: #${_invoiceCode(widget.previewInvoiceId!)}'
                                : '',
                            style: const TextStyle(fontSize: 11, color: Colors.black),
                          ),
                          Text(
                            widget.checkInAt != null ? 'Giờ vào: ${_fmtDt(widget.checkInAt!)}' : '',
                            style: const TextStyle(fontSize: 11, color: Colors.black),
                          ),
                        ]),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Text('Bàn: ${widget.tableId}', style: const TextStyle(fontSize: 12, color: Colors.black)),
                        Text('Giờ ra: ${_nowStr()}', style: const TextStyle(fontSize: 11, color: Colors.black)),
                      ]),
                    ),
                    if (widget.staffName != null && widget.staffName!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text('Thu ngân: ${widget.staffName}', style: const TextStyle(fontSize: 11, color: Colors.black)),
                      ),
                    const SizedBox(height: 4),
                    const Divider(color: Colors.black),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Expanded(flex: 3, child: Text('Tên Món', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black))),
                        Expanded(flex: 2, child: Text('Đơn Giá', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black))),
                        Expanded(flex: 2, child: Text('Thành Tiền', textAlign: TextAlign.right, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: Colors.black))),
                      ]),
                    ),
                    const Divider(color: Colors.black, height: 8),
                    ...items.map((it) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(children: [
                        Expanded(flex: 3, child: Text('${it.quantity} x ${it.name}', style: const TextStyle(fontSize: 12, color: Colors.black))),
                        Expanded(flex: 2, child: Text('${_vndFmt.format(it.price)}đ', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, color: Colors.black))),
                        Expanded(flex: 2, child: Text('${_vndFmt.format(it.price * it.quantity)}đ', textAlign: TextAlign.right, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black))),
                      ]),
                    )),
                    const Divider(color: Colors.black),
                    if (_service > 0) _pvRow('Phí dịch vụ (${_service.toStringAsFixed(0)}%)', '${_vndFmt.format(_serviceAmount)}đ'),
                    if (_discount > 0) _pvRow('Giảm giá${_code != null ? ' [$_code]' : ''}', '-${_vndFmt.format(_discount)}đ'),
                    const Divider(color: Colors.black, thickness: 1.2),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('TỔNG CỘNG', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.black)),
                      Text('${_vndFmt.format(_total)}đ', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.black)),
                    ]),
                    const SizedBox(height: 14),
                    const Center(child: Text('CẢM ƠN QUÝ KHÁCH!', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.black))),
                    const Center(child: Text('HẸN GẶP LẠI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.black))),
                    if (_qrUrl != null) ...[
                      const SizedBox(height: 12),
                      const Center(child: Text('Quét mã để chuyển khoản', style: TextStyle(fontSize: 11, color: Colors.black))),
                      const SizedBox(height: 6),
                      Center(
                        child: Image.network(
                          _qrUrl!,
                          width: 140,
                          height: 140,
                          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                          loadingBuilder: (ctx, child, progress) => progress == null
                              ? child
                              : const SizedBox(width: 140, height: 140, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                        ),
                      ),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  // Tắt "Tự động lưu vào doanh thu" cần mật khẩu quản lý — giống hệt bản web
  // (InvoiceModal.jsx: handleToggleSave) để tránh nhân viên tùy tiện bỏ qua
  // ghi nhận doanh thu. Bật lại thì không cần mật khẩu.

  Future<void> _handleToggleSaveRevenue() async {
    if (_saveRevenue) {
      // Trước đây dùng mật khẩu cố định ghi trong code (ai giải nén app cũng
      // đọc được) → nay phải là mật khẩu của 1 tài khoản admin thật, và lưu
      // lại người duyệt để ghi nhật ký khi in.
      final approver = await requestManagerApproval(
        context,
        action: 'Hủy lưu doanh thu cho hóa đơn bàn ${widget.tableId} '
            '(${_vndFmt.format(_total)}đ).',
      );
      if (approver == null || !mounted) return;
      setState(() {
        _saveRevenue = false;
        _revenueApprover = approver;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Đã mở khóa chỉnh sửa!'), backgroundColor: Color(0xFF059669)));
    } else {
      setState(() {
        _saveRevenue = true;
        _revenueApprover = null;
      });
    }
  }

  String? get _qrUrl {
    if (!BankQrService.instance.shouldPrint) return null;
    final content = (_saveRevenue && widget.previewInvoiceId != null)
        ? 'HD ${_invoiceCode(widget.previewInvoiceId!)}'
        : 'Ban ${widget.tableId}';
    return BankQrService.instance.imageUrl(amount: _total, content: content);
  }

  String _nowStr() => _fmtDt(DateTime.now());

  String _fmtDt(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
  }

  // Cùng công thức với _printInvoice: 8 ký tự cuối của ID hóa đơn, viết hoa
  // (khớp với mã hiển thị bên trang quản lý hóa đơn trên web).
  String _invoiceCode(String id) =>
      (id.length >= 8 ? id.substring(id.length - 8) : id).toUpperCase();

  Widget _pvRow(String l, String r) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: const TextStyle(fontSize: 12, color: Colors.black)),
          Text(r, style: const TextStyle(fontSize: 12, color: Colors.black)),
        ]),
      );

  Widget _label(String t, {Color color = const Color(0xFF94A3B8)}) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t.toUpperCase(), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 0.5, color: color)),
      );

  InputDecoration _fieldDeco(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        isDense: true,
        filled: true, fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFE2E8F0))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF2563EB))),
      );
}

// ═══════════════════════════════════════════════════════
//  BOARD TAB — Quản lý bàn kiểu POS (master–detail)
//  Trái: danh sách bàn (lọc theo trạng thái). Phải: chi tiết + thao tác.
//  Tái dùng toàn bộ dialog + _OrderBlock của KDS → chức năng đầy đủ như tab Đơn hàng.
// ═══════════════════════════════════════════════════════
class _TableBoardTab extends StatefulWidget {
  const _TableBoardTab();
  @override
  State<_TableBoardTab> createState() => _TableBoardTabState();
}

class _TableBoardTabState extends State<_TableBoardTab> {
  final _orderService    = OrderService();
  final _menuService     = MenuService();
  final _tableService    = TableService();
  final _discountService = DiscountService();
  final _invoiceService  = InvoiceService();

  StreamSubscription? _menuSub, _tableSub, _discountSub, _ordersSub;
  Map<String, MenuItemModel> _menuCache = {};
  List<TableModel> _tables = [];
  List<DiscountModel> _discounts = [];
  List<OrderModel> _activeOrders = [];
  final Set<String> _clearingTableIds = {};
  // Bàn/thẻ vừa xuất bill trên máy này (hiển thị ngay, chưa chờ Firestore):
  // key → mã các đơn nằm trong bill đó.
  final Map<String, Set<String>> _billedOrderIds = {};
  bool _loaded = false;

  String _statusFilter = 'Đặt Món'; // mặc định
  String? _selectedKey;
  double _detailWidth = 440; // mặc định "Vừa"
  bool _gridView = true; // false = danh sách, true = dạng bảng (lưới) — mặc định dạng bảng

  Timer? _ticker; // làm mới số phút đã trôi qua
  StreamSubscription? _invoiceSub;
  List<Map<String, dynamic>> _todayInvoices = []; // hóa đơn đã xuất trong ngày
  String? _selectedInvoiceId;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      // Qua ngày mới → đăng ký lại để chỉ lấy hóa đơn của ngày mới.
      final now = DateTime.now();
      if (_invoiceDay != DateTime(now.year, now.month, now.day)) _subscribeTodayInvoices();
      if (mounted) setState(() {});
    });
    _subscribeTodayInvoices();
    _menuSub = _menuService.streamMenuItems().listen((items) {
      if (mounted) setState(() => _menuCache = {for (final m in items) m.id: m});
    });
    _tableSub = _tableService.streamTables().listen((tables) {
      if (mounted) setState(() => _tables = tables);
    }, onError: (e) => debugPrint('[BOARD] tables: $e'));
    _discountSub = _discountService.streamDiscounts().listen((discounts) {
      final now = DateTime.now();
      final filtered = discounts.where((d) {
        if (!d.active) return false;
        if (d.expiresAt != null && now.isAfter(d.expiresAt!)) return false;
        if (d.isMaxedOut) return false;
        return true;
      }).toList();
      if (mounted) setState(() => _discounts = filtered);
    }, onError: (e) => debugPrint('[BOARD] discounts: $e'));
    _ordersSub = activeOrdersQuery().snapshots().listen((snap) {
      final active = <OrderModel>[];
      for (final d in snap.docs) {
        try {
          final o = OrderModel.fromDoc(d);
          if (_kActive.contains(o.status)) active.add(o);
        } catch (_) {}
      }
      if (mounted) setState(() {
        _activeOrders = active;
        _loaded = true;
      });
    }, onError: (e) {
      if (mounted) setState(() => _loaded = true);
    });
  }

  DateTime? _invoiceDay;

  /// Hóa đơn đã xuất trong NGÀY HIỆN TẠI — lọc theo createdAt ngay trên server
  /// (1 field, không cần composite index) thay vì tải toàn bộ lịch sử hóa đơn.
  void _subscribeTodayInvoices() {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    _invoiceDay = todayStart;
    _invoiceSub?.cancel();
    _invoiceSub = FirebaseFirestore.instance
        .collection('invoices')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(todayStart))
        .snapshots()
        .listen((snap) {
      final list = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final m = <String, dynamic>{'id': d.id, ...d.data()};
        if (m['status'] == 'superseded') continue;
        final ts = m['createdAt'];
        final dt = ts is Timestamp ? ts.toDate() : null;
        if (dt == null || dt.isBefore(todayStart)) continue;
        list.add(m);
      }
      list.sort((a, b) {
        final ta = a['createdAt'] is Timestamp ? (a['createdAt'] as Timestamp).seconds : 0;
        final tb = b['createdAt'] is Timestamp ? (b['createdAt'] as Timestamp).seconds : 0;
        return tb.compareTo(ta);
      });
      if (mounted) setState(() => _todayInvoices = list);
    }, onError: (e) => debugPrint('[BOARD] invoices: $e'));
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _invoiceSub?.cancel();
    _menuSub?.cancel();
    _tableSub?.cancel();
    _discountSub?.cancel();
    _ordersSub?.cancel();
    super.dispose();
  }

  // ── Helpers (giữ nguyên logic như KDS) ──
  TableModel? _findTable(String tableId) {
    final raw = tableId.trim();
    final padded = raw.padLeft(2, '0');
    final numeric = int.tryParse(raw);
    TableModel? match;
    for (final t in _tables) {
      final isMatch = t.id == raw || t.id == padded ||
          (numeric != null && int.tryParse(t.id) == numeric);
      if (isMatch) {
        if (t.activeDiscount != null) return t;
        match ??= t;
      }
    }
    return match;
  }

  // Bàn đã xuất bill CHO CÁC ĐƠN ĐANG HIỆN — bill chỉ bao gồm những đơn có lúc
  // in bill; khách gọi thêm đơn SAU đó thì bàn quay lại "chưa xuất bill" (trước
  // đây tính theo cả bàn → đơn mới cũng bị hiện "đã xuất bill").
  bool _isBilled(String tableId, List<OrderModel> orders) =>
      _tableBilledFor(_findTable(tableId), _billedOrderIds[tableId], orders);

  bool _hasServiceRequest(String tableId) => _findTable(tableId)?.serviceRequest != null;

  bool _isTakeawayTable(String baseId) {
    final t = _findTable(baseId);
    if (t != null && t.isTakeaway) return true;
    return baseId == 'Mang về';
  }

  // Đơn mang về đã xuất bill? Ưu tiên set tạm; nếu không, tra hóa đơn thật theo ĐÚNG orderId.
  // Nhờ đó không bị mất trạng thái sau restart và không nhầm giữa các đơn mang về.
  bool _isTakeawayBilled(String key, List<OrderModel> orders) {
    if (_billedOrderIds.containsKey(key)) return true;
    if (orders.isEmpty) return false;
    final oid = orders.first.id;
    return _todayInvoices.any((inv) => inv['orderId'] == oid);
  }

  void _applyDiscountLocally(String tableId, Map<String, dynamic>? disc) {
    final t = _findTable(tableId);
    setState(() {
      if (t == null) {
        if (disc != null) {
          _tables = [..._tables, TableModel(
            id: tableId, name: tableId, capacity: 4, status: 'available', activeDiscount: disc,
          )];
        }
      } else {
        _tables = _tables
            .map((x) => x.id == t.id ? x.copyWith(activeDiscount: disc, clearDiscount: disc == null) : x)
            .toList();
      }
    });
  }

  void _handleUpdateStatus(String orderId, String status) {
    _orderService.updateStatus(orderId, status);
  }

  void _handleOpenPayment(BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {String? cardKey, bool isTakeaway = false}) {
    final billKey = cardKey ?? tableId;
    final staff = ctx.read<AuthProvider>().currentUser;
    final staffName = staff?.fullName;
    final staffId = staff?.id;
    final table = _findTable(tableId);
    final clearedAt = table?.clearedAt;
    DateTime? sessionStart;
    for (final o in tableOrders) {
      final t = o.createdAt;
      if (t == null) continue;
      if (sessionStart == null || t.isBefore(sessionStart)) sessionStart = t;
    }
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    // Sinh trước ID hóa đơn để preview hiển thị ĐÚNG mã sẽ in ra (không phải mã giả)
    final previewInvoiceId = _invoiceService.newInvoiceId();
    // Takeaway: giảm giá ở cấp đơn → dựng activeDiscount tạm để hóa đơn áp đúng
    Map<String, dynamic>? invoiceDiscount = table?.activeDiscount;
    if (isTakeaway) {
      final amt = tableOrders.fold(0.0, (s, o) => s + o.discountAmount);
      final code = tableOrders.map((o) => o.discountCode).firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null);
      invoiceDiscount = (amt > 0 || code != null) ? {'type': 'amount', 'value': amt, 'code': code} : null;
    }
    final existingFuture = (isTakeaway && firstOrderId != null)
        ? _invoiceService.getLatestActiveForOrder(firstOrderId)
        : _invoiceService.getLatestActiveForTable(
            tableId, clearedAt: clearedAt, sessionStart: sessionStart);

    showDialog(
      context: ctx,
      builder: (dCtx) => _InvoiceDialog(
        tableId: tableId,
        tableOrders: tableOrders,
        activeDiscount: invoiceDiscount,
        existingInvoiceFuture: existingFuture,
        staffName: staffName,
        checkInAt: sessionStart,
        previewInvoiceId: previewInvoiceId,
        onPrint: (data) async {
          final act = table?.activeDiscount;
          final invoiceId = data['shouldSave'] == true ? previewInvoiceId : null;
          if (data['shouldSave'] == true) {
            await _invoiceService.saveInvoice({
              'orderId': firstOrderId,
              'tableId': tableId,
              'items': tableOrders.expand((o) => o.items.map((i) => i.toMap())).toList(),
              'subtotal': data['subtotal'],
              'vatPercent': data['vat'],
              'vatAmount': data['vatAmount'],
              'servicePercent': data['serviceCharge'],
              'serviceAmount': data['serviceAmount'],
              'discount': data['discount'],
              'discountCode': data['discountCode'],
              'totalAmount': data['finalTotal'],
            }, reason: data['reason'], previousInvoiceId: data['previousInvoiceId'],
               staffName: staffName, staffId: staffId, invoiceId: previewInvoiceId);
            if (!isTakeaway) {
              await _orderService.updateTableLastBilledAt(tableId,
                  orderIds: tableOrders.map((o) => o.id).toList());
            }
            final actId = act?['id'];
            if (actId != null) {
              await _discountService.incrementUsage(actId.toString());
            }
          }
          if (mounted) setState(() => _billedOrderIds[billKey] = tableOrders.map((o) => o.id).toSet());
          try {
            await _printInvoice(tableId, tableOrders, data,
                staffName: staffName, checkInAt: sessionStart, invoiceId: invoiceId);
          } catch (e) {
            debugPrint('[BOARD] print error: $e');
          }
          if (dCtx.mounted) Navigator.pop(dCtx);
          if (mounted) {
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text(data['isPrint2'] == true ? 'Đã in lại & lưu hóa đơn!' : 'Đã xuất & in hóa đơn!'),
              backgroundColor: const Color(0xFF059669),
              duration: const Duration(seconds: 2),
            ));
            // Sau khi xuất & in hóa đơn xong → mở luôn popup Dọn bàn để nhân viên
            // xử lý tiếp cho nhanh, khỏi phải tự bấm thêm 1 lần nữa.
            _handleCompleteTable(ctx, tableId, tableOrders,
                isBilled: true, cardKey: cardKey, isTakeaway: isTakeaway);
          }
        },
      ),
    );
  }

  // In hóa đơn: nếu đã cấu hình máy in nhiệt (ESC/POS qua LAN/Bluetooth, xem màn hình
  // "Cài đặt máy in") thì in thẳng qua máy in nhiệt; nếu chưa cấu hình thì in qua hộp
  // thoại in hệ thống (AirPrint) như trước đây.
  Future<void> _printInvoice(String tableId, List<OrderModel> tableOrders, Map<String, dynamic> data,
      {String? staffName, DateTime? checkInAt, String? invoiceId}) async {
    final items = tableOrders.expand((o) => o.items).toList();
    final subtotal = (data['subtotal'] as num?)?.toDouble() ?? 0;
    final serviceAmount = (data['serviceAmount'] as num?)?.toDouble() ?? 0;
    final discount = (data['discount'] as num?)?.toDouble() ?? 0;
    final total = (data['finalTotal'] as num?)?.toDouble() ?? 0;
    final code = data['discountCode']?.toString();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    String fmtDt(DateTime d) => '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
    final timeStr = fmtDt(now); // Giờ ra — thời điểm xuất/in hóa đơn
    final checkInStr = checkInAt != null ? fmtDt(checkInAt) : null; // Giờ vào — đơn đầu tiên của phiên bàn
    // Mã hóa đơn ngắn để tra cứu — giống web: 8 ký tự cuối của id hóa đơn, viết hoa
    final invoiceCode = (invoiceId != null && invoiceId.length >= 8)
        ? invoiceId.substring(invoiceId.length - 8).toUpperCase()
        : invoiceId?.toUpperCase();

    // Mã QR chuyển khoản (VietQR) — chỉ tải khi đã bật + cấu hình đủ tài khoản.
    await BankQrService.instance.load();
    Uint8List? qrBytes;
    if (BankQrService.instance.shouldPrint) {
      try {
        final qrContent = invoiceCode != null ? 'HD $invoiceCode' : 'Ban $tableId';
        final qrUrl = BankQrService.instance.imageUrl(amount: total, content: qrContent);
        final resp = await http.get(Uri.parse(qrUrl)).timeout(const Duration(seconds: 8));
        if (resp.statusCode == 200) qrBytes = resp.bodyBytes;
      } catch (e) {
        debugPrint('[QR] Lỗi tải mã QR chuyển khoản, bỏ qua: $e');
      }
    }

    await PrinterService.instance.load();
    if (PrinterService.instance.isConfigured) {
      final lines = <ReceiptLine>[
        ReceiptLine('EM COFFEE', bold: true, fontSize: 34, align: ReceiptAlign.center),
        ReceiptLine('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', fontSize: 20, align: ReceiptAlign.center),
        ReceiptLine('Hotline: 0742-619-457', fontSize: 20, align: ReceiptAlign.center),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        if (invoiceCode != null || checkInStr != null)
          ReceiptLine(
            invoiceCode != null ? 'Số hóa đơn: #$invoiceCode' : '',
            right: checkInStr != null ? 'Giờ vào: $checkInStr' : '',
            fontSize: 18,
          ),
        ReceiptLine('Bàn: $tableId', right: 'Giờ ra: $timeStr', fontSize: 20),
        if (staffName != null && staffName.isNotEmpty)
          ReceiptLine('Thu ngân: $staffName', fontSize: 18),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        ReceiptLine('Tên Món', mid: 'Đơn Giá', right: 'Thành Tiền', fontSize: 18, bold: true),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        ...items.map((it) => ReceiptLine('${it.quantity} x ${it.name}',
            mid: '${_vndFmt.format(it.price)}đ',
            right: '${_vndFmt.format(it.price * it.quantity)}đ', fontSize: 22)),
        ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        if (serviceAmount > 0)
          ReceiptLine('Phí dịch vụ', right: '${_vndFmt.format(serviceAmount)}đ', fontSize: 22),
        if (discount > 0)
          ReceiptLine('Giảm giá${code != null ? ' [$code]' : ''}',
              right: '-${_vndFmt.format(discount)}đ', fontSize: 22),
        ReceiptLine('================================', fontSize: 18, align: ReceiptAlign.center),
        ReceiptLine('TỔNG CỘNG', right: '${_vndFmt.format(total)}đ', fontSize: 28, bold: true),
        ReceiptLine('', fontSize: 12),
        ReceiptLine('CẢM ƠN QUÝ KHÁCH!', bold: true, fontSize: 22, align: ReceiptAlign.center),
        ReceiptLine('HẸN GẶP LẠI', bold: true, fontSize: 22, align: ReceiptAlign.center),
        if (qrBytes != null) ...[
          ReceiptLine('', fontSize: 10),
          ReceiptLine('Quét mã để chuyển khoản', fontSize: 18, align: ReceiptAlign.center),
        ],
      ];
      try {
        final bytes = await ReceiptImageBuilder.buildEscPosBytes(lines: lines, qrImageBytes: qrBytes);
        await PrinterService.instance.sendBytes(bytes);
        return;
      } catch (e) {
        debugPrint('[PRINTER] Lỗi in máy in nhiệt, chuyển sang in AirPrint: $e');
        // rơi xuống nhánh in PDF/AirPrint bên dưới để không mất hóa đơn
      }
    }

    // Chưa cấu hình máy in nhiệt (hoặc in nhiệt lỗi) → in PDF qua hộp thoại hệ thống
    final doc = pw.Document(theme: await _receiptPdfTheme());
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80,
      build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Center(child: pw.Text('EM COFFEE', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', style: const pw.TextStyle(fontSize: 8))),
        pw.Center(child: pw.Text('Hotline: 0742-619-457', style: const pw.TextStyle(fontSize: 8))),
        pw.Divider(thickness: 1),
        if (invoiceCode != null || checkInStr != null)
          pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
            pw.Text(invoiceCode != null ? 'Số hóa đơn: #$invoiceCode' : '', style: const pw.TextStyle(fontSize: 8)),
            pw.Text(checkInStr != null ? 'Giờ vào: $checkInStr' : '', style: const pw.TextStyle(fontSize: 8)),
          ]),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('Bàn: $tableId', style: const pw.TextStyle(fontSize: 9)),
          pw.Text('Giờ ra: $timeStr', style: const pw.TextStyle(fontSize: 8)),
        ]),
        if (staffName != null && staffName.isNotEmpty)
          pw.Text('Thu ngân: $staffName', style: const pw.TextStyle(fontSize: 8)),
        pw.Divider(),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(flex: 3, child: pw.Text('Tên Món', style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
          pw.Expanded(flex: 2, child: pw.Text('Đơn Giá', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
          pw.Expanded(flex: 2, child: pw.Text('Thành Tiền', textAlign: pw.TextAlign.right, style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold))),
        ]),
        pw.Divider(),
        ...items.map((it) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(flex: 3, child: pw.Text('${it.quantity} x ${it.name}', style: const pw.TextStyle(fontSize: 9))),
          pw.Expanded(flex: 2, child: pw.Text('${_vndFmt.format(it.price)}đ', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
          pw.Expanded(flex: 2, child: pw.Text('${_vndFmt.format(it.price * it.quantity)}đ', textAlign: pw.TextAlign.right, style: const pw.TextStyle(fontSize: 9))),
        ])),
        pw.Divider(),
        if (serviceAmount > 0) _pdfRow('Phí dịch vụ', '${_vndFmt.format(serviceAmount)}đ'),
        if (discount > 0) _pdfRow('Giảm giá${code != null ? ' [$code]' : ''}', '-${_vndFmt.format(discount)}đ'),
        pw.Divider(thickness: 1),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('TỔNG CỘNG', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text('${_vndFmt.format(total)}đ', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.SizedBox(height: 12),
        pw.Center(child: pw.Text('CẢM ƠN QUÝ KHÁCH!', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('HẸN GẶP LẠI', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        if (qrBytes != null) ...[
          pw.SizedBox(height: 8),
          pw.Center(child: pw.Text('Quét mã để chuyển khoản', style: const pw.TextStyle(fontSize: 8))),
          pw.SizedBox(height: 4),
          pw.Center(child: pw.Image(pw.MemoryImage(qrBytes), width: 90, height: 90)),
        ],
      ]),
    ));
    await Printing.layoutPdf(onLayout: (format) async => doc.save());
  }

  Future<void> _handleCompleteTable(
      BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {bool isBilled = false, String? cardKey, bool isTakeaway = false}) async {
    final clearKey = cardKey ?? tableId;
    final reasonCtrl = TextEditingController();
    final billOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    _PaymentResult? payment;
    if (isBilled) {
      // Đã xuất bill → bước THU TIỀN: bắt buộc chọn phương thức (không còn mặc
      // định "Tiền mặt"), nhập tiền khách đưa / xác nhận đã nhận chuyển khoản.
      final inv = billOrderId == null
          ? null
          : await _invoiceService.getLatestActiveForOrder(billOrderId);
      if (!mounted || !ctx.mounted) return;
      final billTotal = (inv?['totalAmount'] as num?)?.toDouble() ??
          tableOrders.fold<double>(0.0, (s, o) => s + o.totalPrice);
      payment = await showDialog<_PaymentResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _CollectPaymentDialog(tableId: tableId, total: billTotal),
      );
      if (payment == null || !mounted) return;
    } else {
      // Chưa xuất bill → bắt buộc nhập lý do dọn bàn
      final confirmed = await _askClearReason(ctx, tableId, reasonCtrl);
      if (confirmed != true || !mounted) return;
    }

    final orderIds = tableOrders.where((o) => _kActive.contains(o.status)).map((o) => o.id).toList();
    final totalAmount = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
    final currentUser = context.read<AuthProvider>().currentUser;
    // Dọn bàn CHƯA xuất bill mà bàn có tiền = đơn không vào doanh thu → bắt
    // buộc quản lý duyệt (chống thu tiền khách rồi dọn bàn không ghi bill).
    AccountModel? approver;
    if (!isBilled && totalAmount > 0) {
      approver = await requestManagerApproval(
        context,
        action: 'Dọn bàn $tableId chưa xuất bill — ${_vndFmt.format(totalAmount)}đ '
            'sẽ KHÔNG được tính vào doanh thu.\nLý do: ${reasonCtrl.text.trim()}',
      );
      if (approver == null || !mounted) return;
    }

    setState(() => _clearingTableIds.add(clearKey));
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    try {
      if (isBilled && firstOrderId != null) {
        try {
          await _invoiceService.recordPayment(
            firstOrderId,
            method: payment!.method,
            total: payment.total,
            cashReceived: payment.cashReceived,
            transferConfirmed: payment.transferConfirmed,
            staffId: currentUser?.id,
            staffName: currentUser?.fullName,
          );
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Không lưu được thông tin thu tiền, vui lòng thử lại'),
              backgroundColor: Color(0xFFDC2626)));
          }
          return;
        }
      }
      await _orderService.completeAllOrdersAndFreeTable(
        tableId, orderIds,
        clearReason: isBilled ? null : reasonCtrl.text.trim(),
        totalAmount: totalAmount,
        staffId: currentUser?.id,
        staffName: currentUser?.fullName,
        staffRole: currentUser?.role,
        approvedById: approver?.id,
        approvedByName: approver?.fullName,
      );
      if (!isTakeaway) {
        try {
          await _tableService.clearTable(tableId);
        } catch (e) {
          debugPrint('[BOARD] clearTable error: $e');
        }
      }
      if (mounted) setState(() => _billedOrderIds.remove(clearKey));
    } finally {
      if (mounted) setState(() => _clearingTableIds.remove(clearKey));
    }
  }

  void _showDetailDialog(BuildContext ctx, String tableId, List<OrderModel> tableOrders) {
    showDialog(
      context: ctx,
      builder: (_) => _OrderDetailDialog(tableId: tableId, tableOrders: tableOrders, menuCache: _menuCache),
    );
  }

  void _showEditOrderDialog(BuildContext ctx, OrderModel order) {
    showDialog(
      context: ctx,
      builder: (_) => _EditOrderDialog(
        order: order,
        menuCache: _menuCache,
        onSave: (items, vnd, usd) async {
          if (items.isEmpty) {
            await _orderService.deleteOrder(order.id);
          } else {
            await _orderService.updateOrderItems(order.id, items, vnd: vnd, usd: usd);
          }
        },
      ),
    );
  }

  void _showAddProductDialog(BuildContext ctx, String tableId) {
    showDialog(
      context: ctx,
      builder: (_) => _AddProductDialog(
        tableId: tableId,
        menuCache: _menuCache,
        onConfirm: (items) async {
          await _orderService.createOrder(tableId: tableId, items: items);
          if (ctx.mounted) {
            final qty = items.fold<int>(0, (s, i) => s + i.quantity);
            ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
              content: Text('Đã thêm $qty món vào bàn $tableId!'),
              backgroundColor: const Color(0xFF059669),
              duration: const Duration(seconds: 2),
            ));
          }
        },
      ),
    );
  }

  void _showDiscountPicker(BuildContext ctx, String tableId, {required double orderTotal}) {
    final table = _findTable(tableId);
    showDialog(
      context: ctx,
      builder: (_) => _DiscountPickerDialog(
        tableId: tableId,
        discounts: _discounts,
        activeDiscountId: table?.activeDiscount?['id']?.toString(),
        orderTotal: orderTotal,
        onApply: (d) async {
          final data = {
            'id': d.id, 'code': d.code, 'type': d.type, 'value': d.value,
            'maxDiscount': d.maxDiscount, 'description': d.description,
          };
          _applyDiscountLocally(tableId, data);
          await _tableService.setTableDiscount(tableId, data);
        },
        onRemove: () async {
          _applyDiscountLocally(tableId, null);
          await _tableService.clearTableDiscount(tableId);
        },
      ),
    );
  }

  // Mã giảm giá cho ĐƠN mang về (áp ở cấp đơn — mỗi đơn riêng, không dùng chung bàn)
  void _showDiscountPickerForOrder(BuildContext ctx, OrderModel order) {
    final curId = order.discountCode == null
        ? null
        : _discounts.where((x) => x.code == order.discountCode).firstOrNull?.id;
    showDialog(
      context: ctx,
      builder: (_) => _DiscountPickerDialog(
        tableId: order.tableId,
        discounts: _discounts,
        activeDiscountId: curId,
        orderTotal: order.totalPrice,
        onApply: (d) async {
          final amount = _calcDiscount(
            {'type': d.type, 'value': d.value, 'maxDiscount': d.maxDiscount},
            order.totalPrice,
          );
          await _orderService.setOrderDiscount(order.id, code: d.code, amount: amount);
        },
        onRemove: () async {
          await _orderService.setOrderDiscount(order.id, code: null, amount: 0);
        },
      ),
    );
  }

  Future<void> _handleClearServiceRequest(String tableId) async {
    try {
      await _tableService.clearServiceRequest(tableId);
    } catch (e) {
      debugPrint('[BOARD] clearServiceRequest error: $e');
    }
  }

  // ── UI master–detail ──
  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(width: 44, height: 44, child: CircularProgressIndicator(strokeWidth: 3)),
        SizedBox(height: 14),
        Text('ĐANG CHUẨN BỊ...', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 2)),
      ]));
    }

    // Gom nhóm (giống KDS): bàn thường gộp; mang về tách theo từng đơn
    final grouped = <String, List<OrderModel>>{};
    final groupBase = <String, String>{};
    for (final o in _activeOrders) {
      final base = _canonTableId(o.tableId);
      final takeaway = _isTakeawayTable(base);
      final key = takeaway ? '$base@@${o.id}' : base;
      grouped.putIfAbsent(key, () => []).add(o);
      groupBase[key] = base;
    }

    bool matchFilter(String key, List<OrderModel> orders) {
      final allDone = orders.every((o) => _isDone(o.status));
      switch (_statusFilter) {
        case 'Chờ thanh toán': return allDone;
        default: return !allDone; // 'Đặt Món' (mục 'Đã xuất bill' xử lý riêng theo hóa đơn ngày)
      }
    }

    DateTime? earliestOf(List<OrderModel> os) {
      DateTime? e;
      for (final o in os) {
        final t = o.createdAt;
        if (t == null) continue;
        if (e == null || t.isBefore(e)) e = t;
      }
      return e;
    }

    // Bàn chờ LÂU NHẤT lên đầu (ưu tiên xử lý trước) — thay vì sắp theo mã bàn
    final entries = grouped.entries.where((e) => matchFilter(e.key, e.value)).toList()
      ..sort((a, b) {
        final ta = earliestOf(a.value);
        final tb = earliestOf(b.value);
        if (ta == null && tb == null) return groupBase[a.key]!.compareTo(groupBase[b.key]!);
        if (ta == null) return 1;
        if (tb == null) return -1;
        return ta.compareTo(tb);
      });
    final keys = entries.map((e) => e.key).toList();

    // Bàn đang chọn (mặc định bàn đầu tiên)
    final selKey = (keys.contains(_selectedKey) ? _selectedKey : (keys.isNotEmpty ? keys.first : null));
    final billedView = _statusFilter == 'Đã thanh toán';
    final selInv = _todayInvoices.where((m) => m['id'] == _selectedInvoiceId).firstOrNull
        ?? (_todayInvoices.isNotEmpty ? _todayInvoices.first : null);

    // Đếm số lượng cho từng mục lọc
    int cntDatMon = 0, cntCho = 0;
    for (final e in grouped.entries) {
      if (e.value.every((o) => _isDone(o.status))) {
        cntCho++;
      } else {
        cntDatMon++;
      }
    }
    final counts = <String, int>{
      'Đặt Món': cntDatMon,
      'Chờ thanh toán': cntCho,
      'Đã thanh toán': _todayInvoices.length,
    };

    // Tổng tiền dự kiến thu ở các bàn đang "Chờ thanh toán" — giúp thu ngân ước lượng nhanh
    double pendingPaymentTotal = 0;
    for (final e in grouped.entries) {
      if (!e.value.every((o) => _isDone(o.status))) continue;
      final base = groupBase[e.key]!;
      final takeaway = _isTakeawayTable(base) && e.key != base;
      final subtotal = e.value.fold(0.0, (s, o) => s + o.totalPrice);
      final disc = takeaway
          ? e.value.fold(0.0, (s, o) => s + o.discountAmount)
          : _calcDiscount(_findTable(base)?.activeDiscount, subtotal);
      pendingPaymentTotal += (subtotal - disc);
    }

    return Row(children: [
      // ── TRÁI: danh sách ──
      Expanded(
        child: Column(children: [
          _boardFilterBar(counts),
          if (!billedView) _boardSummaryBar(cntDatMon, cntCho, pendingPaymentTotal),
          // Bàn đang gọi (phục vụ / tính tiền) nhưng CHƯA có đơn → không có thẻ bàn
          // nào để hiện banner, nên liệt kê riêng ở đây để nhân viên không bỏ sót.
          if (!billedView) ..._noOrderServiceBanners(groupBase.values.toSet()),
          const Divider(height: 1),
          Expanded(
            child: billedView
                ? _billedList(selInv)
                : (entries.isEmpty
                    ? Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            _statusFilter == 'Đặt Món' ? Icons.restaurant_rounded : Icons.receipt_long_rounded,
                            size: 40, color: const Color(0xFFCBD5E1),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            _statusFilter == 'Đặt Món'
                                ? 'Chưa có bàn nào đang gọi món'
                                : 'Không có bàn nào chờ thanh toán',
                            style: const TextStyle(color: AppColors.textHint, fontSize: 13),
                          ),
                        ]),
                      )
                    : (_gridView
                        // Dạng bảng: lưới thẻ nhiều cột
                        ? GridView.builder(
                            padding: const EdgeInsets.all(12),
                            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 380, mainAxisExtent: 150,
                              crossAxisSpacing: 8, mainAxisSpacing: 8,
                            ),
                            itemCount: entries.length,
                            itemBuilder: (_, i) {
                              final e = entries[i];
                              return _boardListCard(e.key, groupBase[e.key]!, e.value, selKey == e.key);
                            },
                          )
                        // Dạng danh sách: 1 cột
                        : ListView.separated(
                            padding: const EdgeInsets.all(12),
                            itemCount: entries.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (_, i) {
                              final e = entries[i];
                              return _boardListCard(e.key, groupBase[e.key]!, e.value, selKey == e.key);
                            },
                          ))),
          ),
        ]),
      ),
      // Thanh kéo chỉnh độ rộng
      MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragUpdate: (d) => setState(() {
            _detailWidth = (_detailWidth - d.delta.dx).clamp(320.0, 640.0);
          }),
          child: Container(width: 10, color: Colors.transparent, alignment: Alignment.center,
              child: Container(width: 1, color: AppColors.divider)),
        ),
      ),
      // ── PHẢI: chi tiết ──
      SizedBox(
        width: _detailWidth,
        child: billedView
            ? (selInv == null
                ? const Center(child: Text('Chưa có hóa đơn nào hôm nay', style: TextStyle(color: AppColors.textHint)))
                : _billedDetail(selInv))
            : (selKey == null
                ? const Center(child: Text('Chọn một bàn để xem chi tiết', style: TextStyle(color: AppColors.textHint)))
                : _boardDetail(selKey, groupBase[selKey]!, grouped[selKey]!)),
      ),
    ]);
  }

  List<Widget> _noOrderServiceBanners(Set<String> tablesWithOrders) {
    final calling = _tables
        .where((t) => t.serviceRequest != null && !tablesWithOrders.contains(_canonTableId(t.id)))
        .toList()
      ..sort((a, b) => a.serviceRequest!.compareTo(b.serviceRequest!));
    return [
      for (final t in calling)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: t.isBillRequest ? const Color(0xFFEFF6FF) : const Color(0xFFFFFBEB),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: t.isBillRequest ? const Color(0xFF93C5FD) : const Color(0xFFFCD34D), width: 1.5),
          ),
          child: Row(children: [
            Icon(t.isBillRequest ? Icons.receipt_long_rounded : Icons.notifications_active,
                size: 16, color: t.isBillRequest ? const Color(0xFF1D4ED8) : const Color(0xFFB45309)),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Bàn ${t.id} — ${t.serviceRequestLabel} (chưa có đơn)',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800,
                      color: t.isBillRequest ? const Color(0xFF1D4ED8) : const Color(0xFFB45309))),
            ),
            GestureDetector(
              onTap: () => _handleClearServiceRequest(t.id),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                    color: t.isBillRequest ? const Color(0xFF2563EB) : const Color(0xFFFBBF24),
                    borderRadius: BorderRadius.circular(8)),
                child: const Text('Đã xử lý', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ]),
        ),
    ];
  }

  // Thanh tổng quan nhanh — số bàn đang phục vụ + tổng tiền dự kiến chờ thanh toán,
  // để thu ngân/quản lý ước lượng ngay không cần đếm từng thẻ
  Widget _boardSummaryBar(int serving, int waiting, double waitingTotal) {
    Widget stat(IconData icon, Color color, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
        ]);
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: const Color(0xFFF8FAFC),
      child: Row(children: [
        stat(Icons.restaurant_rounded, const Color(0xFFB45309), '$serving bàn đang phục vụ'),
        const SizedBox(width: 16),
        stat(Icons.payments_rounded, const Color(0xFF059669),
            waiting > 0 ? '$waiting bàn chờ thu ${_vndFmt.format(waitingTotal)}đ' : 'Không có bàn chờ thanh toán'),
      ]),
    );
  }

  Widget _boardFilterBar(Map<String, int> counts) {
    const filters = ['Đặt Món', 'Chờ thanh toán', 'Đã thanh toán'];
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.surface,
      child: Row(children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: filters.map((f) {
              final sel = _statusFilter == f;
              final n = counts[f] ?? 0;
              return Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _statusFilter = f),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: sel ? AppColors.primary : AppColors.background,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: sel ? AppColors.primary : AppColors.divider),
                    ),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(f, style: TextStyle(
                        fontSize: 13, fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? Colors.white : AppColors.textSecondary)),
                      const SizedBox(width: 6),
                      Container(
                        height: 20,
                        constraints: const BoxConstraints(minWidth: 20),
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: BoxDecoration(
                          color: sel ? Colors.white.withValues(alpha: 0.28) : AppColors.divider,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        alignment: Alignment.center,
                        child: Text('$n', style: TextStyle(
                          fontSize: 12, height: 1.0, fontWeight: FontWeight.w800,
                          color: sel ? Colors.white : const Color(0xFF64748B))),
                      ),
                    ]),
                  ),
                ),
              );
            }).toList()),
          ),
        ),
        // Nút đổi giao diện: danh sách ↔ dạng bảng (lưới)
        IconButton(
          icon: Icon(_gridView ? Icons.view_list_rounded : Icons.grid_view_rounded, size: 20),
          color: AppColors.textSecondary,
          tooltip: _gridView ? 'Dạng danh sách' : 'Dạng bảng',
          onPressed: () => setState(() => _gridView = !_gridView),
        ),
      ]),
    );
  }

  String _labelFor(String key, String base, List<OrderModel> orders) {
    final takeaway = _isTakeawayTable(base) && key != base;
    if (takeaway) {
      final id = orders.first.id;
      final short = id.length > 4 ? id.substring(id.length - 4) : id;
      return 'Mang về • #$short';
    }
    final t = _findTable(base);
    return t?.name ?? 'Bàn $base';
  }

  Widget _boardListCard(String key, String base, List<OrderModel> orders, bool selected) {
    final takeaway = _isTakeawayTable(base) && key != base;
    final subtotal = orders.fold(0.0, (s, o) => s + o.totalPrice);
    final disc = takeaway
        ? orders.fold(0.0, (s, o) => s + o.discountAmount)
        : _calcDiscount(_findTable(base)?.activeDiscount, subtotal);
    final net = subtotal - disc;
    final allDone = orders.every((o) => _isDone(o.status));
    final billed = takeaway ? _isTakeawayBilled(key, orders) : _isBilled(base, orders);
    final service = !takeaway && _hasServiceRequest(base);
    final itemCount = orders.fold<int>(0, (s, o) => s + o.items.fold<int>(0, (a, i) => a + i.quantity));

    // Giờ đặt sớm nhất + số phút đã trôi qua
    DateTime? earliest;
    for (final o in orders) {
      final t = o.createdAt;
      if (t == null) continue;
      if (earliest == null || t.isBefore(earliest)) earliest = t;
    }
    final elapsed = _elapsedMinutes(earliest);
    final tc = _timerColor(elapsed);
    final placedAt = earliest == null
        ? '--:--'
        : '${earliest.hour.toString().padLeft(2, '0')}:${earliest.minute.toString().padLeft(2, '0')}';

    const billGreen = Color(0xFF059669);
    // Đơn chưa xong và đã chờ lâu (>=10 phút, trùng ngưỡng đỏ của timer) → cảnh báo trễ rõ ràng hơn
    final bool isLate = !allDone && elapsed >= 10;
    Color border = selected
        ? AppColors.primary
        : (service
            ? const Color(0xFFFBBF24)
            : (billed ? billGreen : (isLate ? AppColors.error : AppColors.divider)));

    return GestureDetector(
      onTap: () => setState(() => _selectedKey = key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          // Đã xuất bill: nền xanh nhạt + viền xanh đậm để phân biệt rõ
          color: billed ? const Color(0xFFECFDF5) : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border, width: (selected || billed || isLate) ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(billed ? Icons.verified_rounded : Icons.chair_rounded,
                size: 18, color: billed ? billGreen : AppColors.textHint),
            const SizedBox(width: 6),
            Expanded(child: Text(_labelFor(key, base, orders),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
            const SizedBox(width: 8),
            Text('${_vndFmt.format(disc > 0 ? net : subtotal)}đ',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFEA580C))),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            Icon(Icons.access_time_rounded, size: 13, color: tc),
            const SizedBox(width: 4),
            Text('Đặt $placedAt · ${_fmtElapsed(elapsed)}',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tc)),
            if (isLate) ...[
              const SizedBox(width: 4),
              const Icon(Icons.warning_amber_rounded, size: 14, color: AppColors.error),
            ],
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            // Đã xuất bill → badge xanh đậm chữ trắng (nổi bật, đưa lên đầu)
            if (billed) _boardChip('✓ Đã xuất bill', billGreen, Colors.white),
            // Trạng thái: chưa xong → "Đặt Món"; đã bill → "Chờ đóng bàn".
            // (Đã xong nhưng chưa bill thì không cần chip vì đang ở đúng mục "Chờ thanh toán")
            if (!allDone)
              _boardChip('Đặt Món', const Color(0xFFFEF3C7), const Color(0xFFB45309))
            else if (billed)
              _boardChip('Chờ đóng bàn', const Color(0xFFFFEDD5), const Color(0xFFC2410C)),
            _boardChip('$itemCount món', const Color(0xFFF1F5F9), const Color(0xFF475569)),
            if (service)
              (_findTable(base)?.isBillRequest ?? false)
                  ? _boardChip(_findTable(base)!.serviceRequestLabel, const Color(0xFFDBEAFE), const Color(0xFF1D4ED8))
                  : _boardChip('Gọi phục vụ', const Color(0xFFFEF3C7), const Color(0xFFB45309)),
          ]),
        ]),
      ),
    );
  }

  Widget _boardChip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg)),
  );

  // ── Mục "Đã xuất bill": danh sách hóa đơn trong NGÀY HIỆN TẠI ──
  String _invLabel(String tableId) {
    if (tableId == 'Mang về') return 'Mang về';
    if (tableId.isEmpty) return 'Bàn ?';
    return int.tryParse(tableId) != null ? 'Bàn $tableId' : tableId;
  }

  String _hhmm(dynamic ts) {
    final dt = ts is Timestamp ? ts.toDate() : null;
    if (dt == null) return '--:--';
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _billedList(Map<String, dynamic>? selInv) {
    if (_todayInvoices.isEmpty) {
      return const Center(child: Text('Chưa có hóa đơn nào hôm nay', style: TextStyle(color: AppColors.textHint)));
    }
    bool isSel(Map<String, dynamic> inv) => selInv != null && selInv['id'] == inv['id'];
    if (_gridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 380, mainAxisExtent: 92,
          crossAxisSpacing: 8, mainAxisSpacing: 8,
        ),
        itemCount: _todayInvoices.length,
        itemBuilder: (_, i) => _invoiceCard(_todayInvoices[i], isSel(_todayInvoices[i])),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _todayInvoices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (_, i) => _invoiceCard(_todayInvoices[i], isSel(_todayInvoices[i])),
    );
  }

  Widget _invoiceCard(Map<String, dynamic> inv, bool selected) {
    final tableId = inv['tableId']?.toString() ?? '';
    final total = (inv['totalAmount'] as num?)?.toDouble() ?? 0;
    final staff = inv['staffName']?.toString();
    final items = (inv['items'] as List?) ?? [];
    final itemCount = items.fold<int>(0, (s, m) {
      final q = (m is Map) ? (m['qty'] ?? m['quantity'] ?? 1) : 1;
      return s + (q is num ? q.toInt() : 1);
    });
    final isP2 = inv['isPrint2'] == true || (inv['printCount'] is num && (inv['printCount'] as num) >= 2);

    return GestureDetector(
      onTap: () => setState(() => _selectedInvoiceId = inv['id'] as String?),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: selected ? AppColors.primary : AppColors.divider, width: selected ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.receipt_long_rounded, size: 18, color: Color(0xFF10B981)),
            const SizedBox(width: 6),
            Expanded(child: Text(_invLabel(tableId),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
            Text('${_vndFmt.format(total)}đ',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFEA580C))),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            const Icon(Icons.schedule_rounded, size: 12, color: Color(0xFF94A3B8)),
            const SizedBox(width: 4),
            Expanded(child: Text(
                '${_hhmm(inv['createdAt'])} · $itemCount món${staff != null && staff.isNotEmpty ? ' · $staff' : ''}',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: Color(0xFF64748B)))),
            if (isP2) Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(color: const Color(0xFFFEF3C7), borderRadius: BorderRadius.circular(6)),
              child: const Text('In lại', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: Color(0xFFB45309))),
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _billedDetail(Map<String, dynamic> inv) {
    final tableId = inv['tableId']?.toString() ?? '';
    final staff = inv['staffName']?.toString();
    final subtotal = (inv['subtotal'] as num?)?.toDouble() ?? 0;
    final discount = (inv['discount'] as num?)?.toDouble() ?? 0;
    final total = (inv['totalAmount'] as num?)?.toDouble() ?? 0;
    final code = inv['discountCode']?.toString();
    final parsed = ((inv['items'] as List?) ?? [])
        .map((m) => OrderItem.fromMap(Map<String, dynamic>.from(m as Map))).toList();

    return Column(children: [
      Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: AppColors.surface,
        child: Row(children: [
          Expanded(child: Text('${_invLabel(tableId)} • ${_hhmm(inv['createdAt'])}',
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
          if (staff != null && staff.isNotEmpty)
            Text('NV: $staff', style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: parsed.length,
          separatorBuilder: (_, __) => const Divider(height: 16, thickness: 1, color: Color(0xFFE2E8F0)),
          itemBuilder: (_, i) {
            final it = parsed[i];
            final img = _resolveItemImage(it, _menuCache);
            return Row(children: [
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE2E8F0))),
                clipBehavior: Clip.antiAlias,
                child: (img != null && img.isNotEmpty)
                    ? CachedNetworkImage(imageUrl: img, fit: BoxFit.contain,
                        errorWidget: (_, __, ___) => const Icon(Icons.coffee_rounded, size: 18, color: AppColors.primary))
                    : const Icon(Icons.coffee_rounded, size: 18, color: AppColors.primary),
              ),
              const SizedBox(width: 10),
              Expanded(child: Text('${it.quantity}x ${it.name}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1E293B)))),
              Text('${_vndFmt.format(it.price * it.quantity)}đ',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF475569))),
            ]);
          },
        ),
      ),
      const Divider(height: 1),
      Container(
        padding: const EdgeInsets.all(14),
        color: AppColors.surface,
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Tạm tính', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            Text('${_vndFmt.format(subtotal)}đ', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
          ]),
          if (discount > 0) ...[
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Giảm giá${code != null && code.isNotEmpty ? ' [$code]' : ''}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF047857))),
              Text('-${_vndFmt.format(discount)}đ', style: const TextStyle(fontSize: 13, color: Color(0xFF047857))),
            ]),
          ],
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Thành tiền', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            Text('${_vndFmt.format(total)}đ', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.primary)),
          ]),
        ]),
      ),
    ]);
  }

  Widget _boardDetail(String key, String base, List<OrderModel> orders) {
    final takeaway = _isTakeawayTable(base) && key != base;
    final subtotal = orders.fold(0.0, (s, o) => s + o.totalPrice);
    final activeDisc = takeaway ? null : _findTable(base)?.activeDiscount;
    // Takeaway: giảm giá ở cấp đơn (order.discountAmount); bàn thường: cấp bàn
    final takeawayCode = takeaway
        ? orders.map((o) => o.discountCode).firstWhere((c) => c != null && c.isNotEmpty, orElse: () => null)
        : null;
    final disc = takeaway
        ? orders.fold(0.0, (s, o) => s + o.discountAmount)
        : _calcDiscount(activeDisc, subtotal);
    final net = subtotal - disc;
    final allDone = orders.every((o) => _isDone(o.status));
    final billed = takeaway ? _isTakeawayBilled(key, orders) : _isBilled(base, orders);
    final service = !takeaway && _hasServiceRequest(base);
    final bill = service && (_findTable(base)?.isBillRequest ?? false);
    final isClearing = _clearingTableIds.contains(key);

    return Column(children: [
      // Header
      Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        color: AppColors.surface,
        child: Row(children: [
          Expanded(child: Text(_labelFor(key, base, orders),
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
          // Giảm giá (takeaway → cấp đơn; bàn thường → cấp bàn)
          IconButton(
            icon: Icon(
              (takeaway ? (takeawayCode != null) : (activeDisc != null))
                  ? Icons.local_offer : Icons.local_offer_outlined,
              size: 20),
            color: (takeaway ? (takeawayCode != null) : (activeDisc != null))
                ? const Color(0xFF059669) : AppColors.textSecondary,
            tooltip: 'Giảm giá',
            onPressed: () => takeaway
                ? _showDiscountPickerForOrder(context, orders.first)
                : _showDiscountPicker(context, base, orderTotal: subtotal),
          ),
          // Thêm món
          IconButton(
            icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
            color: const Color(0xFF059669),
            tooltip: 'Thêm món',
            onPressed: () => _showAddProductDialog(context, base),
          ),
          // Xem chi tiết (con mắt)
          IconButton(
            icon: const Icon(Icons.visibility_outlined, size: 20),
            color: AppColors.textSecondary,
            tooltip: 'Xem chi tiết',
            onPressed: () => _showDetailDialog(context, base, orders),
          ),
        ]),
      ),
      const Divider(height: 1),
      // Banner gọi phục vụ (vàng) / gọi tính tiền (xanh dương)
      if (service)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bill ? const Color(0xFFEFF6FF) : const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12),
            border: Border.all(color: bill ? const Color(0xFF93C5FD) : const Color(0xFFFDE68A)),
          ),
          child: Row(children: [
            Icon(bill ? Icons.receipt_long_rounded : Icons.notifications_active, size: 15,
                color: bill ? const Color(0xFF1D4ED8) : const Color(0xFFB45309)),
            const SizedBox(width: 6),
            Expanded(child: Text(_findTable(base)?.serviceRequestMessage ?? 'Khách đang gọi phục vụ!',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700,
                    color: bill ? const Color(0xFF1D4ED8) : const Color(0xFFB45309)))),
            GestureDetector(
              onTap: () => _handleClearServiceRequest(base),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: bill ? const Color(0xFF2563EB) : const Color(0xFFFBBF24), borderRadius: BorderRadius.circular(8)),
                child: const Text('Đã xử lý', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ),
          ]),
        ),
      // Danh sách đơn (tái dùng _OrderBlock)
      Expanded(
        child: ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: orders.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (_, i) => _OrderBlock(
            order: orders[i],
            menuCache: _menuCache,
            onUpdateStatus: _handleUpdateStatus,
            onEdit: () => _showEditOrderDialog(context, orders[i]),
          ),
        ),
      ),
      const Divider(height: 1),
      // Tổng tiền + thao tác
      Container(
        padding: const EdgeInsets.all(14),
        color: AppColors.surface,
        child: Column(children: [
          if (disc > 0) ...[
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              const Text('Tạm tính', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
              Text('${_vndFmt.format(subtotal)}đ', style: const TextStyle(fontSize: 13, color: Color(0xFF64748B))),
            ]),
            const SizedBox(height: 4),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Giảm giá${(takeaway ? takeawayCode : activeDisc?['code']) != null ? ' [${takeaway ? takeawayCode : activeDisc!['code']}]' : ''}',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF047857))),
              Text('-${_vndFmt.format(disc)}đ', style: const TextStyle(fontSize: 13, color: Color(0xFF047857))),
            ]),
            const SizedBox(height: 6),
          ],
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Tổng cộng', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            Text('${_vndFmt.format(net)}đ', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.primary)),
          ]),
          const SizedBox(height: 12),
          // Hàng nút: Thanh toán + Dọn bàn
          Row(children: [
            Expanded(child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                disabledBackgroundColor: const Color(0xFFCBD5E1),
              ),
              onPressed: (allDone && !isClearing)
                  ? () => _handleOpenPayment(context, base, orders, cardKey: key, isTakeaway: takeaway)
                  : null,
              icon: const Icon(Icons.credit_card_rounded, size: 18),
              label: Text(allDone ? 'Thanh toán' : 'Đang pha', style: const TextStyle(fontWeight: FontWeight.w700)),
            )),
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                disabledBackgroundColor: const Color(0xFFCBD5E1),
              ),
              onPressed: (allDone && !isClearing)
                  ? () => _handleCompleteTable(context, base, orders, isBilled: billed, cardKey: key, isTakeaway: takeaway)
                  : null,
              icon: isClearing
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.delete_outline_rounded, size: 18),
              label: const Text('Dọn bàn', style: TextStyle(fontWeight: FontWeight.w700)),
            )),
          ]),
        ]),
      ),
    ]);
  }
}

/// Hỏi lý do dọn bàn khi CHƯA xuất bill (bắt buộc nhập).
Future<bool?> _askClearReason(BuildContext ctx, String tableId, TextEditingController reasonCtrl) {
  return showDialog<bool>(
    context: ctx,
    builder: (dCtx) => StatefulBuilder(
      builder: (sbCtx, setSB) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Dọn bàn $tableId?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Bàn này chưa xuất bill. Vui lòng nhập lý do dọn bàn trước khi tiếp tục.',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
          const SizedBox(height: 12),
          TextField(
            controller: reasonCtrl,
            onChanged: (_) => setSB(() {}),
            decoration: const InputDecoration(
              hintText: 'VD: Khách tự thanh toán, dọn sai bàn...',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            ),
            maxLines: 2,
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Huỷ')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFDC2626), foregroundColor: Colors.white),
            onPressed: reasonCtrl.text.trim().isEmpty ? null : () => Navigator.pop(dCtx, true),
            child: const Text('Dọn bàn'),
          ),
        ],
      ),
    ),
  );
}

class _PaymentResult {
  final String method; // 'Tiền mặt' | 'Chuyển khoản'
  final double total;
  final double? cashReceived; // chỉ với tiền mặt
  final bool transferConfirmed;
  const _PaymentResult({
    required this.method,
    required this.total,
    this.cashReceived,
    this.transferConfirmed = false,
  });
}

/// Bước THU TIỀN trước khi dọn bàn đã xuất bill:
/// - Bắt buộc chọn phương thức (không có mặc định → tránh thu tiền mặt mà
///   để nhầm/cố ý "Chuyển khoản" làm lệch két).
/// - Tiền mặt: nhập tiền khách đưa (có nút chọn nhanh) → hiện tiền thối lại.
/// - Chuyển khoản: hiện QR đúng số tiền + bắt buộc xác nhận đã thấy tiền vào TK.
class _CollectPaymentDialog extends StatefulWidget {
  final String tableId;
  final double total;
  const _CollectPaymentDialog({required this.tableId, required this.total});

  @override
  State<_CollectPaymentDialog> createState() => _CollectPaymentDialogState();
}

class _CollectPaymentDialogState extends State<_CollectPaymentDialog> {
  String? _method;
  final _cashCtrl = TextEditingController();
  bool _transferConfirmed = false;

  double get _total => widget.total;
  double? get _cash {
    final digits = _cashCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? null : double.parse(digits);
  }

  @override
  void initState() {
    super.initState();
    BankQrService.instance.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _cashCtrl.dispose();
    super.dispose();
  }

  // Ô nhập tiền khách đưa: ngăn cách hàng nghìn bằng dấu phẩy (vd: 120,000).
  static final _cashInputFmt = NumberFormat('#,###', 'en_US');

  void _setCash(double v) {
    _cashCtrl.text = _cashInputFmt.format(v);
    setState(() {});
  }

  bool get _canConfirm {
    if (_method == 'Tiền mặt') return (_cash ?? -1) >= _total;
    if (_method == 'Chuyển khoản') return _transferConfirmed;
    return false;
  }

  Widget _methodTile(String m, IconData icon) {
    final sel = _method == m;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _method = m),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: sel ? const Color(0xFFEFF6FF) : Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: sel ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0), width: sel ? 2 : 1),
          ),
          child: Column(children: [
            Icon(icon, size: 22, color: sel ? const Color(0xFF2563EB) : const Color(0xFF94A3B8)),
            const SizedBox(height: 4),
            Text(m, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                color: sel ? const Color(0xFF2563EB) : const Color(0xFF1E293B))),
          ]),
        ),
      ),
    );
  }

  Widget _cashSection() {
    final cash = _cash;
    final change = cash == null ? null : cash - _total;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 14),
      TextField(
        controller: _cashCtrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.right,
        onChanged: (v) {
          final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
          final formatted = digits.isEmpty ? '' : _cashInputFmt.format(int.parse(digits));
          _cashCtrl.value = TextEditingValue(
            text: formatted, selection: TextSelection.collapsed(offset: formatted.length));
          setState(() {});
        },
        decoration: const InputDecoration(
          labelText: 'Khách đưa (VNĐ)',
          border: OutlineInputBorder(),
          isDense: true,
          prefixIcon: Icon(Icons.payments_outlined),
        ),
      ),
      const SizedBox(height: 8),
      _QuickPickButton(
        label: 'Đủ tiền',
        selected: _cash == _total,
        onTap: () => _setCash(_total),
      ),
      if (change != null) ...[
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: (change >= 0 ? const Color(0xFF059669) : const Color(0xFFDC2626)).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            change >= 0 ? 'Thối lại khách: ${_vndFmt.format(change)}đ' : 'Còn thiếu: ${_vndFmt.format(-change)}đ',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                color: change >= 0 ? const Color(0xFF059669) : const Color(0xFFDC2626)),
          ),
        ),
      ],
    ]);
  }

  Widget _transferSection() {
    final qr = BankQrService.instance;
    return Column(children: [
      const SizedBox(height: 14),
      if (qr.shouldPrint)
        Image.network(
          qr.imageUrl(amount: _total, content: 'Ban ${widget.tableId}'),
          width: 180, height: 180,
          errorBuilder: (_, __, ___) => const Text('Không tải được mã QR',
              style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
        )
      else
        const Text('Chưa cấu hình QR ngân hàng (Cài đặt → QR ngân hàng).',
            style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
      const SizedBox(height: 6),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _transferConfirmed,
        onChanged: (v) => setState(() => _transferConfirmed = v ?? false),
        title: Text('Đã kiểm tra: tài khoản quán đã nhận đủ ${_vndFmt.format(_total)}đ',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Thu tiền bàn ${widget.tableId}'),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('Cần thu', style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
              const Spacer(),
              Text('${_vndFmt.format(_total)}đ',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF1E293B))),
            ]),
            const SizedBox(height: 14),
            const Text('Phương thức thanh toán',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
            const SizedBox(height: 6),
            Row(children: [
              _methodTile('Tiền mặt', Icons.payments_outlined),
              const SizedBox(width: 10),
              _methodTile('Chuyển khoản', Icons.account_balance_outlined),
            ]),
            if (_method == 'Tiền mặt') _cashSection(),
            if (_method == 'Chuyển khoản') _transferSection(),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Huỷ')),
        ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF059669), foregroundColor: Colors.white),
          onPressed: _canConfirm
              ? () => Navigator.pop(context, _PaymentResult(
                    method: _method!,
                    total: _total,
                    cashReceived: _method == 'Tiền mặt' ? _cash : null,
                    transferConfirmed: _method == 'Chuyển khoản' && _transferConfirmed,
                  ))
              : null,
          child: const Text('Đã thu tiền · Dọn bàn'),
        ),
      ],
    );
  }
}

/// Nút chọn nhanh (mệnh giá khách đưa...) — màu rõ ràng, dễ bấm trên máy POS:
/// nền trắng + viền + chữ đậm tối; đang chọn → nền xanh chữ trắng.
class _QuickPickButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _QuickPickButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? const Color(0xFF2563EB) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minWidth: 72, minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xFF2563EB) : const Color(0xFFCBD5E1),
              width: 1.5,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: selected ? Colors.white : const Color(0xFF1E293B),
              )),
        ),
      ),
    );
  }
}
