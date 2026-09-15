import 'package:cloud_firestore/cloud_firestore.dart';

class DiscountModel {
  final String id;
  final String code;
  final String type; // 'percent' | 'fixed'
  final double value;
  final double maxDiscount;
  final int usedCount;
  final int? maxUsage;
  final bool active;
  final DateTime? expiresAt;
  final DateTime? createdAt;

  DiscountModel({
    required this.id,
    required this.code,
    required this.type,
    required this.value,
    required this.maxDiscount,
    required this.usedCount,
    this.maxUsage,
    required this.active,
    this.expiresAt,
    this.createdAt,
  });

  factory DiscountModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DiscountModel(
      id: doc.id,
      code: data['code'] ?? '',
      type: data['type'] ?? 'percent',
      value: (data['value'] ?? 0).toDouble(),
      maxDiscount: (data['maxDiscount'] ?? 0).toDouble(),
      usedCount: (data['usedCount'] ?? 0).toInt(),
      maxUsage: data['maxUsage'],
      active: data['active'] ?? true,
      expiresAt: (data['expiresAt'] as Timestamp?)?.toDate(),
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
    'code': code.toUpperCase().trim(),
    'type': type,
    'value': value,
    'maxDiscount': maxDiscount,
    'usedCount': usedCount,
    if (maxUsage != null) 'maxUsage': maxUsage,
    'active': active,
    if (expiresAt != null) 'expiresAt': Timestamp.fromDate(expiresAt!),
  };

  String get typeLabel => type == 'percent'
      ? '${value.toStringAsFixed(0)}%'
      : '${value.toStringAsFixed(0)}đ';

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  bool get isMaxedOut =>
      maxUsage != null && usedCount >= maxUsage!;
}
