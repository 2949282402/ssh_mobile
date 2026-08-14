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
  // presence_available === false 表示 presence 查询失败（Redis 不可用）：
  // 此时 devices.online 是"未知"而非"全部离线"。
  presence_available: z.boolean(),
});

export type OverviewResponse = z.infer<typeof overviewSchema>;
