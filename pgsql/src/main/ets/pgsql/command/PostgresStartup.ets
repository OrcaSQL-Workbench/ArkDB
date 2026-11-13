import { ArkDbError, ArkDbErrorKind } from '@arkdb/core';
import { HarmonyPostgresAuthPlatform, PostgresAuthPlatform, PostgresScramClient, PostgresScramClientState, PostgresScramPort, buildPostgresCleartextPasswordResponse, buildPostgresMd5PasswordResponse } from '../auth/PostgresAuthCrypto';
import { DefaultPostgresScramPort } from '../auth/PostgresSaslPrep';
import { PostgresStartupSession, applyPostgresParameterStatus, postgresErrorFromResponse } from '../execution/PostgresSettlements';
import { PostgresSslMode } from '../model/PostgresConnectionConfig';
import { PostgresFrontendSerializer, PostgresStartupParameter } from '../protocol/PostgresByteCodec';
import { PostgresAuthenticationCleartextPassword, PostgresAuthenticationMd5Password, PostgresAuthenticationOk, PostgresAuthenticationRequest, PostgresAuthenticationSasl, PostgresAuthenticationSaslContinue, PostgresAuthenticationSaslFinal, PostgresBackendKeyData, PostgresBackendMessage, PostgresBackendParser, PostgresErrorResponse, PostgresMessage, PostgresNegotiateProtocolVersion, PostgresNoticeResponse, PostgresNotificationResponse, PostgresParameterStatus, PostgresReadyForQuery } from '../protocol/PostgresMessageChannel';
import { MAX_POSTGRES_MESSAGE_BYTES, POSTGRES_LENGTH_BYTES, POSTGRES_NORMAL_HEADER_BYTES } from '../protocol/PostgresProtocolConstants';

const SCRAM_SHA_256: string = 'SCRAM-SHA-256';
const DEFAULT_AUTH_PLATFORM: PostgresAuthPlatform = new HarmonyPostgresAuthPlatform();
export type PostgresScramPortFactory = (platform: PostgresAuthPlatform) => PostgresScramPort;
function defaultScramPortFactory(platform: PostgresAuthPlatform): PostgresScramPort { return new DefaultPostgresScramPort(platform); }

export function createDefaultPostgresStartupRunner(authPlatform: PostgresAuthPlatform = DEFAULT_AUTH_PLATFORM,
  scramPortFactory: PostgresScramPortFactory = defaultScramPortFactory): (context: PostgresStartupSession) => Promise<void> {
  return (context: PostgresStartupSession): Promise<void> => runPostgresStartup(context, authPlatform, scramPortFactory);
}

export async function runPostgresStartup(context: PostgresStartupSession,
  authPlatform: PostgresAuthPlatform = DEFAULT_AUTH_PLATFORM,
  scramPortFactory: PostgresScramPortFactory = defaultScramPortFactory): Promise<void> {
  await negotiateTlsIfConfigured(context);
  assertStartupActive(context); context.enterAuthenticating();
  await writeExactBytes(context, PostgresFrontendSerializer.startup(buildStartupParameters(context)));
  let authenticated = false; let authExchangeStarted = false; let backendKeyReceived = false;
  let scram: PostgresScramClient | null = null;
  try {
    while (true) {
      const raw = await readStartupMessage(context);
      let parsed: PostgresBackendMessage | null = null;
      try {
        const msg: PostgresBackendMessage = PostgresBackendParser.parse(raw);
        parsed = msg;
        if (msg instanceof PostgresErrorResponse) throw postgresErrorFromResponse(msg);
        if (msg instanceof PostgresNegotiateProtocolVersion) {
          throw ArkDbError.unsupported('PostgreSQL protocol version or startup parameter negotiation is not supported.');
        }
        if (msg instanceof PostgresNoticeResponse) continue;
        if (!authenticated) {
          if (msg instanceof PostgresAuthenticationOk) {
            if (scram !== null && scram.state !== PostgresScramClientState.Finalized) {
              throw ArkDbError.auth('PostgreSQL server completed authentication before SCRAM server signature verification.');
            }
            authenticated = true; continue;
          }
          if (msg instanceof PostgresAuthenticationSasl) {
            if (authExchangeStarted) throw duplicateAuthChallenge();
            authExchangeStarted = true;
            if (!offersMechanism(msg.mechanisms, SCRAM_SHA_256)) throw ArkDbError.unsupported('PostgreSQL server does not offer SCRAM-SHA-256.');
            const pw = context.readPassword();
            if (pw.length === 0) throw ArkDbError.validation('Password is required for PostgreSQL SCRAM authentication.');
            const activeScram = new PostgresScramClient(context.config.user, pw, scramPortFactory(authPlatform));
            scram = activeScram;
            const clientFirst = await runSensitiveBytesStep(context, (): Promise<Uint8Array> => activeScram.start(msg), (): void => activeScram.dispose());
            await writeSensitiveFrame(context, clientFirst); continue;
          }
          if (msg instanceof PostgresAuthenticationSaslContinue) {
            if (scram === null || scram.state !== PostgresScramClientState.Started) throw ArkDbError.protocol('Unexpected PostgreSQL SASLContinue message.');
            const activeScram = scram;
            const clientFinal = await runSensitiveBytesStep(context, (): Promise<Uint8Array> => activeScram.continue(msg), (): void => activeScram.dispose());
            await writeSensitiveFrame(context, clientFinal); continue;
          }
          if (msg instanceof PostgresAuthenticationSaslFinal) {
            if (scram === null || scram.state !== PostgresScramClientState.Continued) throw ArkDbError.protocol('Unexpected PostgreSQL SASLFinal message.');
            assertStartupActive(context); scram.finalize(msg); continue;
          }
          if (msg instanceof PostgresAuthenticationMd5Password) {
            if (authExchangeStarted) throw duplicateAuthChallenge();
            authExchangeStarted = true; const pw = context.readPassword();
            if (pw.length === 0) throw ArkDbError.validation('Password is required for PostgreSQL MD5 authentication.');
            const payload = await runSensitiveBytesStep(context, (): Promise<Uint8Array> => buildPostgresMd5PasswordResponse(pw, context.config.user, msg.salt, authPlatform));
            await writeSensitivePasswordPayload(context, payload); continue;
          }
          if (msg instanceof PostgresAuthenticationCleartextPassword) {
            if (authExchangeStarted) throw duplicateAuthChallenge();
            authExchangeStarted = true; const pw = context.readPassword();
            if (context.config.allowCleartextPassword && context.serverInfo.tlsActive && context.config.ssl.mode === PostgresSslMode.VERIFY_FULL && pw.length === 0) {
              throw ArkDbError.validation('Password is required for PostgreSQL cleartext password authentication.');
            }
            const payload = buildPostgresCleartextPasswordResponse(pw, context.config.allowCleartextPassword, context.serverInfo.tlsActive, context.config.ssl.mode);
            await writeSensitivePasswordPayload(context, payload); continue;
          }
          if (msg instanceof PostgresAuthenticationRequest) {
            if (authExchangeStarted) throw duplicateAuthChallenge();
            throw ArkDbError.unsupported('Unsupported PostgreSQL authentication method: ' + msg.code);
          }
          throw ArkDbError.protocol('Unexpected PostgreSQL backend message before AuthenticationOk.');
        }
        if (msg instanceof PostgresParameterStatus) { assertStartupActive(context); applyPostgresParameterStatus(context.serverInfo, msg); continue; }
        if (msg instanceof PostgresBackendKeyData) {
          if (backendKeyReceived) throw ArkDbError.protocol('Duplicate PostgreSQL BackendKeyData during startup.');
          backendKeyReceived = true; assertStartupActive(context); context.setBackendKeyData(msg.processId, msg.secretKey); continue;
        }
        if (msg instanceof PostgresNotificationResponse) continue;
        if (msg instanceof PostgresReadyForQuery) { assertStartupActive(context); context.applyReadyStatus(msg.status); return; }
        throw ArkDbError.protocol('Unexpected PostgreSQL backend message during post-authentication startup.');
      } finally {
        raw.payload.fill(0);
        if (parsed instanceof PostgresBackendKeyData) parsed.secretKey.fill(0);
      }
    }
  } finally {
    if (scram !== null) { scram.dispose(); scram = null; }
  }
}

async function negotiateTlsIfConfigured(context: PostgresStartupSession): Promise<void> {
  const config = context.config;
  if (config.ssl.mode === PostgresSslMode.DISABLED) { assertStartupActive(context); context.serverInfo.tlsActive = false; return; }
  await writeExactBytes(context, PostgresFrontendSerializer.sslRequest());
  let reply: Uint8Array | null = null;
  try {
    reply = await runStartupStep<Uint8Array | null>(context, (): Promise<Uint8Array | null> => context.transport.read(1));
  } catch (error) {
    if (error instanceof ArkDbError && error.kind === ArkDbErrorKind.Protocol && error.message === 'PostgreSQL transport read was incomplete.') {
      throw ArkDbError.tls('PostgreSQL SSLRequest did not receive a 1-byte server reply.');
    }
    throw error as Error;
  }
  if (reply === null || reply.length !== 1) throw ArkDbError.tls('PostgreSQL SSLRequest did not receive a 1-byte server reply.');
  const decision = reply[0]; reply.fill(0);
  if (decision === 0x53) {
    assertStartupActive(context);
    if (context.transport.prepareTlsUpgrade === undefined || context.transport.upgradeToTls === undefined) throw ArkDbError.tls('PostgreSQL TLS upgrade is unavailable.');
    context.transport.prepareTlsUpgrade();
    await runStartupStep<void>(context, (): Promise<void> => context.transport.upgradeToTls!(config.host, config.port, config.ssl, context.deadline.remainingMs()));
    assertStartupActive(context); context.serverInfo.tlsActive = true; return;
  }
  if (decision === 0x4e) throw ArkDbError.tls('PostgreSQL server does not support TLS connections.', 'SSL_NOT_SUPPORTED');
  if (decision === 0x45) throw ArkDbError.tls('PostgreSQL server rejected SSLRequest before TLS negotiation.', 'SSL_PRE_TLS_ERROR');
  throw ArkDbError.protocol('Unexpected PostgreSQL SSLRequest response byte.');
}

function buildStartupParameters(context: PostgresStartupSession): PostgresStartupParameter[] {
  const config = context.config;
  const database = config.database !== undefined && config.database.length > 0 ? config.database : config.user;
  const parameters: PostgresStartupParameter[] = [{ name: 'user', value: config.user }, { name: 'database', value: database }];
  if (config.applicationName.length > 0) parameters.push({ name: 'application_name', value: config.applicationName });
  parameters.push({ name: 'client_encoding', value: 'UTF8' });
  return parameters;
}
async function readStartupMessage(context: PostgresStartupSession): Promise<PostgresMessage> {
  assertStartupActive(context); let abandoned = false; let hasResolved = false; let resolvedPayload = new Uint8Array(0);
  const task = context.channel.readMessage();
  task.then((msg: PostgresMessage): void => {
    if (abandoned) msg.payload.fill(0); else { hasResolved = true; resolvedPayload = msg.payload; }
  }, (): void => {});
  try { return await runStartupStep<PostgresMessage>(context, (): Promise<PostgresMessage> => task); }
  catch (error) {
    abandoned = true; if (hasResolved) { resolvedPayload.fill(0); resolvedPayload = new Uint8Array(0); }
    throw error as Error;
  }
}
async function runSensitiveBytesStep(context: PostgresStartupSession,
  operation: () => Promise<Uint8Array>, onAbandonedSettle?: () => void): Promise<Uint8Array> {
  assertStartupActive(context); let abandoned = false; let hasResolved = false; let resolved = new Uint8Array(0);
  const task = operation();
  task.then((bytes: Uint8Array): void => {
    if (abandoned) { bytes.fill(0); if (onAbandonedSettle !== undefined) onAbandonedSettle(); }
    else { hasResolved = true; resolved = bytes; }
  }, (): void => { if (abandoned && onAbandonedSettle !== undefined) onAbandonedSettle(); });
  try { return await runStartupStep<Uint8Array>(context, (): Promise<Uint8Array> => task); }
  catch (error) {
    abandoned = true;
    if (hasResolved) { resolved.fill(0); resolved = new Uint8Array(0); if (onAbandonedSettle !== undefined) onAbandonedSettle(); }
    throw error as Error;
  }
}
async function writeSensitivePasswordPayload(context: PostgresStartupSession, payload: Uint8Array): Promise<void> {
  if (payload.length > MAX_POSTGRES_MESSAGE_BYTES - POSTGRES_LENGTH_BYTES) {
    payload.fill(0); throw ArkDbError.validation('PostgreSQL message exceeds the client limit');
  }
  const frame = new Uint8Array(payload.length + POSTGRES_NORMAL_HEADER_BYTES);
  frame[0] = 0x70; new DataView(frame.buffer).setInt32(1, payload.length + POSTGRES_LENGTH_BYTES, false);
  frame.set(payload, POSTGRES_NORMAL_HEADER_BYTES); payload.fill(0);
  await writeSensitiveFrame(context, frame);
}
async function writeSensitiveFrame(context: PostgresStartupSession, frame: Uint8Array): Promise<void> {
  let settled = false; let writeTask: Promise<number> | null = null;
  try {
    assertStartupActive(context);
    const task = context.transport.write(frame); writeTask = task;
    task.then((): void => { settled = true; frame.fill(0); }, (): void => { settled = true; frame.fill(0); });
    const written = await runStartupStep<number>(context, (): Promise<number> => task);
    if (!Number.isSafeInteger(written) || written !== frame.length) throw ArkDbError.protocol('PostgreSQL transport write was incomplete.');
  } finally { if (writeTask === null || settled) frame.fill(0); }
}
async function writeExactBytes(context: PostgresStartupSession, frame: Uint8Array): Promise<void> {
  const written = await runStartupStep<number>(context, (): Promise<number> => context.transport.write(frame));
  if (!Number.isSafeInteger(written) || written !== frame.length) throw ArkDbError.protocol('PostgreSQL transport write was incomplete.');
}
function runStartupStep<T>(context: PostgresStartupSession, operation: () => Promise<T>): Promise<T> {
  return context.deadline.wait<T>((): Promise<T> => context.settlement.raceClose<T>((): Promise<T> => { context.deadline.remainingMs(); return operation(); }));
}
function assertStartupActive(context: PostgresStartupSession): void {
  if (context.settlement.closeReason !== null) throw context.settlement.closeReason;
  if (context.settlement.isSettled) throw ArkDbError.protocol('PostgreSQL command settlement is already settled.');
  context.deadline.remainingMs();
}
function offersMechanism(mechanisms: string[], expected: string): boolean {
  for (const m of mechanisms) { if (m === expected) return true; }
  return false;
}
function duplicateAuthChallenge(): ArkDbError { return ArkDbError.protocol('Unexpected duplicate PostgreSQL authentication challenge.'); }
