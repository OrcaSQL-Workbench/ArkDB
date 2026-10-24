import { ArkDbError } from '../model/ArkDbError';

export enum ServerMetricsAvailability {
  Available = 'available',
  Unsupported = 'unsupported',
  Disabled = 'disabled',
  PermissionDenied = 'permission-denied',
  Empty = 'empty'
}

export enum MetricKind {
  Gauge = 'gauge',
  Counter = 'counter'
}

export class MetricMeasurement {
  name: string = '';
  unit: string = '';
  kind: MetricKind = MetricKind.Gauge;
  value: number | bigint = 0;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (this.name.trim().length === 0 || this.unit.trim().length === 0) {
      errors.push(ArkDbError.validation('Metric name and unit are required.'));
    }
    if (typeof this.value === 'number' && !Number.isFinite(this.value)) {
      errors.push(ArkDbError.validation('Metric value must be finite.'));
    }
    if (this.kind === MetricKind.Counter && this.value < 0) {
      errors.push(ArkDbError.validation('Counter value must not be negative.'));
    }
    return errors;
  }
}

export class ServerMetricsSnapshot {
  availability: ServerMetricsAvailability = ServerMetricsAvailability.Unsupported;
  sampledAtUptimeMs: number | null = null;
  measurements: MetricMeasurement[] = [];
  reason: string = '';
  error: ArkDbError | null = null;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    const mapped = this.availability === ServerMetricsAvailability.Available ||
      this.availability === ServerMetricsAvailability.Empty;
    if (mapped) {
      if (this.sampledAtUptimeMs === null || !Number.isSafeInteger(this.sampledAtUptimeMs) ||
        this.sampledAtUptimeMs < 0) {
        errors.push(ArkDbError.validation('Mapped metrics require a non-negative sample uptime.'));
      }
      if (this.error !== null || this.reason.length > 0 ||
        (this.availability === ServerMetricsAvailability.Available && this.measurements.length === 0) ||
        (this.availability === ServerMetricsAvailability.Empty && this.measurements.length > 0)) {
        errors.push(ArkDbError.validation('Contradictory metrics availability or data.'));
      }
    } else if (this.sampledAtUptimeMs !== null || this.measurements.length > 0 ||
      this.reason.trim().length === 0) {
      errors.push(ArkDbError.validation('Unavailable metrics require a reason and cannot contain samples.'));
    }
    const names: string[] = [];
    for (const measurement of this.measurements) {
      if (names.indexOf(measurement.name) >= 0) {
        errors.push(ArkDbError.validation('Duplicate metric name: ' + measurement.name));
      }
      names.push(measurement.name);
      for (const error of measurement.validate()) errors.push(error);
    }
    return errors;
  }
}
