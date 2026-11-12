import { test } from 'node:test';
import assert from 'node:assert/strict';

const base = process.env.TEST_BASE_URL || 'http://127.0.0.1:3000';
async function request(path, method = 'GET', body) {
  const response = await fetch(`${base}${path}`, { method, headers: body ? { 'content-type': 'application/json' } : {}, body: body ? JSON.stringify(body) : undefined });
  const text = await response.text();
  return { status: response.status, body: text ? JSON.parse(text) : undefined, headers: response.headers };
}

test('Swagger, contrato y salud del contenedor', async () => {
  assert.equal((await fetch(`${base}/docs/`)).status, 200);
  assert.equal((await fetch(`${base}/docs/static/swagger-ui-bundle.js`)).status, 200);
  const spec = await request('/openapi.json');
  assert.equal(spec.body.openapi, '3.0.3');
  assert.ok(spec.body.paths['/api/products'].post);
  assert.ok(spec.body.paths['/api/products/{id}'].delete);
  assert.equal((await request('/health/live')).status, 200);
  assert.equal((await request('/health/ready')).status, 200);
});

test('CRUD real: persistencia, paginacion, actualizacion y borrado', async () => {
  const name = `Prueba-${Date.now()}`;
  const created = await request('/api/products', 'POST', { name, price: 49.90, stock: 4 });
  assert.equal(created.status, 201);
  const id = created.body.id;
  try {
    assert.equal(created.headers.get('location'), `/api/products/${id}`);
    assert.equal(created.body.price, 49.90);
    const read = await request(`/api/products/${id}`);
    assert.equal(read.body.name, name);
    const listed = await request('/api/products?limit=100&offset=0');
    assert.ok(listed.body.items.some(item => item.id === id));
    assert.equal(listed.body.limit, 100);
    const updated = await request(`/api/products/${id}`, 'PUT', { name: `${name}-nuevo`, price: 60, stock: 8 });
    assert.equal(updated.status, 200);
    assert.equal((await request(`/api/products/${id}`)).body.stock, 8);
    assert.equal((await request(`/api/products/${id}`, 'DELETE')).status, 204);
    assert.equal((await request(`/api/products/${id}`)).status, 404);
    assert.equal((await request(`/api/products/${id}`, 'DELETE')).status, 404);
    assert.equal((await request(`/api/products/${id}`, 'PUT', { name, price: 1 })).status, 404);
  } finally { await request(`/api/products/${id}`, 'DELETE'); }
});

test('Validacion de datos y parametros antes de escribir en MySQL', async () => {
  for (const body of [
    { name: 'Producto', price: -1 }, { name: '', price: 1 }, { name: '   ', price: 1 },
    { name: 'Producto' }, { name: 'Producto', price: 1.001 },
    { name: 'Producto', price: 1, stock: -1 }, { name: 'Producto', price: 1, admin: true }
  ]) assert.equal((await request('/api/products', 'POST', body)).status, 400);
  assert.equal((await request('/api/products/abc')).status, 400);
  assert.equal((await request('/api/products?limit=101')).status, 400);
});

test('Consultas parametrizadas conservan texto y no ejecutan SQL del usuario', async () => {
  const name = "Prueba'; DROP TABLE products; --";
  const result = await request('/api/products', 'POST', { name, price: 1 });
  assert.equal(result.status, 201);
  try { assert.equal((await request(`/api/products/${result.body.id}`)).body.name, name); }
  finally { await request(`/api/products/${result.body.id}`, 'DELETE'); }
});
