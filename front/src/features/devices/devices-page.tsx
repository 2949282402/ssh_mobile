import { useEffect, useMemo, useRef, useState } from 'react';
import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Check, Filter, Search, Server, ShieldOff, SlidersHorizontal, Wifi, X } from 'lucide-react';
import { devicesApi } from '../../api/devices';
import { ApiRequestError, isAbortError } from '../../api/errors';
import { queryKeys } from '../../api/query-keys';
import type { EnrolledDevice } from '../../schemas/devices';
import { ConfirmDialog } from '../../components/confirm-dialog';
import { useToast } from '../../components/toast';
import {
  Badge,
  Button,
  ConnectionBadge,
  EmptyState,
  ErrorState,
  PageHeader,
  Skeleton,
} from '../../components/ui';
import { useAdminDevices } from '../../hooks/use-admin-devices';
import { formatDate } from '../../utils/format';

type DeviceFilter = 'all' | 'online' | 'offline';

export function DevicesPage() {
  const devicesQuery = useAdminDevices();
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState<DeviceFilter>('all');
  const [selectedDevice, setSelectedDevice] = useState<EnrolledDevice | null>(null);
  const queryClient = useQueryClient();
  const toast = useToast();
  const revokeAbortRef = useRef<AbortController | null>(null);

  useEffect(() => () => {
    revokeAbortRef.current?.abort();
  }, []);

  const revokeMutation = useMutation({
    mutationFn: (deviceId: string) => {
      revokeAbortRef.current?.abort();
      const controller = new AbortController();
      revokeAbortRef.current = controller;
      return devicesApi.revoke(deviceId, controller.signal);
    },
    onSuccess: (_result, deviceId) => {
      setSelectedDevice(null);
      toast.push(`设备 ${deviceId} 已撤销注册。`, 'success');
      void queryClient.invalidateQueries({ queryKey: queryKeys.devices });
    },
    onError: (error) => {
      if (isAbortError(error)) return;
      toast.push(error instanceof ApiRequestError ? error.message : '设备撤销失败。', 'error');
    },
  });

  const devicesResponse = devicesQuery.data;
  const devices = useMemo(() => {
    if (!devicesResponse) return [];
    const normalizedSearch = search.trim().toLowerCase();
    return devicesResponse.items.filter((device) => {
      const matchesSearch = !normalizedSearch
        || device.device_id.toLowerCase().includes(normalizedSearch)
        || device.platform.toLowerCase().includes(normalizedSearch);
      const matchesFilter = filter === 'all' || (filter === 'online' ? device.online : !device.online);
      return matchesSearch && matchesFilter;
    });
  }, [devicesResponse, filter, search]);

  if (devicesQuery.isPending && !devicesResponse) return <DevicesSkeleton />;
  if (devicesQuery.isError && !devicesResponse) {
    return (
      <div className="page page--narrow">
        <PageHeader eyebrow="Relay / Devices" title="设备管理" description="管理当前进程中的已注册设备。" />
        <ErrorState
          description={devicesQuery.error instanceof ApiRequestError ? devicesQuery.error.message : undefined}
          onRetry={() => void devicesQuery.refetch()}
        />
      </div>
    );
  }
  if (!devicesResponse) return null;

  return (
    <div className="page">
      <PageHeader
        eyebrow="Relay / Devices"
        title="设备管理"
        description="查看设备注册信息和当前 Relay 连接状态。"
        action={(
          <Button variant="outline" onClick={() => void devicesQuery.refetch()} loading={devicesQuery.isFetching}>
            <Wifi size={15} aria-hidden="true" />
            刷新设备
          </Button>
        )}
      />

      <div className="list-toolbar">
        <label className="search-box">
          <Search size={17} aria-hidden="true" />
          <span className="sr-only">搜索设备</span>
          <input
            value={search}
            onChange={(event) => setSearch(event.target.value)}
            placeholder="搜索设备 ID 或平台"
          />
          {search ? (
            <button type="button" className="search-box__clear" aria-label="清除搜索" onClick={() => setSearch('')}>
              <X size={15} />
            </button>
          ) : null}
        </label>
        <div className="filter-group" aria-label="设备状态筛选">
          <Filter size={15} aria-hidden="true" />
          {(['all', 'online', 'offline'] as DeviceFilter[]).map((value) => (
            <button
              type="button"
              key={value}
              className={`filter-button${filter === value ? ' filter-button--active' : ''}`}
              onClick={() => setFilter(value)}
              aria-pressed={filter === value}
            >
              {value === 'all' ? '全部' : value === 'online' ? '在线' : '离线'}
            </button>
          ))}
        </div>
        <span className="list-toolbar__count">显示 {devices.length} / {devicesResponse.total} 台</span>
      </div>

      <section className="table-panel">
        <div className="table-panel__head">
          <div>
            <p className="eyebrow">Enrolled devices</p>
            <h2>已注册设备</h2>
          </div>
          <Badge tone="neutral"><SlidersHorizontal size={13} /> v1 registry</Badge>
        </div>
        {devicesResponse.items.length === 0 ? (
          <EmptyState title="还没有注册设备" description="使用当前 Enrollment Token 注册第一台设备。" icon={<ServerIcon />} />
        ) : devices.length === 0 ? (
          <EmptyState title="没有匹配设备" description="换一个设备 ID、平台或状态筛选条件。" icon={<Search size={21} />} />
        ) : (
          <div className="table-scroll">
            <table className="device-table">
              <thead>
                <tr>
                  <th scope="col">设备</th>
                  <th scope="col">平台</th>
                  <th scope="col">协议</th>
                  <th scope="col">注册时间</th>
                  <th scope="col">当前状态</th>
                  <th scope="col"><span className="sr-only">操作</span></th>
                </tr>
              </thead>
              <tbody>
                {devices.map((device) => {
                  const online = device.online;
                  return (
                    <tr key={device.device_id}>
                      <td data-label="设备">
                        <div className="device-cell">
                          <span className={`device-cell__icon${online ? ' device-cell__icon--online' : ''}`}><ServerIcon /></span>
                          <div>
                            <strong className="type-mono">{device.device_id}</strong>
                            {online && device.remote_addr ? <span>{device.remote_addr}</span> : null}
                            {device.public_key_fingerprint ? <span className="type-mono device-cell__fingerprint">{device.public_key_fingerprint}</span> : null}
                          </div>
                        </div>
                      </td>
                      <td data-label="平台"><Badge tone="neutral">{device.platform || 'unknown'}</Badge></td>
                      <td data-label="协议"><span className="protocol-label"><Check size={14} /> v{device.protocol_version}</span></td>
                      <td data-label="注册时间"><span className="muted-value">{formatDate(device.enrolled_at)}</span></td>
                      <td data-label="当前状态"><ConnectionBadge online={online} /></td>
                      <td data-label="操作" className="device-table__action">
                        <Button variant="danger" onClick={() => setSelectedDevice(device)}>
                          <ShieldOff size={14} />
                          撤销
                        </Button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      {selectedDevice ? (
        <ConfirmDialog
          title="撤销设备注册？"
          description={`设备 ${selectedDevice.device_id} 将从当前 Relay 进程中移除；如果它在线，现有连接也会立即断开。`}
          confirmLabel="撤销设备"
          loading={revokeMutation.isPending}
          onCancel={() => setSelectedDevice(null)}
          onConfirm={() => revokeMutation.mutate(selectedDevice.device_id)}
        />
      ) : null}
    </div>
  );
}

function DevicesSkeleton() {
  return (
    <div className="page">
      <PageHeader eyebrow="Relay / Devices" title="设备管理" description="正在读取设备注册信息。" />
      <section className="table-panel skeleton-table">
        <Skeleton className="skeleton-heading" />
        {Array.from({ length: 4 }, (_, index) => <Skeleton className="skeleton-row" key={index} />)}
      </section>
    </div>
  );
}

function ServerIcon() {
  return <Server size={19} strokeWidth={1.7} aria-hidden="true" />;
}
