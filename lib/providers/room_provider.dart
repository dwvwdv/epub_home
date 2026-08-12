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
    final originalMembers = state.members;
    try {
      final members = await _roomService.getRoomMembers(room.id);
      if (!_isCurrentRoomSession(room.id, roomSessionGeneration) ||
          !identical(state.members, originalMembers)) {
        return;
      }
      state = state.copyWith(members: members);
      // Re-apply online status after DB fetch (DB has no isOnline column)
      if (presenceUsers != null && presenceUsers.isNotEmpty) {
        updateMembersFromPresence(presenceUsers);
      }
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
  }

  void updateMembersFromPresence(List<Map<String, dynamic>> onlineUsers) {
    final updatedMembers = state.members.map((member) {
      final isOnline = onlineUsers.any(
        (u) => u['user_id'] == member.userId,
      );
      final onlineData = onlineUsers.firstWhere(
        (u) => u['user_id'] == member.userId,
        orElse: () => {},
      );
      return member.copyWith(
        isOnline: isOnline,
        hasBook: (onlineData['has_book'] as bool?) ?? member.hasBook,
      );
    }).toList();
    state = state.copyWith(members: updatedMembers);
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

    final updatedRoom = await _roomService.updateRoomBook(
      roomId: room.id,
      bookTitle: bookTitle,
      bookHash: bookHash,
      expectedRevision: room.revision,
    );
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      await _roomService.updateMemberBookStatus(
        roomId: room.id,
        userId: userId,
        hasBook: true,
      );
    }
    if (!_isCurrentRoomSession(room.id, roomSessionGeneration)) {
      throw RoomSessionChangedException(room.id);
    }

    _applyRoomUpdate(
      updatedRoom,
      originRoom: room,
      roomSessionGeneration: roomSessionGeneration,
    );

    await refreshMembers();
  }

  /// Fetch the latest room data from DB (e.g. to get updated CFI on re-entry).
  Future<void> refreshRoom() async {
    final room = state.currentRoom;
    if (room == null) return;
    final roomSessionGeneration = _roomSessionGeneration;
    try {
      final updated = await _roomService.getRoom(room.id);
      if (updated != null) {
        _applyRoomUpdate(
          updated,
          originRoom: room,
          roomSessionGeneration: roomSessionGeneration,
        );
      }
    } catch (error) {
      if (_isCurrentRoomSession(room.id, roomSessionGeneration)) {
        state = state.copyWith(error: error.toString());
      }
    }
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

    final Room updatedRoom;
    try {
      updatedRoom = await _roomService.updateRoomCfi(
        roomId: roomId,
        cfi: cfi,
        expectedRevision: originRoom.revision,
      );
    } on RoomSessionRevokedException catch (error) {
      await _revokeSession(roomId, error.message);
      rethrow;
    }
    if (_roomSessionGeneration != roomSessionGeneration ||
        state.currentRoom?.id != roomId ||
        state.readingSessionId != readingSessionId) {
      throw RoomSessionChangedException(roomId);
    }
    _applyRoomUpdate(
      updatedRoom,
      originRoom: originRoom,
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
