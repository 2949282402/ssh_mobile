import { useQuery } from '@tanstack/react-query';
import { devicesApi } from '../api/devices';
import { shouldRetryApiRequest } from '../api/errors';
import { queryKeys } from '../api/query-keys';

export function useAdminDevices() {
  return useQuery({
    queryKey: queryKeys.devices,
    queryFn: ({ signal }) => devicesApi.list(signal),
    refetchInterval: 15000,
    refetchIntervalInBackground: false,
    retry: shouldRetryApiRequest,
  });
}
