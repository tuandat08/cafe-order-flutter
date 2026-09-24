import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
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
    final res = await _post('/api/login', {
      'username': username.trim(),
      'password': password,
    });
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
    final res = await _post('/api/verify-manager', {'password': password}, idToken: idToken);
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
