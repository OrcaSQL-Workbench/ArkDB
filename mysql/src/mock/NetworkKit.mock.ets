import { BusinessError } from '@kit.BasicServicesKit';
import { cert } from '@kit.DeviceCertificateKit';

interface MessageInfo {
  message: ArrayBuffer;
}

type MessageListener = (info: MessageInfo) => void;
type CloseListener = () => void;
type ErrorListener = (error: BusinessError) => void;

/** Deterministic socket events and certificate responses; no network or TLS engine. */
export class MockSocket {
  closeCalls: number = 0;
  connectResult: Promise<void> | null = null;
  sendResult: Promise<void> | null = null;
  closeResult: Promise<void> | null = null;
  connectFailure: Error | null = null;
  sendFailure: Error | null = null;
  closeFailure: Error | null = null;
  remoteCertificateCalls: number = 0;
  remoteCertificateResult: Promise<cert.EncodingBlob> | null = null;
  remoteCertificateFailure: Error | null = null;
  private messageListener: MessageListener | null = null;
  private closeListener: CloseListener | null = null;
  private errorListener: ErrorListener | null = null;
  private lastMessageListener: MessageListener | null = null;
  private lastCloseListener: CloseListener | null = null;
  private lastErrorListener: ErrorListener | null = null;

  on(type: string, listener: Object): void {
    if (type === 'message') {
      this.messageListener = listener as MessageListener;
      this.lastMessageListener = this.messageListener;
    } else if (type === 'close') {
      this.closeListener = listener as CloseListener;
      this.lastCloseListener = this.closeListener;
    } else if (type === 'error') {
      this.errorListener = listener as ErrorListener;
      this.lastErrorListener = this.errorListener;
    } else {
      throw new Error('Unexpected socket fixture event');
    }
  }

  off(type: string): void {
    if (type === 'message') this.messageListener = null;
    else if (type === 'close') this.closeListener = null;
    else if (type === 'error') this.errorListener = null;
    else throw new Error('Unexpected socket fixture event');
  }

  connect(options: Object): Promise<void> {
    if (this.connectFailure !== null) throw this.connectFailure;
    return this.connectResult === null ? Promise.resolve() : this.connectResult;
  }

  send(options: Object): Promise<void> {
    if (this.sendFailure !== null) throw this.sendFailure;
    return this.sendResult === null ? Promise.resolve() : this.sendResult;
  }

  close(): Promise<void> {
    this.closeCalls += 1;
    if (this.closeFailure !== null) throw this.closeFailure;
    return this.closeResult === null ? Promise.resolve() : this.closeResult;
  }

  getRemoteCertificate(): Promise<cert.EncodingBlob> {
    this.remoteCertificateCalls += 1;
    if (this.remoteCertificateFailure !== null) throw this.remoteCertificateFailure;
    return this.remoteCertificateResult === null
      ? Promise.reject(new Error('Synthetic remote certificate is not configured'))
      : this.remoteCertificateResult;
  }

  get listenerCount(): number {
    return (this.messageListener === null ? 0 : 1) +
      (this.closeListener === null ? 0 : 1) + (this.errorListener === null ? 0 : 1);
  }

  emitMessage(bytes: Uint8Array, late: boolean = false): void {
    const listener = late ? this.lastMessageListener : this.messageListener;
    const delivery = bytes.byteOffset === 0 && bytes.byteLength === bytes.buffer.byteLength ?
      bytes : bytes.slice();
    if (listener !== null) listener({ message: delivery.buffer as ArrayBuffer });
  }

  emitClose(late: boolean = false): void {
    const listener = late ? this.lastCloseListener : this.closeListener;
    if (listener !== null) listener();
  }

  emitError(late: boolean = false): void {
    const listener = late ? this.lastErrorListener : this.errorListener;
    const error: BusinessError = { name: 'SocketFixtureError', message: 'Synthetic socket failure', code: 2300002 };
    if (listener !== null) listener(error);
  }
}

export namespace socket {
  export enum Protocol {
    TLSv12 = 'TLSv1.2',
    TLSv13 = 'TLSv1.3'
  }

  export let latestTcp: MockSocket | null = null;
  export let latestTls: MockSocket | null = null;
  export let nextTcp: MockSocket | null = null;
  export let nextTls: MockSocket | null = null;

  export function constructTCPSocketInstance(): MockSocket {
    const instance = nextTcp === null ? new MockSocket() : nextTcp;
    nextTcp = null;
    latestTcp = instance;
    return instance;
  }

  export function constructTLSSocketInstance(tcp: MockSocket): MockSocket {
    tcp.off('message');
    tcp.off('close');
    tcp.off('error');
    const instance = nextTls === null ? new MockSocket() : nextTls;
    nextTls = null;
    latestTls = instance;
    return instance;
  }
}

export default socket;
