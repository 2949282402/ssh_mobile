import { type ReactNode } from 'react';
import { Cpu, Gauge, MemoryStick, RefreshCw, Server, TimerReset } from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import { useAdminOverview } from '../../hooks/use-admin-overview';
import {
  Badge,
  Button,
  ErrorState,
  InlineNotice,
  MetricTile,
  PageHeader,
  SignalRail,
  Skeleton,
} from '../../components/ui';
import { formatDuration, formatLastUpdated } from '../../utils/format';

export function OverviewPage() {
  const statsQuery = useAdminOverview();
  const stats = statsQuery.data;

  if (statsQuery.isPending && !stats) return <OverviewSkeleton />;
  if (statsQuery.isError && !stats) {
    const description = statsQuery.error instanceof ApiRequestError && statsQuery.error.status === 401
      ? '当前会话已失效，请重新登录。'
      : statsQuery.error instanceof ApiRequestError
        ? statsQuery.error.message
        : '检查 Relay 服务状态后重试。';
    return (
      <div className="page page--narrow">
        <PageHeader eyebrow="Relay / Overview" title="运行概览" description="查看当前 Relay 服务的设备和中继连接状态。" />
        <ErrorState description={description} onRetry={() => void statsQuery.refetch()} />
      </div>
    );
  }
  if (!stats) return null;

  const presenceAvailable = stats.presence_available;
  const refreshFailed = statsQuery.isError;
  const refreshError = statsQuery.error instanceof ApiRequestError
    ? statsQuery.error.message
    : '最近一次刷新失败。';

  return (
    <div className="page">
      <PageHeader
        eyebrow="Relay / Overview"
        title="运行概览"
        description="当前 Relay 服务的设备、连接和进程资源状态。"
        action={(
          <Button variant="outline" onClick={() => void statsQuery.refetch()} loading={statsQuery.isFetching}>
            <RefreshCw size={15} aria-hidden="true" />
            刷新状态
          </Button>
        )}
      />

      <div className="snapshot-meta">
        <Badge tone={refreshFailed ? 'warning' : 'online'} dot>
          {refreshFailed ? 'STALE SNAPSHOT' : 'LIVE SNAPSHOT'}
        </Badge>
        <span>上次同步 {formatLastUpdated(stats.server_time * 1000)}</span>
        <span className="snapshot-meta__separator" aria-hidden="true" />
        <span>每 3 秒自动更新</span>
      </div>

      {refreshFailed ? (
        <InlineNotice tone="warning">{refreshError} 当前显示上次成功同步的数据。</InlineNotice>
      ) : null}

      {!presenceAvailable ? (
        <InlineNotice tone="warning">在线状态暂不可用（presence 服务异常），以下在线数为未知。</InlineNotice>
      ) : null}

      <section className="signal-card">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Relay signal rail</p>
            <h2>链路状态</h2>
          </div>
          <span className="section-heading__note">Admin API v1 / live snapshot</span>
        </div>
        <SignalRail
          nodes={[
            { label: 'Registered devices', value: stats.devices.enrolled },
            { label: 'Online peers', value: presenceAvailable ? stats.devices.online : '未知' },
            { label: 'Active sessions', value: stats.relay.active_transfers, tone: stats.relay.active_transfers > 0 ? 'amber' : 'teal' },
          ]}
        />
      </section>

      <section className="metric-grid" aria-label="Relay 核心指标">
        <MetricTile label="Registered devices" value={stats.devices.enrolled} detail="当前存储已注册" accent="teal" />
        <MetricTile label="Online peers" value={presenceAvailable ? stats.devices.online : '未知'} detail={presenceAvailable ? '已建立 WebSocket 连接' : 'presence 暂不可用'} accent="teal" />
        <MetricTile label="Active sessions" value={stats.relay.active_transfers} detail="内存中的传输会话" accent={stats.relay.active_transfers > 0 ? 'amber' : 'ink'} />
        <MetricTile label="Memory alloc" value={`${stats.runtime.allocated_mem_mb.toFixed(2)} MB`} detail={`${stats.runtime.goroutines} goroutines`} accent="coral" mono />
      </section>

      <div className="overview-grid">
        <section className="panel">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Registry snapshot</p>
              <h2>设备状态</h2>
            </div>
            {presenceAvailable ? <Badge tone="neutral">{stats.devices.online} online</Badge> : <Badge tone="neutral">在线状态未知</Badge>}
          </div>
          <div className="overview-summary">
            {presenceAvailable ? (
              <strong>{stats.devices.online === 0 ? '当前没有在线设备' : `${stats.devices.online} 台设备在线`}</strong>
            ) : (
              <strong>在线状态暂不可用，无法确认当前在线设备数。</strong>
            )}
            <p>设备详情、远端地址和公钥指纹请在 Devices 页面查看。</p>
          </div>
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
            <RuntimeRow icon={<TimerReset size={16} />} label="服务运行时间" value={formatDuration(stats.uptime_seconds)} mono />
            <RuntimeRow icon={<MemoryStick size={16} />} label="内存占用" value={`${stats.runtime.allocated_mem_mb.toFixed(2)} MB`} mono />
            <RuntimeRow icon={<Cpu size={16} />} label="Goroutines" value={String(stats.runtime.goroutines)} mono />
            <RuntimeRow icon={<Server size={16} />} label="注册数据" value="由 Relay 部署配置决定" />
          </div>
          <InlineNotice tone="warning">Relay 重启会结束活动传输会话；设备注册是否保留取决于存储配置。</InlineNotice>
        </section>
      </div>

      <div className="sr-only" aria-live="polite">
        {presenceAvailable
          ? `当前在线设备 ${stats.devices.online} 台，活动会话 ${stats.relay.active_transfers} 个。`
          : `在线状态暂不可用，活动会话 ${stats.relay.active_transfers} 个。`}
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
