import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_write.dart';
import 'package:uuid/uuid.dart';
import '../models/table_model.dart';

class TableService {
  final _db = FirebaseFirestore.instance;

  Stream<List<TableModel>> streamTables() {
    return _db.collection('tables').snapshots().map((s) {
      final list = <TableModel>[];
      for (final d in s.docs) {
        try { list.add(TableModel.fromDoc(d)); } catch (_) {}
      }
      list.sort((a, b) => a.id.compareTo(b.id));
      return list;
    });
  }

  Future<List<TableModel>> getAllTables() async {
    final snap = await _db.collection('tables').get();
    final tables = snap.docs.map(TableModel.fromDoc).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return tables;
  }

  Future<void> saveTable(TableModel table) async {
    await writeLocal(_db.collection('tables').doc(table.id).set(table.toMap()));
  }

  Future<void> updateTable(String id, Map<String, dynamic> data) async {
    await writeLocal(_db.collection('tables').doc(id).update(data));
  }

  Future<void> deleteTable(String id) async {
    await writeLocal(_db.collection('tables').doc(id).delete());
  }

  Future<void> updateStatus(String id, String status) async {
    await writeLocal(_db.collection('tables').doc(id).update({'status': status}));
  }

  // Ghi/xoá discount lên table doc (giống web tableService.setTableDiscount)
  // discount = {id, code, type, value, maxDiscount, description} | null
  Future<void> setTableDiscount(String tableId, Map<String, dynamic>? discount) async {
    final tt = tableId.trim();
    final candidates = <String>{tt, tt.padLeft(2, '0')};
    final nn = int.tryParse(tt);
    if (nn != null) candidates.add(nn.toString());
    for (final id in candidates) {
      final ref = _db.collection('tables').doc(id);
      final snap = await ref.get();
      if (snap.exists) {
        await writeLocal(ref.update({'activeDiscount': discount}));
        return;
      }
    }
    // Không tìm thấy doc bàn nào (vd bàn "Mang về" do POS tạo, chưa có doc tables).
    // Nếu đang áp mã → tạo doc để lưu discount; gỡ mã (null) thì bỏ qua.
    if (discount != null) {
      await writeLocal(_db.collection('tables').doc(tt).set({
        'name': tt,
        'activeDiscount': discount,
      }, SetOptions(merge: true)));
    }
  }

  Future<void> clearTableDiscount(String tableId) => setTableDiscount(tableId, null);

  // Nhân viên đã xử lý gọi phục vụ — xoá signal (giống web clearServiceRequest)
  Future<void> clearServiceRequest(String tableId) async {
    final tt = tableId.trim();
    final candidates = <String>{tt, tt.padLeft(2, '0')};
    final nn = int.tryParse(tt);
    if (nn != null) candidates.add(nn.toString());
    for (final id in candidates) {
      final ref = _db.collection('tables').doc(id);
      final snap = await ref.get();
      if (snap.exists) {
        await writeLocal(ref.update({'serviceRequest': null}));
        return;
      }
    }
  }

  // Ghi nhận bàn đã xuất bill (giống orderService.updateTableLastBilledAt)
  Future<void> updateLastBilledAt(String tableId) async {
    final tt = tableId.trim();
    final candidates = <String>{tt, tt.padLeft(2, '0')};
    final nn = int.tryParse(tt);
    if (nn != null) candidates.add(nn.toString());
    for (final id in candidates) {
      final ref = _db.collection('tables').doc(id);
      final snap = await ref.get();
      if (snap.exists) {
        await writeLocal(ref.update({'lastBilledAt': Timestamp.fromDate(DateTime.now())}));
        return;
      }
    }
    // Bàn không có doc (vd "Mang về") → tạo doc để lưu mốc xuất bill
    await writeLocal(_db.collection('tables').doc(tt).set({
      'name': tt,
      'lastBilledAt': Timestamp.fromDate(DateTime.now()),
    }, SetOptions(merge: true)));
  }

  // Dọn bàn (giống web tableService.clearTable):
  // - xoá toàn bộ cartItems subcollection
  // - reset activeDiscount, sessionId mới, sessionToken=null → QR/URL cũ hết hiệu lực
  Future<void> clearTable(String tableId) async {
    final tt = tableId.trim();
    final candidates = <String>{tt, tt.padLeft(2, '0')};
    final nn = int.tryParse(tt);
    if (nn != null) candidates.add(nn.toString());
    for (final id in candidates) {
      final ref = _db.collection('tables').doc(id);
      final snap = await ref.get();
      if (snap.exists) {
        // Xoá cartItems subcollection
        final cart = await ref.collection('cartItems').get();
        if (cart.docs.isNotEmpty) {
          final batch = _db.batch();
          for (final d in cart.docs) {
            batch.delete(d.reference);
          }
          await writeLocal(batch.commit());
        }
        // Reset phiên: sessionToken=null làm QR cũ không resolve được nữa
        await writeLocal(ref.update({
          'activeDiscount': null,
          'sessionId': const Uuid().v4(),
          'sessionToken': null,
        }));
        return;
      }
    }
    // Bàn "Mang về" (không có doc) — chỉ cần đảm bảo activeDiscount được gỡ
    await writeLocal(_db.collection('tables').doc(tt).set({
      'name': tt,
      'activeDiscount': null,
    }, SetOptions(merge: true)));
  }
}
