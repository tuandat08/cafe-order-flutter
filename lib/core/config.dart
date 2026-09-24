/// Địa chỉ API đăng nhập (repo api-cafe-management, deploy trên Vercel).
/// Đổi khi build: flutter build apk --dart-define=AUTH_API_URL=https://...
const String kAuthApiUrl = String.fromEnvironment(
  'AUTH_API_URL',
  defaultValue: 'https://api-cafe-management.vercel.app',
);

/// TẠM THỜI: khi API đăng nhập chưa chạy được (chưa deploy / cấu hình sai / mất
/// kết nối) thì đăng nhập kiểu cũ (đọc bảng accounts ngay trên máy) để quán không
/// bị gián đoạn. Chỉ dùng được khi Firestore rules còn mở — đặt về false trước
/// khi bật rules mới.
const bool kLegacyAuthFallback = true;
