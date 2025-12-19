import 'dart:async';
import 'package:dio/dio.dart';
import '../models/user.dart';

class SyncService {
  final Dio _dio = Dio();
  static const String _webhookBaseUrl = 'https://n8n.lazyrhythm.com/webhook';

  /// 發送翻頁請求
  Future<PageTurnResponse> requestPageTurn({
    required String roomKey,
    required User user,
    required int currentPage,
    required int targetPage,
  }) async {
    try {
      final response = await _dio.post(
        '$_webhookBaseUrl/$roomKey',
        data: {
          'action': 'page_turn',
          'userId': user.id,
          'userName': user.name,
          'currentPage': currentPage,
          'targetPage': targetPage,
          'timestamp': DateTime.now().toIso8601String(),
        },
        options: Options(
          headers: {'Content-Type': 'application/json'},
          validateStatus: (status) => status! < 500,
        ),
      );

      if (response.statusCode == 200) {
        // 所有人已確認，可以翻頁
        return PageTurnResponse(
          status: PageTurnStatus.ready,
          targetPage: response.data['targetPage'] as int,
          participants: (response.data['participants'] as List?)
                  ?.map((p) => ParticipantStatus.fromJson(p))
                  .toList() ??
              [],
        );
      } else if (response.statusCode == 202) {
        // 等待中
        return PageTurnResponse(
          status: PageTurnStatus.waiting,
          confirmedUsers: (response.data['confirmedUsers'] as List?)
                  ?.map((id) => id.toString())
                  .toList() ??
              [],
          waitingUsers: (response.data['waitingUsers'] as List?)
                  ?.map((id) => id.toString())
                  .toList() ??
              [],
        );
      } else {
        throw Exception('Unexpected status code: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Failed to request page turn: $e');
    }
  }

  /// 輪詢檢查是否所有人都準備好
  Stream<PageTurnResponse> pollPageTurnStatus({
    required String roomKey,
    required User user,
    required int targetPage,
    Duration interval = const Duration(seconds: 1),
  }) async* {
    while (true) {
      try {
        final response = await requestPageTurn(
          roomKey: roomKey,
          user: user,
          currentPage: targetPage - 1,
          targetPage: targetPage,
        );

        yield response;

        if (response.status == PageTurnStatus.ready) {
          break;
        }

        await Future.delayed(interval);
      } catch (e) {
        yield PageTurnResponse(
          status: PageTurnStatus.error,
          error: e.toString(),
        );
        break;
      }
    }
  }

  /// 取消翻頁請求
  Future<void> cancelPageTurn({
    required String roomKey,
    required User user,
  }) async {
    try {
      await _dio.post(
        '$_webhookBaseUrl/$roomKey',
        data: {
          'action': 'cancel_page_turn',
          'userId': user.id,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );
    } catch (e) {
      // 忽略取消失敗
    }
  }
}

enum PageTurnStatus {
  waiting,
  ready,
  error,
}

class PageTurnResponse {
  final PageTurnStatus status;
  final int? targetPage;
  final List<ParticipantStatus>? participants;
  final List<String>? confirmedUsers;
  final List<String>? waitingUsers;
  final String? error;

  PageTurnResponse({
    required this.status,
    this.targetPage,
    this.participants,
    this.confirmedUsers,
    this.waitingUsers,
    this.error,
  });
}

class ParticipantStatus {
  final String userId;
  final bool confirmed;

  ParticipantStatus({
    required this.userId,
    required this.confirmed,
  });

  factory ParticipantStatus.fromJson(Map<String, dynamic> json) =>
      ParticipantStatus(
        userId: json['userId'] as String,
        confirmed: json['confirmed'] as bool,
      );
}
