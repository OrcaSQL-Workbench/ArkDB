import { readFileSync } from 'node:fs';
import { copyFile, cp, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path';
import ts from 'typescript';
import { checkPackage, listFiles } from './check-package.mjs';
import { dependencyClosure, localOutputPaths, readJson5, resolveDriver, ROOT } from './driver-packages.mjs';
import { plainPath } from './har-release.mjs';

function within(parent, file) {
  const path = relative(parent, file);
  return path !== '..' && !path.startsWith(`..${sep}`) && !isAbsolute(path);
}

export function deliveryPlan(root = ROOT, id = 'mysql') {
  resolveDriver(root, id);
  const packages = dependencyClosure(root, id).map((entry) => checkPackage(root, entry.id));
  const entry = packages.at(-1);
  const definition = structuredClone(entry.driver.definition);
  const permissions = new Map();
  for (const checked of packages) {
    for (const permission of checked.driver.definition.requestPermissions ?? []) {
      const previous = permissions.get(permission.name);
      if (previous && JSON.stringify(previous) !== JSON.stringify(permission)) {
        throw new Error(`Conflicting bundled permission: ${permission.name}`);
      }
      permissions.set(permission.name, structuredClone(permission));
    }
    if (checked !== entry) {
      const main = join(checked.driver.directory, 'src', 'main');
      const runtime = join(main, 'ets');
      const other = listFiles(main).filter((file) =>
        !within(runtime, file) && file !== join(main, 'module.json5'));
      if (other.length > 0) {
        throw new Error(`Dependency ${checked.driver.id} has non-ETS assets requiring an explicit resource rule.`);
      }
      const profile = readJson5(join(checked.driver.directory, 'build-profile.json5'));
      if (JSON.stringify(profile).includes('"buildProfileFields"')) {
        throw new Error(`Dependency ${checked.driver.id} has custom BuildProfile fields requiring an explicit delivery rule.`);
      }
    }
  }
  if (permissions.size > 0) definition.requestPermissions = [...permissions.values()];
  else delete definition.requestPermissions;
  const notices = [readFileSync(join(entry.driver.directory, 'README.OpenSource'))];
  for (const checked of packages.filter((item) => item !== entry)) {
    notices.push(Buffer.from(`\n\nBundled source package: ${checked.manifest.name}@${checked.manifest.version}\n\n`));
    notices.push(readFileSync(join(checked.driver.directory, 'README.OpenSource')));
    notices.push(Buffer.from('\n\nPackage license:\n\n'));
    notices.push(readFileSync(join(checked.driver.directory, 'LICENSE')));
  }
  const manifest = structuredClone(entry.manifest);
  manifest.dependencies = {};
  delete manifest.devDependencies;
  delete manifest.overrides;
  return { packages, entry, definition, manifest, notice: Buffer.concat(notices) };
}

function relativeSpecifier(file, target) {
  const path = relative(dirname(file), target).split(sep).join('/').replace(/(?:\.d)?\.ets$/, '');
  return path.startsWith('.') ? path : `./${path}`;
}

function moduleLiterals(source) {
  const literals = [];
  function visit(node) {
    if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) &&
      node.moduleSpecifier && ts.isStringLiteral(node.moduleSpecifier)) {
      literals.push(node.moduleSpecifier);
    } else if (ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument) &&
      ts.isStringLiteral(node.argument.literal)) {
      literals.push(node.argument.literal);
    } else if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword &&
      node.arguments.length > 0 && ts.isStringLiteral(node.arguments[0])) {
      literals.push(node.arguments[0]);
    }
    ts.forEachChild(node, visit);
  }
  visit(source);
  return literals;
}

function rewrittenSource(file, target, text, mappings, packageEntries) {
  const syntax = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  if (syntax.parseDiagnostics.length > 0) {
    throw new Error(`Cannot safely parse source for delivery: ${file}`);
  }
  const replacements = [];
  for (const literal of moduleLiterals(syntax)) {
    const specifier = literal.text;
    let candidates = packageEntries.has(specifier) ? [packageEntries.get(specifier)] : null;
    if (!candidates && specifier.startsWith('.')) {
      const path = resolve(dirname(file), specifier);
      candidates = [path, `${path}.ets`, `${path}.d.ets`, join(path, 'Index.ets')];
    }
    if (!candidates) continue;
    const sourceTarget = candidates.find((candidate) => mappings.has(candidate));
    if (!sourceTarget) throw new Error(`Unmapped internal import ${specifier} in ${file}`);
    replacements.push({
      start: literal.getStart(syntax), end: literal.end,
      text: JSON.stringify(relativeSpecifier(target, mappings.get(sourceTarget)))
    });
  }
  let output = text;
  for (const replacement of replacements.sort((left, right) => right.start - left.start)) {
    output = output.slice(0, replacement.start) + replacement.text + output.slice(replacement.end);
  }
  return output;
}

async function writeJson(file, value) {
  await writeFile(file, `${JSON.stringify(value, null, 2)}\n`);
}

export async function createDeliveryWorkspace(root = ROOT, id = 'mysql') {
  const plan = deliveryPlan(root, id);
  const parent = plainPath(root, localOutputPaths(root, id).workspaces, { allowMissing: true });
  await mkdir(parent, { recursive: true });
  plainPath(root, parent);
  const directory = await mkdtemp(join(parent, 'delivery-'));
  try {
    for (const name of ['AppScope', 'hvigor']) {
      const source = join(root, name);
      listFiles(source);
      await cp(source, join(directory, name), { recursive: true });
    }
    await copyFile(join(root, 'hvigorfile.ts'), join(directory, 'hvigorfile.ts'));
    const profile = structuredClone(readJson5(join(root, 'build-profile.json5')));
    profile.modules = [{ name: id, srcPath: './module' }];
    if (profile.app) {
      profile.app.signingConfigs = [];
      for (const product of profile.app.products ?? []) delete product.signingConfig;
    }
    await writeJson(join(directory, 'build-profile.json5'), profile);
    const project = structuredClone(readJson5(join(root, 'oh-package.json5')));
    project.dependencies = {};
    delete project.devDependencies;
    delete project.overrides;
    await writeJson(join(directory, 'oh-package.json5'), project);
    const moduleDirectory = join(directory, 'module');
    await mkdir(moduleDirectory);
    for (const name of ['README.md', 'CHANGELOG.md', 'LICENSE', 'hvigorfile.ts']) {
      await copyFile(join(plan.entry.driver.directory, name), join(moduleDirectory, name));
    }
    await writeFile(join(moduleDirectory, 'README.OpenSource'), plan.notice);
    await writeJson(join(moduleDirectory, 'oh-package.json5'), plan.manifest);
    const moduleProfile = structuredClone(readJson5(join(plan.entry.driver.directory, 'build-profile.json5')));
    for (const option of [moduleProfile.buildOption, ...(moduleProfile.buildOptionSet ?? [])]) {
      if (option?.arkOptions) {
        delete option.arkOptions.bundledDependencies;
        delete option.arkOptions.bundle;
      }
    }
    await writeJson(join(moduleDirectory, 'build-profile.json5'), moduleProfile);
    await cp(join(plan.entry.driver.directory, 'src', 'main'), join(moduleDirectory, 'src', 'main'),
      { recursive: true });
    await writeJson(join(moduleDirectory, 'src', 'main', 'module.json5'), { module: plan.definition });
    const mappings = new Map();
    const packageEntries = new Map();
    const targets = new Set();
    const files = [];
    const profiles = [];
    for (const checked of plan.packages) {
      const source = checked.driver.directory;
      const runtime = join(source, 'src', 'main', 'ets');
      const target = checked === plan.entry ? join(moduleDirectory, 'src', 'main', 'ets') :
        join(moduleDirectory, 'src', 'main', 'ets', '_deps', checked.driver.id);
      const entry = join(source, 'Index.ets');
      packageEntries.set(checked.manifest.name, entry);
      for (const file of [entry, ...listFiles(runtime).filter((file) => file.endsWith('.ets'))]) {
        const destination = file === entry
          ? checked === plan.entry ? join(moduleDirectory, 'Index.ets') : join(target, 'Index.ets')
          : join(target, relative(runtime, file));
        if (targets.has(destination)) throw new Error(`Delivery source collision: ${destination}`);
        targets.add(destination);
        mappings.set(file, destination);
        files.push(file);
      }
      const destination = checked === plan.entry ? join(moduleDirectory, 'BuildProfile.ets') :
        join(target, 'BuildProfile.ets');
      if (targets.has(destination)) throw new Error(`Delivery BuildProfile collision: ${destination}`);
      targets.add(destination);
      mappings.set(join(source, 'BuildProfile.ets'), destination);
      if (checked !== plan.entry) profiles.push({ file: destination, version: checked.manifest.version });
    }
    for (const file of files) {
      const destination = mappings.get(file);
      const text = rewrittenSource(file, destination, await readFile(file, 'utf8'), mappings, packageEntries);
      await mkdir(dirname(destination), { recursive: true });
      await writeFile(destination, text);
    }
    for (const item of profiles) {
      const parentProfile = relativeSpecifier(item.file, join(moduleDirectory, 'BuildProfile.ets'));
      await writeFile(item.file, `import RootBuildProfile from ${JSON.stringify(parentProfile)};
export const HAR_VERSION = ${JSON.stringify(item.version)};
export const BUILD_MODE_NAME = RootBuildProfile.BUILD_MODE_NAME;
export const DEBUG = RootBuildProfile.DEBUG;
export const TARGET_NAME = RootBuildProfile.TARGET_NAME;
export default class DependencyBuildProfile {
  static readonly HAR_VERSION = HAR_VERSION;
  static readonly BUILD_MODE_NAME = BUILD_MODE_NAME;
  static readonly DEBUG = DEBUG;
  static readonly TARGET_NAME = TARGET_NAME;
}
`);
    }
    await writeJson(join(directory, 'delivery-map.json'), files.map((file) => ({
      source: relative(root, file), target: relative(directory, mappings.get(file))
    })));
    return { directory, moduleDirectory, plan };
  } catch (error) {
    try {
      await rm(directory, { recursive: true, force: true });
    } catch (cleanup) {
      throw new AggregateError([error, cleanup], 'Delivery staging failed and its owned workspace could not be removed.');
    }
    throw error;
  }
}
