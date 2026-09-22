import 'package:cloud_firestore/cloud_firestore.dart';

class DiscountModel {
  final String id;
  final String code;
  final String type; // 'percent' | 'fixed'
  final double value;
  final double maxDiscount;
  final int usedCount;
  final int? maxUsage;
  final String? description;
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
    this.description,
    required this.active,
    this.expiresAt,
    this.createdAt,
  });

  static DateTime? _ts(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is DateTime) return v;
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    if (v is String) return DateTime.tryParse(v);
    return null;
  }

  factory DiscountModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return DiscountModel(
      id: doc.id,
      code: data['code'] ?? '',
      type: data['type'] ?? 'percent',
      value: double.tryParse('${data['value'] ?? 0}') ?? 0.0,
      maxDiscount: double.tryParse('${data['maxDiscount'] ?? 0}') ?? 0.0,
      usedCount: int.tryParse('${data['usedCount'] ?? 0}') ?? 0,
      maxUsage: data['maxUsage'] != null ? int.tryParse('${data['maxUsage']}') : (data['usageLimit'] != null ? int.tryParse('${data['usageLimit']}') : null),
      description: data['description']?.toString(),
      active: data['active'] ?? true,
      expiresAt: _ts(data['expiresAt']),
      createdAt: _ts(data['createdAt']),
    );
  }

  Map<String, dynamic> toMap() => {
    'code': code.toUpperCase().trim(),
    'type': type,
    'value': value,
    'maxDiscount': maxDiscount,
    'usedCount': usedCount,
    if (maxUsage != null) 'maxUsage': maxUsage,
    if (description != null) 'description': description,
    'active': active,
    if (expiresAt != null) 'expiresAt': Timestamp.fromDate(expiresAt!),
  };

  String get typeLabel => type == 'percent'
      ? '${value.toStringAsFixed(0)}%'
      : '${value.toStringAsFixed(0)}đ';

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  // Giống web: chỉ chặn khi usageLimit > 0 (0 = không giới hạn)
  bool get isMaxedOut =>
      maxUsage != null && maxUsage! > 0 && usedCount >= maxUsage!;
}
