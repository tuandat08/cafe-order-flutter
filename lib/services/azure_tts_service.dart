import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// Giọng đọc AI tự nhiên qua Azure AI Speech (Microsoft) — dùng giọng Neural
/// tiếng Việt (mặc định: vi-VN-HoaiMyNeural), nghe tự nhiên hơn hẳn giọng máy
/// iOS mặc định. Gói miễn phí (F0) của Azure: 500.000 ký tự/tháng, lặp lại
/// hàng tháng — với các câu thông báo ngắn trong app thì dùng thoải mái.
///
/// Nếu chưa cấu hình Subscription Key, hoặc gọi API lỗi/mất mạng, hàm speak()
/// trả về false để nơi gọi tự chuyển sang giọng máy (flutter_tts) — không bao
/// giờ bị câm hoàn toàn.
class AzureTtsService {
  AzureTtsService._();
  static final AzureTtsService instance = AzureTtsService._();

  static const _keyKey = 'azure_tts_key';
  static const _regionKey = 'azure_tts_region';
  static const _voiceKey = 'azure_tts_voice';

  String apiKey = '';
  String region = 'southeastasia'; // vùng Azure gần Việt Nam nhất
  String voice = 'vi-VN-HoaiMyNeural';

  bool get isConfigured => apiKey.trim().isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    apiKey = prefs.getString(_keyKey) ?? '';
    region = prefs.getString(_regionKey) ?? 'southeastasia';
    voice = prefs.getString(_voiceKey) ?? 'vi-VN-HoaiMyNeural';
  }

  Future<void> save({required String apiKey, required String region, required String voice}) async {
    this.apiKey = apiKey.trim();
    this.region = region.trim().isEmpty ? 'southeastasia' : region.trim();
    this.voice = voice.trim().isEmpty ? 'vi-VN-HoaiMyNeural' : voice.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyKey, this.apiKey);
    await prefs.setString(_regionKey, this.region);
    await prefs.setString(_voiceKey, this.voice);
  }

  /// Gọi Azure Speech để tổng hợp giọng đọc cho [text], lưu ra file mp3 tạm
  /// rồi gọi [onPlayFile] với đường dẫn file đó để phát. Trả về true nếu
  /// thành công, false nếu cần fallback sang giọng máy.
  Future<bool> speak(String text, {required Future<void> Function(String filePath) onPlayFile}) async {
    if (!isConfigured) return false;
    HttpClient? client;
    try {
      client = HttpClient();
      final uri = Uri.parse('https://$region.tts.speech.microsoft.com/cognitiveservices/v1');
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 6));
      req.headers.set('Ocp-Apim-Subscription-Key', apiKey);
      req.headers.set('Content-Type', 'application/ssml+xml');
      req.headers.set('X-Microsoft-OutputFormat', 'audio-16khz-128kbitrate-mono-mp3');
      req.headers.set('User-Agent', 'cafe-order-flutter');
      final escaped = text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;');
      final ssml = '<speak version="1.0" xml:lang="vi-VN">'
          '<voice name="$voice">$escaped</voice></speak>';
      req.write(ssml);
      final res = await req.close().timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) {
        await res.drain<List<int>>();
        return false;
      }
      final bytes = await res.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
      if (bytes.isEmpty) return false;
      final tmp = File('${Directory.systemTemp.path}/azure_tts_${DateTime.now().millisecondsSinceEpoch}.mp3');
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
