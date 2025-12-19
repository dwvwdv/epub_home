class User {
  final String id;
  final String name;
  final String deviceId;
  final bool isHost;

  User({
    required this.id,
    required this.name,
    required this.deviceId,
    this.isHost = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'deviceId': deviceId,
        'isHost': isHost,
      };

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        name: json['name'] as String,
        deviceId: json['deviceId'] as String,
        isHost: json['isHost'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is User && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
