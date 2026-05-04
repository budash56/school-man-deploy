# SchoolMan Deployment Manual

This repository is the easiest way to run the complete SchoolMan system with Docker. It starts the database, backend, frontend, scanner service, and Nginx proxy together, so the system can be opened from the host computer or from other devices on the same local network.

SchoolMan is split into four sibling repositories:

```text
schoolMan/
  school-man-back/
  school-man-front/
  school-man-scanner/
  school-man-deploy/
```

Keep that folder structure. The deployment builds the application containers from those sibling folders.

## Before You Start

Install these tools first:

- Git, to clone and update the repositories.
- Docker Desktop, or Docker Engine with the Docker Compose plugin.

Check that they are available:

```bash
git --version
docker --version
docker compose version
```

Docker must be running before starting SchoolMan.

## First Installation

Clone or place all four repositories inside the same `schoolMan` folder:

```bash
mkdir -p ~/schoolMan
cd ~/schoolMan

git clone https://github.com/budash56/SchoolManagementBack.git school-man-back
git clone https://github.com/budash56/SchoolManagementFront.git school-man-front
git clone https://github.com/budash56/school-man-scanner.git school-man-scanner
git clone https://github.com/budash56/school-man-deploy.git school-man-deploy
```

Then enter the deployment repository:

```bash
cd ~/schoolMan/school-man-deploy
```

## Recommended Start

Use the startup scripts. They detect the computer's local IP address, write it into the correct `.env` file, build the containers, start the stack, and print the URL to open.

Production:

```bash
./scripts/start-production.sh
```

Testing:

```bash
./scripts/start-testing.sh
```

Production opens on port `8080`. Testing opens on port `8081` and enables testing-only controls.

Example output:

```text
Open on this machine:      http://localhost:8080
Open from another device:  http://192.168.68.114:8080
```

Use the second URL from phones, tablets, or other computers connected to the same Wi-Fi/LAN.

If your shell says `command not found`, run the script with `./` from inside `school-man-deploy`:

```bash
cd ~/schoolMan/school-man-deploy
./scripts/start-production.sh
```

## Production Or Testing

Use production for real data:

```bash
./scripts/start-production.sh
```

Use testing when you need random IDs, random grades, test helpers, or a disposable environment:

```bash
./scripts/start-testing.sh
```

The two environments use different Compose projects, ports, and database volumes:

- Production project: `school-man-production`
- Production URL: `http://localhost:8080`
- Production backend port: `3000`
- Testing project: `school-man-testing`
- Testing URL: `http://localhost:8081`
- Testing backend port: `3001`

## What The Script Changes

The script creates `.env.production` or `.env.testing` if it does not exist. It also updates these values:

```dotenv
COMPOSE_PROJECT_NAME=school-man-production
DEPLOYMENT_NAME=school-man-production
BIND_ADDRESS=192.168.68.114
DB_MIGRATIONS_RUN=true
FRONT_PORT=8080
BACK_PORT=3000
VITE_ENABLE_TEST_FEATURES=false
SCANNER_BASE_URL=http://scanner:8010
SCANNER_TIMEOUT_MS=120000
SCHOOL_SCANNER_OCR_ENGINE=tesseract
```

`BIND_ADDRESS` is the detected local IP. That is what lets other local devices reach the system.

For testing, the script writes testing values such as port `8081` and `VITE_ENABLE_TEST_FEATURES=true`.

## First Login And Daily Use

After the containers are running, open the printed URL in the browser.

Use the admin account that exists in the database dump. After logging in, the normal setup flow is:

1. Check or create the active school year.
2. Create areas and subjects if they are missing.
3. Import curriculum and class groups from the ASC Horarios course schedule.
4. Import professors, workload, and timetable relationships from the ASC Horarios professor schedule.
5. Review classrooms, users, enrollment, planillas, attendance, calendar, and documents from the admin menu.

The timetable imports are designed to complement each other. The course schedule import creates academic structure such as groups, courses, and curriculum. The professor schedule import adds professors, course relationships, workload, and class sessions.

## Database Initialization

Fresh deployments create the database from `SchoolManBeta.sql`, not from the ORM schema alone.

How it works:

- `docker-compose.yml` mounts `SchoolManBeta.sql` into the Postgres container.
- Postgres runs that SQL automatically only when the database volume is empty.
- The backend then runs pending migrations with `DB_MIGRATIONS_RUN=true`.
- Migrations only apply if they have not already been recorded.

This means first startup can take longer while the database is imported.

Watch database logs:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml logs -f db
```

Watch backend logs:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml logs -f back
```

## Common Commands

Show production containers:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml ps
```

Stop production:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml down
```

Start production again:

```bash
./scripts/start-production.sh
```

Show testing containers:

```bash
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml ps
```

Stop testing:

```bash
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml down
```

## Reset The Database

Only do this when you intentionally want to delete the local database volume and recreate it from `SchoolManBeta.sql`.

Production reset:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml down -v
./scripts/start-production.sh
```

Testing reset:

```bash
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml down -v
./scripts/start-testing.sh
```

`down -v` deletes the local database volume. Create a backup first if you need the data later.

## Manual Start Without The Script

Production:

```bash
cp .env.production.example .env.production
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml build
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml up -d
```

Testing:

```bash
cp .env.testing.example .env.testing
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml build
docker compose --env-file .env.testing -p school-man-testing -f docker-compose.yml -f docker-compose.testing.yml up -d
```

For manual LAN access, set `BIND_ADDRESS` in the chosen `.env` file:

```dotenv
BIND_ADDRESS=0.0.0.0
```

or use the computer's local IP:

```dotenv
BIND_ADDRESS=192.168.68.114
```

On macOS, you can check the IP with:

```bash
ipconfig getifaddr en0
```

If that returns nothing:

```bash
ipconfig getifaddr en1
```

## Troubleshooting

If another device cannot open SchoolMan:

- Confirm both devices are on the same network.
- Confirm Docker is running.
- Use the URL printed by the startup script.
- Check that the frontend container is publishing `8080` for production or `8081` for testing.
- Allow incoming connections to Docker or the selected port in the host firewall.
- Open the frontend URL only. Browser API calls go through `/api` on the same host.

If scanner imports fail:

- Check that the scanner container is running.
- Keep `SCANNER_BASE_URL=http://scanner:8010` inside Docker.
- Check scanner logs from the deployment repository:

```bash
docker compose --env-file .env.production -p school-man-production -f docker-compose.yml -f docker-compose.production.yml logs -f scanner
```

If a change does not appear after pulling updates:

```bash
git pull
./scripts/start-production.sh
```

The script rebuilds the containers before starting them.
