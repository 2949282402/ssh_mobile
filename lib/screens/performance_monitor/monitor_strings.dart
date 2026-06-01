part of '../performance_monitor_screen.dart';

extension _PerformanceStrings on AppStrings {
  bool get _isEn => language == AppLanguage.en;

  String get monitorServers => _isEn ? 'Monitor servers' : '监控服务器';
  String get selectMonitorServer =>
      _isEn ? 'Select servers to monitor' : '选择要监控的服务器';
  String get selectMonitorServerHint => _isEn
      ? 'Select one or more servers, then start monitoring. Sampling stays silent until started.'
      : '可多选服务器，点击开始监控后才采样；未开始前保持静默。';
  String selectedMonitorServers(int count) =>
      _isEn ? '$count selected' : '已选择 $count 台';
  String monitoringServers(int count) => _isEn
      ? 'Monitoring $count server${count == 1 ? '' : 's'}'
      : '正在监控 $count 台服务器';
  String get startMonitoring => _isEn ? 'Start' : '开始监控';
  String get stopMonitoring => _isEn ? 'Stop' : '停止监控';
  String get changeSelectionHint => _isEn
      ? 'Stop monitoring before changing server selection.'
      : '停止监控后可修改服务器选择。';
  String get sampleInterval => _isEn ? 'Interval' : '刷新间隔';
  String get historyWindow => _isEn ? 'Range' : '时间范围';
  String get sampling => _isEn ? 'Sampling...' : '正在采样...';
  String get noSamplesYet => _isEn ? 'Waiting for samples' : '等待采样数据';
  String get cpu => 'CPU';
  String get memory => _isEn ? 'Memory' : '内存';
  String get diskIo => _isEn ? 'Disk IO' : '磁盘 IO';
  String get network => _isEn ? 'Network' : '网络';
}
