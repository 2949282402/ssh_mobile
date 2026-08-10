import { useMemo, type ReactNode } from 'react';
import { Activity, Cpu, Gauge, MemoryStick, RefreshCw, Server, TimerReset } from 'lucide-react';
import { ApiRequestError } from '../../api/types';
import { useRelayStats } from '../../hooks/use-relay-stats';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  InlineNotice,
  MetricTile,
  PageHeader,
  SignalRail,
  Skeleton,
} from '../../components/ui';
import { formatLastUpdated } from '../../utils/format';

export function OverviewPage() {
  const statsQuery = useRelayStats();
  const stats = statsQuery.data;
  const onlinePeers = useMemo(() => new Map(stats?.peers.map((peer) => [peer.device_id, peer]) ?? []), [stats?.peers]);

  if (statsQuery.isPending && !stats) return <OverviewSkeleton />;
  if (statsQuery.isError && !stats) {
    const description = statsQuery.error instanceof ApiRequestError && statsQuery.error.status === 401
      ? '当前会话已失效，请重新登录。'
      : statsQuery.error instanceof ApiRequestError
        ? statsQuery.error.message
        : '检查 Relay 服务状态后重试。';
    return (
      <div className="page page--narrow">
        <PageHeader eyebrow="Relay / Overview" title="运行概览" description="查看当前进程里的设备和中继连接状态。" />
        <ErrorState description={description} onRetry={() => void statsQuery.refetch()} />
      </div>
    );
  }
  if (!stats) return null;

  return (
    <div className="page">
      <PageHeader
        eyebrow="Relay / Overview"
        title="运行概览"
        description="当前 Relay 进程的设备、连接和资源状态。"
        action={(
          <Button variant="outline" onClick={() => void statsQuery.refetch()} loading={statsQuery.isFetching}>
            <RefreshCw size={15} aria-hidden="true" />
            刷新状态
          </Button>
        )}
      />

      <div className="snapshot-meta">
        <Badge tone="online" dot>LIVE SNAPSHOT</Badge>
        <span>上次同步 {formatLastUpdated(stats.server_time * 1000)}</span>
        <span className="snapshot-meta__separator" aria-hidden="true" />
        <span>每 3 秒自动更新</span>
      </div>

      <section className="signal-card">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Relay signal rail</p>
            <h2>链路状态</h2>
          </div>
          <span className="section-heading__note">protocol v1 / in-memory</span>
        </div>
        <SignalRail
          nodes={[
            { label: 'Registered devices', value: stats.enrolled_count },
            { label: 'Online peers', value: stats.active_peers },
            { label: 'Active sessions', value: stats.active_sessions, tone: stats.active_sessions > 0 ? 'amber' : 'teal' },
          ]}
        />
      </section>

      <section className="metric-grid" aria-label="Relay 核心指标">
        <MetricTile label="Registered devices" value={stats.enrolled_count} detail="当前进程已注册" accent="teal" />
        <MetricTile label="Online peers" value={stats.active_peers} detail="已建立 WebSocket 连接" accent="teal" />
        <MetricTile label="Active sessions" value={stats.active_sessions} detail="内存中的传输会话" accent={stats.active_sessions > 0 ? 'amber' : 'ink'} />
        <MetricTile label="Memory alloc" value={`${stats.allocated_mem_mb.toFixed(2)} MB`} detail={`${stats.num_goroutines} goroutines`} accent="coral" mono />
      </section>

      <div className="overview-grid">
        <section className="panel">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Connected now</p>
              <h2>在线设备</h2>
            </div>
            <Badge tone="neutral">{stats.active_peers} peers</Badge>
          </div>
          {stats.peers.length === 0 ? (
            <EmptyState title="当前没有在线设备" description="设备完成注册并建立 Relay 连接后，会出现在这里。" icon={<Activity size={21} />} />
          ) : (
            <div className="peer-list">
              {stats.peers.map((peer) => (
                <div className="peer-row" key={peer.device_id}>
                  <span className="peer-row__signal" aria-hidden="true"><span /></span>
                  <div className="peer-row__identity">
                    <strong className="type-mono">{peer.device_id}</strong>
                    <span>{peer.remote_addr || '远端地址未知'}</span>
                  </div>
                  <Badge tone="online" dot>在线</Badge>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="panel runtime-panel">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Process telemetry</p>
              <h2>进程状态</h2>
            </div>
            <Gauge size={19} aria-hidden="true" className="section-heading__icon" />
          </div>
          <div className="runtime-list">
            <RuntimeRow icon={<TimerReset size={16} />} label="服务运行时间" value={stats.uptime_formatted} mono />
            <RuntimeRow icon={<MemoryStick size={16} />} label="内存占用" value={`${stats.allocated_mem_mb.toFixed(2)} MB`} mono />
            <RuntimeRow icon={<Cpu size={16} />} label="Goroutines" value={String(stats.num_goroutines)} mono />
            <RuntimeRow icon={<Server size={16} />} label="数据保存" value="仅驻留内存" />
          </div>
          <InlineNotice tone="warning">Relay 重启后，设备注册和传输会话都会清空。</InlineNotice>
        </section>
      </div>

      <div className="sr-only" aria-live="polite">
        当前在线设备 {onlinePeers.size} 台，活动会话 {stats.active_sessions} 个。
      </div>
    </div>
  );
}

function RuntimeRow({
  icon,
  label,
  value,
  mono = false,
}: {
  icon: ReactNode;
  label: string;
  value: string;
  mono?: boolean;
}) {
  return (
    <div className="runtime-row">
      <span className="runtime-row__icon">{icon}</span>
      <span>{label}</span>
      <strong className={mono ? 'type-mono' : ''}>{value}</strong>
    </div>
  );
}

function OverviewSkeleton() {
  return (
    <div className="page">
      <PageHeader eyebrow="Relay / Overview" title="运行概览" description="正在读取当前 Relay 进程状态。" />
      <section className="signal-card skeleton-card"><Skeleton className="skeleton-heading" /><Skeleton className="skeleton-rail" /></section>
      <div className="metric-grid">
        {Array.from({ length: 4 }, (_, index) => <Skeleton className="skeleton-metric" key={index} />)}
      </div>
    </div>
  );
}
