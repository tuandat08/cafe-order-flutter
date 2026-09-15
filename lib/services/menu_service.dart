import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/menu_item_model.dart';

class MenuService {
  final _db = FirebaseFirestore.instance;

  Stream<List<MenuItemModel>> streamMenuItems() {
    return _db
        .collection('menu')
        .orderBy('category')
        .snapshots()
        .map((s) => s.docs.map(MenuItemModel.fromDoc).toList());
  }

  Future<List<MenuItemModel>> getAllItems() async {
    final snap = await _db.collection('menu').orderBy('category').get();
    return snap.docs.map(MenuItemModel.fromDoc).toList();
  }

  Future<void> addItem(MenuItemModel item) async {
    await _db.collection('menu').add(item.toMap());
  }

  Future<void> updateItem(String id, Map<String, dynamic> data) async {
    await _db.collection('menu').doc(id).update(data);
  }

  Future<void> deleteItem(String id) async {
    await _db.collection('menu').doc(id).delete();
  }

  Future<void> toggleAvailable(String id, bool available) async {
    await _db.collection('menu').doc(id).update({'available': available});
  }

  Future<List<String>> getCategories() async {
    final items = await getAllItems();
    return items.map((i) => i.category).toSet().toList()..sort();
  }
}
