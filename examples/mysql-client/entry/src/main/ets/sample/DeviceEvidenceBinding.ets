import { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';

export { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';

export function currentDeviceEvidenceBinding(): DeviceEvidenceIdentity {
  return new DeviceEvidenceIdentity();
}
