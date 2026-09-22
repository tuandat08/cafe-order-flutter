// File này được tạo tự động. Bạn cần cập nhật các giá trị
// cho từng platform (Android, iOS, macOS) từ Firebase Console.
// Hướng dẫn: https://firebase.google.com/docs/flutter/setup

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions không hỗ trợ platform này.',
        );
    }
  }

  // Web config (từ .env hiện tại)
  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAds7yjZHgKKuoltBfHB6Xfr7MkMvYSXes',
    authDomain: 'order-fa2b5.firebaseapp.com',
    projectId: 'order-fa2b5',
    storageBucket: 'order-fa2b5.firebasestorage.app',
    messagingSenderId: '348886800909',
    appId: '1:348886800909:web:7b762a0247f0237fb29344',
  );

  // ⚠️ Android: Tải google-services.json từ Firebase Console và
  // đặt vào android/app/. Sau đó cập nhật appId dưới đây.
  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAds7yjZHgKKuoltBfHB6Xfr7MkMvYSXes',
    authDomain: 'order-fa2b5.firebaseapp.com',
    projectId: 'order-fa2b5',
    storageBucket: 'order-fa2b5.firebasestorage.app',
    messagingSenderId: '348886800909',
    appId: '1:348886800909:android:REPLACE_WITH_ANDROID_APP_ID', // ← Thay thế
  );

  // ⚠️ iOS: Tải GoogleService-Info.plist từ Firebase Console và
  // đặt vào ios/Runner/. Sau đó cập nhật bundleId và appId dưới đây.
  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyAds7yjZHgKKuoltBfHB6Xfr7MkMvYSXes',
    authDomain: 'order-fa2b5.firebaseapp.com',
    projectId: 'order-fa2b5',
    storageBucket: 'order-fa2b5.firebasestorage.app',
    messagingSenderId: '348886800909',
    appId: '1:348886800909:ios:REPLACE_WITH_IOS_APP_ID', // ← Thay thế
    iosBundleId: 'com.yourcompany.cafeAdmin', // ← Thay thế
  );

  // ⚠️ macOS: Tương tự iOS, thêm macOS app trong Firebase Console.
  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAds7yjZHgKKuoltBfHB6Xfr7MkMvYSXes',
    authDomain: 'order-fa2b5.firebaseapp.com',
    projectId: 'order-fa2b5',
    storageBucket: 'order-fa2b5.firebasestorage.app',
    messagingSenderId: '348886800909',
    appId: '1:348886800909:ios:e88194961ca6e021b29344', // ← Thay thế
    iosBundleId: 'com.yourcompany.cafeAdmin', // ← Thay thế
  );
}
