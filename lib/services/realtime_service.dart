import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../config/app_constants.dart';
import 'supabase_service.dart';

enum RealtimeConnectionStatus {
  disconnected,
  connecting,
  connected,
  reconnecting,
  error,
}

class RealtimeConnectionEvent {
  final RealtimeConnectionStatus status;
  final Object? error;

  const RealtimeConnectionEvent(this.status, {this.error});
}

/// Small adapter around Supabase's channel so room-session behavior can be
/// tested without opening a websocket.
abstract interface class RoomRealtimeChannel {
  void onPresenceSync(VoidCallback callback);
  void onPresenceJoin(ValueChanged<dynamic> callback);
  void onPresenceLeave(ValueChanged<dynamic> callback);
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback);
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  );
  Future<void> track(Map<String, dynamic> payload);
  Future<void> untrack();
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload);
  List<Map<String, dynamic>> presencePayloads();
  Future<void> remove();
}

typedef RoomRealtimeChannelFactory =
    RoomRealtimeChannel Function(String channelName, String presenceKey);

class _SupabaseRoomRealtimeChannel implements RoomRealtimeChannel {
  final SupabaseClient _client;
  final RealtimeChannel _channel;

  _SupabaseRoomRealtimeChannel(
    this._client,
    String channelName,
    String presenceKey,
  ) : _channel = _client.channel(
        channelName,
        opts: RealtimeChannelConfig(
          self: true,
          private: true,
          // A user can legitimately have more than one device. Keep the
          // individual connection metas distinct and merge them by user_id
          // at the provider boundary.
          key: '$presenceKey:${DateTime.now().microsecondsSinceEpoch}',
        ),
      );

  @override
  void onPresenceSync(VoidCallback callback) {
    _channel.onPresenceSync((_) => callback());
  }

  @override
  void onPresenceJoin(ValueChanged<dynamic> callback) {
    _channel.onPresenceJoin(callback);
  }

  @override
  void onPresenceLeave(ValueChanged<dynamic> callback) {
    _channel.onPresenceLeave(callback);
  }

  @override
  void onBroadcast(String event, ValueChanged<Map<String, dynamic>> callback) {
    _channel.onBroadcast(event: event, callback: callback);
  }

  @override
  void subscribe(
    void Function(RealtimeSubscribeStatus status, Object? error) callback,
  ) {
    _channel.subscribe((status, [error]) => callback(status, error));
  }

  @override
  Future<void> track(Map<String, dynamic> payload) async {
    await _channel.track(payload);
  }

  @override
  Future<void> untrack() async {
    await _channel.untrack();
  }

  @override
  Future<void> sendBroadcast(String event, Map<String, dynamic> payload) async {
    await _channel.sendBroadcastMessage(event: event, payload: payload);
  }

  @override
  List<Map<String, dynamic>> presencePayloads() {
    return [
      for (final state in _channel.presenceState())
        for (final presence in state.presences) presence.payload,
    ];
  }

  @override
  Future<void> remove() async {
    await _client.removeChannel(_channel);
  }
}

class RealtimeService {
  static const roomEvents = <String>[
    'page_turn_request',
    'page_turn_confirm',
    'page_turn_execute',
    'page_turn_cancel',
    'page_position_persisting',
    'page_position_commit',
    'page_position_ack',
    'page_turn_complete',
    'reading_session_leave',
    'book_shared',
    'book_chunk',
    'transfer_request',
    'transfer_accept',
    'start_reading',
    'membership_changed',
    'room_closed',
  ];

  final RoomRealtimeChannelFactory _channelFactory;
  RoomRealtimeChannel? _channel;
  String? _roomCode;
  String? _roomTopicId;
  String? _userId;
  Map<String, dynamic>? _presencePayload;
  RealtimeConnectionStatus _connectionStatus =
      RealtimeConnectionStatus.disconnected;
  int _generation = 0;
  Future<void> _operationTail = Future<void>.value();
  bool _isClosed = false;
  Future<void>? _closeFuture;

  final _presenceController =
      StreamController<Map<String, dynamic>>.broadcast();
  final _connectionController =
      StreamController<RealtimeConnectionEvent>.broadcast();
  final _broadcastControllers =
      <String, StreamController<Map<String, dynamic>>>{};

  RealtimeService({RoomRealtimeChannelFactory? channelFactory})
    : _channelFactory =
          channelFactory ??
          ((channelName, presenceKey) => _SupabaseRoomRealtimeChannel(
            SupabaseService.client,
            channelName,
            presenceKey,
          ));

  bool get isConnected =>
      _connectionStatus == RealtimeConnectionStatus.connected;
  String? get roomCode => _roomCode;
  int get generation => _generation;

  Stream<Map<String, dynamic>> get presenceStream => _presenceController.stream;
  Stream<RealtimeConnectionEvent> get connectionStream =>
      _connectionController.stream;

  Stream<Map<String, dynamic>> broadcastStream(String event) {
    _ensureOpen();
    _broadcastControllers[event] ??=
        StreamController<Map<String, dynamic>>.broadcast();
    return _broadcastControllers[event]!.stream;
  }

  Future<void> joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? roomTopicId,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) {
    final normalizedCode = roomCode.trim().toUpperCase();
    final normalizedTopicId = _normalizeTopicId(roomTopicId);
    final payload = _buildPresencePayload(
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
    );

    return _serialize(() async {
      _ensureOpen();

      final canReuseCurrentChannel =
          _connectionStatus == RealtimeConnectionStatus.connecting ||
          _connectionStatus == RealtimeConnectionStatus.connected ||
          _connectionStatus == RealtimeConnectionStatus.reconnecting;
      if (_roomCode == normalizedCode &&
          _roomTopicId == normalizedTopicId &&
          _userId == userId &&
          _channel != null &&
          canReuseCurrentChannel) {
        _presencePayload = payload;
        if (isConnected) {
          await _trackCurrentPresence(_channel!, _generation);
        }
        return;
      }

      await _leaveRoomInternal(emitDisconnected: _channel != null);

      final channelName = AppConstants.roomChannelName(
        normalizedTopicId ?? normalizedCode,
      );
      final generation = ++_generation;
      final channel = _channelFactory(channelName, userId);
      _channel = channel;
      _roomCode = normalizedCode;
      _roomTopicId = normalizedTopicId;
      _userId = userId;
      _presencePayload = payload;
      _emitConnection(RealtimeConnectionStatus.connecting);

      channel.onPresenceSync(() {
        if (!_isCurrent(channel, generation)) return;
        _presenceController.add({
          'event': 'sync',
          'state': channel.presencePayloads(),
          'generation': generation,
        });
      });

      channel.onPresenceJoin((presenceEvent) {
        if (!_isCurrent(channel, generation)) return;
        _presenceController.add({
          'event': 'join',
          'payload': presenceEvent,
          'generation': generation,
        });
      });

      channel.onPresenceLeave((presenceEvent) {
        if (!_isCurrent(channel, generation)) return;
        _presenceController.add({
          'event': 'leave',
          'payload': presenceEvent,
          'generation': generation,
        });
      });

      for (final event in roomEvents) {
        channel.onBroadcast(event, (payload) {
          if (!_isCurrent(channel, generation)) return;
          _broadcastControllers[event]?.add(payload);
        });
      }

      channel.subscribe((status, error) async {
        if (!_isCurrent(channel, generation)) return;
        if (status == RealtimeSubscribeStatus.subscribed) {
          try {
            await _trackCurrentPresence(channel, generation);
            if (_isCurrent(channel, generation)) {
              _emitConnection(RealtimeConnectionStatus.connected);
              debugPrint('Joined room channel: $channelName');
            }
          } catch (trackError) {
            if (_isCurrent(channel, generation)) {
              _emitConnection(
                RealtimeConnectionStatus.error,
                error: trackError,
              );
            }
          }
          return;
        }
        if (status == RealtimeSubscribeStatus.closed) {
          if (_channel != null) {
            _emitConnection(RealtimeConnectionStatus.disconnected);
          }
          return;
        }
        if (status == RealtimeSubscribeStatus.channelError ||
            status == RealtimeSubscribeStatus.timedOut) {
          _emitConnection(
            RealtimeConnectionStatus.error,
            error: error ?? 'Unable to subscribe to room channel',
          );
        }
      });
    });
  }

  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    final channel = _channel;
    if (channel == null || !isConnected) {
      throw StateError('Not connected to a room channel');
    }
    await channel.sendBroadcast(event, payload);
  }

  Future<void> updatePresence({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) {
    final payload = _buildPresencePayload(
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex,
      hasBook: hasBook,
      bookHash: bookHash,
      isReading: isReading,
      readerReady: readerReady,
    );

    return _serialize(() async {
      _ensureOpen();
      _presencePayload = payload;
      final channel = _channel;
      if (channel != null && isConnected) {
        await _trackCurrentPresence(channel, _generation);
      }
    });
  }

  List<Map<String, dynamic>> getOnlineUsers() {
    return _channel?.presencePayloads() ?? const [];
  }

  Future<void> leaveRoom() {
    return _serialize(() => _leaveRoomInternal(emitDisconnected: true));
  }

  Future<void> close() {
    return _closeFuture ??= _closeInternal();
  }

  Future<void> _closeInternal() async {
    // Fail new room operations immediately while the serialized leave waits
    // for work already queued ahead of it.
    _isClosed = true;
    try {
      await leaveRoom();
    } catch (error) {
      debugPrint('Realtime cleanup failed while closing: $error');
    }
    await _presenceController.close();
    await _connectionController.close();
    for (final controller in _broadcastControllers.values) {
      await controller.close();
    }
    _broadcastControllers.clear();
  }

  void dispose() {
    unawaited(close());
  }

  Future<void> _leaveRoomInternal({required bool emitDisconnected}) async {
    final channel = _channel;
    if (channel == null) {
      _roomCode = null;
      _roomTopicId = null;
      _userId = null;
      _presencePayload = null;
      if (emitDisconnected) {
        _emitConnection(RealtimeConnectionStatus.disconnected);
      }
      return;
    }

    ++_generation; // Invalidate callbacks before awaiting any network work.
    _channel = null;
    _roomCode = null;
    _roomTopicId = null;
    _userId = null;
    _presencePayload = null;

    Object? untrackError;
    try {
      await channel.untrack();
    } catch (error) {
      untrackError = error;
    }

    Object? removeError;
    try {
      await channel.remove();
    } catch (error) {
      removeError = error;
    } finally {
      if (emitDisconnected) {
        _emitConnection(RealtimeConnectionStatus.disconnected);
      }
    }

    if (removeError != null) throw removeError;
    if (untrackError != null) throw untrackError;
  }

  Future<void> _trackCurrentPresence(
    RoomRealtimeChannel channel,
    int generation,
  ) async {
    final payload = _presencePayload;
    if (payload == null || !_isCurrent(channel, generation)) return;
    await channel.track({
      ...payload,
      'online_at': DateTime.now().toIso8601String(),
    });
  }

  bool _isCurrent(RoomRealtimeChannel channel, int generation) {
    return !_isClosed &&
        identical(channel, _channel) &&
        generation == _generation;
  }

  Map<String, dynamic> _buildPresencePayload({
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    required bool hasBook,
    required String? bookHash,
    required bool isReading,
    required bool readerReady,
  }) {
    return {
      'user_id': userId,
      'nickname': nickname,
      'avatar_color': avatarColorIndex,
      'has_book': hasBook,
      'book_hash': hasBook ? bookHash : null,
      'is_reading': isReading,
      'reader_ready': readerReady,
    };
  }

  String? _normalizeTopicId(String? roomTopicId) {
    final normalized = roomTopicId?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _operationTail = _operationTail.catchError((_) {}).then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  void _emitConnection(RealtimeConnectionStatus status, {Object? error}) {
    _connectionStatus = status;
    if (!_connectionController.isClosed) {
      _connectionController.add(RealtimeConnectionEvent(status, error: error));
    }
  }

  void _ensureOpen() {
    if (_isClosed) throw StateError('RealtimeService is closed');
  }
}
