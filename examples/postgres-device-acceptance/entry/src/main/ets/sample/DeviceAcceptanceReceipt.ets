import { DeviceEvidenceIdentity } from './DeviceEvidenceIdentity';
import { DevicePlatformInfo } from './DeviceAcceptanceValidation';

export class DeviceCaseResult {
  id: string;
  status: string = 'ignored';
  durationMs: number = 0;
  errorKind?: string;

  constructor(id: string) { this.id = id; }
}

export class DeviceReceiptPayload {
  schemaVersion: number = 2;
  profile: string = '';
  features: string[] = [];
  runId: string = '';
  sourceCommit: string = '';
  sourceClean: boolean = true;
  harSha256: string = '';
  consumerFingerprint: string = '';
  acceptanceFingerprint: string = '';
  hapSha256: string = '';
  apiVersion: number = 0;
  deviceClass: string = '';
  serverVersion: string = '';
  tlsMode: string = 'verify_full';
  authPlugin: string = '';
  challengeIssuedAt: string = '';
  challengeExpiresAt: string = '';
  startedAt: string = '';
  completedAt: string = '';
  operatorEvidenceId: string = '';
  cases: DeviceCaseResult[] = [];
}

export class DeviceReceiptRun {
  profile: string = '';
  signedHapSha256: string = '';
  operatorEvidenceId: string = '';
  startedAt: string = '';
  completedAt: string = '';
  serverVersion: string = '';
  authPlugin: string = '';
}

export function createDeviceReceipt(binding: DeviceEvidenceIdentity, platform: DevicePlatformInfo,
  run: DeviceReceiptRun, cases: DeviceCaseResult[]): DeviceReceiptPayload {
  const receipt = new DeviceReceiptPayload();
  receipt.profile = run.profile;
  receipt.runId = binding.challengeId;
  receipt.sourceCommit = binding.sourceCommit;
  receipt.sourceClean = true;
  receipt.harSha256 = binding.artifactSha256;
  receipt.consumerFingerprint = binding.consumerFingerprint;
  receipt.acceptanceFingerprint = binding.acceptanceFingerprint;
  receipt.hapSha256 = run.signedHapSha256;
  receipt.apiVersion = platform.sdkApiVersion;
  receipt.deviceClass = platform.deviceType;
  receipt.serverVersion = run.serverVersion;
  receipt.tlsMode = 'verify_full';
  receipt.authPlugin = run.authPlugin;
  receipt.challengeIssuedAt = binding.createdAt;
  receipt.challengeExpiresAt = binding.expiresAt;
  receipt.startedAt = run.startedAt;
  receipt.completedAt = run.completedAt;
  receipt.operatorEvidenceId = run.operatorEvidenceId;
  receipt.cases = cases;
  return receipt;
}
