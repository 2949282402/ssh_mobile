import { useEffect, useState, type FormEvent } from 'react';
import {
  Database,
  RefreshCw,
  RotateCcw,
  Save,
} from 'lucide-react';
import { ApiRequestError } from '../../api/errors';
import {
  useTelemetrySettings,
  useUpdateTelemetrySettings,
} from '../../hooks/use-telemetry';
import {
  Badge,
  Button,
  ErrorState,
  InlineNotice,
  PageHeader,
  Skeleton,
} from '../../components/ui';
import { useToast } from '../../components/toast';
import type { TelemetrySettings } from '../../schemas/telemetry';

type TelemetryTrigger = TelemetrySettings['policy']['specialTriggers'][number];

const ALL_SPECIAL_TRIGGERS: Array<{ id: TelemetryTrigger; label: string; desc: string }> = [
  { id: 'highPriorityError', label: '严重错误即时上报 (highPriorityError)', desc: '遇到 error/critical 严重异常立刻触发 Flush' },
  { id: 'appBackground', label: 'App 切到后台 (appBackground)', desc: '进入后台时立刻清空本地积压' },
  { id: 'networkRecovered', label: '网络重新连接 (networkRecovered)', desc: '网络恢复正常后自动尝试上报' },
  { id: 'appForegroundWithBacklog', label: '前台积压检测 (appForegroundWithBacklog)', desc: '冷启动或回到前台且有积压时调度上报' },
];

export function TelemetrySettingsPage() {
  const toast = useToast();
  const settingsQuery = useTelemetrySettings();
  const updateMutation = useUpdateTelemetrySettings();

  const [form, setForm] = useState<TelemetrySettings | null>(null);

  useEffect(() => {
    if (settingsQuery.data) {
      setForm(settingsQuery.data);
    }
  }, [settingsQuery.data]);

  if (settingsQuery.isPending && !form) {
    return <SettingsSkeleton />;
  }

  if (settingsQuery.isError && !form) {
    const errorMsg = settingsQuery.error instanceof ApiRequestError
      ? settingsQuery.error.message
      : '无法加载埋点与保留配置。';
    return (
      <div className="page page--narrow">
        <PageHeader
          eyebrow="Telemetry / Settings"
          title="埋点与策略设置"
          description="管理客户端动态上报策略、定时参数与服务端数据清洗保留规则。"
        />
        <ErrorState description={errorMsg} onRetry={() => void settingsQuery.refetch()} />
      </div>
    );
  }

  if (!form) return null;

  const handleSubmit = async (e: FormEvent) => {
    e.preventDefault();
    try {
      const sanitizedSettings = {
        ...form,
        policy: {
          ...form.policy,
          batchSizeThreshold: Math.min(1000, Math.max(1, form.policy.batchSizeThreshold || 50)),
          timeIntervalSeconds: Math.min(3600, Math.max(5, form.policy.timeIntervalSeconds || 60)),
          maxBatchSize: Math.min(100, Math.max(1, form.policy.maxBatchSize || 100)),
          clientMaxLocalRecords: Math.min(1000000, Math.max(100, form.policy.clientMaxLocalRecords || 10000)),
          policyVersion: form.policy.policyVersion + 1,
        },
        retentionDays: Math.min(3650, Math.max(1, form.retentionDays || 30)),
        retentionMaxRows: Math.min(100000000, Math.max(1000, form.retentionMaxRows || 500000)),
        redisMaxRecords: Math.min(10000, Math.max(10, form.redisMaxRecords || 1000)),
        updatedAt: new Date().toISOString(),
      };
      await updateMutation.mutateAsync(sanitizedSettings);
      toast.push('埋点与保留配置已更新。', 'success');
    } catch (err) {
      const msg = err instanceof ApiRequestError ? err.message : '更新配置失败，请检查参数。';
      toast.push(msg, 'error');
    }
  };

  const handleResetDefaults = () => {
    setForm({
      policy: {
        uploadEnabled: true,
        batchSizeThreshold: 50,
        timeIntervalSeconds: 60,
        maxBatchSize: 100,
        clientMaxLocalRecords: 10000,
        specialTriggers: [
          'highPriorityError',
          'appBackground',
          'networkRecovered',
          'appForegroundWithBacklog',
        ],
        policyVersion: (form?.policy.policyVersion ?? 1) + 1,
      },
      retentionDays: 30,
      retentionMaxRows: 500000,
      retentionTimeEnabled: true,
      retentionRowsEnabled: true,
      redisCacheEnabled: true,
      redisMaxRecords: 1000,
      updatedAt: new Date().toISOString(),
    });
  };

  const toggleSpecialTrigger = (triggerId: TelemetryTrigger) => {
    const current = form.policy.specialTriggers || [];
    const exists = current.includes(triggerId);
    setForm({
      ...form,
      policy: {
        ...form.policy,
        specialTriggers: exists
          ? current.filter((t) => t !== triggerId)
          : [...current, triggerId],
      },
    });
  };

  return (
    <div className="page page--narrow">
      <PageHeader
        eyebrow="Telemetry / Settings"
        title="埋点与策略设置"
        description="动态调控全端上报行为、安全阈值与服务端数据清理生命周期。"
        action={(
          <Button
            variant="outline"
            onClick={() => void settingsQuery.refetch()}
            loading={settingsQuery.isFetching}
          >
            <RefreshCw size={15} aria-hidden="true" />
            重新拉取
          </Button>
        )}
      />

      <form className="settings-form" onSubmit={handleSubmit}>
        {/* Client Upload Policy Card */}
        <section className="panel settings-section" aria-label="客户端上报策略">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Client Upload Policy</p>
              <h2>客户端动态上报策略</h2>
            </div>
            <Badge tone={form.policy.uploadEnabled ? 'online' : 'warning'} dot>
              {form.policy.uploadEnabled ? `ACTIVE (v${form.policy.policyVersion})` : 'DISABLED'}
            </Badge>
          </div>

          <div className="settings-option-card">
            <label className="form-check">
              <input
                type="checkbox"
                checked={form.policy.uploadEnabled}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, uploadEnabled: e.target.checked },
                })}
              />
              <div>
                <strong>启用客户端数据上报 (uploadEnabled)</strong>
                <span>控制客户端 SDK 是否上报业务与诊断埋点数据</span>
              </div>
            </label>
          </div>

          <div className="form-grid form-grid--2col">
            <div className="form-field">
              <label className="form-label" htmlFor="setting-batch-size">
                单批阈值 (batchSizeThreshold, 条)
              </label>
              <input
                id="setting-batch-size"
                type="number"
                min={1}
                max={1000}
                className="form-control"
                value={form.policy.batchSizeThreshold}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, batchSizeThreshold: Number(e.target.value) },
                })}
              />
            </div>

            <div className="form-field">
              <label className="form-label" htmlFor="setting-time-interval">
                定时上报间隔 (timeIntervalSeconds, 秒)
              </label>
              <input
                id="setting-time-interval"
                type="number"
                min={5}
                max={3600}
                className="form-control"
                value={form.policy.timeIntervalSeconds}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, timeIntervalSeconds: Number(e.target.value) },
                })}
              />
            </div>

            <div className="form-field">
              <label className="form-label" htmlFor="setting-max-batch">
                单次上报最大批次 (maxBatchSize, 条)
              </label>
              <input
                id="setting-max-batch"
                type="number"
                min={1}
                max={100}
                className="form-control"
                value={form.policy.maxBatchSize}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, maxBatchSize: Number(e.target.value) },
                })}
              />
            </div>

            <div className="form-field">
              <label className="form-label" htmlFor="setting-max-records">
                客户端本地最大记录数 (clientMaxLocalRecords)
              </label>
              <input
                id="setting-max-records"
                type="number"
                min={100}
                max={1000000}
                className="form-control"
                value={form.policy.clientMaxLocalRecords}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, clientMaxLocalRecords: Number(e.target.value) },
                })}
              />
            </div>
          </div>

          <div>
            <p className="settings-group-label">特殊触发场景 (Special Triggers)</p>
            <div className="form-grid form-grid--2col" style={{ marginTop: '8px' }}>
              {ALL_SPECIAL_TRIGGERS.map((t) => (
                <div key={t.id} className="settings-option-card">
                  <label className="form-check">
                    <input
                      type="checkbox"
                      checked={form.policy.specialTriggers.includes(t.id)}
                      onChange={() => toggleSpecialTrigger(t.id)}
                    />
                    <div>
                      <strong>{t.label}</strong>
                      <span>{t.desc}</span>
                    </div>
                  </label>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* Server Retention & Cleaning Card */}
        <section className="panel settings-section" aria-label="服务端数据保留与清理">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Retention & Cleaning</p>
              <h2>服务端数据清洗与保留生命周期</h2>
            </div>
            <Database size={18} aria-hidden="true" className="section-heading__icon" />
          </div>

          <div className="form-grid form-grid--3col">
            <div className="form-field">
              <label className="form-check" htmlFor="setting-retention-time">
                <input
                  id="setting-retention-time"
                  type="checkbox"
                  checked={form.retentionTimeEnabled}
                  onChange={(e) => setForm({ ...form, retentionTimeEnabled: e.target.checked })}
                />
                <span className="form-label">按时间自动淘汰 (天数)</span>
              </label>
              <input
                type="number"
                min={1}
                max={3650}
                disabled={!form.retentionTimeEnabled}
                className="form-control"
                value={form.retentionDays}
                onChange={(e) => setForm({ ...form, retentionDays: Number(e.target.value) })}
                aria-label="按时间自动淘汰天数"
              />
            </div>

            <div className="form-field">
              <label className="form-check" htmlFor="setting-retention-rows">
                <input
                  id="setting-retention-rows"
                  type="checkbox"
                  checked={form.retentionRowsEnabled}
                  onChange={(e) => setForm({ ...form, retentionRowsEnabled: e.target.checked })}
                />
                <span className="form-label">按最大总行数限制 (行)</span>
              </label>
              <input
                type="number"
                min={1000}
                max={100000000}
                disabled={!form.retentionRowsEnabled}
                className="form-control"
                value={form.retentionMaxRows}
                onChange={(e) => setForm({ ...form, retentionMaxRows: Number(e.target.value) })}
                aria-label="按最大总行数限制"
              />
            </div>

            <div className="form-field">
              <label className="form-check" htmlFor="setting-redis-cache">
                <input
                  id="setting-redis-cache"
                  type="checkbox"
                  checked={form.redisCacheEnabled}
                  onChange={(e) => setForm({ ...form, redisCacheEnabled: e.target.checked })}
                />
                <span className="form-label">Redis 诊断热缓存最大条数</span>
              </label>
              <input
                type="number"
                min={10}
                max={10000}
                disabled={!form.redisCacheEnabled}
                className="form-control"
                value={form.redisMaxRecords}
                onChange={(e) => setForm({ ...form, redisMaxRecords: Number(e.target.value) })}
                aria-label="Redis 诊断热缓存最大条数"
              />
            </div>
          </div>

          <InlineNotice tone="neutral">
            幂等保障：<code>telemetry_ingest_receipts</code> 幂等收据表记录为永久持久化，绝不参与定时清理，确保重复重传永远不会二次入库。
          </InlineNotice>
        </section>

        {/* Footer Actions */}
        <div className="settings-actions">
          <Button type="button" variant="quiet" onClick={handleResetDefaults}>
            <RotateCcw size={15} aria-hidden="true" />
            恢复默认推荐配置
          </Button>

          <Button type="submit" variant="primary" loading={updateMutation.isPending}>
            <Save size={15} aria-hidden="true" />
            保存配置
          </Button>
        </div>
      </form>
    </div>
  );
}

function SettingsSkeleton() {
  return (
    <div className="page page--narrow">
      <PageHeader
        eyebrow="Telemetry / Settings"
        title="埋点与策略设置"
        description="正在读取服务端配置与策略..."
      />
      <section className="panel">
        <Skeleton className="skeleton-heading" />
        <div className="skeleton-row" style={{ marginTop: '16px' }}>
          <Skeleton className="skeleton-metric" />
        </div>
      </section>
      <section className="panel dashboard-section">
        <Skeleton className="skeleton-heading" />
        <div className="skeleton-row" style={{ marginTop: '16px' }}>
          <Skeleton className="skeleton-metric" />
        </div>
      </section>
    </div>
  );
}
