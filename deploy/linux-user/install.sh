#!/usr/bin/env bash
set -euo pipefail

repo_url="${KOBOLD_REPO_URL:-https://github.com/ashu9580/kobold.git}"
repo_ref="${KOBOLD_REPO_REF:-main}"
postgres_package_version="18.4.0-beta.17"
postgres_port="54321"

node_home="${HOME}/.local/node/bin"
app_root="${HOME}/kobold"
config_dir="${HOME}/.config/kobold"
unit_dir="${HOME}/.config/systemd/user"
runtime_dir="${HOME}/kobold-postgres-runtime"
postgres_data_dir="${app_root}/data/postgres"
postgres_socket_dir="${app_root}/data/postgres-socket"
old_environment_file="${HOME}/.config/pathwarden/pathwarden.env"
environment_file="${config_dir}/kobold.env"
release_id="$(date -u +%Y%m%dT%H%M%SZ)"
source_dir="${app_root}/builds/${release_id}"
release_dir="${app_root}/releases/${release_id}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

export PATH="${node_home}:${PATH}"
umask 077

for command_name in corepack git node npm openssl systemctl; do
	command -v "${command_name}" >/dev/null || {
		echo "Required command is missing: ${command_name}" >&2
		exit 1
	}
done
corepack enable pnpm

if [[ ! -f "${old_environment_file}" ]]; then
	echo "Pathwarden environment file is missing: ${old_environment_file}" >&2
	exit 1
fi

mkdir -p \
	"${app_root}/builds" \
	"${app_root}/releases" \
	"${app_root}/data" \
	"${postgres_socket_dir}" \
	"${config_dir}" \
	"${unit_dir}" \
	"${runtime_dir}"
chmod 700 "${app_root}/data" "${postgres_socket_dir}" "${config_dir}" "${runtime_dir}"

if [[ ! -f "${runtime_dir}/package.json" ]]; then
	(
		cd "${runtime_dir}"
		npm init -y >/dev/null
	)
fi
if [[ ! -x "${runtime_dir}/node_modules/@embedded-postgres/linux-arm64/native/bin/postgres" || ! -d "${runtime_dir}/node_modules/pg" ]]; then
	(
		cd "${runtime_dir}"
		npm install --save-exact \
			"@embedded-postgres/linux-arm64@${postgres_package_version}" \
			pg@8.16.3
	)
fi

postgres_bin_dir="${runtime_dir}/node_modules/@embedded-postgres/linux-arm64/native/bin"

set -a
# shellcheck disable=SC1090
source "${old_environment_file}"
set +a
: "${DISCORD_TOKEN:?DISCORD_TOKEN is empty in the Pathwarden environment file}"
: "${DISCORD_APPLICATION_ID:?DISCORD_APPLICATION_ID is empty in the Pathwarden environment file}"
: "${DISCORD_GUILD_ID:?DISCORD_GUILD_ID is empty in the Pathwarden environment file}"

database_password=""
if [[ -f "${environment_file}" ]]; then
	database_url="$(sed -n 's/^DATABASE_URL=//p' "${environment_file}" | head -n 1)"
	if [[ "${database_url}" =~ ^postgresql://kobold:([0-9a-f]+)@127\.0\.0\.1:${postgres_port}/kobold$ ]]; then
		database_password="${BASH_REMATCH[1]}"
	fi
fi
if [[ -z "${database_password}" ]]; then
	database_password="$(openssl rand -hex 32)"
fi

if [[ ! -f "${postgres_data_dir}/PG_VERSION" ]]; then
	password_file="$(mktemp)"
	trap 'rm -f "${password_file}"' EXIT
	printf '%s\n' "${database_password}" > "${password_file}"
	"${postgres_bin_dir}/initdb" \
		-D "${postgres_data_dir}" \
		--username=kobold \
		--pwfile="${password_file}" \
		--auth-local=scram-sha-256 \
		--auth-host=scram-sha-256 \
		--encoding=UTF8 \
		--no-locale
	rm -f "${password_file}"
	trap - EXIT
fi

api_secret="$(openssl rand -hex 32)"
nethys_import_run_on_start="true"
if [[ -f "${environment_file}" ]]; then
	existing_api_secret="$(sed -n 's/^API_SECRET=//p' "${environment_file}" | head -n 1)"
	if [[ -n "${existing_api_secret}" ]]; then
		api_secret="${existing_api_secret}"
	fi
	existing_nethys_setting="$(sed -n 's/^JOBS_NETHYS_IMPORT_RUN_ON_START=//p' "${environment_file}" | head -n 1)"
	if [[ "${existing_nethys_setting}" == "false" ]]; then
		nethys_import_run_on_start="false"
	fi
fi

cat > "${environment_file}.next" <<EOF
CLIENT_ID=${DISCORD_APPLICATION_ID}
CLIENT_TOKEN=${DISCORD_TOKEN}
ADMIN_GUILD_IDS=${DISCORD_GUILD_ID}
DEVELOPER_IDS=
CLIENT_INTENTS=Guilds,GuildMessages,GuildMessageReactions,DirectMessages,DirectMessageReactions,GuildEmojisAndStickers
CLIENT_PARTIALS=Message,Channel,Reaction
CLIENT_INVITE_URL=https://discord.com/api/oauth2/authorize?client_id=${DISCORD_APPLICATION_ID}&permissions=532643576896&scope=applications.commands%20bot
DATABASE_URL=postgresql://kobold:${database_password}@127.0.0.1:${postgres_port}/kobold
API_PORT=8080
API_SECRET=${api_secret}
CLUSTERING_ENABLED=false
JOBS_NETHYS_IMPORT_RUN_ON_START=${nethys_import_run_on_start}
JOBS_NETHYS_IMPORT_LOG=true
LOGGING_PRETTY=true
EOF
chmod 600 "${environment_file}.next"
mv "${environment_file}.next" "${environment_file}"

install -m 0644 "${script_dir}/kobold-postgres.service" "${unit_dir}/kobold-postgres.service"
install -m 0644 "${script_dir}/kobold.service" "${unit_dir}/kobold.service"
systemctl --user daemon-reload
systemctl --user enable --now kobold-postgres.service

for _ in {1..30}; do
	if (
		cd "${runtime_dir}"
		PGPASSWORD="${database_password}" PGPORT="${postgres_port}" node --input-type=module <<'NODE'
import pg from 'pg';
const client = new pg.Client({
	host: '127.0.0.1',
	port: Number(process.env.PGPORT),
	user: 'kobold',
	password: process.env.PGPASSWORD,
	database: 'postgres',
});
await client.connect();
await client.end();
NODE
	) >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
(
	cd "${runtime_dir}"
	PGPASSWORD="${database_password}" PGPORT="${postgres_port}" node --input-type=module <<'NODE'
import pg from 'pg';
const connection = {
	host: '127.0.0.1',
	port: Number(process.env.PGPORT),
	user: 'kobold',
	password: process.env.PGPASSWORD,
	database: 'postgres',
};
const client = new pg.Client(connection);
await client.connect();
const result = await client.query("SELECT 1 FROM pg_database WHERE datname = 'kobold'");
if (result.rowCount === 0) {
	await client.query('CREATE DATABASE kobold');
}
await client.end();
NODE
)

git clone --depth 1 --branch "${repo_ref}" "${repo_url}" "${source_dir}"
(
	cd "${source_dir}"
	corepack pnpm install --frozen-lockfile
	corepack pnpm run -r build
	set -a
	# shellcheck disable=SC1090
	source "${environment_file}"
	set +a
	corepack pnpm --filter @kobold/nethys drizzle:migrate
	corepack pnpm deploy --filter=@kobold/client --prod "${release_dir}"
)

next_link="${app_root}/.current-${release_id}"
ln -s "${release_dir}" "${next_link}"
mv -T "${next_link}" "${app_root}/current"

# Preserve a final Pathwarden snapshot when its backup unit is available.
systemctl --user start pathwarden-backup.service 2>/dev/null || true
systemctl --user disable --now pathwarden.service pathwarden-backup.timer

if ! systemctl --user enable --now kobold.service; then
	systemctl --user disable --now kobold.service 2>/dev/null || true
	systemctl --user enable --now pathwarden.service
	exit 1
fi

sleep 10
if ! systemctl --user is-active --quiet kobold.service; then
	journalctl --user -u kobold.service -n 100 --no-pager >&2 || true
	systemctl --user disable --now kobold.service 2>/dev/null || true
	systemctl --user enable --now pathwarden.service
	exit 1
fi

echo "Installed Kobold release ${release_id} from ${repo_url} at ref ${repo_ref}."
echo "Pathwarden is disabled; its files and data were preserved for rollback."
