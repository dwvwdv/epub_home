class Room {
  final String id;
  final String code;
  final String hostUserId;
  final String? currentBookTitle;
  final String? currentBookHash;
  final String? currentCfi;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Room({
    required this.id,
    required this.code,
    required this.hostUserId,
    this.currentBookTitle,
    this.currentBookHash,
    this.currentCfi,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Room.fromJson(Map<String, dynamic> json) {
    return Room(
      id: json['id'] as String,
      code: json['code'] as String,
      hostUserId: json['host_user_id'] as String,
      currentBookTitle: json['current_book_title'] as String?,
      currentBookHash: json['current_book_hash'] as String?,
      currentCfi: json['current_cfi'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'code': code,
      'host_user_id': hostUserId,
      'current_book_title': currentBookTitle,
      'current_book_hash': currentBookHash,
      'current_cfi': currentCfi,
      'is_active': isActive,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  Room copyWith({
    String? id,
    String? code,
    String? hostUserId,
    String? currentBookTitle,
    String? currentBookHash,
    String? currentCfi,
    bool? isActive,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Room(
      id: id ?? this.id,
      code: code ?? this.code,
      hostUserId: hostUserId ?? this.hostUserId,
      currentBookTitle: currentBookTitle ?? this.currentBookTitle,
      currentBookHash: currentBookHash ?? this.currentBookHash,
      currentCfi: currentCfi ?? this.currentCfi,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
