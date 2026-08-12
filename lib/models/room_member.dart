class RoomMember {
  final String id;
  final String roomId;
  final String userId;
  final String nickname;
  final int avatarColorIndex;
  final bool hasBook;
  final String? readyBookHash;
  final bool isOnline;
  final DateTime joinedAt;
  final DateTime? lastSeenAt;

  const RoomMember({
    required this.id,
    required this.roomId,
    required this.userId,
    required this.nickname,
    this.avatarColorIndex = 0,
    this.hasBook = false,
    this.readyBookHash,
    this.isOnline = false,
    required this.joinedAt,
    this.lastSeenAt,
  });

  factory RoomMember.fromJson(Map<String, dynamic> json) {
    return RoomMember(
      id: json['id'] as String? ?? '',
      roomId: json['room_id'] as String? ?? '',
      userId: json['user_id'] as String,
      nickname: json['nickname'] as String,
      avatarColorIndex: json['avatar_color_index'] as int? ?? 0,
      hasBook: json['has_book'] as bool? ?? false,
      readyBookHash: json['ready_book_hash'] as String?,
      isOnline: json['is_online'] as bool? ?? false,
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : DateTime.now(),
      lastSeenAt: json['last_seen_at'] != null
          ? DateTime.parse(json['last_seen_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'room_id': roomId,
      'user_id': userId,
      'nickname': nickname,
      'avatar_color_index': avatarColorIndex,
      'has_book': hasBook,
      'ready_book_hash': readyBookHash,
      'joined_at': joinedAt.toIso8601String(),
      'last_seen_at': lastSeenAt?.toIso8601String(),
    };
  }

  RoomMember copyWith({
    bool? hasBook,
    String? readyBookHash,
    bool? isOnline,
    int? avatarColorIndex,
    DateTime? lastSeenAt,
  }) {
    return RoomMember(
      id: id,
      roomId: roomId,
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      hasBook: hasBook ?? this.hasBook,
      readyBookHash: readyBookHash ?? this.readyBookHash,
      isOnline: isOnline ?? this.isOnline,
      joinedAt: joinedAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }
}
