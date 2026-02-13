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
  final RoomService _roomService;

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
      return room;
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
      return null;
    }
  }

  Future<void> refreshMembers() async {
    final room = state.currentRoom;
    if (room == null) return;
    try {
      final members = await _roomService.getRoomMembers(room.id);
      state = state.copyWith(members: members);
    } catch (e) {
      // Silently fail, presence will keep UI updated
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

  Future<void> updateBookShared({
    required String bookTitle,
    required String bookHash,
  }) async {
    final room = state.currentRoom;
    if (room == null) return;

    await _roomService.updateRoomBook(
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
      currentRoom: room.copyWith(
        currentBookTitle: bookTitle,
        currentBookHash: bookHash,
      ),
    );

    await refreshMembers();
  }

  Future<void> updateCfi(String cfi) async {
    final room = state.currentRoom;
    if (room == null) return;

    await _roomService.updateRoomCfi(roomId: room.id, cfi: cfi);
    state = state.copyWith(
      currentRoom: room.copyWith(currentCfi: cfi),
    );
  }

  Future<void> leaveRoom() async {
    final room = state.currentRoom;
    final userId = SupabaseService.currentUserId;
    if (room == null || userId == null) return;

    await _roomService.leaveRoom(roomId: room.id, userId: userId);
    state = const RoomState();
  }

  void clearError() {
    state = state.copyWith(error: null);
  }
}
