import { useState } from 'react';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, Copy, Eye, EyeOff, KeyRound, RotateCcw, ShieldCheck } from 'lucide-react';
import { accessApi } from '../../api/access';
import { ApiRequestError } from '../../api/errors';
import { queryKeys } from '../../api/query-keys';
import { ConfirmDialog } from '../../components/confirm-dialog';
import { useToast } from '../../components/toast';
import { Badge, Button, ErrorState, InlineNotice, PageHeader, Skeleton } from '../../components/ui';
import { copyToClipboard } from '../../utils/format';

export function AccessPage() {
  const [revealed, setRevealed] = useState(false);
  const [showRotateDialog, setShowRotateDialog] = useState(false);
  const queryClient = useQueryClient();
  const toast = useToast();
  const tokenQuery = useQuery({
    queryKey: queryKeys.token,
    queryFn: accessApi.token,
    staleTime: Number.POSITIVE_INFINITY,
    retry: 1,
  });
  const rotateMutation = useMutation({
    mutationFn: accessApi.rotateToken,
    onSuccess: (result) => {
      queryClient.setQueryData(queryKeys.token, result);
      setRevealed(true);
      setShowRotateDialog(false);
      toast.push('Enrollment Token 已重新生成。', 'success');
    },
    onError: (error) => toast.push(error instanceof ApiRequestError ? error.message : 'Token 轮换失败。', 'error'),
  });

  const handleCopy = async () => {
    const token = tokenQuery.data?.enrollment_token;
    if (!token) return;
    try {
      await copyToClipboard(token);
      toast.push('Enrollment Token 已复制到剪贴板。', 'success');
    } catch (error) {
      toast.push(error instanceof Error ? error.message : '复制失败。', 'error');
    }
  };

  if (tokenQuery.isPending) {
    return (
      <div className="page">
        <PageHeader eyebrow="Relay / Access" title="注册授权" description="管理新设备加入 Relay 所需的授权口令。" />
        <section className="access-layout"><Skeleton className="skeleton-token-card" /><Skeleton className="skeleton-info-card" /></section>
      </div>
    );
  }

  if (tokenQuery.isError || !tokenQuery.data) {
    return (
      <div className="page page--narrow">
        <PageHeader eyebrow="Relay / Access" title="注册授权" description="管理新设备加入 Relay 所需的授权口令。" />
        <ErrorState
          description={tokenQuery.error instanceof ApiRequestError ? tokenQuery.error.message : '无法读取 Enrollment Token。'}
          onRetry={() => void tokenQuery.refetch()}
        />
      </div>
    );
  }

  const token = tokenQuery.data.enrollment_token;

  return (
    <div className="page">
      <PageHeader
        eyebrow="Relay / Access"
        title="注册授权"
        description="管理新设备加入 Relay 所需的 Enrollment Token。"
        action={<Badge tone="online" dot>AUTHENTICATED</Badge>}
      />

      <div className="access-layout">
        <section className="token-card">
          <div className="token-card__head">
            <div className="token-card__identity">
              <span className="token-card__icon"><KeyRound size={19} /></span>
              <div>
                <p className="eyebrow">Enrollment Token</p>
                <h2>设备注册口令</h2>
              </div>
            </div>
            <Badge tone="warning">高敏感凭据</Badge>
          </div>
          <p className="token-card__description">新设备首次注册 Relay 时需要使用此 Token。默认遮罩，仅在明确操作后显示。</p>
          <div className="token-field">
            <code>{revealed ? token : maskToken(token)}</code>
            <Button variant="quiet" onClick={() => setRevealed((value) => !value)}>
              {revealed ? <EyeOff size={15} /> : <Eye size={15} />}
              {revealed ? '隐藏' : '显示'}
            </Button>
          </div>
          <div className="token-actions">
            <Button variant="outline" onClick={() => void handleCopy()}>
              <Copy size={15} />
              复制 Token
            </Button>
            <Button variant="danger" onClick={() => setShowRotateDialog(true)}>
              <RotateCcw size={15} />
              轮换 Token
            </Button>
          </div>
          <InlineNotice tone="warning">轮换后，旧 Token 将不能用于新设备注册。已建立的设备连接不会因此自动断开。</InlineNotice>
        </section>

        <section className="info-card">
          <div className="info-card__icon"><ShieldCheck size={20} /></div>
          <p className="eyebrow">Credential boundary</p>
          <h2>保持授权口令在控制范围内</h2>
          <p>Token 只通过当前管理员会话读取，不会写入浏览器存储、URL 或页面日志。</p>
          <div className="info-card__rule" />
          <div className="info-card__list">
            <span><Check size={15} /> HttpOnly 管理员会话</span>
            <span><Check size={15} /> Relay API 同源访问</span>
            <span><Check size={15} /> 设备状态仅驻留内存</span>
          </div>
        </section>
      </div>

      {showRotateDialog ? (
        <ConfirmDialog
          title="轮换 Enrollment Token？"
          description="轮换后旧 Token 会立即失效，新设备必须使用新 Token 注册。这个操作不会断开已建立的设备连接。"
          confirmLabel="重新生成 Token"
          tone="primary"
          loading={rotateMutation.isPending}
          onCancel={() => setShowRotateDialog(false)}
          onConfirm={() => rotateMutation.mutate()}
        />
      ) : null}
    </div>
  );
}

function maskToken(token: string) {
  if (token.length <= 8) return '••••••••';
  return `${token.slice(0, 4)}${'•'.repeat(Math.min(token.length - 8, 24))}${token.slice(-4)}`;
}
