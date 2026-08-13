import { fireEvent, render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';
import { useState } from 'react';
import { describe, expect, it, vi } from 'vitest';
import { ConfirmDialog } from './confirm-dialog';

function DialogHarness() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>打开确认框</button>
      {open ? (
        <ConfirmDialog
          title="确认操作"
          description="此操作无法撤销。"
          confirmLabel="确认"
          onConfirm={vi.fn()}
          onCancel={() => setOpen(false)}
        />
      ) : null}
    </>
  );
}

function BackgroundControlHarness() {
  const [open, setOpen] = useState(false);
  return (
    <>
      <button type="button" onClick={() => setOpen(true)}>打开确认框</button>
      <input aria-label="背景输入框" type="text" />
      {open ? (
        <ConfirmDialog
          title="确认操作"
          description="此操作无法撤销。"
          confirmLabel="确认"
          onConfirm={vi.fn()}
          onCancel={() => setOpen(false)}
        />
      ) : null}
    </>
  );
}

describe('ConfirmDialog', () => {
  it('traps Tab focus and restores the trigger focus after Escape', async () => {
    const user = userEvent.setup();
    render(<DialogHarness />);
    const trigger = screen.getByRole('button', { name: '打开确认框' });

    await user.click(trigger);
    const dialog = screen.getByRole('dialog');
    expect(dialog).toHaveFocus();

    await user.tab();
    expect(screen.getByRole('button', { name: '关闭对话框' })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole('button', { name: '取消' })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole('button', { name: '确认' })).toHaveFocus();
    await user.tab();
    expect(screen.getByRole('button', { name: '关闭对话框' })).toHaveFocus();

    await user.keyboard('{Escape}');
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('closes from the backdrop but ignores Escape and backdrop while loading', async () => {
    const onCancel = vi.fn();
    const { rerender } = render(
      <ConfirmDialog
        title="加载中"
        description="请稍候。"
        confirmLabel="继续"
        loading
        onConfirm={vi.fn()}
        onCancel={onCancel}
      />,
    );
    const backdrop = screen.getByRole('presentation');

    fireEvent.mouseDown(backdrop);
    fireEvent.keyDown(document, { key: 'Escape' });
    expect(onCancel).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: '关闭对话框' })).toBeDisabled();

    rerender(
      <ConfirmDialog
        title="可关闭"
        description="请确认。"
        confirmLabel="继续"
        onConfirm={vi.fn()}
        onCancel={onCancel}
      />,
    );
    fireEvent.mouseDown(screen.getByRole('presentation'));
    expect(onCancel).toHaveBeenCalledOnce();
  });

  it('wraps focus backwards with Shift+Tab and keeps a background control out of the tab order', async () => {
    const user = userEvent.setup();
    render(<BackgroundControlHarness />);
    const trigger = screen.getByRole('button', { name: '打开确认框' });

    await user.click(trigger);
    const dialog = screen.getByRole('dialog');
    expect(dialog).toHaveFocus();

    // Reverse wrap from the dialog container lands on the last focusable (确认).
    await user.tab({ shift: true });
    expect(screen.getByRole('button', { name: '确认' })).toHaveFocus();

    // Forward wrap from the last focusable returns to the first (关闭对话框).
    await user.tab();
    expect(screen.getByRole('button', { name: '关闭对话框' })).toHaveFocus();

    // Backwards from the first focusable wraps to the last.
    await user.tab({ shift: true });
    expect(screen.getByRole('button', { name: '确认' })).toHaveFocus();

    // The background control is never reached while the trap is active.
    expect(screen.getByLabelText('背景输入框')).not.toHaveFocus();
    expect(dialog).toBeInTheDocument();
  });

  it('restores focus to the trigger after closing via the cancel button', async () => {
    const user = userEvent.setup();
    render(<DialogHarness />);
    const trigger = screen.getByRole('button', { name: '打开确认框' });

    await user.click(trigger);
    await user.click(screen.getByRole('button', { name: '取消' }));

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('restores focus to the trigger after closing via the close button', async () => {
    const user = userEvent.setup();
    render(<DialogHarness />);
    const trigger = screen.getByRole('button', { name: '打开确认框' });

    await user.click(trigger);
    await user.click(screen.getByRole('button', { name: '关闭对话框' }));

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it('restores focus to the trigger after closing via the backdrop', async () => {
    const user = userEvent.setup();
    render(<DialogHarness />);
    const trigger = screen.getByRole('button', { name: '打开确认框' });

    await user.click(trigger);
    fireEvent.mouseDown(screen.getByRole('presentation'));

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });
});
