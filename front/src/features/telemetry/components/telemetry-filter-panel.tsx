import type { FormEvent, ReactNode } from 'react';
import { Search } from 'lucide-react';
import { Button } from '../../../components/ui';
import type { Platform, Severity, TelemetryFilter } from '../../../schemas/telemetry';

const SEVERITY_OPTIONS: Array<{ label: string; value: Severity }> = [
  { label: 'INFO', value: 'info' },
  { label: 'WARN', value: 'warn' },
  { label: 'ERROR', value: 'error' },
  { label: 'CRITICAL', value: 'critical' },
];

const PLATFORM_OPTIONS: Array<{ label: string; value: Platform }> = [
  { label: 'Android', value: 'android' },
  { label: 'iOS', value: 'ios' },
  { label: 'Linux', value: 'linux' },
  { label: 'macOS', value: 'macos' },
  { label: 'Windows', value: 'windows' },
];

export function TelemetryFilterPanel({
  filter,
  onChange,
  onSearch,
  onReset,
  variant = 'events',
  showPlatform,
  showEventName,
  showTimeRange,
  featurePlaceholder,
}: {
  filter: Partial<TelemetryFilter>;
  onChange: (updater: (prev: Partial<TelemetryFilter>) => Partial<TelemetryFilter>) => void;
  onSearch: (e?: FormEvent) => void;
  onReset: () => void;
  variant?: 'events' | 'diagnostics';
  showPlatform?: boolean;
  showEventName?: boolean;
  showTimeRange?: boolean;
  featurePlaceholder?: string;
}): ReactNode {
  const isEvents = variant === 'events';
  const effectiveShowPlatform = showPlatform ?? isEvents;
  const effectiveShowEventName = showEventName ?? isEvents;
  const effectiveShowTimeRange = showTimeRange ?? isEvents;
  const effectivePlaceholder = featurePlaceholder ?? (isEvents
    ? '按模块搜索 (如 terminal, ssh)...'
    : '按模块搜索 (如 sftp, ssh)...');

  return (
    <form className="filter-panel" onSubmit={onSearch}>
      <div className="filter-panel__tier">
        {effectiveShowTimeRange ? (
          <div className="filter-group" role="group" aria-label="时间区间筛选">
            {(['1h', '24h', '7d', '30d', 'all'] as const).map((tr) => (
              <button
                key={tr}
                type="button"
                className={`filter-button${filter.timeRange === tr ? ' filter-button--active' : ''}`}
                onClick={() => onChange((prev) => ({ ...prev, timeRange: tr }))}
                aria-pressed={filter.timeRange === tr}
              >
                {tr === 'all' ? '全部' : tr}
              </button>
            ))}
          </div>
        ) : null}

        <select
          className="form-select"
          value={filter.severity ?? ''}
          onChange={(e) => onChange((prev) => ({
            ...prev,
            severity: (e.target.value || undefined) as Severity | undefined,
          }))}
          aria-label="日志与事件级别"
        >
          <option value="">{effectiveShowPlatform ? '全部级别 (Severity)' : '全部日志级别'}</option>
          {SEVERITY_OPTIONS.map((s) => (
            <option key={s.value} value={s.value}>{s.label}</option>
          ))}
        </select>

        {effectiveShowPlatform ? (
          <select
            className="form-select"
            value={filter.platform ?? ''}
            onChange={(e) => onChange((prev) => ({
              ...prev,
              platform: (e.target.value || undefined) as Platform | undefined,
            }))}
            aria-label="操作系统平台"
          >
            <option value="">全部平台 (Platform)</option>
            {PLATFORM_OPTIONS.map((p) => (
              <option key={p.value} value={p.value}>{p.label}</option>
            ))}
          </select>
        ) : null}
      </div>

      <div className="filter-panel__grid">
        {effectiveShowEventName ? (
          <input
            type="text"
            placeholder="按事件名搜索..."
            className="form-control"
            value={filter.eventName ?? ''}
            onChange={(e) => onChange((prev) => ({ ...prev, eventName: e.target.value }))}
            aria-label="事件名称"
          />
        ) : null}

        <input
          type="text"
          placeholder={effectivePlaceholder}
          className="form-control"
          value={filter.feature ?? ''}
          onChange={(e) => onChange((prev) => ({ ...prev, feature: e.target.value }))}
          aria-label="功能模块"
        />

        <input
          type="text"
          placeholder="按设备 ID (deviceId)..."
          className="form-control"
          value={filter.deviceId ?? ''}
          onChange={(e) => onChange((prev) => ({ ...prev, deviceId: e.target.value }))}
          aria-label="设备 ID"
        />

        <input
          type="text"
          placeholder="按追踪 ID (traceId)..."
          className="form-control"
          value={filter.traceId ?? ''}
          onChange={(e) => onChange((prev) => ({ ...prev, traceId: e.target.value }))}
          aria-label="追踪 ID"
        />

        <input
          type="text"
          placeholder="按错误码 (errorCode)..."
          className="form-control"
          value={filter.errorCode ?? ''}
          onChange={(e) => onChange((prev) => ({ ...prev, errorCode: e.target.value }))}
          aria-label="错误码"
        />

        <input
          type="text"
          placeholder="按发布渠道 (releaseChannel)..."
          className="form-control"
          value={filter.releaseChannel ?? ''}
          onChange={(e) => onChange((prev) => ({ ...prev, releaseChannel: e.target.value }))}
          aria-label="发布渠道"
        />
      </div>

      <div className="filter-panel__actions">
        <Button type="button" variant="quiet" onClick={onReset}>
          重置
        </Button>
        <Button type="submit" variant="primary">
          <Search size={15} aria-hidden="true" />
          查询
        </Button>
      </div>
    </form>
  );
}
