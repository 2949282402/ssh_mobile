import 'dart:ffi';

/// Native:
///
/// int32_t ssh_quic_ping(void);
///
/// Dart:
///
/// int sshQuicPingNative();
@Native<Int32 Function()>(
  symbol: 'ssh_quic_ping',
)
external int sshQuicPingNative();

@Native<Int32 Function()>(
  symbol: 'ssh_quic_msquic_open_test',
)
external int sshQuicMsQuicOpenTestNative();


///
/// Dart 业务层包装。
///
/// 上层代码最好不要直接到处调用
/// sshQuicPingNative()。
///
/// 所有 native 调用以后都集中放到这个类下面。
///
class SshMobileQuicNative {
  const SshMobileQuicNative();

  int ping() {
    return sshQuicPingNative();
  }

  int msquicOpenTest() {
    return sshQuicMsQuicOpenTestNative();
  }

  void verifyMsQuic() {
    final result =
        msquicOpenTest();

    if (result != 0) {
      throw StateError(
        'MsQuic initialization failed: $result',
      );
    }
  }
}