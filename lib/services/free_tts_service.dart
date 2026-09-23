import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Giọng đọc AI MIỄN PHÍ, KHÔNG CẦN đăng ký tài khoản hay API key — dùng dịch
/// vụ đọc văn bản công khai của Google Dịch (client=tw-ob), là dịch vụ nhiều
/// ứng dụng nhỏ hay dùng cho các câu thông báo ngắn. Đơn giản hơn Azure rất
/// nhiều: không cần tạo tài khoản, không cần thẻ, không cần dán Key gì cả —
/// bật sẵn, dùng được ngay.
///
/// Lưu ý: đây là API không chính thức (không có cam kết uptime từ Google), có
/// giới hạn ~200 ký tự/câu và có thể bị chặn nếu gọi quá nhiều trong thời gian
/// ngắn. Vì vậy vẫn giữ nguyên cơ chế fallback: lỗi/mất mạng/bị chặn → app tự
/// động chuyển sang giọng máy (flutter_tts) như cũ, không bao giờ bị câm.
class FreeTtsService {
  FreeTtsService._();
  static final FreeTtsService instance = FreeTtsService._();

  static const _enabledKey = 'free_tts_enabled';
  bool enabled = true; // bật sẵn mặc định — không cần cấu hình gì

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    enabled = prefs.getBool(_enabledKey) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, value);
  }

  /// Trả về true nếu phát được, false nếu cần fallback sang giọng máy.
  Future<bool> speak(String text, {required Future<void> Function(String filePath) onPlayFile}) async {
    if (!enabled) return false;
    // API công khai giới hạn khoảng 200 ký tự/câu — cắt bớt cho an toàn.
    final safeText = text.length > 180 ? text.substring(0, 180) : text;
    HttpClient? client;
    try {
      client = HttpClient();
      final uri = Uri.https('translate.google.com', '/translate_tts', {
        'ie': 'UTF-8',
        'q': safeText,
        'tl': 'vi',
        'client': 'tw-ob',
      });
      final req = await client.getUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko)');
      req.headers.set('Referer', 'https://translate.google.com/');
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        await res.drain<List<int>>();
        return false;
      }
      final bytes = await res.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (bytes.isEmpty) return false;
      final tmp = File('${Directory.systemTemp.path}/free_tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
      await tmp.writeAsBytes(bytes, flush: true);
      await onPlayFile(tmp.path);
      return true;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }
}
