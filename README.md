# Cafe Admin - Flutter App

Ứng dụng quản lý quán cà phê dành cho Admin, kết nối cùng Firebase với web app hiện tại.

## Tính năng
- 📊 **Dashboard** - Thống kê doanh thu hôm nay, đơn đang xử lý
- 📋 **Đơn hàng** - Xem và cập nhật trạng thái đơn theo thời gian thực
- 🍵 **Menu** - Thêm/sửa/xóa món, bật/tắt món
- 🪑 **Bàn** - Quản lý bàn và trạng thái
- 📈 **Báo cáo** - Doanh thu theo ngày/khoảng thời gian
- 🏷️ **Khuyến mãi** - Quản lý mã giảm giá
- 👥 **Tài khoản** - Quản lý nhân viên và phân quyền

## Cài đặt

### 1. Cài Flutter
```bash
# macOS (via Homebrew)
brew install --cask flutter

# Kiểm tra
flutter doctor
```

### 2. Cài dependencies
```bash
cd cafe_admin
flutter pub get
```

### 3. Cấu hình Firebase cho từng platform

#### Android
1. Vào [Firebase Console](https://console.firebase.google.com) → Project `order-fa2b5`
2. Thêm ứng dụng Android với package name: `com.yourcompany.cafe_admin`
3. Tải `google-services.json` → đặt vào `android/app/`

#### iOS / macOS
1. Thêm ứng dụng iOS với bundle ID: `com.yourcompany.cafeAdmin`
2. Tải `GoogleService-Info.plist` → đặt vào `ios/Runner/` (và `macos/Runner/`)
3. Cập nhật bundle ID trong `lib/firebase_options.dart`

> Sau khi thêm mỗi platform, cập nhật `appId` tương ứng trong `lib/firebase_options.dart`

### 4. Chạy app
```bash
# iOS Simulator
flutter run -d ios

# Android Emulator
flutter run -d android

# macOS
flutter run -d macos

# Xem danh sách thiết bị
flutter devices
```

## Cấu trúc project

```
lib/
├── main.dart              # Entry point
├── firebase_options.dart  # Firebase config
├── core/theme/            # Theme & colors
├── models/                # Data models
├── services/              # Firebase services
├── providers/             # State management
└── screens/               # UI screens
    ├── login/
    ├── main/              # Navigation shell
    ├── dashboard/
    ├── orders/
    ├── menu/
    ├── tables/
    ├── reports/
    ├── discounts/
    └── accounts/
```

## Lưu ý
- App dùng cùng Firebase project với web app (`order-fa2b5`)
- Không cần Firebase Auth - dùng hệ thống tài khoản riêng trong Firestore
- Tài khoản mặc định: `admin` / `123`
