import 'package:get_it/get_it.dart';
import '../services/epub_service.dart';
import '../services/storage_service.dart';
import '../services/room_service.dart';
import '../services/sync_service.dart';
import '../services/network_service.dart';
import '../providers/book_provider.dart';
import '../providers/room_provider.dart';
import '../providers/user_provider.dart';

final getIt = GetIt.instance;

Future<void> setupDependencyInjection() async {
  // Services
  getIt.registerLazySingleton(() => EpubService());
  getIt.registerLazySingleton(() => StorageService());
  getIt.registerLazySingleton(() => RoomService());
  getIt.registerLazySingleton(() => SyncService());
  getIt.registerLazySingleton(() => NetworkService());

  // Initialize storage service
  await getIt<StorageService>().initialize();

  // Providers
  getIt.registerLazySingleton(
    () => BookProvider(
      epubService: getIt<EpubService>(),
      storageService: getIt<StorageService>(),
    ),
  );

  getIt.registerLazySingleton(
    () => RoomProvider(
      roomService: getIt<RoomService>(),
      syncService: getIt<SyncService>(),
    ),
  );

  getIt.registerLazySingleton(
    () => UserProvider(
      storageService: getIt<StorageService>(),
    ),
  );
}
