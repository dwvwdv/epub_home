import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config/app_constants.dart';
import 'supabase_service.dart';

typedef BroadcastCallback = void Function(Map<String, dynamic> payload);
typedef PresenceCallback = void Function(
    Map<String, List<Map<String, dynamic>>> presences);

class RealtimeService {
  RealtimeChannel? _channel;
  final _presenceController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _broadcastControllers = <String, StreamController<Map<String, dynamic>>>{};

  bool get isConnected => _channel != null;

  Stream<Map<String, dynamic>> get presenceStream => _presenceController.stream;

  Stream<Map<String, dynamic>> broadcastStream(String event) {
    _broadcastControllers[event] ??=
        StreamController<Map<String, dynamic>>.broadcast();
    return _broadcastControllers[event]!.stream;
  }

  RealtimeChannel joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
  }) {
    final channelName = AppConstants.roomChannelName(roomCode);
    _channel = SupabaseService.client.channel(
      channelName,
      opts: const RealtimeChannelConfig(self: true),
    );

    // Set up presence tracking
    _channel!.onPresenceSync((payload) {
      final state = _channel!.presenceState();
      _presenceController.add({'event': 'sync', 'state': state});
    });

    _channel!.onPresenceJoin((payload) {
      _presenceController.add({'event': 'join', 'payload': payload});
    });

    _channel!.onPresenceLeave((payload) {
      _presenceController.add({'event': 'leave', 'payload': payload});
    });

    // Set up broadcast listeners for all events
    final events = [
      'page_turn_request',
      'page_turn_confirm',
      'page_turn_execute',
      'page_turn_cancel',
      'book_shared',
      'book_chunk',
      'transfer_request',
      'transfer_accept',
    ];

    for (final event in events) {
      _channel!.onBroadcast(event: event, callback: (payload) {
        _broadcastControllers[event]?.add(payload);
      });
    }

    _channel!.subscribe((status, [error]) async {
      if (status == RealtimeSubscribeStatus.subscribed) {
        await _channel!.track({
          'user_id': userId,
          'nickname': nickname,
          'avatar_color': avatarColorIndex,
          'has_book': hasBook,
          'online_at': DateTime.now().toIso8601String(),
        });
        debugPrint('Joined room channel: $channelName');
      }
    });

    return _channel!;
  }

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    if (_channel == null) {
      throw Exception('Not connected to a room channel');
    }
    await _channel!.sendBroadcastMessage(event: event, payload: payload);
  }

  Future<void> updatePresence({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
  }) async {
    if (_channel == null) return;
    await _channel!.track({
      'user_id': userId,
      'nickname': nickname,
      'avatar_color': avatarColorIndex,
      'has_book': hasBook,
      'online_at': DateTime.now().toIso8601String(),
    });
  }

  Map<String, dynamic> getPresenceState() {
    if (_channel == null) return {};
    return _channel!.presenceState();
  }

  List<Map<String, dynamic>> getOnlineUsers() {
    final state = getPresenceState();
    final users = <Map<String, dynamic>>[];
    for (final presences in state.values) {
      if (presences is List) {
        for (final p in presences) {
          if (p is Map<String, dynamic>) {
            users.add(p);
          }
        }
      }
    }
    return users;
  }

  Future<void> leaveRoom() async {
    if (_channel != null) {
      await _channel!.untrack();
      await SupabaseService.client.removeChannel(_channel!);
      _channel = null;
    }
  }

  void dispose() {
    leaveRoom();
    _presenceController.close();
    for (final controller in _broadcastControllers.values) {
      controller.close();
    }
    _broadcastControllers.clear();
  }
}
