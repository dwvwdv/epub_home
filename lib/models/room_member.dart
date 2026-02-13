class RoomMember {
  final String id;
  final String roomId;
  final String userId;
  final String nickname;
  final int avatarColorIndex;
  final bool hasBook;
  final bool isOnline;
  final DateTime joinedAt;

  const RoomMember({
    required this.id,
    required this.roomId,
    required this.userId,
    required this.nickname,
    this.avatarColorIndex = 0,
    this.hasBook = false,
    this.isOnline = false,
    required this.joinedAt,
  });

  factory RoomMember.fromJson(Map<String, dynamic> json) {
    return RoomMember(
      id: json['id'] as String? ?? '',
      roomId: json['room_id'] as String? ?? '',
      userId: json['user_id'] as String,
      nickname: json['nickname'] as String,
      avatarColorIndex: json['avatar_color_index'] as int? ?? 0,
      hasBook: json['has_book'] as bool? ?? false,
      isOnline: json['is_online'] as bool? ?? false,
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : DateTime.now(),
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
      'joined_at': joinedAt.toIso8601String(),
    };
  }

  RoomMember copyWith({
    bool? hasBook,
    bool? isOnline,
    int? avatarColorIndex,
  }) {
    return RoomMember(
      id: id,
      roomId: roomId,
      userId: userId,
      nickname: nickname,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      hasBook: hasBook ?? this.hasBook,
      isOnline: isOnline ?? this.isOnline,
      joinedAt: joinedAt,
    );
  }
}
