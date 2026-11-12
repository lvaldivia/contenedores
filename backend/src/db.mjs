import mysql from 'mysql2/promise';
import { readFileSync } from 'node:fs';

export function databaseConfig(env = process.env) {
  for (const key of ['DB_HOST', 'DB_USER', 'DB_PASSWORD', 'DB_NAME']) {
    if (!env[key]) throw new Error(`Falta la variable ${key}`);
  }
  return {
    host: env.DB_HOST,
    port: Number(env.DB_PORT || 3306),
    user: env.DB_USER,
    password: env.DB_PASSWORD,
    database: env.DB_NAME,
    connectTimeout: 5000,
    decimalNumbers: true,
    timezone: 'Z',
    ...(env.DB_SSL === 'true' ? { ssl: { rejectUnauthorized: true,
      ...(env.DB_SSL_CA ? { ca: readFileSync(env.DB_SSL_CA, 'utf8') } : {}) } } : {})
  };
}

export function createRepository(config) {
  const pool = mysql.createPool({ ...config, connectionLimit: 5, waitForConnections: true, queueLimit: 20 });
  return {
    async ping() { await pool.query({ sql: 'SELECT 1', timeout: 5000 }); },
    async list(limit, offset) {
      const [rows] = await pool.execute('SELECT id, name, description, price, stock, created_at AS createdAt FROM products ORDER BY id LIMIT ? OFFSET ?', [String(limit), String(offset)]);
      return rows;
    },
    async get(id) {
      const [rows] = await pool.execute('SELECT id, name, description, price, stock, created_at AS createdAt FROM products WHERE id = ?', [id]);
      return rows[0];
    },
    async create(data) {
      const [result] = await pool.execute('INSERT INTO products (name, description, price, stock) VALUES (?, ?, ?, ?)', [data.name, data.description, data.price, data.stock]);
      return this.get(result.insertId);
    },
    async update(id, data) {
      const [result] = await pool.execute('UPDATE products SET name = ?, description = ?, price = ?, stock = ? WHERE id = ?', [data.name, data.description, data.price, data.stock, id]);
      return result.affectedRows ? this.get(id) : undefined;
    },
    async remove(id) {
      const [result] = await pool.execute('DELETE FROM products WHERE id = ?', [id]);
      return result.affectedRows > 0;
    },
    async close() { await pool.end(); }
  };
}
