# Moodle Updater v2.0

A standalone Bash updater for existing Moodle installations. Downloaded Moodle
code is prepared and checked before maintenance starts. The updater preserves
contributed plugins, creates mandatory backups, swaps the code directory, runs
Moodle's own database upgrader as the web user, and restarts web/PHP workers.

## Requirements

- Linux, Bash **4.4+**, root, PHP **8.1+** with SimpleXML, and a working Moodle installation.
- `curl`, GNU `tar`, `find`, `cp`, `mv`, `du`, `df`, `stat`, `mktemp`, `runuser`,
  `systemctl`, and `crontab` unless `--cron-paused` is supplied.
- One active Apache (`apache2`/`httpd`) or Nginx service.
- `mysqldump` for MariaDB/MySQL, or `pg_dump` and `pg_restore` for PostgreSQL.
- The application's database user must be allowed to create a complete dump,
  including routines/triggers. A failed dump is fatal; a schema-only dump never
  counts as a backup.
- Separate, non-nested code and moodledata directories. The code directory must
  be a real directory on the same filesystem as its parent, not a deployment
  symlink or separate mount point.

The target release's `admin/environment.xml` supplies the PHP, extension,
intermediate-upgrade and database minimums. The **connected database server** is
checked, rather than the installed command-line client's version. For example,
Moodle 5.2 accepts MariaDB 10.11, while Moodle 5.3 requires MariaDB 11.4.
Moodle's own upgrader performs its full environment/plugin checks too.

PHP and database **package upgrades are separate operations**. The updater no
longer modifies package repositories, installs packages, or upgrades a database
server. The old `--allow-system-changes` flag exits with a migration message.

## Download and inspect

```bash
curl --fail --location \
  https://raw.githubusercontent.com/EverHype-Systems/moodle-update/main/updater.sh \
  -o updater.sh
bash -n updater.sh
bash updater.sh --help
```

The script embeds its PHP helper; no repository checkout, Python, Composer,
`jq`, or extra helper download is required at runtime. Use a pinned Git commit
instead of `main` when reproducing an approved deployment.

## Usage

Always rehearse major upgrades on an isolated copy of code, database and data.
Disable outbound mail and integrations on that copy. `--dry-run` validates a
plan; it does **not** execute a test database migration or prove plugin runtime
compatibility.

```bash
# Resolve a minor to its newest stable tag and inspect prerequisites.
sudo bash updater.sh --dry-run /var/www/moodle/moodle /var/www/moodle/moodledata 5.2

# Run the exact reviewed release with a complete independent local backup.
sudo bash updater.sh --yes \
  --backup-dir /mnt/backup/moodle \
  /var/www/moodle/moodle /var/www/moodle/moodledata 5.2.4

# Explicit alternative for large immutable content stores on the same filesystem.
sudo bash updater.sh --yes --backup-mode hardlink \
  /var/www/moodle/moodle /var/www/moodle/moodledata 5.2.4

# Development only: an explicit branch requires an explicit opt-in.
sudo bash updater.sh --allow-unstable /srv/staging/moodle /srv/staging/data main
```

`latest` selects the newest stable `vX.Y.Z` tag; it does not select the newest
version compatible with the existing server. If that release needs a newer
runtime/database, preflight stops. Select a supported release explicitly or
upgrade the server separately. Exact missing patch versions never silently
fall back to a stable/development branch. Prerelease tags and explicit branches
always require `--allow-unstable`; downloaded maturity and build numbers are
checked again, including same-minor build downgrades.

### Options

| Option | Behavior |
| --- | --- |
| `--yes`, `-y` | Skip the confirmation prompt; retain every safety check. |
| `--dry-run` | Download, stage and validate; do not swap code, migrate the DB, pause cron, enter maintenance, or change web configuration. Temporary files are removed. Moodle bootstrap may populate its caches; an external backup parent may be created for a capacity check. |
| `--backup-dir DIR` | Persistent backup parent, default `/var/backups/moodle`. Must be outside code and moodledata, and must not contain either directory. Each run gets a private unique subdirectory. |
| `--backup-mode copy` | Default: copy all local moodledata, including `filedir`. |
| `--backup-mode hardlink` | Hardlink only immutable content in `filedir`; copy the rest. Requires the same filesystem. This protects against deletion during an update, **not disk failure or in-place modifications**. Keep an independent/off-server backup too. |
| `--web-user USER` | PHP service account; defaults to the owner of `config.php`. If root owns the file, a non-root account with the same name as its service group is inferred; otherwise pass `--web-user`. Root is not accepted as the Moodle execution user. |
| `--fpm-service UNIT` | Repeatable site-specific PHP-FPM unit, e.g. `php8.3-fpm.service`. Defaults to an active service matching CLI PHP (or the generic `php-fpm.service`). Required for Nginx if no default can be detected; specify it for custom pools or when web PHP differs from CLI PHP. Unrelated FPM versions are not restarted. |
| `--preserve-path PATH` | Repeatable extra non-core path, relative to the old Moodle webroot. Refuses traversal, symlinks and collisions with new core code. |
| `--cron-paused` | Acknowledge that external/system cron and timers are already paused by the operator. Active workers are still checked. |
| `--allow-unstable` | Allow a prerelease tag or an explicit development branch such as `main`. |
| `--skip-webroot-update` | Leave web configuration to the operator. It must point at `public/` when the target uses it. |
| `--no-restart` | Finish migration but leave CLI maintenance and cron paused. Exit **2** with recovery paths. Restart workers and finish verification manually before reopening. |

Set `PHP_BIN=/absolute/path/to/php` to use a specific PHP interpreter.

### Plugins and customizations

Contributed plugins are discovered through Moodle's plugin manager, including
nested subplugins. Their code is copied to the corresponding path in the new
webroot. Declared Moodle minimums and supported branch ranges are checked;
Moodle subsequently checks all plugin dependencies before migration. Plugins
are retained at their current version, **not automatically downloaded or
upgraded**. Undeclared compatibility still needs a staging test.

Already missing plugins are reported; they are not uninstalled and their data
is not deleted. Preserved paths cannot overwrite target core components.
Symlinked/out-of-tree plugins require an operator-led deployment. Git/SVN/Hg
metadata is excluded from preserved plugin trees. Uncommitted tracked core
changes cause preflight to stop. Untracked custom root files and modifications
in non-Git deployments cannot be inferred reliably: review and port them before
upgrading; use `--preserve-path` for additional non-core files. A Git checkout is
replaced by release-archive code; its original Git history remains in the backup.

## Operational sequence

1. Acquire a per-code-directory lock and create private working directories.
2. Read the running site's metadata as its web user. Validate paths and the
   selected active web service.
3. Check staging capacity, resolve a release tag, download once, reject unsafe archive paths/links, and
   extract a staged tree on the code filesystem.
4. Read target requirements; prevent downgrades; preserve contributed plugins,
   extra paths, and configuration. Prepare the `public/` bootstrap when needed.
5. Check backup capacity with headroom and verify backup tooling/cron sources.
   Confirm the reviewed plan unless `--yes` is set.
6. Pause matching Moodle entries in root/web-user crontabs. Other cron entries
   continue running. Enter CLI maintenance and wait up to 120 seconds for
   existing workers. An idle sleeping worker is terminated only when Moodle
   reports no active scheduled/ad-hoc tasks. A busy worker is never killed.
7. Copy code and all local moodledata, then dump the database. Record metadata,
   dump SHA-256, paths and saved crontabs. Write `BACKUP_COMPLETE` only after
   every backup operation succeeds.
8. Swap the code directories using renames on the same filesystem. The old tree
   is retained until the update succeeds. Code is owned by root, readable by
   the service group; `config.php` is `0640`. Source executable bits are retained.
9. Back up and update **exact** Apache/Nginx root directives. Already-correct
   `/public` roots stay unchanged, as do neighboring paths such as `moodle2`.
   Validate server configuration before proceeding.
10. Run Moodle's upgrader and cache purge as the web user with
    `max_input_vars=5000` for CLI commands. Verify no upgrade is pending and the
    installed DB build matches the downloaded code. Persistent PHP settings are
    not rewritten; web PHP must already meet Moodle's requirements.
11. Restart the detected web service and selected PHP-FPM services; check their
    service state. Restore the original CLI-maintenance state and cron entries.
    Remove temporary staging state only after success. Retain the backup,
    `before.json`, `after.json`, `upgrade.log`, and `UPDATE_COMPLETE`.

Crontabs in `/etc/crontab` or `/etc/cron.d` that explicitly invoke this Moodle
path are detected and require external pausing plus `--cron-paused`. Systemd
timers, relative/wrapper invocations, containers and remote schedulers cannot
be reliably discovered. Operators using those mechanisms must pause them too.
The local directory lock protects against this updater running twice, not other
deployment tools. Source archive downloads use HTTPS; the recorded dump hash
checks the backup file, not publisher authentication of the release archive.

## Failure and recovery

The script never prints a success message after a failed dump, migration, cache
purge, service restart, or maintenance cleanup. Database passwords are read with
`CLI_SCRIPT` defined and put in mode-0600 connection files, not command arguments
or progress logs. Connection files are removed on normal exits and handled
signals. Do not run under `bash -x`, which would expose private operational data.

**Before migration starts:** an incomplete backup stops the operation before
code replacement. If installation or web configuration fails after the rename,
the updater restores the original code/configuration and previous maintenance/
cron state. If recovery itself fails, it retains diagnostic state and reports it.

**After migration may have started:** no automatic rollback is attempted.
A migration may have committed schema/data changes. New code, CLI maintenance
and paused cron remain in place. The private working directory and backup paths
are printed so the operator can repair the upgrade or restore a consistent set.
The same controlled handoff applies to `--no-restart` (exit 2).

Recovery requires operator review:

1. Keep the site in CLI maintenance and all of its schedulers paused.
2. Verify `BACKUP_COMPLETE`, the dump hash, and the recorded paths in `paths.txt`.
3. Either repair and rerun Moodle's CLI upgrader, or restore **code, database and
   moodledata from the same backup**. Do not overlay old code onto new code: remove
   the failed tree from service first so obsolete/new files cannot remain mixed.
   Import MariaDB/MySQL `database.sql` with an authorized client; restore the
   PostgreSQL custom-format `database.dump` with `pg_restore` into a clean DB.
4. Restore changed web-server files from `webserver/etc/...`, validate the
   configuration, restart the relevant web/PHP services and verify the site.
5. If the site was originally online, run Moodle's `admin/cli/maintenance.php
   --disable` as its web user. The moodledata snapshot includes the maintenance
   file created for backup consistency; it must not accidentally leave a
   restored site blocked. Preserve maintenance if it was already active before
   the update (`initial_cli_maintenance=true` in `paths.txt`).
6. Restore saved crontabs, merging any unrelated edits made since the backup.
   Keep backups until the update and application-level checks are accepted.

Locks are removed after handled failures. SIGKILL/power loss can leave a stale
`.moodle-updater-<directory>.lock` next to the code. Verify there is no active
update and inspect private working state before removing that lock or retrying.
No unattended updater can guarantee recovery after disk failure or SIGKILL.

## Verification and development

```bash
bash -n updater.sh
bash updater.sh --help
shellcheck updater.sh
python3 tests/test_updater.py
```

Tests are offline and use temporary fixtures. They cover stable/dev resolution,
missing patch rejection, requirement gates, plugin preservation, exact/idempotent
webroot changes, archive validation, secret handling, cron merging, backup/disk
failures, and recovery before/after the database-migration boundary.
CI runs them on Ubuntu 22.04 and 24.04. Real upgrades must additionally be
rehearsed against an isolated database/site copy. A successful CLI update and
service restart do not replace application checks for login, course access,
uploads, plugins and mail; the updater does not send test mail or impersonate users.

## Changes from v1.1

- Fail closed on incomplete backups; full local moodledata coverage and capacity
  checks; persistent backups with explicit copy/hardlink semantics.
- Prepare downloads before downtime; preserve plugins and explicit extra paths.
- Read actual target/server requirements, including changed MariaDB minimums.
- Replace unsafe package/repository upgrades with explicit prerequisite failures.
- Protect concurrent runs; pause cron; preserve pre-existing maintenance state;
  distinguish pre-migration rollback from post-migration recovery.
- Fix `/public/public` rewrites; validate/restart workers before reopening.
- Run Moodle as its service user and keep code/configuration permissions narrow.
- Add offline regression tests and CI. No claim of automatic plugin compatibility
  checking or database recovery beyond the checks described above.
