import 'package:cloud_firestore/cloud_firestore.dart';

class TableModel {
  final String id;
  final String name;
  final int capacity;
  final String status; // 'available' | 'occupied' | 'reserved'
  final String? currentOrderId;

  TableModel({
    required this.id,
    required this.name,
    required this.capacity,
    required this.status,
    this.currentOrderId,
  });

  factory TableModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return TableModel(
      id: doc.id,
      name: data['name'] ?? 'Bàn ${doc.id}',
      capacity: (data['capacity'] ?? 4).toInt(),
      status: data['status'] ?? 'available',
      currentOrderId: data['currentOrderId'],
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'capacity': capacity,
    'status': status,
    if (currentOrderId != null) 'currentOrderId': currentOrderId,
  };

  String get statusLabel {
    switch (status) {
      case 'occupied': return 'Đang dùng';
      case 'reserved': return 'Đặt trước';
      default: return 'Trống';
    }
  }

  bool get isAvailable => status == 'available';
}
