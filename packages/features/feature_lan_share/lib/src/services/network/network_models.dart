// LAN Feature 只保留旧调用点所需的本地命名；实际网络契约归属
// package:network_sdk/network_sdk.dart。

import 'package:network_sdk/network_sdk.dart';

export 'package:network_sdk/network_sdk.dart';

typedef NetworkResult<T> = SdkResult<T>;
typedef NetworkSuccess<T> = SdkSuccess<T>;
typedef NetworkFailure<T> = SdkFailure<T>;
typedef NetworkServiceDisposedException = SdkClientDisposedException;
typedef NetworkRuntimeConfig = SdkRuntimeConfig;
typedef PeerConfig = SdkPeerConfig;
typedef RelayConfig = SdkRelayConfig;
typedef TransferSession = SdkTransferSession;
typedef RouteSnapshot = SdkRouteSnapshot;
typedef NetworkEvent = SdkEvent;
typedef NetworkService = SessionClient;
