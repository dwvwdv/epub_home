enum PageTurnDirection { next, previous }

String pageTurnDirectionToWire(PageTurnDirection direction) {
  return direction == PageTurnDirection.next ? 'next' : 'previous';
}

PageTurnDirection? pageTurnDirectionFromWire(Object? value) {
  return switch (value) {
    'next' => PageTurnDirection.next,
    'previous' => PageTurnDirection.previous,
    _ => null,
  };
}

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
  final String fromCfi;
  final DateTime requestedAt;
  final Set<String> confirmedUserIds;
  final Set<String> requiredUserIds;

  const PageTurnRequest({
    required this.requestId,
    required this.requestedByUserId,
    required this.requestedByNickname,
    required this.direction,
    required this.fromCfi,
    required this.requestedAt,
    required this.confirmedUserIds,
    required this.requiredUserIds,
  });

  bool get isConsensusReached =>
      requiredUserIds.isNotEmpty &&
      requiredUserIds.every(confirmedUserIds.contains);

  Set<String> get pendingUserIds =>
      requiredUserIds.difference(confirmedUserIds);

  int get validConfirmationCount =>
      confirmedUserIds.intersection(requiredUserIds).length;

  double get progress => requiredUserIds.isEmpty
      ? 0
      : validConfirmationCount / requiredUserIds.length;

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
      'direction': pageTurnDirectionToWire(direction),
      'from_cfi': fromCfi,
      'requested_at': requestedAt.toUtc().toIso8601String(),
      'required_users': requiredUserIds.toList()..sort(),
    };
  }

  factory PageTurnRequest.fromJson(Map<String, dynamic> json) {
    final direction = pageTurnDirectionFromWire(json['direction']);
    if (direction == null) {
      throw const FormatException('Invalid page turn direction');
    }

    final requestId = json['request_id'];
    final requestedByUserId = json['user_id'];
    final fromCfi = json['from_cfi'];
    final rawRequestedAt = json['requested_at'];
    final requestedAt = rawRequestedAt is String
        ? DateTime.tryParse(rawRequestedAt)
        : null;
    if (requestId is! String ||
        requestId.isEmpty ||
        requestedByUserId is! String ||
        requestedByUserId.isEmpty ||
        fromCfi is! String ||
        fromCfi.isEmpty ||
        requestedAt == null) {
      throw const FormatException('Invalid page turn request');
    }

    final rawRequiredUsers = json['required_users'];
    if (rawRequiredUsers is! List) {
      throw const FormatException('Invalid required users');
    }

    final requiredUserIds = rawRequiredUsers.whereType<String>().toSet();
    if (requiredUserIds.length != rawRequiredUsers.length ||
        !requiredUserIds.contains(requestedByUserId)) {
      throw const FormatException('Invalid required users');
    }

    return PageTurnRequest(
      requestId: requestId,
      requestedByUserId: requestedByUserId,
      requestedByNickname: json['nickname'] is String
          ? json['nickname'] as String
          : 'Unknown',
      direction: direction,
      fromCfi: fromCfi,
      requestedAt: requestedAt,
      confirmedUserIds: {requestedByUserId},
      requiredUserIds: requiredUserIds,
    );
  }
}

class PageTurnCommand {
  final String requestId;
  final PageTurnDirection direction;
  final String fromCfi;
  final bool isRequester;

  const PageTurnCommand({
    required this.requestId,
    required this.direction,
    required this.fromCfi,
    required this.isRequester,
  });
}

class PagePositionCommit {
  final String requestId;
  final String requestedByUserId;
  final PageTurnDirection direction;
  final String fromCfi;
  final String targetCfi;

  const PagePositionCommit({
    required this.requestId,
    required this.requestedByUserId,
    required this.direction,
    required this.fromCfi,
    required this.targetCfi,
  });

  Map<String, dynamic> toJson() {
    return {
      'request_id': requestId,
      'requested_by_user_id': requestedByUserId,
      'direction': pageTurnDirectionToWire(direction),
      'from_cfi': fromCfi,
      'target_cfi': targetCfi,
    };
  }
}

class PageSyncState {
  final SyncStatus status;
  final PageTurnRequest? currentRequest;
  final String? errorMessage;

  const PageSyncState({
    this.status = SyncStatus.idle,
    this.currentRequest,
    this.errorMessage,
  });

  const PageSyncState.idle()
      : status = SyncStatus.idle,
        currentRequest = null,
        errorMessage = null;

  const PageSyncState.error(String message)
      : status = SyncStatus.idle,
        currentRequest = null,
        errorMessage = message;

  int get validConfirmationCount =>
      currentRequest?.validConfirmationCount ?? 0;

  PageSyncState copyWith({
    SyncStatus? status,
    PageTurnRequest? currentRequest,
    String? errorMessage,
    bool clearCurrentRequest = false,
    bool clearError = false,
  }) {
    return PageSyncState(
      status: status ?? this.status,
      currentRequest:
          clearCurrentRequest ? null : currentRequest ?? this.currentRequest,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}
