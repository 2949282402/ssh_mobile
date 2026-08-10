import 'package:flutter_test/flutter_test.dart';
import 'package:feature_monitoring/feature_monitoring.dart';

void main() {
  test('async probe parsers preserve results off the UI isolate', () async {
    const portsText =
        'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))';

    final sync = ServerStatusProbe.parsePorts(portsText);
    final background = await ServerStatusProbe.parsePortsAsync(portsText);

    expect(background.length, sync.length);
    expect(background.single.port, sync.single.port);
    expect(background.single.process, sync.single.process);
  });

  test('parseDiskUsage filters virtual filesystems and sorts by usage', () {
    final disks = ServerStatusProbe.parseDiskUsage('''
Filesystem 1B-blocks Used Available Use% Mounted on
/dev/sda1 1000 750 250 75% /
tmpfs 1000 100 900 10% /run
overlay 1000 900 100 90% /var/lib/docker/overlay2
/dev/nvme0n1p2 2000 1900 100 95% /data
''');

    expect(disks.map((disk) => disk.mount), ['/data', '/']);
    expect(disks.first.usedPercent, 95);
  });

  test('parsePorts handles ss listening rows', () {
    final ports = ServerStatusProbe.parsePorts('''
tcp LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=123,fd=3))
udp UNCONN 0 0 127.0.0.53:53 0.0.0.0:* users:(("systemd-resolve",pid=42,fd=12))
''');

    expect(ports.map((port) => port.port), [22, 53]);
    expect(ports.first.protocol, 'tcp');
    expect(ports.first.process, contains('sshd'));
  });

  test('parseApplications converts rss from KiB to bytes', () {
    final apps = ServerStatusProbe.parseApplications('''
PID COMMAND RSS %MEM %CPU
100 sshd 2048 1.5 0.2
101 postgres 4096 3.0 1.2
''');

    expect(apps, hasLength(2));
    expect(apps.first.command, 'sshd');
    expect(apps.first.rssBytes, 2048 * 1024);
  });

  test('parseWindowsStatus handles PowerShell JSON envelope', () {
    final snapshot = ServerStatusProbe.parseWindowsStatus('''
noise before
{"cpuPercent":42,"memoryPercent":66.6,"diskBytesPerSecond":1234,"networkBytesPerSecond":5678,"disks":[{"name":"C:","totalBytes":1000,"freeBytes":250,"usedPercent":75}],"ports":[{"LocalAddress":"0.0.0.0","LocalPort":3389,"OwningProcess":4321,"State":"Listen"}],"applications":[{"Id":7,"ProcessName":"powershell","CPU":1.5,"WorkingSet64":2048,"MemoryPercent":0.1}],"services":[{"Name":"wuauserv","DisplayName":"Windows Update","Status":"Running"}]}
noise after
''');

    expect(snapshot.cpuPercent, 42);
    expect(snapshot.diskUsage.single.mount, 'C:');
    expect(snapshot.ports.single.port, 3389);
    expect(snapshot.applications.single.command, 'powershell');
    expect(snapshot.services.single.name, 'wuauserv');
    expect(snapshot.services.single.displayName, 'Windows Update');
    expect(snapshot.services.single.status, 'Running');
  });

  test('parseServices handles systemctl active service rows', () {
    final services = ServerStatusProbe.parseServices('''
cron.service                           loaded active running Regular background program processing daemon
dbus.service                           loaded active running D-Bus System Message Bus
docker.service                         loaded active running Docker Application Container Engine
''');

    expect(services, hasLength(3));
    expect(services.first.name, 'cron.service');
    expect(services.first.loadState, 'loaded');
    expect(services.first.activeState, 'active');
    expect(services.first.status, 'running');
    expect(
      services.first.displayName,
      'Regular background program processing daemon',
    );
  });
}
