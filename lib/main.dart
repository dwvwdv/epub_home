import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'config/supabase_config.dart';
import 'services/supabase_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (SupabaseConfig.isConfigured) {
    await SupabaseService.initialize();
  } else {
    debugPrint(
      'WARNING: Supabase not configured. '
      'Run with --dart-define=SUPABASE_URL=xxx --dart-define=SUPABASE_ANON_KEY=xxx',
    );
  }

  runApp(
    const ProviderScope(
      child: CoTimeBookApp(),
    ),
  );
}
