import { useState, type FormEvent } from 'react';
import { RefreshCw } from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import { useTelemetryEvents } from '../../hooks/use-telemetry';
import {
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

  const handleSearch = (e?: FormEvent) => {
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

      <section className="panel" aria-label="事件筛选">
        <TelemetryFilterPanel
          filter={filterDraft}
          onChange={setFilterDraft}
          onSearch={handleSearch}
          onReset={handleReset}
          variant="events"
        />
      </section>

      <section className="panel dashboard-section" aria-label="事件列表">
        <div className="section-heading">
          <div>
            <p className="eyebrow">Telemetry Records</p>
            <h2>检索结果</h2>
          </div>
          <span className="section-heading__note">
            第 {page} 页 / 共 {totalPages} 页 (共 {total} 条)
          </span>
        </div>

        {items.length === 0 ? (
          <EmptyState
            title="未检索到埋点事件"
            description="当前筛选条件下没有匹配的数据记录，请尝试调整搜索条件或时间窗口。"
          />
        ) : (
          <div className="record-list">
            {items.map((event) => (
              <TelemetryRecordCard
                key={event.eventId}
                record={event}
                expanded={expandedEventId === event.eventId}
                onToggle={() => toggleExpand(event.eventId)}
                variant="event"
              />
            ))}
          </div>
        )}

        <Pagination
          page={page}
          totalPages={totalPages}
          onPageChange={handlePageChange}
          disabled={eventsQuery.isFetching}
        />
      </section>
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
