import { z } from 'zod';

export const overviewSchema = z.object({
  server_time: z.number(),
  uptime_seconds: z.number(),
  devices: z.object({
    enrolled: z.number(),
    online: z.number(),
  }),
  relay: z.object({
    active_transfers: z.number(),
  }),
  runtime: z.object({
    allocated_mem_mb: z.number(),
    goroutines: z.number(),
  }),
});

export type OverviewResponse = z.infer<typeof overviewSchema>;
