import { z } from 'zod';

export const enrolledDeviceSchema = z.object({
  device_id: z.string(),
  platform: z.string(),
  protocol_version: z.number(),
  enrolled_at: z.string(),
  online: z.boolean(),
  remote_addr: z.string(),
  public_key_fingerprint: z.string(),
});

export const devicesResponseSchema = z.object({
  items: z.array(enrolledDeviceSchema),
  total: z.number(),
});

export type EnrolledDevice = z.infer<typeof enrolledDeviceSchema>;
export type DevicesResponse = z.infer<typeof devicesResponseSchema>;
