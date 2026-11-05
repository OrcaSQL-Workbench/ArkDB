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
const APPROVED_CYCLES = [];
const TOOL_LAYER_RULES = [
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
const ALLOWED_ROOT_TOOL_FILES = [
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
const MYSQL_VERTICAL_FEATURE_PATTERN = MYSQL_VERTICAL_FEATURES.join('|');
const MYSQL_LEGACY_VERTICAL_OWNERS = [
  [
    'transaction',
    /^mysql\/src\/main\/ets\/mysql\/(?:model\/MySqlTransactionOptions|execution\/MySqlTransactionRunner)\.ets$/
  ],
  [
    'named',
    /^mysql\/src\/main\/ets\/mysql\/(?:model\/MySqlNamedParameter|execution\/MySqlNamedExecutor|value\/SqlTemplateScanner)\.ets$/
  ],
  [
    'procedure',
    /^mysql\/src\/main\/ets\/mysql\/(?:model\/MySqlProcedure|execution\/MySqlProcedureCaller)\.ets$/
  ],
  [
    'batch',
    /^mysql\/src\/main\/ets\/mysql\/(?:model\/MySqlBatch|execution\/(?:MySqlBatchExecutor|MySqlBatchSupport))\.ets$/
  ],
  [
    'insert',
    /^mysql\/src\/main\/ets\/mysql\/(?:model\/MySqlInsertRows|execution\/MySqlInsertRowsExecutor)\.ets$/
  ],
  [
    'metadata',
    /^mysql\/src\/main\/ets\/mysql\/metadata\//
  ],
  [
    'metrics',
    /^mysql\/src\/main\/ets\/mysql\/metrics\//
  ]
];
const MYSQL_LEGACY_VERTICAL_IMPLEMENTATIONS = [
  [
    'transaction',
    /^mysql\/src\/main\/ets\/mysql\/execution\/MySqlTransactionRunner\.ets$/
  ],
  [
    'named',
    /^mysql\/src\/main\/ets\/mysql\/(?:execution\/MySqlNamedExecutor|value\/SqlTemplateScanner)\.ets$/
  ],
  [
    'procedure',
    /^mysql\/src\/main\/ets\/mysql\/execution\/MySqlProcedureCaller\.ets$/
  ],
  [
    'batch',
    /^mysql\/src\/main\/ets\/mysql\/execution\/(?:MySqlBatchExecutor|MySqlBatchSupport)\.ets$/
  ],
  [
    'insert',
    /^mysql\/src\/main\/ets\/mysql\/execution\/MySqlInsertRowsExecutor\.ets$/
  ],
  [
    'metadata',
    /^mysql\/src\/main\/ets\/mysql\/metadata\/(?:MySqlMetadataProvider|MySqlMetadataSql)\.ets$/
  ],
  [
    'metrics',
    /^mysql\/src\/main\/ets\/mysql\/metrics\/(?:MySqlMetricsSql|MySqlServerMetricsProvider)\.ets$/
  ]
];
const MYSQL_VERTICAL_IMPLEMENTATION_PATH =
  new RegExp('^mysql/src/main/ets/mysql/features/' +
    '(?!(?:' + MYSQL_VERTICAL_CONTRACTS + ')$)' +
    '(?:' + MYSQL_VERTICAL_FEATURE_PATTERN + ')/');

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

function mysqlLegacySiblingImplementationPath(owner) {
  const siblings = MYSQL_LEGACY_VERTICAL_IMPLEMENTATIONS
    .filter(([candidate]) => candidate !== owner)
    .map(([_candidate, pattern]) => pattern.source)
    .join('|');
  return new RegExp('(?:' + siblings + ')');
}

function mysqlMigratedToLegacySiblingRule(owner) {
  return {
    from: new RegExp(
      '^mysql/src/main/ets/mysql/features/' + owner + '/'),
    to: mysqlLegacySiblingImplementationPath(owner),
    transitive: true,
    message: 'MySQL feature ownership must not depend on sibling implementations.'
  };
}

function mysqlLegacySiblingImplementationRule([owner, from]) {
  return {
    from,
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
const ARCHITECTURE_POLICY = {
  allowedCycles: APPROVED_CYCLES,
  allowedRootToolFiles: ALLOWED_ROOT_TOOL_FILES,
  ownedToolDirectories: OWNED_TOOL_DIRECTORIES,
  prohibitedDependencies: [
    {
      from: /^core\//,
      to: /^mysql\//,
      message: 'Shared core must not depend on the MySQL driver.'
    },
    {
      from: /^mysql\/src\/main\/ets\/mysql\/api\//,
      to: /^mysql\/src\/main\/ets\/mysql\/(?:MySqlConnection\.ets|command\/|driver\/|execution\/|features\/(?:cursor\/MySqlCursor\.ets$|longdata\/(?:LongData|MySqlUploadPump)\.ets$|prepared\/(?!MySqlParameter\.ets$))|protocol\/|transport\/)/,
      message: 'MySQL public contracts must not depend on implementation ownership.'
    },
    {
      from: /^mysql\/src\/main\/ets\/mysql\/api\//,
      to: /^mysql\/src\/main\/ets\/mysql\/features\/prepared\/(?!MySqlParameter\.ets$)/,
      transitive: true,
      message: 'MySQL public contracts must not depend on implementation ownership.'
    },
    {
      from: /^mysql\/src\/main\/ets\/mysql\/api\//,
      to: MYSQL_VERTICAL_IMPLEMENTATION_PATH,
      transitive: true,
      message: 'MySQL public contracts must not depend on feature implementation ownership.'
    },
    ...MYSQL_VERTICAL_FEATURES.map(mysqlSiblingImplementationRule),
    ...MYSQL_VERTICAL_FEATURES.map(mysqlMigratedToLegacySiblingRule),
    ...MYSQL_LEGACY_VERTICAL_OWNERS.map(mysqlLegacySiblingImplementationRule),
    {
      from: /^mysql\/src\/main\/ets\/mysql\/(?:protocol|transport)\//,
      to: /^mysql\/src\/main\/ets\/mysql\/features\/(?:cursor|longdata)\//,
      message: 'MySQL wire transport must not depend on cursor or long-data feature ownership.'
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

test('reports the current architecture with no import cycles', () => {
  const graph = readArkTsGraph(ROOT);

  assert.deepEqual(stronglyConnectedFiles(graph), APPROVED_CYCLES);
  assert.doesNotThrow(() => assertImportPolicy(graph, ARCHITECTURE_POLICY));
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
      'mysql/src/test/mysql/features/transaction/MySqlTransactionRunner.test.ets'
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
  assert.throws(() => assertImportPolicy(graph, {
    prohibitedDependencies: [{
      from: 'core/src/main/ets/RuntimeType.ets',
      to: 'core/src/main/ets/RuntimeB.ets',
      message: 'Static import types must reach policy enforcement.'
    }]
  }), /Static import types must reach policy enforcement/);
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
  const root = await fixture(t, {
    'tools/a.mts': "import './b.mts';",
    'tools/b.mts': "import './a.mts';"
  });

  assert.throws(() => readArkTsGraph(root), /Node tooling source.*a\.mts.*\.mjs/i);
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
  assert.throws(() => readArkTsGraph(root), /computed process access.*not supported.*a\.mjs/i);

  await writeFile(source, `
const process = { safe: true };
const key = 'safe';
process[key];
`);
  assert.throws(() => readArkTsGraph(root), /computed process access.*not supported.*a\.mjs/i);
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

test('rejects every cycle that is not an exact known finding', () => {
  const graph = {
    files: ['tools/new-a.mjs', 'tools/new-b.mjs'],
    dependencies: {
      'tools/new-a.mjs': ['tools/new-b.mjs'],
      'tools/new-b.mjs': ['tools/new-a.mjs']
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, { allowedCycles: APPROVED_CYCLES }),
    /Unexpected import cycle: tools\/new-a\.mjs -> tools\/new-b\.mjs/
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

test('rejects reverse tooling ownership imports', () => {
  for (const rule of TOOL_LAYER_RULES) {
    const from = {
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

    assert.throws(() => assertImportPolicy(graph, {
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

  assert.throws(() => assertImportPolicy(graph, {
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
    allowedRootToolFiles: ['tools/architecture-graph.mjs'],
    ownedToolDirectories: OWNED_TOOL_DIRECTORIES
  }), /Unowned root tooling source: tools\/release-helper\.mjs/);
});

test('rejects production tooling in unowned nested directories', () => {
  const graph = {
    files: ['tools/misc/helper.mjs'],
    dependencies: { 'tools/misc/helper.mjs': [] }
  };

  assert.throws(() => assertImportPolicy(graph, {
    allowedRootToolFiles: [],
    ownedToolDirectories: OWNED_TOOL_DIRECTORIES
  }), /Unowned tooling source: tools\/misc\/helper\.mjs/);
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
    /MySQL public contracts must not depend on implementation ownership.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/execution\/MySqlTransactionRunner\.ets/
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
    /MySQL public contracts must not depend on implementation ownership.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/prepared\/PreparedExecutor\.ets/
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
    /MySQL public contracts must not depend on implementation ownership.*api\/MySqlPreparedContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/prepared\/MySqlParameter\.ets -> mysql\/src\/main\/ets\/mysql\/features\/prepared\/NewPreparedHelper\.ets/
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
    /MySQL public contracts must not depend on feature implementation ownership.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/NewSessionHelper\.ets/
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
    /MySQL public contracts must not depend on feature implementation ownership.*api\/MySqlContracts\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/MySqlSessionOptions\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/NewSessionHelper\.ets/
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

test('rejects MySQL vertical feature dependencies on legacy sibling implementations', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionRunner.ets',
      'mysql/src/main/ets/mysql/execution/MySqlInsertRowsExecutor.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/features/transaction/MySqlTransactionRunner.ets': [
        'mysql/src/main/ets/mysql/execution/MySqlInsertRowsExecutor.ets'
      ],
      'mysql/src/main/ets/mysql/execution/MySqlInsertRowsExecutor.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL feature ownership must not depend on sibling implementations.*features\/transaction\/MySqlTransactionRunner\.ets -> mysql\/src\/main\/ets\/mysql\/execution\/MySqlInsertRowsExecutor\.ets/
  );
});

test('rejects legacy vertical owner dependencies on migrated sibling implementations', () => {
  const graph = {
    files: [
      'mysql/src/main/ets/mysql/metadata/MySqlMetadataProvider.ets',
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
    ],
    dependencies: {
      'mysql/src/main/ets/mysql/metadata/MySqlMetadataProvider.ets': [
        'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets'
      ],
      'mysql/src/main/ets/mysql/features/session/NewSessionHelper.ets': []
    }
  };

  assert.throws(
    () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
    /MySQL feature ownership must not depend on sibling implementations.*metadata\/MySqlMetadataProvider\.ets -> mysql\/src\/main\/ets\/mysql\/features\/session\/NewSessionHelper\.ets/
  );
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
      /MySQL public contracts must not depend on implementation ownership/
    );
  }
});

test('rejects wire transport dependencies on cursor and long-data ownership', () => {
  for (const source of [
    'mysql/src/main/ets/mysql/protocol/PacketChannel.ets',
    'mysql/src/main/ets/mysql/transport/TcpTransport.ets'
  ]) {
    for (const target of [
      'mysql/src/main/ets/mysql/features/cursor/MySqlCursor.ets',
      'mysql/src/main/ets/mysql/features/longdata/MySqlUploadPump.ets'
    ]) {
      const graph = {
        files: [source, target],
        dependencies: { [source]: [target], [target]: [] }
      };

      assert.throws(
        () => assertImportPolicy(graph, ARCHITECTURE_POLICY),
        /MySQL wire transport must not depend on cursor or long-data feature ownership/
      );
    }
  }
});
