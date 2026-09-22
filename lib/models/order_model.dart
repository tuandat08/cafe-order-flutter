import 'package:cloud_firestore/cloud_firestore.dart';

class OrderItem {
  final String id;
  final String name;
  final int quantity;
  final double price;
  final String? note;
  final String? image;     // web: item.image (URL ảnh sản phẩm)
  final String? size;      // web: item.size
  final String? sweetness; // web KitchenPage: item.sweetness | khách ghi item.sugar

  OrderItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.price,
    this.note,
    this.image,
    this.size,
    this.sweetness,
  });

  factory OrderItem.fromMap(Map<String, dynamic> map) {
    return OrderItem(
      id: map['id']?.toString() ?? '',
      name: _parseName(map['name']),
      // Web dùng 'qty', Flutter cũ dùng 'quantity' — đọc cả hai
      quantity: _parseInt(map['qty'] ?? map['quantity']),
      // Web: price có thể là số hoặc {vnd, usd}
      price: _parsePrice(map['price']),
      note: map['note']?.toString(),
      image: _parseImg(map['image']),
      size: map['size']?.toString(),
      // Khách ghi 'sugar', KitchenPage đọc 'sweetness' — đọc cả hai
      sweetness: (map['sweetness'] ?? map['sugar'])?.toString(),
    );
  }

  // Ảnh có thể là URL string hoặc object Cloudinary {url, publicId}
  static String? _parseImg(dynamic raw) {
    if (raw == null) return null;
    String? u;
    if (raw is String) {
      u = raw;
    } else if (raw is Map) {
      u = (raw['url'] ?? raw['secure_url'] ?? raw['src'])?.toString();
    } else {
      u = raw.toString();
    }
    if (u == null || u.isEmpty) return null;
    if (u.startsWith('//')) u = 'https:$u';       // protocol-relative → https
    if (u.startsWith('http://')) u = u.replaceFirst('http://', 'https://');
    return u;
  }

  // quantity không bao giờ throw — mặc định 1
  static int _parseInt(dynamic raw) {
    if (raw == null) return 1;
    if (raw is num) return raw.toInt();
    return int.tryParse('$raw') ?? 1;
  }

  // name có thể là String hoặc {vi, en}
  static String _parseName(dynamic raw) {
    if (raw is Map) {
      return (raw['vi'] ?? raw['en'] ?? '').toString();
    }
    return raw?.toString() ?? '';
  }

  // price có thể là số hoặc {vnd, usd}
  static double _parsePrice(dynamic raw) {
    if (raw is Map) {
      return double.tryParse('${raw['vnd'] ?? 0}') ?? 0.0;
    }
    return double.tryParse('${raw ?? 0}') ?? 0.0;
  }

  // Ghi cả 2 schema (web 'qty' + Flutter 'quantity') để đồng bộ 2 chiều
  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'qty': quantity,
    'quantity': quantity,
    'price': price,
    if (note != null) 'note': note,
    if (image != null) 'image': image,
    if (size != null) 'size': size,
    if (sweetness != null) 'sweetness': sweetness,
  };

  double get subtotal => price * quantity;
}

class OrderModel {
  final String id;
  final String tableId;
  final List<OrderItem> items;
  final String status;
  final double totalPrice;     // VND
  final double totalUsd;       // USD
  final String? paymentType;   // Flutter: 'PREPAID' | 'POSTPAID'
  final String? paymentMethod; // Web: 'counter' | ... (khách chọn)
  final String? source;        // Web: 'staff_add' | null
  final String? discountCode;  // Mã giảm áp lên đơn (nếu có)
  final double discountAmount; // Số tiền giảm trên đơn
  final String? note;
  final DateTime? createdAt;
  final String? staffName;

  OrderModel({
    required this.id,
    required this.tableId,
    required this.items,
    required this.status,
    required this.totalPrice,
    this.totalUsd = 0.0,
    this.paymentType,
    this.paymentMethod,
    this.source,
    this.discountCode,
    this.discountAmount = 0.0,
    this.note,
    this.createdAt,
    this.staffName,
  });

  factory OrderModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final itemsList = (data['items'] as List<dynamic>? ?? [])
        .map((i) => OrderItem.fromMap(i as Map<String, dynamic>))
        .toList();

    // Web lưu totalAmount: {vnd, usd}; Flutter cũ lưu totalPrice (số) — đọc cả hai
    double vnd = 0.0;
    double usd = 0.0;
    final ta = data['totalAmount'];
    if (ta is Map) {
      vnd = double.tryParse('${ta['vnd'] ?? 0}') ?? 0.0;
      usd = double.tryParse('${ta['usd'] ?? 0}') ?? 0.0;
    } else if (ta != null) {
      vnd = double.tryParse('$ta') ?? 0.0;
    }
    if (vnd == 0.0 && data['totalPrice'] != null) {
      vnd = double.tryParse('${data['totalPrice']}') ?? 0.0;
    }
    if (usd == 0.0 && vnd > 0) usd = vnd / 26000;

    return OrderModel(
      id: doc.id,
      tableId: data['tableId']?.toString() ?? '',
      items: itemsList,
      status: data['status'] ?? 'pending',
      totalPrice: vnd,
      totalUsd: usd,
      paymentType: data['paymentType']?.toString(),
      paymentMethod: data['paymentMethod']?.toString(),
      source: data['source']?.toString(),
      discountCode: data['discountCode']?.toString(),
      discountAmount: double.tryParse('${data['discountAmount'] ?? 0}') ?? 0.0,
      note: data['note']?.toString(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
      staffName: data['staffName']?.toString(),
    );
  }

  String get statusLabel {
    switch (status) {
      case 'pending': return 'Chờ xử lý';
      case 'preparing': return 'Đang pha chế';
      case 'ready': return 'Sẵn sàng';
      case 'served': return 'Đã phục vụ';
      case 'completed': return 'Hoàn thành';
      case 'paid': return 'Đã thanh toán';
      case 'closed': return 'Đã đóng';
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
