import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/realtime_service.dart';

export '../services/presence_merge.dart' show mergePresenceUsers;

final realtimeServiceProvider = Provider<RealtimeService>((ref) {
  final service = RealtimeService();
  ref.onDispose(service.dispose);
  return service;
});

final presenceProvider = StateNotifierProvider<PresenceNotifier, PresenceState>(
  (ref) {
    return PresenceNotifier(ref.read(realtimeServiceProvider));
  },
);

class PresenceState {
  final List<Map<String, dynamic>> onlineUsers;
  final RealtimeConnectionStatus connectionStatus;
  final bool hasInitialSync;
  final String? error;

  const PresenceState({
    this.onlineUsers = const [],
    this.connectionStatus = RealtimeConnectionStatus.disconnected,
    this.hasInitialSync = false,
    this.error,
  });

  bool get isConnected =>
      connectionStatus == RealtimeConnectionStatus.connected;
  int get onlineCount => onlineUsers.length;

  List<String> get onlineUserIds => onlineUsers
      .map((user) => user['user_id'] as String?)
      .whereType<String>()
      .toList(growable: false);

  PresenceState copyWith({
    List<Map<String, dynamic>>? onlineUsers,
    RealtimeConnectionStatus? connectionStatus,
    bool? hasInitialSync,
    String? error,
    bool clearError = false,
  }) {
    return PresenceState(
      onlineUsers: onlineUsers ?? this.onlineUsers,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      hasInitialSync: hasInitialSync ?? this.hasInitialSync,
      error: clearError ? null : error ?? this.error,
    );
  }
}

class PresenceNotifier extends StateNotifier<PresenceState> {
  final RealtimeService _realtimeService;
  StreamSubscription<Map<String, dynamic>>? _presenceSubscription;
  StreamSubscription<RealtimeConnectionEvent>? _connectionSubscription;

  String? _currentRoomCode;
  String? _currentRoomTopicId;
  String? _currentUserId;
  String? _currentNickname;
  int _currentAvatarColorIndex = 0;
  bool _currentHasBook = false;
  String? _currentBookHash;
  bool _currentIsReading = false;
  bool _currentReaderReady = false;
  bool _isAppActive = true;
  bool _hasPendingJoinAnnouncement = false;

  PresenceNotifier(this._realtimeService) : super(const PresenceState()) {
    _presenceSubscription = _realtimeService.presenceStream.listen((event) {
      // Already merged to one row per logical user by RealtimeService.
      final users = _realtimeService.getOnlineUsers();
      state = state.copyWith(
        onlineUsers: users,
        hasInitialSync: state.hasInitialSync || event['event'] == 'sync',
      );
    });
    _connectionSubscription = _realtimeService.connectionStream.listen((event) {
      final hasUsablePresence =
          event.status == RealtimeConnectionStatus.connected ||
          event.status == RealtimeConnectionStatus.reconnecting;
      state = PresenceState(
        onlineUsers: hasUsablePresence ? state.onlineUsers : const [],
        connectionStatus: event.status,
        hasInitialSync: hasUsablePresence && state.hasInitialSync,
        error: event.error?.toString(),
      );
      if (event.status == RealtimeConnectionStatus.connected) {
        unawaited(_flushJoinAnnouncement());
      }
    });
  }

  Future<void> joinRoom({
    required String roomCode,
    required String userId,
    required String nickname,
    required int avatarColorIndex,
    bool hasBook = false,
    String? roomTopicId,
    String? bookHash,
    bool isReading = false,
    bool readerReady = false,
  }) async {
    final normalizedCode = roomCode.trim().toUpperCase();
    final normalizedTopicId = _normalizeTopicId(roomTopicId);
    final sameSession =
        _currentRoomCode == normalizedCode &&
        _currentRoomTopicId == normalizedTopicId &&
        _currentUserId == userId &&
        (state.connectionStatus == RealtimeConnectionStatus.connecting ||
            state.connectionStatus == RealtimeConnectionStatus.connected ||
            state.connectionStatus == RealtimeConnectionStatus.reconnecting);
    _currentRoomCode = normalizedCode;
    _currentRoomTopicId = normalizedTopicId;
    _currentUserId = userId;
    _currentNickname = nickname;
    _currentAvatarColorIndex = avatarColorIndex;
    _currentHasBook = hasBook;
    _currentBookHash = hasBook ? bookHash : null;
    _currentIsReading = isReading;
    _currentReaderReady = readerReady;

    if (!sameSession) {
      state = const PresenceState(
        connectionStatus: RealtimeConnectionStatus.connecting,
      );
    }

    try {
      await _realtimeService.joinRoom(
        roomCode: normalizedCode,
        userId: userId,
        nickname: nickname,
        avatarColorIndex: avatarColorIndex,
        hasBook: hasBook,
        roomTopicId: normalizedTopicId,
        bookHash: bookHash,
        isReading: _isAppActive && isReading,
        readerReady: _isAppActive && readerReady,
      );
    } catch (error) {
      state = state.copyWith(
        connectionStatus: RealtimeConnectionStatus.error,
        error: error.toString(),
      );
      rethrow;
    }
  }

  Future<void> updateHasBook(bool hasBook, {String? bookHash}) async {
    _currentHasBook = hasBook;
    _currentBookHash = hasBook ? bookHash ?? _currentBookHash : null;
    await _updatePresence();
  }

  Future<void> updateIsReading(bool isReading) async {
    _currentIsReading = isReading;
    // Entering Reader does not mean the EPUB viewer can turn pages yet.
    // Only the chapters-loaded hook may set reader_ready=true.
    if (!isReading) _currentReaderReady = false;
    await _updatePresence();
  }

  Future<void> updateReaderReady(bool readerReady) async {
    _currentReaderReady = readerReady;
    await _updatePresence();
  }

  Future<void> setAppActive(bool isActive) async {
    if (_isAppActive == isActive) return;
    _isAppActive = isActive;
    await _updatePresence();
  }

  /// Broadcast while the caller is still a database member. Realtime channel
  /// authorization is evaluated against room membership, so this must happen
  /// before the leave RPC/delete removes that membership.
  Future<void> announceLeaving() async {
    await _announceMembership('leaving');
  }

  /// Presence alone does not tell existing members that the database roster
  /// grew: it only says a connection appeared. Announcing the join makes every
  /// other client re-read the authoritative member list instead of waiting for
  /// an unrelated refresh.
  ///
  /// [RealtimeService.joinRoom] returns once `subscribe()` has been *called*,
  /// not once the channel is subscribed, so the transport is still connecting
  /// here and sending immediately dropped every join silently.
  ///
  /// The announcement is therefore queued rather than raced against a timer:
  /// it is sent on the next connected event and stays queued until it lands or
  /// the room session is replaced. A slow subscription must not lose it — in
  /// the same-user rejoin this exists for, lingering metas merge to the same
  /// user ID, so the lobby's Presence-ID listener sees no change and this is
  /// the only signal the peers get that the roster grew.
  Future<void> announceJoining() async {
    _hasPendingJoinAnnouncement = true;
    await _flushJoinAnnouncement();
  }

  Future<void> _flushJoinAnnouncement() async {
    if (!_hasPendingJoinAnnouncement || !_realtimeService.isConnected) return;
    _hasPendingJoinAnnouncement = false;
    try {
      await _announceMembership('joined');
    } catch (_) {
      // Re-queue for the next connected event rather than losing the join.
      _hasPendingJoinAnnouncement = true;
    }
  }

  Future<void> _announceMembership(String action) async {
    final roomCode = _currentRoomCode;
    final userId = _currentUserId;
    if (roomCode == null || userId == null || !_realtimeService.isConnected) {
      return;
    }
    await _realtimeService.broadcast(
      event: 'membership_changed',
      payload: {'action': action, 'room_code': roomCode, 'user_id': userId},
    );
  }

  Future<void> _updatePresence() async {
    final userId = _currentUserId;
    if (userId == null) return;
    await _realtimeService.updatePresence(
      userId: userId,
      nickname: _currentNickname ?? '',
      avatarColorIndex: _currentAvatarColorIndex,
      hasBook: _currentHasBook,
      bookHash: _currentBookHash,
      isReading: _isAppActive && _currentIsReading,
      readerReady: _isAppActive && _currentReaderReady,
    );
  }

  Future<void> leaveRoom() async {
    _clearCurrentUser();
    try {
      await _realtimeService.leaveRoom();
    } finally {
      state = const PresenceState();
    }
  }

  void _clearCurrentUser() {
    // A queued announcement belongs to the room session that queued it.
    _hasPendingJoinAnnouncement = false;
    _currentRoomCode = null;
    _currentRoomTopicId = null;
    _currentUserId = null;
    _currentNickname = null;
    _currentAvatarColorIndex = 0;
    _currentHasBook = false;
    _currentBookHash = null;
    _currentIsReading = false;
    _currentReaderReady = false;
    _isAppActive = true;
  }

  String? _normalizeTopicId(String? roomTopicId) {
    final normalized = roomTopicId?.trim().toLowerCase();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  @override
  void dispose() {
    _presenceSubscription?.cancel();
    _connectionSubscription?.cancel();
    super.dispose();
  }
}
