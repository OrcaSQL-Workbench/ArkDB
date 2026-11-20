import { readFileSync } from 'node:fs';
import vm from 'node:vm';

export function createSampleLoader(samples, modules, ts, globals = {}) {
  function load(name) {
    if (!modules.has(name)) {
      if (!name.startsWith('./')) throw new Error(`Unknown module: ${name}`);
      const source = readFileSync(new URL(`${name}.ets`, samples), 'utf8');
      const compiled = ts.transpileModule(source, {
        compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
      }).outputText;
      const exports = {};
      const execute = vm.compileFunction(compiled, ['exports', 'require', ...Object.keys(globals)]);
      execute(exports, load, ...Object.values(globals));
      modules.set(name, exports);
    }
    return modules.get(name);
  }
  return load;
}

export function observeSettlement(promise) {
  const observation = { settled: false };
  observation.result = promise.then(
    (value) => { observation.settled = true; return value; },
    (error) => { observation.settled = true; return error; }
  );
  return observation;
}
