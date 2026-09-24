import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'core/theme/app_theme.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'screens/login/login_screen.dart';
import 'screens/main/main_shell.dart';
import 'widgets/offline_banner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (e) {
    if (e is! FirebaseException || e.code != 'duplicate-app') rethrow;
  }
  await initializeDateFormatting('vi', null);
  runApp(const CafeAdminApp());
}

class CafeAdminApp extends StatelessWidget {
  const CafeAdminApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AuthProvider(),
      child: MaterialApp(
        title: 'Cafe Admin',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        home: const AuthGate(),
        // Dải báo mất kết nối hiện trên MỌI màn hình (kể cả đăng nhập, mở ca).
        builder: (context, child) => OfflineBanner(child: child ?? const SizedBox()),
      ),
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        if (auth.isLoggedIn) return const MainShell();
        return const LoginScreen();
      },
    );
  }
}
