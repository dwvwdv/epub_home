class Room {
  final String id;
  final String code;
  final String hostUserId;
  final String? channelId;
  final String? currentBookTitle;
  final String? currentBookHash;
  final String? currentCfi;
  final bool isActive;
  final DateTime? closedAt;
  final DateTime? expiresAt;
  final DateTime? lastActivityAt;
  final int revision;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Room({
    required this.id,
    required this.code,
    required this.hostUserId,
    this.channelId,
    this.currentBookTitle,
    this.currentBookHash,
    this.currentCfi,
    this.isActive = true,
    this.closedAt,
    this.expiresAt,
    this.lastActivityAt,
    this.revision = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      code: json['code'] as String,
      hostUserId: json['host_user_id'] as String,
      channelId: json['channel_id'] as String?,
      currentBookTitle: json['current_book_title'] as String?,
      currentBookHash: json['current_book_hash'] as String?,
      currentCfi: json['current_cfi'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      closedAt: json['closed_at'] != null
          ? DateTime.parse(json['closed_at'] as String)
          : null,
      expiresAt: json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      lastActivityAt: json['last_activity_at'] != null
          ? DateTime.parse(json['last_activity_at'] as String)
          : null,
      revision: (json['revision'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'host_user_id': hostUserId,
      'channel_id': channelId,
      'current_book_title': currentBookTitle,
      'current_book_hash': currentBookHash,
      'current_cfi': currentCfi,
      'is_active': isActive,
      'closed_at': closedAt?.toIso8601String(),
      'expires_at': expiresAt?.toIso8601String(),
      'last_activity_at': lastActivityAt?.toIso8601String(),
      'revision': revision,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Room copyWith({
    String? id,
    String? code,
    String? hostUserId,
    String? channelId,
    String? currentBookTitle,
    String? currentBookHash,
    String? currentCfi,
    bool? isActive,
    DateTime? closedAt,
    DateTime? expiresAt,
    DateTime? lastActivityAt,
    int? revision,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Room(
      id: id ?? this.id,
      code: code ?? this.code,
      hostUserId: hostUserId ?? this.hostUserId,
      channelId: channelId ?? this.channelId,
      currentBookTitle: currentBookTitle ?? this.currentBookTitle,
      currentBookHash: currentBookHash ?? this.currentBookHash,
      currentCfi: currentCfi ?? this.currentCfi,
      isActive: isActive ?? this.isActive,
      closedAt: closedAt ?? this.closedAt,
      expiresAt: expiresAt ?? this.expiresAt,
      lastActivityAt: lastActivityAt ?? this.lastActivityAt,
      revision: revision ?? this.revision,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
