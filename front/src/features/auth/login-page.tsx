import { useEffect, useState, type FormEvent } from 'react';
import { useMutation } from '@tanstack/react-query';
import { ArrowRight, LockKeyhole, Radio, ShieldCheck } from 'lucide-react';
import { authApi } from '../../api/auth';
import { ApiRequestError } from '../../api/errors';
import { useToast } from '../../components/toast';
import { BrandMark, Button, InlineNotice, SignalRail } from '../../components/ui';

export function LoginPage({
  initialError,
  onAuthenticated,
  onRetry,
}: {
  initialError?: string;
  onAuthenticated: () => void;
  onRetry: () => void;
}) {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState(initialError ?? '');
  const toast = useToast();
  useEffect(() => {
    setError(initialError ?? '');
  }, [initialError]);
  const loginMutation = useMutation({
    mutationFn: () => authApi.login(username.trim(), password),
    onSuccess: () => {
      setPassword('');
      toast.push('已进入 Relay 控制台。', 'success');
      onAuthenticated();
    },
    onError: (mutationError) => {
      if (mutationError instanceof ApiRequestError && mutationError.status === 401) {
        setError('管理员账号或密码不正确。');
      } else if (mutationError instanceof ApiRequestError) {
        setError(mutationError.message);
      } else {
        setError('登录失败，请检查 Relay 服务后重试。');
      }
    },
  });

  const handleSubmit = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    setError('');
    loginMutation.mutate();
  };

  return (
    <main className="login-page">
      <section className="login-visual">
        <div className="login-visual__brand"><BrandMark /><span>SSH MOBILE / RELAY</span></div>
        <div className="login-visual__copy">
          <p className="eyebrow">Relay administration</p>
          <h1>Keep every relay<br /><em>signal</em> in sight.</h1>
          <p>管理设备注册、在线连接与中继会话。数据持久化方式由 Relay 的部署配置决定。</p>
        </div>
        <SignalRail
          nodes={[
            { label: 'Registered', value: 0 },
            { label: 'Online peers', value: 0 },
            { label: 'Sessions', value: 0 },
          ]}
        />
        <div className="login-visual__footer">
          <span><ShieldCheck size={15} /> HttpOnly session</span>
          <span><Radio size={15} /> Admin API v1</span>
        </div>
      </section>

      <section className="login-panel">
        <div className="login-card">
          <div className="login-card__heading">
            <span className="login-card__icon"><LockKeyhole size={19} /></span>
            <div>
              <p className="eyebrow">Administrator access</p>
              <h2>登录控制台</h2>
            </div>
          </div>
          {error ? (
            <div className="login-card__notice">
              <InlineNotice tone="danger">{error}</InlineNotice>
              {initialError ? <button type="button" className="text-button" onClick={onRetry}>重新检查连接</button> : null}
            </div>
          ) : null}
          <form className="login-form" onSubmit={handleSubmit}>
            <label>
              <span>管理员账号</span>
              <input
                value={username}
                onChange={(event) => setUsername(event.target.value)}
                autoComplete="username"
                required
                placeholder="输入管理员账号"
              />
            </label>
            <label>
              <span>管理员密码</span>
              <input
                value={password}
                onChange={(event) => setPassword(event.target.value)}
                autoComplete="current-password"
                required
                type="password"
                placeholder="输入管理员密码"
              />
            </label>
            <Button type="submit" loading={loginMutation.isPending} disabled={!username.trim() || !password}>
              进入 Relay 控制台
              <ArrowRight size={16} aria-hidden="true" />
            </Button>
          </form>
          <p className="login-card__hint">会话由服务端 HttpOnly Cookie 管理，浏览器不会保存登录凭据。</p>
        </div>
      </section>
    </main>
  );
}
