import 'package:cloud_firestore/cloud_firestore.dart';

// Model tương ứng dữ liệu sơ đồ bàn tạo ở trang web (admin > Sơ đồ bàn),
// đọc trực tiếp từ các collection Firestore: floorZones, floorItemPlacements,
// và các field layout* trên chính collection tables.

class FloorZone {
  final String id;
  final String label;
  final double x, y, w, h; // % theo chiều rộng/cao khung sơ đồ
  final String style; // 'hard' | 'soft' | 'void'
  final bool hidden;

  FloorZone({
    required this.id,
    required this.label,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.style,
    this.hidden = false,
  });

  factory FloorZone.fromMap(String id, Map<String, dynamic> data) {
    double d(dynamic v, double def) => v is num ? v.toDouble() : def;
    return FloorZone(
      id: id,
      label: data['label']?.toString() ?? '',
      x: d(data['x'], 0),
      y: d(data['y'], 0),
      w: d(data['w'], 10),
      h: d(data['h'], 10),
      style: data['style']?.toString() ?? 'hard',
      hidden: data['hidden'] == true,
    );
  }

  FloorZone copyWithOverride(Map<String, dynamic> saved) {
    double d(dynamic v, double def) => v is num ? v.toDouble() : def;
    return FloorZone(
      id: id,
      label: label,
      x: d(saved['x'], x),
      y: d(saved['y'], y),
      w: d(saved['w'], w),
      h: d(saved['h'], h),
      style: style,
      hidden: saved['hidden'] == true,
    );
  }
}

class FloorItemPlacement {
  final String id;
  final String typeId;
  final String name;
  final String color; // hex string, vd '#ef4444'
  final String shape; // square|circle|triangle|tree|star|heart|hexagon
  final int floor;
  final double x, y; // %
  final double size; // px

  FloorItemPlacement({
    required this.id,
    required this.typeId,
    required this.name,
    required this.color,
    required this.shape,
    required this.floor,
    required this.x,
    required this.y,
    required this.size,
  });

  factory FloorItemPlacement.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    double d(dynamic v, double def) => v is num ? v.toDouble() : def;
    return FloorItemPlacement(
      id: doc.id,
      typeId: data['typeId']?.toString() ?? '',
      name: data['name']?.toString() ?? '',
      color: data['color']?.toString() ?? '#64748b',
      shape: data['shape']?.toString() ?? 'square',
      floor: (data['floor'] is num) ? (data['floor'] as num).toInt() : 1,
      x: d(data['x'], 50),
      y: d(data['y'], 50),
      size: d(data['size'], 40),
    );
  }
}

// Bàn kèm dữ liệu vị trí trên sơ đồ (đọc trực tiếp từ collection tables,
// tách riêng khỏi TableModel để không ảnh hưởng các màn hình khác đang dùng nó).
class FloorTable {
  final String id;
  final String name;
  final String status; // available | occupied | reserved
  final bool hasServiceRequest;
  /// 'service' | 'bill' — khách gọi phục vụ hay gọi tính tiền (xem TableModel).
  final String? serviceRequestType;
  /// 'cash' | 'transfer' — hình thức khách muốn trả khi gọi tính tiền.
  final String? serviceRequestPayment;
  final int? layoutFloor; // 1 | 2 | null (chưa xếp vị trí)
  final double? layoutX, layoutY; // %
  final double? layoutSize; // px
  final int? seatCount;
  final double? seatRotation; // độ, 0-359

  FloorTable({
    required this.id,
    required this.name,
    required this.status,
    required this.hasServiceRequest,
    this.serviceRequestType,
    this.serviceRequestPayment,
    this.layoutFloor,
    this.layoutX,
    this.layoutY,
    this.layoutSize,
    this.seatCount,
    this.seatRotation,
  });

  bool get isPlaced => layoutFloor == 1 || layoutFloor == 2;

  bool get isBillRequest => hasServiceRequest && serviceRequestType == 'bill';

  /// Nhãn ngắn dưới tên bàn trên sơ đồ khi khách gọi tính tiền.
  String get billBadge => switch (serviceRequestPayment) {
        'transfer' => 'Tính tiền · CK',
        'cash' => 'Tính tiền · TM',
        _ => 'Tính tiền',
      };

  factory FloorTable.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    double? dOrNull(dynamic v) => v is num ? v.toDouble() : null;
    int? iOrNull(dynamic v) => v is num ? v.toInt() : null;
    return FloorTable(
      id: doc.id,
      name: data['name']?.toString() ?? 'Bàn ${doc.id}',
      status: data['status']?.toString() ?? 'available',
      hasServiceRequest: data['serviceRequest'] != null,
      serviceRequestType: data['serviceRequestType'] as String?,
      serviceRequestPayment: data['serviceRequestPayment'] as String?,
      layoutFloor: iOrNull(data['layoutFloor']),
      layoutX: dOrNull(data['layoutX']),
      layoutY: dOrNull(data['layoutY']),
      layoutSize: dOrNull(data['layoutSize']),
      seatCount: iOrNull(data['seatCount']),
      seatRotation: dOrNull(data['seatRotation']),
    );
  }
}
