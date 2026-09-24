import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../core/config.dart';
import '../models/account_model.dart';

const _salt = 'cafe_pos_v1_2024';

class AuthService {
  final _db = FirebaseFirestore.instance;

  String hashPassword(String password) {
    final bytes = utf8.encode(password + _salt);
    return sha256.convert(bytes).toString();
  }

  /// Đăng nhập qua API (repo api-cafe-management): máy chủ kiểm tra mật khẩu,
  /// trả về Firebase custom token → đăng nhập Firebase Auth. App không còn tự
  /// đọc bảng accounts để so mật khẩu (Security Rules sẽ chặn việc đó).
  ///
  /// Trả về null nếu sai tên đăng nhập / mật khẩu; ném [AuthApiException] cho
  /// các lỗi khác (bị khóa tạm, mất mạng, lỗi máy chủ).
  Future<AccountModel?> login(String username, String password) async {
    final http.Response res;
    try {
      res = await _post('/api/login', {
        'username': username.trim(),
        'password': password,
      });
    } on AuthApiException {
      if (!kLegacyAuthFallback) rethrow;
      return _legacyLogin(username, password);
    }
    if (kLegacyAuthFallback && _apiNotReady(res)) return _legacyLogin(username, password);
    if (res.statusCode == 401) return null;
    final data = _decode(res);
    if (res.statusCode != 200) throw AuthApiException(_errorOf(data));

    await FirebaseAuth.instance.signInWithCustomToken(data['token'] as String);
    final u = data['user'] as Map<String, dynamic>;
    return AccountModel(
      id: u['id'] as String,
      username: (u['username'] ?? '') as String,
      passwordHash: '',
      fullName: (u['fullName'] ?? '') as String,
      role: (u['role'] ?? 'staff') as String,
      active: true,
    );
  }

  Future<void> signOut() => FirebaseAuth.instance.signOut();

  /// Xác thực mật khẩu của 1 tài khoản ADMIN đang hoạt động — dùng cho các
  /// thao tác cần quản lý duyệt. Kiểm tra ở API vì máy nhân viên không được
  /// đọc bảng accounts. Trả về tài khoản admin đã duyệt, hoặc null nếu sai.
  Future<AccountModel?> verifyManagerPassword(String password) async {
    final idToken = await FirebaseAuth.instance.currentUser?.getIdToken();
    final http.Response res;
    try {
      res = await _post('/api/verify-manager', {'password': password}, idToken: idToken);
    } on AuthApiException {
      if (!kLegacyAuthFallback) rethrow;
      return _legacyVerifyManager(password);
    }
    if (kLegacyAuthFallback && (_apiNotReady(res) || idToken == null)) {
      return _legacyVerifyManager(password);
    }
    if (res.statusCode == 401 && idToken != null) {
      final data = _decode(res);
      if (_errorOf(data).contains('Mật khẩu')) return null;
      throw AuthApiException(_errorOf(data));
    }
    final data = _decode(res);
    if (res.statusCode != 200) throw AuthApiException(_errorOf(data));
    final m = data['manager'] as Map<String, dynamic>;
    return AccountModel(
      id: m['id'] as String,
      username: '',
      passwordHash: '',
      fullName: (m['fullName'] ?? '') as String,
      role: 'admin',
      active: true,
    );
  }

  Future<http.Response> _post(String path, Map<String, dynamic> body, {String? idToken}) async {
    try {
      return await http
          .post(
            Uri.parse('$kAuthApiUrl$path'),
            headers: {
              'Content-Type': 'application/json',
              if (idToken != null) 'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const AuthApiException('Không kết nối được máy chủ đăng nhập. Kiểm tra mạng và thử lại.');
    }
  }

  /// API chưa sẵn sàng: 404 của Vercel (chưa deploy), lỗi máy chủ, hoặc không
  /// phải JSON của API.
  static bool _apiNotReady(http.Response res) {
    if (res.statusCode == 404 || res.statusCode >= 500) return true;
    try {
      jsonDecode(res.body);
      return false;
    } catch (_) {
      return true;
    }
  }

  // ── TẠM THỜI: đăng nhập / duyệt kiểu CŨ khi API chưa chạy được ──────────────
  // Chỉ hoạt động khi Firestore rules còn mở. Tắt bằng kLegacyAuthFallback = false
  // (lib/core/config.dart) trước khi bật rules mới.
  Future<AccountModel?> _legacyLogin(String username, String password) async {
    debugPrint('[AuthService] API không phản hồi → đăng nhập dự phòng');
    final hash = hashPassword(password);
    final snap = await _db
        .collection('accounts')
        .where('username', isEqualTo: username.trim().toLowerCase())
        .where('active', isEqualTo: true)
        .limit(1)
        .get();
    if (snap.docs.isEmpty) return null;
    final account = AccountModel.fromDoc(snap.docs.first);
    return account.passwordHash == hash ? account : null;
  }

  Future<AccountModel?> _legacyVerifyManager(String password) async {
    final hash = hashPassword(password);
    final snap = await _db.collection('accounts').where('role', isEqualTo: 'admin').get();
    for (final d in snap.docs) {
      final acc = AccountModel.fromDoc(d);
      if (acc.active && acc.passwordHash == hash) return acc;
    }
    return null;
  }

  static Map<String, dynamic> _decode(http.Response res) {
    try {
      return jsonDecode(res.body) as Map<String, dynamic>;
    } catch (_) {
      return const {};
    }
  }

  static String _errorOf(Map<String, dynamic> data) =>
      (data['error'] as String?) ?? 'Lỗi máy chủ, vui lòng thử lại';

  Future<void> createAccount({
    required String username,
    required String password,
    required String fullName,
    required String role,
  }) async {
    // Không phân biệt hoa/thường ('Admin' trùng 'admin') — chặn 2 tài khoản
    // trùng tên (API đăng nhập sẽ không biết chọn tài khoản nào).
    final uname = username.trim().toLowerCase();
    if (uname.isEmpty) throw const AuthApiException('Vui lòng nhập tên đăng nhập');
    if (RegExp(r'\s').hasMatch(uname)) {
      throw const AuthApiException('Tên đăng nhập không được chứa khoảng trắng');
    }
    final all = await _db.collection('accounts').get();
    final exists = all.docs.any(
        (d) => (d.data()['username'] ?? '').toString().trim().toLowerCase() == uname);
    if (exists) throw const AuthApiException('Tên đăng nhập đã tồn tại');

    final hash = hashPassword(password);
    await _db.collection('accounts').add({
      'username': uname,
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

/// Lỗi từ API đăng nhập (bị khóa tạm, mất mạng, lỗi máy chủ...) — [message]
/// đã là câu tiếng Việt hiển thị được cho người dùng.
class AuthApiException implements Exception {
  final String message;
  const AuthApiException(this.message);

  @override
  String toString() => message;
}
