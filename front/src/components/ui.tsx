import type { ButtonHTMLAttributes, ReactNode } from 'react';
import {
  AlertTriangle,
  Check,
  CircleDashed,
  LoaderCircle,
  RadioTower,
  RefreshCw,
  Server,
  Wifi,
  X,
} from 'lucide-react';

export function BrandMark({ compact = false }: { compact?: boolean }) {
  return (
    <span className={`brand-mark${compact ? ' brand-mark--compact' : ''}`} aria-hidden="true">
      <RadioTower size={compact ? 18 : 21} strokeWidth={1.8} />
    </span>
  );
}

type ButtonVariant = 'primary' | 'quiet' | 'danger' | 'outline' | 'icon';

type ButtonProps = ButtonHTMLAttributes<HTMLButtonElement> & {
  variant?: ButtonVariant;
  loading?: boolean;
  children: ReactNode;
};

export function Button({
  variant = 'primary',
  loading = false,
  disabled,
  children,
  ...props
}: ButtonProps) {
  return (
    <button
      className={`button button--${variant}`}
      disabled={disabled || loading}
      {...props}
    >
      {loading ? <LoaderCircle className="spin" size={16} aria-hidden="true" /> : null}
      {children}
    </button>
  );
}

export function IconButton({
  label,
  children,
  ...props
}: ButtonProps & { label: string }) {
  return (
    <Button {...props} variant="icon" aria-label={label} title={label}>
      {children}
    </Button>
  );
}

export function Badge({
  tone,
  children,
  dot = false,
}: {
  tone: 'online' | 'offline' | 'warning' | 'danger' | 'neutral';
  children: ReactNode;
  dot?: boolean;
}) {
  return (
    <span className={`badge badge--${tone}`}>
      {dot ? <span className="badge__dot" aria-hidden="true" /> : null}
      {children}
    </span>
  );
}

export function PageHeader({
  eyebrow,
  title,
  description,
  action,
}: {
  eyebrow: string;
  title: string;
  description: string;
  action?: ReactNode;
}) {
  return (
    <div className="page-header">
      <div>
        <p className="eyebrow">{eyebrow}</p>
        <h1>{title}</h1>
        <p className="page-header__description">{description}</p>
      </div>
      {action ? <div className="page-header__action">{action}</div> : null}
    </div>
  );
}

export function MetricTile({
  label,
  value,
  detail,
  accent = 'teal',
  mono = false,
}: {
  label: string;
  value: string | number;
  detail: string;
  accent?: 'teal' | 'amber' | 'coral' | 'ink';
  mono?: boolean;
}) {
  return (
    <article className={`metric-tile metric-tile--${accent}`}>
      <div className="metric-tile__topline">
        <span className="metric-tile__label">{label}</span>
        <span className="metric-tile__marker" aria-hidden="true" />
      </div>
      <strong className={`metric-tile__value${mono ? ' type-mono' : ''}`}>{value}</strong>
      <span className="metric-tile__detail">{detail}</span>
    </article>
  );
}

export function SignalRail({
  nodes,
}: {
  nodes: Array<{ label: string; value: number | string; tone?: 'teal' | 'amber' | 'coral' }>;
}) {
  return (
    <div className="signal-rail" aria-label="Relay 连接链路">
      {nodes.map((node, index) => (
        <div className="signal-rail__step" key={node.label}>
          <div className={`signal-rail__node signal-rail__node--${node.tone ?? 'teal'}`}>
            <span className="signal-rail__pulse" aria-hidden="true" />
            <span className="signal-rail__value type-mono">{node.value}</span>
          </div>
          <span className="signal-rail__label">{node.label}</span>
          {index < nodes.length - 1 ? <span className="signal-rail__connector" aria-hidden="true" /> : null}
        </div>
      ))}
    </div>
  );
}

export function LoadingScreen({ label }: { label: string }) {
  return (
    <main className="loading-screen" aria-live="polite">
      <BrandMark />
      <LoaderCircle className="spin" size={24} aria-hidden="true" />
      <p>{label}</p>
    </main>
  );
}

export function Skeleton({ className = '' }: { className?: string }) {
  return <span className={`skeleton ${className}`} aria-hidden="true" />;
}

export function ErrorState({
  title = 'Relay 数据暂时不可用',
  description = '检查服务状态后重试。',
  onRetry,
}: {
  title?: string;
  description?: string;
  onRetry: () => void;
}) {
  return (
    <section className="state-panel state-panel--error" role="alert">
      <span className="state-panel__icon"><AlertTriangle size={20} /></span>
      <div>
        <h2>{title}</h2>
        <p>{description}</p>
      </div>
      <Button variant="outline" onClick={onRetry}>
        <RefreshCw size={15} aria-hidden="true" />
        重试
      </Button>
    </section>
  );
}

export function EmptyState({
  title,
  description,
  icon = <Server size={21} />,
}: {
  title: string;
  description: string;
  icon?: ReactNode;
}) {
  return (
    <section className="state-panel state-panel--empty">
      <span className="state-panel__icon">{icon}</span>
      <div>
        <h2>{title}</h2>
        <p>{description}</p>
      </div>
    </section>
  );
}

export function InlineNotice({
  tone = 'neutral',
  children,
}: {
  tone?: 'neutral' | 'warning' | 'danger' | 'success';
  children: ReactNode;
}) {
  const Icon = tone === 'danger' || tone === 'warning'
    ? AlertTriangle
    : tone === 'success'
      ? Check
      : CircleDashed;
  return (
    <div className={`inline-notice inline-notice--${tone}`} role={tone === 'danger' ? 'alert' : undefined}>
      <Icon size={16} aria-hidden="true" />
      <span>{children}</span>
    </div>
  );
}

export function ConnectionBadge({ online, available = true }: { online: boolean; available?: boolean }) {
  if (!available) {
    // presence 查询失败：在线状态是"未知"，不能当作"离线"。
    return <Badge tone="neutral" dot>未知</Badge>;
  }
  return online ? (
    <Badge tone="online" dot><Wifi size={13} aria-hidden="true" />在线</Badge>
  ) : (
    <Badge tone="offline" dot><X size={13} aria-hidden="true" />离线</Badge>
  );
}
