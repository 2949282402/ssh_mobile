import { useEffect, useState } from 'react';
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

const ALL_SPECIAL_TRIGGERS = [
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

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    try {
      await updateMutation.mutateAsync({
        ...form,
        policy: {
          ...form.policy,
          policyVersion: form.policy.policyVersion + 1,
        },
        updatedAt: new Date().toISOString(),
      });
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

  const toggleSpecialTrigger = (triggerId: string) => {
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

      <form onSubmit={handleSubmit} style={{ display: 'flex', flexDirection: 'column', gap: '1.5rem' }}>
        {/* Client Upload Policy Card */}
        <section className="panel" aria-label="客户端上报策略">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Client Upload Policy</p>
              <h2>客户端动态上报策略</h2>
            </div>
            <Badge tone={form.policy.uploadEnabled ? 'online' : 'warning'} dot>
              {form.policy.uploadEnabled ? `ACTIVE (v${form.policy.policyVersion})` : 'DISABLED'}
            </Badge>
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem', marginTop: '1rem' }}>
            <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', cursor: 'pointer' }}>
              <input
                type="checkbox"
                checked={form.policy.uploadEnabled}
                onChange={(e) => setForm({
                  ...form,
                  policy: { ...form.policy, uploadEnabled: e.target.checked },
                })}
              />
              <strong>启用客户端数据上报 (uploadEnabled)</strong>
            </label>

            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: '1rem' }}>
              <div>
                <label style={{ display: 'block', fontSize: '0.85rem', color: 'var(--ink-soft)', marginBottom: '0.35rem' }}>
                  单批阈值 (batchSizeThreshold, 条)
                </label>
                <input
                  type="number"
                  min={1}
                  max={1000}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.policy.batchSizeThreshold}
                  onChange={(e) => setForm({
                    ...form,
                    policy: { ...form.policy, batchSizeThreshold: Number(e.target.value) },
                  })}
                />
              </div>

              <div>
                <label style={{ display: 'block', fontSize: '0.85rem', color: 'var(--ink-soft)', marginBottom: '0.35rem' }}>
                  定时上报间隔 (timeIntervalSeconds, 秒)
                </label>
                <input
                  type="number"
                  min={5}
                  max={3600}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.policy.timeIntervalSeconds}
                  onChange={(e) => setForm({
                    ...form,
                    policy: { ...form.policy, timeIntervalSeconds: Number(e.target.value) },
                  })}
                />
              </div>

              <div>
                <label style={{ display: 'block', fontSize: '0.85rem', color: 'var(--ink-soft)', marginBottom: '0.35rem' }}>
                  单次上报最大批次 (maxBatchSize, 条)
                </label>
                <input
                  type="number"
                  min={1}
                  max={1000}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.policy.maxBatchSize}
                  onChange={(e) => setForm({
                    ...form,
                    policy: { ...form.policy, maxBatchSize: Number(e.target.value) },
                  })}
                />
              </div>

              <div>
                <label style={{ display: 'block', fontSize: '0.85rem', color: 'var(--ink-soft)', marginBottom: '0.35rem' }}>
                  客户端本地最大记录数 (clientMaxLocalRecords)
                </label>
                <input
                  type="number"
                  min={100}
                  max={1000000}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.policy.clientMaxLocalRecords}
                  onChange={(e) => setForm({
                    ...form,
                    policy: { ...form.policy, clientMaxLocalRecords: Number(e.target.value) },
                  })}
                />
              </div>
            </div>

            <div>
              <span style={{ display: 'block', fontSize: '0.85rem', color: 'var(--ink-soft)', marginBottom: '0.5rem', fontWeight: 600 }}>
                特殊触发场景 (Special Triggers)
              </span>
              <div style={{ display: 'flex', flexDirection: 'column', gap: '0.5rem' }}>
                {ALL_SPECIAL_TRIGGERS.map((t) => (
                  <label key={t.id} style={{ display: 'flex', alignItems: 'flex-start', gap: '0.5rem', cursor: 'pointer' }}>
                    <input
                      type="checkbox"
                      checked={form.policy.specialTriggers.includes(t.id)}
                      onChange={() => toggleSpecialTrigger(t.id)}
                    />
                    <div>
                      <strong style={{ fontSize: '0.9rem' }}>{t.label}</strong>
                      <span style={{ display: 'block', fontSize: '0.8rem', color: 'var(--muted)' }}>{t.desc}</span>
                    </div>
                  </label>
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* Server Retention & Cleaning Card */}
        <section className="panel" aria-label="服务端数据保留与清理">
          <div className="section-heading">
            <div>
              <p className="eyebrow">Retention & Cleaning</p>
              <h2>服务端数据清洗与保留生命周期</h2>
            </div>
            <Database size={18} aria-hidden="true" />
          </div>

          <div style={{ display: 'flex', flexDirection: 'column', gap: '1rem', marginTop: '1rem' }}>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: '1rem' }}>
              <div>
                <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.35rem', cursor: 'pointer' }}>
                  <input
                    type="checkbox"
                    checked={form.retentionTimeEnabled}
                    onChange={(e) => setForm({ ...form, retentionTimeEnabled: e.target.checked })}
                  />
                  <span style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>按时间自动淘汰 (天数)</span>
                </label>
                <input
                  type="number"
                  min={1}
                  max={3650}
                  disabled={!form.retentionTimeEnabled}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.retentionDays}
                  onChange={(e) => setForm({ ...form, retentionDays: Number(e.target.value) })}
                />
              </div>

              <div>
                <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.35rem', cursor: 'pointer' }}>
                  <input
                    type="checkbox"
                    checked={form.retentionRowsEnabled}
                    onChange={(e) => setForm({ ...form, retentionRowsEnabled: e.target.checked })}
                  />
                  <span style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>按最大总行数限制 (行)</span>
                </label>
                <input
                  type="number"
                  min={1000}
                  max={100000000}
                  disabled={!form.retentionRowsEnabled}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.retentionMaxRows}
                  onChange={(e) => setForm({ ...form, retentionMaxRows: Number(e.target.value) })}
                />
              </div>

              <div>
                <label style={{ display: 'flex', alignItems: 'center', gap: '0.5rem', marginBottom: '0.35rem', cursor: 'pointer' }}>
                  <input
                    type="checkbox"
                    checked={form.redisCacheEnabled}
                    onChange={(e) => setForm({ ...form, redisCacheEnabled: e.target.checked })}
                  />
                  <span style={{ fontSize: '0.85rem', color: 'var(--ink-soft)' }}>Redis 诊断流最大缓存 (条)</span>
                </label>
                <input
                  type="number"
                  min={10}
                  max={10000}
                  disabled={!form.redisCacheEnabled}
                  className="button button--quiet"
                  style={{ width: '100%', border: '1px solid var(--line)', padding: '0.5rem', textAlign: 'left' }}
                  value={form.redisMaxRecords}
                  onChange={(e) => setForm({ ...form, redisMaxRecords: Number(e.target.value) })}
                />
              </div>
            </div>

            <InlineNotice tone="neutral">
              幂等保障：`telemetry_ingest_receipts` 幂等收据表记录为永久持久化，绝不参与定时清理，确保重复重传永远不会二次入库。
            </InlineNotice>
          </div>
        </section>

        {/* Footer Actions */}
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: '0.5rem' }}>
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
        <div style={{ marginTop: '1rem' }}>
          <Skeleton className="skeleton-metric" />
        </div>
      </section>
      <section className="panel" style={{ marginTop: '1rem' }}>
        <Skeleton className="skeleton-heading" />
        <div style={{ marginTop: '1rem' }}>
          <Skeleton className="skeleton-metric" />
        </div>
      </section>
    </div>
  );
}
