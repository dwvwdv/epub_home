import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/supabase_config.dart';

class SupabaseService {
  static SupabaseClient get client => Supabase.instance.client;

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
  }

  static String? get currentUserId => client.auth.currentUser?.id;

  static Future<AuthResponse> signInAnonymously() async {
    return await client.auth.signInAnonymously();
  }

  static Future<void> signOut() async {
    await client.auth.signOut();
  }

  static bool get isAuthenticated => client.auth.currentUser != null;
}
