import 'package:cloud_firestore/cloud_firestore.dart';

class OrderItem {
  final String id;
  final String name;
  final int quantity;
  final double price;
  final String? note;

  OrderItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.price,
    this.note,
  });

  factory OrderItem.fromMap(Map<String, dynamic> map) {
    return OrderItem(
      id: map['id'] ?? '',
      name: map['name'] ?? '',
      quantity: (map['quantity'] ?? 1).toInt(),
      price: (map['price'] ?? 0).toDouble(),
      note: map['note'],
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'quantity': quantity,
    'price': price,
    if (note != null) 'note': note,
  };

  double get subtotal => price * quantity;
}

class OrderModel {
  final String id;
  final String tableId;
  final List<OrderItem> items;
  final String status;
  final double totalPrice;
  final String? paymentType; // 'PREPAID' | 'POSTPAID'
  final String? note;
  final DateTime? createdAt;
  final String? staffName;

  OrderModel({
    required this.id,
    required this.tableId,
    required this.items,
    required this.status,
    required this.totalPrice,
    this.paymentType,
    this.note,
    this.createdAt,
    this.staffName,
  });

  factory OrderModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final itemsList = (data['items'] as List<dynamic>? ?? [])
        .map((i) => OrderItem.fromMap(i as Map<String, dynamic>))
        .toList();

    return OrderModel(
      id: doc.id,
      tableId: data['tableId']?.toString() ?? '',
      items: itemsList,
      status: data['status'] ?? 'pending',
      totalPrice: (data['totalPrice'] ?? 0).toDouble(),
      paymentType: data['paymentType'],
      note: data['note'],
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      staffName: data['staffName'],
    );
  }

  String get statusLabel {
    switch (status) {
      case 'pending': return 'Chờ xử lý';
      case 'preparing': return 'Đang pha chế';
      case 'ready': return 'Sẵn sàng';
      case 'served': return 'Đã phục vụ';
      case 'paid': return 'Đã thanh toán';
      case 'cancelled': return 'Đã huỷ';
      default: return status;
    }
  }

  List<String> get nextStatuses {
    switch (status) {
      case 'pending': return ['preparing', 'cancelled'];
      case 'preparing': return ['ready', 'cancelled'];
      case 'ready': return ['served'];
      case 'served': return ['paid'];
      default: return [];
    }
  }
}
