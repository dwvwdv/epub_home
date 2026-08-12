import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'config/supabase_config.dart';
import 'config/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/presence_provider.dart';
import 'providers/room_provider.dart';
import 'router/app_router.dart';

class CoTimeBookApp extends ConsumerStatefulWidget {
  const CoTimeBookApp({super.key});

  @override
  ConsumerState<CoTimeBookApp> createState() => _CoTimeBookAppState();
}

class _CoTimeBookAppState extends ConsumerState<CoTimeBookApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initAuth();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final isActive = state == AppLifecycleState.resumed;
    // Backgrounding is not leaving a room. Presence becomes transiently
    // unavailable and the database lease stops renewing until resume.
    unawaited(_updateAppLifecycle(isActive));
  }

  Future<void> _updateAppLifecycle(bool isActive) async {
    try {
      ref.read(roomProvider.notifier).setAppActive(isActive);
    } catch (error) {
      debugPrint('Unable to update room heartbeat lifecycle: $error');
    }
    try {
      await ref.read(presenceProvider.notifier).setAppActive(isActive);
    } catch (error) {
      debugPrint('Unable to update app lifecycle Presence: $error');
    }
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
