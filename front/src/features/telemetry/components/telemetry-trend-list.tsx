import type { ReactNode } from 'react';

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

function trendBarWidth(value: number, denominator: number): string {
  if (!Number.isFinite(value) || !Number.isFinite(denominator) || denominator <= 0) {
    return '0%';
  }
  return `${Math.min(100, Math.max(0, (value / denominator) * 100))}%`;
}

export function TelemetryTrendList({
  points,
  total,
  accent = 'teal',
  emptyMessage = 'No operations recorded in this time range',
}: {
  points: Array<{ timestamp: string; value: number }>;
  total: number;
  accent?: 'teal' | 'coral';
  emptyMessage?: string;
}): ReactNode {
  if (points.length === 0) {
    return <p className="trend-empty">{emptyMessage}</p>;
  }

  return (
    <div className="trend-list">
      {points.map((point) => (
        <div key={point.timestamp} className="trend-row">
          <span className="trend-row__time type-mono">
            {formatTrendTime(point.timestamp)}
          </span>
          <div className="trend-row__track">
            <div
              className={`trend-row__fill trend-row__fill--${accent === 'coral' && point.value > 0 ? 'coral' : accent}`}
              style={{ width: trendBarWidth(point.value, total) }}
            />
          </div>
          <strong className="trend-row__value type-mono">{point.value}</strong>
        </div>
      ))}
    </div>
  );
}
