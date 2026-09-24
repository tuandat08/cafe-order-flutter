import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/floor_plan_models.dart';

// Đúng các trạng thái đơn hàng được coi là "đang phục vụ" — giống hệt _kActive
// dùng ở orders_screen.dart (POS) để xác định bàn nào đang có khách.
const kActiveOrderStatuses = {'pending', 'preparing', 'ready', 'served', 'completed'};

// Đọc dữ liệu sơ đồ bàn (đã setting ở trang web: admin > Sơ đồ bàn) để hiển thị
// (chỉ đọc — không chỉnh sửa) bên trong app mobile khi tạo đơn (POS).
class FloorPlanService {
  final _db = FirebaseFirestore.instance;

  // Bàn nào đang thực sự có đơn hàng active (chưa thanh toán/huỷ) — nguồn dữ
  // liệu này khớp với cách app tính "đang phục vụ" ở mọi nơi khác (chip chọn
  // bàn, dialog chọn bàn...), KHÔNG dựa vào field status trên chính doc bàn
  // (field đó có thể không được cập nhật đồng bộ theo thời gian thực).
  Stream<Set<String>> streamOccupiedTableIds() {
    // Chỉ tải đơn đang hoạt động (lọc trên server), không tải toàn bộ lịch sử.
    return _db
        .collection('orders')
        .where('status', whereIn: kActiveOrderStatuses.toList())
        .snapshots()
        .map((s) {
      final occ = <String>{};
      for (final d in s.docs) {
        final data = d.data();
        final status = data['status']?.toString() ?? '';
        if (kActiveOrderStatuses.contains(status)) {
          final tid = data['tableId']?.toString() ?? '';
          if (tid.isNotEmpty) occ.add(tid);
        }
      }
      return occ;
    });
  }

  Stream<List<FloorZone>> streamZoneOverrides() {
    return _db.collection('floorZones').snapshots().map(
      (s) => s.docs.map((d) => FloorZone.fromMap(d.id, d.data())).toList(),
    );
  }

  Stream<List<FloorItemPlacement>> streamItemPlacements() {
    return _db.collection('floorItemPlacements').snapshots().map(
      (s) => s.docs.map(FloorItemPlacement.fromDoc).toList(),
    );
  }

  Stream<List<FloorTable>> streamFloorTables() {
    return _db.collection('tables').snapshots().map((s) {
      final list = <FloorTable>[];
      for (final d in s.docs) {
        try {
          final data = d.data();
          if (data['type'] == 'takeaway') continue; // bỏ bàn "Mang về"
          list.add(FloorTable.fromDoc(d));
        } catch (_) {}
      }
      return list;
    });
  }
}
