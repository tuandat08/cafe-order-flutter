import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';

import '../../core/theme/app_theme.dart';
import '../../services/label_image_builder.dart';
import '../../services/label_print_service.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_image_builder.dart';

/// Màn hình cấu hình máy in, gồm 2 tab:
/// - Máy in hóa đơn (ESC/POS, khổ 80mm) — dùng cho in hóa đơn (POS, Bàn, KDS).
/// - Máy in tem (Xprinter XP-365B… lệnh TSPL, tem 40×30mm) — in tem dán ly cho
///   đơn Grab / ShopeeFood.
/// Mỗi máy in chọn kết nối mạng LAN/Wi-Fi (nhập IP) hoặc Bluetooth (quét & chọn),
/// rồi in thử để kiểm tra. Cấu hình được lưu lại trên máy.
class PrinterSettingsScreen extends StatelessWidget {
  const PrinterSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: const Text('Cài đặt máy in'),
          // Panel này trượt ra/vào từ bên phải (không phải điều hướng "quay lại"),
          // nên dùng icon đóng (X) thay vì mũi tên back cho đúng ngữ nghĩa.
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Đóng',
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: const TabBar(
              // Chữ + icon tab màu trắng cho dễ đọc trên nền AppBar
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white,
              indicatorColor: Colors.white,
              tabs: [
            Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Máy in hóa đơn'),
            Tab(icon: Icon(Icons.local_offer_outlined), text: 'Máy in tem ly'),
          ]),
        ),
        body: const TabBarView(children: [
          _PrinterConfigPanel(isLabel: false),
          _PrinterConfigPanel(isLabel: true),
        ]),
      ),
    );
  }
}

class _PrinterConfigPanel extends StatefulWidget {
  final bool isLabel;
  const _PrinterConfigPanel({required this.isLabel});

  @override
  State<_PrinterConfigPanel> createState() => _PrinterConfigPanelState();
}

class _PrinterConfigPanelState extends State<_PrinterConfigPanel>
    with AutomaticKeepAliveClientMixin {
  final _ipCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '9100');
  PrinterConnType _connType = PrinterConnType.network;

  bool _scanning = false;
  bool _busy = false;
  String? _status;
  bool _statusIsError = false;
  List<PrinterDevice> _btDevices = [];
  PrinterDevice? _selectedBtDevice;
  StreamSubscription<PrinterDevice>? _scanSub;

  // ── Riêng máy in tem ──
  final _shopCtrl = TextEditingController();
  final _gapCtrl = TextEditingController(text: '2');
  LabelProtocol _protocol = LabelProtocol.tspl;
  int _wMm = 40;
  int _hMm = 30;
  bool _rotate = false;
  Future<Uint8List>? _preview;

  PrinterService get _svc => widget.isLabel ? PrinterService.label : PrinterService.instance;
  LabelPrintService get _label => LabelPrintService.instance;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _shopCtrl.dispose();
    _gapCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _svc.load();
    if (widget.isLabel) await _label.load();
    if (!mounted) return;
    final s = _svc;
    setState(() {
      _connType = s.connType;
      _ipCtrl.text = s.ip;
      _portCtrl.text = s.port.toString();
      if (s.btAddress.isNotEmpty) {
        _selectedBtDevice = PrinterDevice(name: s.btName, address: s.btAddress);
      }
      if (widget.isLabel) {
        _protocol = _label.protocol;
        _wMm = _label.widthMm;
        _hMm = _label.heightMm;
        _gapCtrl.text = _label.gapMm.toString();
        _shopCtrl.text = _label.shopName;
        _rotate = _label.rotate180;
        _refreshPreview();
      }
    });
  }

  void _setStatus(String msg, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusIsError = isError;
    });
  }

  Future<void> _saveNetwork() async {
    final ip = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 9100;
    if (ip.isEmpty) {
      _setStatus('Vui lòng nhập địa chỉ IP máy in', isError: true);
      return;
    }
    await _svc.saveNetwork(ip: ip, port: port);
    _setStatus('Đã lưu cấu hình máy in mạng LAN ($ip:$port)');
  }

  Future<void> _startBluetoothScan() async {
    setState(() {
      _scanning = true;
      _btDevices = [];
    });
    _scanSub?.cancel();
    _scanSub = _svc.scanBluetoothDevices().listen(
      (device) {
        if (!mounted) return;
        setState(() {
          if (!_btDevices.any((d) => d.address == device.address)) {
            _btDevices = [..._btDevices, device];
          }
        });
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
      onError: (Object _) {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _selectBluetoothDevice(PrinterDevice d) async {
    setState(() => _selectedBtDevice = d);
    await _svc.saveBluetooth(address: d.address ?? '', name: d.name ?? '');
    _setStatus('Đã chọn máy in Bluetooth: ${d.name ?? d.address}');
  }

  // ── Máy in tem: lưu cấu hình tem + làm mới ảnh xem trước ──
  Future<void> _saveLabelSettings() async {
    await _label.save(
      protocol: _protocol,
      widthMm: _wMm,
      heightMm: _hMm,
      gapMm: int.tryParse(_gapCtrl.text.trim()) ?? 2,
      shopName: _shopCtrl.text.trim(),
      rotate180: _rotate,
    );
    if (mounted) setState(_refreshPreview);
  }

  void _refreshPreview() {
    _preview = LabelImageBuilder.renderPng(_label.sample(), widthMm: _wMm, heightMm: _hMm);
  }

  Future<void> _testPrint() async {
    setState(() => _busy = true);
    _setStatus('Đang gửi bản in thử…');
    try {
      if (_connType == PrinterConnType.network) {
        await _saveNetwork();
      }
      if (widget.isLabel) {
        await _saveLabelSettings();
        await _label.printSample();
        _setStatus('Đã gửi tem in thử thành công!');
        return;
      }
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final lines = <ReceiptLine>[
        const ReceiptLine('EM COFFEE', bold: true, fontSize: 34, align: ReceiptAlign.center),
        const ReceiptLine('IN THỬ MÁY IN', fontSize: 22, align: ReceiptAlign.center),
        ReceiptLine(
          'Thời gian: ${two(now.day)}/${two(now.month)}/${now.year} ${two(now.hour)}:${two(now.minute)}',
          fontSize: 20,
        ),
        const ReceiptLine('--------------------------------', fontSize: 18, align: ReceiptAlign.center),
        const ReceiptLine('Nếu bạn đọc được dòng này bằng', fontSize: 20, align: ReceiptAlign.center),
        const ReceiptLine('tiếng Việt có dấu thì máy in đã', fontSize: 20, align: ReceiptAlign.center),
        const ReceiptLine('kết nối và hoạt động tốt!', fontSize: 20, align: ReceiptAlign.center),
      ];
      final bytes = await ReceiptImageBuilder.buildEscPosBytes(lines: lines);
      await _svc.sendBytes(bytes);
      _setStatus('Đã gửi bản in thử thành công!');
    } catch (e) {
      _setStatus('In thử thất bại: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _labelSettingsCard(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Loại máy & khổ tem', style: t.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SegmentedButton<LabelProtocol>(
            segments: const [
              ButtonSegment(value: LabelProtocol.tspl, label: Text('Máy in tem (TSPL)')),
              ButtonSegment(value: LabelProtocol.escpos, label: Text('Máy in bill + decal')),
            ],
            selected: {_protocol},
            onSelectionChanged: (s) {
              _protocol = s.first;
              _saveLabelSettings();
            },
          ),
          const SizedBox(height: 6),
          Text(
            _protocol == LabelProtocol.tspl
                ? 'Xprinter XP-365B / XP-420B / XP-236B, TSC… dùng giấy tem bế sẵn có khe hở.'
                : 'Máy in hóa đơn ESC/POS lắp cuộn decal nhiệt liên tục — mỗi tem in xong cắt 1 lần.',
            style: t.bodySmall?.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Text('Khổ tem (rộng × cao)', style: t.labelLarge),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final p in LabelPrintService.presets)
              ChoiceChip(
                label: Text('${p[0]}×${p[1]} mm${p[0] == 40 && p[1] == 30 ? ' (phổ biến)' : ''}'),
                selected: _wMm == p[0] && _hMm == p[1],
                // Màu rõ ràng: đang chọn = nền nâu chữ trắng; chưa chọn = nền trắng chữ đậm có viền
                showCheckmark: true,
                checkmarkColor: Colors.white,
                selectedColor: AppColors.primary,
                backgroundColor: Colors.white,
                side: BorderSide(
                  color: _wMm == p[0] && _hMm == p[1] ? AppColors.primary : const Color(0xFFCBD5E1),
                  width: 1.2,
                ),
                labelStyle: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _wMm == p[0] && _hMm == p[1] ? Colors.white : AppColors.textPrimary,
                ),
                onSelected: (_) {
                  _wMm = p[0];
                  _hMm = p[1];
                  _saveLabelSettings();
                },
              ),
          ]),
          if (_protocol == LabelProtocol.tspl) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _gapCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Khe hở giữa 2 tem (mm, thường là 2)'),
              onChanged: (_) => _saveLabelSettings(),
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _shopCtrl,
            decoration: const InputDecoration(labelText: 'Tên quán in ở chân tem (có thể để trống)'),
            onChanged: (_) => _saveLabelSettings(),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Xoay tem 180°'),
            subtitle: const Text('Bật nếu tem in ra bị ngược chiều'),
            value: _rotate,
            onChanged: (v) {
              _rotate = v;
              _saveLabelSettings();
            },
          ),
          const SizedBox(height: 8),
          Text('Xem trước', style: t.labelLarge),
          const SizedBox(height: 8),
          Center(
            child: FutureBuilder<Uint8List>(
              future: _preview,
              builder: (_, snap) {
                if (!snap.hasData) {
                  return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
                }
                return Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: AppColors.divider),
                    borderRadius: BorderRadius.circular(8),
                    boxShadow: const [BoxShadow(color: Color(0x14000000), blurRadius: 6, offset: Offset(0, 2))],
                  ),
                  clipBehavior: Clip.antiAlias,
                  // Hiện to gấp ~1.25 kích thước dot để dễ nhìn trên iPad.
                  child: Image.memory(snap.data!, width: _wMm * 8 * 1.25, filterQuality: FilterQuality.medium),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  widget.isLabel
                      ? 'Máy in tem dán ly cho đơn Grab / ShopeeFood. Khuyên dùng Xprinter XP-365B bản LAN, tem 40×30mm.'
                      : 'Chọn cách kết nối máy in nhiệt (ESC/POS, khổ 80mm) dùng để in hóa đơn.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 16),
                SegmentedButton<PrinterConnType>(
                  segments: const [
                    ButtonSegment(value: PrinterConnType.network, label: Text('Wi-Fi / LAN'), icon: Icon(Icons.wifi)),
                    ButtonSegment(value: PrinterConnType.bluetooth, label: Text('Bluetooth'), icon: Icon(Icons.bluetooth)),
                  ],
                  selected: {_connType},
                  onSelectionChanged: (s) => setState(() => _connType = s.first),
                ),
                const SizedBox(height: 20),
                if (_connType == PrinterConnType.network) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Địa chỉ IP máy in',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            'Xem địa chỉ IP trên màn hình cấu hình mạng của máy in (in tờ test từ nút trên máy in), đảm bảo iPad và máy in cùng chung Wi-Fi.',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _ipCtrl,
                            decoration: const InputDecoration(labelText: 'IP máy in', hintText: 'VD: 192.168.1.50'),
                            keyboardType: TextInputType.number,
                          ),
                          const SizedBox(height: 12),
                          TextField(
                            controller: _portCtrl,
                            decoration: const InputDecoration(labelText: 'Cổng (mặc định 9100)'),
                            keyboardType: TextInputType.number,
                          ),
                          const SizedBox(height: 16),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(onPressed: _saveNetwork, child: const Text('Lưu cấu hình')),
                          ),
                        ],
                      ),
                    ),
                  ),
                ] else ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text('Máy in Bluetooth xung quanh',
                                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
                              ),
                              TextButton.icon(
                                onPressed: _scanning ? null : _startBluetoothScan,
                                icon: _scanning
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                                    : const Icon(Icons.refresh),
                                label: Text(_scanning ? 'Đang quét...' : 'Quét lại'),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (_btDevices.isEmpty && !_scanning)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Text('Bấm "Quét lại" để tìm máy in Bluetooth đã bật nguồn gần iPad.',
                                  style: TextStyle(color: AppColors.textSecondary)),
                            ),
                          ..._btDevices.map((d) => ListTile(
                                leading: Icon(
                                  _selectedBtDevice?.address == d.address ? Icons.check_circle : Icons.print,
                                  color: _selectedBtDevice?.address == d.address ? AppColors.primary : null,
                                ),
                                title: Text(d.name?.isNotEmpty == true ? d.name! : (d.address ?? 'Không tên')),
                                subtitle: Text(d.address ?? ''),
                                onTap: () => _selectBluetoothDevice(d),
                              )),
                        ],
                      ),
                    ),
                  ),
                ],
                if (widget.isLabel) ...[
                  const SizedBox(height: 16),
                  _labelSettingsCard(context),
                ],
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _testPrint,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.print),
                    label: Text(widget.isLabel ? 'In thử tem' : 'In thử'),
                  ),
                ),
                if (_status != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _status!,
                    style: TextStyle(color: _statusIsError ? AppColors.error : const Color(0xFF059669), fontWeight: FontWeight.w600),
                  ),
                ],
                const SizedBox(height: 24),
                Text(
                  widget.isLabel
                      ? 'Tem chỉ in khi bấm nút "In tem" trên đơn Grab / ShopeeFood đã pha xong. Mỗi ly 1 tem.'
                      : 'Nếu chưa cấu hình máy in ở đây, app sẽ tự động in hóa đơn qua hộp thoại in hệ thống (AirPrint) như trước.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
