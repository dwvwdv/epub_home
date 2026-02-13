import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/supabase_service.dart';

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  return AuthNotifier();
});

class AuthState {
  final String? userId;
  final String nickname;
  final bool isLoading;
  final String? error;

  const AuthState({
    this.userId,
    this.nickname = '',
    this.isLoading = false,
    this.error,
  });

  bool get isAuthenticated => userId != null;

  AuthState copyWith({
    String? userId,
    String? nickname,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      userId: userId ?? this.userId,
      nickname: nickname ?? this.nickname,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState());

  Future<void> signInAnonymously() async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      await SupabaseService.signInAnonymously();
      state = state.copyWith(
        userId: SupabaseService.currentUserId,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  void setNickname(String nickname) {
    state = state.copyWith(nickname: nickname);
  }

  Future<void> checkExistingSession() async {
    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      state = state.copyWith(userId: userId);
    }
  }
}
