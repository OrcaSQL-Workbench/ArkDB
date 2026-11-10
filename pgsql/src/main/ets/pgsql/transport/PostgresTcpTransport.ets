import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import {
  ArkDbError, ConnectionTimerPort, SystemConnectionTimerPort
} from '@arkdb/core';
import { PostgresByteTransport } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES } from '../protocol/PostgresProtocolConstants';
import {
  PostgresSslConfig, PostgresSslMode
} from '../model/PostgresConnectionConfig';
import {
  postgresParseCertificateSubjectAlternativeName
} from './PostgresCertificateDer';
const MAX_POSTGRES_WIRE_BYTES: number = MAX_POSTGRES_MESSAGE_BYTES + 1;
const RECEIVE_BLOCK_BYTES: number = 64 * 1024;
const SOCKET_CLOSE_TIMEOUT_MS: number = 1000;
const MAX_TLS_FILE_BYTES: number = 1024 * 1024;
interface PendingRead {
  need: number;
  resolve: (value: Uint8Array | null | PromiseLike<Uint8Array | null>) => void;
  reject: (reason?: Object) => void;
}
interface PostgresStreamSocket {
  listen(message: (data: Uint8Array) => void, close: () => void,
    error: (failure: Object) => void): void;
  clearListeners(): void;
  send(data: Uint8Array): Promise<void>;
  close(): Promise<void>;
}
export interface PostgresTcpSocket extends PostgresStreamSocket {
  connect(host: string, port: number, timeoutMs: number): Promise<void>;
  prepareUpgrade(): void;
  upgrade(): PostgresTlsSocket;
}
export interface PostgresTlsSocket extends PostgresStreamSocket {
  connectTls(host: string, port: number, config: PostgresSslConfig,
    timeoutMs: number): Promise<void>;
  verifyPeerIdentity(host: string): Promise<void>;
}
export interface PostgresTcpSocketFactory {
  create(): PostgresTcpSocket;
}
class NetworkKitPostgresTcpSocket implements PostgresTcpSocket {
  private readonly tcp: socket.TCPSocket;
  private readonly verifier: PostgresTlsIdentityVerifier;
  constructor(verifier: PostgresTlsIdentityVerifier) {
    this.tcp = socket.constructTCPSocketInstance();
    this.verifier = verifier;
  }
  listen(message: (data: Uint8Array) => void, close: () => void,
    error: (failure: Object) => void): void {
    this.tcp.on('message', (info: socket.SocketMessageInfo): void => {
      message(new Uint8Array(info.message));
    });
    this.tcp.on('close', close);
    this.tcp.on('error', (failure: BusinessError): void => {
      error(failure);
    });
  }
  clearListeners(): void {
    clearNetworkKitListeners(this.tcp);
  }
  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    const address: socket.NetAddress = { address: host, port: port };
    const options: socket.TCPConnectOptions = {
      address: address,
      timeout: timeoutMs
    };
    try {
      await this.tcp.connect(options);
    } catch (error) {
      throw new Error(asMessage(error as Object));
    }
  }
  async send(data: Uint8Array): Promise<void> {
    const copy = new ArrayBuffer(data.length);
    new Uint8Array(copy).set(data);
    const options: socket.TCPSendOptions = { data: copy };
    try {
      await this.tcp.send(options);
    } catch (error) {
      throw new Error(asMessage(error as Object));
    }
  }
  async close(): Promise<void> {
    try {
      await this.tcp.close();
    } catch (error) {
      throw new Error(asMessage(error as Object));
    }
  }
  prepareUpgrade(): void {
    this.tcp.off('message');
  }
  upgrade(): PostgresTlsSocket {
    try {
      clearNetworkKitListeners(this.tcp);
      return new NetworkKitPostgresTlsSocket(
        socket.constructTLSSocketInstance(this.tcp), this.verifier);
    } catch (error) {
      if (error instanceof ArkDbError) throw error;
      throw new Error(asMessage(error as Object));
    }
  }
}
class NetworkKitPostgresTlsSocket implements PostgresTlsSocket {
  private readonly tls: socket.TLSSocket;
  private readonly verifier: PostgresTlsIdentityVerifier;
  constructor(tls: socket.TLSSocket, verifier: PostgresTlsIdentityVerifier) {
    this.tls = tls;
    this.verifier = verifier;
  }
  listen(message: (data: Uint8Array) => void, close: () => void,
    error: (failure: Object) => void): void {
    this.tls.on('message', (info: socket.SocketMessageInfo): void => {
      message(new Uint8Array(info.message));
    });
    this.tls.on('close', close);
    this.tls.on('error', (failure: BusinessError): void => error(failure));
  }
  clearListeners(): void {
    clearNetworkKitListeners(this.tls);
  }
  async connectTls(host: string, port: number, config: PostgresSslConfig,
    timeoutMs: number): Promise<void> {
    try {
      await this.tls.connect(
        buildPostgresTlsConnectOptions(host, port, config, timeoutMs));
    } catch (error) {
      if (error instanceof ArkDbError) throw error;
      throw new Error(asMessage(error as Object));
    }
  }
  async verifyPeerIdentity(host: string): Promise<void> {
    try {
      await this.verifier.verify(
        await this.tls.getRemoteCertificate(), host);
    } catch (error) {
      if (error instanceof ArkDbError) throw error;
      throw new Error(asMessage(error as Object));
    }
  }
  async send(data: Uint8Array): Promise<void> {
    const copy = new ArrayBuffer(data.length);
    new Uint8Array(copy).set(data);
    try {
      await this.tls.send(copy);
    } catch (error) {
      throw new Error(asMessage(error as Object));
    }
  }
  async close(): Promise<void> {
    try {
      await this.tls.close();
    } catch (error) {
      throw new Error(asMessage(error as Object));
    }
  }
}
class NetworkKitPostgresTcpSocketFactory implements PostgresTcpSocketFactory {
  private readonly verifier: PostgresTlsIdentityVerifier =
    createDefaultPostgresTlsIdentityVerifier();
  create(): PostgresTcpSocket {
    return new NetworkKitPostgresTcpSocket(this.verifier);
  }
}
export class PostgresTcpTransport implements PostgresByteTransport {
  private readonly factory: PostgresTcpSocketFactory;
  private readonly maximumReceiveBytes: number;
  private readonly timers: ConnectionTimerPort;
  private active: PostgresStreamSocket | null = null;
  private tcp: PostgresTcpSocket | null = null;
  private tlsPrepared: boolean = false;
  private tlsActive: boolean = false;
  private chunks: Uint8Array[] = [];
  private buffered: number = 0;
  private headIndex: number = 0;
  private headOffset: number = 0;
  private tailLength: number = 0;
  private pending: PendingRead | null = null;
  private fatal: ArkDbError | null = null;
  private closeTask: Promise<void> = Promise.resolve();
  private closeFailure: ArkDbError | null = null;
  private operationFailures: Array<(error: ArkDbError) => void> = [];
  constructor(factory: PostgresTcpSocketFactory = new NetworkKitPostgresTcpSocketFactory(),
    maximumReceiveBytes: number = MAX_POSTGRES_MESSAGE_BYTES,
    timers: ConnectionTimerPort = new SystemConnectionTimerPort()) {
    if (!Number.isSafeInteger(maximumReceiveBytes) ||
      maximumReceiveBytes <= 0 || maximumReceiveBytes > MAX_POSTGRES_MESSAGE_BYTES) {
      throw ArkDbError.validation(
        'PostgreSQL receive buffer limit must be between 1 and 33554432 bytes');
    }
    this.factory = factory;
    this.maximumReceiveBytes = maximumReceiveBytes;
    this.timers = timers;
  }
  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    this.throwIfFailed();
    if (this.active !== null) {
      throw ArkDbError.protocol('PostgreSQL transport is already connected');
    }
    try {
      const current = this.factory.create();
      this.active = current;
      this.tcp = current;
      current.listen(
        (data: Uint8Array): void => {
          if (this.active === current && !this.tlsPrepared) {
            this.onData(data);
          }
        },
        (): void => {
          if (this.active === current) this.onClose(false);
        },
        (error: Object): void => {
          if (this.active === current) this.onError(error, false);
        }
      );
      await this.runWhileOpen((): Promise<void> =>
        current.connect(host, port, timeoutMs));
      this.throwIfFailed();
    } catch (error) {
      const failure = error instanceof ArkDbError ? error :
        ArkDbError.network('PostgreSQL TCP connect failed: ' + asMessage(error));
      this.fail(failure);
      await this.closeTask;
      throw this.fatal!;
    }
  }
  prepareTlsUpgrade(): void {
    this.throwIfFailed();
    const current = this.tcp;
    if (current === null || this.active !== current || this.tlsActive) {
      throw ArkDbError.tls(
        'PostgreSQL TCP socket is not available for TLS upgrade');
    }
    if (this.pending !== null || this.buffered !== 0 ||
      this.operationFailures.length !== 0) {
      throw ArkDbError.protocol(
        'PostgreSQL TLS upgrade requires an idle empty plaintext stream');
    }
    try {
      current.prepareUpgrade();
      this.tlsPrepared = true;
    } catch (error) {
      const failure = error instanceof ArkDbError ? error :
        ArkDbError.tls('PostgreSQL TLS listener handoff failed: ' +
          asMessage(error as Object));
      this.fail(failure);
      throw failure;
    }
  }
  async upgradeToTls(host: string, port: number, config: PostgresSslConfig,
    timeoutMs: number): Promise<void> {
    this.throwIfFailed();
    const current = this.tcp;
    if (current === null || this.active !== current || !this.tlsPrepared) {
      throw ArkDbError.protocol('PostgreSQL TLS upgrade was not prepared');
    }
    if (this.pending !== null || this.buffered !== 0 ||
      this.operationFailures.length !== 0) {
      throw ArkDbError.protocol(
        'PostgreSQL TLS upgrade requires an idle empty plaintext stream');
    }
    const tlsConfig = config.clone();
    if (tlsConfig.mode === PostgresSslMode.DISABLED) {
      const failure = ArkDbError.tls('PostgreSQL TLS is disabled');
      this.fail(failure);
      await this.closeTask;
      throw this.fatal!;
    }

    let tls: PostgresTlsSocket;
    try {
      tls = current.upgrade();
    } catch (error) {
      const failure = error instanceof ArkDbError ? error :
        ArkDbError.tls('PostgreSQL TLS socket construction failed: ' +
          asMessage(error as Object));
      this.fail(failure);
      await this.closeTask;
      throw this.fatal!;
    }
    this.tcp = null;
    this.active = tls;
    this.tlsActive = true;

    let phase = 'listener setup';
    try {
      tls.listen(
        (data: Uint8Array): void => {
          if (this.active === tls) this.onData(data);
        },
        (): void => {
          if (this.active === tls) this.onClose(true);
        },
        (error: Object): void => {
          if (this.active === tls) this.onError(error, true);
        }
      );
      phase = 'connect';
      await this.runWhileOpen((): Promise<void> =>
        tls.connectTls(host, port, tlsConfig, timeoutMs));
      if (tlsConfig.mode === PostgresSslMode.VERIFY_FULL) {
        phase = 'verification';
        await this.runWhileOpen((): Promise<void> =>
          tls.verifyPeerIdentity(host));
      }
      this.throwIfFailed();
      this.tlsPrepared = false;
    } catch (error) {
      const failure = error instanceof ArkDbError ? error :
        ArkDbError.tls('PostgreSQL TLS ' + phase + ' failed: ' +
          asMessage(error as Object));
      this.fail(failure);
      await this.closeTask;
      throw this.fatal!;
    }
  }
  read(length: number): Promise<Uint8Array | null> {
    return new Promise<Uint8Array | null>(
      (resolve: (value: Uint8Array | null | PromiseLike<Uint8Array | null>) => void,
        reject: (reason?: Object) => void): void => {
        if (this.fatal !== null) {
          reject(this.fatal);
          return;
        }
        if (!Number.isSafeInteger(length) || length < 0 ||
          length > this.maximumReceiveBytes) {
          reject(ArkDbError.validation(
            'PostgreSQL read length exceeds the receive buffer limit'));
          return;
        }
        if (this.pending !== null) {
          reject(ArkDbError.protocol('Concurrent PostgreSQL transport reads are not supported'));
          return;
        }
        if (this.tlsPrepared) {
          reject(ArkDbError.protocol(
            'PostgreSQL TLS upgrade is prepared'));
          return;
        }
        if (this.active === null) {
          reject(ArkDbError.network('PostgreSQL socket is not connected'));
          return;
        }
        this.pending = { need: length, resolve: resolve, reject: reject };
        this.tryResolve();
      });
  }
  async write(data: Uint8Array): Promise<number> {
    this.throwIfFailed();
    if (this.tlsPrepared) {
      throw ArkDbError.protocol('PostgreSQL TLS upgrade is prepared');
    }
    if (data.length > MAX_POSTGRES_WIRE_BYTES) {
      throw ArkDbError.validation('PostgreSQL transport write exceeds the message limit');
    }
    const current = this.active;
    const isTls = this.tlsActive;
    try {
      if (current === null) throw ArkDbError.network('PostgreSQL socket is not connected');
      await this.runWhileOpen((): Promise<void> => current.send(data));
      this.throwIfFailed();
      return data.length;
    } catch (error) {
      const failure = error instanceof ArkDbError ? error :
        isTls ?
          ArkDbError.tls(
            'PostgreSQL TLS send failed: ' + asMessage(error)) :
          ArkDbError.network(
            'PostgreSQL socket send failed: ' + asMessage(error));
      this.fail(failure);
      await this.closeTask;
      throw this.fatal!;
    }
  }
  runWhileOpen<T>(operation: () => Promise<T>): Promise<T> {
    return new Promise<T>((resolve: (value: T | PromiseLike<T>) => void,
      reject: (reason?: Object) => void): void => {
      if (this.fatal !== null) {
        reject(this.fatal);
        return;
      }
      let settled = false;
      const rejectOperation = (error: Object): void => {
        if (settled) return;
        settled = true;
        this.removeOperationFailure(rejectOperation);
        reject(error);
      };
      this.operationFailures.push(rejectOperation);
      try {
        operation().then((value: T): void => {
          if (settled) return;
          settled = true;
          this.removeOperationFailure(rejectOperation);
          resolve(value);
        }, rejectOperation);
      } catch (error) {
        rejectOperation(error as Object);
      }
    });
  }
  async close(): Promise<void> {
    await this.abort(ArkDbError.network('PostgreSQL transport closed'));
  }
  async abort(error: ArkDbError): Promise<void> {
    this.fail(error);
    await this.closeTask;
    if (this.closeFailure !== null) throw this.closeFailure;
  }
  private onData(data: Uint8Array): void {
    if (this.fatal !== null || data.length === 0) return;
    let offset = 0;
    const pending = this.pending;
    if (pending !== null && this.buffered < pending.need) {
      const count = Math.min(pending.need - this.buffered, data.length);
      this.append(data, 0, count);
      offset = count;
      this.tryResolve();
    }
    const remaining = data.length - offset;
    if (remaining > this.maximumReceiveBytes - this.buffered) {
      this.fail(ArkDbError.protocol('PostgreSQL receive buffer exceeds client limit'));
      return;
    }
    this.append(data, offset, remaining);
    this.tryResolve();
  }
  private onClose(tls: boolean): void {
    this.fail(tls ?
      ArkDbError.tls('PostgreSQL TLS socket closed by server') :
      ArkDbError.network('PostgreSQL socket closed by server'), true);
  }
  private onError(error: Object, tls: boolean): void {
    this.fail(tls ?
      ArkDbError.tls(
        'PostgreSQL TLS socket error: ' + asMessage(error)) :
      ArkDbError.network(
        'PostgreSQL socket error: ' + asMessage(error)));
  }
  private tryResolve(): void {
    const pending = this.pending;
    if (pending === null || this.buffered < pending.need) return;
    this.pending = null;
    pending.resolve(this.take(pending.need));
  }
  private take(length: number): Uint8Array {
    const result = new Uint8Array(length);
    let offset = 0;
    while (offset < length) {
      const head = this.chunks[this.headIndex];
      const end = this.headIndex === this.chunks.length - 1 ?
        this.tailLength : head.length;
      const count = Math.min(end - this.headOffset, length - offset);
      result.set(head.subarray(this.headOffset, this.headOffset + count), offset);
      this.headOffset += count;
      offset += count;
      if (this.headOffset === end) {
        this.headIndex += 1;
        this.headOffset = 0;
      }
    }
    this.buffered -= length;
    this.compactChunks();
    return result;
  }
  private append(data: Uint8Array, start: number, length: number): void {
    let offset = start;
    const end = start + length;
    while (offset < end) {
      if (this.chunks.length === this.headIndex ||
        this.tailLength === this.chunks[this.chunks.length - 1].length) {
        this.chunks.push(new Uint8Array(
          Math.min(RECEIVE_BLOCK_BYTES, this.maximumReceiveBytes)));
        this.tailLength = 0;
      }
      const tail = this.chunks[this.chunks.length - 1];
      const count = Math.min(tail.length - this.tailLength, end - offset);
      tail.set(data.subarray(offset, offset + count), this.tailLength);
      this.tailLength += count;
      offset += count;
    }
    this.buffered += length;
  }
  private compactChunks(): void {
    if (this.headIndex === this.chunks.length) {
      this.chunks = [];
      this.headIndex = 0;
      this.tailLength = 0;
    } else if (this.headIndex >= 64 && this.headIndex * 2 >= this.chunks.length) {
      this.chunks = this.chunks.slice(this.headIndex);
      this.headIndex = 0;
    }
  }
  private fail(error: ArkDbError, alreadyClosed: boolean = false): void {
    if (this.fatal !== null) return;
    this.fatal = error;
    this.chunks = [];
    this.buffered = 0;
    this.headIndex = 0;
    this.headOffset = 0;
    this.tailLength = 0;
    const pending = this.pending;
    this.pending = null;
    if (pending !== null) pending.reject(error);
    const operations = this.operationFailures;
    this.operationFailures = [];
    for (const reject of operations) reject(error);
    const current = this.active;
    this.active = null;
    this.tcp = null;
    this.tlsPrepared = false;
    this.tlsActive = false;
    if (current !== null) this.closeTask = this.releaseSocket(current, alreadyClosed);
  }
  private async releaseSocket(current: PostgresStreamSocket,
    alreadyClosed: boolean): Promise<void> {
    let cleanupFailure: ArkDbError | null = null;
    try {
      current.clearListeners();
    } catch (error) {
      cleanupFailure = ArkDbError.network(
        'PostgreSQL socket listener cleanup failed: ' + asMessage(error));
    }
    if (alreadyClosed) {
      this.closeFailure = cleanupFailure;
      return;
    }
    await new Promise<void>((resolve: () => void): void => {
      let settled = false;
      let timerId = 0;
      const finish = (failure: ArkDbError | null): void => {
        if (settled) return;
        settled = true;
        this.timers.cancel(timerId);
        this.closeFailure = failure === null ? cleanupFailure : failure;
        resolve();
      };
      const failed = (error: Object): void => {
        finish(ArkDbError.network('PostgreSQL socket close failed: ' + asMessage(error)));
      };
      timerId = this.timers.schedule((): void => {
        finish(ArkDbError.network('PostgreSQL socket close timed out'));
      }, SOCKET_CLOSE_TIMEOUT_MS);
      try {
        current.close().then((): void => finish(null), failed);
      } catch (error) {
        failed(error as Object);
      }
    });
  }
  private removeOperationFailure(listener: (error: ArkDbError) => void): void {
    const index = this.operationFailures.indexOf(listener);
    if (index >= 0) this.operationFailures.splice(index, 1);
  }
  private throwIfFailed(): void {
    if (this.fatal !== null) throw this.fatal;
  }
}
function clearNetworkKitListeners(
  active: socket.TCPSocket | socket.TLSSocket): void {
  let firstFailure: Object | null = null;
  try {
    active.off('message');
  } catch (error) {
    firstFailure = error as Object;
  }
  try {
    active.off('close');
  } catch (error) {
    if (firstFailure === null) firstFailure = error as Object;
  }
  try {
    active.off('error');
  } catch (error) {
    if (firstFailure === null) firstFailure = error as Object;
  }
  if (firstFailure !== null) throw new Error(asMessage(firstFailure));
}
function asMessage(error: Object): string {
  if (error instanceof Error && error.message.length > 0) return error.message;
  const failure = error as BusinessError;
  if (failure !== null && failure !== undefined &&
    typeof failure.message === 'string' && failure.message.length > 0) return failure.message;
  return String(error);
}
export interface PostgresTlsFilePort {
  read(path: string, maximumBytes: number, label: string): string;
}
export interface PostgresTlsIdentityVerifier {
  verify(certificate: socket.X509CertRawData, host: string): Promise<void>;
}
class UnsupportedPostgresTlsIdentityVerifier
implements PostgresTlsIdentityVerifier {
  async verify(certificate: socket.X509CertRawData, host: string): Promise<void> {
    throw ArkDbError.tls(
      'PostgreSQL VERIFY_FULL identity verification is not available in this build',
      'TLS_IDENTITY_VERIFIER_UNAVAILABLE');
  }
}
export function createDefaultPostgresTlsIdentityVerifier(): PostgresTlsIdentityVerifier {
  return new UnsupportedPostgresTlsIdentityVerifier();
}
export function postgresCertificateHasSubjectAlternativeName(
  certificateDer: Uint8Array): boolean {
  return postgresParseCertificateSubjectAlternativeName(
    certificateDer).present;
}
class SystemPostgresTlsFilePort implements PostgresTlsFilePort {
  read(path: string, maximumBytes: number, label: string): string {
    try {
      const size = fileIo.statSync(path).size;
      if (!Number.isSafeInteger(size) || size < 1 || size > maximumBytes) {
        throw new Error(label + ' file must be between 1 byte and 1 MiB');
      }
      return fileIo.readTextSync(path, {
        offset: 0,
        length: size,
        encoding: 'utf-8'
      });
    } catch (error) {
      if (error instanceof Error) throw error;
      throw new Error(asMessage(error as Object));
    }
  }
}
export function buildPostgresTlsConnectOptions(host: string, port: number,
  config: PostgresSslConfig, timeoutMs: number,
  files: PostgresTlsFilePort = new SystemPostgresTlsFilePort()): socket.TLSConnectOptions {
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 ||
    timeoutMs > 0xFFFFFFFF) {
    throw ArkDbError.tls(
      'PostgreSQL TLS timeout must be between 1 and 4294967295 milliseconds');
  }
  if (config.mode !== PostgresSslMode.DISABLED &&
    config.mode !== PostgresSslMode.REQUIRED &&
    config.mode !== PostgresSslMode.VERIFY_CA &&
    config.mode !== PostgresSslMode.VERIFY_FULL) {
    throw ArkDbError.tls('Unsupported PostgreSQL TLS mode: ' + config.mode);
  }
  if (config.mode === PostgresSslMode.DISABLED) {
    throw ArkDbError.tls('PostgreSQL TLS is disabled');
  }
  const secureOptions: socket.TLSSecureOptions = {};
  if (config.mode === PostgresSslMode.VERIFY_CA ||
    config.mode === PostgresSslMode.VERIFY_FULL) {
    const caPath = configuredPath(config.caCertPath);
    if (caPath.length > 0) {
      secureOptions.ca = readTlsText(files, caPath, 'CA certificate');
    }
  }
  const certPath = configuredPath(config.clientCertPath);
  const keyPath = configuredPath(config.clientKeyPath);
  if ((certPath.length > 0) !== (keyPath.length > 0)) {
    throw ArkDbError.tls(
      'Client certificate and private key must be configured together');
  }
  if (certPath.length > 0) {
    secureOptions.cert =
      readTlsText(files, certPath, 'client certificate');
    secureOptions.key =
      readTlsText(files, keyPath, 'client private key');
    secureOptions.isBidirectionalAuthentication = true;
  }
  const protocols = tlsProtocols(config.tlsVersions);
  if (protocols.length > 0) secureOptions.protocols = protocols;
  const cipherSuite = config.cipherSuites?.trim();
  if (cipherSuite !== undefined && cipherSuite.length > 0) {
    secureOptions.cipherSuite = cipherSuite;
  }
  return {
    address: { address: host, port: port },
    secureOptions: secureOptions,
    skipRemoteValidation: config.mode === PostgresSslMode.REQUIRED,
    timeout: timeoutMs
  };
}
function configuredPath(path: string | undefined): string {
  return path === undefined ? '' : path.trim();
}
function readTlsText(files: PostgresTlsFilePort, path: string,
  label: string): string {
  try {
    return files.read(path, MAX_TLS_FILE_BYTES, label);
  } catch (error) {
    if (error instanceof ArkDbError) throw error;
    throw ArkDbError.tls('Could not read ' + label + ' file: ' +
      asMessage(error as Object));
  }
}

function tlsProtocols(versions: string[] | undefined):
Array<socket.Protocol> {
  const protocols: Array<socket.Protocol> = [];
  if (versions === undefined) return protocols;
  for (const version of versions) {
    if (version === 'TLSv1.2') {
      protocols.push(socket.Protocol.TLSv12);
    } else if (version === 'TLSv1.3') {
      protocols.push(socket.Protocol.TLSv13);
    } else {
      throw ArkDbError.tls('Unsupported TLS version: ' + version);
    }
  }
  return protocols;
}
