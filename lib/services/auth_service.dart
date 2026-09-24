import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import '../models/account_model.dart';

const _salt = 'cafe_pos_v1_2024';

class AuthService {
  final _db = FirebaseFirestore.instance;

  String hashPassword(String password) {
    final bytes = utf8.encode(password + _salt);
    return sha256.convert(bytes).toString();
  }

  Future<AccountModel?> login(String username, String password) async {
    final hash = hashPassword(password);
    final cleanUsername = username.trim().toLowerCase();
    // ignore: avoid_print
    print('[AuthService] login attempt username="$cleanUsername" hash=$hash');
    final snap = await _db
        .collection('accounts')
        .where('username', isEqualTo: cleanUsername)
        .where('active', isEqualTo: true)
        .limit(1)
        .get();
    // ignore: avoid_print
    print('[AuthService] query returned ${snap.docs.length} doc(s)');

    if (snap.docs.isEmpty) return null;
    final account = AccountModel.fromDoc(snap.docs.first);
    // ignore: avoid_print
    print('[AuthService] found account username=${account.username} storedHash=${account.passwordHash} inputHash=$hash match=${account.passwordHash == hash}');
    if (account.passwordHash != hash) return null;
    return account;
  }

  Future<void> createAccount({
    required String username,
    required String password,
    required String fullName,
    required String role,
  }) async {
    final hash = hashPassword(password);
    await _db.collection('accounts').add({
      'username': username.trim().toLowerCase(),
      'passwordHash': hash,
      'fullName': fullName.trim(),
      'role': role,
      'active': true,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Future<void> updateAccount(String id, Map<String, dynamic> data) async {
    await _db.collection('accounts').doc(id).update({
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Xác thực mật khẩu của 1 tài khoản ADMIN đang hoạt động — dùng cho các
  /// thao tác cần quản lý duyệt (thay cho mật khẩu cố định ghi trong code).
  /// Trả về tài khoản admin khớp mật khẩu, hoặc null nếu không khớp.
  Future<AccountModel?> verifyManagerPassword(String password) async {
    final hash = hashPassword(password);
    final snap = await _db
        .collection('accounts')
        .where('role', isEqualTo: 'admin')
        .get();
    for (final d in snap.docs) {
      final acc = AccountModel.fromDoc(d);
      if (acc.active && acc.passwordHash == hash) return acc;
    }
    return null;
  }

  Future<void> updatePassword(String id, String newPassword) async {
    final hash = hashPassword(newPassword);
    await _db.collection('accounts').doc(id).update({
      'passwordHash': hash,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  Stream<List<AccountModel>> streamAccounts() {
    return _db
        .collection('accounts')
        .orderBy('createdAt', descending: false)
        .snapshots()
        .map((snap) => snap.docs.map(AccountModel.fromDoc).toList());
  }
}
