import 'package:cloud_firestore/cloud_firestore.dart';

class TableModel {
  final String id;
  final String name;
  final int capacity;
  final String status; // 'available' | 'occupied' | 'reserved'
  final String? currentOrderId;
  final Map<String, dynamic>? activeDiscount; // web: {id, code, type, value, maxDiscount, description}
  final DateTime? serviceRequest; // web: tables.serviceRequest (đang gọi phục vụ)
  /// Khách gọi để làm gì: 'service' (gọi phục vụ) | 'bill' (gọi tính tiền).
  /// null = web bản cũ / Security Rules cũ → coi như gọi phục vụ.
  final String? serviceRequestType;
  /// Hình thức khách muốn trả khi gọi tính tiền: 'cash' | 'transfer'.
  final String? serviceRequestPayment;
  final DateTime? lastBilledAt;   // web: tables.lastBilledAt (đã xuất bill)
  final DateTime? clearedAt;      // web: tables.clearedAt (lần dọn bàn gần nhất)
  /// Mã các đơn nằm trong bill in gần nhất — đơn đặt SAU khi in bill không có
  /// trong danh sách này → bàn chưa được coi là đã xuất bill cho đơn mới đó.
  final List<String>? lastBilledOrderIds;
  final bool isTakeaway;          // web: tables.type == 'takeaway' (bàn mang về)

  TableModel({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    this.currentOrderId,
    this.activeDiscount,
    this.serviceRequest,
    this.serviceRequestType,
    this.serviceRequestPayment,
    this.lastBilledAt,
    this.clearedAt,
    this.lastBilledOrderIds,
    this.isTakeaway = false,
  });

  static DateTime? _ts(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  static int _int(dynamic v, int def) {
    if (v is num) return v.toInt();
    return int.tryParse('${v ?? ''}') ?? def;
  }

  factory TableModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TableModel(
      id: doc.id,
      name: data['name'] ?? 'Bàn ${doc.id}',
      capacity: _int(data['capacity'], 4),
      status: data['status'] ?? 'available',
      currentOrderId: data['currentOrderId'],
      activeDiscount: data['activeDiscount'] is Map ? (data['activeDiscount'] as Map).cast<String, dynamic>() : null,
      serviceRequest: _ts(data['serviceRequest']),
      serviceRequestType: data['serviceRequestType'] as String?,
      serviceRequestPayment: data['serviceRequestPayment'] as String?,
      lastBilledAt: _ts(data['lastBilledAt']),
      clearedAt: _ts(data['clearedAt']),
      lastBilledOrderIds: data['lastBilledOrderIds'] is List
          ? (data['lastBilledOrderIds'] as List).map((e) => e.toString()).toList()
          : null,
      isTakeaway: data['type'] == 'takeaway',
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'capacity': capacity,
    'status': status,
    if (currentOrderId != null) 'currentOrderId': currentOrderId,
  };

  String get statusLabel {
    switch (status) {
      case 'occupied': return 'Đang dùng';
      case 'reserved': return 'Đặt trước';
      default: return 'Trống';
    }
  }

  bool get isAvailable => status == 'available';

  bool get isBillRequest => serviceRequest != null && serviceRequestType == 'bill';

  String get _paymentLabel => switch (serviceRequestPayment) {
        'transfer' => 'chuyển khoản',
        'cash' => 'tiền mặt',
        _ => '',
      };

  /// Nhãn ngắn (chip, tiêu đề banner): "Gọi phục vụ" / "Tính tiền · chuyển khoản".
  String get serviceRequestLabel {
    if (!isBillRequest) return 'Gọi phục vụ';
    return _paymentLabel.isEmpty ? 'Gọi tính tiền' : 'Tính tiền · $_paymentLabel';
  }

  /// Câu thông báo trong thẻ bàn.
  String get serviceRequestMessage {
    if (!isBillRequest) return 'Khách đang gọi phục vụ!';
    return _paymentLabel.isEmpty ? 'Khách muốn tính tiền!' : 'Khách muốn tính tiền — $_paymentLabel!';
  }

  /// Câu đọc bằng giọng nói khi có yêu cầu mới.
  String serviceRequestSpeech(String tableLabel) {
    if (!isBillRequest) return 'Bàn $tableLabel đang gọi nhân viên!';
    return _paymentLabel.isEmpty
        ? 'Bàn $tableLabel muốn thanh toán.'
        : 'Bàn $tableLabel muốn thanh toán, $_paymentLabel.';
  }

  TableModel copyWith({Map<String, dynamic>? activeDiscount, bool clearDiscount = false}) {
    return TableModel(
      id: id, name: name, capacity: capacity, status: status,
      currentOrderId: currentOrderId,
      activeDiscount: clearDiscount ? null : (activeDiscount ?? this.activeDiscount),
      serviceRequest: serviceRequest, lastBilledAt: lastBilledAt, clearedAt: clearedAt,
      serviceRequestType: serviceRequestType, serviceRequestPayment: serviceRequestPayment,
      lastBilledOrderIds: lastBilledOrderIds,
      isTakeaway: isTakeaway,
    );
  }
}
