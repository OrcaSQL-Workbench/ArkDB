import { ErrorEvent, MessageEvents, worker } from '@kit.ArkTS';
import { DeviceAcceptanceRequest, DeviceAcceptanceResponse, DeviceShutdownResponse } from './Messages';

let retryBlocked: boolean = false;
let workerActive: boolean = false;

export class DeviceWorkerHost {
  private readonly instance: worker.ThreadWorker;
  private readonly exit: Promise<void>;
  private readonly response: Promise<DeviceAcceptanceResponse>;
  private resolveResponse: ((response: DeviceAcceptanceResponse) => void) | null = null;
  private rejectResponse: ((error: Error) => void) | null = null;
  private finished: boolean = false;
  private started: boolean = false;
  private responseReceived: boolean = false;
  private stopSent: boolean = false;
  private shutdownAcknowledged: boolean = false;
  private cancelled: boolean = false;
  private failure: string = '';
  private shutdownTask: Promise<void> | null = null;
  private sentRequest: DeviceAcceptanceRequest | null = null;
  private executionTimer: number = -1;

  constructor() {
    if (retryBlocked) throw new Error('Worker exit is unconfirmed. Restart the app before retrying.');
    if (workerActive) throw new Error('An acceptance Worker is already active.');
    workerActive = true;
    try {
      this.instance = new worker.ThreadWorker('entry/ets/workers/device.worker.ets');
    } catch (_error) {
      workerActive = false;
      throw new Error('Acceptance Worker could not be started.');
    }
    this.response = new Promise<DeviceAcceptanceResponse>((resolve, reject): void => {
      this.resolveResponse = resolve;
      this.rejectResponse = reject;
    });
    this.exit = new Promise<void>((resolve): void => {
      this.instance.onexit = (code: number): void => {
        if (this.finished) return;
        this.finished = true;
        workerActive = false;
        this.clearSentRequest();
        if (!this.shutdownAcknowledged || code !== 0) this.setFailure('Worker exit was not confirmed safely.');
        if (!this.responseReceived) this.rejectPendingResponse();
        resolve();
      };
    });
    this.instance.onmessage = (event: MessageEvents): void => this.receive(event.data);
    this.instance.onerror = (_error: ErrorEvent): void => this.fail('Worker execution failed.');
    this.instance.onmessageerror = (): void => this.fail('Worker message could not be decoded.');
  }

  async run(request: DeviceAcceptanceRequest): Promise<DeviceAcceptanceResponse> {
    if (this.finished || this.started || this.shutdownTask !== null) {
      request.password = '';
      throw new Error('Worker has already started or stopped.');
    }
    this.started = true;
    const sent = this.copyRequest(request);
    request.password = '';
    this.sentRequest = sent;
    this.executionTimer = setTimeout((): void => {
      this.fail('Worker execution timed out; its outcome is unknown.');
    }, 24 * 60 * 60 * 1000);
    try {
      this.instance.postMessageWithSharedSendable(sent);
    } catch (_error) {
      sent.password = '';
      this.sentRequest = null;
      this.fail('Worker request could not be delivered.');
    }
    let response: DeviceAcceptanceResponse;
    try {
      response = await this.response;
    } catch (_error) {
      await this.shutdown();
      throw new Error('Worker execution outcome is unknown.');
    }
    await this.shutdown();
    if (this.cancelled) throw new Error('Worker execution was interrupted; its outcome is unknown.');
    return response;
  }

  private copyRequest(request: DeviceAcceptanceRequest): DeviceAcceptanceRequest {
    const copy = new DeviceAcceptanceRequest();
    copy.operation = request.operation;
    copy.host = request.host;
    copy.port = request.port;
    copy.user = request.user;
    copy.password = request.password;
    copy.database = request.database;
    copy.schema = request.schema;
    copy.caCertPath = request.caCertPath;
    copy.mismatchHost = request.mismatchHost;
    copy.profile = request.profile;
    copy.signedHapSha256 = request.signedHapSha256;
    copy.operatorEvidenceId = request.operatorEvidenceId;
    return copy;
  }

  stop(): Promise<void> {
    this.cancelled = true;
    return this.shutdown();
  }

  private receive(value: Object): void {
    if (this.finished) return;
    if (value instanceof DeviceAcceptanceResponse && this.started && !this.responseReceived) {
      this.responseReceived = true;
      if (this.resolveResponse !== null) this.resolveResponse(value);
    } else if (value instanceof DeviceShutdownResponse && this.stopSent &&
      !this.shutdownAcknowledged) {
      this.shutdownAcknowledged = true;
      if (!value.ok) this.setFailure('Worker cleanup could not be confirmed.');
    } else {
      this.fail('Worker returned an unexpected message.');
    }
  }

  private fail(message: string): void {
    this.setFailure(message);
    this.rejectPendingResponse();
    void this.shutdown().catch((): void => {
      console.error('Device acceptance Worker shutdown was not confirmed.');
    });
  }

  private setFailure(message: string): void {
    if (this.failure.length === 0) this.failure = message;
  }

  private rejectPendingResponse(): void {
    if (this.started && this.rejectResponse !== null) {
      this.rejectResponse(new Error('Worker execution outcome is unknown.'));
    }
  }

  private clearSentRequest(): void {
    if (this.sentRequest !== null) {
      this.sentRequest.password = '';
      this.sentRequest = null;
    }
  }

  private shutdown(): Promise<void> {
    if (this.shutdownTask !== null) return this.shutdownTask;
    if (this.executionTimer !== -1) {
      clearTimeout(this.executionTimer);
      this.executionTimer = -1;
    }
    this.shutdownTask = Promise.resolve().then((): Promise<void> => this.performShutdown());
    return this.shutdownTask;
  }

  private performShutdown(): Promise<void> {
    return new Promise<void>((resolve, reject): void => {
      let timer: number = 0;
      const abort = (): void => {
        this.setFailure('Worker shutdown timed out; its outcome is unknown.');
        this.clearSentRequest();
        if (this.finished) {
          reject(new Error(this.failure));
          return;
        }
        try {
          this.instance.terminate();
        } catch (_error) {
          retryBlocked = true;
          this.rejectPendingResponse();
          reject(new Error('Worker termination is unconfirmed. Restart the app before retrying.'));
          return;
        }
        timer = setTimeout((): void => {
          retryBlocked = true;
          this.rejectPendingResponse();
          reject(new Error('Worker termination is unconfirmed. Restart the app before retrying.'));
        }, 5000);
      };
      timer = setTimeout(abort, 5000);
      this.exit.then((): void => {
        clearTimeout(timer);
        if (this.failure.length > 0) reject(new Error(this.failure));
        else resolve();
      });
      if (!this.finished) {
        const request = new DeviceAcceptanceRequest();
        request.operation = 'stop';
        try {
          this.stopSent = true;
          this.instance.postMessageWithSharedSendable(request);
        } catch (_error) {
          clearTimeout(timer);
          abort();
        }
      }
    });
  }
}
