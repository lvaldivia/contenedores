import Fastify from 'fastify';
import swagger from '@fastify/swagger';
import swaggerUI from '@fastify/swagger-ui';
import { hostname } from 'node:os';

const error = { type: 'object', required: ['message'], properties: { message: { type: 'string' } } };
const fields = {
  name: { type: 'string', minLength: 1, maxLength: 120, pattern: '\\S', examples: ['Teclado'] },
  description: { type: 'string', maxLength: 1000, default: '' },
  price: { type: 'number', minimum: 0, maximum: 99999999.99, multipleOf: 0.01 },
  stock: { type: 'integer', minimum: 0, maximum: 2147483647, default: 0 }
};
const input = { type: 'object', additionalProperties: false, required: ['name', 'price'], properties: fields };
const product = { type: 'object', required: ['id', 'name', 'description', 'price', 'stock', 'createdAt'], properties: {
  id: { type: 'integer' }, ...fields, createdAt: { type: 'string', format: 'date-time' }
} };
const params = { type: 'object', required: ['id'], properties: { id: { type: 'integer', minimum: 1, maximum: 2147483647 } } };
const failures = { 400: error, 404: error, 503: error, 500: error };

// Route schemas are the single source for validation and generated OpenAPI.
export async function buildApp({ repository, logger = true, version = process.env.APP_VERSION || 'v1' }) {
  const app = Fastify({ logger, bodyLimit: 16384, ajv: { customOptions: { removeAdditional: false } } });
  await app.register(swagger, { openapi: {
    openapi: '3.0.3', info: { title: 'API de productos - Laboratorio ECS / EKS', version: '1.0.0',
      description: 'CRUD de productos persistidos en MySQL. API de demostracion sin autenticacion; usar datos ficticios y acceso de red restringido.' },
    servers: [{ url: '/' }], tags: [{ name: 'Productos' }, { name: 'Operacion' }]
  } });
  await app.register(swaggerUI, { routePrefix: '/docs', uiConfig: { docExpansion: 'list', persistAuthorization: false } });
  app.setErrorHandler((err, request, reply) => {
    if (err.validation || err.statusCode === 400) return reply.code(400).send({ message: 'Solicitud invalida: revise los campos y tipos en Swagger.' });
    if (err.statusCode === 413) return reply.code(413).send({ message: 'Solicitud demasiado grande.' });
    if (err.statusCode === 415) return reply.code(415).send({ message: 'Use Content-Type: application/json.' });
    request.log.error({ code: err.code, message: err.message }, 'Fallo al procesar la solicitud');
    const dbFailure = ['ECONNREFUSED', 'ETIMEDOUT', 'PROTOCOL_CONNECTION_LOST', 'ER_CON_COUNT_ERROR', 'ER_ACCESS_DENIED_ERROR', 'POOL_ENQUEUELIMIT'].includes(err.code);
    return reply.code(dbFailure ? 503 : 500).send({ message: dbFailure ? 'Base de datos temporalmente no disponible.' : 'Error interno.' });
  });
  app.get('/', { schema: { hide: true } }, async (_, reply) => reply.redirect('/docs'));
  app.get('/health/live', { schema: { tags: ['Operacion'], summary: 'Proceso activo (no consulta MySQL)', response: { 200: { type: 'object', properties: { status: { type: 'string' } } } } } }, async () => ({ status: 'ok' }));
  app.get('/health/ready', { schema: { tags: ['Operacion'], summary: 'Conexion MySQL disponible', response: { 200: { type: 'object', properties: { status: { type: 'string' } } }, 503: error } } }, async (_, reply) => {
    try { await repository.ping(); return { status: 'ready' }; }
    catch { return reply.code(503).send({ message: 'MySQL no disponible.' }); }
  });
  app.get('/api/info', { schema: { tags: ['Operacion'], summary: 'Version y contenedor que respondio', response: { 200: { type: 'object', properties: {
    version: { type: 'string' }, environment: { type: 'string' }, hostname: { type: 'string' }
  } } } } }, async () => ({ version, environment: process.env.APP_ENV || 'local', hostname: hostname() }));
  app.get('/api/products', { schema: { tags: ['Productos'], summary: 'Listar productos con paginacion', querystring: {
    type: 'object', additionalProperties: false, properties: { limit: { type: 'integer', minimum: 1, maximum: 100, default: 20 }, offset: { type: 'integer', minimum: 0, maximum: 1000000, default: 0 } }
  }, response: { 200: { type: 'object', properties: { items: { type: 'array', items: product }, limit: { type: 'integer' }, offset: { type: 'integer' } } }, ...failures } } }, async request => {
    const { limit, offset } = request.query;
    return { items: await repository.list(limit, offset), limit, offset };
  });
  app.get('/api/products/:id', { schema: { tags: ['Productos'], summary: 'Obtener un producto', params, response: { 200: product, ...failures } } }, async (request, reply) => {
    const item = await repository.get(request.params.id);
    return item || reply.code(404).send({ message: 'Producto no encontrado.' });
  });
  app.post('/api/products', { schema: { tags: ['Productos'], summary: 'Crear un producto', body: input, response: { 201: product, ...failures } } }, async (request, reply) => {
    const item = await repository.create(request.body);
    return reply.code(201).header('Location', `/api/products/${item.id}`).send(item);
  });
  app.put('/api/products/:id', { schema: { tags: ['Productos'], summary: 'Reemplazar los datos de un producto', params, body: input, response: { 200: product, ...failures } } }, async (request, reply) => {
    const item = await repository.update(request.params.id, request.body);
    return item || reply.code(404).send({ message: 'Producto no encontrado.' });
  });
  app.delete('/api/products/:id', { schema: { tags: ['Productos'], summary: 'Eliminar un producto', params, response: { 204: { type: 'null' }, ...failures } } }, async (request, reply) => {
    if (!await repository.remove(request.params.id)) return reply.code(404).send({ message: 'Producto no encontrado.' });
    return reply.code(204).send();
  });
  app.get('/openapi.json', { schema: { hide: true } }, async () => app.swagger());
  app.addHook('onClose', async () => repository.close());
  return app;
}
