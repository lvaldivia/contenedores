import { writeFile } from 'node:fs/promises';
import { buildApp } from '../src/app.mjs';
const app = await buildApp({ logger: false, repository: { async close() {} } });
await app.ready();
await writeFile(new URL('../docs/openapi.json', import.meta.url), JSON.stringify(app.swagger(), null, 2) + '\n');
await app.close();
console.log('Contrato exportado: docs/openapi.json');
