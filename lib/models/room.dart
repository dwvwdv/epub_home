import 'book.dart';
import 'user.dart';

enum RoomStatus {
  waiting,
  reading,
  syncing,
  closed,
}

enum PageStatus {
  viewing, // 正在查看當前頁
  readyToTurn, // 準備翻頁
  waiting, // 等待其他人
}

class Room {
  final String id;
  final String name;
  final String hostId;
  final Book book;
  final List<User> participants;
  RoomStatus status;
  Map<String, PageStatus> pageStatuses;
  int currentPage;

  Room({
    required this.id,
    required this.name,
    required this.hostId,
    required this.book,
    required this.participants,
    this.status = RoomStatus.waiting,
    Map<String, PageStatus>? pageStatuses,
    this.currentPage = 0,
  }) : pageStatuses = pageStatuses ?? {};

  bool get isAllReady {
    if (participants.isEmpty) return false;
    return participants.every(
      (user) => pageStatuses[user.id] == PageStatus.readyToTurn,
    );
  }

  int get readyCount {
    return participants
        .where((user) => pageStatuses[user.id] == PageStatus.readyToTurn)
        .length;
  }

  int get totalCount => participants.length;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'hostId': hostId,
        'book': book.toJson(),
        'participants': participants.map((u) => u.toJson()).toList(),
        'status': status.name,
        'pageStatuses': pageStatuses.map(
          (key, value) => MapEntry(key, value.name),
        ),
        'currentPage': currentPage,
      };

  factory Room.fromJson(Map<String, dynamic> json) => Room(
        id: json['id'] as String,
        name: json['name'] as String,
        hostId: json['hostId'] as String,
        book: Book.fromJson(json['book'] as Map<String, dynamic>),
        participants: (json['participants'] as List)
            .map((u) => User.fromJson(u as Map<String, dynamic>))
            .toList(),
        status: RoomStatus.values.firstWhere(
          (e) => e.name == json['status'],
          orElse: () => RoomStatus.waiting,
        ),
        pageStatuses: (json['pageStatuses'] as Map<String, dynamic>).map(
          (key, value) => MapEntry(
            key,
            PageStatus.values.firstWhere((e) => e.name == value),
          ),
        ),
        currentPage: json['currentPage'] as int? ?? 0,
      );
}
