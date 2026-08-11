import { useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import {
  KeyRound,
  LayoutDashboard,
  LogOut,
  Menu,
  RadioTower,
  Server,
  X,
} from 'lucide-react';
import { authApi } from '../api/auth';
import { queryKeys } from '../api/query-keys';
import { BrandMark, IconButton } from '../components/ui';
import { useToast } from '../components/toast';

const navItems = [
  { to: '/overview', label: 'Overview', chinese: '运行概览', icon: LayoutDashboard },
  { to: '/devices', label: 'Devices', chinese: '设备管理', icon: Server },
  { to: '/access', label: 'Access', chinese: '注册授权', icon: KeyRound },
];

const pageNames: Record<string, string> = {
  '/overview': '运行概览',
  '/devices': '设备管理',
  '/access': '注册授权',
};

export function AppShell({ username }: { username: string }) {
  const [navOpen, setNavOpen] = useState(false);
  const location = useLocation();
  const queryClient = useQueryClient();
  const toast = useToast();
  const logoutMutation = useMutation({
    mutationFn: authApi.logout,
    onSuccess: () => {
      queryClient.clear();
      void queryClient.invalidateQueries({ queryKey: queryKeys.auth });
    },
    onError: () => toast.push('退出登录失败，请重试。', 'error'),
  });

  const closeNav = () => setNavOpen(false);

  return (
    <div className="app-shell">
      <div className={`nav-scrim${navOpen ? ' nav-scrim--visible' : ''}`} onClick={closeNav} />
      <aside className={`sidebar${navOpen ? ' sidebar--open' : ''}`}>
        <div className="sidebar__head">
          <NavLink to="/overview" className="brand-lockup" onClick={closeNav}>
            <BrandMark />
            <span>
              <strong>SSH Mobile</strong>
              <small>RELAY CONTROL</small>
            </span>
          </NavLink>
          <IconButton label="关闭导航" onClick={closeNav} className="mobile-only">
            <X size={18} />
          </IconButton>
        </div>

        <div className="sidebar__section-label">Control plane</div>
        <nav className="sidebar__nav" aria-label="主导航">
          {navItems.map((item) => {
            const Icon = item.icon;
            return (
              <NavLink
                key={item.to}
                to={item.to}
                onClick={closeNav}
                className={({ isActive }) => `nav-link${isActive ? ' nav-link--active' : ''}`}
              >
                <Icon size={18} strokeWidth={1.8} aria-hidden="true" />
                <span>
                  <strong>{item.chinese}</strong>
                  <small>{item.label}</small>
                </span>
              </NavLink>
            );
          })}
        </nav>

        <div className="sidebar__bottom">
          <div className="memory-note">
            <span className="memory-note__icon"><RadioTower size={15} /></span>
            <div>
              <strong>Memory-only relay</strong>
              <span>服务重启后设备需重新注册</span>
            </div>
          </div>
          <div className="account-row">
            <span className="account-avatar" aria-hidden="true">{username.slice(0, 1).toUpperCase()}</span>
            <div className="account-row__identity">
              <strong>{username}</strong>
              <span>Administrator</span>
            </div>
            <IconButton
              label="退出登录"
              onClick={() => logoutMutation.mutate()}
              disabled={logoutMutation.isPending}
            >
              <LogOut size={16} />
            </IconButton>
          </div>
        </div>
      </aside>

      <main className="content-shell">
        <header className="topbar">
          <div className="topbar__left">
            <IconButton label="打开导航" onClick={() => setNavOpen(true)} className="mobile-only">
              <Menu size={20} />
            </IconButton>
            <div>
              <span className="topbar__eyebrow">SSH MOBILE / RELAY</span>
              <strong>{pageNames[location.pathname] ?? 'Relay 控制台'}</strong>
            </div>
          </div>
          <div className="topbar__status">
            <span className="status-dot" aria-hidden="true" />
            <span>SESSION ACTIVE</span>
          </div>
        </header>
        <div className="content-scroll">
          <Outlet />
        </div>
      </main>
    </div>
  );
}
