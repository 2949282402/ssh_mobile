import { useCallback, useEffect, useRef, useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { NavLink, Outlet, useLocation } from 'react-router-dom';
import {
  Activity,
  KeyRound,
  Layers,
  LayoutDashboard,
  LogOut,
  Menu,
  RadioTower,
  Server,
  Sliders,
  Terminal,
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
  { to: '/telemetry', label: 'Telemetry', chinese: '埋点概览', icon: Activity },
  { to: '/telemetry/events', label: 'Events', chinese: '事件检索', icon: Layers },
  { to: '/telemetry/diagnostics', label: 'Diagnostics', chinese: '诊断日志', icon: Terminal },
  { to: '/telemetry/settings', label: 'Settings', chinese: '埋点策略', icon: Sliders },
];

const pageNames: Record<string, string> = {
  '/overview': '运行概览',
  '/devices': '设备管理',
  '/access': '注册授权',
  '/telemetry': '数据埋点概览',
  '/telemetry/events': '事件浏览器',
  '/telemetry/diagnostics': '诊断日志',
  '/telemetry/settings': '埋点与策略设置',
};

const NAV_FOCUSABLE_SELECTOR = [
  'button:not([disabled])',
  '[href]',
  '[tabindex]:not([tabindex="-1"])',
].join(',');

export function AppShell({ username }: { username: string }) {
  const [navOpen, setNavOpen] = useState(false);
  const location = useLocation();
  const queryClient = useQueryClient();
  const toast = useToast();
  const sidebarRef = useRef<HTMLElement>(null);
  const openNavButtonRef = useRef<HTMLButtonElement>(null);
  const closeNavButtonRef = useRef<HTMLButtonElement>(null);
  const restoreNavFocusRef = useRef(false);
  const previousPathRef = useRef(location.pathname);
  const logoutMutation = useMutation({
    mutationFn: () => authApi.logout(),
    onSuccess: () => {
      void queryClient.cancelQueries({ queryKey: ['relay'] });
      void queryClient.cancelQueries({ queryKey: ['telemetry'] });
      void queryClient.cancelQueries({ queryKey: queryKeys.auth, exact: true });
      queryClient.removeQueries({ queryKey: ['relay'] });
      queryClient.removeQueries({ queryKey: ['telemetry'] });
      queryClient.setQueryData(queryKeys.auth, {
        authenticated: false,
        username: '',
      });
    },
    onError: () => toast.push('退出登录失败，请重试。', 'error'),
  });

  const closeNav = useCallback(() => {
    restoreNavFocusRef.current = true;
    setNavOpen(false);
  }, []);

  useEffect(() => {
    if (navOpen) {
      closeNavButtonRef.current?.focus();
      return;
    }
    if (restoreNavFocusRef.current) {
      restoreNavFocusRef.current = false;
      openNavButtonRef.current?.focus();
    }
  }, [navOpen]);

  useEffect(() => {
    if (!navOpen) return undefined;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        closeNav();
        return;
      }
      if (event.key !== 'Tab') return;

      const sidebar = sidebarRef.current;
      if (!sidebar) return;
      const focusable = Array.from(sidebar.querySelectorAll<HTMLElement>(NAV_FOCUSABLE_SELECTOR));
      if (focusable.length === 0) {
        event.preventDefault();
        sidebar.focus();
        return;
      }
      const activeIndex = focusable.indexOf(document.activeElement as HTMLElement);
      const nextIndex = event.shiftKey
        ? activeIndex <= 0 ? focusable.length - 1 : activeIndex - 1
        : activeIndex === focusable.length - 1 ? 0 : activeIndex + 1;
      if (activeIndex === -1) {
        event.preventDefault();
        focusable[event.shiftKey ? focusable.length - 1 : 0]?.focus();
        return;
      }
      event.preventDefault();
      focusable[nextIndex]?.focus();
    };
    document.addEventListener('keydown', handleKeyDown);
    return () => document.removeEventListener('keydown', handleKeyDown);
  }, [closeNav, navOpen]);

  useEffect(() => {
    if (previousPathRef.current === location.pathname) return;
    previousPathRef.current = location.pathname;
    if (navOpen) closeNav();
  }, [closeNav, location.pathname, navOpen]);

  return (
    <div className="app-shell">
      <div
        className={`nav-scrim${navOpen ? ' nav-scrim--visible' : ''}`}
        aria-hidden="true"
        onClick={closeNav}
      />
      <aside
        id="primary-navigation"
        ref={sidebarRef}
        className={`sidebar${navOpen ? ' sidebar--open' : ''}`}
        aria-label="Relay 导航"
        tabIndex={-1}
      >
        <div className="sidebar__head">
          <NavLink to="/overview" className="brand-lockup" onClick={closeNav}>
            <BrandMark />
            <span>
              <strong>SSH Mobile</strong>
              <small>RELAY CONTROL</small>
            </span>
          </NavLink>
          <IconButton ref={closeNavButtonRef} label="关闭导航" onClick={closeNav} className="mobile-only">
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
                end
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
              <strong>Relay state</strong>
              <span>持久化方式由部署配置决定</span>
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

      <main className="content-shell" inert={navOpen} aria-hidden={navOpen || undefined}>
        <header className="topbar">
          <div className="topbar__left">
            <IconButton
              ref={openNavButtonRef}
              label="打开导航"
              onClick={() => setNavOpen(true)}
              className="mobile-only"
              aria-expanded={navOpen}
              aria-controls="primary-navigation"
            >
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
