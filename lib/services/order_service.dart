import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/order_model.dart';

class OrderService {
  final _db = FirebaseFirestore.instance;

  // ─── Active orders: filter + sort hoàn toàn client-side ─────────────
  // Không dùng whereIn/orderBy trên Firestore → không cần composite index.
  Stream<List<OrderModel>> streamActiveOrders() {
    return _db.collection('orders').snapshots().map((snap) {
      const active = {'pending', 'preparing', 'ready', 'served'};
      final list = <OrderModel>[];
      for (final doc in snap.docs) {
        try {
          final o = OrderModel.fromDoc(doc);
          if (active.contains(o.status)) list.add(o);
        } catch (e) {
          debugPrint('[OrderService] fromDoc error ${doc.id}: $e');
        }
      }
      list.sort((a, b) {
        final ta = a.createdAt?.millisecondsSinceEpoch ?? 9999999999999;
        final tb = b.createdAt?.millisecondsSinceEpoch ?? 9999999999999;
        return tb.compareTo(ta);
      });
      debugPrint('[OrderService] stream: raw=${snap.docs.length} active=${list.length}');
      return list;
    });
  }

  Stream<List<OrderModel>> streamOrdersByDate(DateTime date) {
    final start = DateTime(date.year, date.month, date.day);
    final end = start.add(const Duration(days: 1));
    return _db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snap) {
          final list = <OrderModel>[];
          for (final doc in snap.docs) {
            try { list.add(OrderModel.fromDoc(doc)); } catch (e) {
              debugPrint('[OrderService] streamOrdersByDate fromDoc: $e');
            }
          }
          return list;
        });
  }

  Future<List<OrderModel>> getOrdersByDateRange(DateTime from, DateTime to) async {
    final snap = await _db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(from))
        .where('createdAt', isLessThan: Timestamp.fromDate(to))
        .orderBy('createdAt', descending: true)
        .get();
    return snap.docs
        .map((d) { try { return OrderModel.fromDoc(d); } catch (_) { return null; } })
        .whereType<OrderModel>()
        .toList();
  }

  Future<void> updateStatus(String orderId, String status) async {
    await _db.collection('orders').doc(orderId).update({
      'status': status,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // Tìm document bàn theo id (thử cả "2" lẫn "02") — giống web _resolveTableRef
  Future<DocumentReference?> _resolveTableRef(String tableId) async {
    final candidates = <String>{tableId.trim(), tableId.trim().padLeft(2, '0')};
    for (final id in candidates) {
      final ref = _db.collection('tables').doc(id);
      final snap = await ref.get();
      if (snap.exists) return ref;
    }
    return null;
  }

  // Đóng tất cả đơn + giải phóng bàn + ghi clearLogs (giống web completeAllOrdersAndFreeTable)
  Future<void> completeAllOrdersAndFreeTable(
    String tableId,
    List<String> orderIds, {
    String? clearReason,
    double totalAmount = 0,
    String? staffId,
    String? staffName,
    String? staffRole,
  }) async {
    final clearedAt = Timestamp.fromDate(DateTime.now());
    // 1. Đóng tất cả đơn
    await Future.wait(orderIds.map((id) =>
        _db.collection('orders').doc(id).update({'status': 'closed'})));
    // 2. Cập nhật bàn: available + clearedAt (+ clearReason)
    final tableRef = await _resolveTableRef(tableId);
    if (tableRef != null) {
      await tableRef.update({
        'status': 'available',
        'clearedAt': clearedAt,
        if (clearReason != null) 'clearReason': clearReason,
      });
    }
    // 3. Dọn bàn không xuất bill → ghi clearLogs
    if (clearReason != null) {
      await _db.collection('clearLogs').add({
        'tableId': tableId,
        'reason': clearReason,
        'clearedAt': clearedAt,
        'orderIds': orderIds,
        'orderCount': orderIds.length,
        'totalAmount': totalAmount,
        if (staffId != null) 'staffId': staffId,
        if (staffName != null) 'staffName': staffName,
        if (staffRole != null) 'staffRole': staffRole,
      });
    }
  }

  // Ghi nhận bàn đã xuất bill (giống web updateTableLastBilledAt)
  Future<void> updateTableLastBilledAt(String tableId) async {
    final tableRef = await _resolveTableRef(tableId);
    if (tableRef != null) {
      await tableRef.update({'lastBilledAt': Timestamp.fromDate(DateTime.now())});
    }
  }

  // Áp/gỡ mã giảm giá ở cấp ĐƠN (dùng cho đơn mang về — mỗi đơn riêng)
  Future<void> setOrderDiscount(String orderId, {String? code, double amount = 0}) async {
    await _db.collection('orders').doc(orderId).update({
      'discountCode': code,
      'discountAmount': amount,
    });
  }

  Future<void> deleteOrder(String orderId) async {
    await _db.collection('orders').doc(orderId).delete();
  }

  // Cập nhật danh sách món + tổng tiền (giống web orderService.updateOrderItems)
  Future<void> updateOrderItems(
      String orderId, List<OrderItem> items,
      {required double vnd, required double usd}) async {
    await _db.collection('orders').doc(orderId).update({
      'items': items.map((i) => i.toMap()).toList(),
      'totalAmount': {'vnd': vnd, 'usd': usd},
      'totalPrice': vnd,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<Map<String, dynamic>> getTodayStats() async {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day);
    final end = start.add(const Duration(days: 1));
    final snap = await _db
        .collection('orders')
        .where('createdAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('createdAt', isLessThan: Timestamp.fromDate(end))
        .get();
    final paid = snap.docs
        .map((d) { try { return OrderModel.fromDoc(d); } catch (_) { return null; } })
        .whereType<OrderModel>()
        .where((o) => o.status == 'paid')
        .toList();
    return {
      'orderCount': paid.length,
      'revenue': paid.fold(0.0, (s, o) => s + o.totalPrice),
    };
  }

  /// Tạo đơn hàng và chờ server xác nhận ghi thành công.
  /// Nếu Firestore Security Rules block write → throw FirebaseException.
  Future<String> createOrder({
    required String tableId,
    required List<OrderItem> items,
    String? note,
    String paymentType = 'POSTPAID',
  }) async {
    final total = items.fold(0.0, (s, i) => s + i.subtotal);
    final usd = double.parse((total / 26000).toStringAsFixed(2));
    // Ghi cả 2 schema (web totalAmount/paymentMethod + Flutter totalPrice/paymentType)
    // để web và Flutter đều đọc đúng
    final ref = await _db.collection('orders').add({
      'tableId': tableId,
      'items': items.map((i) => i.toMap()).toList(),
      'status': 'pending',
      'totalPrice': total,
      'totalAmount': {'vnd': total, 'usd': usd},
      'paymentType': paymentType,
      'paymentMethod': 'counter',
      'source': 'staff_add',
      if (note != null && note.isNotEmpty) 'note': note,
      'createdAt': FieldValue.serverTimestamp(),
    });
    // Xác nhận từ server — phát hiện lỗi Security Rules ngay lập tức
    try {
      await ref.get(const GetOptions(source: Source.server));
      debugPrint('[OrderService] createOrder OK: ${ref.id}');
    } catch (e) {
      debugPrint('[OrderService] createOrder server error: $e');
      await ref.delete().catchError((_) {});
      rethrow;
    }
    return ref.id;
  }
}
