# SchoolMan Deployment

This repository is the deployment wrapper for the SchoolMan stack. It does not contain the application source code itself; it builds the backend from `../school-man-back`, the frontend from `../school-man-front`, the scanner from `../school-man-scanner`, and runs them together with PostgreSQL through Docker Compose.

## What Is Here

- `docker-compose.yml`: runs `db`, `scanner`, `back`, and `front`
- `nginx/default.conf`: SPA routing and `/api` proxy from the frontend container to the backend container
- `SchoolManBeta.sql`: logical PostgreSQL backup with schema, migrations table, and seed data
- `.env`: deployment-time secrets and runtime configuration

## Set Up

Follow these steps on a new machine to pull the repositories, install the required tooling, and start the stack.

### 1. Install the required tools

You need these tools installed before cloning or deploying:

- `git`
- Docker with `docker compose` support

On macOS or Windows, Docker Desktop is the simplest option because it includes both Docker Engine and the Compose plugin. On Linux, install Docker Engine and the Docker Compose plugin.

Verify the tools are available:

```bash
git --version
docker --version
docker compose version
```

You do not need to install Node.js, npm, or PostgreSQL on the host machine for this deployment flow because the backend, frontend, and database all run inside Docker containers.

### 2. Clone the repositories into the expected sibling layout

The Compose file uses relative build contexts, so the four repositories must sit next to each other in the same parent directory:

```text
schoolMan/
  school-man-scanner/
  school-man-back/
  school-man-front/
  school-man-deploy/
```

If this deployment repository is already cloned, go to its parent directory and make sure the application repositories are cloned next to it:

```bash
cd ..
git clone https://github.com/budash56/school-man-scanner.git school-man-scanner
git clone https://github.com/budash56/SchoolManagementBack.git school-man-back
git clone https://github.com/budash56/SchoolManagementFront.git school-man-front
git clone https://github.com/budash56/school-man-deploy.git school-man-deploy
cd school-man-deploy
```

If `school-man-scanner`, `school-man-back`, or `school-man-front` are missing or renamed, `docker compose build` will fail.

### 3. Create the deployment environment file

Use the example file as the starting point:

```bash
cp .env.example .env
```

Then update `.env` with the real values for your environment.

At minimum, confirm these values are correct:

- `POSTGRES_DB`
- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `DATABASE_URL`
- `JWT_SECRET`
- `SCANNER_BASE_URL`
- `EMAIL_*` values if SMTP is enabled

Important: inside Docker Compose, the database host in `DATABASE_URL` must be `db`, not `localhost`.

Example:

```dotenv
DATABASE_URL=postgres://postgres:change-me@db:5432/schoolmg
SCANNER_BASE_URL=http://scanner:8010
```

### 4. Build the containers

From `school-man-deploy`, build all images:

```bash
docker compose build
```

### 5. Start PostgreSQL and the scanner

Start the database and scanner containers first:

```bash
docker compose up -d db scanner
```

Wait until PostgreSQL is ready:

```bash
docker compose exec db sh -lc 'pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
```

### 6. Initialize the database

Choose one initialization path.

Option A, start with an empty database and let the backend run migrations:

```bash
docker compose up -d back front
```

Option B, restore the provided seed database from `SchoolManBeta.sql` and then start the app:

```bash
docker compose exec -T db sh -lc 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < SchoolManBeta.sql
docker compose up -d back front
```

Use the SQL restore only on a new or intentionally reset database.

### 7. Open the application

After the containers are running, open:

- Frontend: `http://localhost:8080`
- Backend API: `http://localhost:3000`

## Environment Variables

Use `.env.example` as the template. The critical values are:

- `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `DATABASE_URL`
- `JWT_SECRET`
- `EMAIL_*` if SMTP is enabled

Important: inside Docker Compose, the database host in `DATABASE_URL` must be `db`, not `localhost`.

Example:

```dotenv
DATABASE_URL=postgres://postgres:change-me@db:5432/schoolmg
```

## Frontend API Base URL

The frontend defaults to `/api` when `VITE_API_BASE_URL` is unset, which matches this deployment because Nginx proxies `/api/` to `back:3000`.

If you override the frontend environment in `../school-man-front/.env.local`, keep `VITE_API_BASE_URL=/api` unless you intentionally want the browser to call an external absolute API URL.

## Database Restore Caveat

`SchoolManBeta.sql` was dumped from PostgreSQL `17.3`, while `docker-compose.yml` currently runs `postgres:16`.

That matters because the dump includes PostgreSQL 17 statements such as:

- `SET transaction_timeout = 0;`

If you plan to restore `SchoolManBeta.sql` as-is, align the runtime database with PostgreSQL 17 or preprocess the dump before importing it. Starting with an empty database and letting the backend run migrations does not depend on the dump.

## Public Deployment Notes

- The bundled Nginx config is an internal app server only. It listens on plain HTTP and uses `server_name _;`.
- For internet-facing deployments, put a real reverse proxy or load balancer in front of port `8080` and terminate TLS there.
- Avoid exposing port `3000` publicly unless you intentionally want direct backend access.
- Replace all placeholder secrets before production use.

## Day-2 Operations

Start or restart everything:

```bash
docker compose up -d
```

View logs:

```bash
docker compose logs -f
```

Rebuild after updating the backend or frontend sibling repositories:

```bash
docker compose build back front
docker compose up -d back front
```

Create a backup:

```bash
mkdir -p backups
docker compose exec -T db sh -lc 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB"' > backups/schoolman-$(date +%F).sql
```
