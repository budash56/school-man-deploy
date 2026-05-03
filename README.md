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
- `docker-compose.production.yml`: production override; testing-only frontend controls are disabled.
- `docker-compose.testing.yml`: testing override; enables test helper controls such as random planilla IDs and random grades.
- `nginx/default.conf`: serves the React app and proxies `/api` traffic to the backend.
- `.env.example`: template for deployment configuration.
- `.env.production.example`: production environment template.
- `.env.testing.example`: testing environment template.
- `SchoolManBeta.sql`: database dump used to initialize a fresh deployment database.

## Getting Started

Install Docker Desktop or Docker Engine with the Compose plugin, then confirm Compose is available:

```bash
docker --version
docker compose version
```

Fast path: run the LAN startup script. It detects this machine's local IP, creates the matching environment file when missing, writes the detected IP into `BIND_ADDRESS`, fills safe deployment defaults, builds the containers, starts the stack, and prints the URL for other devices.

Production:

```bash
./scripts/start-production.sh
```

Testing:

```bash
./scripts/start-testing.sh
```

Production runs on port `8080`. Testing runs on port `8081` and shows testing-only buttons such as random planilla IDs and random grades.

Use the printed LAN URL from another device on the same Wi-Fi/LAN. Production example:

```text
http://192.168.100.22:8080
```

Testing example:

```text
http://192.168.100.22:8081
```

Manual setup is below if you prefer to run the Compose commands yourself.

Create the production environment file:

```bash
cp .env.production.example .env.production
```

Or create the testing environment file:

```bash
cp .env.testing.example .env.testing
```

Edit the chosen file and confirm database, JWT, email, ports, and scanner values. Inside Docker Compose, service hostnames should use container names, for example:

```dotenv
DATABASE_URL=postgres://postgres:change-me@db:5432/schoolmg
DB_MIGRATIONS_RUN=true
BIND_ADDRESS=0.0.0.0
FRONT_PORT=8080
BACK_PORT=3000
VITE_ENABLE_TEST_FEATURES=false
SCANNER_BASE_URL=http://scanner:8010
SCANNER_TIMEOUT_MS=120000
SCHOOL_SCANNER_OCR_ENGINE=tesseract
```

Build and start production manually:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml build
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml up -d
```

Build and start testing manually:

```bash
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml build
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml up -d
```

Check that every container is running:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml ps
```

Open production:

```text
http://localhost:8080
```

Open testing:

```text
http://localhost:8081
```

## Production And Testing

Production and testing are separate Compose projects with separate container names, ports, and database volumes.

- Production project: `school-man-production`
- Production frontend: `http://localhost:8080`
- Production backend port: `3000`
- Production test helpers: disabled
- Testing project: `school-man-testing`
- Testing frontend: `http://localhost:8081`
- Testing backend port: `3001`
- Testing test helpers: enabled

This means you can keep production data separate from testing data. If both stacks are running, use the port to choose which one you are opening.

## Access From Other Devices On The Same Network

The easiest way is:

```bash
./scripts/start-production.sh
```

It prints both the local URL and the URL that another device should use.

The stack publishes the frontend and backend on `BIND_ADDRESS`.

When you run:

```bash
./scripts/start-production.sh
```

the script writes the detected LAN IP into `.env.production`, for example:

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
- Check that Compose `ps` shows `YOUR_LOCAL_IP:8080->80/tcp` for production or `YOUR_LOCAL_IP:8081->80/tcp` for testing.
- Allow incoming connections to Docker/port `8080` for production or `8081` for testing in the host firewall.
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

## Clear Testing Data But Keep Admins

Use this only on the testing stack. It removes school data, imported timetables, planillas, students, teachers, courses, subjects, classrooms, and school years, but keeps users whose role is `admin`.

Make sure the testing stack is running:

```bash
./scripts/start-testing.sh
```

Then run:

```bash
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml exec -T db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' <<'SQL'
BEGIN;

TRUNCATE TABLE
  public.attendance,
  public.audit_logs,
  public.buildings,
  public.calendar_events,
  public.class_group_curriculum_overrides,
  public.class_group_fixed_locations,
  public.class_groups,
  public.classrooms,
  public.course_instances,
  public.courses,
  public.curricula,
  public.curriculum_items,
  public.disciplinary_records,
  public.enrollments,
  public.grade_scheme_values,
  public.grade_schemes,
  public.grades,
  public.notifications,
  public.planilla_sheets,
  public.school_years,
  public.students,
  public.subject_areas,
  public.subjects,
  public.teacher_subjects,
  public.terms,
  public.timetable_assignments,
  public.timetable_slots
RESTART IDENTITY CASCADE;

DELETE FROM public.users WHERE role <> 'admin';
ALTER SEQUENCE IF EXISTS public.print_generation_seq RESTART WITH 1;

COMMIT;
SQL
```

After this reset, sign in with an admin user, create a school year, and import the timetable PDF from `/dashboard/timetable`.

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
