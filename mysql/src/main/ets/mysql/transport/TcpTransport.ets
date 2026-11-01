import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
import { cert } from '@kit.DeviceCertificateKit';
import { util } from '@kit.ArkTS';
import { ArkDbError, Logger, LogTag, ConnectionTimerPort, SystemConnectionTimerPort } from '@arkdb/core';
import { SslConfig, SslMode } from '../model/ConnectionConfig';

export const MAX_RECEIVE_BUFFER_BYTES: number = 32 * 1024 * 1024;
const RECEIVE_BLOCK_BYTES: number = 64 * 1024;
const SOCKET_CLOSE_TIMEOUT_MS: number = 1000;

interface PendingRead {
  need: number;
  timeoutId: number;
  resolve: (value: Uint8Array | PromiseLike<Uint8Array>) => void;
  reject: (reason?: Object) => void;
}

export interface TcpByteSender {
  send(data: Uint8Array): Promise<void>;
}

export interface PacketByteTransport {
  read(length: number, timeoutMs?: number): Promise<Uint8Array>;
  write(data: Uint8Array, timeoutMs?: number): Promise<void>;
  runWhileOpen?<T>(operation: () => Promise<T>): Promise<T>;
}

/**
 * Bounded TCP/TLS byte-stream. The framing layer pulls exact-length reads; a stalled
 * reader fails closed rather than retaining unlimited socket deliveries.
 */
export class TcpTransport implements PacketByteTransport {
  private tcp: socket.TCPSocket | null = null;
  private tls: socket.TLSSocket | null = null;
  private rxChunks: Uint8Array[] = [];
  private rxLength: number = 0;
  private rxHeadOffset: number = 0;
  private rxTailLength: number = 0;
  private pending: PendingRead | null = null;
  private fatal: ArkDbError | null = null;
  private sender: TcpByteSender | null;
  private tlsPrepared: boolean = false;
  private maximumReceiveBytes: number;
  private closeTask: Promise<void> | null = null;
  private closeFailure: ArkDbError | null = null;
  private operationFailures: Array<(error: ArkDbError) => void> = [];
  private timers: ConnectionTimerPort;

  constructor(sender: TcpByteSender | null = null,
    maximumReceiveBytes: number = MAX_RECEIVE_BUFFER_BYTES,
    timers: ConnectionTimerPort = new SystemConnectionTimerPort()) {
    if (!Number.isSafeInteger(maximumReceiveBytes) ||
      maximumReceiveBytes <= 0 || maximumReceiveBytes > MAX_RECEIVE_BUFFER_BYTES) {
      throw ArkDbError.validation('Receive buffer limit must be an integer between 1 and 33554432');
    }
    this.sender = sender;
    this.maximumReceiveBytes = maximumReceiveBytes;
    this.timers = timers;
  }

  async connect(host: string, port: number, timeoutMs: number): Promise<void> {
    if (this.fatal !== null) throw this.fatal;
    if (this.tcp !== null || this.tls !== null) {
      throw ArkDbError.protocol('Transport is already connected');
    }
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (info: socket.SocketMessageInfo): void => {
      if (this.tcp === tcp && !this.tlsPrepared) this.onData(new Uint8Array(info.message));
    });
    tcp.on('close', (): void => {
      if (this.tcp === tcp) this.onClose();
    });
    tcp.on('error', (err: BusinessError): void => {
      if (this.tcp === tcp) this.onError(err);
    });
    const address: socket.NetAddress = { address: host, port: port };
    const options: socket.TCPConnectOptions = { address: address, timeout: timeoutMs };
    try {
      await this.runWhileOpen((): Promise<void> => tcp.connect(options));
      this.throwIfFailed();
      Logger.d(LogTag.Net, 'tcp connected host=' + Logger.mask(host) + ' port=' + port);
    } catch (e) {
      Logger.w(LogTag.Net, 'tcp connect failed host=' + Logger.mask(host) +
        ' port=' + port + ' error=' + Logger.errorToken(e));
      this.fail(ArkDbError.network('TCP connect to ' + host + ':' + port + ' failed: ' + asMessage(e)));
      await this.closeTask;
      throw this.fatal!;
    }
  }

  /** Stop plaintext reads before the SSL Request can make the server emit TLS bytes. */
  prepareTlsUpgrade(): void {
    this.throwIfFailed();
    const tcp = this.tcp;
    if (tcp === null) throw ArkDbError.tls('Cannot start TLS: socket is not connected');
    if (this.pending !== null || this.rxLength !== 0) {
      throw ArkDbError.protocol('Cannot start TLS while plaintext data is pending');
    }
    this.tlsPrepared = true;
    tcp.off('message');
    // constructTLSSocketInstance() transfers the FD and removes the remaining TCP listeners.
  }

  /** Upgrade the connected TCP stream in place after MySQL's SSL Request packet. */
  async upgradeToTls(host: string, port: number, config: SslConfig, timeoutMs: number): Promise<void> {
    if (this.fatal !== null) throw this.fatal;
    const tcp = this.tcp;
    if (tcp === null) throw ArkDbError.tls('Cannot start TLS: socket is not connected');
    if (!this.tlsPrepared) throw ArkDbError.protocol('TLS upgrade was not prepared');
    this.tlsPrepared = false;
    let tls: socket.TLSSocket;
    try {
      tls = socket.constructTLSSocketInstance(tcp);
    } catch (e) {
      this.fail(ArkDbError.tls('Could not create TLS socket: ' + asMessage(e)));
      await this.closeTask;
      throw this.fatal!;
    }
    this.tls = tls;
    this.tcp = null;
    tls.on('message', (info: socket.SocketMessageInfo): void => {
      if (this.tls === tls) this.onData(new Uint8Array(info.message));
    });
    tls.on('close', (): void => {
      if (this.tls === tls) this.onClose();
    });
    tls.on('error', (err: BusinessError): void => {
      if (this.tls === tls) this.onTlsError(err);
    });

    try {
      await this.runWhileOpen((): Promise<void> =>
        tls.connect(buildTlsConnectOptions(host, port, config, timeoutMs)));
      if (config.mode === SslMode.VERIFY_IDENTITY) {
        await this.runWhileOpen((): Promise<void> => verifyTlsIdentity(tls, host));
      }
      this.throwIfFailed();
      Logger.i(LogTag.Net, 'tls connected host=' + Logger.mask(host) + ' port=' + port);
    } catch (e) {
      const error = e instanceof ArkDbError ? e :
        ArkDbError.tls('TLS connect to ' + host + ':' + port + ' failed: ' + asMessage(e));
      this.fail(error);
      await this.closeTask;
      throw this.fatal!;
    }
  }

  /** Resolve exactly n bytes (waiting for inbound data as needed). */
  read(n: number, timeoutMs: number = 0): Promise<Uint8Array> {
    return new Promise<Uint8Array>(
      (resolve: (value: Uint8Array | PromiseLike<Uint8Array>) => void, reject: (reason?: Object) => void): void => {
        if (this.fatal !== null) {
          reject(this.fatal);
          return;
        }
        if (!Number.isSafeInteger(n) || n < 0 || n > this.maximumReceiveBytes) {
          reject(ArkDbError.validation('Read length must fit the transport receive buffer limit'));
          return;
        }
        if (this.pending !== null) {
          reject(ArkDbError.protocol('Concurrent transport reads are not supported'));
          return;
        }
        const pending: PendingRead = { need: n, timeoutId: 0, resolve: resolve, reject: reject };
        this.pending = pending;
        if (timeoutMs > 0) {
          pending.timeoutId = this.timers.schedule((): void => {
            if (this.pending !== pending) return;
            this.fail(ArkDbError.protocol(
              'Truncated result exceeded synchronization drain time budget'));
          }, timeoutMs);
        }
        this.tryResolve();
      });
  }

  async write(data: Uint8Array, timeoutMs: number = 0): Promise<void> {
    if (this.fatal !== null) throw this.fatal;
    const ab = new ArrayBuffer(data.length);
    new Uint8Array(ab).set(data);
    const isTls = this.sender === null && this.tls !== null;
    try {
      await this.awaitWrite((): Promise<void> => {
        if (this.sender !== null) return this.sender.send(new Uint8Array(ab));
        const tls = this.tls;
        if (tls !== null) return tls.send(ab);
        const tcp = this.tcp;
        if (tcp === null) throw ArkDbError.network('Cannot write: socket is not connected');
        const options: socket.TCPSendOptions = { data: ab };
        return tcp.send(options);
      }, timeoutMs);
      this.throwIfFailed();
    } catch (e) {
      const error = e instanceof ArkDbError ? e : (isTls ?
        ArkDbError.tls('TLS send failed: ' + asMessage(e)) :
        ArkDbError.network('TCP send failed: ' + asMessage(e)));
      this.fail(error);
      await this.closeTask;
      throw this.fatal!;
    }
  }

  private awaitWrite(operation: () => Promise<void>, timeoutMs: number): Promise<void> {
    const pending = this.runWhileOpen(operation);
    if (timeoutMs <= 0) return pending;
    return new Promise<void>((resolve: () => void,
      reject: (reason?: Object) => void): void => {
      let settled = false;
      const timeoutId = this.timers.schedule((): void => {
        if (settled) return;
        const error = ArkDbError.protocol(
          'Truncated result exceeded synchronization drain time budget');
        this.fail(error);
      }, timeoutMs);
      pending.then(
        (): void => {
          if (settled) return;
          settled = true;
          this.timers.cancel(timeoutId);
          resolve();
        },
        (error: Object): void => {
          if (settled) return;
          settled = true;
          this.timers.cancel(timeoutId);
          reject(error);
        }
      );
    });
  }

  /** Dispose each terminal subscription when its individual operation settles. */
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

  private removeOperationFailure(listener: (error: ArkDbError) => void): void {
    const index = this.operationFailures.indexOf(listener);
    if (index >= 0) this.operationFailures.splice(index, 1);
  }

  private throwIfFailed(): void {
    if (this.fatal !== null) throw this.fatal;
  }

  async close(): Promise<void> {
    await this.abort(ArkDbError.network('Connection closed'));
  }

  async abort(error: ArkDbError): Promise<void> {
    this.fail(error);
    await this.closeTask;
    if (this.closeFailure !== null) throw this.closeFailure;
  }

  private fail(error: ArkDbError, alreadyClosed: boolean = false): void {
    if (this.fatal !== null) return;
    this.fatal = error;
    this.rxChunks = [];
    this.rxLength = 0;
    this.rxHeadOffset = 0;
    this.rxTailLength = 0;
    this.failPending();
    const operations = this.operationFailures;
    this.operationFailures = [];
    for (const reject of operations) reject(error);
    const tls = this.tls;
    const tcp = this.tcp;
    this.tls = null;
    this.tcp = null;
    this.tlsPrepared = false;
    const active = tls !== null ? tls : tcp;
    if (active !== null) {
      this.closeTask = this.releaseSocket(active, alreadyClosed);
    }
  }

  private async releaseSocket(active: socket.TCPSocket | socket.TLSSocket,
    alreadyClosed: boolean): Promise<void> {
    try {
      active.off('message');
      active.off('close');
      active.off('error');
    } catch (error) {
      Logger.w(LogTag.Net, 'socket listener cleanup error=' + Logger.errorToken(error));
    }
    if (alreadyClosed) return;
    await new Promise<void>((resolve: () => void): void => {
      let settled = false;
      let timeoutId = 0;
      const finish = (error: ArkDbError | null): void => {
        if (settled) return;
        settled = true;
        this.timers.cancel(timeoutId);
        this.closeFailure = error;
        resolve();
      };
      const failed = (error: Object): void => {
        if (settled) return;
        Logger.w(LogTag.Net, 'socket close error=' + Logger.errorToken(error));
        finish(ArkDbError.network('Socket close failed'));
      };
      timeoutId = this.timers.schedule((): void => {
        if (settled) return;
        Logger.w(LogTag.Net, 'socket close timed out');
        finish(ArkDbError.network('Socket close timed out'));
      }, SOCKET_CLOSE_TIMEOUT_MS);
      try {
        active.close().then((): void => finish(null), failed);
      } catch (error) {
        failed(error as Object);
      }
    });
  }

  private onData(chunk: Uint8Array): void {
    if (this.fatal !== null || chunk.length === 0) {
      return;
    }
    if (chunk.length > this.maximumReceiveBytes - this.rxLength) {
      Logger.w(LogTag.Net, 'receive buffer limit buffered=' + this.rxLength +
        ' incoming=' + chunk.length + ' maximum=' + this.maximumReceiveBytes);
      this.fail(ArkDbError.protocol('Transport receive buffer exceeds client limit'));
      return;
    }
    let offset = 0;
    while (offset < chunk.length) {
      if (this.rxChunks.length === 0 ||
        this.rxTailLength === this.rxChunks[this.rxChunks.length - 1].length) {
        this.rxChunks.push(new Uint8Array(Math.min(RECEIVE_BLOCK_BYTES, this.maximumReceiveBytes)));
        this.rxTailLength = 0;
      }
      const tail = this.rxChunks[this.rxChunks.length - 1];
      const length = Math.min(tail.length - this.rxTailLength, chunk.length - offset);
      tail.set(chunk.subarray(offset, offset + length), this.rxTailLength);
      this.rxTailLength += length;
      offset += length;
    }
    this.rxLength += chunk.length;
    this.tryResolve();
  }

  private onClose(): void {
    Logger.d(LogTag.Net, 'socket closed');
    this.fail(ArkDbError.network('Connection closed by server'), true);
  }

  private onError(err: BusinessError): void {
    Logger.w(LogTag.Net, 'socket error=' + Logger.errorToken(err));
    this.fail(ArkDbError.network('Socket error: ' + asMessage(err)));
  }

  private onTlsError(err: BusinessError): void {
    Logger.w(LogTag.Net, 'tls socket error=' + Logger.errorToken(err));
    this.fail(ArkDbError.tls('TLS socket error: ' + asMessage(err)));
  }

  private failPending(): void {
    const p = this.pending;
    if (p !== null && this.fatal !== null) {
      this.pending = null;
      this.clearPendingTimer(p);
      p.reject(this.fatal);
    }
  }

  private tryResolve(): void {
    const p = this.pending;
    if (p === null) {
      return;
    }
    if (this.fatal !== null) {
      this.pending = null;
      this.clearPendingTimer(p);
      p.reject(this.fatal);
      return;
    }
    if (this.rxLength < p.need) {
      return;
    }
    const out = this.take(p.need);
    this.pending = null;
    this.clearPendingTimer(p);
    p.resolve(out);
  }

  private clearPendingTimer(pending: PendingRead): void {
    if (pending.timeoutId !== 0) {
      this.timers.cancel(pending.timeoutId);
      pending.timeoutId = 0;
    }
  }

  private take(n: number): Uint8Array {
    const out = new Uint8Array(n);
    let off = 0;
    while (off < n) {
      const head = this.rxChunks[0];
      const end = this.rxChunks.length === 1 ? this.rxTailLength : head.length;
      const length = Math.min(end - this.rxHeadOffset, n - off);
      out.set(head.subarray(this.rxHeadOffset, this.rxHeadOffset + length), off);
      this.rxHeadOffset += length;
      off += length;
      if (this.rxHeadOffset === end) {
        this.rxChunks.shift();
        this.rxHeadOffset = 0;
        if (this.rxChunks.length === 0) this.rxTailLength = 0;
      }
    }
    this.rxLength -= n;
    return out;
  }
}

function buildTlsConnectOptions(host: string, port: number,
  config: SslConfig, timeoutMs: number): socket.TLSConnectOptions {
  const secureOptions: socket.TLSSecureOptions = {};
  if (config.mode === SslMode.VERIFY_CA || config.mode === SslMode.VERIFY_IDENTITY) {
    const caPath = configuredPath(config.caCertPath);
    if (caPath.length > 0) secureOptions.ca = readTlsFile(caPath, 'CA certificate');
  }

  const certPath = configuredPath(config.clientCertPath);
  const keyPath = configuredPath(config.clientKeyPath);
  if ((certPath.length > 0) !== (keyPath.length > 0)) {
    throw ArkDbError.tls('Client certificate and private key must be configured together');
  }
  if (certPath.length > 0) {
    secureOptions.cert = readTlsFile(certPath, 'client certificate');
    secureOptions.key = readTlsFile(keyPath, 'client private key');
    secureOptions.isBidirectionalAuthentication = true;
  }

  const protocols = tlsProtocols(config.tlsVersions);
  if (protocols.length > 0) secureOptions.protocols = protocols;
  if (config.cipherSuites !== undefined && config.cipherSuites.trim().length > 0) {
    secureOptions.cipherSuite = config.cipherSuites.trim();
  }

  const address: socket.NetAddress = { address: host, port: port };
  return {
    address: address,
    secureOptions: secureOptions,
    skipRemoteValidation: config.mode === SslMode.PREFERRED || config.mode === SslMode.REQUIRED,
    timeout: timeoutMs
  };
}

function configuredPath(path: string | undefined): string {
  return path !== undefined ? path.trim() : '';
}

function readTlsFile(path: string, label: string): string {
  try {
    const file = fileIo.openSync(path, fileIo.OpenMode.READ_ONLY);
    try {
      const size = fileIo.statSync(file.fd).size;
      if (!Number.isSafeInteger(size) || size < 1 || size > 1024 * 1024) {
        throw new Error(label + ' file must be between 1 byte and 1 MiB');
      }
      const buffer = new ArrayBuffer(size);
      const read = fileIo.readSync(file.fd, buffer, { offset: 0, length: size });
      if (read !== size) throw new Error(label + ' file could not be read completely');
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer));
    } finally {
      fileIo.closeSync(file);
    }
  } catch (e) {
    throw ArkDbError.tls('Could not read ' + label + ' file: ' + asMessage(e));
  }
}

function tlsProtocols(versions: string[] | undefined): Array<socket.Protocol> {
  const protocols: Array<socket.Protocol> = [];
  if (versions === undefined) return protocols;
  for (const version of versions) {
    const value = version.trim();
    if (value.length === 0) continue;
    if (value === 'TLSv1.2') {
      protocols.push(socket.Protocol.TLSv12);
    } else if (value === 'TLSv1.3') {
      protocols.push(socket.Protocol.TLSv13);
    } else {
      throw ArkDbError.tls('Unsupported TLS version: ' + value);
    }
  }
  return protocols;
}

async function verifyTlsIdentity(tls: socket.TLSSocket, host: string): Promise<void> {
  try {
    const certificate = await cert.createX509Cert(await tls.getRemoteCertificate());
    if (!certificateMatchesHost(certificate, host)) {
      throw ArkDbError.tls('TLS certificate does not match host ' + host, 'TLS_HOSTNAME_MISMATCH');
    }
  } catch (e) {
    if (e instanceof ArkDbError) throw e;
    throw ArkDbError.tls('Could not verify TLS server identity: ' + asMessage(e));
  }
}

function certificateMatchesHost(certificate: cert.X509Cert, host: string): boolean {
  const ip = ipAddressBytes(host);
  if (ip !== null) {
    const generalName: cert.GeneralName = {
      type: cert.GeneralNameType.GENERAL_NAME_TYPE_IP_ADDRESS,
      name: derIpGeneralName(ip)
    };
    const parameters: cert.X509CertMatchParameters = {
      subjectAlternativeNames: [generalName],
      matchAllSubjectAltNames: false
    };
    return certificate.match(parameters);
  }

  try {
    const names = certificate.getSubjectAltNames().data;
    for (const encoded of names) {
      if (dnsNameMatchesHost(dnsNameFromSan(encoded), host)) return true;
    }
    return false;
  } catch (e) {
    const commonNames = certificate.getSubjectX500DistinguishedName().getName('CN');
    for (const commonName of commonNames) {
      if (dnsNameMatchesHost(commonName, host)) return true;
    }
    return false;
  }
}

export function dnsNameMatchesHost(certificateName: string, host: string): boolean {
  const pattern = normalizedDnsName(certificateName);
  const target = normalizedDnsName(host);
  if (pattern.length === 0 || target.length === 0) return false;
  const wildcard = pattern.startsWith('*.');
  if (!wildcard) return pattern.indexOf('*') < 0 && pattern === target;
  if (pattern.indexOf('*', 1) >= 0) return false;
  return target.endsWith(pattern.substring(1)) &&
    target.split('.').length === pattern.split('.').length;
}

function normalizedDnsName(value: string): string {
  let normalized = value.trim().toLowerCase();
  while (normalized.endsWith('.')) normalized = normalized.substring(0, normalized.length - 1);
  return normalized;
}

export function dnsNameFromSan(data: Uint8Array): string {
  let offset = 0;
  let length = data.length;
  if (data.length >= 2 && data[0] === 0x82) {
    if (data[1] < 0x80) {
      offset = 2;
      length = data[1];
    } else if (data[1] === 0x81 && data.length >= 3) {
      offset = 3;
      length = data[2];
    } else {
      return '';
    }
    if (offset + length > data.length) return '';
  }
  let result = '';
  for (let index = offset; index < offset + length; index++) {
    const value = data[index];
    if (value === 0) break;
    if (value < 0x20 || value > 0x7e) return '';
    result += String.fromCharCode(value);
  }
  return result;
}

function derIpGeneralName(address: Uint8Array): Uint8Array {
  const encoded = new Uint8Array(address.length + 2);
  encoded[0] = 0x87;
  encoded[1] = address.length;
  encoded.set(address, 2);
  return encoded;
}

export function ipAddressBytes(host: string): Uint8Array | null {
  let value = host.trim();
  if (value.startsWith('[') && value.endsWith(']')) {
    value = value.substring(1, value.length - 1);
  }
  if (value.indexOf(':') >= 0) return ipv6Bytes(value);
  return ipv4Bytes(value);
}

function ipv4Bytes(value: string): Uint8Array | null {
  const parts = value.split('.');
  if (parts.length !== 4) return null;
  const out = new Uint8Array(4);
  for (let index = 0; index < parts.length; index++) {
    if (parts[index].length === 0) return null;
    const part = Number(parts[index]);
    if (!Number.isInteger(part) || part < 0 || part > 255) return null;
    out[index] = part;
  }
  return out;
}

function ipv6Bytes(value: string): Uint8Array | null {
  if (value.indexOf('%') >= 0 || value.indexOf('::') !== value.lastIndexOf('::')) return null;
  const compressedAt = value.indexOf('::');
  const leftText = compressedAt >= 0 ? value.substring(0, compressedAt) : value;
  const rightText = compressedAt >= 0 ? value.substring(compressedAt + 2) : '';
  const left = ipv6Groups(leftText);
  const right = ipv6Groups(rightText);
  if (left === null || right === null) return null;
  const missing = 8 - left.length - right.length;
  if ((compressedAt < 0 && missing !== 0) || (compressedAt >= 0 && missing < 1)) return null;
  const groups: number[] = left.slice();
  for (let index = 0; index < missing; index++) groups.push(0);
  for (const group of right) groups.push(group);
  if (groups.length !== 8) return null;
  const out = new Uint8Array(16);
  for (let index = 0; index < groups.length; index++) {
    out[index * 2] = (groups[index] >>> 8) & 0xff;
    out[index * 2 + 1] = groups[index] & 0xff;
  }
  return out;
}

function ipv6Groups(value: string): number[] | null {
  const groups: number[] = [];
  if (value.length === 0) return groups;
  const parts = value.split(':');
  for (let index = 0; index < parts.length; index++) {
    const part = parts[index];
    if (part.length === 0) return null;
    if (part.indexOf('.') >= 0) {
      if (index !== parts.length - 1) return null;
      const ipv4 = ipv4Bytes(part);
      if (ipv4 === null) return null;
      groups.push((ipv4[0] << 8) | ipv4[1]);
      groups.push((ipv4[2] << 8) | ipv4[3]);
      continue;
    }
    if (part.length > 4 || !isHex(part)) return null;
    groups.push(parseInt(part, 16));
  }
  return groups;
}

function isHex(value: string): boolean {
  for (let index = 0; index < value.length; index++) {
    const code = value.charCodeAt(index);
    const digit = code >= 48 && code <= 57;
    const lower = code >= 97 && code <= 102;
    const upper = code >= 65 && code <= 70;
    if (!digit && !lower && !upper) return false;
  }
  return true;
}

function asMessage(e: Object): string {
  const be = e as BusinessError;
  if (be !== null && be !== undefined && be.message !== undefined) {
    return be.message;
  }
  return String(e);
}
