import type { ReactNode } from 'react';
import { ChevronDown, ChevronUp } from 'lucide-react';
import { Badge, Button, CodeBlock } from '../../../components/ui';
import type { Severity, TelemetryRecord } from '../../../schemas/telemetry';

const SEVERITY_TONES: Record<Severity, 'online' | 'warning' | 'danger'> = {
  info: 'online',
  warn: 'warning',
  error: 'danger',
  critical: 'danger',
};

export function TelemetryRecordCard({
  record,
  expanded,
  onToggle,
  variant = 'event',
}: {
  record: TelemetryRecord;
  expanded: boolean;
  onToggle: () => void;
  variant?: 'event' | 'diagnostic';
}): ReactNode {
  const tone = SEVERITY_TONES[record.severity] ?? 'online';
  const isDiagnostic = variant === 'diagnostic';

  const timeFormatted = isDiagnostic
    ? new Date(record.occurredAt).toLocaleTimeString()
    : new Date(record.occurredAt).toLocaleString();

  const buttonAriaLabel = isDiagnostic
    ? `查看日志详情 ${record.eventName}`
    : `查看详情 ${record.eventName}`;

  const buttonText = isDiagnostic
    ? (expanded ? '收起' : '查看详情')
    : (expanded ? '收起详情' : '查看详情');

  const hasProperties = record.properties && Object.keys(record.properties).length > 0;

  return (
    <article className={`record-card${expanded ? ' record-card--expanded' : ''}`}>
      <div className="record-card__summary">
        <div className="record-card__main">
          <Badge tone={tone} dot>
            {record.severity.toUpperCase()}
          </Badge>
          <strong className="record-card__title type-mono">
            {record.eventName}
          </strong>
          <span className="record-card__meta">
            {isDiagnostic ? record.feature : `v${record.eventVersion} · ${record.feature}`}
          </span>
          {record.releaseChannel ? (
            <span className="record-card__meta">
              channel: {record.releaseChannel}
            </span>
          ) : null}
          <span className="record-card__device type-mono">
            {record.deviceId}
          </span>
          {record.error ? (
            <span className="record-card__error-preview">
              [{record.error.errorCode}] {record.error.message}
            </span>
          ) : null}
        </div>

        <div className="record-card__aside">
          <span className="record-card__time">{timeFormatted}</span>
          <Button
            variant="quiet"
            onClick={onToggle}
            aria-label={buttonAriaLabel}
            aria-expanded={expanded}
          >
            {expanded ? <ChevronUp size={16} aria-hidden="true" /> : <ChevronDown size={16} aria-hidden="true" />}
            {buttonText}
          </Button>
        </div>
      </div>

      {expanded ? (
        <div className="record-card__detail">
          {isDiagnostic ? (
            <div className="metadata-grid">
              <div className="metadata-field">
                <span className="metadata-field__label">Event ID / Trace:</span>
                <span className="metadata-field__value type-mono">{record.eventId} / {record.traceId}</span>
              </div>
              <div className="metadata-field">
                <span className="metadata-field__label">Session / Device:</span>
                <span className="metadata-field__value type-mono">{record.sessionId} / {record.deviceId}</span>
              </div>
              <div className="metadata-field">
                <span className="metadata-field__label">Platform / Version:</span>
                <span className="metadata-field__value type-mono">{record.platform} ({record.appVersion}+{record.buildNumber})</span>
              </div>
              {record.releaseChannel ? (
                <div className="metadata-field">
                  <span className="metadata-field__label">Release Channel:</span>
                  <span className="metadata-field__value type-mono">{record.releaseChannel}</span>
                </div>
              ) : null}
            </div>
          ) : (
            <div className="metadata-grid">
              <div className="metadata-field">
                <span className="metadata-field__label">Event ID:</span>
                <span className="metadata-field__value type-mono">{record.eventId}</span>
              </div>
              <div className="metadata-field">
                <span className="metadata-field__label">Session ID:</span>
                <span className="metadata-field__value type-mono">{record.sessionId}</span>
              </div>
              <div className="metadata-field">
                <span className="metadata-field__label">Trace ID:</span>
                <span className="metadata-field__value type-mono">{record.traceId}</span>
              </div>
              <div className="metadata-field">
                <span className="metadata-field__label">App Version:</span>
                <span className="metadata-field__value type-mono">
                  {record.appVersion} ({record.buildNumber}) / {record.platform}
                </span>
              </div>
              {record.releaseChannel ? (
                <div className="metadata-field">
                  <span className="metadata-field__label">Release Channel:</span>
                  <span className="metadata-field__value type-mono">{record.releaseChannel}</span>
                </div>
              ) : null}
            </div>
          )}

          {record.error ? (
            <div className="error-block">
              <div className="error-block__head">
                <strong className="error-block__title">
                  {isDiagnostic
                    ? `Error Code: [${record.error.errorCode}]`
                    : `Error Details [${record.error.errorCode}]`}
                </strong>
                <span className="error-block__category">
                  Category: {record.error.category}
                  {!isDiagnostic && record.error.terminalFailure ? ' (Terminal)' : ''}
                </span>
              </div>
              <p className="error-block__message">{record.error.message}</p>
              {record.error.stackTrace ? (
                <CodeBlock>{record.error.stackTrace}</CodeBlock>
              ) : null}
            </div>
          ) : null}

          {(!isDiagnostic || hasProperties) ? (
            <div className="metadata-field">
              <span className="metadata-field__label">Properties Payload:</span>
              <CodeBlock json>{JSON.stringify(record.properties, null, 2)}</CodeBlock>
            </div>
          ) : null}
        </div>
      ) : null}
    </article>
  );
}
