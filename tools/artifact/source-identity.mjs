import { readFileSync } from 'node:fs';
import { join, relative, sep } from 'node:path';
import { listFiles } from '../workspace/check-package.mjs';
import { dependencyClosure, ROOT } from '../workspace/driver-packages.mjs';
import { createSha256 } from '../lib/hash.mjs';

export function sourceFingerprint(root = ROOT, id = 'mysql') {
  const packages = dependencyClosure(root, id);
  const files = [
    ...['build-profile.json5', 'oh-package.json5', 'hvigorfile.ts'].map((name) => join(root, name)),
    join(root, 'hvigor', 'hvigor-config.json5'), join(root, 'AppScope', 'app.json5'),
    ...packages.flatMap((entry) => [
      ...['Index.ets', 'oh-package.json5', 'arkdb-package.json', 'build-profile.json5', 'hvigorfile.ts',
        'README.md', 'CHANGELOG.md', 'LICENSE', 'README.OpenSource']
        .map((name) => join(entry.directory, name)),
      ...listFiles(join(entry.directory, 'src', 'main'))
    ])
  ];
  const hash = createSha256();
  for (const file of files.sort()) {
    hash.update(relative(root, file).split(sep).join('/')).update('\0');
    hash.update(readFileSync(file)).update('\0');
  }
  return hash.digest('hex');
}
