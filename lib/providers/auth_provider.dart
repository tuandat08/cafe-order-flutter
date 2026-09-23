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
    } catch (e, st) {
      // ignore: avoid_print
      print('[AuthProvider] login exception: $e');
      // ignore: avoid_print
      print(st);
      _error = 'Lỗi kết nối. Vui lòng thử lại.';
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  void logout() {
    _currentUser = null;
    _error = null;
    notifyListeners();
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
