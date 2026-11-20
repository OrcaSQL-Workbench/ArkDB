import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';
import ts from 'typescript';

const source = new URL('../../examples/postgres-device-acceptance/entry/src/main/ets/sample/DeviceAcceptanceCases.ets',
  import.meta.url);
const State = { Ready: 'ready' };
const Kind = { Server: 'server' };

class ArkDbError extends Error {
  constructor(sqlState) {
    super('server error');
    this.kind = Kind.Server;
    this.sqlState = sqlState;
  }
}

function loadCases() {
  const compiled = ts.transpileModule(readFileSync(source, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exports = {};
  const postgres = {
    ArkDbError, ArkDbErrorKind: Kind, CancellationOutcome: { Requested: 'requested' },
    ConnectionState: State, QueryOptions: class {},
    PostgresParameter: class { constructor(type, value) { this.type = type; this.value = value; } },
    PostgresParameterType: { Int8: 1, Numeric: 2, Bytea: 3, Text: 4 }
  };
  vm.runInNewContext(compiled, {
    exports, Error, Uint8Array, setTimeout, clearTimeout,
    require(name) {
      assert.equal(name, '@arkdb/postgres');
      return postgres;
    }
  });
  return exports.DeviceAcceptanceCases;
}

function withTimeoutSetup(connection) {
  return {
    ...connection,
    query: (sql) => sql === 'SET statement_timeout = 0'
      ? Promise.resolve({ rows: [] })
      : connection.query(sql)
  };
}

test('fixed acceptance cases check errors, exact prepared values, and the bound schema challenge', async () => {
  const Cases = loadCases();
  const calls = [];
  let allowed = true;
  const cases = new Cases('challenge-id', 'challenge-value', { wait: async () => {} }, () => {
    if (!allowed) throw new Error('inactive');
  });
  const connection = {
    query: async (sql) => {
      calls.push(sql);
      assert.equal(sql, 'SELECT * FROM arkdb_device_acceptance_required_missing_table');
      throw new ArkDbError('42P01');
    },
    postgresFeatures: { prepared: { execute: async (sql, params) => {
      calls.push(sql);
      if (params.length === 1) {
        assert.equal(sql, 'SELECT challenge_value FROM arkdb_device_acceptance WHERE challenge_id = $1');
        assert.equal(params[0].type, 4);
        assert.equal(params[0].value, 'challenge-id');
        return { rows: [['challenge-value']] };
      }
      assert.equal(sql, 'SELECT $1::bigint AS exact_bigint, $2::numeric(10,2) AS exact_decimal, ' +
        '$3::bytea AS exact_binary');
      assert.deepEqual(Array.from(params, (param) => param.type), [1, 2, 3]);
      assert.equal(params[0].value, 9007199254740993n);
      assert.equal(params[1].value, '12.34');
      assert.deepEqual([...params[2].value], [0, 127, 255]);
      return { rows: [[9007199254740993n, '12.34', new Uint8Array([0, 127, 255])]] };
    } } }
  };
  assert.equal(await cases.verifyServerError(connection), true);
  assert.equal(await cases.verifyPreparedValues(connection), true);
  assert.equal(await cases.verifyAuthorizedSchema(connection), true);
  connection.postgresFeatures.prepared.execute = async () => ({ rows: [['incorrect']] });
  assert.equal(await cases.verifyPreparedValues(connection), false);
  assert.equal(await cases.verifyAuthorizedSchema(connection), false);
  connection.query = async () => { throw new ArkDbError('28000'); };
  assert.equal(await cases.verifyServerError(connection), false);
  allowed = false;
  const prior = calls.length;
  await assert.rejects(() => cases.verifyServerError(connection), /inactive/);
  await assert.rejects(() => cases.verifyPreparedValues(connection), /inactive/);
  await assert.rejects(() => cases.verifyAuthorizedSchema(connection), /inactive/);
  assert.equal(calls.length, prior);
});

test('cancellation verifies interruption and stops before further work when the guard closes', async () => {
  const Cases = loadCases();
  const calls = [];
  let rejectQuery;
  let allowed = true;
  const cases = new Cases('id', 'value', { wait: async () => { calls.push('wait'); } }, () => {
    if (!allowed) throw new Error('inactive');
  });
  const connection = {
    state: State.Ready,
    query: (sql) => {
      calls.push('query');
      assert.equal(sql, 'SELECT pg_sleep(10), 1');
      return new Promise((_, reject) => { rejectQuery = reject; });
    },
    cancel: async () => {
      calls.push('cancel');
      rejectQuery(new ArkDbError('57014'));
      return { outcome: 'requested' };
    },
    isInterruptionError: (error) => error.sqlState === '57014',
    ping: async () => { calls.push('ping'); },
    close: async () => { calls.push('close'); rejectQuery(new ArkDbError('57014')); }
  };
  assert.equal(await cases.verifyCancellation(withTimeoutSetup(connection)), true);
  assert.deepEqual(calls, ['query', 'wait', 'cancel', 'ping']);

  calls.length = 0;
  const stopped = new Cases('id', 'value', { wait: async () => {
    calls.push('wait');
    allowed = false;
  } }, () => { if (!allowed) throw new Error('inactive'); });
  await assert.rejects(() => stopped.verifyCancellation(withTimeoutSetup(connection)),
    (error) => error.operationError?.message === 'inactive');
  assert.deepEqual(calls, ['query', 'wait', 'close']);
});

test('a case cannot pass if the guard closes while an operation is pending', async () => {
  const Cases = loadCases();
  for (const method of ['verifyServerError', 'verifyPreparedValues', 'verifyAuthorizedSchema']) {
    let active = true;
    const cases = new Cases('id', 'value', { wait: async () => {} }, () => {
      if (!active) throw new Error('inactive');
    });
    const connection = {
      query: async () => { active = false; throw new ArkDbError('42P01'); },
      postgresFeatures: { prepared: { execute: async () => {
        active = false;
        return method === 'verifyPreparedValues'
          ? { rows: [[9007199254740993n, '12.34', new Uint8Array([0, 127, 255])]] }
          : { rows: [['value']] };
      } } }
    };
    await assert.rejects(() => cases[method](connection), /inactive/, method);
  }
});

test('failed cancellation closes and settles the outstanding query', async () => {
  const Cases = loadCases();
  const calls = [];
  let rejectQuery;
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  const connection = {
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => { throw new Error('cancel failed'); },
    close: async () => { calls.push('close'); rejectQuery(new Error('closed')); },
    ping: async () => { calls.push('ping'); }
  };
  await assert.rejects(() => cases.verifyCancellation(withTimeoutSetup(connection)), (error) =>
    error.operationError?.message === 'cancel failed' && error.queryError?.message === 'closed');
  assert.deepEqual(calls, ['close']);
});

test('a cancellation that was not requested closes the query and fails the case', async () => {
  const Cases = loadCases();
  let resolveQuery;
  let closed = false;
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  const connection = {
    query: () => new Promise((resolve) => { resolveQuery = resolve; }),
    cancel: async () => ({ outcome: 'not-requested' }),
    close: async () => { closed = true; resolveQuery({ rows: [] }); }
  };
  assert.equal(await cases.verifyCancellation(withTimeoutSetup(connection)), false);
  assert.equal(closed, true);
});

test('cancellation does not pass when the guard closes during ping', async () => {
  const Cases = loadCases();
  let active = true;
  let rejectQuery;
  let closed = false;
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {
    if (!active) throw new Error('inactive');
  });
  const connection = {
    state: State.Ready,
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => { rejectQuery(new ArkDbError('57014')); return { outcome: 'requested' }; },
    isInterruptionError: () => true,
    ping: async () => { active = false; },
    close: async () => { closed = true; }
  };
  await assert.rejects(() => cases.verifyCancellation(withTimeoutSetup(connection)),
    (error) => error.operationError?.message === 'inactive');
  assert.equal(closed, true);
});

test('cancellation closes a pending query if the guard closes during cancel', async () => {
  const Cases = loadCases();
  let active = true;
  let rejectQuery;
  let closed = false;
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {
    if (!active) throw new Error('inactive');
  });
  const connection = {
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => { active = false; return { outcome: 'requested' }; },
    close: async () => { closed = true; rejectQuery(new Error('closed')); }
  };
  const operation = cases.verifyCancellation(withTimeoutSetup(connection)).then(
    () => null, (error) => error
  );
  let timeout;
  const error = await Promise.race([
    operation, new Promise((resolve) => { timeout = setTimeout(() => resolve(null), 200); })
  ]);
  clearTimeout(timeout);
  if (error === null) {
    rejectQuery(new Error('test released pending query'));
    await operation;
  }
  assert.equal(error?.operationError?.message, 'inactive');
  assert.equal(closed, true);
});

test('cleanup failure preserves both cancellation and cleanup errors', async () => {
  const Cases = loadCases();
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  let rejectQuery;
  const connection = {
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => { throw new Error('cancel failed'); },
    close: async () => { throw new Error('close failed'); }
  };
  const error = await cases.verifyCancellation(withTimeoutSetup(connection)).catch((failure) => failure);
  assert.equal(error.operationError.message, 'cancel failed');
  assert.equal(error.cleanupError.message, 'close failed');
  assert.equal((await error.cleanupSettlement).message, 'close failed');
  assert.equal(typeof error.querySettlement?.then, 'function');
  rejectQuery(new Error('query cleanup failed'));
  assert.equal((await error.querySettlement).message, 'query cleanup failed');
});

test('cancellation cleanup times out without losing the outstanding query', async (t) => {
  const Cases = loadCases();
  for (const stalled of ['close', 'query']) {
    await t.test(stalled, async () => {
      let rejectQuery;
      let rejectClose;
      const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
      const connection = {
        query: () => new Promise((_, reject) => { rejectQuery = reject; }),
        cancel: async () => { throw new Error('cancel failed'); },
        close: () => stalled === 'close'
          ? new Promise((_, reject) => { rejectClose = reject; })
          : Promise.resolve()
      };
      const pending = cases.verifyCancellation(withTimeoutSetup(connection)).catch((error) => error);
      let timer;
      const failure = await Promise.race([
        pending, new Promise((resolve) => { timer = setTimeout(() => resolve(null), 2300); })
      ]);
      clearTimeout(timer);
      if (failure === null) {
        if (rejectClose) rejectClose(new Error('late close failure'));
        rejectQuery(new Error('query failed'));
        await pending;
      }
      assert.notEqual(failure, null, `${stalled} cleanup must not hang`);
      assert.equal(failure.operationError.message, 'cancel failed');
      assert.match(failure.cleanupError.message, /timed out/);
      assert.equal(failure.cleanupError.constructor.name, 'DeviceCaseCleanupTimeoutError');
      if (rejectClose) rejectClose(new Error('late close failure'));
      rejectQuery(new Error('query failed'));
      assert.equal((await failure.querySettlement).message, 'query failed');
      const lateCleanup = await failure.cleanupSettlement;
      assert.equal(lateCleanup?.message ?? null, stalled === 'close' ? 'late close failure' : null);
    });
  }
});

test('unexpected query failures survive cancellation cleanup', async () => {
  const Cases = loadCases();
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  const queryError = new ArkDbError('57014');
  let rejectQuery;
  let closed = false;
  const connection = {
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => { rejectQuery(queryError); return { outcome: 'requested' }; },
    isInterruptionError: () => false,
    close: async () => { closed = true; }
  };
  await assert.rejects(() => cases.verifyCancellation(withTimeoutSetup(connection)), (error) => error === queryError);
  assert.equal(closed, true);
});

test('not-requested cancellation keeps the query handle if cleanup fails', async () => {
  const Cases = loadCases();
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  let rejectQuery;
  const connection = {
    query: () => new Promise((_, reject) => { rejectQuery = reject; }),
    cancel: async () => ({ outcome: 'not-requested' }),
    close: async () => { throw new Error('close failed'); }
  };
  const error = await cases.verifyCancellation(withTimeoutSetup(connection)).catch((failure) => failure);
  assert.match(error.operationError.message, /not requested/);
  assert.equal(error.cleanupError.message, 'close failed');
  rejectQuery(new Error('query failed'));
  assert.equal((await error.querySettlement).message, 'query failed');
});

test('guard closure during not-requested cancellation cleanup prevents a verdict', async () => {
  const Cases = loadCases();
  let active = true;
  let resolveQuery;
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {
    if (!active) throw new Error('inactive');
  });
  const connection = {
    query: () => new Promise((resolve) => { resolveQuery = resolve; }),
    cancel: async () => ({ outcome: 'not-requested' }),
    close: async () => { active = false; resolveQuery({ rows: [] }); }
  };
  await assert.rejects(() => cases.verifyCancellation(withTimeoutSetup(connection)), /inactive/);
});

test('a query failure during cleanup is never discarded', async () => {
  const Cases = loadCases();
  for (const cancelFails of [false, true]) {
    let rejectQuery;
    const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
    const connection = {
      query: () => new Promise((_, reject) => { rejectQuery = reject; }),
      cancel: async () => {
        if (cancelFails) throw new Error('cancel failed');
        return { outcome: 'not-requested' };
      },
      close: async () => { rejectQuery(new Error('query cleanup failed')); }
    };
    await assert.rejects(() => cases.verifyCancellation(withTimeoutSetup(connection)), (error) => {
      assert.equal(cancelFails ? error.operationError?.message : undefined,
        cancelFails ? 'cancel failed' : undefined);
      assert.equal(cancelFails ? error.queryError?.message : error.message, 'query cleanup failed');
      return true;
    });
  }
});

test('cancellation disables server statement timeouts before starting the sleep query', async () => {
  const Cases = loadCases();
  const cases = new Cases('id', 'value', { wait: async () => {} }, () => {});
  const calls = [];
  let timeoutEnabled = true;
  let rejectQuery;
  const connection = {
    state: State.Ready,
    query: async (sql) => {
      calls.push(sql);
      if (sql === 'SET statement_timeout = 0') {
        timeoutEnabled = false;
        return { rows: [] };
      }
      assert.equal(sql, 'SELECT pg_sleep(10), 1');
      if (timeoutEnabled) throw new ArkDbError('57014');
      return new Promise((_, reject) => { rejectQuery = reject; });
    },
    cancel: async () => {
      if (rejectQuery) rejectQuery(new ArkDbError('57014'));
      return { outcome: 'requested' };
    },
    isInterruptionError: () => true,
    ping: async () => {},
    close: async () => {}
  };
  assert.equal(await cases.verifyCancellation(connection), true);
  assert.deepEqual(calls, ['SET statement_timeout = 0', 'SELECT pg_sleep(10), 1']);
});

test('cancellation does not start a query if disabling timeouts fails or the guard closes', async () => {
  const Cases = loadCases();
  for (const failSetup of [true, false]) {
    let active = true;
    const calls = [];
    const cases = new Cases('id', 'value', { wait: async () => {} }, () => {
      if (!active) throw new Error('inactive');
    });
    const connection = {
      query: async (sql) => {
        calls.push(sql);
        if (failSetup) throw new Error('setup failed');
        active = false;
        return { rows: [] };
      }
    };
    await assert.rejects(() => cases.verifyCancellation(connection), failSetup ? /setup failed/ : /inactive/);
    assert.deepEqual(calls, ['SET statement_timeout = 0']);
  }
});
