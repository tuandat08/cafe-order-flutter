import 'package:flutter/material.dart';
import 'package:audioplayers/audioplayers.dart';

import '../../core/theme/app_theme.dart';
import '../../services/azure_tts_service.dart';
import '../../services/free_tts_service.dart';

/// Cấu hình giọng đọc AI cho thông báo "gọi phục vụ".
/// Mặc định dùng giọng AI MIỄN PHÍ, không cần đăng ký tài khoản hay thẻ thanh
/// toán gì cả — bật sẵn, dùng ngay. Mục Azure bên dưới chỉ dành cho ai muốn
/// nâng cấp lên giọng chất lượng cao hơn, hoàn toàn không bắt buộc.
class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({super.key});

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  bool _freeEnabled = true;

  final _keyCtrl = TextEditingController();
  final _regionCtrl = TextEditingController(text: 'southeastasia');
  String _voice = 'vi-VN-HoaiMyNeural';
  bool _showAdvanced = false;

  bool _busy = false;
  String? _status;
  bool _statusIsError = false;

  final _testPlayer = AudioPlayer();

  static const _voices = [
    {'id': 'vi-VN-HoaiMyNeural', 'label': 'HoaiMy (nữ)'},
    {'id': 'vi-VN-NamMinhNeural', 'label': 'NamMinh (nam)'},
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await FreeTtsService.instance.load();
    await AzureTtsService.instance.load();
    final a = AzureTtsService.instance;
    setState(() {
      _freeEnabled = FreeTtsService.instance.enabled;
      _keyCtrl.text = a.apiKey;
      _regionCtrl.text = a.region;
      _voice = a.voice;
      _showAdvanced = a.isConfigured; // đã có key trước đó thì mở sẵn mục nâng cao
    });
  }

  @override
  void dispose() {
    _keyCtrl.dispose();
    _regionCtrl.dispose();
    _testPlayer.dispose();
    super.dispose();
  }

  Future<void> _toggleFree(bool v) async {
    await FreeTtsService.instance.setEnabled(v);
    if (mounted) setState(() => _freeEnabled = v);
  }

  Future<void> _testFree() async {
    setState(() { _busy = true; _status = null; });
    final wasEnabled = FreeTtsService.instance.enabled;
    if (!wasEnabled) await FreeTtsService.instance.setEnabled(true); // bật tạm để nghe thử
    final ok = await FreeTtsService.instance.speak(
      'Bàn ba đang gọi nhân viên!',
      onPlayFile: (path) async {
        try { await _testPlayer.play(DeviceFileSource(path)); } catch (_) {}
      },
    );
    if (!wasEnabled) await FreeTtsService.instance.setEnabled(false); // trả lại trạng thái cũ
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusIsError = !ok;
      _status = ok
          ? 'Đã phát thử bằng giọng AI miễn phí.'
          : 'Không gọi được (có thể do mất mạng hoặc bị giới hạn tạm thời) — app sẽ tự dùng giọng máy khi cần.';
    });
  }

  Future<void> _saveAzure() async {
    await AzureTtsService.instance.save(
      apiKey: _keyCtrl.text,
      region: _regionCtrl.text,
      voice: _voice,
    );
    if (!mounted) return;
    setState(() {
      _status = AzureTtsService.instance.isConfigured
          ? 'Đã lưu Azure — sẽ được ưu tiên dùng nếu giọng miễn phí gặp sự cố.'
          : 'Đã xoá cấu hình Azure.';
      _statusIsError = false;
    });
  }

  Future<void> _testAzure() async {
    setState(() { _busy = true; _status = null; });
    await AzureTtsService.instance.save(
      apiKey: _keyCtrl.text,
      region: _regionCtrl.text,
      voice: _voice,
    );
    final ok = await AzureTtsService.instance.speak(
      'Bàn ba đang gọi nhân viên!',
      onPlayFile: (path) async {
        try { await _testPlayer.play(DeviceFileSource(path)); } catch (_) {}
      },
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusIsError = !ok;
      _status = ok
          ? 'Đã phát thử bằng giọng AI Azure.'
          : 'Không gọi được Azure (kiểm tra Key/Region hoặc mạng).';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Giọng đọc AI'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Đóng',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Giọng đọc AI cho câu thông báo "gọi phục vụ" — nghe tự nhiên hơn giọng máy mặc định.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                // ── Giọng miễn phí — mặc định, không cần đăng ký gì ──
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(children: [
                          Expanded(child: Text('Giọng AI miễn phí (khuyên dùng)',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                          Switch(value: _freeEnabled, onChanged: _toggleFree),
                        ]),
                        const SizedBox(height: 4),
                        const Text(
                          'Dùng ngay, không cần đăng ký tài khoản, không cần thẻ thanh toán, '
                          'không cần dán Key gì cả. Nếu có sự cố mạng, app tự chuyển sang giọng máy.',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 40,
                          child: OutlinedButton.icon(
                            onPressed: _busy ? null : _testFree,
                            icon: _busy
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                : const Icon(Icons.volume_up, size: 18),
                            label: const Text('Nghe thử'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(_status!, style: TextStyle(
                    color: _statusIsError ? AppColors.error : const Color(0xFF059669),
                    fontWeight: FontWeight.w600,
                  )),
                ],
                const SizedBox(height: 16),
                // ── Nâng cao (tuỳ chọn) — Azure, cần tự đăng ký lấy Key ──
                InkWell(
                  onTap: () => setState(() => _showAdvanced = !_showAdvanced),
                  child: Row(children: [
                    Icon(_showAdvanced ? Icons.expand_less : Icons.expand_more, size: 18, color: AppColors.textSecondary),
                    const SizedBox(width: 4),
                    const Text('Nâng cao: dùng Azure (không bắt buộc)',
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                  ]),
                ),
                if (_showAdvanced) ...[
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'Chỉ cần nếu bạn muốn giọng chất lượng cao hơn nữa và không ngại tự '
                            'đăng ký tài khoản Azure (Microsoft) lấy Key miễn phí riêng.',
                            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _keyCtrl,
                            obscureText: true,
                            decoration: const InputDecoration(labelText: 'Azure Subscription Key', hintText: 'Dán key vào đây'),
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _regionCtrl,
                            decoration: const InputDecoration(labelText: 'Region', hintText: 'VD: southeastasia'),
                          ),
                          const SizedBox(height: 12),
                          DropdownButtonFormField<String>(
                            initialValue: _voice,
                            decoration: const InputDecoration(labelText: 'Giọng đọc'),
                            items: _voices
                                .map((v) => DropdownMenuItem(value: v['id'], child: Text(v['label']!)))
                                .toList(),
                            onChanged: (v) => setState(() => _voice = v ?? _voice),
                          ),
                          const SizedBox(height: 16),
                          Row(children: [
                            Expanded(
                              child: SizedBox(
                                height: 44,
                                child: OutlinedButton(onPressed: _saveAzure, child: const Text('Lưu')),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: SizedBox(
                                height: 44,
                                child: ElevatedButton.icon(
                                  onPressed: _busy ? null : _testAzure,
                                  icon: _busy
                                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : const Icon(Icons.volume_up),
                                  label: const Text('Nghe thử'),
                                ),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                const Text(
                  'Thứ tự dùng: giọng miễn phí trước → Azure nếu đã cấu hình → giọng máy nếu cả hai lỗi.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
