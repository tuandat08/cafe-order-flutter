import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/account_model.dart';
import '../services/auth_service.dart';

class AuthProvider extends ChangeNotifier {
  final _authService = AuthService();

  AccountModel? _currentUser;
  bool _isLoading = false;
  String? _error;

  AccountModel? get currentUser => _currentUser;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isLoggedIn => _currentUser != null;
  bool get isAdmin => _currentUser?.role == 'admin';

  Future<bool> login(String username, String password) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final user = await _authService.login(username, password);
      if (user != null) {
        _currentUser = user;
        _isLoading = false;
        notifyListeners();
        return true;
      } else {
        _error = 'Tên đăng nhập hoặc mật khẩu không đúng';
        _isLoading = false;
        notifyListeners();
        return false;
      }
    } on AuthApiException catch (e) {
      _error = e.message;
      _isLoading = false;
      notifyListeners();
      return false;
    } on FirebaseAuthException catch (e) {
      // Mật khẩu đúng (API đã cấp token) nhưng đăng nhập Firebase Auth trên máy
      // thất bại — hiện mã lỗi để biết nguyên nhân (vd: keychain-error trên macOS).
      debugPrint('[AuthProvider] FirebaseAuth error: ${e.code} ${e.message}');
      _error = 'Lỗi đăng nhập Firebase (${e.code}). ${e.message ?? ''}'.trim();
      _isLoading = false;
      notifyListeners();
      return false;
    } catch (e) {
      debugPrint('[AuthProvider] login exception: $e');
      _error = 'Lỗi đăng nhập: $e';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void logout() {
    // Thoát phiên Firebase Auth (không chờ) — Security Rules dựa vào phiên này.
    _authService.signOut().catchError((_) {});
    _currentUser = null;
    _error = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
