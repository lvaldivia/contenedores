import mysql from 'mysql2/promise';
import { databaseConfig } from './db.mjs';

const config = databaseConfig();
const connection = await mysql.createConnection({ ...config,
  user: process.env.DB_ADMIN_USER || config.user,
  password: process.env.DB_ADMIN_PASSWORD || config.password
});
try {
  await connection.query(`CREATE TABLE IF NOT EXISTS products (
    id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(120) NOT NULL,
    description VARCHAR(1000) NOT NULL DEFAULT '',
    price DECIMAL(10,2) NOT NULL,
    stock INT NOT NULL DEFAULT 0,
    created_at TIMESTAMP(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
    CONSTRAINT positive_price CHECK (price >= 0),
    CONSTRAINT positive_stock CHECK (stock >= 0)
  )`);
  if (process.env.DB_ADMIN_USER) {
    if (!/^[a-zA-Z][a-zA-Z0-9_]{0,31}$/.test(config.user) || !/^[a-zA-Z][a-zA-Z0-9_]{0,63}$/.test(config.database)) throw new Error('Usuario o base no validos');
    await connection.query("CREATE USER IF NOT EXISTS ?@'%' IDENTIFIED BY ?", [config.user, config.password]);
    await connection.query("ALTER USER ?@'%' IDENTIFIED BY ?", [config.user, config.password]);
    await connection.query(`GRANT SELECT, INSERT, UPDATE, DELETE ON \`${config.database}\`.* TO ?@'%'`, [config.user]);
  }
  console.log('Tabla products inicializada.');
} catch (err) {
  console.error('No se pudo inicializar la base de datos:', err.code || 'INIT_FAILED');
  process.exitCode = 1;
} finally { await connection.end(); }
