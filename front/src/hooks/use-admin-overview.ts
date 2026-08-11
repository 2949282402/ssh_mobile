import { useQuery } from '@tanstack/react-query';
import { overviewApi } from '../api/overview';
import { queryKeys } from '../api/query-keys';

export function useAdminOverview() {
  return useQuery({
    queryKey: queryKeys.overview,
    queryFn: overviewApi.get,
    refetchInterval: 3000,
    refetchIntervalInBackground: false,
    retry: 1,
  });
}
