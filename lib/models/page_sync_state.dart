enum PageTurnDirection { next, previous }

enum SyncStatus {
  idle,
  requesting,
  confirming,
  waiting,
  turning,
}

class PageTurnRequest {
  final String requestId;
  final String requestedByUserId;
  final String requestedByNickname;
  final PageTurnDirection direction;
  final String? fromCfi;
  final DateTime requestedAt;
  final Set<String> confirmedUserIds;
  final Set<String> requiredUserIds;

  const PageTurnRequest({
    required this.requestId,
    required this.requestedByUserId,
    required this.requestedByNickname,
    required this.direction,
    this.fromCfi,
    required this.requestedAt,
    required this.confirmedUserIds,
    required this.requiredUserIds,
  });

  bool get isConsensusReached =>
      requiredUserIds.isNotEmpty &&
      requiredUserIds.every((id) => confirmedUserIds.contains(id));

  Set<String> get pendingUserIds =>
      requiredUserIds.difference(confirmedUserIds);

  double get progress =>
      requiredUserIds.isEmpty ? 0 : confirmedUserIds.length / requiredUserIds.length;

  PageTurnRequest copyWith({
    Set<String>? confirmedUserIds,
    Set<String>? requiredUserIds,
  }) {
    return PageTurnRequest(
      requestId: requestId,
      requestedByUserId: requestedByUserId,
      requestedByNickname: requestedByNickname,
      direction: direction,
      fromCfi: fromCfi,
      requestedAt: requestedAt,
      confirmedUserIds: confirmedUserIds ?? this.confirmedUserIds,
      requiredUserIds: requiredUserIds ?? this.requiredUserIds,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'request_id': requestId,
      'user_id': requestedByUserId,
      'nickname': requestedByNickname,
      'direction': direction == PageTurnDirection.next ? 'next' : 'previous',
      'from_cfi': fromCfi,
      'required_users': requiredUserIds.toList(),
    };
  }

  factory PageTurnRequest.fromJson(Map<String, dynamic> json) {
    return PageTurnRequest(
      requestId: json['request_id'] as String,
      requestedByUserId: json['user_id'] as String,
      requestedByNickname: json['nickname'] as String? ?? 'Unknown',
      direction: json['direction'] == 'next'
          ? PageTurnDirection.next
          : PageTurnDirection.previous,
      fromCfi: json['from_cfi'] as String?,
      requestedAt: DateTime.now(),
      confirmedUserIds: {json['user_id'] as String},
      requiredUserIds: Set<String>.from(
        (json['required_users'] as List<dynamic>?)?.cast<String>() ?? [],
      ),
    );
  }
}

class PageSyncState {
  final SyncStatus status;
  final PageTurnRequest? currentRequest;

  const PageSyncState({
    this.status = SyncStatus.idle,
    this.currentRequest,
  });

  const PageSyncState.idle()
      : status = SyncStatus.idle,
        currentRequest = null;

  PageSyncState copyWith({
    SyncStatus? status,
    PageTurnRequest? currentRequest,
  }) {
    return PageSyncState(
      status: status ?? this.status,
      currentRequest: currentRequest ?? this.currentRequest,
    );
  }
}
