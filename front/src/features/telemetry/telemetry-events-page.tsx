import { useState } from 'react';
import {
  ChevronDown,
  ChevronLeft,
  ChevronRight,
  ChevronUp,
  RefreshCw,
  Search,
} from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import { useTelemetryEvents } from '../../hooks/use-telemetry';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  PageHeader,
  Skeleton,
} from '../../components/ui';
import type {
  Platform,
  Severity,
  TelemetryFilter,
  TelemetryRecord,
} from '../../schemas/telemetry';

const SEVERITIES: Array<{ label: string; value: Severity }> = [
  { label: 'INFO', value: 'info' },
  { label: 'WARN', value: 'warn' },
  { label: 'ERROR', value: 'error' },
  { label: 'CRITICAL', value: 'critical' },
];

const PLATFORMS: Array<{ label: string; value: Platform }> = [
  { label: 'Android', value: 'android' },
  { label: 'iOS', value: 'ios' },
  { label: 'Linux', value: 'linux' },
  { label: 'macOS', value: 'macos' },
  { label: 'Windows', value: 'windows' },
];

export function TelemetryEventsPage() {
  const [filterDraft, setFilterDraft] = useState<Partial<TelemetryFilter>>({
    timeRange: '24h',
    eventName: '',
    feature: '',
    deviceId: '',
    traceId: '',
    errorCode: '',
    releaseChannel: '',
    page: 1,
    pageSize: 50,
  });

  const [activeFilter, setActiveFilter] = useState<Partial<TelemetryFilter>>({
    timeRange: '24h',
    page: 1,
    pageSize: 50,
  });

  const [expandedEventId, setExpandedEventId] = useState<string | null>(null);

  const eventsQuery = useTelemetryEvents(activeFilter);
  const data = eventsQuery.data;

  const handleSearch = (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    setActiveFilter({
      ...filterDraft,
      page: 1,
    });
  };

  const handleReset = () => {
    const resetValues: Partial<TelemetryFilter> = {
      timeRange: '24h',
      eventName: '',
      feature: '',
      deviceId: '',
      traceId: '',
      severity: undefined,
      platform: undefined,
      errorCode: '',
      releaseChannel: '',
      page: 1,
      pageSize: 50,
    };
    setFilterDraft(resetValues);
    setActiveFilter({
      timeRange: '24h',
      page: 1,
      pageSize: 50,
    });
  };

  const handlePageChange = (newPage: number) => {
    const nextFilter = { ...activeFilter, page: newPage };
    setFilterDraft(nextFilter);
    setActiveFilter(nextFilter);
  };

  const toggleExpand = (eventId: string) => {
    setExpandedEventId((prev) => (prev === eventId ? null : eventId));
  };

  if (eventsQuery.isPending && !data) {
    return <EventsSkeleton />;
  }

  if (eventsQuery.isError && !data) {
    const errorMsg = eventsQuery.error instanceof ApiRequestError
      ? eventsQuery.error.message
      : '无法加载埋点事件列表。';
    return (
      <div className="page">
        <PageHeader
          eyebrow="Telemetry / Explorer"
          title="事件浏览器"
          description="检索与分析全端上报的埋点事件与异常追踪记录。"
        />
        <ErrorState description={errorMsg} onRetry={() => void eventsQuery.refetch()} />
      </div>
    );
  }

  const items = data?.items ?? [];
  const total = data?.total ?? 0;
  const page = data?.page ?? 1;
  const pageSize = data?.pageSize ?? 50;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));

  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Explorer"
        title="事件浏览器"
        description="支持多维过滤检索全端业务埋点事件与异常堆栈。"
        action={(
          <Button
            variant="outline"
            onClick={() => void eventsQuery.refetch()}
            loading={eventsQuery.isFetching}
          >
            <RefreshCw size={15} aria-hidden="true" />
            刷新
          </Button>
        )}
      />

      {/* Filter Toolbar */}
      <section className="panel" aria-label="事件筛选">
        <form onSubmit={handleSearch} style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '0.5rem', alignItems: 'center' }}>
            <div style={{ display: 'flex', gap: '0.25rem', alignItems: 'center' }}>
              {(['1h', '24h', '7d', '30d', 'all'] as const).map((tr) => (
                <Button
                  key={tr}
                  type="button"
                  variant={filterDraft.timeRange === tr ? 'primary' : 'quiet'}
                  onClick={() => setFilterDraft((prev) => ({ ...prev, timeRange: tr }))}
                >
                  {tr === 'all' ? '全部' : tr}
                </Button>
              ))}
            </div>

            <select
              className="button button--quiet"
              style={{ padding: '0.4rem 0.6rem', borderRadius: '6px', border: '1px solid var(--line)' }}
              value={filterDraft.severity ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({
                ...prev,
                severity: (e.target.value || undefined) as Severity | undefined,
              }))}
            >
              <option value="">全部级别 (Severity)</option>
              {SEVERITIES.map((s) => (
                <option key={s.value} value={s.value}>{s.label}</option>
              ))}
            </select>

            <select
              className="button button--quiet"
              style={{ padding: '0.4rem 0.6rem', borderRadius: '6px', border: '1px solid var(--line)' }}
              value={filterDraft.platform ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({
                ...prev,
                platform: (e.target.value || undefined) as Platform | undefined,
              }))}
            >
              <option value="">全部平台 (Platform)</option>
              {PLATFORMS.map((p) => (
                <option key={p.value} value={p.value}>{p.label}</option>
              ))}
            </select>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '0.5rem' }}>
            <input
              type="text"
              placeholder="按事件名搜索..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.eventName ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, eventName: e.target.value }))}
            />
            <input
              type="text"
              placeholder="按模块搜索 (如 terminal, ssh)..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.feature ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, feature: e.target.value }))}
            />
            <input
              type="text"
              placeholder="按设备 ID (deviceId)..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.deviceId ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, deviceId: e.target.value }))}
            />
            <input
              type="text"
              placeholder="按追踪 ID (traceId)..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.traceId ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, traceId: e.target.value }))}
            />
            <input
              type="text"
              placeholder="按错误码 (errorCode)..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.errorCode ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, errorCode: e.target.value }))}
            />
            <input
              type="text"
              placeholder="按发布渠道 (releaseChannel)..."
              className="button button--quiet"
              style={{ border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
              value={filterDraft.releaseChannel ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({ ...prev, releaseChannel: e.target.value }))}
            />
          </div>

          <div style={{ display: 'flex', gap: '0.5rem', justifyContent: 'flex-end', marginTop: '0.25rem' }}>
            <Button type="button" variant="quiet" onClick={handleReset}>
              重置
            </Button>
            <Button type="submit" variant="primary">
              <Search size={15} aria-hidden="true" />
              查询
            </Button>
          </div>
        </form>
      </section>

      {/* Events Table / List */}
      <section className="panel" aria-label="事件列表" style={{ marginTop: '1rem' }}>
        <div className="section-heading">
          <div>
            <p className="eyebrow">Telemetry Records</p>
            <h2>检索结果</h2>
          </div>
          <span style={{ color: 'var(--muted)', fontSize: '0.9rem' }}>
            第 {page} 页 / 共 {totalPages} 页 (共 {total} 条)
          </span>
        </div>

        {items.length === 0 ? (
          <EmptyState
            title="未检索到埋点事件"
            description="当前筛选条件下没有匹配的数据记录，请尝试调整搜索条件或时间窗口。"
          />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', marginTop: '1rem' }}>
            {items.map((event) => (
              <EventRowItem
                key={event.eventId}
                event={event}
                expanded={expandedEventId === event.eventId}
                onToggle={() => toggleExpand(event.eventId)}
              />
            ))}
          </div>
        )}

        {/* Pagination Footer */}
        {totalPages > 1 ? (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '1.5rem', paddingTop: '1rem', borderTop: '1px solid var(--line)' }}>
            <Button
              variant="quiet"
              disabled={page <= 1 || eventsQuery.isFetching}
              onClick={() => handlePageChange(page - 1)}
            >
              <ChevronLeft size={16} aria-hidden="true" />
              上一页
            </Button>
            <span style={{ color: 'var(--ink-soft)', fontSize: '0.9rem' }}>
              第 {page} / {totalPages} 页
            </span>
            <Button
              variant="quiet"
              disabled={page >= totalPages || eventsQuery.isFetching}
              onClick={() => handlePageChange(page + 1)}
            >
              下一页
              <ChevronRight size={16} aria-hidden="true" />
            </Button>
          </div>
        ) : null}
      </section>
    </div>
  );
}

function EventRowItem({
  event,
  expanded,
  onToggle,
}: {
  event: TelemetryRecord;
  expanded: boolean;
  onToggle: () => void;
}) {
  const tone = event.severity === 'critical'
    ? 'danger'
    : event.severity === 'error'
      ? 'warning'
      : event.severity === 'warn'
        ? 'warning'
        : 'online';

  return (
    <div
      style={{
        border: '1px solid var(--line)',
        borderRadius: '8px',
        background: 'var(--paper)',
        overflow: 'hidden',
        transition: 'border-color 0.2s',
      }}
    >
      <div
        style={{
          display: 'flex',
          justifyContent: 'space-between',
          alignItems: 'center',
          padding: '0.75rem 1rem',
          cursor: 'pointer',
          background: expanded ? 'var(--canvas)' : 'inherit',
        }}
        onClick={onToggle}
      >
        <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center', flexWrap: 'wrap' }}>
          <Badge tone={tone} dot>
            {event.severity.toUpperCase()}
          </Badge>
          <strong className="type-mono" style={{ fontSize: '0.95rem' }}>
            {event.eventName}
          </strong>
          <span style={{ color: 'var(--muted)', fontSize: '0.85rem' }}>
            v{event.eventVersion} · {event.feature}
          </span>
          {event.releaseChannel ? (
            <span style={{ color: 'var(--muted)', fontSize: '0.85rem' }}>
              channel: {event.releaseChannel}
            </span>
          ) : null}
          <span className="type-mono" style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>
            {event.deviceId}
          </span>
          {event.error ? (
            <span style={{ color: 'var(--coral)', fontSize: '0.85rem', fontWeight: 500 }}>
              [{event.error.errorCode}] {event.error.message}
            </span>
          ) : null}
        </div>

        <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center' }}>
          <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>
            {new Date(event.occurredAt).toLocaleString()}
          </span>
          <Button
            variant="quiet"
            onClick={(e) => {
              e.stopPropagation();
              onToggle();
            }}
            aria-label={`查看详情 ${event.eventName}`}
          >
            {expanded ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
            {expanded ? '收起详情' : '查看详情'}
          </Button>
        </div>
      </div>

      {expanded ? (
        <div style={{ padding: '1rem', borderTop: '1px solid var(--line)', background: 'var(--canvas)' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '0.75rem', marginBottom: '1rem' }}>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Event ID:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{event.eventId}</div>
            </div>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Session ID:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{event.sessionId}</div>
            </div>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Trace ID:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{event.traceId}</div>
            </div>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>App Version:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{event.appVersion} ({event.buildNumber}) / {event.platform}</div>
            </div>
            {event.releaseChannel ? (
              <div>
                <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Release Channel:</span>
                <div className="type-mono" style={{ fontSize: '0.85rem' }}>{event.releaseChannel}</div>
              </div>
            ) : null}
          </div>

          {event.error ? (
            <div style={{ marginBottom: '1rem', padding: '0.75rem', background: 'var(--coral-pale)', borderRadius: '6px', border: '1px solid var(--coral)' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.5rem' }}>
                <strong style={{ color: 'var(--coral)' }}>Error Details [{event.error.errorCode}]</strong>
                <span style={{ fontSize: '0.85rem', color: 'var(--coral)' }}>Category: {event.error.category} {event.error.terminalFailure ? '(Terminal)' : ''}</span>
              </div>
              <p style={{ margin: 0, color: 'var(--ink)' }}>{event.error.message}</p>
              {event.error.stackTrace ? (
                <pre
                  style={{
                    margin: '0.5rem 0 0 0',
                    padding: '0.5rem',
                    background: 'rgba(0, 0, 0, 0.05)',
                    borderRadius: '4px',
                    fontSize: '0.8rem',
                    overflowX: 'auto',
                    whiteSpace: 'pre-wrap',
                  }}
                >
                  {event.error.stackTrace}
                </pre>
              ) : null}
            </div>
          ) : null}

          <div>
            <span style={{ fontSize: '0.8rem', color: 'var(--muted)', fontWeight: 600 }}>Properties Payload:</span>
            <pre
              style={{
                margin: '0.25rem 0 0 0',
                padding: '0.75rem',
                background: 'var(--paper)',
                border: '1px solid var(--line)',
                borderRadius: '6px',
                fontSize: '0.85rem',
                overflowX: 'auto',
              }}
            >
              {JSON.stringify(event.properties, null, 2)}
            </pre>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function EventsSkeleton() {
  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Explorer"
        title="事件浏览器"
        description="正在读取埋点事件记录..."
      />
      <section className="panel">
        <Skeleton className="skeleton-heading" />
      </section>
      <section className="panel" style={{ marginTop: '1rem' }}>
        {Array.from({ length: 5 }, (_, index) => (
          <div key={index} style={{ margin: '0.5rem 0' }}>
            <Skeleton className="skeleton-metric" />
          </div>
        ))}
      </section>
    </div>
  );
}
