import 'dart:async';
import 'package:flutter/foundation.dart';

/// Ghi Firestore theo kiểu "lưu trên máy trước".
///
/// Firestore áp dụng lệnh ghi vào bộ nhớ máy NGAY khi gọi, nhưng Future của
/// set()/update()/delete() chỉ hoàn tất khi MÁY CHỦ xác nhận — lúc mất mạng thì
/// không bao giờ hoàn tất → màn hình quay mãi (vd: in hóa đơn khi offline).
///
/// Hàm này chờ tối đa [wait]: có mạng thì lệnh thường xong trước đó (lỗi, vd bị
/// Security Rules chặn, vẫn được ném ra như cũ); mất mạng thì bỏ qua việc chờ —
/// dữ liệu đã nằm trong hàng đợi trên máy và Firestore tự gửi lên khi có mạng lại.
Future<void> writeLocal(Future<void> write, {Duration wait = const Duration(milliseconds: 1500)}) {
  // Quan sát lỗi đến MUỘN (sau khi đã thôi chờ) để không thành lỗi không ai bắt.
  write.then((_) {}, onError: (Object e) => debugPrint('[writeLocal] ghi thất bại (muộn): $e'));
  return write.timeout(wait, onTimeout: () {
    debugPrint('[writeLocal] chưa có xác nhận từ máy chủ — đã lưu trên máy, sẽ tự đồng bộ');
  });
}
