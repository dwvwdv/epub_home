import 'dart:async';
import 'package:uuid/uuid.dart';
import '../models/room.dart';
import '../models/user.dart';
import '../models/book.dart';

class RoomService {
  final _uuid = const Uuid();
  final Map<String, Room> _rooms = {};
  final StreamController<List<Room>> _roomsController =
      StreamController<List<Room>>.broadcast();

  Stream<List<Room>> get roomsStream => _roomsController.stream;

  /// 創建房間
  Room createRoom({
    required String name,
    required User host,
    required Book book,
  }) {
    final roomId = _uuid.v4();
    final room = Room(
      id: roomId,
      name: name,
      hostId: host.id,
      book: book,
      participants: [host],
      pageStatuses: {host.id: PageStatus.viewing},
    );

    _rooms[roomId] = room;
    _notifyRoomsChanged();

    return room;
  }

  /// 加入房間
  bool joinRoom({
    required String roomId,
    required User user,
  }) {
    final room = _rooms[roomId];
    if (room == null) return false;

    // 檢查是否已在房間中
    if (room.participants.any((p) => p.id == user.id)) {
      return true;
    }

    room.participants.add(user);
    room.pageStatuses[user.id] = PageStatus.viewing;
    _notifyRoomsChanged();

    return true;
  }

  /// 離開房間
  bool leaveRoom({
    required String roomId,
    required String userId,
  }) {
    final room = _rooms[roomId];
    if (room == null) return false;

    room.participants.removeWhere((p) => p.id == userId);
    room.pageStatuses.remove(userId);

    // 如果房主離開且還有其他人，轉移房主
    if (room.hostId == userId && room.participants.isNotEmpty) {
      room.participants.first.isHost;
    }

    // 如果房間空了，刪除房間
    if (room.participants.isEmpty) {
      _rooms.remove(roomId);
    }

    _notifyRoomsChanged();
    return true;
  }

  /// 更新用戶翻頁狀態
  void updatePageStatus({
    required String roomId,
    required String userId,
    required PageStatus status,
  }) {
    final room = _rooms[roomId];
    if (room == null) return;

    room.pageStatuses[userId] = status;
    _notifyRoomsChanged();
  }

  /// 設置房間當前頁碼
  void setRoomCurrentPage({
    required String roomId,
    required int page,
  }) {
    final room = _rooms[roomId];
    if (room == null) return;

    room.currentPage = page;

    // 重置所有用戶狀態為 viewing
    for (final participant in room.participants) {
      room.pageStatuses[participant.id] = PageStatus.viewing;
    }

    _notifyRoomsChanged();
  }

  /// 獲取房間
  Room? getRoom(String roomId) => _rooms[roomId];

  /// 獲取所有房間
  List<Room> getAllRooms() => _rooms.values.toList();

  /// 獲取用戶創建的房間
  List<Room> getUserHostedRooms(String userId) {
    return _rooms.values.where((room) => room.hostId == userId).toList();
  }

  /// 獲取用戶加入的房間
  List<Room> getUserJoinedRooms(String userId) {
    return _rooms.values
        .where((room) => room.participants.any((p) => p.id == userId))
        .toList();
  }

  /// 關閉房間
  void closeRoom(String roomId) {
    final room = _rooms[roomId];
    if (room != null) {
      room.status = RoomStatus.closed;
      _rooms.remove(roomId);
      _notifyRoomsChanged();
    }
  }

  void _notifyRoomsChanged() {
    _roomsController.add(_rooms.values.toList());
  }

  void dispose() {
    _roomsController.close();
  }
}
