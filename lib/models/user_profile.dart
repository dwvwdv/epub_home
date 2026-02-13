class UserProfile {
  final String id;
  final String nickname;
  final int avatarColorIndex;
  final DateTime joinedAt;

  const UserProfile({
    required this.id,
    required this.nickname,
    this.avatarColorIndex = 0,
    required this.joinedAt,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    return UserProfile(
      id: json['user_id'] as String? ?? json['id'] as String,
      nickname: json['nickname'] as String,
      avatarColorIndex: json['avatar_color_index'] as int? ?? 0,
      joinedAt: json['joined_at'] != null
          ? DateTime.parse(json['joined_at'] as String)
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'user_id': id,
      'nickname': nickname,
      'avatar_color_index': avatarColorIndex,
      'joined_at': joinedAt.toIso8601String(),
    };
  }

  UserProfile copyWith({
    String? id,
    String? nickname,
    int? avatarColorIndex,
    DateTime? joinedAt,
  }) {
    return UserProfile(
      id: id ?? this.id,
      nickname: nickname ?? this.nickname,
      avatarColorIndex: avatarColorIndex ?? this.avatarColorIndex,
      joinedAt: joinedAt ?? this.joinedAt,
    );
  }
}
