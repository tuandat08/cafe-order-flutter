import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/shift_model.dart';

/// Dịch vụ kiểm ca / đóng ca — đối chiếu tiền mặt thực tế trong ngăn kéo với
/// doanh thu hệ thống ghi nhận, giúp phát hiện thất thoát cuối mỗi ca.
class ShiftService {
  final _db = FirebaseFirestore.instance;
  CollectionReference<Map<String, dynamic>> get _col => _db.collection('shifts');

  /// Ca đang mở của 1 nhân viên (nếu có) — mỗi người chỉ được mở 1 ca cùng lúc.
  Stream<ShiftModel?> watchOpenShift(String staffId) {
    return _col
        .where('staffId', isEqualTo: staffId)
        .where('status', isEqualTo: 'open')
        .limit(1)
        .snapshots()
        .map((snap) => snap.docs.isEmpty ? null : ShiftModel.fromDoc(snap.docs.first));
  }

  /// TOÀN BỘ các ca đang mở của MọI nhân viên (không lọc theo staffId) —
  /// dùng để phát hiện ca cũ bị bỏ dở từ người khác (vd: staff A mở ca rồi
  /// thoát app kiểu vượt-tắt, sau đó admin hoặc staff B đăng nhập) — vì ngăn
  /// kéo tiền là dùng chung, ca cũ phải được đóng trước khi BỬ KỂ AI dùng app tiếp.
  Stream<List<ShiftModel>> watchAllOpenShifts() {
    return _col
        .where('status', isEqualTo: 'open')
        .snapshots()
        .map((snap) => snap.docs.map(ShiftModel.fromDoc).toList());
  }

  Future<ShiftModel?> getOpenShift(String staffId) async {
    final snap = await _col
        .where('staffId', isEqualTo: staffId)
        .where('status', isEqualTo: 'open')
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    return ShiftModel.fromDoc(snap.docs.first);
  }

  Future<String> openShift({
    required String staffId,
    required String staffName,
    required double openingCash,
  }) async {
    final ref = await _col.add({
      'staffId': staffId,
      'staffName': staffName,
      'openedAt': FieldValue.serverTimestamp(),
      'openingCash': openingCash,
      'status': 'open',
    });
    return ref.id;
  }

  /// Cộng dồn doanh thu từ danh sách hóa đơn, chia theo phương thức thanh
  /// toán (bỏ qua bản bị supersede) — dùng chung cho cả truy vấn 1 lần và stream.
  Map<String, dynamic> _aggregateRevenue(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    double cash = 0, transfer = 0, other = 0;
    int count = 0;
    for (final d in docs) {
      final inv = d.data();
      if (inv['status'] == 'superseded') continue;
      final amount = (inv['totalAmount'] ?? 0).toDouble();
      final method = inv['paymentMethod'];
      if (method == 'Tiền mặt') {
        cash += amount;
      } else if (method == 'Chuyển khoản') {
        transfer += amount;
      } else {
        other += amount;
      }
      count++;
    }
    return {
      'cashRevenue': cash,
      'transferRevenue': transfer,
      'otherRevenue': other,
      'invoiceCount': count,
    };
  }

  /// Doanh thu ghi nhận từ mốc [since] đến hiện tại (truy vấn 1 lần).
  Future<Map<String, dynamic>> _revenueSince(DateTime since) async {
    final snap = await _db
        .collection('invoices')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
        .get();
    return _aggregateRevenue(snap.docs);
  }

  /// Doanh thu "sống" của ca đang mở — dùng để hiển thị số liệu tạm thời
  /// trước khi đóng ca (không ghi vào Firestore).
  Future<Map<String, dynamic>> previewRevenue(DateTime since) => _revenueSince(since);

  /// Doanh thu "sống" của ca đang mở, cập nhật NGAY khi có hóa đơn mới được
  /// thanh toán — dùng để màn hình Kiểm ca tự cập nhật số liệu theo thời gian
  /// thực, không cần bấm refresh thủ công.
  Stream<Map<String, dynamic>> watchRevenueSince(DateTime since) {
    return _db
        .collection('invoices')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(since))
        .snapshots()
        .map((snap) => _aggregateRevenue(snap.docs));
  }

  Future<void> closeShift(
    ShiftModel shift, {
    required double closingCashCounted,
    String? note,
  }) async {
    final revenue = await _revenueSince(shift.openedAt);
    await _col.doc(shift.id).update({
      'closedAt': FieldValue.serverTimestamp(),
      'closingCashCounted': closingCashCounted,
      'cashRevenue': revenue['cashRevenue'],
      'transferRevenue': revenue['transferRevenue'],
      'otherRevenue': revenue['otherRevenue'],
      'invoiceCount': revenue['invoiceCount'],
      if (note != null && note.isNotEmpty) 'note': note,
      'status': 'closed',
    });
  }

  /// Tiền mặt dự kiến trong ngăn kéo NGAY LÚC NÀY nếu đóng ca (đầu ca + doanh
  /// thu tiền mặt phát sinh tới hiện tại) — dùng để hiển thị trước khi mở dialog đóng ca.
  Future<double> computeExpectedCash(ShiftModel shift) async {
    final r = await _revenueSince(shift.openedAt);
    final cash = (r['cashRevenue'] ?? 0).toDouble();
    return shift.openingCash + cash;
  }

  /// Lịch sử các ca đã đóng TRONG NGÀY HÔM NAY (theo giờ thiết bị), mới nhất
  /// trước — chỉ hiển thị thông tin của ngày hiện tại, không lẫn các ngày cũ.
  Stream<List<ShiftModel>> streamClosedShifts({int limit = 50}) {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    return _col
        .where('status', isEqualTo: 'closed')
        .where('closedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(startOfToday))
        .orderBy('closedAt', descending: true)
        .limit(limit)
        .snapshots()
        .map((snap) => snap.docs.map(ShiftModel.fromDoc).toList());
  }
}
