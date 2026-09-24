import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_write.dart';

/// Dịch vụ hóa đơn — port từ web invoiceService.
class InvoiceService {
  final _db = FirebaseFirestore.instance;

  /// Sinh trước 1 ID hóa đơn (chưa ghi vào Firestore) — dùng để hiển thị "Số
  /// hóa đơn" trên preview TRƯỚC khi bấm in, rồi dùng lại đúng ID này khi lưu
  /// thật (saveInvoice) để preview và bill in ra khớp 100%.
  String newInvoiceId() => _db.collection('invoices').doc().id;

  /// Hóa đơn active gần nhất của bàn (để phát hiện "in lần 2").
  Future<Map<String, dynamic>?> getLatestActiveForTable(
    String tableId, {
    DateTime? clearedAt,
    DateTime? sessionStart,
  }) async {
    try {
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      // Chỉ lấy hóa đơn TỪ ĐẦU NGÀY (lọc createdAt trên server, 1 field → không
      // cần composite index) rồi lọc bàn ở máy — trước đây lọc theo tableId nên
      // tải TOÀN BỘ hóa đơn từ trước tới nay của bàn, càng dùng lâu càng chậm.
      final snap = await _db
          .collection('invoices')
          .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(todayStart))
          .get();
      if (snap.docs.isEmpty) return null;

      final list = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final inv = <String, dynamic>{'id': d.id, ...d.data()};
        if ('${inv['tableId']}' != tableId) continue;
        if (inv['status'] == 'superseded') continue;
        final ts = inv['createdAt'];
        final dt = ts is Timestamp ? ts.toDate() : null;
        if (dt == null) {
          list.add(inv); // pending write → coi là hợp lệ
          continue;
        }
        if (dt.isBefore(todayStart)) continue;
        if (clearedAt != null && !dt.isAfter(clearedAt)) continue;
        if (sessionStart != null && dt.isBefore(sessionStart)) continue;
        list.add(inv);
      }
      if (list.isEmpty) return null;
      list.sort((a, b) {
        final ta = a['createdAt'] is Timestamp ? (a['createdAt'] as Timestamp).seconds : 0;
        final tb = b['createdAt'] is Timestamp ? (b['createdAt'] as Timestamp).seconds : 0;
        return tb.compareTo(ta);
      });
      return list.first;
    } catch (_) {
      return null;
    }
  }

  /// Hóa đơn active gần nhất theo ĐÚNG 1 đơn (dùng cho bàn mang về: mỗi đơn 1 bill).
  Future<Map<String, dynamic>?> getLatestActiveForOrder(String orderId) async {
    try {
      final snap = await _db
          .collection('invoices')
          .where('orderId', isEqualTo: orderId)
          .get();
      if (snap.docs.isEmpty) return null;
      final list = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final inv = <String, dynamic>{'id': d.id, ...d.data()};
        if (inv['status'] == 'superseded') continue;
        list.add(inv);
      }
      if (list.isEmpty) return null;
      list.sort((a, b) {
        final ta = a['createdAt'] is Timestamp ? (a['createdAt'] as Timestamp).seconds : 0;
        final tb = b['createdAt'] is Timestamp ? (b['createdAt'] as Timestamp).seconds : 0;
        return tb.compareTo(ta);
      });
      return list.first;
    } catch (_) {
      return null;
    }
  }

  Future<void> supersede(String invoiceId) async {
    try {
      await writeLocal(_db.collection('invoices').doc(invoiceId).update({
        'status': 'superseded',
        'supersededAt': FieldValue.serverTimestamp(),
      }));
    } catch (_) {}
  }

  /// Lưu hóa đơn đầy đủ. Trả về id, hoặc null nếu lỗi.
  Future<String?> saveInvoice(
    Map<String, dynamic> data, {
    String? reason,
    String? previousInvoiceId,
    String? staffName,
    String? staffId,
    String? invoiceId, // nếu có (từ newInvoiceId()) → ghi đúng ID này, để khớp với preview
  }) async {
    try {
      final isPrint2 = previousInvoiceId != null;
      final toSave = <String, dynamic>{
        'orderId': data['orderId'],
        'tableId': '${data['tableId']}',
        'items': data['items'] ?? [],
        'subtotal': data['subtotal'] ?? 0,
        'vatPercent': data['vatPercent'] ?? 0,
        'vatAmount': data['vatAmount'] ?? 0,
        'servicePercent': data['servicePercent'] ?? 0,
        'serviceAmount': data['serviceAmount'] ?? 0,
        'discount': data['discount'] ?? 0,
        'discountCode': data['discountCode'],
        'totalAmount': data['totalAmount'] ?? 0,
        'paymentMethod': data['paymentMethod'],
        'staffName': staffName,
        'staffId': staffId,
        'createdAt': Timestamp.fromDate(DateTime.now()),
        'type': 'payment_record',
        'status': 'active',
        'printCount': isPrint2 ? 2 : 1,
        if (isPrint2) 'isPrint2': true,
        if (isPrint2) 'reason': reason,
        if (isPrint2) 'previousInvoiceId': previousInvoiceId,
      };
      String resultId;
      if (invoiceId != null && invoiceId.isNotEmpty) {
        await writeLocal(_db.collection('invoices').doc(invoiceId).set(toSave));
        resultId = invoiceId;
      } else {
        final ref = _db.collection('invoices').doc();
        await writeLocal(ref.set(toSave));
        resultId = ref.id;
      }
      if (isPrint2 && previousInvoiceId != null) {
        await supersede(previousInvoiceId);
      }
      return resultId;
    } catch (_) {
      return null;
    }
  }

  /// Ghi nhận THU TIỀN cho hóa đơn active của đơn: phương thức, tiền khách
  /// đưa / tiền thối (tiền mặt), xác nhận đã nhận chuyển khoản, ai thu, lúc nào.
  Future<void> recordPayment(
    String orderId, {
    required String method,
    required double total,
    double? cashReceived,
    bool transferConfirmed = false,
    String? staffId,
    String? staffName,
  }) async {
    final snap = await _db
        .collection('invoices')
        .where('orderId', isEqualTo: orderId)
        .where('status', isEqualTo: 'active')
        .get();
    if (snap.docs.isEmpty) return;
    await writeLocal(_db.collection('invoices').doc(snap.docs.first.id).update({
      'paymentMethod': method,
      'paidAt': Timestamp.fromDate(DateTime.now()),
      if (staffId != null) 'paidById': staffId,
      if (staffName != null) 'paidByName': staffName,
      if (cashReceived != null) 'cashReceived': cashReceived,
      if (cashReceived != null) 'changeGiven': cashReceived - total,
      if (method == 'Chuyển khoản') 'transferConfirmed': transferConfirmed,
    }));
  }

  /// Cập nhật phương thức thanh toán cho hóa đơn active của đơn.
  Future<void> setPaymentMethod(String orderId, String paymentMethod) async {
    try {
      final snap = await _db
          .collection('invoices')
          .where('orderId', isEqualTo: orderId)
          .where('status', isEqualTo: 'active')
          .get();
      if (snap.docs.isEmpty) return;
      await writeLocal(_db.collection('invoices').doc(snap.docs.first.id).update({'paymentMethod': paymentMethod}));
    } catch (_) {}
  }
}
