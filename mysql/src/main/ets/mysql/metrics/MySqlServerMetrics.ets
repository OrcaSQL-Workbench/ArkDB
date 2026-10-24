import { ArkDbError, ArkDbErrorKind, ServerMetricsAvailability } from '@arkdb/core';
export { ServerMetricsAvailability } from '@arkdb/core';

export const MAX_METRICS_PROCESS_ROWS: number = 100;
export const MAX_METRICS_REPLICATION_CHANNELS: number = 16;
export const MAX_PROCESS_COMMAND_UTF8_BYTES: number = 64;
export const MAX_PROCESS_STATE_UTF8_BYTES: number = 512;
export const MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES: number = 128;
export const MAX_METRICS_UNSIGNED_64: bigint = 18446744073709551615n;

export enum ServerMetricsErrorKind {
  UnsupportedProduct = 'unsupported-product',
  UnsupportedSource = 'unsupported-source',
  PerformanceSchemaDisabled = 'performance-schema-disabled',
  Server = 'server'
}

export interface ServerMetricsModel {
  validate(): ArkDbError[];
}

export enum ReplicationIoRunning {
  Yes = 'yes',
  No = 'no',
  Connecting = 'connecting',
  Unknown = 'unknown'
}

export enum ReplicationSqlRunning {
  Yes = 'yes',
  No = 'no',
  Unknown = 'unknown'
}

export class MetricGauge implements ServerMetricsModel {
  value: bigint = 0n;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    addUnsigned64Error(errors, this.value, 'Metric value');
    return errors;
  }
}

export class MetricCounter implements ServerMetricsModel {
  value: bigint = 0n;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    addUnsigned64Error(errors, this.value, 'Metric value');
    return errors;
  }
}

export class ServerMetricsCategory<T extends ServerMetricsModel> implements ServerMetricsModel {
  availability: ServerMetricsAvailability = ServerMetricsAvailability.Unsupported;
  sampledAtUptimeMs: number | null = null;
  data: T | null = null;
  errorKind: ServerMetricsErrorKind | null = null;
  errorCode: number | null = null;
  errorSqlState: string | null = null;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    const mapped = this.availability === ServerMetricsAvailability.Available ||
      this.availability === ServerMetricsAvailability.Empty;

    if (mapped) {
      if (this.sampledAtUptimeMs === null) {
        errors.push(validationError('Metrics sample uptime is required for mapped results'));
      } else {
        addNonNegativeSafeIntegerError(errors, this.sampledAtUptimeMs, 'Metrics sample uptime');
      }
      if (this.data === null) {
        errors.push(validationError('Metrics data is required for available and empty results'));
      } else {
        appendErrors(errors, this.data.validate());
      }
      if (this.errorKind !== null || this.errorCode !== null || this.errorSqlState !== null) {
        errors.push(validationError('Mapped metrics results cannot include errors'));
      }
    } else {
      if (this.sampledAtUptimeMs !== null) {
        errors.push(validationError('Unavailable metrics results cannot include sample uptime'));
      }
      if (this.data !== null) {
        errors.push(validationError('Unavailable metrics results cannot include data'));
      }
      if (this.errorKind === null) {
        errors.push(validationError('Unavailable metrics results require an error kind'));
      } else if (this.errorKindAllowedForAvailability()) {
        this.validateErrorMetadata(errors);
      } else {
        errors.push(validationError('Metrics error kind is not valid for availability'));
      }
    }
    return errors;
  }

  private errorKindAllowedForAvailability(): boolean {
    if (this.availability === ServerMetricsAvailability.Unsupported) {
      return this.errorKind === ServerMetricsErrorKind.UnsupportedProduct ||
        this.errorKind === ServerMetricsErrorKind.UnsupportedSource ||
        this.errorKind === ServerMetricsErrorKind.Server;
    }
    if (this.availability === ServerMetricsAvailability.Disabled) {
      return this.errorKind === ServerMetricsErrorKind.PerformanceSchemaDisabled;
    }
    if (this.availability === ServerMetricsAvailability.PermissionDenied) {
      return this.errorKind === ServerMetricsErrorKind.Server;
    }
    return false;
  }

  private validateErrorMetadata(errors: ArkDbError[]): void {
    if (this.errorKind === ServerMetricsErrorKind.Server) {
      if (this.errorCode === null) {
        errors.push(validationError('Server metrics errors require an error code'));
      } else {
        addNonNegativeSafeIntegerError(errors, this.errorCode, 'Metrics error code');
      }
      if (this.errorSqlState === null) {
        errors.push(validationError('Server metrics errors require a SQLSTATE'));
      } else if (this.errorSqlState.length !== 5) {
        errors.push(validationError('Metrics SQLSTATE must be five characters'));
      }
    } else {
      if (this.errorCode !== null || this.errorSqlState !== null) {
        errors.push(validationError('Local metrics errors cannot include server metadata'));
      }
    }
  }
}

export class ServerOverviewSnapshot implements ServerMetricsModel {
  threadsConnected: MetricGauge = new MetricGauge();
  threadsRunning: MetricGauge = new MetricGauge();
  connectionAttempts: MetricCounter = new MetricCounter();
  abortedConnectionAttempts: MetricCounter = new MetricCounter();
  maxUsedConnections: MetricGauge = new MetricGauge();

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    appendErrors(errors, this.threadsConnected.validate());
    appendErrors(errors, this.threadsRunning.validate());
    appendErrors(errors, this.connectionAttempts.validate());
    appendErrors(errors, this.abortedConnectionAttempts.validate());
    appendErrors(errors, this.maxUsedConnections.validate());
    return errors;
  }
}

export class ServerProcessInfo implements ServerMetricsModel {
  command: string = '';
  state: string | null = null;
  durationSeconds: number = 0;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    addUtf8BoundError(errors, this.command, 1, MAX_PROCESS_COMMAND_UTF8_BYTES,
      'Process command');
    if (this.state !== null) {
      addUtf8BoundError(errors, this.state, 0, MAX_PROCESS_STATE_UTF8_BYTES,
        'Process state');
    }
    addNonNegativeSafeIntegerError(errors, this.durationSeconds, 'Process duration');
    return errors;
  }
}

export class ServerProcessSnapshot implements ServerMetricsModel {
  rows: ServerProcessInfo[] = [];
  truncated: boolean = false;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (this.rows.length > MAX_METRICS_PROCESS_ROWS) {
      errors.push(validationError('Process snapshot exceeds the row limit'));
    }
    for (const row of this.rows) {
      appendErrors(errors, row.validate());
    }
    return errors;
  }
}

export class InnoDbSnapshot implements ServerMetricsModel {
  bufferPoolPagesTotal: MetricGauge = new MetricGauge();
  bufferPoolPagesFree: MetricGauge = new MetricGauge();
  bufferPoolPagesData: MetricGauge = new MetricGauge();
  bufferPoolPagesDirty: MetricGauge = new MetricGauge();
  bufferPoolReadRequests: MetricCounter = new MetricCounter();
  bufferPoolReads: MetricCounter = new MetricCounter();
  bufferPoolWriteRequests: MetricCounter = new MetricCounter();
  bufferPoolPagesFlushed: MetricCounter = new MetricCounter();
  rowsRead: MetricCounter = new MetricCounter();
  rowsInserted: MetricCounter = new MetricCounter();
  rowsUpdated: MetricCounter = new MetricCounter();
  rowsDeleted: MetricCounter = new MetricCounter();

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    appendErrors(errors, this.bufferPoolPagesTotal.validate());
    appendErrors(errors, this.bufferPoolPagesFree.validate());
    appendErrors(errors, this.bufferPoolPagesData.validate());
    appendErrors(errors, this.bufferPoolPagesDirty.validate());
    appendErrors(errors, this.bufferPoolReadRequests.validate());
    appendErrors(errors, this.bufferPoolReads.validate());
    appendErrors(errors, this.bufferPoolWriteRequests.validate());
    appendErrors(errors, this.bufferPoolPagesFlushed.validate());
    appendErrors(errors, this.rowsRead.validate());
    appendErrors(errors, this.rowsInserted.validate());
    appendErrors(errors, this.rowsUpdated.validate());
    appendErrors(errors, this.rowsDeleted.validate());
    return errors;
  }
}

export class QueryActivitySnapshot implements ServerMetricsModel {
  questions: MetricCounter = new MetricCounter();
  queries: MetricCounter = new MetricCounter();
  slowQueries: MetricCounter = new MetricCounter();

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    appendErrors(errors, this.questions.validate());
    appendErrors(errors, this.queries.validate());
    appendErrors(errors, this.slowQueries.validate());
    return errors;
  }
}

export class ReplicationChannelInfo implements ServerMetricsModel {
  channelName: string = '';
  ioRunning: ReplicationIoRunning = ReplicationIoRunning.Unknown;
  sqlRunning: ReplicationSqlRunning = ReplicationSqlRunning.Unknown;
  secondsBehindSource: bigint | null = null;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    addUtf8BoundError(errors, this.channelName, 0, MAX_REPLICATION_CHANNEL_NAME_UTF8_BYTES,
      'Replication channel name');
    if (this.secondsBehindSource !== null) {
      addUnsigned64Error(errors, this.secondsBehindSource, 'Replication lag');
    }
    return errors;
  }
}

export class ReplicationSnapshot implements ServerMetricsModel {
  channels: ReplicationChannelInfo[] = [];
  truncated: boolean = false;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (this.channels.length > MAX_METRICS_REPLICATION_CHANNELS) {
      errors.push(validationError('Replication snapshot exceeds the channel limit'));
    }
    for (const channel of this.channels) {
      appendErrors(errors, channel.validate());
    }
    return errors;
  }
}

function validationError(message: string): ArkDbError {
  return new ArkDbError(ArkDbErrorKind.Validation, message);
}

function appendErrors(target: ArkDbError[], source: ArkDbError[]): void {
  for (const error of source) {
    target.push(error);
  }
}

function addNonNegativeSafeIntegerError(errors: ArkDbError[], value: number, field: string): void {
  if (!Number.isSafeInteger(value) || value < 0) {
    errors.push(validationError(field + ' must be a non-negative safe integer'));
  }
}

function addUnsigned64Error(errors: ArkDbError[], value: bigint, field: string): void {
  if (value < 0n || value > MAX_METRICS_UNSIGNED_64) {
    errors.push(validationError(field + ' must be an unsigned 64-bit value'));
  }
}

function addUtf8BoundError(errors: ArkDbError[], value: string, minBytes: number,
  maxBytes: number, field: string): void {
  const bytes = utf8ByteLength(value);
  if (bytes < minBytes || bytes > maxBytes) {
    errors.push(validationError(field + ' must be between ' + String(minBytes) +
      ' and ' + String(maxBytes) + ' UTF-8 bytes'));
  }
}

function utf8ByteLength(value: string): number {
  let bytes = 0;
  for (let i = 0; i < value.length; i++) {
    const code = value.charCodeAt(i);
    if (code <= 0x7F) {
      bytes += 1;
    } else if (code <= 0x7FF) {
      bytes += 2;
    } else if (code >= 0xD800 && code <= 0xDBFF && i + 1 < value.length) {
      const next = value.charCodeAt(i + 1);
      if (next >= 0xDC00 && next <= 0xDFFF) {
        bytes += 4;
        i++;
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
