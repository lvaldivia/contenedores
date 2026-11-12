import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp } from '../src/app.mjs';

test('La caida de MySQL cambia readiness a 503 pero mantiene liveness', async () => {
  const app = await buildApp({ logger: false, repository: {
    async ping() { throw new Error('database down'); },
    async list() { const err = new Error('database down'); err.code = 'ECONNREFUSED'; throw err; },
    async close() {}
  } });
  try {
    assert.equal((await app.inject('/health/live')).statusCode, 200);
    assert.equal((await app.inject('/health/ready')).statusCode, 503);
    const response = await app.inject('/api/products');
    assert.equal(response.statusCode, 503);
    assert.equal(response.json().message, 'Base de datos temporalmente no disponible.');
  } finally { await app.close(); }
});
