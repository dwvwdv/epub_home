import 'dart:async';

import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/services/page_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const cfi = 'epubcfi(/6/4!/4/2/1:0)';

  group('PageSyncService', () {
    test('fails closed until presence contains the current reader', () async {
      final transport = FakePageSyncTransport();
      final service = createService(transport, currentCfi: cfi);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      final requested = await service.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );

      expect(requested, isFalse);
      expect(service.currentState.status, SyncStatus.idle);
      expect(
        service.currentState.errorMessage,
        contains('presence to synchronize'),
      );
      expect(transport.sentEvents, isEmpty);
    });

    test(
      'fails closed when a reading presence has no readiness field',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [
            readyUser('user-a'),
            {'user_id': 'legacy-reader', 'is_reading': true},
          ];
        final service = createService(transport, currentCfi: cfi);
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        final requested = await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );

        expect(requested, isFalse);
        expect(service.currentState.errorMessage, contains('become ready'));
      },
    );

    test('fails closed while any online reader is still loading', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [
          readyUser('user-a'),
          {'user_id': 'user-b', 'is_reading': true, 'reader_ready': false},
        ];
      final service = createService(transport, currentCfi: cfi);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      final requested = await service.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );

      expect(requested, isFalse);
      expect(service.currentState.errorMessage, contains('become ready'));
      expect(transport.sentEvents, isEmpty);
    });

    test(
      'frozen roster keeps a transitioning lobby member pending',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [
            readyUser('user-a'),
            readyUser('user-a'),
            readyUser('user-b'),
            readyUser('user-b'),
            {
              'user_id': 'lobby-user',
              'is_reading': false,
              'reader_ready': true,
            },
          ];
        final service = createService(transport, currentCfi: cfi);
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        final requested = await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );

        expect(requested, isFalse);
        expect(service.currentState.status, SyncStatus.idle);
        expect(service.currentState.errorMessage, contains('become ready'));
        expect(transport.sentEvents, isEmpty);
      },
    );

    test('explicit session leave removes a transitioning member', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [
          readyUser('user-a'),
          {'user_id': 'user-b', 'is_reading': false, 'reader_ready': false},
        ];
      final service = createService(transport, currentCfi: cfi);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      expect(
        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        ),
        isFalse,
      );

      transport.emit('reading_session_leave', {
        'session_id': 'session-1',
        'user_id': 'user-b',
      });
      await flushEvents();
      expect(
        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        ),
        isTrue,
      );
    });

    test(
      'self echo executes and commits a requester turn exactly once',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a')];
        final service = createService(transport, currentCfi: cfi);
        var turns = 0;
        var commits = 0;
        service.onPageTurn = (_) => turns++;
        service.onPositionCommit = (_) => commits++;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        await flushEvents();

        expect(turns, 1);
        expect(service.currentState.status, SyncStatus.turning);

        final execute = transport.sentEvents.singleWhere(
          (event) => event.event == 'page_turn_execute',
        );
        transport.emit('page_turn_execute', execute.payload);
        await flushEvents();
        expect(turns, 1);

        const targetCfi = 'epubcfi(/6/6)';
        service.updateReaderContext(isReady: true, currentCfi: targetCfi);
        final committed = await service.commitPagePosition(targetCfi);
        final acknowledged = await service.acknowledgePagePosition(targetCfi);
        await flushEvents();

        expect(committed, isTrue);
        expect(acknowledged, isTrue);
        expect(turns, 1);
        expect(commits, 1);
        expect(service.currentState.status, SyncStatus.idle);
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_turn_execute',
          ),
          hasLength(1),
        );
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_position_ack',
          ),
          hasLength(1),
        );
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_turn_complete',
          ),
          hasLength(1),
        );

        transport.emit('page_turn_execute', execute.payload);
        await flushEvents();
        expect(turns, 1);
      },
    );

    test(
      'ignores confirmations from users outside the required quorum',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        var turns = 0;
        service.onPageTurn = (_) => turns++;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;

        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'outsider',
        });
        await flushEvents();
        expect(service.currentState.currentRequest!.confirmedUserIds, {
          'user-a',
        });
        expect(turns, 0);

        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();
        expect(turns, 1);
      },
    );

    test('validates executor identity and direction', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final service = createService(
        transport,
        userId: 'user-b',
        nickname: 'Bob',
        currentCfi: cfi,
      );
      var turns = 0;
      var commits = 0;
      service.onPageTurn = (_) => turns++;
      service.onPositionCommit = (_) => commits++;
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      transport.emit(
        'page_turn_request',
        requestPayload(requestId: 'request-1', fromCfi: cfi),
      );
      await flushEvents();
      expect(service.currentState.status, SyncStatus.confirming);

      // Execute is invalid until this reader has explicitly confirmed.
      transport.emit('page_turn_execute', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'direction': 'next',
      });
      await flushEvents();
      expect(turns, 0);

      await service.confirmPageTurn();
      await flushEvents();

      transport.emit('page_turn_execute', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'direction': 'previous',
      });
      transport.emit('page_turn_execute', {
        'request_id': 'request-1',
        'requested_by_user_id': 'not-the-requester',
        'direction': 'next',
      });
      await flushEvents();
      expect(turns, 0);

      transport.emit('page_turn_execute', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'direction': 'next',
      });
      await flushEvents();
      expect(turns, 1);

      transport.emit('page_position_commit', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'direction': 'previous',
        'from_cfi': cfi,
        'target_cfi': 'epubcfi(/6/6)',
      });
      await flushEvents();
      expect(commits, 0);
      expect(service.currentState.status, SyncStatus.turning);

      transport.emit('page_position_commit', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'direction': 'next',
        'from_cfi': cfi,
        'target_cfi': 'epubcfi(/6/6)',
      });
      await flushEvents();
      expect(commits, 1);
      expect(service.currentState.status, SyncStatus.turning);

      const targetCfi = 'epubcfi(/6/6)';
      service.updateReaderContext(isReady: true, currentCfi: targetCfi);
      expect(await service.acknowledgePagePosition(targetCfi), isTrue);
      transport.emit('page_turn_complete', {
        'request_id': 'request-1',
        'requested_by_user_id': 'user-a',
        'completed_by_user_id': 'user-a',
        'direction': 'next',
        'from_cfi': cfi,
        'target_cfi': targetCfi,
      });
      await flushEvents();
      expect(service.currentState.status, SyncStatus.idle);
    });

    test(
      'requester waits for every display ack and completes only once',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        var turns = 0;
        service.onPageTurn = (_) => turns++;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();
        expect(turns, 1);

        const targetCfi = 'epubcfi(/6/8)';
        service.updateReaderContext(isReady: true, currentCfi: targetCfi);
        expect(await service.commitPagePosition(targetCfi), isTrue);
        expect(await service.acknowledgePagePosition(targetCfi), isTrue);
        await flushEvents();

        expect(service.currentState.status, SyncStatus.turning);
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_turn_complete',
          ),
          isEmpty,
        );

        transport.emit('page_position_ack', {
          'request_id': requestId,
          'user_id': 'user-b',
          'target_cfi': targetCfi,
        });
        transport.emit('page_position_ack', {
          'request_id': requestId,
          'user_id': 'user-b',
          'target_cfi': targetCfi,
        });
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_turn_complete',
          ),
          hasLength(1),
        );
        transport.emit('page_turn_execute', {
          'request_id': requestId,
          'requested_by_user_id': 'user-a',
          'direction': 'next',
        });
        await flushEvents();
        expect(turns, 1);
      },
    );

    test(
      'requester completes when an unacked reader leaves after commit',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();

        const targetCfi = 'epubcfi(/6/9)';
        service.updateReaderContext(isReady: true, currentCfi: targetCfi);
        expect(await service.commitPagePosition(targetCfi), isTrue);
        expect(await service.acknowledgePagePosition(targetCfi), isTrue);
        await flushEvents();
        expect(service.currentState.status, SyncStatus.turning);

        transport.onlineUsers = [readyUser('user-a')];
        transport.emitPresence({'event': 'leave'});
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        expect(
          transport.sentEvents.where(
            (event) => event.event == 'page_turn_complete',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'reader reconnect rejoins the roster for later page turns',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();

        const targetCfi = 'epubcfi(/6/13)';
        service.updateReaderContext(isReady: true, currentCfi: targetCfi);
        expect(await service.commitPagePosition(targetCfi), isTrue);
        expect(await service.acknowledgePagePosition(targetCfi), isTrue);

        transport.onlineUsers = [readyUser('user-a')];
        transport.emitPresence({'event': 'leave'});
        await flushEvents();
        expect(service.currentState.status, SyncStatus.idle);

        transport.onlineUsers = [
          readyUser('user-a'),
          {
            'user_id': 'user-b',
            'is_reading': true,
            'reader_ready': false,
          },
        ];
        transport.emitPresence({'event': 'sync'});
        await flushEvents();

        expect(
          await service.requestPageTurn(
            direction: PageTurnDirection.next,
            fromCfi: targetCfi,
          ),
          isFalse,
        );
        expect(service.currentState.errorMessage, contains('become ready'));
      },
    );

    test(
      'ignores a delayed confirmation from a reader that became unready',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        var turns = 0;
        service.onPageTurn = (_) => turns++;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.onlineUsers = [
          readyUser('user-a'),
          {'user_id': 'user-b', 'is_reading': true, 'reader_ready': false},
        ];
        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();

        expect(turns, 0);
        expect(service.currentState.currentRequest!.confirmedUserIds, {
          'user-a',
        });
      },
    );

    test(
      'execute timeout rolls the reader back and releases the lock',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a')];
        final service = createService(
          transport,
          currentCfi: cfi,
          requestTimeout: const Duration(milliseconds: 20),
        );
        final recoveries = <String>[];
        service.onPositionRecovery = recoveries.add;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        expect(service.currentState.status, SyncStatus.turning);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(service.currentState.status, SyncStatus.idle);
        expect(service.currentState.currentRequest, isNull);
        expect(service.currentState.errorMessage, contains('timed out'));
        expect(recoveries, [cfi]);
      },
    );

    test('database persistence pauses the ambiguous execute timeout', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final requester = createService(
        transport,
        currentCfi: cfi,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final follower = createService(
        transport,
        userId: 'user-b',
        nickname: 'Bob',
        currentCfi: cfi,
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(() async {
        await requester.dispose();
        await follower.dispose();
        await transport.dispose();
      });

      await requester.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );
      await flushEvents();
      expect(await follower.confirmPageTurn(), isTrue);
      await flushEvents();
      final requestId = requester.currentState.currentRequest!.requestId;
      expect(await requester.beginPositionPersistence(requestId), isTrue);
      await flushEvents();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(requester.currentState.status, SyncStatus.turning);
      expect(follower.currentState.status, SyncStatus.turning);
      expect(requester.currentState.currentRequest?.requestId, requestId);
      expect(follower.currentState.currentRequest?.requestId, requestId);

      requester.reportPositionPersistenceFailure(
        requestId: requestId,
        error: StateError('database unavailable'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await flushEvents();
      expect(requester.currentState.status, SyncStatus.idle);
      expect(follower.currentState.status, SyncStatus.idle);
      expect(requester.currentState.errorMessage, contains('timed out'));
    });

    test('missing display ack times out at the committed CFI', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final service = createService(
        transport,
        currentCfi: cfi,
        requestTimeout: const Duration(milliseconds: 20),
      );
      final recoveries = <String>[];
      service.onPositionRecovery = recoveries.add;
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      await service.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );
      final requestId = service.currentState.currentRequest!.requestId;
      transport.emit('page_turn_confirm', {
        'request_id': requestId,
        'user_id': 'user-b',
      });
      await flushEvents();

      const targetCfi = 'epubcfi(/6/10)';
      service.updateReaderContext(isReady: true, currentCfi: targetCfi);
      expect(await service.commitPagePosition(targetCfi), isTrue);
      await flushEvents();
      expect(service.currentState.status, SyncStatus.turning);

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(service.currentState.status, SyncStatus.idle);
      expect(service.currentState.errorMessage, contains('timed out'));
      expect(recoveries, [targetCfi]);
      expect(
        transport.sentEvents.where(
          (event) => event.event == 'page_turn_complete',
        ),
        isEmpty,
      );
    });

    test('database persistence failure remains retryable before commit', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a')];
      final service = createService(transport, currentCfi: cfi);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      await service.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );
      final requestId = service.currentState.currentRequest!.requestId;
      const targetCfi = 'epubcfi(/6/11)';
      service.updateReaderContext(isReady: true, currentCfi: targetCfi);
      service.reportPositionPersistenceFailure(
        requestId: requestId,
        error: StateError('database unavailable'),
      );

      expect(service.currentState.status, SyncStatus.turning);
      expect(service.currentState.currentRequest?.requestId, requestId);
      expect(service.currentState.errorMessage, contains('retrying'));
      expect(
        transport.sentEvents.where(
          (event) => event.event == 'page_position_commit',
        ),
        isEmpty,
      );

      expect(await service.commitPagePosition(targetCfi), isTrue);
      expect(await service.acknowledgePagePosition(targetCfi), isTrue);
      await flushEvents();
      expect(service.currentState.status, SyncStatus.idle);
    });

    test(
      'completion send failure keeps the committed CFI authoritative',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        final recoveries = <String>[];
        service.onPositionRecovery = recoveries.add;
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.emit('page_turn_confirm', {
          'request_id': requestId,
          'user_id': 'user-b',
        });
        await flushEvents();

        const targetCfi = 'epubcfi(/6/12)';
        service.updateReaderContext(isReady: true, currentCfi: targetCfi);
        expect(await service.commitPagePosition(targetCfi), isTrue);
        expect(await service.acknowledgePagePosition(targetCfi), isTrue);
        await flushEvents();
        transport.failingEvents.add('page_turn_complete');
        transport.emit('page_position_ack', {
          'request_id': requestId,
          'user_id': 'user-b',
          'target_cfi': targetCfi,
        });
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        expect(service.currentState.errorMessage, contains('complete'));
        expect(recoveries, [targetCfi]);
      },
    );

    test('arbitrates a lower request id while already waiting', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final service = createService(
        transport,
        userId: 'user-b',
        nickname: 'Bob',
        currentCfi: cfi,
      );
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      transport.emit(
        'page_turn_request',
        requestPayload(requestId: 'z-request', fromCfi: cfi),
      );
      await flushEvents();
      await service.confirmPageTurn();
      expect(service.currentState.status, SyncStatus.waiting);

      transport.emit(
        'page_turn_request',
        requestPayload(requestId: 'a-request', fromCfi: cfi),
      );
      await flushEvents();

      expect(service.currentState.status, SyncStatus.confirming);
      expect(service.currentState.currentRequest!.requestId, 'a-request');
    });

    test('network failure returns to idle with an actionable error', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a')]
        ..failingEvents.add('page_turn_request');
      final service = createService(transport, currentCfi: cfi);
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      final requested = await service.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );

      expect(requested, isFalse);
      expect(service.currentState.status, SyncStatus.idle);
      expect(service.currentState.currentRequest, isNull);
      expect(service.currentState.errorMessage, contains('network failure'));
    });

    test('execute failure returns idle but commit failure stays retryable', () async {
      final executeTransport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a')]
        ..failingEvents.add('page_turn_execute');
      final executeService = createService(executeTransport, currentCfi: cfi);
      addTearDown(() async {
        await executeService.dispose();
        await executeTransport.dispose();
      });

      final executed = await executeService.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );
      expect(executed, isFalse);
      expect(executeService.currentState.status, SyncStatus.idle);
      expect(executeService.currentState.errorMessage, contains('execute'));

      final commitTransport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a')];
      final commitService = createService(commitTransport, currentCfi: cfi);
      addTearDown(() async {
        await commitService.dispose();
        await commitTransport.dispose();
      });
      await commitService.requestPageTurn(
        direction: PageTurnDirection.next,
        fromCfi: cfi,
      );
      commitTransport.failingEvents.add('page_position_commit');

      final committed = await commitService.commitPagePosition('epubcfi(/6/6)');
      expect(committed, isFalse);
      expect(commitService.currentState.status, SyncStatus.turning);
      expect(commitService.currentState.currentRequest, isNotNull);
      expect(commitService.currentState.errorMessage, contains('retrying'));

      commitTransport.failingEvents.remove('page_position_commit');
      expect(
        await commitService.commitPagePosition('epubcfi(/6/6)'),
        isTrue,
      );
    });

    test('rejects a stale request and broadcasts cancellation', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final service = createService(
        transport,
        userId: 'user-b',
        nickname: 'Bob',
        currentCfi: cfi,
      );
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      transport.emit(
        'page_turn_request',
        requestPayload(requestId: 'stale-request', fromCfi: 'epubcfi(/6/2)'),
      );
      await flushEvents();

      expect(service.currentState.status, SyncStatus.idle);
      expect(
        transport.sentEvents.any(
          (event) =>
              event.event == 'page_turn_cancel' &&
              event.payload['request_id'] == 'stale-request',
        ),
        isTrue,
      );
    });

    test('rejects a request from another reading session', () async {
      final transport = FakePageSyncTransport()
        ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
      final service = createService(
        transport,
        userId: 'user-b',
        nickname: 'Bob',
        currentCfi: cfi,
      );
      addTearDown(() async {
        await service.dispose();
        await transport.dispose();
      });

      final payload = requestPayload(
        requestId: 'other-session-request',
        fromCfi: cfi,
      )..['session_id'] = 'session-2';
      transport.emit('page_turn_request', payload);
      await flushEvents();

      expect(service.currentState.currentRequest, isNull);
      expect(
        transport.sentEvents.any(
          (event) =>
              event.event == 'page_turn_cancel' &&
              event.payload['request_id'] == 'other-session-request',
        ),
        isTrue,
      );
    });

    test(
      'rejects an expired request after a reader session restarts',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(
          transport,
          userId: 'user-b',
          nickname: 'Bob',
          currentCfi: cfi,
        );
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        transport.emit(
          'page_turn_request',
          requestPayload(
            requestId: 'expired-request',
            fromCfi: cfi,
            requestedAt: DateTime.now().toUtc().subtract(
              const Duration(minutes: 1),
            ),
          ),
        );
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        expect(
          transport.sentEvents.any(
            (event) =>
                event.event == 'page_turn_cancel' &&
                event.payload['request_id'] == 'expired-request',
          ),
          isTrue,
        );
      },
    );

    test(
      'presence sync cancels when a required reader becomes unready',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a'), readyUser('user-b')];
        final service = createService(transport, currentCfi: cfi);
        addTearDown(() async {
          await service.dispose();
          await transport.dispose();
        });

        await service.requestPageTurn(
          direction: PageTurnDirection.next,
          fromCfi: cfi,
        );
        final requestId = service.currentState.currentRequest!.requestId;
        transport.onlineUsers = [
          readyUser('user-a'),
          {'user_id': 'user-b', 'is_reading': true, 'reader_ready': false},
        ];
        transport.emitPresence({'event': 'sync'});
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        expect(service.currentState.errorMessage, contains('not_ready'));
        expect(
          transport.sentEvents.any(
            (event) =>
                event.event == 'page_turn_cancel' &&
                event.payload['request_id'] == requestId,
          ),
          isTrue,
        );
      },
    );

    test(
      'dispose is idempotent, removes listeners, and ignores later events',
      () async {
        final transport = FakePageSyncTransport()
          ..onlineUsers = [readyUser('user-a')];
        final service = createService(transport, currentCfi: cfi);

        await service.dispose();
        await service.dispose();
        transport.emit(
          'page_turn_request',
          requestPayload(
            requestId: 'after-dispose',
            fromCfi: cfi,
            requiredUsers: const ['user-a'],
          ),
        );
        await flushEvents();

        expect(service.currentState.status, SyncStatus.idle);
        await transport.dispose();
      },
    );
  });
}

PageSyncService createService(
  FakePageSyncTransport transport, {
  String userId = 'user-a',
  String nickname = 'Alice',
  required String currentCfi,
  Duration requestTimeout = const Duration(seconds: 30),
}) {
  final service = PageSyncService(
    transport: transport,
    currentUserId: userId,
    currentNickname: nickname,
    readingSessionId: 'session-1',
    expectedParticipantUserIds: transport.onlineUsers
        .map((user) => user['user_id'])
        .whereType<String>()
        .toSet(),
    requestTimeout: requestTimeout,
  );
  service.updateReaderContext(isReady: true, currentCfi: currentCfi);
  service.initialize();
  return service;
}

Map<String, dynamic> readyUser(String userId) => {
  'user_id': userId,
  'nickname': userId,
  'is_reading': true,
  'reader_ready': true,
};

Map<String, dynamic> requestPayload({
  required String requestId,
  required String fromCfi,
  List<String> requiredUsers = const ['user-a', 'user-b'],
  DateTime? requestedAt,
}) {
  return {
    'session_id': 'session-1',
    'request_id': requestId,
    'user_id': 'user-a',
    'nickname': 'Alice',
    'direction': 'next',
    'from_cfi': fromCfi,
    'requested_at': (requestedAt ?? DateTime.now().toUtc()).toIso8601String(),
    'required_users': requiredUsers,
  };
}

Future<void> flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class SentEvent {
  final String event;
  final Map<String, dynamic> payload;

  const SentEvent(this.event, this.payload);
}

class FakePageSyncTransport implements PageSyncTransport {
  final Map<String, StreamController<Map<String, dynamic>>> _controllers = {};
  final StreamController<Map<String, dynamic>> _presenceController =
      StreamController<Map<String, dynamic>>.broadcast();

  List<Map<String, dynamic>> onlineUsers = [];
  final List<SentEvent> sentEvents = [];
  final Set<String> failingEvents = {};
  bool echo = true;

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) {
    return (_controllers[event] ??=
            StreamController<Map<String, dynamic>>.broadcast())
        .stream;
  }

  @override
  Stream<Map<String, dynamic>> get presenceStream => _presenceController.stream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() => onlineUsers;

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    if (failingEvents.contains(event)) {
      throw StateError('network failure for $event');
    }
    sentEvents.add(SentEvent(event, Map<String, dynamic>.from(payload)));
    if (echo) emit(event, payload);
  }

  void emit(String event, Map<String, dynamic> payload) {
    _controllers[event]?.add(Map<String, dynamic>.from(payload));
  }

  void emitPresence(Map<String, dynamic> event) {
    _presenceController.add(Map<String, dynamic>.from(event));
  }

  Future<void> dispose() async {
    await _presenceController.close();
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
