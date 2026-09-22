import 'dart:async';
import 'dart:io';

import 'package:flutter_pos_printer_platform_image_3/flutter_pos_printer_platform_image_3.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PrinterConnType { network, bluetooth }

/// Quản lý cấu hình + gửi lệnh in ESC/POS tới máy in nhiệt, hỗ trợ 2 kiểu
/// kết nối: mạng LAN/Wi-Fi (khuyên dùng, in qua socket TCP cổng 9100) hoặc
/// Bluetooth. Cấu hình được lưu lại trên máy (SharedPreferences) nên chỉ cần
/// cài đặt 1 lần cho mỗi iPad/quầy.
class PrinterService {
  PrinterService._();
  static final PrinterService instance = PrinterService._();

  static const _kConnType = 'printer_conn_type';
  static const _kIp = 'printer_ip';
  static const _kPort = 'printer_port';
  static const _kBtAddress = 'printer_bt_address';
  static const _kBtName = 'printer_bt_name';

  PrinterConnType connType = PrinterConnType.network;
  String ip = '';
  int port = 9100;
  String btAddress = '';
  String btName = '';

  bool _loaded = false;

  bool get isConfigured => connType == PrinterConnType.network
      ? ip.isNotEmpty
      : btAddress.isNotEmpty;

  Future<void> load() async {
    if (_loaded) return;
    final sp = await SharedPreferences.getInstance();
    connType = sp.getString(_kConnType) == 'bluetooth'
        ? PrinterConnType.bluetooth
        : PrinterConnType.network;
    ip = sp.getString(_kIp) ?? '';
    port = sp.getInt(_kPort) ?? 9100;
    btAddress = sp.getString(_kBtAddress) ?? '';
    btName = sp.getString(_kBtName) ?? '';
    _loaded = true;
  }

  Future<void> reload() async {
    _loaded = false;
    await load();
  }

  Future<void> saveNetwork({required String ip, int port = 9100}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kConnType, 'network');
    await sp.setString(_kIp, ip);
    await sp.setInt(_kPort, port);
    this.connType = PrinterConnType.network;
    this.ip = ip;
    this.port = port;
    _loaded = true;
  }

  Future<void> saveBluetooth({required String address, required String name}) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kConnType, 'bluetooth');
    await sp.setString(_kBtAddress, address);
    await sp.setString(_kBtName, name);
    this.connType = PrinterConnType.bluetooth;
    this.btAddress = address;
    this.btName = name;
    _loaded = true;
  }

  Future<void> clear() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_kConnType);
    await sp.remove(_kIp);
    await sp.remove(_kPort);
    await sp.remove(_kBtAddress);
    await sp.remove(_kBtName);
    connType = PrinterConnType.network;
    ip = '';
    port = 9100;
    btAddress = '';
    btName = '';
  }

  /// Quét các máy in Bluetooth xung quanh. Đây là 1 Stream "lazy" — máy chỉ
  /// thực sự bắt đầu quét khi có nơi lắng nghe (listen) stream này; mỗi máy in
  /// tìm thấy sẽ được phát ra 1 lần (tự dừng sau ~7s hoặc khi hết pin quét).
  Stream<PrinterDevice> scanBluetoothDevices() {
    return PrinterManager.instance.discovery(type: PrinterType.bluetooth, isBle: false);
  }

  /// Gửi mảng byte lệnh ESC/POS đã dựng sẵn (xem [ReceiptImageBuilder]) tới
  /// máy in đang được cấu hình.
  Future<void> sendBytes(List<int> bytes) async {
    await load();
    if (connType == PrinterConnType.network) {
      await _sendViaNetwork(bytes);
    } else {
      await _sendViaBluetooth(bytes);
    }
  }

  Future<void> _sendViaNetwork(List<int> bytes) async {
    if (ip.isEmpty) {
      throw Exception('Chưa cấu hình địa chỉ IP máy in. Vào Cài đặt máy in để cấu hình.');
    }
    final socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
    try {
      socket.add(bytes);
      await socket.flush();
    } finally {
      await socket.close();
    }
  }

  Future<void> _sendViaBluetooth(List<int> bytes) async {
    if (btAddress.isEmpty) {
      throw Exception('Chưa chọn máy in Bluetooth. Vào Cài đặt máy in để chọn.');
    }
    final manager = PrinterManager.instance;
    await manager.connect(
      type: PrinterType.bluetooth,
      model: BluetoothPrinterInput(
        name: btName,
        address: btAddress,
        isBle: false,
        autoConnect: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // Lưu ý: phải gửi List<int> thường (không phải Uint8List) — code native
    // của plugin đọc 'bytes' như NSArray số nguyên (NSNumber), còn Uint8List sẽ
    // bị mã hoá thành FlutterStandardTypedData/NSData làm crash bên iOS.
    manager.send(type: PrinterType.bluetooth, bytes: List<int>.from(bytes));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    try {
      await manager.disconnect(type: PrinterType.bluetooth);
    } catch (_) {
      // bỏ qua lỗi ngắt kết nối, không ảnh hưởng việc in
    }
  }

  /// Kiểm tra kết nối bằng cách gửi 1 dòng test in ngắn (chỉ dùng cho LAN;
  /// đơn giản, không phụ thuộc esc_pos_utils_plus để tránh vòng phụ thuộc
  /// ngược trong service này).
  Future<void> testNetworkConnection(String testIp, int testPort) async {
    final socket = await Socket.connect(testIp, testPort, timeout: const Duration(seconds: 5));
    await socket.close();
  }
}
