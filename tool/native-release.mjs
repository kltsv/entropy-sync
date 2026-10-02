import { execFileSync } from 'node:child_process';
import { cpSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { buildEngine, pluginRoot, packageRoot } from './engine.mjs';
const engine = buildEngine();
const output = join(pluginRoot, 'dist', 'native');
mkdirSync(output, { recursive: true });
cpSync(engine.binary, join(output, engine.asset));
