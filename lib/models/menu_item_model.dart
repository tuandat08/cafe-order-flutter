import 'package:cloud_firestore/cloud_firestore.dart';

class MenuItemModel {
  final String id;
  final String name;
  final double price;
  final String category;
  final String? imageUrl;
  final String? description;
  final bool available;

  MenuItemModel({
    required this.id,
    required this.name,
    required this.price,
    required this.category,
    this.imageUrl,
    this.description,
    this.available = true,
  });

  static String? _parseString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map) return value['url']?.toString() ?? value.values.first?.toString();
    return value.toString();
  }

  // Giá có thể là số hoặc {vnd, usd} (web lưu price: {vnd, usd})
  static double _parsePrice(dynamic raw) {
    if (raw is Map) {
      return double.tryParse('${raw['vnd'] ?? 0}') ?? 0.0;
    }
    return double.tryParse('${raw ?? 0}') ?? 0.0;
  }

  // Ảnh có thể là URL string hoặc object Cloudinary {url, secure_url, src}
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

  factory MenuItemModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return MenuItemModel(
      id: doc.id,
      name: _parseString(data['name']) ?? '',
      price: _parsePrice(data['price']),
      category: _parseString(data['category']) ?? '',
      imageUrl: _parseImg(data['imageUrl']) ?? _parseImg(data['image']),
      description: _parseString(data['description']),
      available: data['available'] ?? true,
    );
  }

  Map<String, dynamic> toMap() => {
    'name': name,
    'price': price,
    'category': category,
    if (imageUrl != null) 'imageUrl': imageUrl,
    if (description != null) 'description': description,
    'available': available,
  };

  MenuItemModel copyWith({
    String? name,
    double? price,
    String? category,
    String? imageUrl,
    String? description,
    bool? available,
  }) {
    return MenuItemModel(
      id: id,
      name: name ?? this.name,
      price: price ?? this.price,
      category: category ?? this.category,
      imageUrl: imageUrl ?? this.imageUrl,
      description: description ?? this.description,
      available: available ?? this.available,
    );
  }
}
