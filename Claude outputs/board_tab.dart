
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
  final Set<String> _billedTableIds = {};
  bool _loaded = false;

  String _statusFilter = 'Tất cả';
  String? _selectedKey;
  double _detailWidth = 400;

  @override
  void initState() {
    super.initState();
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
    _ordersSub = FirebaseFirestore.instance.collection('orders').snapshots().listen((snap) {
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

  @override
  void dispose() {
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

  bool _isBilled(String tableId) {
    if (_billedTableIds.contains(tableId)) return true;
    final t = _findTable(tableId);
    if (t?.lastBilledAt == null) return false;
    final cleared = t!.clearedAt;
    return cleared == null || t.lastBilledAt!.isAfter(cleared);
  }

  bool _hasServiceRequest(String tableId) => _findTable(tableId)?.serviceRequest != null;

  bool _isTakeawayTable(String baseId) {
    final t = _findTable(baseId);
    if (t != null && t.isTakeaway) return true;
    return baseId == 'Mang về';
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
            }, reason: data['reason'], previousInvoiceId: data['previousInvoiceId'],
               staffName: staffName, staffId: staffId);
            if (!isTakeaway) {
              await _orderService.updateTableLastBilledAt(tableId);
            }
            final actId = act?['id'];
            if (actId != null) {
              await _discountService.incrementUsage(actId.toString());
            }
          }
          if (mounted) setState(() => _billedTableIds.add(billKey));
          try {
            await _printInvoice(tableId, tableOrders, data);
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
          }
        },
      ),
    );
  }

  Future<void> _printInvoice(String tableId, List<OrderModel> tableOrders, Map<String, dynamic> data) async {
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

  Future<void> _handleCompleteTable(
      BuildContext ctx, String tableId, List<OrderModel> tableOrders,
      {bool isBilled = false, String? cardKey, bool isTakeaway = false}) async {
    final clearKey = cardKey ?? tableId;
    final reasonCtrl = TextEditingController();
    String payMethod = 'Tiền mặt';

    final confirmed = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => StatefulBuilder(
        builder: (sbCtx, setSB) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('Dọn bàn $tableId?'),
          content: isBilled
              ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Chọn phương thức thanh toán trước khi đóng bàn.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B))),
                  const SizedBox(height: 12),
                  ...['Tiền mặt', 'Chuyển khoản'].map((m) => Padding(
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
                          Icon(m == 'Tiền mặt' ? Icons.payments_outlined : Icons.account_balance_outlined,
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

    setState(() => _clearingTableIds.add(clearKey));
    final orderIds = tableOrders.where((o) => _kActive.contains(o.status)).map((o) => o.id).toList();
    final totalAmount = tableOrders.fold(0.0, (s, o) => s + o.totalPrice);
    final firstOrderId = tableOrders.isNotEmpty ? tableOrders.first.id : null;
    try {
      if (isBilled && firstOrderId != null) {
        await _invoiceService.setPaymentMethod(firstOrderId, payMethod);
      }
      await _orderService.completeAllOrdersAndFreeTable(
        tableId, orderIds,
        clearReason: isBilled ? null : reasonCtrl.text.trim(),
        totalAmount: totalAmount,
      );
      if (!isTakeaway) {
        try {
          await _tableService.clearTable(tableId);
        } catch (e) {
          debugPrint('[BOARD] clearTable error: $e');
        }
      }
      if (mounted) setState(() => _billedTableIds.remove(clearKey));
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

  void _showDiscountPicker(BuildContext ctx, String tableId) {
    final table = _findTable(tableId);
    showDialog(
      context: ctx,
      builder: (_) => _DiscountPickerDialog(
        tableId: tableId,
        discounts: _discounts,
        activeDiscountId: table?.activeDiscount?['id']?.toString(),
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
      final base = groupBase[key]!;
      final allDone = orders.every((o) => _isDone(o.status));
      final takeaway = _isTakeawayTable(base) && key != base;
      final billed = takeaway ? _billedTableIds.contains(key) : _isBilled(base);
      switch (_statusFilter) {
        case 'Đang pha': return !allDone;
        case 'Hoàn thành': return allDone && !billed;
        case 'Đã xuất bill': return billed;
        default: return true;
      }
    }

    final entries = grouped.entries.where((e) => matchFilter(e.key, e.value)).toList()
      ..sort((a, b) => groupBase[a.key]!.compareTo(groupBase[b.key]!));
    final keys = entries.map((e) => e.key).toList();

    // Bàn đang chọn (mặc định bàn đầu tiên)
    final selKey = (keys.contains(_selectedKey) ? _selectedKey : (keys.isNotEmpty ? keys.first : null));

    return Row(children: [
      // ── TRÁI: danh sách bàn ──
      Expanded(
        child: Column(children: [
          _boardFilterBar(grouped.length),
          const Divider(height: 1),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('Không có bàn nào', style: TextStyle(color: AppColors.textHint)))
                : ListView.separated(
                    padding: const EdgeInsets.all(12),
                    itemCount: entries.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final e = entries[i];
                      return _boardListCard(e.key, groupBase[e.key]!, e.value, selKey == e.key);
                    },
                  ),
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
      // ── PHẢI: chi tiết + thao tác ──
      SizedBox(
        width: _detailWidth,
        child: selKey == null
            ? const Center(child: Text('Chọn một bàn để xem chi tiết', style: TextStyle(color: AppColors.textHint)))
            : _boardDetail(selKey, groupBase[selKey]!, grouped[selKey]!),
      ),
    ]);
  }

  Widget _boardFilterBar(int total) {
    const filters = ['Tất cả', 'Đang pha', 'Hoàn thành', 'Đã xuất bill'];
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      color: AppColors.surface,
      child: Row(children: [
        const Icon(Icons.table_restaurant_rounded, size: 18, color: AppColors.primary),
        const SizedBox(width: 8),
        const Text('Danh sách bàn', style: TextStyle(fontWeight: FontWeight.w700, color: AppColors.textPrimary)),
        const SizedBox(width: 12),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: filters.map((f) {
              final sel = _statusFilter == f;
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
                    child: Text(f, style: TextStyle(
                      fontSize: 12, fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                      color: sel ? Colors.white : AppColors.textSecondary)),
                  ),
                ),
              );
            }).toList()),
          ),
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
    final disc = takeaway ? 0.0 : _calcDiscount(_findTable(base)?.activeDiscount, subtotal);
    final net = subtotal - disc;
    final allDone = orders.every((o) => _isDone(o.status));
    final billed = takeaway ? _billedTableIds.contains(key) : _isBilled(base);
    final service = !takeaway && _hasServiceRequest(base);
    final itemCount = orders.fold<int>(0, (s, o) => s + o.items.fold<int>(0, (a, i) => a + i.quantity));

    Color border = selected ? AppColors.primary : (service ? const Color(0xFFFBBF24) : (billed ? const Color(0xFF6EE7B7) : AppColors.divider));

    return GestureDetector(
      onTap: () => setState(() => _selectedKey = key),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary.withValues(alpha: 0.06) : (billed ? const Color(0xFFF0FDF4) : AppColors.surface),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border, width: selected ? 2 : 1),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.chair_rounded, size: 18, color: billed ? const Color(0xFF10B981) : AppColors.textHint),
            const SizedBox(width: 6),
            Expanded(child: Text(_labelFor(key, base, orders),
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: Color(0xFF1E293B)))),
            if (disc > 0)
              Text('${_vndFmt.format(net)}đ', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFEA580C)))
            else
              Text('${_vndFmt.format(subtotal)}đ', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Color(0xFFEA580C))),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 4, children: [
            _boardChip(allDone ? 'Hoàn thành' : 'Đang pha',
                allDone ? const Color(0xFFD1FAE5) : const Color(0xFFFEF3C7),
                allDone ? const Color(0xFF065F46) : const Color(0xFFB45309)),
            _boardChip('$itemCount món', const Color(0xFFF1F5F9), const Color(0xFF475569)),
            if (billed) _boardChip('Đã xuất bill', const Color(0xFFD1FAE5), const Color(0xFF047857)),
            if (service) _boardChip('Gọi phục vụ', const Color(0xFFFEF3C7), const Color(0xFFB45309)),
          ]),
        ]),
      ),
    );
  }

  Widget _boardChip(String label, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: fg)),
  );

  Widget _boardDetail(String key, String base, List<OrderModel> orders) {
    final takeaway = _isTakeawayTable(base) && key != base;
    final subtotal = orders.fold(0.0, (s, o) => s + o.totalPrice);
    final activeDisc = takeaway ? null : _findTable(base)?.activeDiscount;
    final disc = _calcDiscount(activeDisc, subtotal);
    final net = subtotal - disc;
    final allDone = orders.every((o) => _isDone(o.status));
    final billed = takeaway ? _billedTableIds.contains(key) : _isBilled(base);
    final service = !takeaway && _hasServiceRequest(base);
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
          IconButton(
            icon: const Icon(Icons.open_in_full_rounded, size: 18),
            color: AppColors.textSecondary,
            tooltip: 'Xem chi tiết',
            onPressed: () => _showDetailDialog(context, base, orders),
          ),
        ]),
      ),
      const Divider(height: 1),
      // Banner gọi phục vụ
      if (service)
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFFFFBEB), borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFFDE68A)),
          ),
          child: Row(children: [
            const Icon(Icons.notifications_active, size: 15, color: Color(0xFFB45309)),
            const SizedBox(width: 6),
            const Expanded(child: Text('Khách đang gọi phục vụ!',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Color(0xFFB45309)))),
            GestureDetector(
              onTap: () => _handleClearServiceRequest(base),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: const Color(0xFFFBBF24), borderRadius: BorderRadius.circular(8)),
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
              Text('Giảm giá${activeDisc?['code'] != null ? ' [${activeDisc!['code']}]' : ''}',
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
          const SizedBox(height: 8),
          // Hàng nút: Thêm món + Giảm giá
          Row(children: [
            Expanded(child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF059669),
                side: const BorderSide(color: Color(0xFFA7F3D0)),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: () => _showAddProductDialog(context, base),
              icon: const Icon(Icons.add_circle_outline_rounded, size: 18),
              label: const Text('Thêm món', style: TextStyle(fontWeight: FontWeight.w700)),
            )),
            if (!takeaway) ...[
              const SizedBox(width: 8),
              Expanded(child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF64748B),
                  side: const BorderSide(color: Color(0xFFCBD5E1)),
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _showDiscountPicker(context, base),
                icon: Icon(activeDisc != null ? Icons.local_offer : Icons.local_offer_outlined, size: 16),
                label: Text(activeDisc != null ? '${activeDisc['code']}' : 'Giảm giá',
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
              )),
            ],
          ]),
        ]),
      ),
    ]);
  }
}
