import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../config/supabase_config.dart';
import '../config/theme.dart';
import '../providers/auth_provider.dart';
import '../providers/room_provider.dart';
import '../widgets/room_code_input.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  final _nicknameController = TextEditingController();
  final _roomCodeController = TextEditingController();
  bool _isJoinMode = false;

  @override
  void dispose() {
    _nicknameController.dispose();
    _roomCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final roomState = ref.watch(roomProvider);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              // App title
              const Icon(
                Icons.menu_book_rounded,
                size: 64,
                color: AppTheme.primaryColor,
              ),
              const SizedBox(height: 16),
              const Text(
                'CoTime Book',
                style: TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Read together, anywhere',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
              const Spacer(),

              // Nickname input
              TextField(
                controller: _nicknameController,
                decoration: const InputDecoration(
                  hintText: 'Your nickname',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                maxLength: 20,
                buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
              ),
              const SizedBox(height: 24),

              if (_isJoinMode) ...[
                // Join room mode
                RoomCodeInput(controller: _roomCodeController),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => setState(() => _isJoinMode = false),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: const Text('Back'),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: roomState.isLoading ? null : _joinRoom,
                        child: roomState.isLoading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Join Room'),
                      ),
                    ),
                  ],
                ),
              ] else ...[
                // Default mode: Create or Join
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: roomState.isLoading ? null : _createRoom,
                    icon: const Icon(Icons.add),
                    label: roomState.isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Create Room'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() => _isJoinMode = true),
                    icon: const Icon(Icons.login),
                    label: const Text('Join Room'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: AppTheme.primaryColor),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
              ],

              if (roomState.error != null || authState.error != null) ...[
                const SizedBox(height: 16),
                Text(
                  roomState.error ?? authState.error!,
                  style: const TextStyle(color: AppTheme.errorColor),
                  textAlign: TextAlign.center,
                ),
              ],

              const Spacer(),

              // Auth status
              if (!SupabaseConfig.isConfigured)
                Text(
                  'Supabase not configured.\n'
                  'Run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                )
              else if (authState.isAuthenticated)
                Text(
                  'Connected',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 12,
                  ),
                )
              else
                TextButton(
                  onPressed: authState.isLoading
                      ? null
                      : () async {
                          await ref.read(authProvider.notifier).signInAnonymously();
                        },
                  child: authState.isLoading
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Tap to connect'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String? _validateNickname() {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      _showError('Please enter a nickname');
      return null;
    }
    return nickname;
  }

  Future<void> _createRoom() async {
    final nickname = _validateNickname();
    if (nickname == null) return;

    // Ensure authenticated
    if (!ref.read(authProvider).isAuthenticated) {
      await ref.read(authProvider.notifier).signInAnonymously();
    }

    ref.read(authProvider.notifier).setNickname(nickname);
    final room = await ref.read(roomProvider.notifier).createRoom(nickname);
    if (room != null && mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': room.code});
    }
  }

  Future<void> _joinRoom() async {
    final nickname = _validateNickname();
    if (nickname == null) return;

    final code = _roomCodeController.text.trim();
    if (code.length != 6) {
      _showError('Please enter a valid 6-character room code');
      return;
    }

    // Ensure authenticated
    if (!ref.read(authProvider).isAuthenticated) {
      await ref.read(authProvider.notifier).signInAnonymously();
    }

    ref.read(authProvider.notifier).setNickname(nickname);
    final room = await ref.read(roomProvider.notifier).joinRoom(code, nickname);
    if (room != null && mounted) {
      context.goNamed('lobby', pathParameters: {'roomCode': room.code});
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }
}
