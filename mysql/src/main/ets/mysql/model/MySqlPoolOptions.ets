import { ArkDbError } from '@arkdb/core';

export class MySqlPoolOptions {
  maxSize: number = 4;
  minIdle: number = 0;
  maxQueueSize: number = 64;
  acquireTimeoutMs: number = 10000;
  releaseTimeoutMs: number = 5000;
  idleTimeoutMs: number = 60000;
  closeTimeoutMs: number = 5000;

  validate(): ArkDbError[] {
    const errors: ArkDbError[] = [];
    if (!Number.isSafeInteger(this.maxSize) || this.maxSize < 1 || this.maxSize > 64) {
      errors.push(ArkDbError.validation('MySQL pool maxSize must be an integer between 1 and 64.'));
    }
    if (!Number.isSafeInteger(this.minIdle) || this.minIdle < 0 ||
      this.minIdle > this.maxSize) {
      errors.push(ArkDbError.validation(
        'MySQL pool minIdle must be an integer between 0 and maxSize.'));
    }
    if (!Number.isSafeInteger(this.maxQueueSize) || this.maxQueueSize < 0 ||
      this.maxQueueSize > 4096) {
      errors.push(ArkDbError.validation(
        'MySQL pool maxQueueSize must be an integer between 0 and 4096.'));
    }
    if (!Number.isSafeInteger(this.acquireTimeoutMs) || this.acquireTimeoutMs < 1 ||
      this.acquireTimeoutMs > 86400000) {
      errors.push(ArkDbError.validation(
        'MySQL pool acquireTimeoutMs must be an integer between 1 and 86400000.'));
    }
    if (!Number.isSafeInteger(this.releaseTimeoutMs) || this.releaseTimeoutMs < 1 ||
      this.releaseTimeoutMs > 60000) {
      errors.push(ArkDbError.validation(
        'MySQL pool releaseTimeoutMs must be an integer between 1 and 60000.'));
    }
    if (!Number.isSafeInteger(this.idleTimeoutMs) || this.idleTimeoutMs < 0 ||
      this.idleTimeoutMs > 86400000) {
      errors.push(ArkDbError.validation(
        'MySQL pool idleTimeoutMs must be 0 or an integer between 1 and 86400000.'));
    }
    if (!Number.isSafeInteger(this.closeTimeoutMs) || this.closeTimeoutMs < 1 ||
      this.closeTimeoutMs > 60000) {
      errors.push(ArkDbError.validation(
        'MySQL pool closeTimeoutMs must be an integer between 1 and 60000.'));
    }
    return errors;
  }

  clone(): MySqlPoolOptions {
    const copy = new MySqlPoolOptions();
    copy.maxSize = this.maxSize;
    copy.minIdle = this.minIdle;
    copy.maxQueueSize = this.maxQueueSize;
    copy.acquireTimeoutMs = this.acquireTimeoutMs;
    copy.releaseTimeoutMs = this.releaseTimeoutMs;
    copy.idleTimeoutMs = this.idleTimeoutMs;
    copy.closeTimeoutMs = this.closeTimeoutMs;
    return copy;
  }
}
