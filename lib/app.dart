import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/supabase_config.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'router/app_router.dart';

class CoTimeBookApp extends ConsumerStatefulWidget {
  const CoTimeBookApp({super.key});

  @override
  ConsumerState<CoTimeBookApp> createState() => _CoTimeBookAppState();
}

class _CoTimeBookAppState extends ConsumerState<CoTimeBookApp> {
  @override
  void initState() {
    super.initState();
    _initAuth();
  }

  Future<void> _initAuth() async {
    final authNotifier = ref.read(authProvider.notifier);

    if (SupabaseConfig.isConfigured) {
      // Check for existing session first
      await authNotifier.checkExistingSession();

      // If no session, sign in anonymously
      if (!ref.read(authProvider).isAuthenticated) {
        await authNotifier.signInAnonymously();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'CoTime Book',
      theme: AppTheme.darkTheme,
      routerConfig: AppRouter.router,
      debugShowCheckedModeBanner: false,
    );
  }
}
