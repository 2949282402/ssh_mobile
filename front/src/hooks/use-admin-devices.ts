import { useQuery } from '@tanstack/react-query';
import { devicesApi } from '../api/devices';
import { queryKeys } from '../api/query-keys';

export function useAdminDevices() {
  return useQuery({
    queryKey: queryKeys.devices,
    queryFn: devicesApi.list,
    refetchInterval: 15000,
    refetchIntervalInBackground: false,
    retry: 1,
  });
}
