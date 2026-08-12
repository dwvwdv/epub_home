import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/services/epub_storage_service.dart';
import 'package:cotime_book/services/file_transfer_service.dart';
import 'package:cotime_book/services/realtime_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('initialize installs a single book chunk subscription', () async {
    final realtime = RealtimeService(
      channelFactory: (_, __) => throw StateError('not used'),
    );
    final transfer = FileTransferService(
      realtimeService: realtime,
      storageService: EpubStorageService(),
      currentUserId: 'alice',
    );

    transfer.initialize();
    transfer.initialize();

    expect(transfer.subscriptionCount, 1);
    await transfer.dispose();
    expect(transfer.subscriptionCount, 0);
    await realtime.close();
  });

  test('sendBook rejects a file larger than the configured limit', () async {
    final realtime = RealtimeService(
      channelFactory: (_, __) => throw StateError('not used'),
    );
    final transfer = FileTransferService(
      realtimeService: realtime,
      storageService: EpubStorageService(),
      currentUserId: 'alice',
    );

    await expectLater(
      transfer.sendBook(
        fileBytes: Uint8List(AppConstants.maxFileSize + 1),
        bookHash: List.filled(64, '0').join(),
      ),
      throwsArgumentError,
    );
    await transfer.dispose();
    await realtime.close();
  });
}
