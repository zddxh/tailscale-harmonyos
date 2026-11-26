import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import vm from 'node:vm';

const require = createRequire(import.meta.url);
const studio = process.env.DEVECO_STUDIO_HOME ?? '/Applications/DevEco-Studio.app/Contents';
const ts = require(require.resolve('typescript', {
  paths: [process.cwd(), `${studio}/tools/hvigor/hvigor`]
}));

// Run the actual platform-independent class logic, replacing only OS services.
// This is intentionally not a second implementation of the binding state machine.
export function loadArkTS(relativePath, dependencies, globals = {}, transform = source => source) {
  const source = transform(readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8'));
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 }
  }).outputText;
  const exports = {};
  vm.runInNewContext(output, {
    exports,
    require(name) {
      if (!(name in dependencies)) throw Error(`Missing platform stub: ${name}`);
      return dependencies[name];
    },
    ...globals
  }, { filename: relativePath });
  return exports;
}
