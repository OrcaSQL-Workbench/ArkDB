import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

export function extractExamples(markdown) {
  const examples = [];
  const names = new Set();
  for (const match of markdown.matchAll(
    /<!-- arkts-example: ([a-z][a-z0-9-]*) -->\s*```typescript\r?\n([\s\S]*?)```/g)) {
    const [, name, source] = match;
    if (names.has(name)) throw new Error(`Duplicate documented example: ${name}`);
    if (!/\bexport\s/.test(source)) throw new Error(`Documented example ${name} must be an independent module.`);
    names.add(name);
    examples.push({ name, source });
  }
  if (examples.length === 0) throw new Error('No compilable ArkTS usage examples were found.');
  return examples;
}

export async function addDocumentationChecks(workspace, markdown) {
  const examples = extractExamples(markdown);
  const directory = join(workspace, 'entry', 'src', 'main', 'ets', 'readme-check');
  await mkdir(directory, { recursive: true });
  for (const example of examples) {
    await writeFile(join(directory, `${example.name}.ets`), example.source);
  }
  await writeFile(join(directory, 'Examples.ets'),
    examples.map((example) => `import './${example.name}';`).join('\n') + '\n');
  const ability = join(workspace, 'entry', 'src', 'main', 'ets', 'entryability', 'EntryAbility.ets');
  await writeFile(ability, `import '../readme-check/Examples';\n${await readFile(ability, 'utf8')}`);
  return examples.length;
}
