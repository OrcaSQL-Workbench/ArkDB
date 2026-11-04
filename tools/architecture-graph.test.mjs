import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import {
  assertImportPolicy, readArkTsGraph, stronglyConnectedFiles
} from './architecture-graph.mjs';

const ROOT = fileURLToPath(new URL('..', import.meta.url));
const KNOWN_CYCLES = [
  [
    'mysql/src/main/ets/mysql/driver/MySqlConnectionFeatures.ets',
    'mysql/src/main/ets/mysql/driver/MySqlContracts.ets',
    'mysql/src/main/ets/mysql/driver/MySqlSession.ets',
    'mysql/src/main/ets/mysql/execution/MySqlTransactionRunner.ets'
  ],
  [
    'tools/delivery-workspace.mjs',
    'tools/har-release.mjs',
    'tools/package-har.mjs'
  ]
];
const ARCHITECTURE_POLICY = {
  allowedCycles: KNOWN_CYCLES,
  prohibitedDependencies: [
    {
      from: /^core\//,
      to: /^mysql\//,
      message: 'Shared core must not depend on the MySQL driver.'
    }
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

test('reports the current ArkTS and tooling cycles deterministically', () => {
  const graph = readArkTsGraph(ROOT);

  assert.deepEqual(stronglyConnectedFiles(graph), KNOWN_CYCLES);
  assert.doesNotThrow(() => assertImportPolicy(graph, ARCHITECTURE_POLICY));
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
void import('./dynamic.mjs');
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

  assert.throws(() => readArkTsGraph(root), /CommonJS tooling source.*a\.cjs/i);
});

test('resolves Node static imports with query and hash suffixes', async (t) => {
  const root = await fixture(t, {
    'tools/a.mjs': "import './b.mjs?graph=1';",
    'tools/b.mjs': "export { value } from './a.mjs#graph'; export const value = 1;"
  });

  assert.deepEqual(stronglyConnectedFiles(readArkTsGraph(root)), [
    ['tools/a.mjs', 'tools/b.mjs']
  ]);
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
    () => assertImportPolicy(graph, { allowedCycles: KNOWN_CYCLES }),
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
