import { describe, expect, it } from '@ohos/hypium';
import { Logger } from '../../../main/ets/core/diagnostics/Logger';
import { LogLevel, LogSink, LogTag } from '../../../main/ets/core/diagnostics/LogSink';
import { ConnectionConfig, SslMode } from '../../../main/ets/core/model/ConnectionConfig';
import { ArkDbError, ArkDbErrorKind } from '../../../main/ets/core/model/ArkDbError';
import { ConnectionState, ServerFamily } from '../../../main/ets/core/model/ServerInfo';
import { Capabilities } from '../../../main/ets/mysql/protocol/Constants';
import { PacketWriter } from '../../../main/ets/mysql/protocol/PacketWriter';
import { MockSocket, socket } from '../../../mock/NetworkKit.mock';
import { MySqlConnection, authPluginLogValue, queryFailureDiagnostic } from
  '../../../main/ets/mysql/MySqlConnection';

const SERVER_CAPABILITIES: number = Capabilities.PROTOCOL_41 | Capabilities.SECURE_CONNECTION |
  Capabilities.PLUGIN_AUTH | Capabilities.TRANSACTIONS;

class RecordingLogSink implements LogSink {
  messages: string[] = [];
  handshakeMessages: string[] = [];
  handshakeLevels: LogLevel[] = [];

  write(level: LogLevel, tag: string, message: string, timestampMs: number): void {
    this.messages.push(message);
    if (tag === LogTag.Conn && message.startsWith('handshake ')) {
      this.handshakeMessages.push(message);
      this.handshakeLevels.push(level);
    }
  }
}

export default function connectionDiagnosticsTest(): void {
  describe('connection diagnostics', () => {
    it('connectLogsOmitPlainVersionsWithoutChangingServerInfo', 0, async () => {
      await expectPrivateHandshakeLog('8.0.44', '8.0.44', ServerFamily.MySQL);
      await expectPrivateHandshakeLog('8.0.44', '8.0.44', ServerFamily.MySQL,
        'caching_sha2_password');
    });

    it('connectLogsOmitArbitraryServerVersionSuffixes', 0, async () => {
      for (const version of [
        '8.0.44-version-private-canary',
        '8.0.44 version-private-canary with spaces',
        '8.0.44-"version-private-canary"-%{public}s'
      ]) {
        await expectPrivateHandshakeLog(version, version, ServerFamily.MySQL);
      }
    });

    it('connectLogsOmitServerVersionControlCharacters', 0, async () => {
      const version = '8.0.44-\r\n\t\u001b[31mversion-private-canary\u007f';
      await expectPrivateHandshakeLog(version, version, ServerFamily.MySQL);
    });

    it('connectKeepsMariaDbVersionParsingAndFamilyDetection', 0, async () => {
      const version = '10.11.8-MariaDB-version-private-canary';
      await expectPrivateHandshakeLog('5.5.5-' + version, version, ServerFamily.MariaDB);
    });

    it('connectMasksUnknownAuthenticationPluginsAtTheSink', 0, async () => {
      const config = new ConnectionConfig();
      config.host = 'synthetic.invalid';
      config.ssl.mode = SslMode.DISABLED;
      const peer = new MockSocket();
      const connection = new MySqlConnection(config, '');
      const plugin = 'plugin-private-canary';
      const sink = new RecordingLogSink();
      const previousLevel = Logger.level;
      Logger.addSink(sink);
      Logger.setLevel(LogLevel.INFO);
      socket.nextTcp = peer;
      try {
        const connecting = connection.connect();
        peer.emitMessage(handshake('8.0.44', plugin));
        let rejected = false;
        try {
          await connecting;
        } catch (error) {
          expect(error instanceof ArkDbError).assertTrue();
          if (error instanceof ArkDbError) {
            expect(error.kind).assertEqual(ArkDbErrorKind.Auth);
            rejected = true;
          }
        }
        expect(rejected).assertTrue();
        expect(connection.state).assertEqual(ConnectionState.Error);
        expect(connection.serverInfo.authPlugin).assertEqual(plugin);
        expect(sink.handshakeMessages.length).assertEqual(1);
        expect(sink.handshakeMessages[0]).assertEqual(
          'handshake family=MySQL plugin=' + Logger.mask(plugin));
        expect(sink.messages.includes('unsupported auth plugin=' + Logger.mask(plugin))).assertTrue();
        for (const message of sink.messages) {
          expect(message.includes(plugin)).assertFalse();
          expect(message.includes('8.0.44')).assertFalse();
        }
      } finally {
        Logger.removeSink(sink);
        Logger.setLevel(previousLevel);
        socket.nextTcp = null;
        await connection.close();
      }
      expect(peer.listenerCount).assertEqual(0);
    });

    it('logsOnlyKnownAuthenticationPluginNames', 0, () => {
      expect(authPluginLogValue('mysql_native_password'))
        .assertEqual('mysql_native_password');
      expect(authPluginLogValue('caching_sha2_password'))
        .assertEqual('caching_sha2_password');

      const canary = 'canary-private-plugin';
      const masked = authPluginLogValue(canary);
      expect(masked.startsWith('#')).assertTrue();
      expect(masked.includes(canary)).assertFalse();
    });

    it('formatsServerQueryFailuresWithoutMessageOrSqlText', 0, () => {
      const messageCanary = 'server-message-canary';
      const sqlCanary = 'SELECT private_query_canary';
      const error = ArkDbError.server(
        messageCanary + ' sql=' + sqlCanary, 1064, '42000');
      const diagnostic = queryFailureDiagnostic(error, 25);

      expect(diagnostic.includes(
        'kind=Server code=1064 sqlState=42000 dur=25ms')).assertTrue();
      expect(diagnostic.includes('error=' + Logger.errorToken(error))).assertTrue();
      expect(diagnostic.includes(messageCanary)).assertFalse();
      expect(diagnostic.includes(sqlCanary)).assertFalse();
    });

    it('omitsUnavailableQueryMetadataAndBoundsDuration', 0, () => {
      const canary = 'network-message-canary';
      const error = new ArkDbError(ArkDbErrorKind.Network, canary);
      const diagnostic = queryFailureDiagnostic(error, -17.5);

      expect(diagnostic.includes('kind=Network dur=0ms')).assertTrue();
      expect(diagnostic.includes(' code=')).assertFalse();
      expect(diagnostic.includes(' sqlState=')).assertFalse();
      expect(diagnostic.includes(canary)).assertFalse();
      expect(queryFailureDiagnostic(error, 25.9).includes('dur=25ms')).assertTrue();
      expect(queryFailureDiagnostic(error, Number.POSITIVE_INFINITY)
        .includes('dur=0ms')).assertTrue();
    });

    it('omitsSqlStateValuesOutsideTheSafeProtocolAlphabet', 0, () => {
      const controlCharacterState = ArkDbError.server(
        'server-message-canary', 1064, '42\n00');
      const lowercaseState = ArkDbError.server(
        'server-message-canary', 1064, '42a00');

      expect(queryFailureDiagnostic(controlCharacterState, 1)
        .includes(' sqlState=')).assertFalse();
      expect(queryFailureDiagnostic(controlCharacterState, 1)
        .includes('\n')).assertFalse();
      expect(queryFailureDiagnostic(lowercaseState, 1)
        .includes(' sqlState=')).assertFalse();
    });
  });
}

async function expectPrivateHandshakeLog(rawVersion: string, expectedVersion: string,
  family: ServerFamily, plugin: string = 'mysql_native_password'): Promise<void> {
  const config = new ConnectionConfig();
  config.host = 'synthetic.invalid';
  config.ssl.mode = SslMode.DISABLED;
  const peer = new MockSocket();
  const connection = new MySqlConnection(config, '');
  const sink = new RecordingLogSink();
  const previousLevel = Logger.level;
  Logger.addSink(sink);
  Logger.setLevel(LogLevel.INFO);
  socket.nextTcp = peer;
  try {
    const connecting = connection.connect();
    peer.emitMessage(new PacketWriter().writeBytes(handshake(rawVersion, plugin))
      .writeBytes(ok(2)).toUint8Array());
    await connecting;

    expect(connection.state).assertEqual(ConnectionState.Ready);
    expect(connection.serverInfo.version).assertEqual(expectedVersion);
    expect(connection.serverInfo.family).assertEqual(family);
    expect(connection.serverInfo.productName).assertEqual(String(family));
    expect(connection.serverInfo.capabilities).assertEqual(SERVER_CAPABILITIES);
    expect(connection.serverInfo.protocolVersion).assertEqual(10);
    expect(connection.serverInfo.connectionId).assertEqual(42);
    expect(connection.serverInfo.authPlugin).assertEqual(plugin);
    expect(connection.sessionStatus.autocommit).assertTrue();
    expect(sink.handshakeMessages.length).assertEqual(1);
    expect(sink.handshakeLevels[0]).assertEqual(LogLevel.INFO);
    expect(sink.handshakeMessages[0]).assertEqual(
      'handshake family=' + String(family) + ' plugin=' + authPluginLogValue(plugin));
    for (const message of sink.messages) {
      for (const excluded of [
        rawVersion, expectedVersion, 'version-private-canary', 'server=',
        '\r', '\n', '\t', '\u001b', '\u007f'
      ]) {
        expect(message.includes(excluded)).assertFalse();
      }
    }

    const ping = connection.ping();
    peer.emitMessage(ok(1));
    await ping;
    expect(connection.state).assertEqual(ConnectionState.Ready);
  } finally {
    Logger.removeSink(sink);
    Logger.setLevel(previousLevel);
    socket.nextTcp = null;
    await connection.close();
  }
  expect(peer.closeCalls).assertEqual(1);
  expect(peer.listenerCount).assertEqual(0);
}

function handshake(version: string, plugin: string = 'mysql_native_password'): Uint8Array {
  const payload = new PacketWriter().writeUInt8(10).writeNulString(version).writeUInt32(42)
    .writeBytes(new Uint8Array(8)).writeUInt8(0).writeUInt16(SERVER_CAPABILITIES & 0xffff)
    .writeUInt8(45).writeUInt16(2).writeUInt16(SERVER_CAPABILITIES >>> 16).writeUInt8(21)
    .writeBytes(new Uint8Array(10)).writeBytes(new Uint8Array(12)).writeUInt8(0)
    .writeNulString(plugin).toUint8Array();
  return frame(0, payload);
}

function ok(sequence: number): Uint8Array {
  return frame(sequence, new Uint8Array([0, 0, 0, 2, 0, 0, 0]));
}

function frame(sequence: number, payload: Uint8Array): Uint8Array {
  return new PacketWriter().writeUInt24(payload.length).writeUInt8(sequence)
    .writeBytes(payload).toUint8Array();
}
