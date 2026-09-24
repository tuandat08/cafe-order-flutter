import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Dải báo trên cùng màn hình khi app MẤT KẾT NỐI tới máy chủ Firestore.
///
/// Không cần thư viện kiểm tra mạng riêng: lắng nghe 1 truy vấn nhỏ với
/// `includeMetadataChanges` — khi Firestore mất kết nối tới server, snapshot
/// được đánh dấu `isFromCache = true`; có lại kết nối → `false`. Nhờ vậy báo
/// đúng việc "dữ liệu có đang đồng bộ với server hay không" (Wi-Fi vẫn bắt
/// nhưng mất Internet cũng được phát hiện).
///
/// Khi offline, các thao tác vẫn được lưu trên máy và tự gửi lên khi có mạng lại.
class OfflineBanner extends StatefulWidget {
  final Widget child;
  const OfflineBanner({super.key, required this.child});

  @override
  State<OfflineBanner> createState() => _OfflineBannerState();
}

enum _ConnState { online, offline, reconnected }

class _OfflineBannerState extends State<OfflineBanner> {
  StreamSubscription? _sub;
  Timer? _offlineDelay;
  Timer? _hideReconnected;
  _ConnState _state = _ConnState.online;

  @override
  void initState() {
    super.initState();
    // `settings` ai cũng được đọc (kể cả trước khi đăng nhập) — xem firestore.rules.
    _sub = FirebaseFirestore.instance
        .collection('settings')
        .limit(1)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snap) => _onConnection(!snap.metadata.isFromCache),
          onError: (_) {},
        );
  }

  void _onConnection(bool online) {
    if (online) {
      _offlineDelay?.cancel();
      _offlineDelay = null;
      if (_state == _ConnState.offline) {
        setState(() => _state = _ConnState.reconnected);
        _hideReconnected?.cancel();
        _hideReconnected = Timer(const Duration(seconds: 3), () {
          if (mounted) setState(() => _state = _ConnState.online);
        });
      }
    } else if (_state != _ConnState.offline && _offlineDelay == null) {
      // Chờ vài giây mới báo — tránh chớp báo lúc app vừa mở (lần đầu đọc từ
      // bộ nhớ máy trước khi kịp kết nối server) hoặc mạng chập chờn rất ngắn.
      _offlineDelay = Timer(const Duration(seconds: 4), () {
        _offlineDelay = null;
        if (mounted) setState(() => _state = _ConnState.offline);
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _offlineDelay?.cancel();
    _hideReconnected?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_state == _ConnState.online) return widget.child;
    final offline = _state == _ConnState.offline;
    return Column(
      children: [
        Material(
          color: offline ? const Color(0xFFDC2626) : const Color(0xFF059669),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: [
                  Icon(offline ? Icons.cloud_off_rounded : Icons.cloud_done_rounded,
                      size: 16, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      offline
                          ? 'Mất kết nối — thao tác vẫn được lưu trên máy và sẽ tự đồng bộ khi có mạng. '
                              'Máy khác chưa thấy thay đổi của bạn.'
                          : 'Đã kết nối lại — dữ liệu đã đồng bộ.',
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Dải báo đã chiếm phần tai thỏ/thanh trạng thái → bỏ padding trên của
        // nội dung bên dưới để không bị thụt 2 lần.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: widget.child,
          ),
        ),
      ],
    );
  }
}
