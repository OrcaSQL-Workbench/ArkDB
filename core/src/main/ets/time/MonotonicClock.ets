import { systemDateTime } from '@kit.BasicServicesKit';

export function monotonicNowMs(): number {
  return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
}
