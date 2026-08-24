import { afterEach, describe, expect, it, vi } from 'vitest';
import { copyToClipboard, formatDate, formatDuration, formatLastUpdated } from './format';

describe('format utilities', () => {
  const originalClipboard = Object.getOwnPropertyDescriptor(navigator, 'clipboard');
  const originalExecCommand = Object.getOwnPropertyDescriptor(document, 'execCommand');

  afterEach(() => {
    vi.restoreAllMocks();
    if (originalClipboard) {
      Object.defineProperty(navigator, 'clipboard', originalClipboard);
    } else {
      Reflect.deleteProperty(navigator, 'clipboard');
    }
    if (originalExecCommand) {
      Object.defineProperty(document, 'execCommand', originalExecCommand);
    } else {
      Reflect.deleteProperty(document, 'execCommand');
    }
  });

  it('renders invalid dates as an explicit unknown value', () => {
    expect(formatDate('not-a-date')).toBe('未知时间');
    expect(formatDate('2026-08-22T00:00:00Z')).not.toBe('未知时间');
  });

  it('keeps the never-synced sentinel separate from a real timestamp', () => {
    expect(formatLastUpdated(0)).toBe('尚未同步');
    expect(formatLastUpdated(Date.UTC(2026, 7, 22, 3, 4, 5))).toMatch(/\d{2}:04:05/);
  });

  it('clamps negative and fractional durations and carries days', () => {
    expect(formatDuration(-2.8)).toBe('00h 00m 00s');
    expect(formatDuration(3661.9)).toBe('01h 01m 01s');
    expect(formatDuration(2 * 86400 + 3 * 3600 + 4 * 60 + 5)).toBe('2d 03h 04m 05s');
  });

  it('uses the modern clipboard API when available', async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });

    await copyToClipboard('secret-token');

    expect(writeText).toHaveBeenCalledWith('secret-token');
  });

  it('falls back to a hidden textarea when the clipboard API is absent', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: undefined,
    });
    const execCommand = vi.fn().mockReturnValue(true);
    Object.defineProperty(document, 'execCommand', {
      configurable: true,
      value: execCommand,
    });
    const appendChild = vi.spyOn(document.body, 'appendChild');

    await copyToClipboard('fallback-value');

    expect(execCommand).toHaveBeenCalledWith('copy');
    const textarea = appendChild.mock.calls[0]?.[0] as HTMLTextAreaElement;
    expect(textarea).toHaveClass('clipboard-fallback');
    expect(textarea).not.toHaveAttribute('style');
    expect(textarea.value).toBe('');
    expect(document.querySelector('textarea')).toBeNull();
  });

  it('reports a browser that rejects the fallback copy operation', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: undefined,
    });
    Object.defineProperty(document, 'execCommand', {
      configurable: true,
      value: vi.fn().mockReturnValue(false),
    });

    await expect(copyToClipboard('unsupported')).rejects.toThrow('当前浏览器不支持复制。');
  });
});
