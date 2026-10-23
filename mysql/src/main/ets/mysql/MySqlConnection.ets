import { ConnectionConfig, SslMode } from '../core/model/ConnectionConfig';
import { DatabaseContext } from '../core/model/DatabaseContext';
import { ConnectionState, ServerInfo } from '../core/model/ServerInfo';
import { QueryResult } from '../core/model/QueryResult';
import { DatabaseSessionStatus, QueryExecutionSummary, QueryOptions, QueryResultSink } from '../core/model/QueryStream';
import { ArkDbError, ArkDbErrorKind } from '../core/model/ArkDbError';
import { DbConnection } from '../core/connection/DbConnection';
import { ConnectionDeadline, ConnectionTimerPort, SystemConnectionTimerPort,
  connectionCleanupError } from '../core/connection/ConnectionDeadline';
import { TcpTransport } from '../core/transport/TcpTransport';
import { PacketChannel, MysqlPacket } from './protocol/PacketChannel';
import { PacketWriter } from './protocol/PacketWriter';
import { Capabilities, Command, PacketType } from './protocol/Constants';
import { parseHandshake, HandshakePacket } from './auth/Handshake';
import { nativeScramble } from './auth/NativePassword';
import { cachingSha2Scramble, obfuscatePassword } from './auth/CachingSha2';
import { rsaOaepEncrypt } from './auth/Crypto';
import { buildHandshakeResponse, buildSslRequest, computeClientCapabilities,
  HandshakeResponseParams } from './auth/HandshakeResponse';
import { parseErr, parseOk } from './command/ResultPackets';
import { buildComQuery, parseQueryStream, parseResultSet, validateQueryOptions } from './command/Query';
import { Logger } from '../core/diagnostics/Logger';
import { LogTag } from '../core/diagnostics/LogSink';
import { monotonicNowMs } from '../core/time/MonotonicClock';

/**
 * A single MySQL/MariaDB connection over TCP with an optional in-handshake TLS upgrade.
 * Orchestrates: connect → handshake → mysql_native_password auth → commands.
 * Not thread-safe — run one per Worker connection, requests strictly serialized.
 */
export class MySqlConnection implements DbConnection {
  private config: ConnectionConfig;
  private password: string;
  private transport: TcpTransport;
  private timers: ConnectionTimerPort;
  private opening: ConnectionDeadline | null = null;
  private closing: Promise<void> | null = null;
  private channel: PacketChannel | null = null;
  private clientCaps: number = 0;
  private authNonce: Uint8Array = new Uint8Array(0);
  private tlsActive: boolean = false;
  private connState: ConnectionState = ConnectionState.Idle;
  private info: ServerInfo = new ServerInfo();
  private status: DatabaseSessionStatus = new DatabaseSessionStatus();

  constructor(config: ConnectionConfig, password: string, transport: TcpTransport = new TcpTransport(),
    timers: ConnectionTimerPort = new SystemConnectionTimerPort()) {
    this.config = config.clone();
    this.password = password;
    this.transport = transport;
    this.timers = timers;
  }

  get state(): ConnectionState {
    return this.connState;
  }

  get serverInfo(): ServerInfo {
    return this.info;
  }

  get sessionStatus(): DatabaseSessionStatus {
    return this.status.clone();
  }

  /** Connect, read the handshake, and authenticate. */
  async connect(): Promise<void> {
    if (this.connState !== ConnectionState.Idle && this.connState !== ConnectionState.Closed) {
      throw ArkDbError.protocol('connect() called in state ' + this.connState);
    }
    const deadline = new ConnectionDeadline(this.config.connectTimeoutMs, this.timers);
    this.opening = deadline;
    try {
      this.connState = ConnectionState.Connecting;
      this.tlsActive = false;
      Logger.i(LogTag.Conn, 'connecting host=' + Logger.mask(this.config.host) + ' port=' + this.config.port);
      await deadline.wait((): Promise<void> =>
        this.transport.connect(this.config.host, this.config.port, deadline.remainingMs()));
      deadline.remainingMs();
      const channel = new PacketChannel(this.transport);
      this.channel = channel;

      const handshakePkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
      deadline.remainingMs();
      if (firstByte(handshakePkt.payload) === PacketType.ERR) {
        const err = parseErr(handshakePkt.payload, 0);
        throw ArkDbError.server(err.message, err.code, err.sqlState);
      }
      const handshake = parseHandshake(handshakePkt.payload);
      this.applyServerInfo(handshake);
      this.authNonce = handshake.salt;
      Logger.i(LogTag.Conn, 'handshake family=' + String(handshake.family) +
        ' plugin=' + authPluginLogValue(handshake.authPluginName));

      const withDb = this.config.defaultSchema !== undefined && this.config.defaultSchema.length > 0;
      const withTls = mysqlTlsRequested(this.config.ssl.mode, handshake.capabilities);
      this.clientCaps = computeClientCapabilities(handshake.capabilities, withDb, withTls);

      this.connState = ConnectionState.Authenticating;
      const params = new HandshakeResponseParams();
      params.capabilities = this.clientCaps;
      params.user = this.config.user;
      params.authPluginName = handshake.authPluginName;
      if (withDb) {
        params.database = this.config.defaultSchema;
      }
      if (withTls) {
        this.transport.prepareTlsUpgrade();
        await deadline.wait((): Promise<void> => channel.writePacket(buildSslRequest(
          params.capabilities, params.charset, params.maxPacketSize)));
        await deadline.wait((): Promise<void> => this.transport.upgradeToTls(
          this.config.host, this.config.port, this.config.ssl, deadline.remainingMs()));
        deadline.remainingMs();
        this.tlsActive = true;
        this.info.tlsActive = true;
      }
      params.authResponse = await deadline.wait((): Promise<Uint8Array> =>
        this.computeAuth(handshake.authPluginName, handshake.salt));
      await deadline.wait((): Promise<void> => channel.writePacket(buildHandshakeResponse(params)));

      const authStatusFlags = await this.readAuthResult(channel, deadline);
      deadline.remainingMs();
      this.applyStatusFlags(authStatusFlags);
      if (this.status.autocommit !== this.config.autocommit) {
        channel.resetSequence();
        await deadline.wait((): Promise<void> => channel.writePacket(buildComQuery(
          this.config.autocommit ? 'SET autocommit = 1' : 'SET autocommit = 0')));
        const setup = await deadline.wait((): Promise<QueryResult> =>
          parseResultSet(channel, this.clientCaps));
        deadline.remainingMs();
        this.status.autocommit = setup.autocommit;
        this.status.inTransaction = setup.inTransaction;
      }
      deadline.remainingMs();
      this.connState = ConnectionState.Ready;
      Logger.i(LogTag.Conn, 'ready host=' + Logger.mask(this.config.host) + ' user=' + Logger.mask(this.config.user));
    } catch (e) {
      if (this.connState !== ConnectionState.Closed) this.connState = ConnectionState.Error;
      const oe = toArkDbError(e);
      deadline.cancel(oe);
      Logger.e(LogTag.Conn, 'connect failed host=' + Logger.mask(this.config.host) +
        ' kind=' + String(oe.kind) + ' error=' + Logger.errorToken(oe));
      this.channel = null;
      try {
        await this.transport.abort(oe);
      } catch (cleanup) {
        Logger.w(LogTag.Conn, 'connect cleanup failed error=' + Logger.errorToken(cleanup));
        throw connectionCleanupError(oe);
      }
      throw oe;
    } finally {
      deadline.dispose();
      if (this.opening === deadline) this.opening = null;
    }
  }

  /** Run a text SQL statement and return the (fully buffered) result. */
  async query(sql: string): Promise<QueryResult> {
    const channel = this.requireReady();
    const command = buildComQuery(sql);
    let startedAtMs: number = 0;
    this.connState = ConnectionState.Querying;
    try {
      channel.resetSequence();
      startedAtMs = monotonicNowMs();
      await channel.writePacket(command);
      const result = await parseResultSet(channel, this.clientCaps);
      result.executionTimeMs = monotonicNowMs() - startedAtMs;
      this.status.autocommit = result.autocommit;
      this.status.inTransaction = result.inTransaction;
      this.connState = ConnectionState.Ready;
      Logger.d(LogTag.Query, 'query ok rows=' + result.rows.length + ' cols=' + result.columns.length + ' dur=' + result.executionTimeMs + 'ms');
      return result;
    } catch (e) {
      const failedAtMs = monotonicNowMs();
      const oe = await this.classifyCommandFailure(e);
      const diagnostic = queryFailureDiagnostic(oe, failedAtMs - startedAtMs);
      Logger.e(LogTag.Query, 'query failed ' + diagnostic);
      throw oe;
    }
  }

  /** Run a text SQL statement and emit bounded result chunks through an awaited sink. */
  async queryStream(sql: string, options: QueryOptions, sink: QueryResultSink): Promise<QueryExecutionSummary> {
    const channel = this.requireReady();
    const executionOptions = options.clone();
    validateQueryOptions(executionOptions);
    const command = buildComQuery(sql);
    let startedAtMs: number = 0;
    this.connState = ConnectionState.Querying;
    try {
      channel.resetSequence();
      startedAtMs = monotonicNowMs();
      await channel.writePacket(command);
      const summary = await parseQueryStream(channel, this.clientCaps,
        executionOptions, sink, this.status);
      if (!summary.statusKnown) {
        try {
          await this.refreshSessionStatus(channel, summary.synchronizationDeadlineMs);
        } catch (error) {
          throw synchronizationRefreshFailure(error as Object);
        }
        summary.status = this.status.clone();
        summary.statusKnown = true;
      }
      this.status = summary.status.clone();
      this.connState = ConnectionState.Ready;
      Logger.d(LogTag.Query, 'query stream ok results=' + summary.resultSetCount + ' rows=' +
        summary.loadedRowCount + '/' + summary.rowCount + ' dur=' + summary.executionTimeMs + 'ms');
      return summary;
    } catch (e) {
      const failedAtMs = monotonicNowMs();
      const error = await this.classifyCommandFailure(e);
      const diagnostic = queryFailureDiagnostic(error, failedAtMs - startedAtMs);
      Logger.e(LogTag.Query, 'query stream failed ' + diagnostic);
      throw error;
    }
  }

  /** Round-trip COM_PING. */
  async ping(): Promise<void> {
    const channel = this.requireReady();
    const w = new PacketWriter();
    w.writeUInt8(Command.PING);
    const command = w.toUint8Array();
    try {
      channel.resetSequence();
      await channel.writePacket(command);
      this.expectOk(await channel.readPacket());
    } catch (e) {
      throw await this.classifyCommandFailure(e);
    }
  }

  /** Switch the default database (COM_INIT_DB / USE). */
  async useDatabase(name: string): Promise<void> {
    const channel = this.requireReady();
    Logger.d(LogTag.Conn, 'useDatabase ' + Logger.mask(name));
    const w = new PacketWriter();
    w.writeUInt8(Command.INIT_DB);
    w.writeString(name);
    const command = w.toUint8Array();
    try {
      channel.resetSequence();
      await channel.writePacket(command);
      this.expectOk(await channel.readPacket());
    } catch (e) {
      throw await this.classifyCommandFailure(e);
    }
  }

  async changeContext(context: DatabaseContext): Promise<void> {
    const database = context.schema.length > 0 ? context.schema : context.catalog;
    if (database.length === 0) {
      throw ArkDbError.validation('A database name is required');
    }
    await this.useDatabase(database);
  }

  async setAutocommit(enabled: boolean): Promise<DatabaseSessionStatus> {
    await this.query(enabled ? 'SET autocommit = 1' : 'SET autocommit = 0');
    return this.sessionStatus;
  }

  async commit(): Promise<DatabaseSessionStatus> {
    await this.query('COMMIT');
    return this.sessionStatus;
  }

  async rollback(): Promise<DatabaseSessionStatus> {
    await this.query('ROLLBACK');
    return this.sessionStatus;
  }

  /** Politely COM_QUIT (best effort) then close the socket. */
  close(): Promise<void> {
    if (this.closing === null) this.closing = this.closeInternal();
    return this.closing;
  }

  private async closeInternal(): Promise<void> {
    const channel = this.channel;
    const polite = this.opening === null && this.connState === ConnectionState.Ready;
    this.connState = ConnectionState.Closed;
    this.channel = null;
    if (this.opening !== null) {
      this.opening.cancel(ArkDbError.cancelled('Connection closed while opening.'));
    }
    if (channel !== null && polite) {
      try {
        channel.resetSequence();
        const w = new PacketWriter();
        w.writeUInt8(Command.QUIT);
        await channel.writePacket(w.toUint8Array(), 1000);
      } catch (e) {
        Logger.w(LogTag.Conn, 'quit before close failed error=' + Logger.errorToken(e));
      }
    }
    await this.transport.close();
    Logger.d(LogTag.Conn, 'closed');
  }

  private async computeAuth(plugin: string, salt: Uint8Array): Promise<Uint8Array> {
    if (plugin === 'mysql_native_password' || plugin.length === 0) {
      Logger.d(LogTag.Auth, 'scramble plugin=mysql_native_password');
      return await nativeScramble(this.password, salt);
    }
    if (plugin === 'caching_sha2_password') {
      Logger.d(LogTag.Auth, 'scramble plugin=caching_sha2_password (fast)');
      return await cachingSha2Scramble(this.password, salt);
    }
    Logger.e(LogTag.Auth, 'unsupported auth plugin=' + authPluginLogValue(plugin));
    throw new ArkDbError(ArkDbErrorKind.Auth, 'Unsupported authentication plugin: ' + plugin);
  }

  private async readAuthResult(channel: PacketChannel, deadline: ConnectionDeadline): Promise<number> {
    const pkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
    deadline.remainingMs();
    const fb = firstByte(pkt.payload);
    if (fb === PacketType.OK) {
      return parseOk(pkt.payload, this.clientCaps).statusFlags;
    }
    if (fb === PacketType.ERR) {
      const err = parseErr(pkt.payload, this.clientCaps);
      throw ArkDbError.server(err.message, err.code, err.sqlState);
    }
    if (fb === 0xfe) {
      // AuthSwitchRequest: [0xfe][plugin NUL][salt EOF]
      const r = pkt.reader();
      r.readUInt8();
      const newPlugin = r.readNulString();
      let newSalt = r.readBytes(r.remaining);
      if (newSalt.length > 0 && newSalt[newSalt.length - 1] === 0x00) {
        newSalt = newSalt.subarray(0, newSalt.length - 1);
      }
      this.authNonce = newSalt;
      Logger.d(LogTag.Auth, 'auth-switch -> ' + authPluginLogValue(newPlugin));
      const response = await deadline.wait((): Promise<Uint8Array> => this.computeAuth(newPlugin, newSalt));
      await deadline.wait((): Promise<void> => channel.writePacket(response));
      return await this.readAuthResult(channel, deadline);
    }
    if (fb === 0x01) {
      // AuthMoreData — caching_sha2_password flow.
      const r = pkt.reader();
      r.readUInt8(); // 0x01
      const indicator = r.hasMore() ? r.peekUInt8() : -1;
      if (indicator === 0x03) {
        // fast-auth success — the OK packet follows.
        Logger.d(LogTag.Auth, 'caching_sha2 fast-auth ok');
        return await this.readAuthResult(channel, deadline);
      }
      if (indicator === 0x04) {
        // full authentication required.
        Logger.d(LogTag.Auth, 'caching_sha2 full-auth required');
        await this.cachingSha2FullAuth(channel, deadline);
        return await this.readAuthResult(channel, deadline);
      }
      throw ArkDbError.protocol('Unexpected AuthMoreData indicator 0x' + (indicator & 0xff).toString(16));
    }
    throw ArkDbError.protocol('Unexpected auth response byte 0x' + fb.toString(16));
  }

  /** caching_sha2 full auth: cleartext over TLS, else RSA-OAEP over the plaintext channel. */
  private async cachingSha2FullAuth(channel: PacketChannel, deadline: ConnectionDeadline): Promise<void> {
    if (this.tlsActive) {
      Logger.d(LogTag.Auth, 'full-auth via TLS cleartext');
      const w = new PacketWriter();
      w.writeString(this.password);
      w.writeUInt8(0x00);
      await deadline.wait((): Promise<void> => channel.writePacket(w.toUint8Array()));
      return;
    }
    Logger.d(LogTag.Auth, 'full-auth via RSA public key');
    // Plaintext: request the server RSA public key, then send OAEP(password XOR nonce).
    const request = new PacketWriter();
    request.writeUInt8(0x02); // request_public_key
    await deadline.wait((): Promise<void> => channel.writePacket(request.toUint8Array()));

    const keyPkt = await deadline.wait((): Promise<MysqlPacket> => channel.readPacket());
    const kr = keyPkt.reader();
    if (kr.readUInt8() !== 0x01) {
      throw ArkDbError.protocol('Expected AuthMoreData carrying the RSA public key');
    }
    const pem = kr.readEofString();
    const obfuscated = obfuscatePassword(this.password, this.authNonce);
    const encrypted = await deadline.wait((): Promise<Uint8Array> => rsaOaepEncrypt(pem, obfuscated));
    await deadline.wait((): Promise<void> => channel.writePacket(encrypted));
  }

  private requireReady(): PacketChannel {
    if (this.connState !== ConnectionState.Ready || this.channel === null) {
      throw ArkDbError.protocol('Connection is not ready (state ' + this.connState + ')');
    }
    return this.channel;
  }

  private expectOk(pkt: MysqlPacket): void {
    const fb = firstByte(pkt.payload);
    if (fb === PacketType.ERR) {
      const err = parseErr(pkt.payload, this.clientCaps);
      throw ArkDbError.server(err.message, err.code, err.sqlState);
    }
    if (fb !== PacketType.OK) {
      throw ArkDbError.protocol('Expected an OK packet, got 0x' + fb.toString(16));
    }
    this.applyStatusFlags(parseOk(pkt.payload, this.clientCaps).statusFlags);
  }

  private async refreshSessionStatus(channel: PacketChannel,
    synchronizationDeadlineMs: number): Promise<void> {
    if (remainingSynchronizationTimeMs(synchronizationDeadlineMs, monotonicNowMs()) <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    channel.resetSequence();
    const writer = new PacketWriter();
    writer.writeUInt8(Command.PING);
    let remaining = remainingSynchronizationTimeMs(
      synchronizationDeadlineMs, monotonicNowMs());
    if (remaining <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    await channel.writePacket(writer.toUint8Array(), remaining);
    remaining = remainingSynchronizationTimeMs(
      synchronizationDeadlineMs, monotonicNowMs());
    if (remaining <= 0) {
      throw ArkDbError.protocol('Truncated result exceeded synchronization drain time budget');
    }
    this.expectOk(await channel.readPacket(remaining));
  }

  private applyServerInfo(hp: HandshakePacket): void {
    const si = new ServerInfo();
    si.family = hp.family;
    si.driverId = 'mysql';
    si.productName = String(hp.family);
    si.connectionHandle = String(hp.connectionId);
    si.nativeCapabilities = String(hp.capabilities);
    si.defaultEncoding = String(hp.charset);
    si.version = hp.serverVersion;
    si.protocolVersion = hp.protocolVersion;
    si.connectionId = hp.connectionId;
    si.capabilities = hp.capabilities;
    si.charset = hp.charset;
    si.authPlugin = hp.authPluginName;
    si.tlsActive = this.tlsActive;
    this.info = si;
    this.applyStatusFlags(hp.statusFlags);
  }

  private applyStatusFlags(statusFlags: number): void {
    this.status.autocommit = (statusFlags & 0x0002) !== 0;
    this.status.inTransaction = (statusFlags & 0x0001) !== 0;
  }

  private async classifyCommandFailure(error: Object): Promise<ArkDbError> {
    const typed = toArkDbError(error);
    this.connState = connectionStateAfterCommandFailure(typed.kind);
    if (this.connState === ConnectionState.Error) await this.safeClose();
    return typed;
  }

  private async safeClose(): Promise<void> {
    try {
      await this.transport.close();
    } catch (e) {
      Logger.w(LogTag.Conn, 'transport cleanup failed error=' + Logger.errorToken(e));
    }
    this.channel = null;
  }
}

export function connectionStateAfterCommandFailure(kind: ArkDbErrorKind): ConnectionState {
  return kind === ArkDbErrorKind.Server ? ConnectionState.Ready : ConnectionState.Error;
}

export function authPluginLogValue(plugin: string): string {
  if (plugin === 'mysql_native_password' || plugin === 'caching_sha2_password') {
    return plugin;
  }
  return Logger.mask(plugin);
}

export function queryFailureDiagnostic(error: ArkDbError, durationMs: number): string {
  let diagnostic = 'kind=' + errorKindLogValue(error.kind);
  if (error.code !== undefined && Number.isFinite(error.code) &&
    Math.floor(error.code) === error.code) {
    diagnostic += ' code=' + error.code;
  }
  if (error.sqlState !== undefined && isSafeSqlState(error.sqlState)) {
    diagnostic += ' sqlState=' + error.sqlState;
  }
  return diagnostic + ' dur=' + diagnosticDurationMs(durationMs) +
    'ms error=' + Logger.errorToken(error);
}

export function mysqlTlsRequested(mode: SslMode, serverCapabilities: number): boolean {
  const supported = (serverCapabilities & Capabilities.SSL) !== 0;
  if (mode === SslMode.DISABLED) return false;
  if (mode === SslMode.PREFERRED) return supported;
  if (mode === SslMode.REQUIRED || mode === SslMode.VERIFY_CA ||
    mode === SslMode.VERIFY_IDENTITY) {
    if (!supported) {
      throw ArkDbError.tls('Server does not support TLS required by SSL mode ' + String(mode));
    }
    return true;
  }
  throw ArkDbError.tls('Unsupported SSL mode: ' + String(mode));
}

export function remainingSynchronizationTimeMs(deadlineMs: number, nowMs: number): number {
  if (!Number.isFinite(deadlineMs) || !Number.isFinite(nowMs) || deadlineMs < 0) return 0;
  return Math.max(0, deadlineMs - nowMs);
}

export function synchronizationRefreshFailure(error: Object): ArkDbError {
  return ArkDbError.protocol('Could not verify session status after result truncation');
}

/** Convenience factory mirroring the documented public API. */
export function createMySqlConnection(config: ConnectionConfig, password: string): MySqlConnection {
  return new MySqlConnection(config, password);
}

function firstByte(payload: Uint8Array): number {
  return payload.length > 0 ? payload[0] : -1;
}

function diagnosticDurationMs(durationMs: number): number {
  if (!Number.isFinite(durationMs) || durationMs <= 0) return 0;
  return Math.min(Number.MAX_SAFE_INTEGER, Math.floor(durationMs));
}

function isSafeSqlState(sqlState: string): boolean {
  if (sqlState.length !== 5) return false;
  for (let index = 0; index < sqlState.length; index += 1) {
    const code = sqlState.charCodeAt(index);
    const isDigit = code >= 0x30 && code <= 0x39;
    const isUppercaseLetter = code >= 0x41 && code <= 0x5a;
    if (!isDigit && !isUppercaseLetter) return false;
  }
  return true;
}

function errorKindLogValue(kind: ArkDbErrorKind): string {
  switch (kind) {
    case ArkDbErrorKind.Network:
      return 'Network';
    case ArkDbErrorKind.Tls:
      return 'Tls';
    case ArkDbErrorKind.Auth:
      return 'Auth';
    case ArkDbErrorKind.Protocol:
      return 'Protocol';
    case ArkDbErrorKind.Server:
      return 'Server';
    case ArkDbErrorKind.Timeout:
      return 'Timeout';
    case ArkDbErrorKind.Cancelled:
      return 'Cancelled';
    case ArkDbErrorKind.Validation:
      return 'Validation';
  }
}

function toArkDbError(e: Object): ArkDbError {
  if (e instanceof ArkDbError) {
    return e;
  }
  const err = e as Error;
  const msg = err !== null && err !== undefined && err.message !== undefined ? err.message : String(e);
  return ArkDbError.protocol(msg);
}
