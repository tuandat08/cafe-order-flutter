import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/table_model.dart';

class TableService {
  final _db = FirebaseFirestore.instance;

  Stream<List<TableModel>> streamTables() {
    return _db.collection('tables').snapshots().map(
      (s) => s.docs.map(TableModel.fromDoc).toList()
        ..sort((a, b) => a.id.compareTo(b.id)),
    );
  }

  Future<List<TableModel>> getAllTables() async {
    final snap = await _db.collection('tables').get();
    final tables = snap.docs.map(TableModel.fromDoc).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return tables;
  }

  Future<void> saveTable(TableModel table) async {
    await _db.collection('tables').doc(table.id).set(table.toMap());
  }

  Future<void> updateTable(String id, Map<String, dynamic> data) async {
    await _db.collection('tables').doc(id).update(data);
  }

  Future<void> deleteTable(String id) async {
    await _db.collection('tables').doc(id).delete();
  }

  Future<void> updateStatus(String id, String status) async {
    await _db.collection('tables').doc(id).update({'status': status});
  }
}
