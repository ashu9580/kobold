# User-level Linux deployment

This deployment profile runs the Kobold Discord client and a private PostgreSQL
server as systemd user services. It is intended for the existing `pf2ebot`
account, which has Node.js 24 but does not have sudo or Docker access.

The installer:

- reuses the Discord token, application ID, and guild ID from
  `~/.config/pathwarden/pathwarden.env` without printing them;
- installs an ARM64 PostgreSQL runtime inside the user's home directory;
- creates a password-protected database listening only on `127.0.0.1:54321`;
- builds the configured Kobold fork and runs all database migrations;
- takes a final Pathwarden backup, disables Pathwarden, and starts Kobold; and
- restores Pathwarden automatically if the Kobold service fails its initial
  service check.

Run `install.sh` from a directory containing both service unit files. Override
the source repository or ref with `KOBOLD_REPO_URL` and `KOBOLD_REPO_REF`.

Secrets are stored with mode `0600` in `~/.config/kobold/kobold.env`. The old
Pathwarden release and data remain untouched for manual rollback.

The first deployment enables a one-time Nethys import on startup. After the log
contains `Job 'Nethys Import' initial run completed.`, change
`JOBS_NETHYS_IMPORT_RUN_ON_START` to `false`; later installer runs preserve that
setting.
