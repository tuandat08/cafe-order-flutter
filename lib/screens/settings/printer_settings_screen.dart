import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';

import '../../core/theme/app_theme.dart';
import '../../services/printer_service.dart';
import '../../services/receipt_image_builder.dart';

/// Màn hình cấu hình máy in nhiệt (ESC/POS) cho hóa đơn: chọn kết nối qua
/// mạng LAN/Wi-Fi (nhập IP máy in) hoặc Bluetooth (quét & chọn máy in), rồi
/// in thử để kiểm tra. Cấu hình được lưu lại trên máy, dùng chung cho toàn
/// bộ chức năng in hóa đơn trong app (POS, Bàn, KDS).
class PrinterSettingsScreen extends StatefulWidget {
  const PrinterSettingsScreen({super.key});

  @override
  State<PrinterSettingsScreen> createState() => _PrinterSettingsScreenState();
}

class _PrinterSettingsScreenState extends State<PrinterSettingsScreen> {
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
    super.dispose();
  }

  Future<void> _load() async {
    await PrinterService.instance.load();
    final s = PrinterService.instance;
    setState(() {
      _connType = s.connType;
      _ipCtrl.text = s.ip;
      _portCtrl.text = s.port.toString();
      if (s.btAddress.isNotEmpty) {
        _selectedBtDevice = PrinterDevice(name: s.btName, address: s.btAddress);
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
    await PrinterService.instance.saveNetwork(ip: ip, port: port);
    _setStatus('Đã lưu cấu hình máy in mạng LAN ($ip:$port)');
  }

  Future<void> _startBluetoothScan() async {
    setState(() {
      _scanning = true;
      _btDevices = [];
    });
    _scanSub?.cancel();
    _scanSub = PrinterService.instance.scanBluetoothDevices().listen(
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
    await PrinterService.instance.saveBluetooth(address: d.address ?? '', name: d.name ?? '');
    _setStatus('Đã chọn máy in Bluetooth: ${d.name ?? d.address}');
  }

  Future<void> _testPrint() async {
    setState(() => _busy = true);
    _setStatus('Đang gửi bản in thử…');
    try {
      if (_connType == PrinterConnType.network) {
        await _saveNetwork();
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
      await PrinterService.instance.sendBytes(bytes);
      _setStatus('Đã gửi bản in thử thành công!');
    } catch (e) {
      _setStatus('In thử thất bại: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
                  'Chọn cách kết nối máy in nhiệt (ESC/POS, khổ 80mm) dùng để in hóa đơn.',
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
                const SizedBox(height: 20),
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _busy ? null : _testPrint,
                    icon: _busy
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.print),
                    label: const Text('In thử'),
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
                  'Nếu chưa cấu hình máy in ở đây, app sẽ tự động in hóa đơn qua hộp thoại in hệ thống (AirPrint) như trước.',
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
