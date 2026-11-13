# CA públicas de Amazon RDS

`rds-global-bundle.pem` es el bundle público global obtenido el 2026-11-13 de
[AWS RDS Trust Store](https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem).
Se incluye en la imagen para verificar TLS de RDS en las regiones comerciales
que puede elegir el alumno. No contiene passwords, claves privadas ni credenciales.

Los scripts generan `DB_SSL_CA=/app/certs/rds-global-bundle.pem`. El bundle
regional anterior se conserva como referencia, pero el recorrido portable usa
el global. Renovar desde el origen oficial antes de su caducidad y reconstruir
la imagen; no resolver fallos de CA desactivando `rejectUnauthorized`.
