import 'dart:async';
import 'dart:io';
import 'package:multicast_dns/multicast_dns.dart';

class NetworkService {
  static const String _serviceType = '_epubhome._tcp';
  static const int _port = 8888;

  MDnsClient? _mdnsClient;
  final Map<String, DiscoveredDevice> _discoveredDevices = {};
  final StreamController<List<DiscoveredDevice>> _devicesController =
      StreamController<List<DiscoveredDevice>>.broadcast();

  Stream<List<DiscoveredDevice>> get devicesStream => _devicesController.stream;

  /// 啟動 mDNS 服務發現
  Future<void> startDiscovery() async {
    try {
      _mdnsClient = MDnsClient();
      await _mdnsClient!.start();

      // 持續搜索設備
      await for (final PtrResourceRecord ptr
          in _mdnsClient!.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(_serviceType),
      )) {
        await for (final SrvResourceRecord srv
            in _mdnsClient!.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(ptr.domainName),
        )) {
          // 獲取 IP 地址
          await for (final IPAddressResourceRecord ip
              in _mdnsClient!.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
          )) {
            final device = DiscoveredDevice(
              name: ptr.domainName,
              host: ip.address.address,
              port: srv.port,
            );

            _discoveredDevices[device.id] = device;
            _notifyDevicesChanged();
          }
        }
      }
    } catch (e) {
      print('Failed to start mDNS discovery: $e');
    }
  }

  /// 廣播本地服務
  Future<void> advertiseService({
    required String deviceName,
    required String roomId,
  }) async {
    try {
      if (_mdnsClient == null) {
        _mdnsClient = MDnsClient();
        await _mdnsClient!.start();
      }

      // 廣播服務
      final serviceName = '$deviceName.$_serviceType.local';

      // 注意：multicast_dns 包目前不支持直接廣播服務
      // 這裡需要使用其他方式或自定義實現
      // 暫時作為佔位符
      print('Advertising service: $serviceName on port $_port');
    } catch (e) {
      print('Failed to advertise service: $e');
    }
  }

  /// 停止發現
  Future<void> stopDiscovery() async {
    _mdnsClient?.stop();
    _mdnsClient = null;
    _discoveredDevices.clear();
    _notifyDevicesChanged();
  }

  /// 獲取已發現的設備
  List<DiscoveredDevice> getDiscoveredDevices() =>
      _discoveredDevices.values.toList();

  void _notifyDevicesChanged() {
    _devicesController.add(_discoveredDevices.values.toList());
  }

  /// 獲取本機 IP 地址
  Future<String?> getLocalIpAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          // 排除 localhost
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Failed to get local IP: $e');
    }
    return null;
  }

  void dispose() {
    stopDiscovery();
    _devicesController.close();
  }
}

class DiscoveredDevice {
  final String name;
  final String host;
  final int port;

  DiscoveredDevice({
    required this.name,
    required this.host,
    required this.port,
  });

  String get id => '$host:$port';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DiscoveredDevice &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
