import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/room.dart';
import '../models/room_member.dart';
import '../services/room_service.dart';
import '../services/supabase_service.dart';

final roomServiceProvider = Provider<RoomService>((ref) => RoomService());

final roomProvider = StateNotifierProvider<RoomNotifier, RoomState>((ref) {
  return RoomNotifier(ref.read(roomServiceProvider));
});

class RoomState {
  final Room? currentRoom;
  final List<RoomMember> members;
  final bool isLoading;
  final String? error;

  const RoomState({
    this.currentRoom,
    this.members = const [],
    this.isLoading = false,
    this.error,
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
  }) {
    return RoomState(
      currentRoom: currentRoom ?? this.currentRoom,
      members: members ?? this.members,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

class RoomNotifier extends StateNotifier<RoomState> {
  static const heartbeatInterval = Duration(minutes: 5);

  final RoomService _roomService;
  Timer? _heartbeatTimer;
  bool _heartbeatInFlight = false;
  bool _appIsActive = true;

  RoomNotifier(this._roomService) : super(const RoomState());

  Future<Room?> createRoom(String nickname) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final room = await _roomService.createRoom(nickname: nickname);
      final members = await _roomService.getRoomMembers(room.id);
      state = state.copyWith(
        currentRoom: room,
        members: members,
        isLoading: false,
      );
      _startHeartbeat(room.id);
      return room;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }

  Future<Room?> joinRoom(String code, String nickname) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final room = await _roomService.joinRoom(
        code: code,
        nickname: nickname,
      );
      final members = await _roomService.getRoomMembers(room.id);
      state = state.copyWith(
        currentRoom: room,
        members: members,
        isLoading: false,
      );
      _startHeartbeat(room.id);
      return room;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }

  Future<void> refreshMembers({List<Map<String, dynamic>>? presenceUsers}) async {
    final room = state.currentRoom;
    if (room == null) return;
    try {
      final members = await _roomService.getRoomMembers(room.id);
      state = state.copyWith(members: members);
      // Re-apply online status after DB fetch (DB has no isOnline column)
      if (presenceUsers != null && presenceUsers.isNotEmpty) {
        updateMembersFromPresence(presenceUsers);
      }
    } catch (error) {
      state = state.copyWith(error: error.toString());
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
    try {
      await _roomService.updateMemberBookStatus(
        roomId: room.id,
        userId: userId,
        hasBook: true,
      );
      await refreshMembers();
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> updateBookShared({
    required String bookTitle,
    required String bookHash,
  }) async {
    final room = state.currentRoom;
    if (room == null) return;

    final updatedRoom = await _roomService.updateRoomBook(
      roomId: room.id,
      bookTitle: bookTitle,
      bookHash: bookHash,
    );

    final userId = SupabaseService.currentUserId;
    if (userId != null) {
      await _roomService.updateMemberBookStatus(
        roomId: room.id,
        userId: userId,
        hasBook: true,
      );
    }

    state = state.copyWith(
      currentRoom: updatedRoom,
    );

    await refreshMembers();
  }

  /// Fetch the latest room data from DB (e.g. to get updated CFI on re-entry).
  Future<void> refreshRoom() async {
    final room = state.currentRoom;
    if (room == null) return;
    try {
      final updated = await _roomService.getRoom(room.id);
      if (updated != null) {
        state = state.copyWith(currentRoom: updated);
      }
    } catch (error) {
      state = state.copyWith(error: error.toString());
    }
  }

  Future<void> updateCfi(String cfi) async {
    final room = state.currentRoom;
    if (room == null) return;

    final updatedRoom = await _roomService.updateRoomCfi(
      roomId: room.id,
      cfi: cfi,
    );
    state = state.copyWith(currentRoom: updatedRoom);
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

    _heartbeatInFlight = true;
    try {
      final updatedRoom = await _roomService.heartbeatRoom(roomId);
      if (state.currentRoom?.id == roomId) {
        state = state.copyWith(currentRoom: updatedRoom, error: null);
      }
    } catch (error) {
      if (state.currentRoom?.id == roomId) {
        state = state.copyWith(error: error.toString());
      }
      if (rethrowError) rethrow;
    } finally {
      _heartbeatInFlight = false;
    }
  }

  Future<void> leaveRoom() async {
    final room = state.currentRoom;
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
      state = const RoomState();
    }
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
