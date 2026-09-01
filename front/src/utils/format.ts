export function formatDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return '未知时间';
  return new Intl.DateTimeFormat('zh-CN', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(date);
}

export function formatLastUpdated(timestamp: number) {
  if (!timestamp || !Number.isFinite(timestamp)) return '尚未同步';
  return new Intl.DateTimeFormat('zh-CN', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
  }).format(new Date(timestamp));
}

export function formatDuration(seconds: number) {
  const safeSeconds = Number.isFinite(seconds) ? Math.max(0, Math.floor(seconds)) : 0;
  const days = Math.floor(safeSeconds / 86400);
  const hours = Math.floor(safeSeconds / 3600) % 24;
  const minutes = Math.floor(safeSeconds / 60) % 60;
  const remainingSeconds = safeSeconds % 60;
  const prefix = days > 0 ? `${days}d ` : '';
  return `${prefix}${String(hours).padStart(2, '0')}h ${String(minutes).padStart(2, '0')}m ${String(remainingSeconds).padStart(2, '0')}s`;
}

export async function copyToClipboard(value: string) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }

  const input = document.createElement('textarea');
  input.value = value;
  input.setAttribute('readonly', '');
  input.setAttribute('aria-hidden', 'true');
  input.tabIndex = -1;
  input.className = 'clipboard-fallback';
  document.body.appendChild(input);
  let copied = false;
  try {
    input.select();
    copied = typeof document.execCommand === 'function' && document.execCommand('copy');
  } finally {
    input.value = '';
    input.remove();
  }
  if (!copied) throw new Error('当前浏览器不支持复制。');
}
