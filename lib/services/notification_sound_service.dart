import 'package:shared_preferences/shared_preferences.dart';

/// Bật/tắt âm thanh thông báo (chuông "ting" khi có đơn mới, gọi phục vụ,
/// hoặc đơn bị trễ). Trạng thái được lưu lại trên máy (SharedPreferences)
/// để giữ nguyên giữa các lần mở app — bấm ở icon chuông trên thanh top bar.
class NotificationSoundService {
  NotificationSoundService._();
  static final NotificationSoundService instance = NotificationSoundService._();

  static const _key = 'notif_sound_enabled';
  bool _enabled = true;
  bool get enabled => _enabled;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _enabled = prefs.getBool(_key) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    _enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_key, value);
  }
}
