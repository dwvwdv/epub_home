import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
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
          final roomCode = state.pathParameters['roomCode']!;
          return RoomLobbyScreen(roomCode: roomCode);
        },
      ),
      GoRoute(
        path: '/reader/:roomCode',
        name: 'reader',
        builder: (context, state) {
          final roomCode = state.pathParameters['roomCode']!;
          return ReaderScreen(roomCode: roomCode);
        },
      ),
    ],
    errorBuilder: (context, state) => Scaffold(
      body: Center(
        child: Text('Page not found: ${state.uri}'),
      ),
    ),
  );
}
