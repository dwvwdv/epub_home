import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

class SupabaseService {
  static bool _initialized = false;

  static bool get isInitialized => _initialized;

  static SupabaseClient get client {
    if (!_initialized) {
      throw Exception(
        'Supabase is not initialized. '
        'Please provide SUPABASE_URL and SUPABASE_ANON_KEY via --dart-define.',
      );
    }
    return Supabase.instance.client;
  }

  static Future<void> initialize() async {
    if (!SupabaseConfig.isConfigured) {
      throw Exception(
        'Supabase is not configured. '
        'Please provide SUPABASE_URL and SUPABASE_ANON_KEY via --dart-define.',
      );
    }

    await Supabase.initialize(
      url: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
    );
    _initialized = true;
  }

  static String? get currentUserId {
    if (!_initialized) return null;
    return Supabase.instance.client.auth.currentUser?.id;
  }

  static Future<AuthResponse> signInAnonymously() async {
    return await client.auth.signInAnonymously();
  }

  static Future<void> signOut() async {
    await client.auth.signOut();
  }

  static bool get isAuthenticated {
    if (!_initialized) return false;
    return Supabase.instance.client.auth.currentUser != null;
  }
}
