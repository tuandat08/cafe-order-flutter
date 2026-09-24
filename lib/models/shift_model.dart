import 'package:cloud_firestore/cloud_firestore.dart';

/// Một ca làm việc: mở ca (ghi nhận tiền mặt đầu ca) → đóng ca (đếm tiền mặt
/// thực tế, đối chiếu với doanh thu hệ thống ghi nhận trong ca).
class ShiftModel {
  final String id;
  final String staffId;
  final String staffName;
  final DateTime openedAt;
  final double openingCash;

  final DateTime? closedAt;
  final double? closingCashCounted;

  // Doanh thu ghi nhận trong ca (tính khi đóng ca, từ các hóa đơn active).
  final double cashRevenue;
  final double transferRevenue;
  final double otherRevenue;
  final int invoiceCount;

  // Tiền chi ra / nộp thêm vào két trong ca (mua đá, trả ship, nộp tiền lẻ...).
  final double cashIn;
  final double cashOut;

  final String? note;
  final String status; // 'open' | 'closed'

  const ShiftModel({
    required this.id,
    required this.staffId,
    required this.staffName,
    required this.openedAt,
    required this.openingCash,
    this.closedAt,
    this.closingCashCounted,
    this.cashRevenue = 0,
    this.transferRevenue = 0,
    this.otherRevenue = 0,
    this.invoiceCount = 0,
    this.cashIn = 0,
    this.cashOut = 0,
    this.note,
    this.status = 'open',
  });

  /// Tổng doanh thu ghi nhận trong ca (mọi hình thức thanh toán).
  double get totalRevenue => cashRevenue + transferRevenue + otherRevenue;

  /// Tiền mặt dự kiến còn trong ngăn kéo cuối ca = tiền đầu ca + doanh thu
  /// tiền mặt + tiền nộp thêm − tiền chi ra trong ca.
  double get expectedCash => openingCash + cashRevenue + cashIn - cashOut;

  /// Chênh lệch = tiền đếm thực tế - tiền dự kiến. Dương = dư, âm = thiếu.
  double? get discrepancy =>
      closingCashCounted == null ? null : closingCashCounted! - expectedCash;

  bool get isOpen => status == 'open';

  factory ShiftModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ShiftModel(
      id: doc.id,
      staffId: data['staffId'] ?? '',
      staffName: data['staffName'] ?? '',
      openedAt: (data['openedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      openingCash: (data['openingCash'] ?? 0).toDouble(),
      closedAt: (data['closedAt'] as Timestamp?)?.toDate(),
      closingCashCounted: data['closingCashCounted'] == null
          ? null
          : (data['closingCashCounted']).toDouble(),
      cashRevenue: (data['cashRevenue'] ?? 0).toDouble(),
      transferRevenue: (data['transferRevenue'] ?? 0).toDouble(),
      otherRevenue: (data['otherRevenue'] ?? 0).toDouble(),
      invoiceCount: (data['invoiceCount'] ?? 0) as int,
      cashIn: (data['cashIn'] ?? 0).toDouble(),
      cashOut: (data['cashOut'] ?? 0).toDouble(),
      note: data['note'],
      status: data['status'] ?? 'open',
    );
  }
}

/// 1 lần chi tiền ra khỏi két ('out') hoặc nộp thêm tiền vào két ('in') trong ca.
class CashMovement {
  final String id;
  final String type; // 'in' | 'out'
  final double amount;
  final String reason;
  final String staffName;
  final DateTime createdAt;

  const CashMovement({
    required this.id,
    required this.type,
    required this.amount,
    required this.reason,
    required this.staffName,
    required this.createdAt,
  });

  bool get isOut => type == 'out';

  factory CashMovement.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return CashMovement(
      id: doc.id,
      type: data['type'] ?? 'out',
      amount: (data['amount'] ?? 0).toDouble(),
      reason: data['reason'] ?? '',
      staffName: data['staffName'] ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
    );
  }
}
