import 'package:flutter/foundation.dart';
import '../models/room.dart';
import '../models/user.dart';
import '../models/book.dart';
import '../services/room_service.dart';
import '../services/sync_service.dart';

class RoomProvider extends ChangeNotifier {
  final RoomService _roomService;
  final SyncService _syncService;

  Room? _currentRoom;
  List<Room> _rooms = [];
  bool _isWaitingForSync = false;
  String? _error;

  Room? get currentRoom => _currentRoom;
  List<Room> get rooms => _rooms;
  bool get isWaitingForSync => _isWaitingForSync;
  String? get error => _error;

  RoomProvider({
    required RoomService roomService,
    required SyncService syncService,
  })  : _roomService = roomService,
        _syncService = syncService {
    _listenToRoomChanges();
  }

  void _listenToRoomChanges() {
    _roomService.roomsStream.listen((rooms) {
      _rooms = rooms;
      notifyListeners();
    });
  }

  /// 創建房間
  Room createRoom({
    required String name,
    required User host,
    required Book book,
  }) {
    final room = _roomService.createRoom(
      name: name,
      host: host,
      book: book,
    );

    _currentRoom = room;
    notifyListeners();

    return room;
  }

  /// 加入房間
  Future<bool> joinRoom({
    required String roomId,
    required User user,
  }) async {
    final success = _roomService.joinRoom(
      roomId: roomId,
      user: user,
    );

    if (success) {
      _currentRoom = _roomService.getRoom(roomId);
      notifyListeners();
    }

    return success;
  }

  /// 離開房間
  Future<void> leaveRoom({
    required String roomId,
    required String userId,
  }) async {
    _roomService.leaveRoom(
      roomId: roomId,
      userId: userId,
    );

    if (_currentRoom?.id == roomId) {
      _currentRoom = null;
    }

    notifyListeners();
  }

  /// 請求翻頁
  Future<void> requestPageTurn({
    required User user,
    required int targetPage,
  }) async {
    if (_currentRoom == null) return;

    _isWaitingForSync = true;
    _error = null;
    notifyListeners();

    // 更新本地狀態
    _roomService.updatePageStatus(
      roomId: _currentRoom!.id,
      userId: user.id,
      status: PageStatus.readyToTurn,
    );

    try {
      // 輪詢等待所有人確認
      await for (final response in _syncService.pollPageTurnStatus(
        roomKey: _currentRoom!.id,
        user: user,
        targetPage: targetPage,
      )) {
        if (response.status == PageTurnStatus.ready) {
          // 所有人已確認，執行翻頁
          _roomService.setRoomCurrentPage(
            roomId: _currentRoom!.id,
            page: targetPage,
          );

          _isWaitingForSync = false;
          notifyListeners();
          break;
        } else if (response.status == PageTurnStatus.error) {
          _error = response.error;
          _isWaitingForSync = false;
          notifyListeners();
          break;
        }
      }
    } catch (e) {
      _error = e.toString();
      _isWaitingForSync = false;
      notifyListeners();
    }
  }

  /// 取消翻頁請求
  Future<void> cancelPageTurn(User user) async {
    if (_currentRoom == null) return;

    await _syncService.cancelPageTurn(
      roomKey: _currentRoom!.id,
      user: user,
    );

    _roomService.updatePageStatus(
      roomId: _currentRoom!.id,
      userId: user.id,
      status: PageStatus.viewing,
    );

    _isWaitingForSync = false;
    notifyListeners();
  }

  /// 獲取用戶的房間
  List<Room> getUserRooms(String userId) {
    return _roomService.getUserJoinedRooms(userId);
  }

  /// 關閉房間
  void closeRoom(String roomId) {
    _roomService.closeRoom(roomId);

    if (_currentRoom?.id == roomId) {
      _currentRoom = null;
    }

    notifyListeners();
  }
}
