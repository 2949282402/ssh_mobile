import { useState } from 'react';
import {
  AlertTriangle,
  BarChart3,
  RefreshCw,
} from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import { useTelemetryOverview } from '../../hooks/use-telemetry';
import {
  Badge,
  Button,
  ErrorState,
  InlineNotice,
  MetricTile,
  PageHeader,
  Skeleton,
} from '../../components/ui';
import type { TelemetryFilter } from '../../schemas/telemetry';

const TIME_RANGES: Array<{ label: string; value: TelemetryFilter['timeRange'] }> = [
  { label: '1 小时', value: '1h' },
  { label: '24 小时', value: '24h' },
  { label: '7 天', value: '7d' },
  { label: '30 天', value: '30d' },
  { label: '全部', value: 'all' },
];

function formatTrendTime(timestamp: string): string {
  try {
    const isoStr = timestamp.includes('T') ? timestamp : `${timestamp.replace(' ', 'T')}Z`;
    const date = new Date(isoStr);
    if (isNaN(date.getTime())) {
      return timestamp;
    }
    return date.toLocaleDateString([], { month: 'numeric', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  } catch {
    return timestamp;
  }
}

export function TelemetryDashboardPage() {
  const [timeRange, setTimeRange] = useState<TelemetryFilter['timeRange']>('24h');
  const overviewQuery = useTelemetryOverview({ timeRange });
  const data = overviewQuery.data;

  if (overviewQuery.isPending && !data) {
    return <DashboardSkeleton />;
  }

  if (overviewQuery.isError && !data) {
    const errorMsg = overviewQuery.error instanceof ApiRequestError
      ? overviewQuery.error.message
      : '无法加载埋点概览数据，请检查服务连接。';
    return (
      <div className="page page--narrow">
        <PageHeader
          eyebrow="Telemetry / Overview"
          title="数据埋点概览"
          description="查看全端数据埋点、诊断日志及上报通道健康状态。"
        />
        <ErrorState description={errorMsg} onRetry={() => void overviewQuery.refetch()} />
      </div>
    );
  }

  if (!data) return null;

  const health = data.pipelineHealth;
  const healthTone = health.status === 'healthy' ? 'online' : health.status === 'degraded' ? 'warning' : 'danger';

  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Overview"
        title="数据埋点概览"
        description="全端埋点数据指标、诊断日志与采集流水线运行状态。"
        action={(
          <div style={{ display: 'flex', gap: '0.5rem', alignItems: 'center' }}>
            <div className="filter-group" role="group" aria-label="时间区间筛选">
              {TIME_RANGES.map((tr) => (
                <Button
                  key={tr.value}
                  variant={timeRange === tr.value ? 'primary' : 'quiet'}
                  onClick={() => setTimeRange(tr.value)}
                  aria-pressed={timeRange === tr.value}
                >
                  {tr.label}
                </Button>
              ))}
            </div>
            <Button
              variant="outline"
              onClick={() => void overviewQuery.refetch()}
              loading={overviewQuery.isFetching}
            >
              <RefreshCw size={15} aria-hidden="true" />
              刷新
            </Button>
          </div>
        )}
      />

      {overviewQuery.isError ? (
        <InlineNotice tone="warning">
          最近一次刷新失败，当前展示缓存数据。
        </InlineNotice>
      ) : null}

      {/* Pipeline Health Banner */}
      <section className="signal-card" aria-label="埋点通道健康状态">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Ingest Pipeline Health</p>
            <h2>流水线健康状态</h2>
          </div>
          <Badge tone={healthTone} dot>
            {health.status.toUpperCase()}
          </Badge>
        </div>
        <div className="metric-grid" style={{ marginTop: '1rem' }}>
          <MetricTile
            label="服务端 Ingest 延迟"
            value={`${health.serverIngestLatencyMs.toFixed(2)} ms`}
            detail="端到端入库与幂等收据确认耗时"
            accent={health.serverIngestLatencyMs < 20 ? 'teal' : 'amber'}
            mono
          />
          <MetricTile
            label="Ingest 拒绝/失败率"
            value={`${(health.serverIngestErrorRate * 100).toFixed(2)}%`}
            detail="包括签名失败或契约校验拒绝"
            accent={health.serverIngestErrorRate < 0.01 ? 'teal' : 'coral'}
            mono
          />
          <MetricTile
            label="Redis 诊断流状态"
            value={health.redisCacheStatus}
            detail={health.redisCacheStatus === 'active' ? '最近诊断日志实时缓存正常' : '降级至 MySQL 存储'}
            accent={health.redisCacheStatus === 'active' ? 'teal' : 'amber'}
            mono
          />
        </div>
      </section>

      {/* KPI Cards Grid */}
      <div className="section-heading" style={{ marginTop: '1.5rem' }}>
        <div>
          <p className="eyebrow">Core Metrics</p>
          <h2>业务与稳定性核心指标</h2>
        </div>
      </div>
      <section className="metric-grid" aria-label="埋点核心指标">
        <MetricTile
          label="上报事件总数"
          value={data.totalEvents}
          detail="Analytics 业务行为事件总数"
          accent="teal"
          mono
        />
        <MetricTile
          label="诊断日志总数"
          value={data.totalDiagnostics}
          detail="系统调试、链路追踪与异常日志"
          accent="teal"
          mono
        />
        <MetricTile
          label="活跃设备数"
          value={data.recentActiveDevices}
          detail="当前时间窗口内活跃上报的客户端"
          accent="teal"
          mono
        />
        <MetricTile
          label="异常与错误数"
          value={`${data.errorCount} (严重: ${data.criticalErrorCount})`}
          detail={`波及 ${data.affectedDevicesCount} 台设备`}
          accent={data.criticalErrorCount > 0 ? 'coral' : data.errorCount > 0 ? 'amber' : 'ink'}
          mono
        />
        <MetricTile
          label="核心链路成功率"
          value={`${(data.coreOperationSuccessRate * 100).toFixed(1)}%`}
          detail="连接、认证、传输等核心操作"
          accent={data.coreOperationSuccessRate >= 0.99 ? 'teal' : 'coral'}
          mono
        />
        <MetricTile
          label="无错误会话率"
          value={`${(data.errorFreeSessionRate * 100).toFixed(1)}%`}
          detail="全程无任何 error/critical 的会话占比"
          accent={data.errorFreeSessionRate >= 0.95 ? 'teal' : 'amber'}
          mono
        />
      </section>

      {/* Trend Visualizer */}
      <div className="overview-grid" style={{ marginTop: '1.5rem' }}>
        <section className="panel">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Event Trend</p>
              <h2>事件量趋势</h2>
            </div>
            <BarChart3 size={18} aria-hidden="true" />
          </div>
          {data.eventsTrend.length === 0 ? (
            <p style={{ color: 'var(--muted)', padding: '1rem 0' }}>暂无时间窗口内的趋势采样数据</p>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem', marginTop: '1rem' }}>
              {data.eventsTrend.map((point) => (
                <div key={point.timestamp} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <span className="type-mono" style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>
                    {formatTrendTime(point.timestamp)}
                  </span>
                  <div style={{ flex: 1, margin: '0 1rem', background: 'var(--canvas)', height: '12px', borderRadius: '6px', overflow: 'hidden' }}>
                    <div
                      style={{
                        height: '100%',
                        width: `${Math.min(100, Math.max(10, (point.value / (data.totalEvents || 1)) * 100))}%`,
                        background: 'var(--teal)',
                        borderRadius: '6px',
                      }}
                    />
                  </div>
                  <strong className="type-mono">{point.value}</strong>
                </div>
              ))}
            </div>
          )}
        </section>

        <section className="panel">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Error Trend</p>
              <h2>异常与错误趋势</h2>
            </div>
            <AlertTriangle size={18} aria-hidden="true" />
          </div>
          {data.errorsTrend.length === 0 ? (
            <p style={{ color: 'var(--muted)', padding: '1rem 0' }}>暂无异常错误趋势采样数据</p>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem', marginTop: '1rem' }}>
              {data.errorsTrend.map((point) => (
                <div key={point.timestamp} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                  <span className="type-mono" style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>
                    {formatTrendTime(point.timestamp)}
                  </span>
                  <div style={{ flex: 1, margin: '0 1rem', background: 'var(--canvas)', height: '12px', borderRadius: '6px', overflow: 'hidden' }}>
                    <div
                      style={{
                        height: '100%',
                        width: `${Math.min(100, Math.max(10, (point.value / (data.errorCount || 1)) * 100))}%`,
                        background: point.value > 0 ? 'var(--coral)' : 'var(--teal)',
                        borderRadius: '6px',
                      }}
                    />
                  </div>
                  <strong className="type-mono">{point.value}</strong>
                </div>
              ))}
            </div>
          )}
        </section>
      </div>
    </div>
  );
}

function DashboardSkeleton() {
  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Overview"
        title="数据埋点概览"
        description="正在读取埋点数据指标及健康状态..."
      />
      <section className="signal-card skeleton-card">
        <Skeleton className="skeleton-heading" />
        <Skeleton className="skeleton-rail" />
      </section>
      <div className="metric-grid" style={{ marginTop: '1rem' }}>
        {Array.from({ length: 6 }, (_, index) => (
          <Skeleton className="skeleton-metric" key={index} />
        ))}
      </div>
    </div>
  );
}
