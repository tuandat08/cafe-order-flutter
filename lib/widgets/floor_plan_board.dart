import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/floor_plan_models.dart';
import '../services/floor_plan_service.dart';

// Hiển thị (chỉ đọc) sơ đồ bàn đã được thiết lập ở trang quản trị web
// (admin > Sơ đồ bàn): các khu vực cố định (quầy pha chế, WC, kho, thang
// máy, hiên...), vật dụng trang trí và vị trí/kích thước/số ghế của từng
// bàn. Bấm vào 1 bàn trên sơ đồ để chọn bàn đó cho đơn POS — y hệt cấu trúc
// dữ liệu & phép tính dùng ở FloorPlanPage.jsx (web) để 2 bên khớp nhau.

class _FloorDef {
  final int id;
  final String label;
  const _FloorDef(this.id, this.label);
}

const List<_FloorDef> kFloors = [_FloorDef(1, 'Tầng 1'), _FloorDef(2, 'Tầng 2')];

// style: 'hard' = vùng cố định không đặt bàn · 'soft' = khu gợi ý (hiên...)
// vẫn đặt bàn được · 'void' = khoảng trống/thông tầng
final Map<int, List<FloorZone>> kDefaultZones = {
  1: [
    FloorZone(id: 'floor1-counter', label: 'Quầy pha chế', x: 2, y: 4, w: 25, h: 60, style: 'hard'),
    FloorZone(id: 'floor1-porch', label: 'Hiên trước', x: 2, y: 66, w: 13, h: 26, style: 'soft'),
    FloorZone(id: 'floor1-wc', label: 'WC', x: 83, y: 4, w: 13, h: 38, style: 'hard'),
    FloorZone(id: 'floor1-stairs', label: 'Thang máy / thang bộ', x: 83, y: 46, w: 13, h: 46, style: 'hard'),
  ],
  2: [
    FloorZone(id: 'floor2-outdoor', label: 'Hiên ngoài (khu cafe ngoài trời)', x: 2, y: 4, w: 25, h: 88, style: 'soft'),
    FloorZone(id: 'floor2-storage', label: 'Kho', x: 83, y: 4, w: 13, h: 34, style: 'hard'),
    FloorZone(id: 'floor2-stairs', label: 'Thang máy / thang bộ', x: 83, y: 42, w: 13, h: 50, style: 'hard'),
    FloorZone(id: 'floor2-void', label: 'Thông tầng', x: 27, y: 49, w: 32, h: 48, style: 'void'),
  ],
};

const double kChairSize = 12;
const double kChairGap = 12;
const double kDefaultTableSize = 64;

// Xếp ghế đều quanh bàn theo số lượng + góc xoay (độ) — trả về độ lệch
// {dx, dy} (px) so với tâm bàn. Giống hệt chairPositions() ở web: với số ghế
// chẵn, ghế đối diện lấy đúng số âm của ghế còn lại trong cặp để đối xứng
// tuyệt đối (không lệch 1px do làm tròn lượng giác độc lập).
List<Offset> chairPositions(int seatCount, double tSize, double rotation) {
  if (seatCount <= 0) return const [];
  final radius = tSize / 2 + kChairGap;
  final step = 360 / seatCount;
  final offsets = List<Offset>.filled(seatCount, Offset.zero);
  for (var i = 0; i < seatCount; i++) {
    final angleRad = (-90 + rotation + step * i) * math.pi / 180;
    offsets[i] = Offset(
      (radius * math.cos(angleRad)).roundToDouble(),
      (radius * math.sin(angleRad)).roundToDouble(),
    );
  }
  if (seatCount % 2 == 0) {
    final half = seatCount ~/ 2;
    for (var i = 0; i < half; i++) {
      offsets[i + half] = Offset(-offsets[i].dx, -offsets[i].dy);
    }
  }
  return offsets;
}

Color _hex(String v) {
  var s = v.replaceAll('#', '');
  if (s.length == 6) s = 'FF$s';
  return Color(int.tryParse(s, radix: 16) ?? 0xFF64748B);
}

class _TableDot {
  final Color bg, border, text, icon;
  final Color? ring;
  const _TableDot({required this.bg, required this.border, required this.text, required this.icon, this.ring});
}

// Đúng 3 màu trạng thái dùng ở dialog "Chọn bàn" (_TablePickerDialog):
// xám = trống · xanh lá = đang phục vụ · vàng = gọi phục vụ.
const kStatusGray = Color(0xFF94A3B8);   // trống
const kStatusGreen = Color(0xFF16A34A);  // đang phục vụ (AppColors.success)
const kStatusAmber = Color(0xFFF59E0B);  // gọi phục vụ
const kStatusBlue = Color(0xFF2563EB);   // gọi tính tiền

_TableDot _dotColor(FloorTable t, bool occupied) {
  const grayBg = Color(0xFFF1F5F9), grayText = Color(0xFF475569);
  const greenBg = Color(0xFFDCFCE7), greenText = Color(0xFF15803D);
  const amberBg = Color(0xFFFEF3C7), amberText = Color(0xFFB45309);
  if (t.isBillRequest) {
    return const _TableDot(bg: Color(0xFFDBEAFE), border: kStatusBlue, text: Color(0xFF1D4ED8), icon: kStatusBlue, ring: kStatusBlue);
  }
  if (t.hasServiceRequest) {
    return const _TableDot(bg: amberBg, border: kStatusAmber, text: amberText, icon: kStatusAmber, ring: kStatusAmber);
  }
  // occupied: tính từ đơn hàng active thật sự (collection orders) — KHÔNG
  // dùng field status tĩnh trên doc bàn, để khớp đúng trạng thái thực tế.
  if (occupied) {
    return const _TableDot(bg: greenBg, border: kStatusGreen, text: greenText, icon: kStatusGreen);
  }
  return const _TableDot(bg: grayBg, border: kStatusGray, text: grayText, icon: kStatusGray);
}

class _TriangleClipper extends CustomClipper<Path> {
  const _TriangleClipper();
  @override
  Path getClip(Size size) {
    final p = Path();
    p.moveTo(size.width * 0.5, 0);
    p.lineTo(0, size.height);
    p.lineTo(size.width, size.height);
    p.close();
    return p;
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

class _HexagonClipper extends CustomClipper<Path> {
  const _HexagonClipper();
  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    final pts = [
      Offset(w * 0.5, 0),
      Offset(w, h * 0.25),
      Offset(w, h * 0.75),
      Offset(w * 0.5, h),
      Offset(0, h * 0.75),
      Offset(0, h * 0.25),
    ];
    return Path()..addPolygon(pts, true);
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

Widget renderShapeBox(String shape, Color color, double size) {
  switch (shape) {
    case 'tree':
    case 'star':
    case 'heart':
      final icon = shape == 'tree' ? Icons.park_rounded : (shape == 'star' ? Icons.star_rounded : Icons.favorite_rounded);
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: Colors.white,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 2, offset: Offset(0, 1))],
        ),
        child: Icon(icon, size: math.max(10, size * 0.6), color: color),
      );
    case 'circle':
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle, color: color,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 2, offset: Offset(0, 1))],
        ),
      );
    case 'triangle':
      return ClipPath(clipper: const _TriangleClipper(), child: Container(width: size, height: size, color: color));
    case 'hexagon':
      return ClipPath(clipper: const _HexagonClipper(), child: Container(width: size, height: size, color: color));
    case 'square':
    default:
      return Container(
        width: size, height: size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6), color: color,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 2, offset: Offset(0, 1))],
        ),
      );
  }
}

// ── Khung 1 tầng (zones + vật dụng + bàn) ──────────────────────────────────
class FloorPlanFloorView extends StatelessWidget {
  final int floorId;
  final String label;
  final List<FloorZone> zones;
  final List<FloorItemPlacement> items;
  final List<FloorTable> tables;
  final Set<String> occupiedIds; // id các bàn đang thực sự có đơn active
  final void Function(FloorTable table)? onTableTap;

  const FloorPlanFloorView({
    super.key,
    required this.floorId,
    required this.label,
    required this.zones,
    required this.items,
    required this.tables,
    this.occupiedIds = const {},
    this.onTableTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 6, left: 2),
        child: Row(children: [
          const Icon(Icons.layers_rounded, size: 14, color: Color(0xFF059669)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Color(0xFF334155))),
        ]),
      ),
      LayoutBuilder(builder: (ctx, constraints) {
        final w = constraints.maxWidth;
        final h = math.max(w / 4, 220.0);
        return Container(
          width: w, height: h,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFFFCFCFD),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFCBD5E1), width: 1.5),
            boxShadow: const [BoxShadow(color: Color(0x0F0F172A), blurRadius: 10, offset: Offset(0, 3))],
          ),
          child: Stack(children: [
            for (final z in zones)
              Positioned(
                left: w * z.x / 100, top: h * z.y / 100,
                width: w * z.w / 100, height: h * z.h / 100,
                child: _ZoneBox(zone: z),
              ),
            for (final p in items)
              Positioned(
                left: w * p.x / 100 - p.size / 2,
                top: h * p.y / 100 - p.size / 2,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  renderShapeBox(p.shape, _hex(p.color), p.size),
                  const SizedBox(height: 3),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.85), borderRadius: BorderRadius.circular(4)),
                    child: Text(p.name, style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w600, color: Color(0xFF64748B))),
                  ),
                ]),
              ),
            for (final t in tables)
              _TableMarker(
                table: t,
                containerW: w, containerH: h,
                occupied: occupiedIds.contains(t.id),
                onTap: onTableTap == null ? null : () => onTableTap!(t),
              ),
            if (tables.isEmpty && items.isEmpty)
              const Positioned.fill(
                child: Center(child: Text('Chưa có bàn nào trên tầng này', style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)))),
              ),
          ]),
        );
      }),
    ]);
  }
}

// Vẽ vạch chéo (hatch) mô phỏng nền "vùng cố định" (style=hard) giống hệt
// hoạ tiết repeating-linear-gradient 45deg dùng ở web.
class _HatchPainter extends CustomPainter {
  final Color color;
  const _HatchPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..color = color..strokeWidth = 6;
    final diag = size.width + size.height;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(math.pi / 4);
    for (double x = -diag; x < diag; x += 12) {
      canvas.drawLine(Offset(x, -diag), Offset(x, diag), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _HatchPainter oldDelegate) => oldDelegate.color != color;
}

// Vẽ viền nét đứt cho khu "soft"/"void" — giống border-dashed ở web.
class _DashedRectPainter extends CustomPainter {
  final Color color;
  final double radius;
  const _DashedRectPainter(this.color, {this.radius = 8});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius));
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    const dashWidth = 4.5, dashSpace = 3.5;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = math.min(distance + dashWidth, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + dashSpace;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}

class _ZoneBox extends StatelessWidget {
  final FloorZone zone;
  const _ZoneBox({required this.zone});

  @override
  Widget build(BuildContext context) {
    Color bg, border, textColor;
    final isHard = zone.style == 'hard';
    switch (zone.style) {
      case 'soft':
        bg = const Color(0xFFFFFBEB);
        border = const Color(0xFFFDE68A);
        textColor = const Color(0xFFD97706);
        break;
      case 'void':
        bg = const Color(0xFFF8FAFC);
        border = const Color(0xFFCBD5E1);
        textColor = const Color(0xFF94A3B8);
        break;
      default:
        bg = const Color(0xFFF1F5F9);
        border = const Color(0xFFCBD5E1);
        textColor = const Color(0xFF64748B);
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: bg,
        border: isHard ? Border.all(color: border) : null,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Stack(fit: StackFit.expand, children: [
        if (isHard) CustomPaint(painter: _HatchPainter(const Color(0x14647589))),
        if (!isHard) CustomPaint(painter: _DashedRectPainter(border)),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              zone.label, textAlign: TextAlign.center, maxLines: 3, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: textColor, height: 1.15),
            ),
          ),
        ),
      ]),
    );
  }
}

class _TableMarker extends StatelessWidget {
  final FloorTable table;
  final double containerW, containerH;
  final bool occupied;
  final VoidCallback? onTap;
  const _TableMarker({
    required this.table,
    required this.containerW,
    required this.containerH,
    this.occupied = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tSize = table.layoutSize ?? kDefaultTableSize;
    final x = table.layoutX ?? 50, y = table.layoutY ?? 50;
    final rotation = table.seatRotation ?? 0;
    final seatCount = table.seatCount ?? 0;
    final chairs = chairPositions(seatCount, tSize, rotation);
    final c = _dotColor(table, occupied);
    return Positioned(
      left: containerW * x / 100 - tSize / 2,
      top: containerH * y / 100 - tSize / 2,
      width: tSize, height: tSize,
      // clipBehavior: Clip.none để các chấm ghế (đặt NGOÀI khung bàn, bán
      // kính = tSize/2 + khoảng cách) không bị cắt mất bởi Positioned cha.
      child: Stack(clipBehavior: Clip.none, children: [
        // Khung bàn — dùng SizedBox.expand để LUÔN lấp đầy đúng tSize×tSize
        // (không co lại theo icon/chữ bên trong) — đây là toạ độ gốc mà mọi chấm
        // ghế bên dưới tính theo (tSize/2 + dx/dy), nên phải khớp tuyệt đối với
        // kích thước khung hiển thị thật, nếu không ghế sẽ lệch khỏi bàn.
        Positioned.fill(
          child: GestureDetector(
            onTap: onTap,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: c.border, width: 2),
                boxShadow: [
                  const BoxShadow(color: Color(0x1A0F172A), blurRadius: 4, offset: Offset(0, 2)),
                  if (c.ring != null) BoxShadow(color: c.ring!.withOpacity(0.35), blurRadius: 0, spreadRadius: 3),
                ],
              ),
              child: Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(
                    table.isBillRequest
                        ? Icons.receipt_long_rounded
                        : table.hasServiceRequest ? Icons.notifications_active_rounded : Icons.people_alt_rounded,
                    size: math.max(12, tSize * 0.26), color: c.icon,
                  ),
                  const SizedBox(height: 1),
                  SizedBox(
                    width: tSize - 10,
                    child: Text(
                      table.name, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: c.text),
                    ),
                  ),
                  if (table.isBillRequest)
                    SizedBox(
                      width: tSize - 6,
                      child: Text(
                        table.billBadge, textAlign: TextAlign.center, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 8, fontWeight: FontWeight.w700, color: c.text),
                      ),
                    ),
                ]),
              ),
            ),
          ),
        ),
        for (final off in chairs)
          Positioned(
            left: tSize / 2 + off.dx - kChairSize / 2,
            top: tSize / 2 + off.dy - kChairSize / 2,
            child: Container(
              width: kChairSize, height: kChairSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: const Color(0xFF92400E),
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 1.5, offset: Offset(0, 1))],
              ),
            ),
          ),
      ]),
    );
  }
}

// ── Dialog chọn bàn qua sơ đồ trực quan (đọc dữ liệu setting ở web) ────────
class FloorPlanPickerDialog extends StatefulWidget {
  final String selectedTableId;
  const FloorPlanPickerDialog({super.key, this.selectedTableId = ''});

  @override
  State<FloorPlanPickerDialog> createState() => _FloorPlanPickerDialogState();
}

class _FloorPlanPickerDialogState extends State<FloorPlanPickerDialog> {
  final _service = FloorPlanService();
  List<FloorZone> _zoneOverrides = [];
  List<FloorItemPlacement> _items = [];
  List<FloorTable> _tables = [];
  Set<String> _occupiedIds = {};
  bool _loadingZones = true, _loadingItems = true, _loadingTables = true;
  StreamSubscription<List<FloorZone>>? _zoneSub;
  StreamSubscription<List<FloorItemPlacement>>? _itemSub;
  StreamSubscription<List<FloorTable>>? _tableSub;
  StreamSubscription<Set<String>>? _occupiedSub;

  @override
  void initState() {
    super.initState();
    _zoneSub = _service.streamZoneOverrides().listen((v) {
      if (!mounted) return;
      setState(() { _zoneOverrides = v; _loadingZones = false; });
    });
    _itemSub = _service.streamItemPlacements().listen((v) {
      if (!mounted) return;
      setState(() { _items = v; _loadingItems = false; });
    });
    _tableSub = _service.streamFloorTables().listen((v) {
      if (!mounted) return;
      setState(() { _tables = v; _loadingTables = false; });
    });
    // Bàn nào đang thực sự có đơn active — dùng để tô màu "Đang phục vụ" đúng
    // thực tế thay vì field status tĩnh trên doc bàn.
    _occupiedSub = _service.streamOccupiedTableIds().listen((v) {
      if (!mounted) return;
      setState(() => _occupiedIds = v);
    });
  }

  @override
  void dispose() {
    _zoneSub?.cancel();
    _itemSub?.cancel();
    _tableSub?.cancel();
    _occupiedSub?.cancel();
    super.dispose();
  }

  List<FloorZone> _zonesForFloor(int floorId) {
    final overridesById = {for (final z in _zoneOverrides) z.id: z};
    final out = <FloorZone>[];
    for (final base in kDefaultZones[floorId]!) {
      final saved = overridesById[base.id];
      if (saved == null) { out.add(base); continue; }
      if (saved.hidden) continue;
      out.add(base.copyWithOverride({'x': saved.x, 'y': saved.y, 'w': saved.w, 'h': saved.h}));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final loading = _loadingZones || _loadingItems || _loadingTables;
    final unplaced = _tables.where((t) => !t.isPlaced).toList()
      ..sort((a, b) => a.id.compareTo(b.id));

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900, maxHeight: 720),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Icon(Icons.map_rounded, color: Color(0xFF059669)),
              const SizedBox(width: 8),
              const Expanded(child: Text('Sơ đồ bàn', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
            ]),
            const SizedBox(height: 4),
            Row(children: [
              _legendDot(kStatusGray, 'Trống'),
              const SizedBox(width: 14),
              _legendDot(kStatusGreen, 'Đang phục vụ'),
              const SizedBox(width: 14),
              _legendDot(kStatusAmber, 'Gọi phục vụ'),
              const SizedBox(width: 14),
              _legendDot(kStatusBlue, 'Gọi tính tiền'),
              const Spacer(),
              const Text('Bấm vào bàn để chọn', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
            ]),
            const SizedBox(height: 10),
            Flexible(
              child: loading
                  ? const Padding(padding: EdgeInsets.symmetric(vertical: 40), child: CircularProgressIndicator())
                  : SingleChildScrollView(
                      child: Column(children: [
                        for (final f in kFloors) ...[
                          FloorPlanFloorView(
                            floorId: f.id,
                            label: f.label,
                            zones: _zonesForFloor(f.id),
                            items: _items.where((p) => p.floor == f.id).toList(),
                            tables: _tables.where((t) => t.layoutFloor == f.id).toList(),
                            occupiedIds: _occupiedIds,
                            onTableTap: (t) => Navigator.of(context).pop(t.id),
                          ),
                          const SizedBox(height: 14),
                        ],
                        if (unplaced.isNotEmpty) ...[
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Bàn chưa xếp vị trí trên sơ đồ (${unplaced.length})',
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF94A3B8))),
                          ),
                          const SizedBox(height: 6),
                          Wrap(spacing: 8, runSpacing: 8, children: [
                            for (final t in unplaced)
                              ActionChip(
                                label: Text(t.name),
                                onPressed: () => Navigator.of(context).pop(t.id),
                              ),
                          ]),
                        ],
                      ]),
                    ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _legendDot(Color c, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: c)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
      ]);
}
