import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/room_provider.dart';
import '../screens/home_screen.dart';
import '../screens/room_lobby_screen.dart';
import '../screens/reader_screen.dart';

class AppRouter {
  static final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        name: 'home',
        builder: (context, state) => const HomeScreen(),
      ),
      GoRoute(
        path: '/lobby/:roomCode',
        name: 'lobby',
        builder: (context, state) {
          final roomCode = state.pathParameters['roomCode']!.toUpperCase();
          if (!_isRoomCode(roomCode)) {
            return _invalidRoomCodeScreen(context);
          }
          // Lobby performs an asynchronous membership/session check and owns
          // cleanup while leaving. Keep it mounted until that cleanup finishes.
          return RoomLobbyScreen(roomCode: roomCode);
        },
      ),
      GoRoute(
        path: '/reader/:roomCode',
        name: 'reader',
        builder: (context, state) {
          final roomCode = state.pathParameters['roomCode']!.toUpperCase();
          if (!_isRoomCode(roomCode)) {
            return _invalidRoomCodeScreen(context);
          }
          return _ActiveRoomGuard(
            roomCode: roomCode,
            child: ReaderScreen(roomCode: roomCode),
          );
        },
      ),
    ],
    errorBuilder: (context, state) =>
        Scaffold(body: Center(child: Text('Page not found: ${state.uri}'))),
  );

  static bool _isRoomCode(String value) {
    return RegExp(r'^[A-HJ-NP-Z2-9]{6}$').hasMatch(value);
  }

  static Widget _invalidRoomCodeScreen(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Invalid room link')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => context.goNamed('home'),
          child: const Text('Return Home'),
        ),
      ),
    );
  }
}

class _ActiveRoomGuard extends ConsumerWidget {
  final String roomCode;
  final Widget child;

  const _ActiveRoomGuard({required this.roomCode, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeRoom = ref.watch(roomProvider).currentRoom;
    if (activeRoom != null &&
        activeRoom.code.toUpperCase() == roomCode.toUpperCase()) {
      return child;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Room unavailable')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Join this room from Home before opening this page.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: () => context.goNamed('home'),
                child: const Text('Return Home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
