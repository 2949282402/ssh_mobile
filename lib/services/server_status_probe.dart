import 'dart:convert';
import 'dart:math';

/// 服务器状态探测工具类（纯静态方法）。
///
/// 双平台数据采集：
/// - Linux：复合 Shell 脚本通过 SSH exec 一次性读取 /proc + df + ss + ps
/// - Windows：单条 PowerShell 命令通过 CIM/WMI/PerformanceCounter 采集
///
/// 解析层统一输出 RawServerCounters / PortProcessSnapshot /
/// ApplicationMemorySnapshot 等不可变结构，上层不关心平台差异。
class ServerStatusProbe {
  static const performanceCommand = r'''
printf '__PROC__\n'
cat /proc/stat /proc/meminfo /proc/diskstats /proc/net/dev
printf '\n__DF__\n'
if df -P -B1 >/dev/null 2>&1; then
  df -P -B1
elif df -P -k >/dev/null 2>&1; then
  df -P -k | awk 'NR==1 { print "Filesystem 1B-blocks Used Available Use% Mounted on"; next } { if ($2 ~ /^[0-9]+$/) $2=$2*1024; if ($3 ~ /^[0-9]+$/) $3=$3*1024; if ($4 ~ /^[0-9]+$/) $4=$4*1024; print }'
else
  df -P 2>/dev/null || true
fi
''';

  static const portsCommand = r'''
if command -v ss >/dev/null 2>&1; then
  ss -H -tulpen 2>/dev/null || ss -H -tuln 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then
  netstat -tulpen 2>/dev/null || netstat -tuln 2>/dev/null
else
  echo "Neither ss nor netstat is available" >&2
  exit 127
fi
''';

  static const applicationsCommand = r'''
ps -eo pid,comm,rss,pmem,pcpu --sort=-rss | head -n 31
''';

  static const servicesCommand = r'''
if command -v systemctl >/dev/null 2>&1; then
  systemctl list-units --type=service --state=running --no-legend --no-pager
else
  echo "systemctl is not available" >&2
  exit 127
fi
''';

  static const windowsStatusCommand = r'''
powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='SilentlyContinue'; $os=Get-CimInstance Win32_OperatingSystem; $cpu=(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average; $diskBytes=0; try { $diskCounter=(Get-Counter '\PhysicalDisk(_Total)\Disk Bytes/sec' -ErrorAction Stop).CounterSamples | Measure-Object -Property CookedValue -Sum; $diskBytes=[double]$diskCounter.Sum } catch {}; $networkBytes=0; try { $networkCounter=(Get-Counter '\Network Interface(*)\Bytes Total/sec' -ErrorAction Stop).CounterSamples | Measure-Object -Property CookedValue -Sum; $networkBytes=[double]$networkCounter.Sum } catch {}; $disks=Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{ name=$_.DeviceID; totalBytes=[int64]$_.Size; freeBytes=[int64]$_.FreeSpace; usedPercent= if ($_.Size) { [math]::Round((1-$_.FreeSpace/$_.Size)*100,1) } else { 0 } } }; $ports=Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object -First 200 LocalAddress,LocalPort,OwningProcess,State; $apps=Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 30 Id,ProcessName,CPU,WorkingSet64,@{Name='MemoryPercent';Expression={ if ($os.TotalVisibleMemorySize) { [math]::Round($_.WorkingSet64/($os.TotalVisibleMemorySize*1024)*100,2) } else { 0 } }}; $services=Get-Service | Where-Object {$_.Status -eq 'Running'} | Select-Object -First 150 Name,DisplayName,@{Name='Status';Expression={$_.Status.ToString()}}; [pscustomobject]@{ os='windows'; caption=$os.Caption; version=$os.Version; cpuPercent=[double]$cpu; memoryPercent=[math]::Round((1-$os.FreePhysicalMemory/$os.TotalVisibleMemorySize)*100,1); diskBytesPerSecond=$diskBytes; networkBytesPerSecond=$networkBytes; disks=$disks; ports=$ports; applications=$apps; services=$services } | ConvertTo-Json -Depth 5 -Compress"
''';

  static RawServerCounters parsePerformanceOutput(String text) {
    final sections = _splitSections(text);
    final procText = sections['PROC'] ?? text;
    final dfText = sections['DF'] ?? '';
    return RawServerCounters(
      counters: _parseProcCounters(procText),
      diskUsage: parseDiskUsage(dfText),
    );
  }

  static List<DiskUsageSnapshot> parseDiskUsage(String text) {
    final disks = <DiskUsageSnapshot>[];
    final lines = const LineSplitter().convert(text);
    for (final line in lines.skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 6) continue;
      final filesystem = fields[0];
      final mount = fields.sublist(5).join(' ');
      if (!_isRealFilesystem(filesystem, mount)) continue;
      final total = int.tryParse(fields[1]) ?? 0;
      final used = int.tryParse(fields[2]) ?? 0;
      final available = int.tryParse(fields[3]) ?? 0;
      final percentText = fields[4].replaceAll('%', '');
      final percent = double.tryParse(percentText) ??
          (total <= 0 ? 0 : used / total * 100).clamp(0, 100).toDouble();
      disks.add(
        DiskUsageSnapshot(
          filesystem: filesystem,
          mount: mount,
          totalBytes: total,
          usedBytes: used,
          availableBytes: available,
          usedPercent: percent.clamp(0, 100).toDouble(),
        ),
      );
    }
    disks.sort((a, b) => b.usedPercent.compareTo(a.usedPercent));
    return disks.take(8).toList(growable: false);
  }

  static List<PortProcessSnapshot> parsePorts(String text) {
    final ports = <PortProcessSnapshot>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('Proto ')) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 5) continue;
      final protocol = fields.first.toLowerCase();
      var localAddress = '';
      var process = '';
      var state = '';
      if (protocol.startsWith('tcp') || protocol.startsWith('udp')) {
        if (fields.length >= 6 && _looksLikeAddress(fields[4])) {
          state = protocol.startsWith('tcp') ? fields[1] : '';
          localAddress = fields[4];
          process = fields.skip(6).join(' ');
        } else {
          localAddress = fields.length > 3 ? fields[3] : fields.last;
          process = fields.skip(6).join(' ');
        }
      }
      if (localAddress.isEmpty) continue;
      ports.add(
        PortProcessSnapshot(
          protocol: protocol,
          localAddress: localAddress,
          port: _portFromAddress(localAddress),
          state: state,
          process: _cleanProcess(process),
        ),
      );
    }
    ports.sort((a, b) => a.port.compareTo(b.port));
    return ports.take(300).toList(growable: false);
  }

  static List<ApplicationMemorySnapshot> parseApplications(String text) {
    final apps = <ApplicationMemorySnapshot>[];
    for (final line in const LineSplitter().convert(text).skip(1)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 5) continue;
      final pid = int.tryParse(fields[0]);
      final rssKb = int.tryParse(fields[2]);
      if (pid == null || rssKb == null) continue;
      apps.add(
        ApplicationMemorySnapshot(
          pid: pid,
          command: fields[1],
          rssBytes: rssKb * 1024,
          memoryPercent: double.tryParse(fields[3]) ?? 0,
          cpuPercent: double.tryParse(fields[4]) ?? 0,
        ),
      );
    }
    return apps.take(30).toList(growable: false);
  }

  static List<ServiceStatusSnapshot> parseServices(String text) {
    final services = <ServiceStatusSnapshot>[];
    for (final line in const LineSplitter().convert(text)) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length < 4) continue;
      final name = fields[0];
      final loadState = fields[1];
      final activeState = fields[2];
      final status = fields[3];
      final displayName = fields.length > 4 ? fields.sublist(4).join(' ') : '';
      services.add(
        ServiceStatusSnapshot(
          name: name,
          displayName: displayName,
          status: status,
          activeState: activeState,
          loadState: loadState,
        ),
      );
    }
    services.sort((a, b) => a.name.compareTo(b.name));
    return services.toList(growable: false);
  }

  static WindowsStatusSnapshot parseWindowsStatus(String text) {
    final decoded = jsonDecode(_extractJsonObject(text));
    if (decoded is! Map) {
      throw const FormatException('Windows status JSON is not an object.');
    }
    final data = Map<String, dynamic>.from(decoded);
    final diskUsage = _parseWindowsDisks(data['disks']);
    return WindowsStatusSnapshot(
      cpuPercent: _asDouble(data['cpuPercent']).clamp(0, 100).toDouble(),
      memoryPercent: _asDouble(data['memoryPercent']).clamp(0, 100).toDouble(),
      diskBytesPerSecond: max(0.0, _asDouble(data['diskBytesPerSecond'])),
      networkBytesPerSecond: max(
        0.0,
        _asDouble(data['networkBytesPerSecond']),
      ),
      diskUsage: diskUsage,
      ports: _parseWindowsPorts(data['ports']),
      applications: _parseWindowsApplications(data['applications']),
      services: _parseWindowsServices(data['services']),
    );
  }

  static RawPerformanceCounters _parseProcCounters(String text) {
    int? cpuTotal;
    int? cpuBusy;
    int? memTotalKb;
    int? memAvailableKb;
    var diskBytes = 0;
    var networkBytes = 0;

    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      if (trimmed.startsWith('cpu ')) {
        final values = trimmed
            .split(RegExp(r'\s+'))
            .skip(1)
            .map((value) => int.tryParse(value) ?? 0)
            .toList();
        final total = values.fold<int>(0, (sum, value) => sum + value);
        final idle = (values.length > 3 ? values[3] : 0) +
            (values.length > 4 ? values[4] : 0);
        cpuTotal = total;
        cpuBusy = total - idle;
        continue;
      }
      if (trimmed.startsWith('MemTotal:')) {
        memTotalKb = _firstInt(trimmed);
        continue;
      }
      if (trimmed.startsWith('MemAvailable:')) {
        memAvailableKb = _firstInt(trimmed);
        continue;
      }
      if (trimmed.contains(':')) {
        final parts = trimmed.split(':');
        if (parts.length == 2) {
          final name = parts.first.trim();
          if (_isPhysicalNetwork(name)) {
            final fields = parts.last.trim().split(RegExp(r'\s+'));
            if (fields.length >= 16) {
              networkBytes += (int.tryParse(fields[0]) ?? 0) +
                  (int.tryParse(fields[8]) ?? 0);
            }
          }
        }
        continue;
      }

      final fields = trimmed.split(RegExp(r'\s+'));
      if (fields.length >= 14 && _isPhysicalDisk(fields[2])) {
        final sectorsRead = int.tryParse(fields[5]) ?? 0;
        final sectorsWritten = int.tryParse(fields[9]) ?? 0;
        diskBytes += (sectorsRead + sectorsWritten) * 512;
      }
    }

    if (cpuTotal == null ||
        cpuBusy == null ||
        memTotalKb == null ||
        memAvailableKb == null) {
      throw StateError('Unsupported Linux /proc performance output.');
    }

    final usedKb = max(0, memTotalKb - memAvailableKb);
    return RawPerformanceCounters(
      time: DateTime.now(),
      cpuTotal: cpuTotal,
      cpuBusy: cpuBusy,
      memoryPercent: memTotalKb == 0 ? 0 : usedKb / memTotalKb * 100,
      diskBytes: diskBytes,
      networkBytes: networkBytes,
    );
  }

  static Map<String, String> _splitSections(String text) {
    final sections = <String, String>{};
    var current = 'PROC';
    final buffer = StringBuffer();
    void flush() {
      sections[current] = buffer.toString();
      buffer.clear();
    }

    for (final line in const LineSplitter().convert(text)) {
      if (line == '__PROC__') {
        flush();
        current = 'PROC';
        continue;
      }
      if (line == '__DF__') {
        flush();
        current = 'DF';
        continue;
      }
      buffer.writeln(line);
    }
    flush();
    return sections;
  }

  static int? _firstInt(String text) {
    final match = RegExp(r'\d+').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }

  static String _extractJsonObject(String text) {
    final trimmed = text.trim();
    final start = trimmed.indexOf('{');
    final end = trimmed.lastIndexOf('}');
    if (start < 0 || end < start) {
      throw const FormatException('No JSON object found in Windows status.');
    }
    return trimmed.substring(start, end + 1);
  }

  static List<dynamic> _asList(Object? value) {
    if (value == null) return const [];
    if (value is List) return value;
    return [value];
  }

  static double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  static int _asInt(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  static String _asString(Object? value) {
    return value?.toString() ?? '';
  }

  static List<DiskUsageSnapshot> _parseWindowsDisks(Object? value) {
    final disks = <DiskUsageSnapshot>[];
    for (final item in _asList(value)) {
      if (item is! Map) continue;
      final disk = Map<String, dynamic>.from(item);
      final name = _asString(disk['name']).trim();
      final total = max(0, _asInt(disk['totalBytes']));
      final free = max(0, _asInt(disk['freeBytes']));
      if (name.isEmpty || total <= 0) continue;
      final used = max(0, total - free);
      final percent = _asDouble(disk['usedPercent']);
      disks.add(
        DiskUsageSnapshot(
          filesystem: name,
          mount: name,
          totalBytes: total,
          usedBytes: used,
          availableBytes: free,
          usedPercent: percent.clamp(0, 100).toDouble(),
        ),
      );
    }
    disks.sort((a, b) => b.usedPercent.compareTo(a.usedPercent));
    return disks.take(8).toList(growable: false);
  }

  static List<PortProcessSnapshot> _parseWindowsPorts(Object? value) {
    final ports = <PortProcessSnapshot>[];
    for (final item in _asList(value)) {
      if (item is! Map) continue;
      final port = Map<String, dynamic>.from(item);
      final portNumber = _asInt(port['LocalPort']);
      if (portNumber <= 0) continue;
      final address = _asString(port['LocalAddress']);
      final normalizedAddress =
          address.contains(':') && !address.startsWith('[')
              ? '[$address]:$portNumber'
              : '$address:$portNumber';
      final pid = _asInt(port['OwningProcess']);
      ports.add(
        PortProcessSnapshot(
          protocol: 'tcp',
          localAddress: normalizedAddress,
          port: portNumber,
          state: _asString(port['State']),
          process: pid > 0 ? 'PID $pid' : '-',
        ),
      );
    }
    ports.sort((a, b) => a.port.compareTo(b.port));
    return ports.take(300).toList(growable: false);
  }

  static List<ApplicationMemorySnapshot> _parseWindowsApplications(
    Object? value,
  ) {
    final apps = <ApplicationMemorySnapshot>[];
    for (final item in _asList(value)) {
      if (item is! Map) continue;
      final app = Map<String, dynamic>.from(item);
      final pid = _asInt(app['Id']);
      final rss = _asInt(app['WorkingSet64']);
      final command = _asString(app['ProcessName']).trim();
      if (pid <= 0 || command.isEmpty) continue;
      apps.add(
        ApplicationMemorySnapshot(
          pid: pid,
          command: command,
          rssBytes: max(0, rss),
          memoryPercent: _asDouble(app['MemoryPercent']),
          cpuPercent: _asDouble(app['CPU']),
        ),
      );
    }
    return apps.take(30).toList(growable: false);
  }

  static List<ServiceStatusSnapshot> _parseWindowsServices(Object? value) {
    final services = <ServiceStatusSnapshot>[];
    for (final item in _asList(value)) {
      if (item is! Map) continue;
      final service = Map<String, dynamic>.from(item);
      final name = _asString(service['Name']).trim();
      if (name.isEmpty) continue;
      final displayName = _asString(service['DisplayName']).trim();
      final status = _asString(service['Status']).trim();
      services.add(
        ServiceStatusSnapshot(
          name: name,
          displayName: displayName,
          status: status,
          activeState: status,
          loadState: 'loaded',
        ),
      );
    }
    services.sort((a, b) => a.name.compareTo(b.name));
    return services.toList(growable: false);
  }

  static bool _isPhysicalDisk(String name) {
    if (name.startsWith('loop') ||
        name.startsWith('ram') ||
        name.startsWith('zram') ||
        name.startsWith('dm-') ||
        name.startsWith('sr')) {
      return false;
    }
    if (RegExp(r'^(sd|vd|xvd|hd)[a-z]+\d+$').hasMatch(name)) return false;
    if (RegExp(r'^(nvme\d+n\d+p\d+|mmcblk\d+p\d+)$').hasMatch(name)) {
      return false;
    }
    return true;
  }

  static bool _isPhysicalNetwork(String name) {
    return name != 'lo' &&
        !name.startsWith('docker') &&
        !name.startsWith('veth') &&
        !name.startsWith('br-') &&
        !name.startsWith('virbr') &&
        !name.startsWith('tun') &&
        !name.startsWith('tap') &&
        !name.startsWith('cni') &&
        !name.startsWith('flannel');
  }

  static bool _isRealFilesystem(String filesystem, String mount) {
    if (filesystem.startsWith('tmpfs') ||
        filesystem.startsWith('devtmpfs') ||
        filesystem.startsWith('overlay') ||
        filesystem.startsWith('squashfs')) {
      return false;
    }
    return !(mount.startsWith('/proc') ||
        mount.startsWith('/sys') ||
        mount.startsWith('/run') ||
        mount.startsWith('/dev'));
  }

  static bool _looksLikeAddress(String value) {
    return value.contains(':') || value.contains('.');
  }

  static int _portFromAddress(String address) {
    final normalized = address.replaceAll('[', '').replaceAll(']', '');
    final index = normalized.lastIndexOf(':');
    if (index < 0) return 0;
    return int.tryParse(normalized.substring(index + 1)) ?? 0;
  }

  static String _cleanProcess(String process) {
    if (process.isEmpty) return '-';
    return process
        .replaceAll(RegExp(r'users:\(\('), '')
        .replaceAll(RegExp(r'\)\)$'), '')
        .replaceAll('"', '')
        .trim();
  }
}

class RawServerCounters {
  final RawPerformanceCounters counters;
  final List<DiskUsageSnapshot> diskUsage;

  const RawServerCounters({
    required this.counters,
    required this.diskUsage,
  });
}

class WindowsStatusSnapshot {
  final double cpuPercent;
  final double memoryPercent;
  final double diskBytesPerSecond;
  final double networkBytesPerSecond;
  final List<DiskUsageSnapshot> diskUsage;
  final List<PortProcessSnapshot> ports;
  final List<ApplicationMemorySnapshot> applications;
  final List<ServiceStatusSnapshot> services;

  const WindowsStatusSnapshot({
    required this.cpuPercent,
    required this.memoryPercent,
    required this.diskBytesPerSecond,
    required this.networkBytesPerSecond,
    required this.diskUsage,
    required this.ports,
    required this.applications,
    required this.services,
  });
}

class RawPerformanceCounters {
  final DateTime time;
  final int cpuTotal;
  final int cpuBusy;
  final double memoryPercent;
  final int diskBytes;
  final int networkBytes;

  const RawPerformanceCounters({
    required this.time,
    required this.cpuTotal,
    required this.cpuBusy,
    required this.memoryPercent,
    required this.diskBytes,
    required this.networkBytes,
  });
}

class DiskUsageSnapshot {
  final String filesystem;
  final String mount;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double usedPercent;

  const DiskUsageSnapshot({
    required this.filesystem,
    required this.mount,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.usedPercent,
  });

  Map<String, dynamic> toJson() => {
        'filesystem': filesystem,
        'mount': mount,
        'totalBytes': totalBytes,
        'usedBytes': usedBytes,
        'availableBytes': availableBytes,
        'usedPercent': usedPercent,
      };
}

class PortProcessSnapshot {
  final String protocol;
  final String localAddress;
  final int port;
  final String state;
  final String process;

  const PortProcessSnapshot({
    required this.protocol,
    required this.localAddress,
    required this.port,
    required this.state,
    required this.process,
  });

  Map<String, dynamic> toJson() => {
        'protocol': protocol,
        'localAddress': localAddress,
        'port': port,
        'state': state,
        'process': process,
      };
}

class ApplicationMemorySnapshot {
  final int pid;
  final String command;
  final int rssBytes;
  final double memoryPercent;
  final double cpuPercent;

  const ApplicationMemorySnapshot({
    required this.pid,
    required this.command,
    required this.rssBytes,
    required this.memoryPercent,
    required this.cpuPercent,
  });

  Map<String, dynamic> toJson() => {
        'pid': pid,
        'command': command,
        'rssBytes': rssBytes,
        'memoryPercent': memoryPercent,
        'cpuPercent': cpuPercent,
      };
}

class ServiceStatusSnapshot {
  final String name;
  final String displayName;
  final String status;
  final String activeState;
  final String loadState;

  const ServiceStatusSnapshot({
    required this.name,
    required this.displayName,
    required this.status,
    required this.activeState,
    required this.loadState,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'displayName': displayName,
        'status': status,
        'activeState': activeState,
        'loadState': loadState,
      };
}
