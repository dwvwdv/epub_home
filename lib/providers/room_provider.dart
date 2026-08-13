import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import '../providers/page_sync_provider.dart';
import '../providers/presence_provider.dart';
import '../services/room_service.dart';
import '../services/supabase_service.dart';

final roomServiceProvider = Provider<RoomService>((ref) => RoomService());

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) {
  return RoomNotifier(
    ref.read(roomServiceProvider),
    onSessionRevoked: () async {
      await Future.wait<void>([
        ref.read(pageSyncProvider.notifier).stop(),
        ref.read(presenceProvider.notifier).leaveRoom(),
      ]);
    },
  );
});

class RoomState {
  final Room? currentRoom;
  final List<RoomMember> members;
  final bool isLoading;
  final String? error;
  final String? readingSessionId;
  final Set<String> readingParticipantUserIds;

  const RoomState({
    this.currentRoom,
    this.members = const [],
    this.isLoading = false,
    this.error,
    this.readingSessionId,
    this.readingParticipantUserIds = const {},
  });

  bool get isInRoom => currentRoom != null;
  bool get isHost =>
      currentRoom != null &&
      currentRoom!.hostUserId == SupabaseService.currentUserId;
  bool get allMembersHaveBook =>
      members.isNotEmpty && members.every((m) => m.hasBook);

  RoomState copyWith({
    Room? currentRoom,
    List<RoomMember>? members,
    bool? isLoading,
    String? error,
    String? readingSessionId,
    Set<String>? readingParticipantUserIds,
    bool clearReadingSession = false,
  }) {
    return RoomState(
      currentRoom: currentRoom ?? this.currentRoom,
      members: members ?? this.members,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      readingSessionId:
          clearReadingSession ? null : readingSessionId ?? this.readingSessionId,
      readingParticipantUserIds: clearReadingSession
          ? const {}
          : readingParticipantUserIds ?? this.readingParticipantUserIds,
    );
  }
}

class RoomNotifier extends StateNotifier<RoomState> {
  static const heartbeatInterval = Duration(minutes: 5);

  final RoomService _roomService;
  final Future<void> Function()? _onSessionRevoked;
  Timer? _heartbeatTimer;
  bool _heartbeatInFlight = false;
  bool _appIsActive = true;
  bool _revocationInProgress = false;
  int _roomSessionGeneration = 0;
  int _membersFetchGeneration = 0;
  List<Map<String, dynamic>> _lastPresenceUsers = const [];

  RoomNotifier(
    this._roomService, {
    Future<void> Function()? onSessionRevoked,
  }) : _onSessionRevoked = onSessionRevoked,
       super(const RoomState());

  void beginReadingSession({
    required String sessionId,
    required Set<String> participantUserIds,
  }) {
    final currentUserId = SupabaseService.currentUserId;
    if (sessionId.isEmpty ||
        participantUserIds.isEmpty ||
        (currentUserId != null &&
            !participantUserIds.contains(currentUserId))) {
      throw ArgumentError('Invalid reading session roster');
    }
    state = state.copyWith(
      readingSessionId: sessionId,
      readingParticipantUserIds: Set.unmodifiable(participantUserIds),
      error: null,
    );
  }

  Future<Room?> createRoom(String nickname) async {
    final operationGeneration = ++_roomSessionGeneration;
    _resetMemberTracking();
    state = state.copyWith(isLoading: true, error: null);
    try {
      final room = await _roomService.createRoom(nickname: nickname);
      final members = await _roomService.getRoomMembers(room.id);
      if (_roomSessionGeneration != operationGeneration) return null;
      state = state.copyWith(
        currentRoom: room,
        members: members,
        isLoading: false,
        clearReadingSession: true,
      );
      _startHeartbeat(room.id);
      return room;
    } catch (e) {
      if (_roomSessionGeneration == operationGeneration) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      return null;
    }
  }

  Future<Room?> joinRoom(String code, String nickname) async {
    final operationGeneration = ++_roomSessionGeneration;
    _resetMemberTracking();
    state = state.copyWith(isLoading: true, error: null);
    try {
      final room = await _roomService.joinRoom(
        code: code,
        nickname: nickname,
      );
      final members = await _roomService.getRoomMembers(room.id);
      if (_roomSessionGeneration != operationGeneration) return null;
      state = state.copyWith(
        currentRoom: room,
        members: members,
        isLoading: false,
        clearReadingSession: true,
      );
      _startHeartbeat(room.id);
      return room;
    } catch (e) {
      if (_roomSessionGeneration == operationGeneration) {
        state = state.copyWith(isLoading: false, error: e.toString());
      }
      return null;
    }
  }

  Future<void> refreshMembers({List<Map<String, dynamic>>? presenceUsers}) async {
    final room = state.currentRoom;
    if (room == null) return;
    final roomSessionGeneration = _roomSessionGeneration;
    // The database owns the roster; Presence only owns the per-member online
    // and has_book overlay. Guarding on a fetch generation discards a fetch
    // that a *newer* fetch has already superseded, while a Presence overlay
    // applied during the await no longer throws the roster away — that used to
    // drop a member who joined while this refresh was in flight, because the
    // same listener re-applies Presence on every event.
    final fetchGeneration = ++_membersFetchGeneration;
    if (presenceUsers != null) _lastPresenceUsers = presenceUsers;
    try {
      final members = await _roomService.getRoomMembers(room.id);
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration) ||
          fetchGeneration != _membersFetchGeneration) {
        return;
      }
      state = state.copyWith(
        members: _applyPresenceOverlay(members, _lastPresenceUsers),
      );
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration) &&
          fetchGeneration == _membersFetchGeneration) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  void updateMembersFromPresence(List<Map<String, dynamic>> onlineUsers) {
    _lastPresenceUsers = onlineUsers;
    final updatedMembers = _applyPresenceOverlay(state.members, onlineUsers);
    // Presence fires far more often than it changes anything. Rewriting state
    // with an identical roster only churns listeners and rebuilds.
    if (_membersMatch(state.members, updatedMembers)) return;
    state = state.copyWith(members: updatedMembers);
  }

  List<RoomMember> _applyPresenceOverlay(
    List<RoomMember> members,
    List<Map<String, dynamic>> onlineUsers,
  ) {
    if (onlineUsers.isEmpty) return members;
    final onlineById = {
      for (final user in onlineUsers)
        if (user['user_id'] is String) user['user_id'] as String: user,
    };
    return members.map((member) {
      final onlineData = onlineById[member.userId];
      return member.copyWith(
        isOnline: onlineData != null,
        hasBook: (onlineData?['has_book'] as bool?) ?? member.hasBook,
      );
    }).toList(growable: false);
  }

  bool _membersMatch(List<RoomMember> a, List<RoomMember> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      final left = a[index];
      final right = b[index];
      if (left.userId != right.userId ||
          left.nickname != right.nickname ||
          left.avatarColorIndex != right.avatarColorIndex ||
          left.isOnline != right.isOnline ||
          left.hasBook != right.hasBook) {
        return false;
      }
    }
    return true;
  }

  /// Called on all clients (including receiver) when book_shared broadcast arrives.
  void onBookSharedReceived({
    required String bookTitle,
    required String bookHash,
  }) {
    final room = state.currentRoom;
    if (room == null) return;
    state = state.copyWith(
      currentRoom: room.copyWith(
        currentBookTitle: bookTitle,
        currentBookHash: bookHash,
      ),
    );
  }

  /// Update DB has_book status for the current user (receiver side).
  Future<void> updateReceiverBookStatus() async {
    final room = state.currentRoom;
    final userId = SupabaseService.currentUserId;
    if (room == null || userId == null) return;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      await _roomService.updateMemberBookStatus(
        roomId: room.id,
        userId: userId,
        hasBook: true,
      );
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) return;
      await refreshMembers();
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(room.id, error.message);
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  Future<void> updateBookShared({
    required String bookTitle,
    required String bookHash,
  }) async {
    final room = state.currentRoom;
    if (room == null) return;
    final roomSessionGeneration = _roomSessionGeneration;

    var writeOrigin = room;
    Room? updatedRoom;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        updatedRoom = await _roomService.updateRoomBook(
          roomId: room.id,
          bookTitle: bookTitle,
          bookHash: bookHash,
          expectedRevision: writeOrigin.revision,
        );
        break;
      } on RoomRevisionConflictException catch (error) {
        if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
          throw RoomSessionChangedException(room.id);
        }
        _applyRoomUpdate(
          error.currentRoom,
          originRoom: writeOrigin,
          roomSessionGeneration: roomSessionGeneration,
        );
        writeOrigin = state.currentRoom!;
        if (attempt == 1) rethrow;
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(room.id, error.message);
        rethrow;
      }
    }
    if (updatedRoom == null) {
      throw StateError('Room book update did not complete');
    }
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      try {
        await _roomService.updateMemberBookStatus(
          roomId: room.id,
          userId: userId,
          hasBook: true,
        );
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(room.id, error.message);
        rethrow;
      }
    }
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    _applyRoomUpdate(
      updatedRoom,
      originRoom: writeOrigin,
      roomSessionGeneration: roomSessionGeneration,
    );

    await refreshMembers();
  }

  /// Fetch the latest room data from DB (e.g. to get updated CFI on re-entry).
  Future<void> refreshRoom() async {
    await refreshRoomAndGet();
  }

  /// Fetch and return an authoritative room snapshot when recovery depends on
  /// knowing whether the read completed for the current room session.
  Future<Room?> refreshRoomAndGet() async {
    final room = state.currentRoom;
    if (room == null) return null;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      final updated = await _roomService.getRoom(room.id);
      if (updated == null) {
        if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
          await _revokeSession(
            room.id,
            'This room membership is inactive or has expired.',
          );
        }
        return null;
      }
      final applied = _applyRoomUpdate(
        updated,
        originRoom: room,
        roomSessionGeneration: roomSessionGeneration,
      );
      if (applied ||
          (_isCurrentRoomSession(room.id, roomSessionGeneration) &&
              state.currentRoom!.revision > updated.revision)) {
        return state.currentRoom;
      }
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
    return null;
  }

  Future<void> updateCfi(String cfi) async {
    final room = state.currentRoom;
    if (room == null) return;

    await updateCfiForRoom(roomId: room.id, cfi: cfi);
  }

  Future<void> updateCfiForRoom({
    required String roomId,
    required String cfi,
  }) async {
    if (state.currentRoom?.id != roomId || state.isLoading) {
      throw RoomSessionChangedException(roomId);
    }
    final roomSessionGeneration = _roomSessionGeneration;
    final readingSessionId = state.readingSessionId;
    final originRoom = state.currentRoom!;

    var writeOrigin = originRoom;
    Room? updatedRoom;
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        updatedRoom = await _roomService.updateRoomCfi(
          roomId: roomId,
          cfi: cfi,
          expectedRevision: writeOrigin.revision,
        );
        break;
      } on RoomRevisionConflictException catch (error) {
        if (_roomSessionGeneration != roomSessionGeneration ||
            state.currentRoom?.id != roomId ||
            state.readingSessionId != readingSessionId) {
          throw RoomSessionChangedException(roomId);
        }
        _applyRoomUpdate(
          error.currentRoom,
          originRoom: writeOrigin,
          roomSessionGeneration: roomSessionGeneration,
        );
        writeOrigin = state.currentRoom!;
        if (attempt == 1) rethrow;
      } on RoomSessionRevokedException catch (error) {
        await _revokeSession(roomId, error.message);
        rethrow;
      }
    }
    if (updatedRoom == null) {
      throw StateError('Room position update did not complete');
    }
    if (_roomSessionGeneration != roomSessionGeneration ||
        state.currentRoom?.id != roomId ||
        state.readingSessionId != readingSessionId) {
      throw RoomSessionChangedException(roomId);
    }
    _applyRoomUpdate(
      updatedRoom,
      originRoom: writeOrigin,
      roomSessionGeneration: roomSessionGeneration,
      clearError: true,
    );
  }

  Future<void> heartbeat() async {
    final room = state.currentRoom;
    if (room == null) return;

    await _sendHeartbeat(room.id, rethrowError: true);
  }

  void setAppActive(bool isActive) {
    _appIsActive = isActive;
    if (!isActive) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      return;
    }

    final roomId = state.currentRoom?.id;
    if (roomId != null) {
      _startHeartbeat(roomId, sendImmediately: true);
    }
  }

  void _startHeartbeat(String roomId, {bool sendImmediately = false}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_appIsActive) return;

    if (sendImmediately) {
      unawaited(_sendHeartbeat(roomId));
    }
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      unawaited(_sendHeartbeat(roomId));
    });
  }

  Future<void> _sendHeartbeat(
    String roomId, {
    bool rethrowError = false,
  }) async {
    if (_heartbeatInFlight ||
        !_appIsActive ||
        state.currentRoom?.id != roomId) {
      return;
    }

    final roomSessionGeneration = _roomSessionGeneration;
    final originRoom = state.currentRoom!;
    _heartbeatInFlight = true;
    try {
      final updatedRoom = await _roomService.heartbeatRoom(roomId);
      _applyRoomUpdate(
        updatedRoom,
        originRoom: originRoom,
        roomSessionGeneration: roomSessionGeneration,
        clearError: true,
      );
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(roomId, error.message);
      if (rethrowError) rethrow;
    } catch (error) {
      if (_isCurrentRoomSession(roomId, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
      if (rethrowError) rethrow;
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> _revokeSession(String roomId, String reason) async {
    if (_revocationInProgress || state.currentRoom?.id != roomId) return;
    _revocationInProgress = true;
    _roomSessionGeneration++;
    _resetMemberTracking();
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    state = RoomState(error: reason);
    try {
      await _onSessionRevoked?.call();
    } catch (_) {
      // The authoritative room state is already revoked. Best-effort transport
      // cleanup must not turn a periodic heartbeat into an unhandled error.
    } finally {
      _revocationInProgress = false;
    }
  }

  Future<void> leaveRoom() async {
    final room = state.currentRoom;
    final leavingGeneration = ++_roomSessionGeneration;
    _resetMemberTracking();
    if (room == null) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      state = const RoomState();
      return;
    }

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    state = state.copyWith(isLoading: true, error: null);
    try {
      await _roomService.leaveRoom(roomId: room.id);
    } finally {
      if (_roomSessionGeneration == leavingGeneration) {
        state = const RoomState();
      }
    }
  }

  /// Drops the Presence overlay and invalidates any in-flight roster fetch so
  /// a previous room cannot bleed into the next one.
  void _resetMemberTracking() {
    _membersFetchGeneration++;
    _lastPresenceUsers = const [];
  }

  bool _isCurrentRoomSession(String roomId, int roomSessionGeneration) {
    return _roomSessionGeneration == roomSessionGeneration &&
        state.currentRoom?.id == roomId;
  }

  bool _applyRoomUpdate(
    Room updatedRoom, {
    required Room originRoom,
    required int roomSessionGeneration,
    bool clearError = false,
  }) {
    if (!_isCurrentRoomSession(updatedRoom.id, roomSessionGeneration)) {
      return false;
    }
    final currentRoom = state.currentRoom!;
    final isNewer = updatedRoom.revision > currentRoom.revision;
    final isUnchangedSnapshot =
        updatedRoom.revision == currentRoom.revision &&
        identical(currentRoom, originRoom);
    if (!isNewer && !isUnchangedSnapshot) return false;

    state = state.copyWith(
      currentRoom: updatedRoom,
      error: clearError ? null : state.error,
    );
    return true;
  }

  void clearError() {
    state = state.copyWith(error: null);
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    super.dispose();
  }
}
