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

  /// Các ca đang mở, đọc thẳng từ SERVER (không dùng cache offline) — dùng làm
  /// chốt chặn cuối cùng trước khi mở ca mới, vì stream có thể phát kết quả
  /// cache rỗng/cũ ở lần đầu trên máy chưa đồng bộ.
  Future<List<ShiftModel>> getAllOpenShiftsFromServer() async {
    final snap = await _col
        .where('status', isEqualTo: 'open')
        .get(const GetOptions(source: Source.server));
    final list = snap.docs.map(ShiftModel.fromDoc).toList()
      ..sort((a, b) => a.openedAt.compareTo(b.openedAt));
    return list;
  }

  /// Mở ca mới. Ném [ShiftStillOpenException] nếu còn BẤT KỲ ca nào đang mở
  /// (của chính mình hoặc của tài khoản đăng nhập trước chưa đóng ca) — ngăn
  /// kéo tiền dùng chung nên ca cũ phải được kiểm & đóng trước.
  Future<String> openShift({
    required String staffId,
    required String staffName,
    required double openingCash,
  }) async {
    final stillOpen = await getAllOpenShiftsFromServer();
    if (stillOpen.isNotEmpty) throw ShiftStillOpenException(stillOpen.first);
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

  CollectionReference<Map<String, dynamic>> _moves(String shiftId) =>
      _col.doc(shiftId).collection('cashMovements');

  /// Ghi 1 lần chi tiền ra ([type] = 'out') hoặc nộp thêm tiền vào két
  /// ([type] = 'in') trong ca — để tiền két dự kiến luôn khớp thực tế.
  Future<void> addCashMovement(
    String shiftId, {
    required String type,
    required double amount,
    required String reason,
    required String staffId,
    required String staffName,
  }) async {
    await _moves(shiftId).add({
      'type': type,
      'amount': amount,
      'reason': reason,
      'staffId': staffId,
      'staffName': staffName,
      'createdAt': Timestamp.fromDate(DateTime.now()),
    });
  }

  Stream<List<CashMovement>> watchCashMovements(String shiftId) {
    return _moves(shiftId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) => snap.docs.map(CashMovement.fromDoc).toList());
  }

  /// Tổng tiền nộp vào / chi ra trong ca.
  static ({double cashIn, double cashOut}) sumMovements(Iterable<CashMovement> list) {
    double cashIn = 0, cashOut = 0;
    for (final m in list) {
      if (m.isOut) {
        cashOut += m.amount;
      } else {
        cashIn += m.amount;
      }
    }
    return (cashIn: cashIn, cashOut: cashOut);
  }

  Future<({double cashIn, double cashOut})> _movementTotals(String shiftId) async {
    final snap = await _moves(shiftId).get();
    return sumMovements(snap.docs.map(CashMovement.fromDoc));
  }

  Future<void> closeShift(
    ShiftModel shift, {
    required double closingCashCounted,
    String? note,
  }) async {
    final revenue = await _revenueSince(shift.openedAt);
    final moves = await _movementTotals(shift.id);
    await _col.doc(shift.id).update({
      'cashIn': moves.cashIn,
      'cashOut': moves.cashOut,
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
  /// thu tiền mặt + nộp thêm − chi ra) — dùng để hiển thị trước khi đóng ca.
  Future<double> computeExpectedCash(ShiftModel shift) async {
    final r = await _revenueSince(shift.openedAt);
    final cash = (r['cashRevenue'] ?? 0).toDouble();
    final moves = await _movementTotals(shift.id);
    return shift.openingCash + cash + moves.cashIn - moves.cashOut;
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

/// Còn ca đang mở chưa được đóng — không cho mở ca mới.
class ShiftStillOpenException implements Exception {
  final ShiftModel shift;
  const ShiftStillOpenException(this.shift);

  @override
  String toString() =>
      'Ca của ${shift.staffName} vẫn chưa được đóng — cần đóng ca đó trước khi mở ca mới.';
}
