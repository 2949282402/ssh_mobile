import { useState, type FormEvent } from 'react';
import { RefreshCw } from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import { useTelemetryDiagnostics } from '../../hooks/use-telemetry';
import {
  Badge,
  Button,
  EmptyState,
  ErrorState,
  PageHeader,
  Pagination,
  Skeleton,
} from '../../components/ui';
import type { TelemetryFilter } from '../../schemas/telemetry';
import { TelemetryFilterPanel } from './components/telemetry-filter-panel';
import { TelemetryRecordCard } from './components/telemetry-record-card';

export function TelemetryDiagnosticsPage() {
  const [filterDraft, setFilterDraft] = useState<Partial<TelemetryFilter>>({
    feature: '',
    deviceId: '',
    traceId: '',
    errorCode: '',
    releaseChannel: '',
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

  const handleSearch = (e?: FormEvent) => {
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
      releaseChannel: '',
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
          description="查看全端异常捕获、故障追踪与近实时调试诊断日志。"
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
  const usingRedisCache = source === 'redis_cache';

  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Diagnostics"
        title="诊断日志"
        description="全端异常报错堆栈、链路诊断日志与故障分析（每 5 秒轮询更新）。"
        action={(
          <div className="dashboard-toolbar">
            <Badge tone={usingRedisCache ? 'online' : 'neutral'} dot>
              {usingRedisCache ? 'REDIS CACHE' : 'MYSQL'}
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
          {usingRedisCache
            ? '从 Redis 诊断热缓存读取最近诊断记录'
            : '从 MySQL 权威持久层读取诊断记录'}
        </span>
      </div>

      <section className="panel" aria-label="诊断日志筛选">
        <TelemetryFilterPanel
          filter={filterDraft}
          onChange={setFilterDraft}
          onSearch={handleSearch}
          onReset={handleReset}
          variant="diagnostics"
        />
      </section>

      <section className="panel dashboard-section" aria-label="诊断日志列表">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Diagnostic Stream</p>
            <h2>诊断日志条目</h2>
          </div>
          <span className="section-heading__note">
            第 {page} 页 / 共 {totalPages} 页 (共 {total} 条)
          </span>
        </div>

        {items.length === 0 ? (
          <EmptyState
            title="未检索到诊断日志"
            description="当前筛选条件下没有异常或诊断日志，说明系统运行平稳或无上报记录。"
          />
        ) : (
          <div className="record-list">
            {items.map((log) => (
              <TelemetryRecordCard
                key={log.eventId}
                record={log}
                expanded={expandedLogId === log.eventId}
                onToggle={() => toggleExpand(log.eventId)}
                variant="diagnostic"
              />
            ))}
          </div>
        )}

        <Pagination
          page={page}
          totalPages={totalPages}
          onPageChange={handlePageChange}
          disabled={diagQuery.isFetching}
        />
      </section>
    </div>
  );
}

function DiagnosticsSkeleton() {
  return (
    <div className="page">
      <PageHeader
        eyebrow="Telemetry / Diagnostics"
        title="诊断日志"
        description="正在读取全端诊断日志..."
      />
      <section className="panel">
        <Skeleton className="skeleton-heading" />
      </section>
      <section className="panel dashboard-section">
        {Array.from({ length: 5 }, (_, index) => (
          <div key={index} className="skeleton-row">
            <Skeleton className="skeleton-metric" />
          </div>
        ))}
      </section>
    </div>
  );
}
