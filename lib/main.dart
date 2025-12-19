import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'utils/di.dart';
import 'providers/book_provider.dart';
import 'providers/room_provider.dart';
import 'providers/user_provider.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 設置依賴注入
  await setupDependencyInjection();

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => getIt<BookProvider>()),
        ChangeNotifierProvider(create: (_) => getIt<RoomProvider>()),
        ChangeNotifierProvider(create: (_) => getIt<UserProvider>()),
      ],
      child: const EpubHomeApp(),
    );
  }
}
