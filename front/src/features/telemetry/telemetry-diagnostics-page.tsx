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
import { useTelemetryDiagnostics } from '../../hooks/use-telemetry';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  PageHeader,
  Skeleton,
} from '../../components/ui';
import type {
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

export function TelemetryDiagnosticsPage() {
  const [filterDraft, setFilterDraft] = useState<Partial<TelemetryFilter>>({
    feature: '',
    deviceId: '',
    traceId: '',
    errorCode: '',
    page: 1,
    pageSize: 20,
  });

  const [activeFilter, setActiveFilter] = useState<Partial<TelemetryFilter>>({
    page: 1,
    pageSize: 20,
  });

  const [expandedLogId, setExpandedLogId] = useState<string | null>(null);

  const diagQuery = useTelemetryDiagnostics(activeFilter);
  const data = diagQuery.data;

  const handleSearch = (e?: React.FormEvent) => {
    if (e) e.preventDefault();
    setActiveFilter({
      ...filterDraft,
      page: 1,
    });
  };

  const handleReset = () => {
    const resetValues: Partial<TelemetryFilter> = {
      feature: '',
      deviceId: '',
      traceId: '',
      severity: undefined,
      errorCode: '',
      page: 1,
      pageSize: 20,
    };
    setFilterDraft(resetValues);
    setActiveFilter({
      page: 1,
      pageSize: 20,
    });
  };

  const handlePageChange = (newPage: number) => {
    const nextFilter = { ...activeFilter, page: newPage };
    setFilterDraft(nextFilter);
    setActiveFilter(nextFilter);
  };

  const toggleExpand = (eventId: string) => {
    setExpandedLogId((prev) => (prev === eventId ? null : eventId));
  };

  if (diagQuery.isPending && !data) {
    return <DiagnosticsSkeleton />;
  }

  if (diagQuery.isError && !data) {
    const errorMsg = diagQuery.error instanceof ApiRequestError
      ? diagQuery.error.message
      : '无法加载诊断日志，请检查服务连接。';
    return (
      <div className="page">
        <PageHeader
          eyebrow="Telemetry / Diagnostics"
          title="诊断日志"
          description="查看全端异常捕获、故障追踪与实时调试诊断日志。"
        />
        <ErrorState description={errorMsg} onRetry={() => void diagQuery.refetch()} />
      </div>
    );
  }

  const items = data?.items ?? [];
  const total = data?.total ?? 0;
  const page = data?.page ?? 1;
  const pageSize = data?.pageSize ?? 20;
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  const source = data?.source ?? 'redis_cache';

  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Diagnostics"
        title="诊断日志"
        description="全端异常报错堆栈、链路诊断日志实时流与故障分析。"
        action={(
          <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center' }}>
            <Badge tone={source === 'redis_cache' ? 'online' : 'warning'} dot>
              {source === 'redis_cache' ? 'REDIS CACHE' : 'MYSQL FALLBACK'}
            </Badge>
            <Button
              variant="outline"
              onClick={() => void diagQuery.refetch()}
              loading={diagQuery.isFetching}
            >
              <RefreshCw size={15} aria-hidden="true" />
              刷新
            </Button>
          </div>
        )}
      />

      <div className="snapshot-meta">
        <Badge tone="neutral">每 5 秒自动轮询更新</Badge>
        <span>
          {source === 'redis_cache'
            ? '从 Redis Stream 诊断流缓存高速读取最新 1000 条诊断记录'
            : 'Redis 暂未启用或降级，直接查询 MySQL 持久层'}
        </span>
      </div>

      {/* Filter Bar */}
      <section className="panel" aria-label="诊断日志筛选" style={{ marginTop: '1rem' }}>
        <form onSubmit={handleSearch} style={{ display: 'flex', flexDirection: 'column', gap: '0.75rem' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(180px, 1fr))', gap: '0.5rem' }}>
            <select
              className="button button--quiet"
              style={{ padding: '0.4rem 0.6rem', borderRadius: '6px', border: '1px solid var(--line)' }}
              value={filterDraft.severity ?? ''}
              onChange={(e) => setFilterDraft((prev) => ({
                ...prev,
                severity: (e.target.value || undefined) as Severity | undefined,
              }))}
            >
              <option value="">全部日志级别</option>
              {SEVERITIES.map((s) => (
                <option key={s.value} value={s.value}>{s.label}</option>
              ))}
            </select>

            <input
              type="text"
              placeholder="按模块搜索 (如 sftp, ssh)..."
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
          </div>

          <div style={{ display: 'flex', gap: '0.5rem', justifyContent: 'flex-end' }}>
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

      {/* Logs Stream View */}
      <section className="panel" aria-label="诊断日志列表" style={{ marginTop: '1rem' }}>
        <div className="section-heading">
          <div>
            <p className="eyebrow">Diagnostic Stream</p>
            <h2>日志流条目</h2>
          </div>
          <span style={{ color: 'var(--muted)', fontSize: '0.9rem' }}>
            第 {page} 页 / 共 {totalPages} 页 (共 {total} 条)
          </span>
        </div>

        {items.length === 0 ? (
          <EmptyState
            title="未检索到诊断日志"
            description="当前筛选条件下没有异常或诊断日志，说明系统运行平稳或无上报记录。"
          />
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem', marginTop: '1rem' }}>
            {items.map((log) => (
              <DiagnosticLogItem
                key={log.eventId}
                log={log}
                expanded={expandedLogId === log.eventId}
                onToggle={() => toggleExpand(log.eventId)}
              />
            ))}
          </div>
        )}

        {/* Pagination Footer */}
        {totalPages > 1 ? (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '1.5rem', paddingTop: '1rem', borderTop: '1px solid var(--line)' }}>
            <Button
              variant="quiet"
              disabled={page <= 1 || diagQuery.isFetching}
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
              disabled={page >= totalPages || diagQuery.isFetching}
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

function DiagnosticLogItem({
  log,
  expanded,
  onToggle,
}: {
  log: TelemetryRecord;
  expanded: boolean;
  onToggle: () => void;
}) {
  const tone = log.severity === 'critical'
    ? 'danger'
    : log.severity === 'error'
      ? 'warning'
      : log.severity === 'warn'
        ? 'warning'
        : 'online';

  return (
    <div
      style={{
        border: '1px solid var(--line)',
        borderRadius: '8px',
        background: 'var(--paper)',
        overflow: 'hidden',
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
            {log.severity.toUpperCase()}
          </Badge>
          <strong className="type-mono" style={{ fontSize: '0.95rem' }}>
            {log.eventName}
          </strong>
          <span style={{ color: 'var(--muted)', fontSize: '0.85rem' }}>
            {log.feature}
          </span>
          <span className="type-mono" style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>
            {log.deviceId}
          </span>
          {log.error ? (
            <span style={{ color: 'var(--coral)', fontSize: '0.85rem', fontWeight: 500 }}>
              [{log.error.errorCode}] {log.error.message}
            </span>
          ) : null}
        </div>

        <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center' }}>
          <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>
            {new Date(log.occurredAt).toLocaleTimeString()}
          </span>
          <Button
            variant="quiet"
            onClick={(e) => {
              e.stopPropagation();
              onToggle();
            }}
            aria-label={`查看日志详情 ${log.eventName}`}
          >
            {expanded ? <ChevronUp size={16} /> : <ChevronDown size={16} />}
            {expanded ? '收起' : '查看详情'}
          </Button>
        </div>
      </div>

      {expanded ? (
        <div style={{ padding: '1rem', borderTop: '1px solid var(--line)', background: 'var(--canvas)' }}>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: '0.75rem', marginBottom: '1rem' }}>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Event ID / Trace:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{log.eventId} / {log.traceId}</div>
            </div>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Session / Device:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{log.sessionId} / {log.deviceId}</div>
            </div>
            <div>
              <span style={{ fontSize: '0.8rem', color: 'var(--muted)' }}>Platform / Version:</span>
              <div className="type-mono" style={{ fontSize: '0.85rem' }}>{log.platform} ({log.appVersion}+{log.buildNumber})</div>
            </div>
          </div>

          {log.error ? (
            <div style={{ marginBottom: '1rem', padding: '0.75rem', background: 'var(--coral-pale)', borderRadius: '6px', border: '1px solid var(--coral)' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: '0.5rem' }}>
                <strong style={{ color: 'var(--coral)' }}>Error Code: [{log.error.errorCode}]</strong>
                <span style={{ fontSize: '0.85rem', color: 'var(--coral)' }}>Category: {log.error.category}</span>
              </div>
              <p style={{ margin: 0, color: 'var(--ink)' }}>{log.error.message}</p>
              {log.error.stackTrace ? (
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
                  {log.error.stackTrace}
                </pre>
              ) : null}
            </div>
          ) : null}

          {Object.keys(log.properties || {}).length > 0 ? (
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
                {JSON.stringify(log.properties, null, 2)}
              </pre>
            </div>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function DiagnosticsSkeleton() {
  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Diagnostics"
        title="诊断日志"
        description="正在读取全端诊断日志流..."
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
