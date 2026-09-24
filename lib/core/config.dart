/// Địa chỉ API đăng nhập (repo api-cafe-management, deploy trên Vercel).
/// Đổi khi build: flutter build apk --dart-define=AUTH_API_URL=https://...
const String kAuthApiUrl = String.fromEnvironment(
  'AUTH_API_URL',
  defaultValue: 'https://api-cafe-management.vercel.app',
);
