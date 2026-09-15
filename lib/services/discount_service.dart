import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/discount_model.dart';

class DiscountService {
  final _db = FirebaseFirestore.instance;

  Stream<List<DiscountModel>> streamDiscounts() {
    return _db.collection('discounts').snapshots().map(
      (s) => s.docs.map(DiscountModel.fromDoc).toList(),
    );
  }

  Future<void> save(DiscountModel discount) async {
    final data = discount.toMap();
    if (discount.id.isEmpty) {
      await _db.collection('discounts').add({
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else {
      await _db.collection('discounts').doc(discount.id).update(data);
    }
  }

  Future<void> delete(String id) async {
    await _db.collection('discounts').doc(id).delete();
  }

  Future<void> toggle(String id, bool active) async {
    await _db.collection('discounts').doc(id).update({'active': active});
  }
}
