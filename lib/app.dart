import 'package:flutter/material.dart';
import 'screens/home_screen.dart';
import 'utils/constants.dart';

class EpubHomeApp extends StatelessWidget {
  const EpubHomeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}
