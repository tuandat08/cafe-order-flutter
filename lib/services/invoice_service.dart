import 'package:cloud_firestore/cloud_firestore.dart';

/// Dịch vụ hóa đơn — port từ web invoiceService.
class InvoiceService {
  final _db = FirebaseFirestore.instance;

  /// Hóa đơn active gần nhất của bàn (để phát hiện "in lần 2").
  Future<Map<String, dynamic>?> getLatestActiveForTable(
    String tableId, {
    DateTime? clearedAt,
    DateTime? sessionStart,
  }) async {
    try {
      final now = DateTime.now();
      final todayStart = DateTime(now.year, now.month, now.day);
      final snap = await _db
          .collection('invoices')
          .where('tableId', isEqualTo: tableId)
          .get();
      if (snap.docs.isEmpty) return null;

      final list = <Map<String, dynamic>>[];
      for (final d in snap.docs) {
        final inv = <String, dynamic>{'id': d.id, ...d.data()};
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
      await _db.collection('invoices').doc(invoiceId).update({
        'status': 'superseded',
        'supersededAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  /// Lưu hóa đơn đầy đủ. Trả về id, hoặc null nếu lỗi.
  Future<String?> saveInvoice(
    Map<String, dynamic> data, {
    String? reason,
    String? previousInvoiceId,
    String? staffName,
    String? staffId,
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
      final ref = await _db.collection('invoices').add(toSave);
      if (isPrint2 && previousInvoiceId != null) {
        await supersede(previousInvoiceId);
      }
      return ref.id;
    } catch (_) {
      return null;
    }
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
      await _db.collection('invoices').doc(snap.docs.first.id).update({'paymentMethod': paymentMethod});
    } catch (_) {}
  }
}
