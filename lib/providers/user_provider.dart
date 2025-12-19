import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/user.dart';
import '../services/storage_service.dart';

class UserProvider extends ChangeNotifier {
  final StorageService _storageService;
  final _uuid = const Uuid();

  User? _currentUser;

  User? get currentUser => _currentUser;

  UserProvider({required StorageService storageService})
      : _storageService = storageService {
    _loadUser();
  }

  /// 加載用戶
  Future<void> _loadUser() async {
    _currentUser = _storageService.getCurrentUser();

    // 如果沒有用戶，創建一個
    if (_currentUser == null) {
      await _createDefaultUser();
    }

    notifyListeners();
  }

  /// 創建默認用戶
  Future<void> _createDefaultUser() async {
    final deviceId = _storageService.getDeviceId() ?? _uuid.v4();
    await _storageService.saveDeviceId(deviceId);

    _currentUser = User(
      id: _uuid.v4(),
      name: 'User_${deviceId.substring(0, 6)}',
      deviceId: deviceId,
    );

    await _storageService.saveCurrentUser(_currentUser!);
    notifyListeners();
  }

  /// 更新用戶名稱
  Future<void> updateUserName(String name) async {
    if (_currentUser == null) return;

    _currentUser = User(
      id: _currentUser!.id,
      name: name,
      deviceId: _currentUser!.deviceId,
      isHost: _currentUser!.isHost,
    );

    await _storageService.saveCurrentUser(_currentUser!);
    notifyListeners();
  }

  /// 設置為房主
  void setAsHost(bool isHost) {
    if (_currentUser == null) return;

    _currentUser = User(
      id: _currentUser!.id,
      name: _currentUser!.name,
      deviceId: _currentUser!.deviceId,
      isHost: isHost,
    );

    notifyListeners();
  }
}
