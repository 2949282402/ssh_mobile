import { useQuery } from '@tanstack/react-query';
import { relayApi } from '../api/types';

export function useRelayStats() {
  return useQuery({
    queryKey: ['relay', 'stats'],
    queryFn: relayApi.stats,
    refetchInterval: 3000,
    refetchIntervalInBackground: false,
    retry: 1,
  });
}
