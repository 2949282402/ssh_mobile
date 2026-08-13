import { useQuery } from '@tanstack/react-query';
import { overviewApi } from '../api/overview';
import { shouldRetryApiRequest } from '../api/errors';
import { queryKeys } from '../api/query-keys';

export function useAdminOverview() {
  return useQuery({
    queryKey: queryKeys.overview,
    queryFn: ({ signal }) => overviewApi.get(signal),
    refetchInterval: 3000,
    refetchIntervalInBackground: false,
    retry: shouldRetryApiRequest,
  });
}
