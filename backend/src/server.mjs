import { buildApp } from './app.mjs';
import { createRepository, databaseConfig } from './db.mjs';

const app = await buildApp({ repository: createRepository(databaseConfig()) });
for (const signal of ['SIGTERM', 'SIGINT']) {
  process.once(signal, async () => { await app.close(); });
}
try { await app.listen({ host: '0.0.0.0', port: Number(process.env.PORT || 3000) }); }
catch (err) { app.log.error({ message: err.message }, 'No se pudo iniciar'); await app.close(); process.exitCode = 1; }
