import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../../core/theme/app_theme.dart';
import '../../models/menu_item_model.dart';
import '../../models/order_model.dart';
import '../../models/table_model.dart';
import '../../models/discount_model.dart';
import '../../services/menu_service.dart';
import '../../services/order_service.dart';
import '../../services/table_service.dart';
import '../../services/discount_service.dart';
import '../../services/invoice_service.dart';

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

// Dòng label/giá trị trong hóa đơn PDF
pw.Widget _pdfRow(String label, String value) => pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label, style: const pw.TextStyle(fontSize: 9)),
        pw.Text(value, style: const pw.TextStyle(fontSize: 9)),
      ],
    );

final _vndFmt = NumberFormat('#,###', 'vi_VN');

// ═══════════════════════════════════════════════════════
//  ENTRY POINT
// ═══════════════════════════════════════════════════════
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab = TabController(length: 2, vsync: this);
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _tab.addListener(() {
      if (_tab.indexIsChanging || _tabIndex != _tab.index) {
        setState(() => _tabIndex = _tab.index);
      }
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
      body: Column(children: [
        _buildTopBar(),
        Expanded(
          child: IndexedStack(
            index: _tabIndex,
            children: const [_POSTab(), _KDSTab()],
          ),
        ),
      ]),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(children: [
        _tabBtn(0, Icons.point_of_sale_rounded, 'POS - Tạo đơn'),
        const SizedBox(width: 8),
        _tabBtn(1, Icons.receipt_long_rounded, 'Đơn hàng'),
      ]),
    );
  }

  Widget _tabBtn(int idx, IconData icon, String label) {
    final active = _tabIndex == idx;
    return GestureDetector(
      onTap: () {
        _tab.animateTo(idx);
        setState(() => _tabIndex = idx);
      },
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
}

// ═══════════════════════════════════════════════════════
//  POS TAB
// ═══════════════════════════════════════════════════════
class _POSTab extends StatefulWidget {
  const _POSTab();
  @override
  State<_POSTab> createState() => _POSTabState();
}

class _POSTabState extends State<_POSTab> {
  final _menuService  = MenuService();
  final _orderService = OrderService();

  final List<_CartEntry> _cart = [];
  String _tableId = 'T1';
  String _catFilter = 'Tất cả';
  bool _submitting = false;

  double get _total => _cart.fold(0, (s, e) => s + e.subtotal);

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
        flex: 3,
        child: Column(children: [
          // Chọn bàn
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppColors.surface,
            child: Row(children: [
              const Text('Bàn: ', style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(width: 8),
              ...['T1','T2','T3','T4','T5','T6','Mang về'].map((t) => Padding(
                padding: const EdgeInsets.only(right: 6),
                child: GestureDetector(
                  onTap: () => setState(() => _tableId = t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: _tableId == t ? AppColors.primary : AppColors.background,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: _tableId == t ? AppColors.primary : AppColors.divider),
                    ),
                    child: Text(t, style: TextStyle(
                      color: _tableId == t ? Colors.white : AppColors.textSecondary,
                      fontSize: 12, fontWeight: FontWeight.w500,
                    )),
                  ),
                ),
              )),
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
                final filtered = _catFilter == 'Tất cả'
                    ? all : all.where((m) => m.category == _catFilter).toList();
                return Column(children: [
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
                      itemBuilder: (_, i) => _MenuCard(
                        item: filtered[i],
                        onTap: () => _addItem(filtered[i]),
                      ),
                    ),
                  ),
                ]);
              },
            ),
          ),
        ]),
      ),
      const VerticalDivider(width: 1),
      // Giỏ hàng
      SizedBox(
        width: 280,
        child: Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: AppColors.surface,
            child: Row(children: [
              const Icon(Icons.shopping_cart_outlined, size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              const Text('Giỏ hàng', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
              const Spacer(),
              Text('Bàn $_tableId', style: const TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600, fontSize: 13)),
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
                    itemBuilder: (_, i) => _CartRow(
                      entry: _cart[i],
                      onRemove: () => _removeItem(i),
                      onQtyChange: (d) => _changeQty(i, d),
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

// ── Menu Card ─────────────────────────────────────────────────────────────────
class _MenuCard extends StatelessWidget {
  final MenuItemModel item;
  final VoidCallback onTap;
  const _MenuCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
              child: Container(
                color: AppColors.background,
                child: item.imageUrl != null && item.imageUrl!.isNotEmpty
                    ? Image.network(item.imageUrl!, fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.coffee_rounded, size: 36, color: AppColors.primary)))
                    : const Center(child: Icon(Icons.coffee_rounded, size: 36, color: AppColors.primary)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
              const SizedBox(height: 2),
              Text('${_vndFmt.format(item.price)}đ',
                  style: const TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w700)),
            ]),
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
    return Row(children: [
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
  final Set<String> _billedTableIds = {};

  // ── Âm thanh + giọng đọc (giống useAudioNotification web) ──
  final AudioPlayer _notifPlayer = AudioPlayer();
  final AudioPlayer _warnPlayer  = AudioPlayer();
  final FlutterTts _tts = FlutterTts();
  bool _audioUnlocked = false;
  bool _audioSeeded = false;
  Set<String> _prevOrderIds = {};
  Set<String> _prevServiceIds = {};
  List<OrderModel> _activeOrders = [];

  @override
  void initState() {
    super.initState();
    _tts.setLanguage('vi-VN');
    _tts.setSpeechRate(0.9);
    // Cập nhật timer mỗi phút (giống setInterval 60000 trong web) + cảnh báo đơn trễ
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_audioUnlocked) {
        for (final o in _activeOrders) {
          if (o.status == 'pending' && _elapsedMinutes(o.createdAt) >= 10) {
            _playWarning('Chú ý, bàn số ${o.tableId} đang bị trễ món.');
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
      final serviceIds = tables.where((t) => t.serviceRequest != null).map((t) => t.id).toSet();
      if (_audioUnlocked) {
        for (final id in serviceIds) {
          if (!_prevServiceIds.contains(id)) {
            _playWarning('Bàn $id đang gọi nhân viên!');
            break;
          }
        }
      }
      _prevServiceIds = serviceIds;
      setState(() => _tables = tables);
    });
    // Load discounts đang hoạt động (giống discountService.subscribe web)
    _discountSub = _discountService.streamDiscounts().listen((discounts) {
      final now = DateTime.now();
      if (mounted) setState(() => _discounts = discounts.where((d) {
        if (!d.active) return false;
        if (d.expiresAt != null && now.isAfter(d.expiresAt!)) return false;
        if (d.isMaxedOut) return false;
        return true;
      }).toList());
    });
    // Theo dõi đơn để phát chuông + đọc "Bàn số X đặt món" khi có đơn mới
    _ordersAudioSub = FirebaseFirestore.instance.collection('orders').snapshots().listen((snap) {
      final active = <OrderModel>[];
      for (final d in snap.docs) {
        try {
          final o = OrderModel.fromDoc(d);
          if (_kActive.contains(o.status)) active.add(o);
        } catch (_) {}
      }
      final ids = active.map((o) => o.id).toSet();
      if (!_audioSeeded) {
        _audioSeeded = true;
        _prevOrderIds = ids;
        _activeOrders = active;
        return;
      }
      final newOnes = active.where((o) => !_prevOrderIds.contains(o.id)).toList();
      if (newOnes.isNotEmpty && _audioUnlocked) {
        _safePlay(_notifPlayer, 'sounds/notification.wav');
        for (final o in newOnes) {
          _tts.speak('Bàn số ${o.tableId} đặt món');
        }
      }
      _prevOrderIds = ids;
      _activeOrders = active;
    });
  }

  void _safePlay(AudioPlayer p, String asset) {
    try { p.play(AssetSource(asset)); } catch (_) {}
  }

  void _playWarning(String msg) {
    _safePlay(_warnPlayer, 'sounds/warning.wav');
    try { _tts.speak(msg); } catch (_) {}
  }

  void _unlockAudio() {
    // Desktop không cần unlock để phát, nhưng giữ overlay giống web
    _safePlay(_notifPlayer, 'sounds/notification.wav');
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
    _tts.stop();
    super.dispose();
  }

  // Tìm table doc theo id — giống web: t.id === tableId || t.id === padStart(2,'0')
  TableModel? _findTable(String tableId) {
    final padded = tableId.trim().padLeft(2, '0');
    for (final t in _tables) {
      if (t.id == tableId.trim() || t.id == padded) return t;
    }
    return null;
  }

  // Bàn đã xuất bill — giống web billedTableIds:
  // lastBilledAt tồn tại và (chưa dọn bao giờ | lastBilledAt > clearedAt)
  // + overlay local (optimistic ngay sau khi xuất bill)
  bool _isBilled(String tableId) {
    if (_billedTableIds.contains(tableId)) return true;
    final t = _findTable(tableId);
    if (t?.lastBilledAt == null) return false;
    final cleared = t!.clearedAt;
    return cleared == null || t.lastBilledAt!.isAfter(cleared);
  }

  // Bàn đang gọi phục vụ — giống web serviceRequestTableIds
  bool _hasServiceRequest(String tableId) => _findTable(tableId)?.serviceRequest != null;

  // Tương đương handleUpdateStatus trong web
  void _handleUpdateStatus(String orderId, String status) {
    _orderService.updateStatus(orderId, status);
  }

  // Tương đương handleOpenPayment trong web — mở InvoiceModal (xuất + in hóa đơn)
  // Web: lưu invoice + updateTableLastBilledAt + incrementUsage, KHÔNG đổi status đơn
  void _handleOpenPayment(BuildContext ctx, String tableId, List<OrderModel> tableOrders) {
    final table = _findTable(tableId);
    final clearedAt = table?.clearedAt;
    DateTime? sessionStart;
    for (final o in tableOrders) {
      final t = o.createdAt;
      if (t == null) continue;
      if (sessionStart == null || t.isBefore(sessionStart)) sessionStart = t;
    }
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    final existingFuture = _invoiceService.getLatestActiveForTable(
        tableId, clearedAt: clearedAt, sessionStart: sessionStart);

    showDialog(
      context: ctx,
      builder: (dCtx) => _InvoiceDialog(
        tableId: tableId,
        tableOrders: tableOrders,
        activeDiscount: table?.activeDiscount,
        existingInvoiceFuture: existingFuture,
        onPrint: (data) async {
          final act = table?.activeDiscount;
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
            }, reason: data['reason'], previousInvoiceId: data['previousInvoiceId']);
            await _orderService.updateTableLastBilledAt(tableId);
            final actId = act?['id'];
            if (actId != null) {
              await _discountService.incrementUsage(actId.toString());
            }
          }
          if (mounted) setState(() => _billedTableIds.add(tableId));
          // In hóa đơn (mở hộp thoại in của hệ thống)
          try {
            await _printInvoice(tableId, tableOrders, data);
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
          }
        },
      ),
    );
  }

  // In hóa đơn ra PDF rồi mở hộp thoại in của hệ thống (giống window.print web)
  Future<void> _printInvoice(String tableId, List<OrderModel> tableOrders, Map<String, dynamic> data) async {
    // Font Unicode để in được tiếng Việt (font mặc định của pdf không có dấu)
    final font = await PdfGoogleFonts.robotoRegular();
    final fontBold = await PdfGoogleFonts.robotoBold();
    final doc = pw.Document(theme: pw.ThemeData.withFont(base: font, bold: fontBold));
    final items = tableOrders.expand((o) => o.items).toList();
    final subtotal = (data['subtotal'] as num?)?.toDouble() ?? 0;
    final serviceAmount = (data['serviceAmount'] as num?)?.toDouble() ?? 0;
    final discount = (data['discount'] as num?)?.toDouble() ?? 0;
    final total = (data['finalTotal'] as num?)?.toDouble() ?? 0;
    final code = data['discountCode']?.toString();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final timeStr = '${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}';

    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.roll80,
      build: (c) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Center(child: pw.Text('EM COFFEE', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('29 Nguyễn Hiến Lê, Hoà Xuân Đà Nẵng', style: const pw.TextStyle(fontSize: 8))),
        pw.Center(child: pw.Text('Hotline: 0742-619-457', style: const pw.TextStyle(fontSize: 8))),
        pw.Divider(thickness: 1),
        pw.Text('Bàn: $tableId', style: const pw.TextStyle(fontSize: 9)),
        pw.Text('Thời gian: $timeStr', style: const pw.TextStyle(fontSize: 9)),
        pw.Divider(),
        ...items.map((it) => pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Expanded(child: pw.Text('${it.quantity} x ${it.name}', style: const pw.TextStyle(fontSize: 9))),
          pw.Text('${_vndFmt.format(it.price * it.quantity)}đ', style: const pw.TextStyle(fontSize: 9)),
        ])),
        pw.Divider(),
        _pdfRow('Tạm tính', '${_vndFmt.format(subtotal)}đ'),
        if (serviceAmount > 0) _pdfRow('Phí dịch vụ', '${_vndFmt.format(serviceAmount)}đ'),
        if (discount > 0) _pdfRow('Giảm giá${code != null ? ' [$code]' : ''}', '-${_vndFmt.format(discount)}đ'),
        pw.Divider(thickness: 1),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [
          pw.Text('THÀNH TIỀN', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          pw.Text('${_vndFmt.format(total)}đ', style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
        ]),
        pw.Center(child: pw.Text('≈ \$${(total / 26000).toStringAsFixed(2)} USD', style: const pw.TextStyle(fontSize: 8, fontStyle: pw.FontStyle.italic))),
        pw.SizedBox(height: 12),
        pw.Center(child: pw.Text('CẢM ƠN QUÝ KHÁCH!', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
        pw.Center(child: pw.Text('HẸN GẶP LẠI', style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold))),
      ]),
    ));
    await Printing.layoutPdf(onLayout: (format) async => doc.save());
  }

  // Tương đương handleCompleteTable + executeClearTable trong web — dọn bàn
  // Web: requireReason: !isBilled (chưa bill → lý do; đã bill → chọn PTTT)
  Future<void> _handleCompleteTable(
      BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {bool isBilled = false}) async {
    final reasonCtrl = TextEditingController();
    String payMethod = 'Tiền mặt';

    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => StatefulBuilder(
        builder: (sbCtx, setSB) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Dọn bàn $tableId?'),
          content: isBilled
              // Đã xuất bill → chọn phương thức thanh toán (giống web showPaymentMethod)
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Chọn phương thức thanh toán trước khi đóng bàn.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                  const SizedBox(height: 12),
                  ...['Tiền mặt', 'Chuyển khoản', 'Thẻ'].map((m) => Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: GestureDetector(
                      onTap: () => setSB(() => payMethod = m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: payMethod == m ? const Color(0xFFEFF6FF) : Colors.white,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: payMethod == m ? const Color(0xFF2563EB) : const Color(0xFFE2E8F0),
                            width: payMethod == m ? 2 : 1),
                        ),
                        child: Row(children: [
                          Icon(m == 'Tiền mặt' ? Icons.payments_outlined
                              : m == 'Chuyển khoản' ? Icons.account_balance_outlined : Icons.credit_card_rounded,
                              size: 16, color: payMethod == m ? const Color(0xFF2563EB) : const Color(0xFF94A3B8)),
                          const SizedBox(width: 8),
                          Text(m, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600,
                              color: payMethod == m ? const Color(0xFF2563EB) : const Color(0xFF1E293B))),
                          const Spacer(),
                          if (payMethod == m) const Icon(Icons.check_circle, size: 18, color: Color(0xFF2563EB)),
                        ]),
                      ),
                    ),
                  )),
                ])
              // Chưa xuất bill → bắt buộc nhập lý do
              : Column(mainAxisSize: MainAxisSize.min, children: [
                  const Text('Bàn này chưa xuất bill. Vui lòng nhập lý do dọn bàn trước khi tiếp tục.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reasonCtrl,
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
              onPressed: () {
                if (!isBilled && reasonCtrl.text.trim().isEmpty) return;
                Navigator.pop(dCtx, true);
              },
              child: const Text('Dọn bàn'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _clearingTableIds.add(tableId));
    final orderIds = tableOrders.where((o) => _kActive.contains(o.status)).map((o) => o.id).toList();
    final totalAmount = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    try {
      // Giống web: nếu đã bill → ghi PTTT vào hóa đơn TRƯỚC khi clear
      if (isBilled && firstOrderId != null) {
        await _invoiceService.setPaymentMethod(firstOrderId, payMethod);
      }
      // completeAllOrdersAndFreeTable: đóng orders (closed) + clearedAt + clearLogs (nếu có lý do)
      await _orderService.completeAllOrdersAndFreeTable(
        tableId, orderIds,
        clearReason: isBilled ? null : reasonCtrl.text.trim(),
        totalAmount: totalAmount,
      );
      // clearTable: xoá cart + reset sessionToken → QR/URL bàn hết hiệu lực
      try {
        await _tableService.clearTable(tableId);
      } catch (e) {
        debugPrint('[KDS] clearTable error: $e');
      }
      if (mounted) setState(() => _billedTableIds.remove(tableId));
    } finally {
      if (mounted) setState(() => _clearingTableIds.remove(tableId));
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
          await _orderService.updateOrderItems(order.id, items, vnd: vnd, usd: usd);
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
  void _showDiscountPicker(BuildContext ctx, String tableId) {
    final table = _findTable(tableId);
    showDialog(
      context: ctx,
      builder: (_) => _DiscountPickerDialog(
        tableId: tableId,
        discounts: _discounts,
        activeDiscountId: table?.activeDiscount?['id']?.toString(),
        onApply: (d) async {
          await _tableService.setTableDiscount(tableId, {
            'id': d.id,
            'code': d.code,
            'type': d.type,
            'value': d.value,
            'maxDiscount': d.maxDiscount,
            'description': d.description,
          });
        },
        onRemove: () async {
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
      StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('orders').snapshots(),
      builder: (ctx, snap) {
        if (snap.hasError) {
          return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, color: Color(0xFFDC2626), size: 48),
            const SizedBox(height: 12),
            Text('${snap.error}', style: const TextStyle(color: Color(0xFFDC2626), fontSize: 12)),
          ]));
        }

        if (!snap.hasData) {
          return const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(height: 16),
            Text('ĐANG CHUẨN BỊ...', style: TextStyle(color: Color(0xFF94A3B8), fontSize: 12, letterSpacing: 2)),
          ]));
        }

        // Lọc active orders — giống activeOrders trong web
        final allOrders = <OrderModel>[];
        for (final doc in snap.data!.docs) {
          try {
            final o = OrderModel.fromDoc(doc);
            if (_kActive.contains(o.status)) allOrders.add(o);
          } catch (e) {
            debugPrint('[KDS] parse error ${doc.id}: $e');
          }
        }

        // Gom theo bàn — giống groupedOrders trong web
        final Map<String, List<OrderModel>> groupedOrders = {};
        for (final o in allOrders) {
          final tid = o.tableId.isEmpty ? 'Bàn chưa xác định' : o.tableId;
          groupedOrders.putIfAbsent(tid, () => []).add(o);
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
                          Text('Bàn ${t.id} — Gọi phục vụ',
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
                      final tableId     = entry.key;
                      final tableOrders = entry.value;
                      final tableTotal  = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
                      final isAllCompleted = tableOrders.every((o) => _isDone(o.status));
                      final isClearing = _clearingTableIds.contains(tableId);
                      final isBilled   = _isBilled(tableId);
                      final hasServiceRequest = _hasServiceRequest(tableId);

                      return SizedBox(
                        width: (constraints.maxWidth - (cols - 1) * 8) / cols,
                        child: _TableCard(
                          tableId: tableId,
                          tableOrders: tableOrders,
                          tableTotal: tableTotal,
                          isAllCompleted: isAllCompleted,
                          isClearing: isClearing,
                          isBilled: isBilled,
                          hasServiceRequest: hasServiceRequest,
                          activeDiscount: _findTable(tableId)?.activeDiscount,
                          menuCache: _menuCache,
                          onUpdateStatus: _handleUpdateStatus,
                          onPayment: () => _handleOpenPayment(ctx, tableId, tableOrders),
                          onClearTable: () => _handleCompleteTable(ctx, tableId, tableOrders, isBilled: isBilled),
                          onViewDetail: () => _showDetailDialog(ctx, tableId, tableOrders),
                          onAddProduct: () => _showAddProductDialog(ctx, tableId),
                          onEditOrder: (order) => _showEditOrderDialog(ctx, order),
                          onPickDiscount: () => _showDiscountPicker(ctx, tableId),
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
      },
      ),
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
  final List<OrderModel> tableOrders;
  final double tableTotal;
  final bool isAllCompleted;
  final bool isClearing;
  final bool isBilled;
  final bool hasServiceRequest;
  final Map<String, dynamic>? activeDiscount;
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
    required this.tableOrders,
    required this.tableTotal,
    required this.isAllCompleted,
    required this.isClearing,
    required this.isBilled,
    required this.hasServiceRequest,
    required this.activeDiscount,
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
              const Expanded(child: Text('Khách đang gọi phục vụ!',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB45309)))),
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
                child: Text('Bàn: $tableId', style: const TextStyle(
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
            Row(children: [
              RichText(
                text: TextSpan(
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFEA580C)),
                  children: [
                    TextSpan(text: '${_vndFmt.format(tableTotal)}đ'),
                    TextSpan(
                      text: '  ≈ \$${tableOrders.fold(0.0, (s, o) => s + o.totalUsd).toStringAsFixed(2)} USD',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w400, color: Color(0xFF94A3B8)),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              // Mã giảm giá — giống web: có activeDiscount → xanh + code + chevron, chưa có → dashed "Mã GG"
              GestureDetector(
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
          Text('$elapsed phút', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tc)),
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
        ...order.items.map((item) {
          // Giống web: dùng item.image trực tiếp, fallback menu cache theo item.id
          final imageUrl = (item.image != null && item.image!.isNotEmpty)
              ? item.image
              : menuCache[item.id]?.imageUrl;

          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Ảnh sản phẩm 40×40 (giống web: w-10 h-10)
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF1F5F9),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFE2E8F0)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: (imageUrl != null && imageUrl.isNotEmpty)
                      ? Image.network(imageUrl, fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)))
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
              ...widget.tableOrders.expand((order) => order.items.map((item) => Padding(
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
              ))).toList(),
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
              ...['Tiền mặt', 'Chuyển khoản', 'Thẻ'].map((m) => Padding(
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
                  Text('Chi tiết bàn $tableId',
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
                final imageUrl = (item.image != null && item.image!.isNotEmpty)
                    ? item.image : menuCache[item.id]?.imageUrl;
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
                            ? Image.network(imageUrl, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.restaurant, size: 22, color: Color(0xFF94A3B8)))
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

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final items = _items.map((e) => OrderItem(
        id: e.id, name: e.name, quantity: e.qty, price: e.price,
        note: e.note.isEmpty ? null : e.note, image: e.image, size: e.size, sweetness: e.sweetness,
      )).toList();
      final vnd = _totalVnd;
      await widget.onSave(items, vnd, double.parse((vnd / 26000).toStringAsFixed(2)));
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
                      final imageUrl = (it.image != null && it.image!.isNotEmpty)
                          ? it.image : widget.menuCache[it.id]?.imageUrl;
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFFE2E8F0))),
                            clipBehavior: Clip.antiAlias,
                            child: (imageUrl != null && imageUrl.isNotEmpty)
                                ? Image.network(imageUrl, fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => const Icon(Icons.restaurant, size: 18, color: Color(0xFF94A3B8)))
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
                  backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  disabledBackgroundColor: const Color(0xFF94A3B8),
                ),
                onPressed: (_saving || _items.isEmpty) ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.save_outlined, size: 18),
                label: Text(_saving ? 'Đang lưu...' : 'Lưu thay đổi', style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _sqIcon(IconData icon, VoidCallback onTap, {Color color = const Color(0xFF475569)}) {
    return GestureDetector(onTap: onTap,
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
                                              ? Image.network(p.imageUrl!, fit: BoxFit.cover,
                                                  errorBuilder: (_, __, ___) => const Icon(Icons.coffee, size: 22, color: Color(0xFF94A3B8)))
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
                    ? Image.network(p.imageUrl!, fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(Icons.coffee, size: 18, color: Color(0xFF94A3B8)))
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
  final Future<void> Function(DiscountModel d) onApply;
  final Future<void> Function() onRemove;
  const _DiscountPickerDialog({required this.tableId, required this.discounts,
    required this.activeDiscountId, required this.onApply, required this.onRemove});

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
                      return GestureDetector(
                        onTap: isApplying ? null : () async {
                          setState(() => _applyingId = d.id);
                          try {
                            if (isSel) { await widget.onRemove(); } else { await widget.onApply(d); }
                            if (mounted) Navigator.pop(context);
                          } catch (_) {
                            if (mounted) setState(() => _applyingId = null);
                          }
                        },
                        child: Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isSel ? const Color(0xFFECFDF5) : Colors.white,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: isSel ? const Color(0xFF10B981) : const Color(0xFFE2E8F0), width: isSel ? 2 : 1),
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
                              // subtitle = code · valueLabel (nếu có description) | chỉ code
                              Text(d.description != null ? '${d.code} · ${_valueLabel(d)}' : d.code,
                                  style: const TextStyle(fontSize: 10, color: Color(0xFF94A3B8), fontWeight: FontWeight.w600)),
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
                        ),
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
  final Future<void> Function(Map<String, dynamic> data) onPrint;
  const _InvoiceDialog({
    required this.tableId,
    required this.tableOrders,
    required this.activeDiscount,
    required this.existingInvoiceFuture,
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
                        onTap: () => setState(() => _saveRevenue = !_saveRevenue),
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
                // Nút Đóng / In
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFFE2E8F0)))),
                  child: Row(children: [
                    Expanded(child: OutlinedButton(
                      onPressed: _printing ? null : () => Navigator.pop(context),
                      child: const Text('Đóng'))),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFFE2E8F0)),
                      onPressed: canPrint ? _doPrint : null,
                      icon: _printing
                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.print, size: 15),
                      label: Text(_isPrint2 ? 'In lại' : 'In hóa đơn', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                    )),
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
                    Text('Bàn: ${widget.tableId}', style: const TextStyle(fontSize: 12, color: Colors.black)),
                    Text('Thời gian: ${_nowStr()}', style: const TextStyle(fontSize: 12, color: Colors.black)),
                    const Divider(color: Colors.black),
                    ...items.map((it) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        Expanded(child: Text('${it.quantity} x ${it.name}', style: const TextStyle(fontSize: 12, color: Colors.black))),
                        Text('${_vndFmt.format(it.price * it.quantity)}đ', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.black)),
                      ]),
                    )),
                    const Divider(color: Colors.black),
                    _pvRow('Tạm tính', '${_vndFmt.format(_subtotal)}đ'),
                    if (_service > 0) _pvRow('Phí dịch vụ (${_service.toStringAsFixed(0)}%)', '${_vndFmt.format(_serviceAmount)}đ'),
                    if (_discount > 0) _pvRow('Giảm giá${_code != null ? ' [$_code]' : ''}', '-${_vndFmt.format(_discount)}đ'),
                    const Divider(color: Colors.black, thickness: 1.2),
                    Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      const Text('THÀNH TIỀN', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.black)),
                      Text('${_vndFmt.format(_total)}đ', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: Colors.black)),
                    ]),
                    Center(child: Text('≈ \$${(_total / 26000).toStringAsFixed(2)} USD', style: const TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: Colors.black))),
                    const SizedBox(height: 14),
                    const Center(child: Text('CẢM ƠN QUÝ KHÁCH!', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.black))),
                    const Center(child: Text('HẸN GẶP LẠI', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w900, color: Colors.black))),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }

  String _nowStr() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.day)}/${two(n.month)}/${n.year} ${two(n.hour)}:${two(n.minute)}';
  }

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
