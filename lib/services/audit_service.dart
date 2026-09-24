import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/account_model.dart';

/// Nhật ký thao tác nhạy cảm về tiền (hủy/bớt món, xóa đơn, in bill không lưu
/// doanh thu...) — ghi lại AI làm, AI duyệt, LÚC NÀO, LÝ DO và số liệu trước/sau
/// để quản lý đối soát khi két bị lệch.
class AuditService {
  final _db = FirebaseFirestore.instance;

  // Mã hành động
  static const orderItemsReduced = 'order_items_reduced';
  static const orderDeleted = 'order_deleted';
  static const invoiceNotSaved = 'invoice_not_saved';

  Future<void> log({
    required String action,
    required AccountModel? staff,
    AccountModel? approvedBy,
    String? tableId,
    String? orderId,
    String? reason,
    double? amountBefore,
    double? amountAfter,
    Map<String, dynamic>? details,
  }) async {
    try {
      await _db.collection('auditLogs').add({
        'action': action,
        'createdAt': FieldValue.serverTimestamp(),
        'staffId': staff?.id,
        'staffName': staff?.fullName,
        'staffRole': staff?.role,
        if (approvedBy != null) 'approvedById': approvedBy.id,
        if (approvedBy != null) 'approvedByName': approvedBy.fullName,
        if (tableId != null) 'tableId': tableId,
        if (orderId != null) 'orderId': orderId,
        if (reason != null) 'reason': reason,
        if (amountBefore != null) 'amountBefore': amountBefore,
        if (amountAfter != null) 'amountAfter': amountAfter,
        if (amountBefore != null && amountAfter != null)
          'amountDiff': amountAfter - amountBefore,
        if (details != null) ...details,
      });
    } catch (e) {
      // Không chặn thao tác chính nếu ghi nhật ký lỗi (vd: mất mạng tạm thời —
      // Firestore vẫn tự đồng bộ lại khi có mạng).
      debugPrint('[Audit] log error: $e');
    }
  }
}
