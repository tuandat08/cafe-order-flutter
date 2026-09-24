import 'package:cloud_firestore/cloud_firestore.dart';
import 'firestore_write.dart';
import '../models/discount_model.dart';

class DiscountService {
  final _db = FirebaseFirestore.instance;

  Stream<List<DiscountModel>> streamDiscounts() {
    return _db.collection('discounts').snapshots().map((s) {
      final list = <DiscountModel>[];
      for (final d in s.docs) {
        try { list.add(DiscountModel.fromDoc(d)); } catch (_) {}
      }
      return list;
    });
  }

  Future<void> save(DiscountModel discount) async {
    final data = discount.toMap();
    if (discount.id.isEmpty) {
      await _db.collection('discounts').add({
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      await writeLocal(_db.collection('discounts').doc(discount.id).update(data));
    }
  }

  Future<void> delete(String id) async {
    await writeLocal(_db.collection('discounts').doc(id).delete());
  }

  Future<void> toggle(String id, bool active) async {
    await writeLocal(_db.collection('discounts').doc(id).update({'active': active}));
  }

  // Tăng lượt dùng mã sau khi áp dụng (giống web incrementUsage)
  Future<void> incrementUsage(String id) async {
    await writeLocal(_db.collection('discounts').doc(id).update({'usedCount': FieldValue.increment(1)}));
  }
}
