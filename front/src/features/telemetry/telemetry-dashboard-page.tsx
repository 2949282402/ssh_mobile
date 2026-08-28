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
  { label: '1 天', value: '1d' },
  { label: '24 小时', value: '24h' },
  { label: '7 天', value: '7d' },
  { label: '30 天', value: '30d' },
  { label: '全部', value: 'all' },
];

const TIME_RANGE_SECONDS: Record<TelemetryFilter['timeRange'], number | null> = {
  '1h': 3600,
  '1d': 86400,
  '24h': 86400,
  '7d': 604800,
  '30d': 2592000,
  all: null,
};

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

function formatLatency(value: number): string {
  if (!Number.isFinite(value) || value <= 0) return 'No data';
  if (value >= 1000) return `${(value / 1000).toFixed(2)}s`;
  return `${value.toFixed(0)}ms`;
}

function formatObservedLatency(value: number, samples: number): string {
  if (!Number.isFinite(value) || samples <= 0) return 'No data';
  if (value >= 1000) return `${(value / 1000).toFixed(2)}s`;
  return `${value.toFixed(0)}ms`;
}

function formatRate(rate: number, denominator: number, digits: number): string {
  if (!Number.isFinite(rate) || !Number.isFinite(denominator) || denominator <= 0) return 'No data';
  return `${(rate * 100).toFixed(digits)}%`;
}

function trendBarWidth(value: number, denominator: number): string {
  if (!Number.isFinite(value) || !Number.isFinite(denominator) || denominator <= 0) {
    return '0%';
  }
  return `${Math.min(100, Math.max(0, (value / denominator) * 100))}%`;
}

function formatThroughput(events: number, seconds: number | null): string {
  if (events <= 0) return '0/s';
  if (seconds === null || seconds <= 0) {
    // For "all time" the window span is unknown; report the total count instead.
    return `${events}`;
  }
  const perSecond = events / seconds;
  if (perSecond >= 100) return `${Math.round(perSecond)}/s`;
  if (perSecond >= 10) return `${perSecond.toFixed(1)}/s`;
  return `${perSecond.toFixed(2)}/s`;
}

function latencyDetailLabel(samples: number | undefined): string {
  if (!samples || samples <= 0) {
    return 'No operations recorded in this time range';
  }
  return `基于 ${samples} 次完成操作采样`;
}

function redisStatusDetail(status: string): string {
  if (status === 'active') return '最近诊断日志实时缓存正常';
  if (status === 'fallback_mysql') return 'Redis 探活失败，诊断流已降级至 MySQL 存储';
  return 'Redis 未启用，诊断流直接查询 MySQL 持久层';
}

function latencyAccent(value: number | undefined): 'teal' | 'amber' | 'coral' {
  if (!value || value <= 0) return 'teal';
  if (value < 500) return 'teal';
  if (value < 1500) return 'amber';
  return 'coral';
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
            label="服务端 Ingest 平均延迟"
            value={health.serverIngestRequests > 0 ? `${health.serverIngestLatencyMs.toFixed(2)} ms` : 'No data'}
            detail={`服务启动以来，Service.IngestBatch 从调用到返回的平均耗时（含存储与诊断缓存更新；不含认证、解码、限流与过载拒绝）；${health.serverIngestRequests} 次调用`}
            accent={health.serverIngestLatencyMs < 20 ? 'teal' : 'amber'}
            mono
          />
          <MetricTile
            label="服务端 Ingest P95 延迟"
            value={health.serverIngestRequests > 0 ? `${health.serverIngestLatencyP95Ms.toFixed(2)} ms` : 'No data'}
            detail="服务启动以来 Service.IngestBatch 调用耗时的 95 分位；单位为毫秒，延迟样本最多保留最近 1024 次"
            accent={health.serverIngestLatencyP95Ms < 50 ? 'teal' : 'amber'}
            mono
          />
          <MetricTile
            label="服务端 Ingest 错误率"
            value={formatRate(health.serverIngestErrorRate, health.serverIngestRequests, 2)}
            detail={`服务启动以来 Service.IngestBatch 返回 error 的调用数 ÷ 调用总数；不含认证、解码、限流与过载拒绝，单条 rejected ACK 不算服务错误；${health.serverIngestRequests} 次调用作为分母`}
            accent={health.serverIngestRequests > 0 && health.serverIngestErrorRate >= 0.01 ? 'coral' : 'teal'}
            mono
          />
          <MetricTile
            label="Redis 诊断流状态"
            value={health.redisCacheStatus}
            detail={redisStatusDetail(health.redisCacheStatus)}
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
          detail="Analytics 记录总数（不等于业务操作成功率分母）"
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
          label="业务操作成功率"
          value={formatRate(data.businessOperationSuccessRate, data.businessOperationDenominator, 1)}
          detail={`目录中 businessOperation=true 且 role 为 success/failure 的终结事件（无论 recordType）按 success ÷ (success + failure)；排除 started 与 businessOperation=false 的诊断/投递事件；${data.businessOperationSuccesses}/${data.businessOperationDenominator} 个终结操作成功`}
          accent={data.businessOperationDenominator > 0 && data.businessOperationSuccessRate < 0.99 ? 'coral' : 'teal'}
          mono
        />
        <MetricTile
          label="无错误会话率"
          value={formatRate(data.errorFreeSessionRate, data.errorFreeSessionDenominator, 1)}
          detail={`全程无任何 error/critical 的会话占比；${data.errorFreeSessionSuccesses}/${data.errorFreeSessionDenominator} 个会话无错误`}
          accent={data.errorFreeSessionDenominator > 0 && data.errorFreeSessionRate < 0.95 ? 'amber' : 'teal'}
          mono
        />
      </section>

      {/* Latency Percentiles */}
      <div className="section-heading" style={{ marginTop: '1.5rem' }}>
        <div>
          <p className="eyebrow">Completion Latency</p>
          <h2>完成操作延迟分位</h2>
        </div>
      </div>
      <section className="metric-grid" aria-label="完成操作延迟分位">
        <MetricTile
          label="P50 中位延迟"
          value={formatLatency(data.latency?.p50Ms ?? 0)}
          detail={latencyDetailLabel(data.latency?.samples)}
          accent="teal"
          mono
        />
        <MetricTile
          label="P95 延迟"
          value={formatLatency(data.latency?.p95Ms ?? 0)}
          detail="95% 完成操作不超过该耗时"
          accent={latencyAccent(data.latency?.p95Ms)}
          mono
        />
        <MetricTile
          label="P99 延迟"
          value={formatLatency(data.latency?.p99Ms ?? 0)}
          detail="99% 完成操作不超过该耗时"
          accent={latencyAccent(data.latency?.p99Ms)}
          mono
        />
        <MetricTile
          label="事件吞吐"
          value={formatThroughput(data.totalEvents, TIME_RANGE_SECONDS[timeRange] ?? TIME_RANGE_SECONDS.all)}
          detail={`${timeRange === 'all' ? '全部时间' : timeRange} 窗口内上报速率`}
          accent="teal"
          mono
        />
      </section>

      {/* Delivery Delay */}
      <div className="section-heading" style={{ marginTop: '1.5rem' }}>
        <div>
          <p className="eyebrow">Delivery Delay</p>
          <h2>客户端投递延迟</h2>
        </div>
      </div>
      <section className="metric-grid" aria-label="客户端投递延迟">
        <MetricTile
          label="平均投递延迟"
          value={formatObservedLatency(data.deliveryDelay.averageMs, data.deliveryDelay.samples)}
          detail="receivedAt − occurredAt；未来 occurredAt 按 0 ms 计入样本，并单独计数时钟偏差"
          accent="teal"
          mono
        />
        <MetricTile
          label="P50 投递延迟"
          value={formatObservedLatency(data.deliveryDelay.p50Ms, data.deliveryDelay.samples)}
          detail={`客户端事件到服务端接收的中位延迟；${data.deliveryDelay.samples} 个可测样本`}
          accent="teal"
          mono
        />
        <MetricTile
          label="P95 投递延迟"
          value={formatObservedLatency(data.deliveryDelay.p95Ms, data.deliveryDelay.samples)}
          detail="95% 可测事件的 receivedAt − occurredAt 不超过该值"
          accent={latencyAccent(data.deliveryDelay.p95Ms)}
          mono
        />
        <MetricTile
          label="未来时间戳样本"
          value={data.deliveryDelay.futureTimestampCount}
          detail="occurredAt 晚于 receivedAt 的事件；延迟按 0 ms 计入统计"
          accent={data.deliveryDelay.futureTimestampCount > 0 ? 'amber' : 'teal'}
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
            <p style={{ color: 'var(--muted)', padding: '1rem 0' }}>No operations recorded in this time range</p>
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
                        width: trendBarWidth(point.value, data.totalEvents),
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
            <p style={{ color: 'var(--muted)', padding: '1rem 0' }}>No operations recorded in this time range</p>
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
                        width: trendBarWidth(point.value, data.errorCount),
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
