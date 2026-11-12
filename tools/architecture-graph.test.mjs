import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import test from 'node:test';
import {
  assertImportPolicy, readArkTsGraph, stronglyConnectedFiles
} from './architecture-graph.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const TOOL_LAYER_RULES = [
  {
    from: /^tools\/(?:lib|workspace|artifact)\//,
    to: /^tools\/[^/]+\.mjs$/,
    transitive: true,
    message: 'Low-level tooling must not depend on root workflow or CLI modules.'
  },
  {
    from: /^tools\/lib\//,
    to: /^tools\/(?:workspace|artifact|build|consumer|release|device)\//,
    transitive: true,
    message: 'Tool lib must not depend on workflow layers.'
  },
  {
    from: /^tools\/workspace\//,
    to: /^tools\/(?:artifact|build|consumer|release|device)\//,
    transitive: true,
    message: 'Tool workspace ownership must not depend on higher workflow layers.'
  },
  {
    from: /^tools\/artifact\//,
    to: /^tools\/(?:build|consumer|release|device)\//,
    transitive: true,
    message: 'Tool artifact primitives must not depend on workflow orchestration.'
  },
  {
    from: /^tools\/build\//,
    to: /^tools\/(?:consumer|release|device)\//,
    transitive: true,
    message: 'Tool build ownership must not depend on downstream workflows.'
  },
  {
    from: /^tools\/consumer\//,
    to: /^tools\/(?:build|release|device)\//,
    transitive: true,
    message: 'Tool consumer ownership must not depend on build, release, or device workflows.'
  },
  {
    from: /^tools\/release\//,
    to: /^tools\/(?:build|device)\//,
    transitive: true,
    message: 'Tool release ownership must not depend on build or device workflows.'
  },
  {
    from: /^tools\/device\//,
    to: /^tools\/build\//,
    transitive: true,
    message: 'Tool device ownership must not depend on build orchestration.'
  },
  {
    from: /^tools\/device\//,
    to: /^tools\/release\/(?!(?:contracts|bundle)\.mjs$)/,
    transitive: true,
    message: 'Tool device ownership may depend only on sealed release contracts.'
  },
  {
    from: /^tools\/device\//,
    to: /^tools\/consumer\/(?!evidence\.mjs$)/,
    transitive: true,
    message: 'Tool device ownership may depend only on sealed consumer evidence contracts.'
  }
];
const ROOT_TOOL_FILES = [
  'tools/architecture-graph.mjs',
  'tools/check-package.mjs',
  'tools/check-release.mjs',
  'tools/delivery-workspace.mjs',
  'tools/doc-examples.mjs',
  'tools/driver-contracts.mjs',
  'tools/driver-packages.mjs',
  'tools/github-release.mjs',
  'tools/hap-content.mjs',
  'tools/har-release.mjs',
  'tools/package-har.mjs',
  'tools/plan-har-builds.mjs',
  'tools/prepare-har-release.mjs',
  'tools/publish-har.mjs',
  'tools/run-hvigor.mjs',
  'tools/run-ohos-tests.mjs',
  'tools/run-ohpm.mjs',
  'tools/test-consumer.mjs',
  'tools/verify-device-evidence.mjs',
  'tools/verify-download.mjs',
  'tools/verify-driver.mjs'
];
const OWNED_TOOL_DIRECTORIES = [
  'artifact',
  'build',
  'consumer',
  'device',
  'lib',
  'release',
  'workspace'
];
const MYSQL_FEATURE_DIRECTORIES = [
  'batch',
  'cursor',
  'insert',
  'longdata',
  'metadata',
  'metrics',
  'named',
  'prepared',
  'procedure',
  'session',
  'transaction'
];
const OWNED_SOURCE_ROOTS = [
  {
    root: '',
    files: ['hvigorfile.ts'],
    directories: []
  },
  {
    root: 'core',
    files: ['Index.ets', 'hvigorfile.ts'],
    directories: ['src']
  },
  {
    root: 'core/src/main/ets',
    directories: [
      'connection',
      'diagnostics',
      'driver',
      'execution',
      'metadata',
      'metrics',
      'model',
      'time'
    ]
  },
  {
    root: 'mysql',
    files: ['Index.ets', 'hvigorfile.ts'],
    directories: ['src']
  },
  {
    root: 'mysql/src/main/ets',
    directories: ['mysql']
  },
  {
    root: 'mysql/src/main/ets/mysql',
    files: ['MySqlConnection.ets'],
    directories: [
      'api',
      'auth',
      'command',
      'connection',
      'diagnostics',
      'driver',
      'execution',
      'features',
      'model',
      'protocol',
      'transport',
      'value'
    ]
  },
  {
    root: 'mysql/src/main/ets/mysql/features',
    directories: MYSQL_FEATURE_DIRECTORIES
  },
  {
    root: 'pgsql',
    files: ['Index.ets', 'hvigorfile.ts'],
    directories: ['src']
  },
  {
    root: 'pgsql/src/main/ets',
    directories: ['pgsql']
  },
  {
    root: 'pgsql/src/main/ets/pgsql',
    files: ['PostgresConnection.ets'],
    directories: ['api', 'auth', 'driver', 'execution', 'features', 'model', 'protocol', 'transport', 'value']
  },
  {
    root: 'pgsql/src/main/ets/pgsql/features',
    directories: ['prepared']
  },
  {
    root: 'tools',
    files: ROOT_TOOL_FILES.map((file) => file.slice('tools/'.length)),
    directories: OWNED_TOOL_DIRECTORIES
  }
];
const MYSQL_VERTICAL_FEATURES = [
  'session',
  'transaction',
  'named',
  'procedure',
  'batch',
  'insert',
  'metadata',
  'metrics'
];
const MYSQL_VERTICAL_CONTRACTS = [
  'session/MySqlSessionOptions\\.ets',
  'transaction/MySqlTransactionOptions\\.ets',
  'named/MySqlNamedParameter\\.ets',
  'procedure/MySqlProcedure\\.ets',
  'batch/MySqlBatch\\.ets',
  'insert/MySqlInsertRows\\.ets',
  'metrics/(?:MySqlMetricsProvider|MySqlServerMetrics)\\.ets'
].join('|');
const MYSQL_FEATURE_CONTRACT_MODELS = [
  'batch/MySqlBatch\\.ets',
  'cursor/MySqlCursorOptions\\.ets',
  'insert/MySqlInsertRows\\.ets',
  'longdata/(?:MySqlByteSource|MySqlLongDataOptions)\\.ets',
  'metrics/(?:MySqlMetricsProvider|MySqlServerMetrics)\\.ets',
  'named/MySqlNamedParameter\\.ets',
  'prepared/MySqlParameter\\.ets',
  'procedure/MySqlProcedure\\.ets',
  'session/MySqlSessionOptions\\.ets',
  'transaction/MySqlTransactionOptions\\.ets'
].join('|');
const MYSQL_CONTRACT_MODEL_PATH = new RegExp(
  '^mysql/src/main/ets/mysql/' +
  '(?:model/.+\\.ets|features/(?:' + MYSQL_FEATURE_CONTRACT_MODELS +
  ')|protocol/Constants\\.ets)$'
);
const MYSQL_NON_LEAF_IMPLEMENTATION_PATH = new RegExp(
  '^mysql/src/main/ets/mysql/' +
  '(?!(?:model/.+\\.ets|features/(?:' + MYSQL_FEATURE_CONTRACT_MODELS +
  ')|protocol/Constants\\.ets)$).+'
);
const MYSQL_VERTICAL_FEATURE_PATTERN = MYSQL_VERTICAL_FEATURES.join('|');
const MYSQL_VERTICAL_IMPLEMENTATION_PATH = new RegExp(
  '^mysql/src/main/ets/mysql/features/' +
  '(?!(?:' + MYSQL_VERTICAL_CONTRACTS + ')$)' +
  '(?:' + MYSQL_VERTICAL_FEATURE_PATTERN + ')/'
);
const FORBIDDEN_MYSQL_LEGACY_PRODUCTION_PATHS = [
  'mysql/src/main/ets/mysql/driver/MySqlConnectionFeatures.ets',
  'mysql/src/main/ets/mysql/driver/MySqlContracts.ets',
  'mysql/src/main/ets/mysql/driver/MySqlCursorContracts.ets',
  'mysql/src/main/ets/mysql/driver/MySqlPreparedContracts.ets',
  'mysql/src/main/ets/mysql/driver/MySqlSession.ets',
  'mysql/src/main/ets/mysql/execution/MySqlBatchSupport.ets',
  'mysql/src/main/ets/mysql/command/PrepareResponse.ets',
  'mysql/src/main/ets/mysql/command/PreparedExecutor.ets',
  'mysql/src/main/ets/mysql/command/PreparedStatement.ets',
  'mysql/src/main/ets/mysql/execution/MySqlStatementCache.ets',
  'mysql/src/main/ets/mysql/model/MySqlParameter.ets',
  'mysql/src/main/ets/mysql/value/BinaryParameterEncoder.ets',
  'mysql/src/main/ets/mysql/value/BinaryRowDecoder.ets'
];

function mysqlSiblingImplementationPath(owner) {
  return new RegExp(
    '^mysql/src/main/ets/mysql/features/(?!' + owner +
    '/)(?!(?:' + MYSQL_VERTICAL_CONTRACTS + ')$)' +
    '(?:' + MYSQL_VERTICAL_FEATURE_PATTERN + ')/');
}

function mysqlSiblingImplementationRule(owner) {
  return {
    from: new RegExp(
      '^mysql/src/main/ets/mysql/features/' + owner + '/'),
    to: mysqlSiblingImplementationPath(owner),
    transitive: true,
    message: 'MySQL feature ownership must not depend on sibling implementations.'
  };
}

function assertFeatureOwnership(graph, owner, productionMoves, testMoves) {
  for (const [legacy, owned] of productionMoves) {
    assert.equal(graph.files.includes(legacy), false,
      `${owner} still has a legacy production owner: ${legacy}`);
    assert.equal(graph.files.includes(owned), true,
      `${owner} is missing its production owner: ${owned}`);
  }
  for (const [legacy, owned] of testMoves) {
    assert.equal(existsSync(join(ROOT, ...legacy.split('/'))), false,
      `${owner} still has a legacy test owner: ${legacy}`);
    assert.equal(existsSync(join(ROOT, ...owned.split('/'))), true,
      `${owner} is missing its test owner: ${owned}`);
  }
}

const FORBIDDEN_MYSQL_CURSOR_PATHS = [
  'mysql/src/main/ets/mysql/command/MySqlCursor.ets',
  'mysql/src/main/ets/mysql/model/MySqlCursorOptions.ets',
  'mysql/src/test/mysql/command/MySqlCursor.test.ets'
];
const FORBIDDEN_MYSQL_LONG_DATA_PATHS = [
  'mysql/src/main/ets/mysql/command/LongData.ets',
  'mysql/src/main/ets/mysql/model/MySqlByteSource.ets',
  'mysql/src/main/ets/mysql/model/MySqlLongDataOptions.ets',
  'mysql/src/main/ets/mysql/transport/MySqlUploadPump.ets',
  'mysql/src/test/mysql/command/LongData.test.ets',
  'mysql/src/test/mysql/transport/MySqlUploadPump.test.ets'
];
const POSTGRES_LEAF_PATTERN =
  '(?:model/.+\\.ets|features/prepared/PostgresParameter\\.ets|' +
  'protocol/PostgresProtocolConstants\\.ets|value/PostgresTypeOids\\.ets)';
const POSTGRES_CONTRACT_MODEL_PATH =
  new RegExp('^pgsql/src/main/ets/pgsql/' + POSTGRES_LEAF_PATTERN + '$');
const POSTGRES_NON_LEAF_IMPLEMENTATION_PATH =
  new RegExp('^pgsql/src/main/ets/pgsql/(?!' + POSTGRES_LEAF_PATTERN + '$).+');
const ARCHITECTURE_POLICY = {
  forbiddenSources: FORBIDDEN_MYSQL_LEGACY_PRODUCTION_PATHS,
  ownedSourceRoots: OWNED_SOURCE_ROOTS,
  prohibitedDependencies: [
    {
      from: /^core\//,
      to: /^mysql\//,
      message: 'Shared core must not depend on the MySQL driver.'
    },
    {
      from: /^core\//,
      to: /^pgsql\//,
      message: 'Shared core must not depend on database drivers.'
    },
    {
      from: /^mysql\//,
      to: /^pgsql\//,
      transitive: true,
      message: 'Database drivers must not depend on sibling drivers.'
    },
    {
      from: /^pgsql\//,
      to: /^mysql\//,
      transitive: true,
      message: 'Database drivers must not depend on sibling drivers.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/value\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/(?!(?:value|model|protocol)\/).+/,
      transitive: true,
      message: 'PostgreSQL value codecs may depend only on value, model, and protocol leaves.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/api\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/(?!(?:api\/|model\/|features\/prepared\/PostgresParameter\.ets$)).+/,
      message: 'PostgreSQL api may import only contract and model leaves.'
    },
    {
      from: POSTGRES_CONTRACT_MODEL_PATH,
      to: POSTGRES_NON_LEAF_IMPLEMENTATION_PATH,
      transitive: true,
      message: 'PostgreSQL contract and model leaves must not depend on implementations.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/features\/prepared\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/transport\//,
      transitive: true,
      message: 'PostgreSQL prepared feature must not depend on byte transport implementations.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/(?:protocol|transport)\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/features\//,
      transitive: true,
      message: 'PostgreSQL protocol and byte transport must not depend on feature ownership.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/(?:protocol|transport)\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/(?:PostgresConnection\.ets$|driver\/|execution\/)/,
      transitive: true,
      message: 'PostgreSQL protocol and byte transport must not depend on connection or execution ownership.'
    },
    {
      from: /^pgsql\/src\/main\/ets\/pgsql\/execution\//,
      to: /^pgsql\/src\/main\/ets\/pgsql\/(?:PostgresConnection\.ets$|driver\/)/,
      transitive: true,
      message: 'PostgreSQL execution primitives must not depend on connection or driver facades.'
    },
    {
      from: /^mysql\/src\/main\/ets\/mysql\/api\//,
      to: new RegExp(
        '^mysql/src/main/ets/mysql/' +
        '(?!(?:api/|model/|features/(?:' + MYSQL_FEATURE_CONTRACT_MODELS + ')$)).+'
      ),
      message: 'MySQL api may import only contract and model leaves.'
    },
    {
      from: MYSQL_CONTRACT_MODEL_PATH,
      to: MYSQL_NON_LEAF_IMPLEMENTATION_PATH,
      transitive: true,
      message: 'MySQL contract and model leaves must not depend on implementations.'
    },
    {
      from: /^mysql\/src\/main\/ets\/mysql\/features\/(?:prepared|cursor|longdata)\//,
      to: MYSQL_VERTICAL_IMPLEMENTATION_PATH,
      transitive: true,
      message: 'MySQL protocol feature cluster must not depend on vertical feature implementations.'
    },
    ...MYSQL_VERTICAL_FEATURES.map(mysqlSiblingImplementationRule),
    {
      from: /^mysql\/src\/main\/ets\/mysql\/(?:protocol|transport)\//,
      to: /^mysql\/src\/main\/ets\/mysql\/features\//,
      message: 'MySQL protocol and byte transport must not depend on feature ownership.'
    },
    ...TOOL_LAYER_RULES
  ]
};

async function fixture(t, files) {
  const root = await mkdtemp(join(tmpdir(), 'arkdb-architecture-'));
  t.after(() => import('node:fs/promises').then(({ rm }) =>
    rm(root, { recursive: true, force: true })));
  for (const [file, source] of Object.entries(files)) {
    const target = join(root, ...file.split('/'));
    await mkdir(dirname(target), { recursive: true });
    await writeFile(target, source);
  }
  return root;
}

function testOwnedSourceRoots(files) {
  const roots = new Map();
  for (const file of files) {
    const parts = file.split('/');
    const root = parts.length === 1 ? '' : parts[0];
    const path = parts.length === 1 ? parts : parts.slice(1);
    const ownership = roots.get(root) ?? {
      root,
      files: new Set(),
      directories: new Set()
    };
    roots.set(root, ownership);
    if (path.length === 1) ownership.files.add(path[0]);
    else ownership.directories.add(path[0]);
  }
  return [...roots.values()].map((entry) => ({
    root: entry.root,
    files: [...entry.files].sort(),
    directories: [...entry.directories].sort()
  }));
}

function assertTestPolicy(graph, policy = {}) {
  assertImportPolicy(graph, {
    ownedSourceRoots: testOwnedSourceRoots(graph.files),
    ...policy
  });
}

test('reports the current architecture with no import cycles', () => {
  const graph = readArkTsGraph(ROOT);

  assert.deepEqual(stronglyConnectedFiles(graph), []);
  assert.doesNotThrow(() => assertImportPolicy(graph, ARCHITECTURE_POLICY));
});

test('includes workspace and package Hvigor entry points in the tooling graph', () => {
  const graph = readArkTsGraph(ROOT);

  for (const file of [
    'hvigorfile.ts',
    'core/hvigorfile.ts',
    'mysql/hvigorfile.ts',
    'pgsql/hvigorfile.ts'
  ]) {
    assert.equal(graph.files.includes(file), true, `Missing build tooling source: ${file}`);
  }
});

test('P04, P07, P08, P09, P12A, P14, and P17 own exactly the registered PostgreSQL primitive sources', () => {
  const graph = readArkTsGraph(ROOT);

  assert.deepEqual(graph.files.filter((file) => file.startsWith('pgsql/')).sort(), [
    'pgsql/Index.ets',
    'pgsql/hvigorfile.ts',
    'pgsql/src/main/ets/pgsql/PostgresConnection.ets',
    'pgsql/src/main/ets/pgsql/api/PostgresContracts.ets',
    'pgsql/src/main/ets/pgsql/api/PostgresPreparedContracts.ets',
    'pgsql/src/main/ets/pgsql/auth/PostgresAuthCrypto.ets',
    'pgsql/src/main/ets/pgsql/auth/PostgresSaslPrep.ets',
    'pgsql/src/main/ets/pgsql/driver/PostgresDriverFactory.ets',
    'pgsql/src/main/ets/pgsql/execution/PostgresCommandGate.ets',
    'pgsql/src/main/ets/pgsql/execution/PostgresSettlements.ets',
    'pgsql/src/main/ets/pgsql/features/prepared/PostgresParameter.ets',
    'pgsql/src/main/ets/pgsql/features/prepared/PostgresParameterEncoder.ets',
    'pgsql/src/main/ets/pgsql/model/PostgresConnectionConfig.ets',
    'pgsql/src/main/ets/pgsql/model/PostgresModels.ets',
    'pgsql/src/main/ets/pgsql/protocol/PostgresByteCodec.ets',
    'pgsql/src/main/ets/pgsql/protocol/PostgresMessageChannel.ets',
    'pgsql/src/main/ets/pgsql/protocol/PostgresProtocolConstants.ets',
    'pgsql/src/main/ets/pgsql/transport/PostgresCertificateDer.ets',
    'pgsql/src/main/ets/pgsql/transport/PostgresDer.ets',
    'pgsql/src/main/ets/pgsql/transport/PostgresTcpTransport.ets',
    'pgsql/src/main/ets/pgsql/value/PostgresTextValueDecoder.ets',
    'pgsql/src/main/ets/pgsql/value/PostgresTypeOids.ets'
  ]);
});

test('R08 session feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'session', [
    [
      'mysql/src/main/ets/mysql/model/MySqlSessionOptions.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets'
    ],
    [
      'mysql/src/main/ets/mysql/model/MySqlContext.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlContext.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlSessionController.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionController.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlSessionInitialization.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionInitialization.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/connection/MySqlSessionInitialization.test.ets',
      'mysql/src/test/mysql/features/session/MySqlSessionInitialization.test.ets'
    ],
    [
      'mysql/src/test/mysql/connection/MySqlSessionReset.test.ets',
      'mysql/src/test/mysql/features/session/MySqlSessionReset.test.ets'
    ]
  ]);
});

test('metadata context normalization does not import session implementation ownership', () => {
  const graph = readArkTsGraph(ROOT);
  const legacy = 'mysql/src/main/ets/mysql/metadata/MySqlMetadataProvider.ets';
  const owned = 'mysql/src/main/ets/mysql/features/metadata/MySqlMetadataProvider.ets';
  const provider = graph.files.includes(owned) ? owned : legacy;

  assert.equal(graph.files.includes(provider), true);
  assert.equal(
    graph.dependencies[provider].includes(
      'mysql/src/main/ets/mysql/features/session/MySqlContext.ets'),
    false,
    'Metadata must own its context normalization instead of importing session implementation.'
  );
});

test('R08 transaction feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'transaction', [
    [
      'mysql/src/main/ets/mysql/model/MySqlTransactionOptions.ets',
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionOptions.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlTransactionRunner.ets',
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionRunner.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/execution/MySqlTransactionRunner.test.ets',
      'mysql/src/test/mysql/features/transaction/MySqlTransactionLifecycle.test.ets'
    ]
  ]);
});

test('R08 named feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'named', [
    [
      'mysql/src/main/ets/mysql/model/MySqlNamedParameter.ets',
      'mysql/src/main/ets/mysql/features/named/MySqlNamedParameter.ets'
    ],
    [
      'mysql/src/main/ets/mysql/value/SqlTemplateScanner.ets',
      'mysql/src/main/ets/mysql/features/named/SqlTemplateScanner.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlNamedExecutor.ets',
      'mysql/src/main/ets/mysql/features/named/MySqlNamedExecutor.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/value/SqlTemplateScanner.test.ets',
      'mysql/src/test/mysql/features/named/SqlTemplateScanner.test.ets'
    ],
    [
      'mysql/src/test/mysql/execution/MySqlNamedExecutor.test.ets',
      'mysql/src/test/mysql/features/named/MySqlNamedExecutor.test.ets'
    ]
  ]);
});

test('R08 procedure feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'procedure', [
    [
      'mysql/src/main/ets/mysql/model/MySqlProcedure.ets',
      'mysql/src/main/ets/mysql/features/procedure/MySqlProcedure.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlProcedureCaller.ets',
      'mysql/src/main/ets/mysql/features/procedure/MySqlProcedureCaller.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/execution/MySqlProcedureCaller.test.ets',
      'mysql/src/test/mysql/features/procedure/MySqlProcedureCaller.test.ets'
    ]
  ]);
});

test('R08 batch feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'batch', [
    [
      'mysql/src/main/ets/mysql/model/MySqlBatch.ets',
      'mysql/src/main/ets/mysql/features/batch/MySqlBatch.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlBatchSupport.ets',
      'mysql/src/main/ets/mysql/features/batch/MySqlBatchSupport.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlBatchExecutor.ets',
      'mysql/src/main/ets/mysql/features/batch/MySqlBatchExecutor.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/execution/MySqlBatchExecutor.test.ets',
      'mysql/src/test/mysql/features/batch/MySqlBatchExecutor.test.ets'
    ]
  ]);
});

test('R08 insert feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'insert', [
    [
      'mysql/src/main/ets/mysql/model/MySqlInsertRows.ets',
      'mysql/src/main/ets/mysql/features/insert/MySqlInsertRows.ets'
    ],
    [
      'mysql/src/main/ets/mysql/execution/MySqlInsertRowsExecutor.ets',
      'mysql/src/main/ets/mysql/features/insert/MySqlInsertRowsExecutor.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/execution/MySqlInsertRowsExecutor.test.ets',
      'mysql/src/test/mysql/features/insert/MySqlInsertRowsExecutor.test.ets'
    ]
  ]);
});

test('R08 metadata feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'metadata', [
    [
      'mysql/src/main/ets/mysql/metadata/MySqlMetadataSql.ets',
      'mysql/src/main/ets/mysql/features/metadata/MySqlMetadataSql.ets'
    ],
    [
      'mysql/src/main/ets/mysql/metadata/MySqlMetadataProvider.ets',
      'mysql/src/main/ets/mysql/features/metadata/MySqlMetadataProvider.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/metadata/MySqlMetadataProvider.test.ets',
      'mysql/src/test/mysql/features/metadata/MySqlMetadataProvider.test.ets'
    ]
  ]);
});

test('R08 metrics feature owns its vertical production and test files', () => {
  const graph = readArkTsGraph(ROOT);

  assertFeatureOwnership(graph, 'metrics', [
    [
      'mysql/src/main/ets/mysql/metrics/MySqlMetricsProvider.ets',
      'mysql/src/main/ets/mysql/features/metrics/MySqlMetricsProvider.ets'
    ],
    [
      'mysql/src/main/ets/mysql/metrics/MySqlServerMetrics.ets',
      'mysql/src/main/ets/mysql/features/metrics/MySqlServerMetrics.ets'
    ],
    [
      'mysql/src/main/ets/mysql/metrics/MySqlMetricsSql.ets',
      'mysql/src/main/ets/mysql/features/metrics/MySqlMetricsSql.ets'
    ],
    [
      'mysql/src/main/ets/mysql/metrics/MySqlServerMetricsProvider.ets',
      'mysql/src/main/ets/mysql/features/metrics/MySqlServerMetricsProvider.ets'
    ]
  ], [
    [
      'mysql/src/test/mysql/metrics/MySqlServerMetricsProvider.test.ets',
      'mysql/src/test/mysql/features/metrics/MySqlServerMetricsProvider.test.ets'
    ]
  ]);
});

test('rejects stale cursor ownership paths', () => {
  const stalePaths = FORBIDDEN_MYSQL_CURSOR_PATHS.filter((path) =>
    existsSync(join(ROOT, ...path.split('/'))));

  assert.deepEqual(stalePaths, []);
});

test('rejects stale long-data ownership paths', () => {
  const stalePaths = FORBIDDEN_MYSQL_LONG_DATA_PATHS.filter((path) =>
    existsSync(join(ROOT, ...path.split('/'))));
  assert.deepEqual(stalePaths, []);
});

test('R12 tests use explicit production, fixture, consumer and acceptance ownership', () => {
  const required = [
    'core/src/test/fixtures/ReferenceAdapter.ets',
    'mysql/src/test/mysql/diagnostics/LoggerPrivacy.test.ets',
    'mysql/src/test/mysql/diagnostics/MySqlExecutionObserver.test.ets',
    'mysql/src/test/mysql/execution/cancellation/MySqlCancellationControl.test.ets',
    'mysql/src/test/mysql/execution/cancellation/MySqlCancellationCursor.test.ets',
    'mysql/src/test/mysql/execution/cancellation/MySqlCancellationPrepared.test.ets',
    'mysql/src/test/mysql/execution/cancellation/MySqlCancellationText.test.ets',
    'mysql/src/test/mysql/execution/cancellation/fixtures/MySqlCancellationFixture.ets',
    'mysql/src/test/mysql/features/cursor/MySqlCursorFetch.test.ets',
    'mysql/src/test/mysql/features/cursor/MySqlCursorLifecycle.test.ets',
    'mysql/src/test/mysql/features/cursor/MySqlCursorOpen.test.ets',
    'mysql/src/test/mysql/features/cursor/fixtures/MySqlCursorFixture.ets',
    'mysql/src/test/mysql/features/longdata/LongDataCancellation.test.ets',
    'mysql/src/test/mysql/features/longdata/LongDataEncoding.test.ets',
    'mysql/src/test/mysql/features/longdata/LongDataFailure.test.ets',
    'mysql/src/test/mysql/features/longdata/LongDataOwnership.test.ets',
    'mysql/src/test/mysql/features/longdata/fixtures/LongDataFixture.ets',
    'mysql/src/test/mysql/features/metrics/ServerMetrics.test.ets',
    'mysql/src/test/mysql/features/prepared/BinaryParameterEncoder.test.ets',
    'mysql/src/test/mysql/features/prepared/BinaryRowDecoder.test.ets',
    'mysql/src/test/mysql/features/prepared/fixtures/PreparedExecutionFixture.ets',
    'mysql/src/test/mysql/features/prepared/fixtures/PreparedStatementFixture.ets',
    'mysql/src/test/mysql/features/prepared/fixtures/StatementCacheFixture.ets',
    'mysql/src/test/mysql/features/prepared/PreparedStatementClose.test.ets',
    'mysql/src/test/mysql/features/prepared/PreparedStatementMetadata.test.ets',
    'mysql/src/test/mysql/features/prepared/PreparedStatementOwnership.test.ets',
    'mysql/src/test/mysql/features/prepared/PreparedStatementValidation.test.ets',
    'mysql/src/test/mysql/features/prepared/StatementCacheCancellation.test.ets',
    'mysql/src/test/mysql/features/prepared/StatementCacheFailure.test.ets',
    'mysql/src/test/mysql/features/prepared/StatementCacheReuse.test.ets',
    'mysql/src/test/mysql/features/prepared/StatementCacheState.test.ets',
    'mysql/src/test/mysql/features/transaction/fixtures/MySqlTransactionFixture.ets',
    'mysql/src/test/mysql/features/transaction/MySqlTransactionCompletion.test.ets',
    'mysql/src/test/mysql/features/transaction/MySqlTransactionInsertRows.test.ets',
    'mysql/src/test/mysql/features/transaction/MySqlTransactionLifecycle.test.ets',
    'mysql/src/test/mysql/model/ConnectionConfig.test.ets',
    'mysql/src/test/mysql/protocol/fixtures/PacketTransportFixture.ets',
    'mysql/src/test/mysql/transport/TcpTransport.test.ets',
    'examples/mysql-client/entry/src/test/consumer/LegacyPublicInterface.test.ets',
    'examples/mysql-client/entry/src/test/consumer/PreparedPublicInterface.test.ets',
    'examples/mysql-client/entry/src/test/fixtures/public/LegacyCustomConnection.ets',
    'examples/mysql-client/entry/src/test/sample/SampleRunner.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/acceptance/DeviceAcceptanceRunner.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/evidence/DeviceReceiptClipboard.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/evidence/DeviceReceiptSigner.test.ets',
    'examples/postgres-client/entry/src/test/consumer/PublicInterface.test.ets'
  ];
  const forbidden = [
    'core/src/test/ReferenceAdapter.ets',
    'mysql/src/test/core',
    'mysql/src/test/core/List.test.ets',
    'mysql/src/test/mysql/command/PreparedExecutionFixture.ets',
    'mysql/src/test/mysql/command/PreparedExecute.test.ets',
    'mysql/src/test/mysql/command/PreparedStatement.test.ets',
    'mysql/src/test/mysql/command/PreparedStream.test.ets',
    'mysql/src/test/mysql/connection/MySqlExecutionObserver.test.ets',
    'mysql/src/test/mysql/execution/MySqlCancellation.test.ets',
    'mysql/src/test/mysql/execution/MySqlStatementCache.test.ets',
    'mysql/src/test/mysql/features/cursor/MySqlCursor.test.ets',
    'mysql/src/test/mysql/features/longdata/LongData.test.ets',
    'mysql/src/test/mysql/features/prepared/MySqlStatementCache.test.ets',
    'mysql/src/test/mysql/features/prepared/PreparedStatement.test.ets',
    'mysql/src/test/mysql/features/transaction/MySqlTransactionRunner.test.ets',
    'mysql/src/test/mysql/protocol/PacketTransportFixture.ets',
    'mysql/src/test/mysql/value/BinaryParameterEncoder.test.ets',
    'mysql/src/test/mysql/value/BinaryRowDecoder.test.ets',
    'examples/mysql-client/device-acceptance-cases.json',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceAcceptanceManifest.ets',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceAcceptanceRunner.ets',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceEvidenceBinding.ets',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceEvidenceIdentity.ets',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceReceiptClipboard.ets',
    'examples/mysql-client/entry/src/main/ets/sample/DeviceReceiptSigner.ets',
    'examples/mysql-client/entry/src/test/DeviceAcceptanceRunner.test.ets',
    'examples/mysql-client/entry/src/test/DeviceReceiptClipboard.test.ets',
    'examples/mysql-client/entry/src/test/DeviceReceiptSigner.test.ets',
    'examples/mysql-client/entry/src/test/LegacyPublicInterface.test.ets',
    'examples/mysql-client/entry/src/test/PreparedPublicInterface.test.ets',
    'examples/mysql-client/entry/src/test/SampleRunner.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/DeviceAcceptanceRunner.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/DeviceReceiptClipboard.test.ets',
    'examples/mysql-device-acceptance/entry/src/test/DeviceReceiptSigner.test.ets',
    'tools/artifact-channel.test.mjs',
    'tools/check-package.test.mjs',
    'tools/check-release.test.mjs',
    'tools/delivery-workspace.test.mjs',
    'tools/doc-examples.test.mjs',
    'tools/driver-packages.test.mjs',
    'tools/github-release.test.mjs',
    'tools/hap-content.test.mjs',
    'tools/har-consumer.test.mjs',
    'tools/legacy-release.test.mjs',
    'tools/package-har.test.mjs',
    'tools/prepare-har-release.test.mjs',
    'tools/publish-har.test.mjs',
    'tools/run-hvigor.test.mjs',
    'tools/shared-har.test.mjs',
    'tools/standalone-har.test.mjs',
    'tools/test-consumer.test.mjs',
    'tools/verify-device-evidence.test.mjs',
    'tools/verify-download.test.mjs'
  ];

  assert.deepEqual(required.filter((path) =>
    !existsSync(join(ROOT, ...path.split('/')))), []);
  assert.deepEqual(forbidden.filter((path) =>
    existsSync(join(ROOT, ...path.split('/')))), []);
});

test('reads static runtime and tooling imports without executing scanned source', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': "export { RuntimeA } from './src/main/ets/RuntimeA';",
    'core/src/main/ets/RuntimeA.ets': `
import { RuntimeB } from './RuntimeB';
export class RuntimeA {
  value: RuntimeB = new RuntimeB();
}
`,
    'core/src/main/ets/RuntimeB.ets': 'export class RuntimeB {}',
    'core/src/main/ets/RuntimeType.ets':
      "export type RuntimeType = import('./RuntimeB').RuntimeB;",
    'tools/a.mjs': `
import './b.mjs';
export { value } from './c.mjs';
throw new Error('scanned source was executed');
`,
    'tools/b.mjs': "export const sideEffect = 'static';",
    'tools/c.mjs': "export const value = 're-exported';",
    'tools/dynamic.mjs': "export const ignored = 'dynamic';",
    'tools/ignored.test.mjs': "import './a.mjs';",
    'oh_modules/generated/arkdb-package.json': '{"kind":"shared"}',
    'oh_modules/generated/oh-package.json5': "{name:'@arkdb/generated'}",
    'oh_modules/generated/Index.ets': "export { Generated } from './Generated';",
    'oh_modules/generated/Generated.ets': 'export class Generated {}',
    'tools/.test/generated.mjs': "import '../a.mjs';",
    'tools/.ohpm-cache/generated.mjs': "import '../a.mjs';",
    'tools/.tmp-generated/generated.mjs': "import '../a.mjs';"
  });

  const graph = readArkTsGraph(root);

  assert.deepEqual(graph.files, [
    'core/Index.ets',
    'core/src/main/ets/RuntimeA.ets',
    'core/src/main/ets/RuntimeB.ets',
    'core/src/main/ets/RuntimeType.ets',
    'tools/a.mjs',
    'tools/b.mjs',
    'tools/c.mjs',
    'tools/dynamic.mjs'
  ]);
  assert.deepEqual(graph.dependencies, {
    'core/Index.ets': ['core/src/main/ets/RuntimeA.ets'],
    'core/src/main/ets/RuntimeA.ets': ['core/src/main/ets/RuntimeB.ets'],
    'core/src/main/ets/RuntimeB.ets': [],
    'core/src/main/ets/RuntimeType.ets': ['core/src/main/ets/RuntimeB.ets'],
    'tools/a.mjs': ['tools/b.mjs', 'tools/c.mjs'],
    'tools/b.mjs': [],
    'tools/c.mjs': [],
    'tools/dynamic.mjs': []
  });
  assert.throws(() => assertTestPolicy(graph, {
    prohibitedDependencies: [{
      from: 'core/src/main/ets/RuntimeType.ets',
      to: 'core/src/main/ets/RuntimeB.ets',
      message: 'Static import types must reach policy enforcement.'
    }]
  }), /Static import types must reach policy enforcement/);
});

test('reads triple-slash runtime references as dependency edges', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': "export { RuntimeA } from './src/main/ets/RuntimeA';",
    'core/src/main/ets/RuntimeA.ets':
      "/// <reference path='RuntimeB.ets' />\nexport class RuntimeA {}",
    'core/src/main/ets/RuntimeB.ets': 'export class RuntimeB {}'
  });

  const graph = readArkTsGraph(root);

  assert.deepEqual(graph.dependencies['core/src/main/ets/RuntimeA.ets'], [
    'core/src/main/ets/RuntimeB.ets'
  ]);
});

test('reads the owned tools build layer but ignores nested generated build output', async (t) => {
  const root = await fixture(t, {
    'tools/build/package-har.mjs': "import '../lib/hash.mjs';",
    'tools/build/generated/ignored.mjs': 'export const generated = true;',
    'tools/lib/hash.mjs': 'export const sha256 = () => "hash";',
    'tools/workspace/build/ignored.mjs': 'export const generated = true;'
  });

  const graph = readArkTsGraph(root);

  assert.deepEqual(graph.files, [
    'tools/build/generated/ignored.mjs',
    'tools/build/package-har.mjs',
    'tools/lib/hash.mjs'
  ]);
  assert.deepEqual(graph.dependencies['tools/build/package-har.mjs'], [
    'tools/lib/hash.mjs'
  ]);
});

test('orders graph and cycle output independently of host locale collation', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './b.mjs';",
    'tools/b.mjs': "import './a.mjs';",
    'tools/c.mjs': 'export const value = 1;'
  });
  const localeCompare = String.prototype.localeCompare;
  String.prototype.localeCompare = function reverseOrdinal(other) {
    const right = String(other);
    return this < right ? 1 : this > right ? -1 : 0;
  };
  try {
    const graph = readArkTsGraph(root);
    assert.deepEqual(graph.files, ['tools/a.mjs', 'tools/b.mjs', 'tools/c.mjs']);
    assert.deepEqual(stronglyConnectedFiles(graph), [
      ['tools/a.mjs', 'tools/b.mjs']
    ]);
  } finally {
    String.prototype.localeCompare = localeCompare;
  }
});

test('rejects linked runtime and tooling source trees', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': 'export class Root {}',
    'core/src/main/ets/Runtime.ets': 'export class Runtime {}',
    'runtime-link-target/Linked.ets': 'export class Linked {}',
    'tools/a.mjs': 'export const value = 1;',
    'tool-link-target/linked.mjs': 'export const linked = true;'
  });
  const runtimeLink = join(root, 'core', 'src', 'main', 'ets', 'linked');
  await symlink(join(root, 'runtime-link-target'), runtimeLink,
    process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => readArkTsGraph(root), /symbolic link.*linked/i);
  await rm(runtimeLink, { recursive: true, force: true });

  const toolLink = join(root, 'tools', 'linked');
  await symlink(join(root, 'tool-link-target'), toolLink,
    process.platform === 'win32' ? 'junction' : 'dir');
  assert.throws(() => readArkTsGraph(root), /symbolic link.*linked/i);
});

test('rejects case-mismatched registered and fixed architecture paths', async (t) => {
  const registrationRoot = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./CORE'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': 'export class Root {}',
    'core/src/main/ets/Runtime.ets': 'export class Runtime {}'
  });
  assert.throws(() => readArkTsGraph(registrationRoot), /exact path case.*CORE/i);

  const entryRoot = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/index.ets': 'export class Root {}',
    'core/src/main/ets/Runtime.ets': 'export class Runtime {}'
  });
  assert.throws(() => readArkTsGraph(entryRoot), /exact path case.*Index\.ets/i);

  const toolsRoot = await fixture(t, {
    'TOOLS/a.mjs': 'export const value = 1;'
  });
  assert.throws(() => readArkTsGraph(toolsRoot), /exact path case.*tools/i);
});

test('rejects registered module roots inside generated directories', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./build/core'}]}",
    'build/core/arkdb-package.json': '{"kind":"shared"}',
    'build/core/oh-package.json5': "{name:'@arkdb/core'}",
    'build/core/Index.ets': 'export class Root {}',
    'build/core/src/main/ets/Runtime.ets': 'export class Runtime {}'
  });

  assert.throws(() => readArkTsGraph(root), /registered module.*ignored directory.*build/i);
});

test('rejects case-mismatched local imports instead of hiding their edges', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './B.mjs';",
    'tools/b.mjs': "import './a.mjs';"
  });

  assert.throws(() => readArkTsGraph(root), /exact import path case.*B\.mjs.*b\.mjs/i);
});

test('rejects unsupported CommonJS tooling instead of omitting require edges', async (t) => {
  const root = await fixture(t, {
    'tools/a.cjs': "require('./b.cjs');",
    'tools/b.cjs': "require('./a.cjs');"
  });

  assert.throws(() => readArkTsGraph(root), /Node tooling source.*a\.cjs.*\.mjs/i);
});

test('rejects JavaScript tooling whose package scope can be CommonJS', async (t) => {
  const root = await fixture(t, {
    'tools/commonjs/package.json': '{"type":"commonjs"}',
    'tools/commonjs/a.js': "require('./b.js');",
    'tools/commonjs/b.js': "require('./a.js');"
  });

  assert.throws(() => readArkTsGraph(root), /Node tooling source.*a\.js.*\.mjs/i);
});

test('rejects native TypeScript tooling outside the supported mjs seam', async (t) => {
  for (const suffix of ['mts', 'tsx', 'jsx']) {
    const root = await fixture(t, {
      [`tools/a.${suffix}`]: `import './b.${suffix}';`,
      [`tools/b.${suffix}`]: `import './a.${suffix}';`
    });

    assert.throws(() => readArkTsGraph(root),
      new RegExp(`Node tooling source.*a\\.${suffix}.*\\.mjs`, 'i'));
  }
});

test('rejects non-ArkTS package runtime source suffixes', async (t) => {
  for (const suffix of ['ts', 'tsx', 'jsx']) {
    const root = await fixture(t, {
      'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
      'core/arkdb-package.json': '{"kind":"shared"}',
      'core/oh-package.json5': "{name:'@arkdb/core'}",
      'core/Index.ets': 'export class Root {}',
      [`core/src/main/ets/Runtime.${suffix}`]: 'export class Runtime {}'
    });

    assert.throws(() => readArkTsGraph(root),
      new RegExp(`ArkDB runtime source.*Runtime\\.${suffix}.*lowercase \\.ets`, 'i'));
  }
});

test('does not hide package runtime sources in generated-name directories', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': 'export class Root {}',
    'core/src/main/ets/build/Hidden.ts': 'export class Hidden {}'
  });

  assert.throws(() => readArkTsGraph(root),
    /ArkDB runtime source.*build.*Hidden\.ts.*lowercase \.ets/i);
});

test('rejects case-drifted Node tooling source suffixes', async (t) => {
  const root = await fixture(t, {
    'tools/a.MJS': "import './b.mjs';",
    'tools/b.mjs': 'export const value = 1;'
  });

  assert.throws(() => readArkTsGraph(root), /Node tooling source.*a\.MJS.*lowercase \.mjs/i);
});

test('rejects createRequire tooling that can hide runtime dependency edges', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': `
import { createRequire } from 'node:module';
const require = createRequire(import.meta.url);
require('./b.mjs');
`,
    'tools/b.mjs': "import './a.mjs';"
  });

  assert.throws(() => readArkTsGraph(root), /createRequire.*not supported.*a\.mjs/i);
});

test('rejects getBuiltinModule tooling that can create a hidden require', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': `
const require = process.getBuiltinModule('module').createRequire(import.meta.url);
require('./b.mjs');
`,
    'tools/b.mjs': "import './a.mjs';"
  });

  assert.throws(() => readArkTsGraph(root), /getBuiltinModule.*not supported.*a\.mjs/i);
});

test('rejects every computed process access without binding ambiguity', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': `
const key = 'safe';
(process)[key];
`,
    'tools/b.mjs': "import './a.mjs';"
  });
  const source = join(root, 'tools', 'a.mjs');
  assert.throws(() => readArkTsGraph(root), /computed process access.*not supported.*a\.mjs/i);

  await writeFile(source, `
const key = 'safe';
(globalThis.process)[key];
`);
  assert.throws(() => readArkTsGraph(root),
    /computed globalThis access.*not supported.*a\.mjs/i);

  await writeFile(source, `
const process = { safe: true };
const key = 'safe';
process[key];
`);
  assert.throws(() => readArkTsGraph(root), /computed process access.*not supported.*a\.mjs/i);

  await writeFile(source, `
const require = globalThis['process']['getBuiltinModule']('module')
  .createRequire(import.meta.url);
require('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /(?:computed globalThis access|getBuiltinModule).*not supported.*a\.mjs/i);

  await writeFile(source, `
const require = globalThis['pro' + 'cess']['getBuiltin' + 'Module']('module')
  .createRequire(import.meta.url);
require('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /(?:computed globalThis access|getBuiltinModule).*not supported.*a\.mjs/i);

  await writeFile(source, `
const processAlias = globalThis.process;
const require = processAlias['getBuiltin' + 'Module']('module')
  .createRequire(import.meta.url);
require('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /process aliases.*not supported.*a\.mjs/i);

  await writeFile(source, `
import processAlias from 'node:process';
const require = processAlias['getBuiltin' + 'Module']('module')
  .createRequire(import.meta.url);
require('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /process module imports.*not supported.*a\.mjs/i);

  await writeFile(source, `
Reflect.get(process, 'getBuiltin' + 'Module')('module')
  .createRequire(import.meta.url)('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /reflective access.*not supported.*a\.mjs/i);

  await writeFile(source, `
const ReflectAlias = Reflect;
const processAlias = ReflectAlias.get(globalThis, 'process');
const getBuiltin = ReflectAlias.get(processAlias, 'getBuiltinModule');
const createRequire = ReflectAlias.get(getBuiltin('module'), 'createRequire');
createRequire(import.meta.url)('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /reflective aliases.*not supported.*a\.mjs/i);

  await writeFile(source, `
const ReflectAlias = globalThis.Reflect;
const processAlias = ReflectAlias.get(globalThis, 'process');
const getBuiltin = ReflectAlias.get(processAlias, 'getBuiltinModule');
const createRequire = ReflectAlias.get(getBuiltin('module'), 'createRequire');
createRequire(import.meta.url)('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /reflective aliases.*not supported.*a\.mjs/i);

  await writeFile(source, `
const globalAlias = globalThis;
const processAlias = globalAlias['pro' + 'cess'];
const getBuiltin = processAlias['getBuiltin' + 'Module'];
getBuiltin('module').createRequire(import.meta.url)('./b.mjs');
`);
  assert.throws(() => readArkTsGraph(root),
    /globalThis aliases.*not supported.*a\.mjs/i);
});

test('rejects nested tooling package scopes that can create self-references', async (t) => {
  const root = await fixture(t, {
    'tools/local/Package.json': '{"name":"local-pkg","type":"module","exports":"./b.mjs"}',
    'tools/local/a.mjs': "import 'local-pkg';",
    'tools/local/b.mjs': "import './a.mjs';"
  });

  assert.throws(() => readArkTsGraph(root), /nested Node tooling package scope.*package\.json/i);
});

test('resolves Node static imports with query and hash suffixes', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './b.mjs?redirect=%2Ftmp';",
    'tools/b.mjs': "export { value } from './a.mjs#route=%5Ctmp'; export const value = 1;"
  });

  assert.deepEqual(stronglyConnectedFiles(readArkTsGraph(root)), [
    ['tools/a.mjs', 'tools/b.mjs']
  ]);
});

test('rejects noncanonical and implicit Node local specifiers', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './b';",
    'tools/b.mjs': 'export const value = 1;',
    'tools/.hidden/b.mjs': 'export const hidden = true;',
    'tools/directory/index.mjs': 'export const value = 1;'
  });
  const source = join(root, 'tools', 'a.mjs');
  assert.throws(() => readArkTsGraph(root), /must target \.mjs.*\.\/b/i);

  await writeFile(source, "import './directory';");
  assert.throws(() => readArkTsGraph(root),
    /must target \.mjs.*\.\/directory/i);

  await writeFile(source, "import 'file:.\/b.mjs';");
  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL.*file:.\/b\.mjs/i);

  await writeFile(source, "import '.hidden/b.mjs';");
  assert.throws(() => readArkTsGraph(root), /valid relative Node specifier.*\.hidden/i);

  for (const specifier of ['././b.mjs', './x/../b.mjs', './%2e/b.mjs']) {
    await writeFile(source, `import ${JSON.stringify(specifier)};`);
    assert.throws(() => readArkTsGraph(root), /noncanonical dot segment/i);
  }

  for (const specifier of ['./directory//index.mjs', './b%2emjs']) {
    await writeFile(source, `import ${JSON.stringify(specifier)};`);
    assert.throws(() => readArkTsGraph(root),
      /canonical relative \.mjs specifier|must target \.mjs/i);
  }
});

test('rejects noncanonical whitespace in file URL imports', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': 'export const pending = true;',
    'tools/b.mjs': 'export const value = 1;'
  });
  const target = pathToFileURL(join(root, 'tools', 'b.mjs')).href;
  const source = join(root, 'tools', 'a.mjs');
  await writeFile(source, `import ${JSON.stringify(` ${target}`)};`);
  assert.throws(() => readArkTsGraph(root), /canonical URL encoding/i);

  await writeFile(source, `import ${JSON.stringify(target.replace('file:', 'fi\tle:'))};`);
  assert.throws(() => readArkTsGraph(root), /canonical URL encoding/i);
});

test('rejects encoded Node path separators before filesystem conversion', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './a%5Cb.mjs';"
  });
  const source = join(root, 'tools', 'a.mjs');
  assert.throws(() => readArkTsGraph(root), /encoded path separator.*%5C/i);

  await writeFile(source, "import './a%2Fb.mjs';");
  assert.throws(() => readArkTsGraph(root), /encoded path separator.*%2F/i);
});

test('rejects local file URL imports outside the supported relative seam', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': 'export const pending = true;',
    'tools/b.mjs': "import './a.mjs';"
  });
  let target = pathToFileURL(join(root, 'tools', 'b.mjs')).href.replace(/^file:/, 'FILE:');
  if (process.platform === 'win32') {
    target = target.replace(/^FILE:\/\/\/([A-Z]):/, (_, drive) => `FILE:///${drive.toLowerCase()}:`);
  }
  await writeFile(join(root, 'tools', 'a.mjs'), `import ${JSON.stringify(target)};`);

  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL.*FILE:/i);
});

test('rejects noncanonical file URL aliases', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': 'export const pending = true;',
    'tools/b.mjs': 'export const value = 1;'
  });
  const source = join(root, 'tools', 'a.mjs');
  const target = pathToFileURL(join(root, 'tools', 'b.mjs')).href;
  await writeFile(source, `import ${JSON.stringify(target.replace('/b.mjs', '/./b.mjs'))};`);
  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL/i);

  const localhost = target.replace(/^file:\/\//, 'file://localhost');
  await writeFile(source, `import ${JSON.stringify(localhost)};`);
  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL/i);

  await writeFile(source, `import ${JSON.stringify(target.replace('/b.mjs', '/b%2emjs'))};`);
  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL/i);
});

test('keeps Node tooling dependencies separate from ArkTS sources', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': 'export class Root {}',
    'core/src/main/ets/Runtime.ets': 'export class Runtime {}',
    'tools/a.mjs': "import '../core/Index.ets';"
  });
  assert.throws(() => readArkTsGraph(root), /Node tooling imports must target \.mjs/i);

  await writeFile(join(root, 'tools', 'a.mjs'), "import '@arkdb/core';");
  assert.deepEqual(readArkTsGraph(root).dependencies['tools/a.mjs'], []);
});

test('rejects unresolved ArkTS imports except generated BuildProfile', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': 'export class Root {}',
    'core/src/main/ets/Runtime.ets': "import { Missing } from './Missing';"
  });
  assert.throws(() => readArkTsGraph(root), /Cannot resolve ArkTS architecture import.*\.\/Missing/);

  await writeFile(join(root, 'core', 'src', 'main', 'ets', 'Runtime.ets'),
    "import { Missing } from '@arkdb/core/Missing';");
  assert.throws(() => readArkTsGraph(root),
    /Cannot resolve ArkTS architecture import.*@arkdb\/core\/Missing/);

  await mkdir(join(root, 'core', 'src', 'main', 'ets', 'diagnostics'), { recursive: true });
  await writeFile(join(root, 'core', 'src', 'main', 'ets', 'Runtime.ets'),
    'export class Runtime {}');
  await writeFile(join(root, 'core', 'src', 'main', 'ets', 'diagnostics', 'Logger.ets'),
    "import Missing from '../../../../BuildProfile/Missing';");
  assert.throws(() => readArkTsGraph(root),
    /Cannot resolve ArkTS architecture import.*BuildProfile\/Missing/);

  await writeFile(join(root, 'core', 'src', 'main', 'ets', 'diagnostics', 'Logger.ets'),
    "import BuildProfile from '../../../../BuildProfile';");
  assert.deepEqual(readArkTsGraph(root).dependencies[
    'core/src/main/ets/diagnostics/Logger.ets'
  ], []);
});

test('rejects root package self-references that can resolve to tooling files', async (t) => {
  const root = await fixture(t, {
    'package.json': '{"name":"local-pkg","type":"module","exports":{"./b":"./tools/b.mjs"}}',
    'tools/a.mjs': "import 'local-pkg/b';",
    'tools/b.mjs': "import './a.mjs';"
  });

  assert.throws(() => readArkTsGraph(root), /root Node package self-reference.*local-pkg\/b/i);
});

test('rejects data modules that can hide local dependency edges', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': 'export const pending = true;',
    'tools/b.mjs': "import './a.mjs';"
  });
  const target = pathToFileURL(join(root, 'tools', 'b.mjs')).href;
  const data = `data:text/javascript,${encodeURIComponent(`import ${JSON.stringify(target)};`)}`;
  await writeFile(join(root, 'tools', 'a.mjs'), `import ${JSON.stringify(data)};`);

  assert.throws(() => readArkTsGraph(root), /unsupported absolute Node module URL.*data:/i);
});

test('rejects every import cycle without an exception mechanism', () => {
  const graph = {
    files: ['tools/new-a.mjs', 'tools/new-b.mjs'],
    dependencies: {
      'tools/new-a.mjs': ['tools/new-b.mjs'],
      'tools/new-b.mjs': ['tools/new-a.mjs']
    }
  };

  assert.throws(
    () => assertTestPolicy(graph),
    /Unexpected import cycle: tools\/new-a\.mjs -> tools\/new-b\.mjs/
  );
});

test('rejects obsolete cycle allowlist configuration', () => {
  const graph = {
    files: ['tools/only.mjs'],
    dependencies: { 'tools/only.mjs': [] }
  };

  assert.throws(
    () => assertImportPolicy(graph, { allowedCycles: [] }),
    /Cycle allowlists are not supported/
  );
});

test('rejects malformed and unknown architecture policy configuration', () => {
  const graph = {
    files: ['tools/only.mjs'],
    dependencies: { 'tools/only.mjs': [] }
  };

  assert.throws(
    () => assertImportPolicy(graph, []),
    /Architecture policy must be a plain object/
  );
  class Policy {}
  assert.throws(
    () => assertImportPolicy(graph, new Policy()),
    /Architecture policy must be a plain object/
  );
  class SpoofedPolicy {
    get __proto__() {
      return Object.prototype;
    }
  }
  assert.throws(
    () => assertImportPolicy(graph, new SpoofedPolicy()),
    /Architecture policy must be a plain object/
  );
  assert.throws(
    () => assertImportPolicy(graph, Object.create(null)),
    /Architecture policy must be a plain object/
  );
  assert.throws(
    () => assertImportPolicy(graph, { ownedSourceRoot: [] }),
    /Unknown architecture policy field: ownedSourceRoot/
  );
  assert.throws(
    () => assertTestPolicy(graph, {
      prohibitedDependencies: [{
        from: 'tools/only.mjs',
        to: 'tools/only.mjs',
        transitive: 'true'
      }]
    }),
    /Architecture dependency rule transitive must be boolean/
  );
});

test('requires every architecture policy to define source ownership', () => {
  const graph = {
    files: ['tools/only.mjs'],
    dependencies: { 'tools/only.mjs': [] }
  };

  assert.throws(
    () => assertImportPolicy(graph, {}),
    /Architecture policy must define nonempty owned source roots/
  );
});

test('rejects prohibited dependencies even when the graph is acyclic', () => {
  const graph = {
    files: ['core/Index.ets', 'mysql/Index.ets'],
    dependencies: {
      'core/Index.ets': ['mysql/Index.ets'],
      'mysql/Index.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /Shared core must not depend on the MySQL driver.*core\/Index\.ets -> mysql\/Index\.ets/
  );
});

test('rejects core-to-PostgreSQL and cross-driver dependencies', () => {
  for (const [source, target, message] of [
    ['core/Index.ets', 'pgsql/Index.ets',
      'Shared core must not depend on database drivers.'],
    ['mysql/Index.ets', 'pgsql/Index.ets',
      'Database drivers must not depend on sibling drivers.'],
    ['pgsql/Index.ets', 'mysql/Index.ets',
      'Database drivers must not depend on sibling drivers.']
  ]) {
    const graph = {
      files: ['core/Index.ets', 'mysql/Index.ets', 'pgsql/Index.ets'],
      dependencies: {
        'core/Index.ets': [],
        'mysql/Index.ets': [],
        'pgsql/Index.ets': [],
        [source]: [target]
      }
    };

    assert.throws(
      () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
      new RegExp(message.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))
    );
  }
});

test('rejects reverse tooling ownership imports', () => {
  for (const rule of TOOL_LAYER_RULES) {
    const from = {
      'Low-level tooling must not depend on root workflow or CLI modules.':
        'tools/lib/hash.mjs',
      'Tool lib must not depend on workflow layers.': 'tools/lib/hash.mjs',
      'Tool workspace ownership must not depend on higher workflow layers.':
        'tools/workspace/delivery-workspace.mjs',
      'Tool artifact primitives must not depend on workflow orchestration.':
        'tools/artifact/har-inspection.mjs',
      'Tool build ownership must not depend on downstream workflows.':
        'tools/build/package-har.mjs',
      'Tool consumer ownership must not depend on build, release, or device workflows.':
        'tools/consumer/test-consumer.mjs',
      'Tool release ownership must not depend on build or device workflows.':
        'tools/release/prepare-har-release.mjs',
      'Tool device ownership must not depend on build orchestration.':
        'tools/device/verifier.mjs',
      'Tool device ownership may depend only on sealed release contracts.':
        'tools/device/challenge.mjs',
      'Tool device ownership may depend only on sealed consumer evidence contracts.':
        'tools/device/harness.mjs'
    }[rule.message];
    const to = {
      'Low-level tooling must not depend on root workflow or CLI modules.':
        'tools/check-package.mjs',
      'Tool lib must not depend on workflow layers.': 'tools/build/package-har.mjs',
      'Tool workspace ownership must not depend on higher workflow layers.':
        'tools/artifact/har-inspection.mjs',
      'Tool artifact primitives must not depend on workflow orchestration.':
        'tools/consumer/test-consumer.mjs',
      'Tool build ownership must not depend on downstream workflows.':
        'tools/release/prepare-har-release.mjs',
      'Tool consumer ownership must not depend on build, release, or device workflows.':
        'tools/build/package-har.mjs',
      'Tool release ownership must not depend on build or device workflows.':
        'tools/device/verifier.mjs',
      'Tool device ownership must not depend on build orchestration.':
        'tools/build/package-har.mjs',
      'Tool device ownership may depend only on sealed release contracts.':
        'tools/release/prepare-har-release.mjs',
      'Tool device ownership may depend only on sealed consumer evidence contracts.':
        'tools/consumer/test-consumer.mjs'
    }[rule.message];
    const graph = {
      files: [from, to],
      dependencies: { [from]: [to], [to]: [] }
    };

    assert.throws(() => assertTestPolicy(graph, {
      prohibitedDependencies: [rule]
    }), new RegExp(rule.message.replaceAll('.', '\\.')));
  }
});

test('rejects reverse tooling ownership imports through compatibility wrappers', () => {
  const graph = {
    files: [
      'tools/consumer/test-consumer.mjs',
      'tools/package-har.mjs',
      'tools/build/package-har.mjs'
    ],
    dependencies: {
      'tools/consumer/test-consumer.mjs': ['tools/package-har.mjs'],
      'tools/package-har.mjs': ['tools/build/package-har.mjs'],
      'tools/build/package-har.mjs': []
    }
  };
  const rule = TOOL_LAYER_RULES.find((candidate) =>
    candidate.message ===
    'Tool consumer ownership must not depend on build, release, or device workflows.');

  assert.throws(() => assertTestPolicy(graph, {
    prohibitedDependencies: [rule]
  }), /consumer\/test-consumer\.mjs -> tools\/package-har\.mjs -> tools\/build\/package-har\.mjs/);
});

test('rejects dynamic tooling imports instead of hiding ownership edges', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "void import('./b.mjs');",
    'tools/b.mjs': 'export const value = true;'
  });

  assert.throws(() => readArkTsGraph(root),
    /Dynamic Node imports are not supported.*tools.*a\.mjs/i);

  const source = join(root, 'tools', 'a.mjs');
  const overflowKey = Array.from({ length: 64 }, (_, index) =>
    `false ? 'safe${index}' : `).join('') + "'constructor'";
  for (const hidden of [
    "eval(\"import('./b.mjs')\");",
    "new Function(\"return import('./b.mjs')\")();",
    "Object.getPrototypeOf(async function () {}).constructor(" +
      "\"return import('./b.mjs')\")();",
    "function load(O) {\n" +
      "  O.getOwnPropertyDescriptor({}, 'constructor');\n" +
      "}\nload(Object);",
    "function getProto() {\n" +
      "  return Object.getPrototypeOf(async function () {});\n" +
      "}\ngetProto();",
    "const key = [];\n" +
      "key.push('constructor');\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "const key = 'constructor';\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "const key = `con${'structor'}`;\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "let key = 'constructor';\n" +
      "if (false) key = 'safe';\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "if (true) { var key = 'constructor'; }\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "const key = 'constructor';\n" +
      "function unused() { const key = 'safe'; }\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "let key = 'safe';\n" +
      "({})[key = 'constructor'][key](\"return import('./b.mjs')\")();",
    "let key = 'con';\n" +
      "key += 'structor';\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "let key = 'con';\n" +
      "key += 'structor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let key = 'con';\n" +
      "key = key + 'structor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let key = '';\n" +
      "key ||= 'constructor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = '' || 'constructor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const [key] = ['constructor'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let key;\n" +
      "[key] = ['constructor'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let key = 'safe';\n" +
      "[, key] = [...['safe', 'constructor'], 'safe'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const names = ['constructor'];\n" +
      "let key;\n" +
      "[key] = names;\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const override = { key: 'constructor' };\n" +
      "const { key } = { key: 'safe', ...override };\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "function load(key = 'constructor') {\n" +
      "  return ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}\nload();",
    "function load(key) {\n" +
      "  return ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "function load(key = 'safe') {\n" +
      "  return ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "function load(key = 'safe') {\n" +
      "  const Loader = ({})[key][key];\n" +
      "  return Loader(\"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "function load(key) {\n" +
      "  const proto = ({})[key];\n" +
      "  const Loader = proto[key];\n" +
      "  return Loader(\"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "const key = ['con', 'structor'].join('');\n" +
      "const object = {};\n" +
      "const ObjectCtor = object[key];\n" +
      "const Loader = ObjectCtor[key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = (() => 'constructor')();\n" +
      "const holder = { proto: ({})[key] };\n" +
      "const Loader = holder.proto[key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "function load(key) {\n" +
      "  const Loader = ((async function () {})[key] as any);\n" +
      "  return Loader(\"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "function load(key) {\n" +
      "  return ({})[key][key].call(" +
      "null, \"return import('./b.mjs')\")();\n" +
      "}\nload('constructor');",
    "let key = false;\n" +
      "key = key || 'constructor';\n" +
      "({})[key][key](\"return import('./b.mjs')\")();",
    "const key = 'constructor';\n" +
      "function load(alias = key) {\n" +
      "  var key = 'safe';\n" +
      "  return ({})[alias][alias](\"return import('./b.mjs')\")();\n" +
      "}\nload();",
    "const { 'constructor': Loader } = " +
      "Object.getPrototypeOf(async function () {});\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = 'constructor';\n" +
      "const { [key]: Loader } = " +
      "Object.getPrototypeOf(async function () {});\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = 'constructor';\n" +
      "let Loader;\n" +
      "({ [key]: Loader } = " +
      "Object.getPrototypeOf(async function () {}));\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = ['constructor'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const [unused, key] = [...['safe', 'constructor'], 'safe'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const key = ['safe'];\n" +
      "key[0] = 'constructor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const [...[, key]] = [[0, 'safe'], 'constructor'];\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "for (const key of ['constructor']) {\n" +
      "  ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}",
    "let key = 'safe';\n" +
      "for (key of ['constructor']) {\n" +
      "  ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}",
    "let key = 'safe';\n" +
      "for (key of ['safe', ...['constructor']]) {\n" +
      "  ({})[key][key](\"return import('./b.mjs')\")();\n" +
      "}",
    "const key = 'constructor';\n" +
      "let Loader = () => undefined;\n" +
      "for ({ [key]: Loader } of [" +
      "Object.getPrototypeOf(async function () {})]) {\n" +
      "  Loader(\"return import('./b.mjs')\")();\n" +
      "}",
    "const { constructor } = " +
      "Object.getPrototypeOf(async function () {});\n" +
      "constructor(\"return import('./b.mjs')\")();",
    "const Loader = Object.getOwnPropertyDescriptor(" +
      "Object.getPrototypeOf(async function () {}), 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const Loader = Object.getOwnPropertyDescriptor.call(" +
      "Object, Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const api = 'getOwnPropertyDescriptor';\n" +
      "const Loader = Object[api](" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const { getOwnPropertyDescriptor: descriptor } = Object;\n" +
      "const Loader = descriptor(" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const O = Object;\n" +
      "const Loader = O.getOwnPropertyDescriptor(" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let O;\n" +
      "O = Object;\n" +
      "const Loader = O.getOwnPropertyDescriptor(" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let O;\n" +
      "O = Object;\n" +
      "const descriptor = O.getOwnPropertyDescriptor;\n" +
      "const proto = O.getPrototypeOf(async function () {});\n" +
      "const Loader = descriptor(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const member = 'getOwnPropertyDescriptor';\n" +
      "const descriptor = Object[member];\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = descriptor(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const descriptor = Object.getOwnPropertyDescriptor.bind(Object);\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = descriptor(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let descriptor = Object.getOwnPropertyDescriptors;\n" +
      "if (false) descriptor = Object.getOwnPropertyDescriptor;\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const descriptors = descriptor(proto);\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const plural = true;\n" +
      "const member = plural ? " +
      "'getOwnPropertyDescriptors' : 'getOwnPropertyDescriptor';\n" +
      "const descriptor = Object[member];\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const descriptors = descriptor(proto);\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const holder = { d: Object.getOwnPropertyDescriptor };\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = holder.d(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const d = Object.getOwnPropertyDescriptor;\n" +
      "const holder = { d };\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = holder.d(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "class Holder {\n" +
      "  constructor(d) { this.d = d; }\n" +
      "}\n" +
      "const holder = new Holder(Object.getOwnPropertyDescriptor);\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = holder.d(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let O;\n" +
      "let getProto;\n" +
      "let descriptor;\n" +
      "[O, getProto, descriptor] = [" +
      "Object, Object.getPrototypeOf, Object.getOwnPropertyDescriptor];\n" +
      "const proto = getProto(async function () {});\n" +
      "const Loader = descriptor(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let getProto;\n" +
      "[, getProto] = [...[null, Object.getPrototypeOf], null];\n" +
      "const proto = getProto(async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let O;\n" +
      "let getProto;\n" +
      "let descriptor;\n" +
      "[, O, getProto, descriptor] = [...[" +
      "null, Object, Object.getPrototypeOf, " +
      "Object.getOwnPropertyDescriptor], null];\n" +
      "const proto = getProto(async function () {});\n" +
      "const Loader = descriptor(proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "function load(" +
      "descriptor = Object.getOwnPropertyDescriptor, " +
      "proto = Object.getPrototypeOf(async function () {})) {\n" +
      "  var Object = { safe: true };\n" +
      "  const Loader = descriptor(proto, 'constructor').value;\n" +
      "  Loader(\"return import('./b.mjs')\")();\n" +
      "}\nload();",
    "function load({" +
      "descriptor = Object.getOwnPropertyDescriptor, " +
      "proto = Object.getPrototypeOf(async function () {})" +
      "} = {}) {\n" +
      "  const Loader = descriptor(proto, 'constructor').value;\n" +
      "  Loader(\"return import('./b.mjs')\")();\n" +
      "}\nload();",
    "let a = Object.getOwnPropertyDescriptor;\n" +
      "let b = Object.getOwnPropertyDescriptor;\n" +
      "let c = Object.getOwnPropertyDescriptor;\n" +
      "function step() {\n" +
      "  c = b;\n  b = a;\n" +
      "  a = Object.getOwnPropertyDescriptors;\n" +
      "}\nstep();\nstep();\nstep();\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const descriptors = c(proto);\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const member = 'getPrototypeOf';\n" +
      "const proto = Object[member](async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const getProto = Object.getPrototypeOf;\n" +
      "const proto = getProto(async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const proto = Object.getPrototypeOf.call(" +
      "Object, async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const proto = Object.getPrototypeOf.apply(" +
      "Object, [async function () {}]);\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const getProto = Object.getPrototypeOf.bind(Object);\n" +
      "const proto = getProto(async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const O = Object;\n" +
      "const proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = O.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const O = Object;\n" +
      "const proto = O.getPrototypeOf(async function () {});\n" +
      "const Loader = O.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let proto;\n" +
      "proto = Object.getPrototypeOf(async function () {});\n" +
      "const Loader = Object.getOwnPropertyDescriptor(" +
      "proto, 'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const Loader = Object.getOwnPropertyDescriptor.apply(Object, [" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor']).value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const wrapper = true ? 'call' : 'apply';\n" +
      "const Loader = Object.getOwnPropertyDescriptor[wrapper](" +
      "Object, [Object.getPrototypeOf(async function () {}), " +
      "'constructor']).value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const args = [Object.getPrototypeOf(async function () {}), " +
      "'constructor'];\n" +
      "const Loader = Object.getOwnPropertyDescriptor.apply(" +
      "Object, [...args]).value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const O = Object;\n" +
      "const descriptors = O.getOwnPropertyDescriptors(" +
      "Object.getPrototypeOf(async function () {}));\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let O;\n" +
      "O = Object;\n" +
      "const descriptors = O.getOwnPropertyDescriptors(" +
      "Object.getPrototypeOf(async function () {}));\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const descriptors = Object.getOwnPropertyDescriptors.apply(Object, [" +
      "Object.getPrototypeOf(async function () {})]);\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let descriptor;\n" +
      "({ holder: { ['getOwnPropertyDescriptor']: descriptor } } = " +
      "{ holder: Object });\n" +
      "const Loader = descriptor(" +
      "Object.getPrototypeOf(async function () {}), " +
      "'constructor').value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "const descriptors = Object.getOwnPropertyDescriptors(" +
      "Object.getPrototypeOf(async function () {}));\n" +
      "const Loader = Object.values(descriptors)[0].value;\n" +
      "Loader(\"return import('./b.mjs')\")();",
    "let key = 'con';\n" +
      "key += 'structor';\n" +
      "const load = ({})[key][key]`return import('./b.mjs')`;\n" +
      "load();",
    `const key = ${overflowKey};\n` +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();",
    `const prefix = ${overflowKey.replace("'constructor'", "'con'")};\n` +
      "const key = prefix + 'structor';\n" +
      "const Loader = ({})[key][key];\n" +
      "Loader(\"return import('./b.mjs')\")();"
  ]) {
    await writeFile(source, hidden);
    assert.throws(() => readArkTsGraph(root),
      /Node code generation is not supported.*tools.*a\.mjs/i,
      hidden);
  }
});

test('allows benign indexed tooling writes and loop shadowing', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': `
const key = 'safe';
const values = {};
values[key] = () => true;
values[key]();
const counts = { safe: 0 };
counts[key] += 1;
const handlers = { safe: () => true };
handlers[key]();
for (const key of ['other']) {
  void key;
}
values[key]();
for (const key of ['safe']) {
  handlers[key]();
}
`
  });

  assert.doesNotThrow(() => readArkTsGraph(root));
});

test('rejects dynamic ArkTS imports instead of hiding runtime edges', async (t) => {
  const root = await fixture(t, {
    'build-profile.json5': "{modules:[{name:'core',srcPath:'./core'}]}",
    'core/arkdb-package.json': '{"kind":"shared"}',
    'core/oh-package.json5': "{name:'@arkdb/core'}",
    'core/Index.ets': "export { RuntimeA } from './src/main/ets/RuntimeA';",
    'core/src/main/ets/RuntimeA.ets': "void import('./RuntimeB');\nexport class RuntimeA {}",
    'core/src/main/ets/RuntimeB.ets': 'export class RuntimeB {}'
  });

  assert.throws(() => readArkTsGraph(root),
    /Dynamic ArkTS imports are not supported.*RuntimeA\.ets/i);
});

test('rejects Hvigor CommonJS loader syntax', async (t) => {
  const root = await fixture(t, {
    'hvigorfile.ts': "import nodeModule = require('node:module');\n" +
      "nodeModule.createRequire(import.meta.url)('./hidden.mjs');\n"
  });

  assert.throws(() => readArkTsGraph(root),
    /CommonJS|createRequire-capable module imports are not supported/i);

  await writeFile(join(root, 'hvigorfile.ts'),
    "module.require('./hidden.mjs');\n");
  assert.throws(() => readArkTsGraph(root),
    /CommonJS loader access is not supported/i);

  for (const source of [
    "require('./hidden.mjs');\n",
    "const load = require;\nload('./hidden.mjs');\n",
    "const load = (require);\nload('./hidden.mjs');\n",
    "const load = (require as NodeRequire);\nload('./hidden.mjs');\n",
    "const load = typeof require === 'function' ? require : undefined;\n" +
      "load?.('./hidden.mjs');\n",
    "const load = [require][0];\nload('./hidden.mjs');\n",
    "const load = require.bind(null);\nload('./hidden.mjs');\n",
    "const load = module.require.bind(module);\nload('./hidden.mjs');\n",
    "module!.require('./hidden.mjs');\n",
    "const moduleAlias = module;\nmoduleAlias.require('./hidden.mjs');\n",
    "const { ['require']: load } = module || {};\nload('./hidden.mjs');\n",
    "class Loader extends require {}\n" +
      "Object.getPrototypeOf(Loader)('./hidden.mjs');\n",
    "global.require('./hidden.mjs');\n",
    "global['require']('./hidden.mjs');\n",
    "global.module.require('./hidden.mjs');\n",
    "globalThis.require('./hidden.mjs');\n",
    "globalThis.module.require('./hidden.mjs');\n",
    "const moduleAlias = globalThis.module;\nmoduleAlias.require('./hidden.mjs');\n",
    "let moduleAlias;\nmoduleAlias ??= globalThis.module;\n" +
      "moduleAlias.require('./hidden.mjs');\n",
    "globalThis.module.createRequire(import.meta.url)('./hidden.mjs');\n",
    "let globalAlias;\nglobalAlias ??= globalThis;\n" +
      "globalAlias.require('./hidden.mjs');\n",
    "const globalAlias = global;\nglobalAlias.require('./hidden.mjs');\n",
    "const load = arguments[1];\nload('./hidden.mjs');\n",
    "arguments[2].require('./hidden.mjs');\n",
    "declare function require(name: string): Object;\n" +
      "export { require as loader };\n"
  ]) {
    await writeFile(join(root, 'hvigorfile.ts'), source);
    assert.throws(() => readArkTsGraph(root),
      /CommonJS loader access is not supported/i);
  }
});

test('allows benign module-shaped declaration names in Hvigor', async (t) => {
  const root = await fixture(t, {
    'hvigorfile.ts':
      'interface Config { module: string; require?: boolean }\n' +
      'type RequireType = typeof require;\n' +
      'type ModuleType = typeof module;\n' +
      'class Holder { module: string = \"entry\"; require(): boolean { return false; } }\n' +
      'const { module: kind, require: needed } = new Holder();\n' +
      'void kind;\nvoid needed;\n'
  });

  assert.doesNotThrow(() => readArkTsGraph(root));
});

test('rejects unsupported Hvigor module specifiers', async (t) => {
  const root = await fixture(t, {
    'package.json': '{"name":"arkdb-tooling","type":"module"}',
    'hvigorfile.ts': "import 'file:///tmp/hidden.mjs';\n"
  });
  const source = join(root, 'hvigorfile.ts');

  assert.throws(() => readArkTsGraph(root),
    /Unsupported absolute Node module URL.*file:/i);

  await writeFile(source,
    "import 'data:text/javascript,export%20default%201';\n");
  assert.throws(() => readArkTsGraph(root),
    /Unsupported absolute Node module URL.*data:/i);

  await writeFile(source, "import 'arkdb-tooling/check-package';\n");
  assert.throws(() => readArkTsGraph(root),
    /Root Node package self-reference is not supported/i);
});

test('rejects production tooling outside an ownership layer or explicit root allowlist', () => {
  const graph = {
    files: ['tools/architecture-graph.mjs', 'tools/release-helper.mjs'],
    dependencies: {
      'tools/architecture-graph.mjs': [],
      'tools/release-helper.mjs': []
    }
  };

  assert.throws(() => assertImportPolicy(graph, {
    ownedSourceRoots: [{
      root: 'tools',
      files: ['architecture-graph.mjs'],
      directories: OWNED_TOOL_DIRECTORIES
    }]
  }), /Unowned architecture source: tools\/release-helper\.mjs/);
});

test('rejects production tooling in unowned nested directories', () => {
  const graph = {
    files: ['tools/misc/helper.mjs'],
    dependencies: { 'tools/misc/helper.mjs': [] }
  };

  assert.throws(() => assertImportPolicy(graph, {
    ownedSourceRoots: [{
      root: 'tools',
      files: [],
      directories: OWNED_TOOL_DIRECTORIES
    }]
  }), /Unowned architecture source: tools\/misc\/helper\.mjs/);
});

test('rejects runtime sources outside final owned directories', () => {
  const graph = {
    files: ['mysql/src/main/ets/mysql/misc/Helper.ets'],
    dependencies: { 'mysql/src/main/ets/mysql/misc/Helper.ets': [] }
  };

  assert.throws(() => assertImportPolicy(graph, {
    ownedSourceRoots: [{
      root: 'mysql/src/main/ets/mysql',
      files: ['MySqlConnection.ets'],
      directories: ['api']
    }]
  }), /Unowned architecture source: mysql\/src\/main\/ets\/mysql\/misc\/Helper\.ets/);
});

test('rejects runtime sources outside the MySQL namespace', () => {
  const rogue = 'mysql/src/main/ets/rogue/Helper.ets';
  const graph = {
    files: [rogue],
    dependencies: { [rogue]: [] }
  };

  assert.throws(() => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /Unowned architecture source: mysql\/src\/main\/ets\/rogue\/Helper\.ets/);
});

test('rejects stale legacy architecture sources explicitly', () => {
  const legacy = 'mysql/src/main/ets/mysql/driver/MySqlSession.ets';
  const graph = {
    files: [legacy],
    dependencies: { [legacy]: [] }
  };

  assert.throws(() => assertTestPolicy(graph, {
    forbiddenSources: [legacy]
  }), /Stale architecture source is forbidden: mysql\/src\/main\/ets\/mysql\/driver\/MySqlSession\.ets/);
});

test('rejects MySQL api dependencies on implementation ownership', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/execution/MySqlTransactionRunner.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/execution/MySqlTransactionRunner.ets'
      ],
      'mysql/src/main/ets/mysql/execution/MySqlTransactionRunner.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL api may import only contract and model leaves.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/execution\/MySqlTransactionRunner\.ets/
  );
});

test('rejects MySQL api dependencies outside contract and model leaves', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/auth/Crypto.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/auth/Crypto.ets'
      ],
      'mysql/src/main/ets/mysql/auth/Crypto.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL api may import only contract and model leaves.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/auth\/Crypto\.ets/
  );
});

test('rejects contract and model leaves that reach command implementations', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets',
      'mysql/src/main/ets/mysql/command/Query.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets': [
        'mysql/src/main/ets/mysql/command/Query.ets'
      ],
      'mysql/src/main/ets/mysql/command/Query.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL contract and model leaves must not depend on implementations.*features\/session\/MySqlSessionOptions\.ets -> mysql\/src\/main\/ets\/mysql\/command\/Query\.ets/
  );
});

test('rejects nested model leaves that reach feature implementations', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/model/nested/Bridge.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionRunner.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/model/nested/Bridge.ets'
      ],
      'mysql/src/main/ets/mysql/model/nested/Bridge.ets': [
        'mysql/src/main/ets/mysql/features/session/MySqlSessionRunner.ets'
      ],
      'mysql/src/main/ets/mysql/features/session/MySqlSessionRunner.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL contract and model leaves must not depend on implementations.*model\/nested\/Bridge\.ets/
  );
});

test('rejects MySQL api dependencies on prepared implementation ownership', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/features/prepared/PreparedExecutor.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/features/prepared/PreparedExecutor.ets'
      ],
      'mysql/src/main/ets/mysql/features/prepared/PreparedExecutor.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL api may import only contract and model leaves.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/prepared\/PreparedExecutor\.ets/
  );
});

test('rejects MySQL api dependencies on prepared implementations through contracts', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlPreparedContracts.ets',
      'mysql/src/main/ets/mysql/features/prepared/MySqlParameter.ets',
      'mysql/src/main/ets/mysql/features/prepared/NewPreparedHelper.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlPreparedContracts.ets': [
        'mysql/src/main/ets/mysql/features/prepared/MySqlParameter.ets'
      ],
      'mysql/src/main/ets/mysql/features/prepared/MySqlParameter.ets': [
        'mysql/src/main/ets/mysql/features/prepared/NewPreparedHelper.ets'
      ],
      'mysql/src/main/ets/mysql/features/prepared/NewPreparedHelper.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL contract and model leaves must not depend on implementations.*features\/prepared\/MySqlParameter\.ets -> mysql\/src\/main\/ets\/mysql\/features\/prepared\/NewPreparedHelper\.ets/
  );
});

test('rejects MySQL api dependencies on vertical feature implementation ownership', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
      ],
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL api may import only contract and model leaves.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/NewSessionHelper\.ets/
  );
});

test('rejects MySQL api dependencies on vertical implementations through contracts', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets',
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/api/MySqlContracts.ets': [
        'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets'
      ],
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets': [
        'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
      ],
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL contract and model leaves must not depend on implementations.*features\/session\/MySqlSessionOptions\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/NewSessionHelper\.ets/
  );
});

test('rejects MySQL vertical feature dependencies on sibling implementations', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionRunner.ets',
      'mysql/src/main/ets/mysql/features/insert/NewInsertHelper.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionRunner.ets': [
        'mysql/src/main/ets/mysql/features/insert/NewInsertHelper.ets'
      ],
      'mysql/src/main/ets/mysql/features/insert/NewInsertHelper.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL feature ownership must not depend on sibling implementations.*features\/transaction\/MySqlTransactionRunner\.ets -> mysql\/src\/main\/ets\/mysql\/features\/insert\/NewInsertHelper\.ets/
  );
});

test('rejects prepared, cursor, and long-data dependencies on vertical implementations', () => {
  for (const source of [
    'mysql/src/main/ets/mysql/features/prepared/PreparedExecutor.ets',
    'mysql/src/main/ets/mysql/features/cursor/MySqlCursor.ets',
    'mysql/src/main/ets/mysql/features/longdata/LongData.ets'
  ]) {
    const target = 'mysql/src/main/ets/mysql/features/insert/NewInsertHelper.ets';
    const graph = {
      files: [source, target],
      dependencies: { [source]: [target], [target]: [] }
    };

    assert.throws(
      () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
      /MySQL protocol feature cluster must not depend on vertical feature implementations/
    );
  }
});

test('rejects MySQL api dependencies on cursor and long-data implementations', () => {
  for (const target of [
    'mysql/src/main/ets/mysql/features/cursor/MySqlCursor.ets',
    'mysql/src/main/ets/mysql/features/longdata/LongData.ets',
    'mysql/src/main/ets/mysql/features/longdata/MySqlUploadPump.ets'
  ]) {
    const source = 'mysql/src/main/ets/mysql/api/MySqlFeatureContracts.ets';
    const graph = {
      files: [source, target],
      dependencies: { [source]: [target], [target]: [] }
    };

    assert.throws(
      () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
      /MySQL api may import only contract and model leaves/
    );
  }
});

test('rejects protocol and byte transport dependencies on every feature', () => {
  for (const source of [
    'mysql/src/main/ets/mysql/protocol/PacketChannel.ets',
    'mysql/src/main/ets/mysql/transport/TcpTransport.ets'
  ]) {
    for (const target of [
      'mysql/src/main/ets/mysql/features/cursor/MySqlCursor.ets',
      'mysql/src/main/ets/mysql/features/longdata/MySqlUploadPump.ets',
      'mysql/src/main/ets/mysql/features/session/MySqlSessionOptions.ets'
    ]) {
      const graph = {
        files: [source, target],
        dependencies: { [source]: [target], [target]: [] }
      };

      assert.throws(
        () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
        /MySQL protocol and byte transport must not depend on feature ownership/
      );
    }
  }
});

test('rejects PostgreSQL value codec dependencies outside value, model, and protocol leaves', () => {
  for (const target of [
    'pgsql/src/main/ets/pgsql/PostgresConnection.ets',
    'pgsql/src/main/ets/pgsql/auth/PostgresAuthCrypto.ets',
    'pgsql/src/main/ets/pgsql/transport/PostgresTcpTransport.ets'
  ]) {
    const source = 'pgsql/src/main/ets/pgsql/value/PostgresTextValueDecoder.ets';
    const graph = {
      files: [source, target],
      dependencies: { [source]: [target], [target]: [] }
    };

    assert.throws(
      () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
      /PostgreSQL value codecs may depend only on value, model, and protocol leaves/
    );
  }
});

test('enforces PostgreSQL api, parameter leaf, execution, and prepared feature layering', () => {
  const cases = [
    ['api/PostgresPreparedContracts.ets', 'features/prepared/PostgresParameterEncoder.ets',
      /PostgreSQL api may import only contract and model leaves/],
    ['features/prepared/PostgresParameter.ets', 'features/prepared/PostgresParameterEncoder.ets',
      /PostgreSQL contract and model leaves must not depend on implementations/],
    ['features/prepared/PostgresParameterEncoder.ets', 'transport/PostgresTcpTransport.ets',
      /PostgreSQL prepared feature must not depend on byte transport implementations/],
    ['protocol/PostgresByteCodec.ets', 'features/prepared/PostgresParameter.ets',
      /PostgreSQL protocol and byte transport must not depend on feature ownership/],
    ['transport/PostgresTcpTransport.ets', 'execution/PostgresCommandGate.ets',
      /PostgreSQL protocol and byte transport must not depend on connection or execution ownership/],
    ['execution/PostgresCommandGate.ets', 'PostgresConnection.ets',
      /PostgreSQL execution primitives must not depend on connection or driver facades/],
    ['execution/PostgresSettlements.ets', 'driver/PostgresDriverFactory.ets',
      /PostgreSQL execution primitives must not depend on connection or driver facades/]
  ];
  for (const [fromRel, toRel, expected] of cases) {
    const source = `pgsql/src/main/ets/pgsql/${fromRel}`;
    const target = `pgsql/src/main/ets/pgsql/${toRel}`;
    const graph = { files: [source, target], dependencies: { [source]: [target], [target]: [] } };
    assert.throws(() => assertImportPolicy(graph, ARCHITECTURE_POLICY), expected);
  }
});


