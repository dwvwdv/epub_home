import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/widgets/sync_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a synchronization error instead of a false synced state',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState.error('Realtime is unavailable'),
          onlineUsers: [],
        ),
      ),
    ));

    expect(find.text('Realtime is unavailable'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
  });

  testWidgets('counts unique ready readers only', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: const PageSyncState.idle(),
          onlineUsers: [
            readyUser('user-a'),
            readyUser('user-a'),
            readyUser('user-b'),
            {
              'user_id': 'lobby-user',
              'is_reading': false,
              'reader_ready': true,
            },
            {
              'user_id': 'loading-user',
              'is_reading': true,
              'reader_ready': false,
            },
          ],
        ),
      ),
    ));

    expect(find.text('2 readers ready'), findsOneWidget);
  });

  testWidgets('confirmation progress ignores spoofed non-quorum ids',
      (tester) async {
    final request = PageTurnRequest(
      requestId: 'request-1',
      requestedByUserId: 'user-a',
      requestedByNickname: 'Alice',
      direction: PageTurnDirection.next,
      fromCfi: 'epubcfi(/6/4)',
      requestedAt: DateTime.now(),
      confirmedUserIds: const {'user-a', 'outsider'},
      requiredUserIds: const {'user-a', 'user-b'},
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState(
            status: SyncStatus.requesting,
            currentRequest: request,
          ),
          onlineUsers: [readyUser('user-a'), readyUser('user-b')],
        ),
      ),
    ));

    expect(find.text('1/2'), findsOneWidget);
  });
}

Map<String, dynamic> readyUser(String userId) => {
      'user_id': userId,
      'nickname': userId,
      'is_reading': true,
      'reader_ready': true,
    };
