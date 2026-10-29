import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/order_model.dart';
import 'label_image_builder.dart';
import 'printer_service.dart';

/// Ngôn ngữ lệnh của máy in tem.
/// - tspl: máy in tem chuyên dụng (Xprinter XP-365B, XP-420B, XP-236B, TSC…) — mặc định.
/// - escpos: máy in bill lắp giấy decal nhiệt cuộn liên tục.
enum LabelProtocol { tspl, escpos }

/// 1 tem cần in: món nào, ly thứ mấy.
class CupLabelRef {
  final int itemIndex; // vị trí món trong order.items
  final int cupIndex;  // 1-based trên cả đơn
  const CupLabelRef(this.itemIndex, this.cupIndex);
}

/// Cấu hình tem + in tem dán ly cho đơn giao qua app (Grab / ShopeeFood).
/// Cấu hình lưu trên từng máy (SharedPreferences), giống máy in hóa đơn.
class LabelPrintService {
  LabelPrintService._();
  static final LabelPrintService instance = LabelPrintService._();

  static const _kProtocol = 'label_protocol';
  static const _kWidth = 'label_width_mm';
  static const _kHeight = 'label_height_mm';
  static const _kGap = 'label_gap_mm';
  static const _kShopName = 'label_shop_name';
  static const _kRotate = 'label_rotate180';

  /// Các khổ tem phổ biến (rộng × cao, mm). 40×30 dùng nhiều nhất cho ly.
  static const presets = <List<int>>[[40, 30], [50, 30], [50, 40], [35, 25]];

  LabelProtocol protocol = LabelProtocol.tspl;
  int widthMm = 40;
  int heightMm = 30;
  int gapMm = 2;
  String shopName = '';
  bool rotate180 = false;

  bool _loaded = false;

  PrinterService get printer => PrinterService.label;

  Future<void> load() async {
    await printer.load();
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    protocol = sp.getString(_kProtocol) == 'escpos' ? LabelProtocol.escpos : LabelProtocol.tspl;
    widthMm = sp.getInt(_kWidth) ?? 40;
    heightMm = sp.getInt(_kHeight) ?? 30;
    gapMm = sp.getInt(_kGap) ?? 2;
    shopName = sp.getString(_kShopName) ?? '';
    rotate180 = sp.getBool(_kRotate) ?? false;
    _loaded = true;
  }

  Future<void> save({
    required LabelProtocol protocol,
    required int widthMm,
    required int heightMm,
    required int gapMm,
    required String shopName,
    required bool rotate180,
  }) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kProtocol, protocol.name);
    await sp.setInt(_kWidth, widthMm);
    await sp.setInt(_kHeight, heightMm);
    await sp.setInt(_kGap, gapMm);
    await sp.setString(_kShopName, shopName);
    await sp.setBool(_kRotate, rotate180);
    this.protocol = protocol;
    this.widthMm = widthMm;
    this.heightMm = heightMm;
    this.gapMm = gapMm;
    this.shopName = shopName;
    this.rotate180 = rotate180;
    _loaded = true;
  }

  /// Tất cả tem của đơn: mỗi ly 1 tem, đánh số 1..N trên cả đơn.
  static List<CupLabelRef> allCups(OrderModel order) {
    final refs = <CupLabelRef>[];
    var n = 0;
    for (var i = 0; i < order.items.length; i++) {
      for (var q = 0; q < order.items[i].quantity; q++) {
        refs.add(CupLabelRef(i, ++n));
      }
    }
    return refs;
  }

  static String? itemOptions(OrderItem it) {
    final parts = <String>[
      if (it.size != null && it.size!.isNotEmpty) 'Size ${it.size}',
      if (it.sweetness != null && it.sweetness!.isNotEmpty) 'Đường ${it.sweetness}',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  CupLabelData dataFor(OrderModel order, CupLabelRef ref, int cupTotal) {
    final it = order.items[ref.itemIndex];
    final t = order.createdAt ?? DateTime.now();
    return CupLabelData(
      channelLabel: OrderChannel.label(order.channel),
      orderCode: order.externalOrderCode ?? '',
      cupIndex: ref.cupIndex,
      cupTotal: cupTotal,
      itemName: it.name,
      options: itemOptions(it),
      note: it.note,
      shopName: shopName,
      timeText: DateFormat('HH:mm dd/MM').format(t),
    );
  }

  /// Tem mẫu cho phần xem trước / in thử trong Cài đặt.
  CupLabelData sample() => CupLabelData(
        channelLabel: 'GRAB',
        orderCode: 'GF-482',
        cupIndex: 1,
        cupTotal: 3,
        itemName: 'Cà phê sữa đá',
        options: 'Size L · Đường 70%',
        note: 'Ít đá, không ống hút',
        shopName: shopName.isEmpty ? 'Tên quán' : shopName,
        timeText: DateFormat('HH:mm dd/MM').format(DateTime.now()),
      );

  Future<List<int>> _encode(List<CupLabelData> labels) async {
    final images = [
      for (final d in labels)
        await LabelImageBuilder.renderMono(d, widthMm: widthMm, heightMm: heightMm, rotate180: rotate180),
    ];
    if (protocol == LabelProtocol.tspl) {
      return LabelImageBuilder.encodeTspl(images, widthMm: widthMm, heightMm: heightMm, gapMm: gapMm);
    }
    return LabelImageBuilder.encodeEscPos(images);
  }

  /// In tem cho [order]. [cups] = null → in tất cả các ly. Trả về số tem đã gửi.
  Future<int> printOrder(OrderModel order, {List<CupLabelRef>? cups}) async {
    await load();
    if (!printer.isConfigured) {
      throw Exception('Chưa cấu hình máy in tem. Vào Cài đặt máy in → Máy in tem.');
    }
    final all = allCups(order);
    final list = cups ?? all;
    if (list.isEmpty) return 0;
    final data = [for (final r in list) dataFor(order, r, all.length)];
    await printer.sendBytes(await _encode(data));
    return data.length;
  }

  Future<void> printSample() async {
    await load();
    await printer.sendBytes(await _encode([sample()]));
  }
}
