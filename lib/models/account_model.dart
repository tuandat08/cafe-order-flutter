import 'package:cloud_firestore/cloud_firestore.dart';

class AccountModel {
  final String id;
  final String username;
  final String passwordHash;
  final String fullName;
  final String role; // 'admin' | 'staff' | 'kitchen'
  final bool active;
  final DateTime? createdAt;

  AccountModel({
    required this.id,
    required this.username,
    required this.passwordHash,
    required this.fullName,
    required this.role,
    required this.active,
    this.createdAt,
  });

  factory AccountModel.fromDoc(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return AccountModel(
      id: doc.id,
      username: data['username'] ?? '',
      passwordHash: data['passwordHash'] ?? '',
      fullName: data['fullName'] ?? '',
      role: data['role'] ?? 'staff',
      active: data['active'] ?? true,
      createdAt: (data['createdAt'] as Timestamp?)?.toDate(),
    );
  }

  Map<String, dynamic> toMap() => {
    'username': username,
    'passwordHash': passwordHash,
    'fullName': fullName,
    'role': role,
    'active': active,
    'updatedAt': FieldValue.serverTimestamp(),
  };

  String get roleLabel {
    switch (role) {
      case 'admin': return 'Quản lý';
      case 'kitchen': return 'Bếp';
      default: return 'Nhân viên';
    }
  }
}
