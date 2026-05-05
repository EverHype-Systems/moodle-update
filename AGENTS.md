# Agent Instructions

This repository contains a production Moodle updater. Treat every change as operationally risky.

## Updater Safety Rules

- Keep `updater.sh` dependency-light. It must continue to work after `curl -o updater.sh ... && bash updater.sh ...` on a minimal Ubuntu/Debian server.
- Do not perform package manager, database server, or PHP version changes unattended unless the user explicitly opts in. The script uses `--allow-system-changes` for those upgrades.
- Web server root changes for Moodle `public/` must be backed up first and remain skippable with `--skip-webroot-update`.
- Resolve Moodle downloads before changing local files. Stable releases must use GitHub `vX.Y.Z` tags. Dev or unreleased targets such as `5.3dev` must require `--allow-unstable`.
- Moodle `config.php` must be read with `CLI_SCRIPT` defined. Do not include it from PHP one-liners without that guard.
- Moodle 5.1+ contains a `public/` webroot. Any updater change that installs those versions must account for Apache/Nginx `DocumentRoot` or `root` updates.
- Do not append maintenance flags after Moodle's `require_once(.../lib/setup.php)` line. Use Moodle CLI maintenance commands first, and only fall back to editing `config.php` before setup is required.
- Keep backup paths as explicit variables. Do not capture logging output into variables that later become filesystem paths.

## Verification

Before handing off changes:

- Run `bash -n updater.sh`.
- Run `bash updater.sh --help`.
- Verify target resolution for `latest`, a stable minor such as `5.2`, and any requested dev target such as `5.3 --allow-unstable`.
- If package, PHP, database, or web server behavior changes, document the operational impact in `README.md`.
