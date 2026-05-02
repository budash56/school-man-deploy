# SchoolMan Deployment

SchoolMan Deployment is the Docker Compose wrapper for running the full SchoolMan stack together. It does not contain the application source code; it coordinates the backend, frontend, scanner, and PostgreSQL database from sibling repositories.

Use this repository when you want to run SchoolMan as a complete environment instead of starting each service manually.

## What It Runs

The deployment stack includes:

- PostgreSQL for application data.
- SchoolMan Backend for authentication, business rules, and APIs.
- SchoolMan Frontend for the staff dashboard.
- SchoolScanner for OCR-assisted planilla scanning.
- Nginx for serving the frontend and proxying browser `/api` requests to the backend.

## Repository Layout

The deployment expects this sibling folder layout:

```text
schoolMan/
  school-man-back/
  school-man-front/
  school-man-scanner/
  school-man-deploy/
```

The Compose file builds the app containers from those sibling repositories. If one is missing or renamed, the build will fail.

## What Each File Is For

- `docker-compose.yml`: defines the database, scanner, backend, and frontend containers.
- `nginx/default.conf`: serves the React app and proxies `/api` traffic to the backend.
- `.env.example`: template for deployment configuration.
- `SchoolManBeta.sql`: database dump used to initialize a fresh deployment database.

## Getting Started

Create the environment file:

```bash
cp .env.example .env
```

Edit `.env` and confirm database, JWT, email, and scanner values. Inside Docker Compose, service hostnames should use container names, for example:

```dotenv
DATABASE_URL=postgres://postgres:change-me@db:5432/schoolmg
DB_MIGRATIONS_RUN=false
SCANNER_BASE_URL=http://scanner:8010
SCANNER_TIMEOUT_MS=120000
SCHOOL_SCANNER_OCR_ENGINE=tesseract
```

Build and start the stack:

```bash
docker compose build
docker compose up -d
```

Open the app:

```text
http://localhost:8080
```

## Database Options

On first startup, PostgreSQL imports `SchoolManBeta.sql` automatically from `/docker-entrypoint-initdb.d`. The backend is configured with `DB_MIGRATIONS_RUN=false`, so database creation comes from the SQL dump rather than TypeORM migrations.

This import only happens when the Docker volume is empty. If you already started the stack and want to rebuild the database from the SQL dump, remove the database volume first:

```bash
docker compose down -v
docker compose up -d
```

Use `down -v` carefully: it deletes the local database volume.

## Day-To-Day Operations

Start or restart everything:

```bash
docker compose up -d
```

View logs:

```bash
docker compose logs -f
```

Rebuild after changing source repositories:

```bash
docker compose build
docker compose up -d
```

Back up the database:

```bash
mkdir -p backups
docker compose exec -T db sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > backups/schoolman-$(date +%F).sql
```

## Production Notes

- Replace all placeholder secrets before real deployment.
- Put a real TLS-terminating proxy or load balancer in front of the stack for public access.
- Avoid exposing the backend or database directly to the internet.
- Keep the scanner container running for planilla OCR workflows.
- The bundled Nginx config allows planilla image uploads up to 25 MB and keeps `/api` proxy reads open long enough for OCR fallback work.
