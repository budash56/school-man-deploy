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

Install Docker Desktop or Docker Engine with the Compose plugin, then confirm Compose is available:

```bash
docker --version
docker compose version
```

Fast path: run the LAN startup script. It detects this machine's local IP, creates `.env` from `.env.example` when missing, writes the detected IP into `BIND_ADDRESS`, fills safe deployment defaults, builds the containers, starts the stack, and prints the URL for other devices:

```bash
./scripts/start-lan.sh
```

Use the printed LAN URL from another device on the same Wi-Fi/LAN, for example:

```text
http://192.168.100.22:8080
```

Manual setup is below if you prefer to run the Compose commands yourself.

Create the environment file:

```bash
cp .env.example .env
```

Edit `.env` and confirm database, JWT, email, and scanner values. Inside Docker Compose, service hostnames should use container names, for example:

```dotenv
DATABASE_URL=postgres://postgres:change-me@db:5432/schoolmg
DB_MIGRATIONS_RUN=true
BIND_ADDRESS=0.0.0.0
SCANNER_BASE_URL=http://scanner:8010
SCANNER_TIMEOUT_MS=120000
SCHOOL_SCANNER_OCR_ENGINE=tesseract
```

Build and start the stack:

```bash
docker compose build
docker compose up -d
```

Check that every container is running:

```bash
docker compose ps
```

Open the app:

```text
http://localhost:8080
```

## Access From Other Devices On The Same Network

The easiest way is:

```bash
./scripts/start-lan.sh
```

It prints both the local URL and the URL that another device should use.

The stack publishes the frontend and backend on `BIND_ADDRESS`.

When you run:

```bash
./scripts/start-lan.sh
```

the script writes the detected LAN IP into `.env`, for example:

```dotenv
BIND_ADDRESS=192.168.100.22
```

Manual setup can still use the all-interfaces default:

```dotenv
BIND_ADDRESS=0.0.0.0
```

`0.0.0.0` means Docker listens on all network interfaces of the host machine. A specific IP, such as `192.168.100.22`, binds deployment to that interface.

On macOS, find the local IP with:

```bash
ipconfig getifaddr en0
```

If that returns nothing, try:

```bash
ipconfig getifaddr en1
```

Then open this from another device on the same network:

```text
http://YOUR_LOCAL_IP:8080
```

Example:

```text
http://192.168.100.22:8080
```

If another device cannot connect:

- Make sure both devices are on the same network.
- Make sure Docker is running.
- Check that `docker compose ps` shows `YOUR_LOCAL_IP:8080->80/tcp` or `0.0.0.0:8080->80/tcp` for `front`.
- Allow incoming connections to Docker/port `8080` in the host firewall.
- Use the frontend URL only; browser traffic to the backend goes through `/api` on the same frontend host.

## Database Initialization

This deployment creates the initial database from `SchoolManBeta.sql`, then lets the backend run any newer TypeORM migrations that are not already recorded in the `migrations` table.

How it works:

- `docker-compose.yml` mounts `SchoolManBeta.sql` into the Postgres container at `/docker-entrypoint-initdb.d/01-schoolman.sql`.
- The official Postgres image automatically runs files in that folder only when the database volume is empty.
- The SQL dump includes the migration baseline for the schema it contains.
- The backend receives `DB_MIGRATIONS_RUN=true`, so it applies only migrations that have not already been recorded.
- The backend waits for the Postgres healthcheck before starting.

For a first-time setup, the normal start command is enough:

```bash
docker compose up -d
```

Watch the database import if needed:

```bash
docker compose logs -f db
```

After import, verify that the backend and frontend started:

```bash
docker compose ps
docker compose logs --tail=100 back
```

## Reset Database From SQL

The SQL import does not run again while the existing Postgres volume remains. To intentionally delete the local database and recreate it from `SchoolManBeta.sql`, run:

```bash
docker compose down -v
docker compose up -d
```

Use `down -v` carefully: it deletes the local database volume.

If you need to preserve data, create a backup before resetting.

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

Rebuild only one service:

```bash
docker compose build back
docker compose up -d back
```

Restart OCR scanner after scanner changes:

```bash
docker compose build scanner
docker compose up -d scanner back front
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
