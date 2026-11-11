import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { cert } from '@kit.DeviceCertificateKit';
import {
  ArkDbError, ConnectionTimerPort, SystemConnectionTimerPort
} from '@arkdb/core';
import { PostgresByteTransport } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES } from '../protocol/PostgresProtocolConstants';
import {
  PostgresSslConfig, PostgresSslMode
} from '../model/PostgresConnectionConfig';
import {
  PostgresSubjectAlternativeNames,
  postgresParseCertificateSubjectAlternativeName,
  postgresParseSubjectAlternativeNamesEntry
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
export interface PostgresDecodedCertificate {
  subjectAlternativeNameExtension(): Uint8Array;
  subjectCommonNames(): string[];
}
export interface PostgresPeerCertificate {
  certificateDer(): Uint8Array;
  subjectAlternativeNameExtension(): Uint8Array;
  subjectCommonNames(): string[];
}
export interface PostgresPeerCertificateFactory {
  create(certificate: socket.X509CertRawData): Promise<PostgresPeerCertificate>;
}
class NetworkKitPostgresDecodedCertificate
implements PostgresDecodedCertificate {
  private readonly certificate: cert.X509Cert;
  constructor(certificate: cert.X509Cert) {
    this.certificate = certificate;
  }
  subjectAlternativeNameExtension(): Uint8Array {
    const oid: cert.DataBlob = {
      data: new Uint8Array([
        0x32, 0x2e, 0x35, 0x2e, 0x32, 0x39, 0x2e, 0x31, 0x37
      ])
    };
    return this.certificate.getExtensionsObject().getEntry(
      cert.ExtensionEntryType.EXTENSION_ENTRY_TYPE_ENTRY_VALUE, oid).data.slice();
  }
  subjectCommonNames(): string[] {
    return this.certificate.getSubjectX500DistinguishedName()
      .getName('CN').slice();
  }
}
export class NetworkKitPostgresPeerCertificate
implements PostgresPeerCertificate {
  private readonly certificate: PostgresDecodedCertificate;
  private readonly encoded: Uint8Array;
  constructor(certificate: PostgresDecodedCertificate, encoded: Uint8Array) {
    this.certificate = certificate;
    this.encoded = encoded.slice();
  }
  certificateDer(): Uint8Array {
    return this.encoded.slice();
  }
  subjectAlternativeNameExtension(): Uint8Array {
    return this.certificate.subjectAlternativeNameExtension().slice();
  }
  subjectCommonNames(): string[] {
    return this.certificate.subjectCommonNames().slice();
  }
}
class NetworkKitPostgresPeerCertificateFactory
implements PostgresPeerCertificateFactory {
  async create(encoded: socket.X509CertRawData):
  Promise<PostgresPeerCertificate> {
    const certificate = await cert.createX509Cert(encoded);
    return new NetworkKitPostgresPeerCertificate(
      new NetworkKitPostgresDecodedCertificate(certificate), encoded.data);
  }
}
class NetworkKitPostgresTlsIdentityVerifier
implements PostgresTlsIdentityVerifier {
  private readonly certificates: PostgresPeerCertificateFactory;
  constructor(certificates: PostgresPeerCertificateFactory =
    new NetworkKitPostgresPeerCertificateFactory()) {
    this.certificates = certificates;
  }
  async verify(certificate: socket.X509CertRawData, host: string): Promise<void> {
    try {
      const peer = await this.certificates.create(certificate);
      if (!postgresCertificateMatchesHost(peer, host)) {
        throw ArkDbError.tls(
          'PostgreSQL TLS certificate does not match the requested host',
          'TLS_HOSTNAME_MISMATCH');
      }
    } catch (error) {
      if (error instanceof ArkDbError) throw error;
      throw ArkDbError.tls(
        'Could not verify PostgreSQL TLS server identity: ' +
        asMessage(error as Object));
    }
  }
}
export function createDefaultPostgresTlsIdentityVerifier(
  certificates: PostgresPeerCertificateFactory =
    new NetworkKitPostgresPeerCertificateFactory()):
PostgresTlsIdentityVerifier {
  return new NetworkKitPostgresTlsIdentityVerifier(certificates);
}
export function postgresCertificateHasSubjectAlternativeName(
  certificateDer: Uint8Array): boolean {
  return postgresParseCertificateSubjectAlternativeName(
    certificateDer).present;
}
export function postgresCertificateMatchesHost(
  certificate: PostgresPeerCertificate, host: string): boolean {
  const names = subjectAlternativeNames(certificate);
  const address = postgresIpAddressBytes(host);
  if (address !== null) {
    if (names === null) return false;
    for (const candidate of names.ipAddresses) {
      if (bytesEqual(candidate, address)) return true;
    }
    return false;
  }
  if (looksLikeIpLiteral(host)) return false;
  if (names !== null && names.dnsNames.length > 0) {
    for (const candidate of names.dnsNames) {
      const name = asciiDnsName(candidate);
      if (name !== null && postgresDnsNameMatchesHost(name, host)) return true;
    }
    return false;
  }
  const commonNames = certificate.subjectCommonNames();
  return commonNames.length > 0 &&
    postgresDnsNameMatchesHost(commonNames[0], host);
}
function subjectAlternativeNames(certificate: PostgresPeerCertificate):
PostgresSubjectAlternativeNames | null {
  if (!postgresCertificateHasSubjectAlternativeName(
    certificate.certificateDer())) return null;
  return postgresParseSubjectAlternativeNamesEntry(
    certificate.subjectAlternativeNameExtension());
}
function asciiDnsName(data: Uint8Array): string | null {
  let result = '';
  for (let index = 0; index < data.length; index += 1) {
    const value = data[index];
    if (value > 0x7f) return null;
    result += String.fromCharCode(value);
  }
  return result;
}
export function postgresDnsNameMatchesHost(certificateName: string,
  host: string): boolean {
  const pattern = normalizedCertificateDnsName(certificateName);
  const target = normalizedReferenceDnsName(host);
  if (pattern === null || target === null) return false;
  if (!pattern.startsWith('*.')) return pattern === target;
  const patternLabels = pattern.split('.');
  const targetLabels = target.split('.');
  if (patternLabels.length !== targetLabels.length) return false;
  for (let index = 1; index < patternLabels.length; index += 1) {
    if (patternLabels[index] !== targetLabels[index]) return false;
  }
  return true;
}
function normalizedCertificateDnsName(value: string): string | null {
  const normalized = asciiLowercase(value);
  if (normalized === null) return null;
  return validDnsName(normalized, true) ? normalized : null;
}
function normalizedReferenceDnsName(value: string): string | null {
  let normalized = asciiLowercase(value);
  if (normalized === null) return null;
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return validDnsName(normalized, false) ? normalized : null;
}
function asciiLowercase(value: string): string | null {
  let result = '';
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code > 0x7f) return null;
    result += String.fromCharCode(
      code >= 65 && code <= 90 ? code + 32 : code);
  }
  return result;
}
function validDnsName(value: string, wildcardAllowed: boolean): boolean {
  if (value.length < 1 || value.length > 253 ||
    value.startsWith('.') || value.endsWith('.') ||
    value.indexOf('..') >= 0) return false;
  const labels = value.split('.');
  for (let index = 0; index < labels.length; index += 1) {
    const label = labels[index];
    if (wildcardAllowed && index === 0 && label === '*') {
      if (labels.length < 3) return false;
      continue;
    }
    if (label.length < 1 || label.length > 63 ||
      label.startsWith('-') || label.endsWith('-')) return false;
    for (let position = 0; position < label.length; position += 1) {
      const code = label.charCodeAt(position);
      const digit = code >= 48 && code <= 57;
      const letter = code >= 97 && code <= 122;
      if (!digit && !letter && code !== 45) return false;
    }
  }
  return true;
}
export function postgresIpAddressBytes(host: string): Uint8Array | null {
  if (host.startsWith('[') || host.endsWith(']')) return null;
  if (host.indexOf(':') >= 0) return ipv6Bytes(host);
  return ipv4Bytes(host);
}
function ipv4Bytes(value: string): Uint8Array | null {
  const parts = value.split('.');
  if (parts.length !== 4) return null;
  const result = new Uint8Array(4);
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part.length < 1 || (part.length > 1 && part.startsWith('0')) ||
      !decimalDigits(part)) return null;
    const parsed = Number(part);
    if (parsed > 255) return null;
    result[index] = parsed;
  }
  return result;
}
function ipv6Bytes(value: string): Uint8Array | null {
  if (value.length < 2 || value.indexOf('%') >= 0 ||
    value.indexOf('::') !== value.lastIndexOf('::')) return null;
  const compressedAt = value.indexOf('::');
  const left = ipv6Groups(
    compressedAt < 0 ? value : value.substring(0, compressedAt),
    compressedAt < 0);
  const right = ipv6Groups(
    compressedAt < 0 ? '' : value.substring(compressedAt + 2), true);
  if (left === null || right === null) return null;
  const missing = 8 - left.length - right.length;
  if ((compressedAt < 0 && missing !== 0) ||
    (compressedAt >= 0 && missing < 1)) return null;
  const groups = left.slice();
  for (let index = 0; index < missing; index += 1) groups.push(0);
  for (const group of right) groups.push(group);
  const result = new Uint8Array(16);
  for (let index = 0; index < groups.length; index += 1) {
    result[index * 2] = (groups[index] >>> 8) & 0xff;
    result[index * 2 + 1] = groups[index] & 0xff;
  }
  return result;
}
function ipv6Groups(value: string,
  embeddedIpv4Allowed: boolean): number[] | null {
  if (value.length === 0) return [];
  const groups: number[] = [];
  const parts = value.split(':');
  for (let index = 0; index < parts.length; index += 1) {
    const part = parts[index];
    if (part.length < 1) return null;
    if (part.indexOf('.') >= 0) {
      if (!embeddedIpv4Allowed || index !== parts.length - 1) return null;
      const address = ipv4Bytes(part);
      if (address === null) return null;
      groups.push((address[0] << 8) | address[1]);
      groups.push((address[2] << 8) | address[3]);
    } else {
      if (part.length > 4 || !hexDigits(part)) return null;
      groups.push(parseInt(part, 16));
    }
  }
  return groups;
}
function decimalDigits(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    if (code < 48 || code > 57) return false;
  }
  return true;
}
function hexDigits(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const code = value.charCodeAt(index);
    const digit = code >= 48 && code <= 57;
    const lower = code >= 97 && code <= 102;
    const upper = code >= 65 && code <= 70;
    if (!digit && !lower && !upper) return false;
  }
  return true;
}
function looksLikeIpLiteral(value: string): boolean {
  let normalized = value;
  if (normalized.endsWith('.')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.startsWith('[') || normalized.endsWith(']') ||
    normalized.indexOf(':') >= 0) return true;
  const parts = normalized.split('.');
  if (parts.length < 1 || parts.length > 4) return false;
  for (const part of parts) {
    if (!legacyIpv4Number(part)) return false;
  }
  return true;
}
function legacyIpv4Number(value: string): boolean {
  let start = 0;
  if (value.startsWith('+') || value.startsWith('-')) start = 1;
  if (start >= value.length) return false;
  if (value.length - start > 2 && value[start] === '0' &&
    (value[start + 1] === 'x' || value[start + 1] === 'X')) {
    return hexDigits(value.substring(start + 2));
  }
  return decimalDigits(value.substring(start));
}
function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let index = 0; index < left.length; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
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
