# Alert Database (PostgreSQL)

This container runs PostgreSQL and stores data for the alert management system.

## Connection (authoritative)

Per container convention, always use `db_connection.txt`:

```bash
cat db_connection.txt
# psql postgresql://appuser:dbuser123@localhost:5000/myapp
```

You can also connect directly:

```bash
psql -h localhost -U appuser -d myapp -p 5000
```

## Apply schema migrations + seed data

After starting the database (`startup.sh`), run:

```bash
./apply_migrations.sh
```

This will:
- create/upgrade the schema from `migrations/`
- load seed data from `seed/`
- record applied versions in `schema_migrations`

## Schema overview

Core tables:
- `users`, `roles`, `permissions`, `user_roles`, `role_permissions`
- `templates`
- `user_preferences`
- `alerts`, `alert_user_overrides`
- `notification_runs`, `notification_logs`, `in_app_notifications`
- `alert_daily_stats`, `channel_daily_stats`

## Notes for backend integration

The backend should connect using the same connection string / env vars:
- `POSTGRES_URL`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_PORT`

In this workspace, the startup script also generates `db_visualizer/postgres.env` for the DB viewer.
