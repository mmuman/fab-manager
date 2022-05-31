#!/bin/bash -xe

src="$(realpath "$(dirname "$0")/..")"
dest=/usr/src/app

fail () {
	echo "$@"
	exit 1
}

# Debian has something else named yarn!?
#yarn () {
#	yarnpkg "$@"
#}

# lsb_release not installed by default
distro="$(sed -n '/^ID/s/ID=//p' /etc/*-release)"

welcome_message()
{
	clear
	echo "This script will installing Fab-Manager outside of Docker."
	echo "TODO: TLS."
	echo "Distribution: $distro Container: $container"
	echo "This script will stop when something fails."
	read -rp "Continue? (Y/n) " confirm </dev/tty
	if [[ "$confirm" = "n" ]]; then exit 1; fi
}

read_email()
{
  local email
  read -rp "Please input a valid email address > " email </dev/tty
  if [[ "$email" == *"@"*"."* ]]; then
    EMAIL="$email"
  else
    read_email
  fi
}

config()
{
	read -rp "Primary domain?" MAIN_DOMAIN </dev/tty
	read -rp "Other domains (space separated)?" OTHER_DOMAINS </dev/tty
}

welcome_message
config



# Make sure we do not run anything there
systemctl stop supervisor || true

echo "Installing dependencies…"
case "$distro" in
	debian)
		# Other services from docker-compose.yml
		apt update
		apt satisfy -y "apt-transport-https, curl, gpg"
		rm -f /usr/share/keyrings/elasticsearch-keyring.gpg
		curl https://artifacts.elastic.co/GPG-KEY-elasticsearch | \
			gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg
		echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main" | \
			tee /etc/apt/sources.list.d/elastic-8.x.list
		apt update
		apt satisfy -y "postgresql (>=13), elasticsearch, redis, nginx"
		# Install runtime dependencies
		# We keep the same order as Dockerfile
		apt satisfy -y "redis (>= 5:6.0.0), ruby (>= 1:2.6)"
		apt satisfy -y "bash,
		curl,
		nodejs,
		yarnpkg,
		git,
		openssh-server,
		imagemagick,
		supervisor,
		tzdata,
		libc-dev-bin,
		ruby-dev (>= 1:2.6),
		zlib1g-dev,
		lzma-dev, xz-utils,
		postgresql-server-dev-all, libecpg-dev,
		postgresql-client,
		libxml2-dev,
		libxslt1-dev,
		libsass-dev,
		libsass1,
		rsync"
		# Force yarnpkg as yarn
		ln -sf /usr/bin/yarnpkg /usr/bin/yarn
		# Install buildtime dependencies
		apt satisfy -y "build-essential,
		linux-headers-amd64, patch, rsync"
		#TODO: dpkg-reconfigure tzdata ???
		;;
	*)
		fail "Distro '$distro' unsupported. Please send patch."
		;;
esac

gem install bundler
# Throw error if Gemfile has been modified since Gemfile.lock
bundle config --global frozen 1


cd /tmp
cp "$src/"Gemfile /tmp/
cp "$src/"Gemfile.lock /tmp/
bundle config set --local without 'development test doc'
bundle install #--binstubs --without development test doc
bundle binstubs --all
cd -

mkdir -p /usr/src/app
cd /usr/src/app
cp "$src/"package.json /usr/src/app/package.json
cp "$src/"yarn.lock /usr/src/app/yarn.lock
yarn install

#XXX: debugging
if false; then
# Clean up build deps, cached packages and temp files
case "$distro" in
	debian)
		apt purge -y build-essential linux-headers-amd64 patch gpg
		apt autoremove -y
		apt clean
		;;
	*)
		fail "Distro '$distro' unsupported. Please send patch."
		;;
esac
yarn cache clean
# Some things we should not delete
#rm -rf /tmp/* \
#	/var/tmp/* \
rm -rf /tmp/yarn-* \
	/usr/lib/ruby/gems/*/cache/*
fi

# Web app
mkdir -p /usr/src/app && \
    mkdir -p /usr/src/app/config && \
    mkdir -p /usr/src/app/invoices && \
    mkdir -p /usr/src/app/payment_schedules && \
    mkdir -p /usr/src/app/exports && \
    mkdir -p /usr/src/app/imports && \
    mkdir -p /usr/src/app/log && \
    mkdir -p /usr/src/app/public/uploads && \
    mkdir -p /usr/src/app/public/packs && \
    mkdir -p /usr/src/app/accounting && \
    mkdir -p /usr/src/app/proof_of_identity_files && \
    mkdir -p /usr/src/app/tmp/sockets && \
    mkdir -p /usr/src/app/tmp/pids


cp "$src/"docker/database.yml /usr/src/app/config/database.yml
# --delete will not delete excluded stuff
rsync -avz --exclude-from="$src/.dockerignore" \
	--exclude=.dockerignore \
	--exclude=payment_schedules \
	--exclude=config/env \
	--delete \
	"$src/". "$dest"
# Work around app/doc ignored
rsync -avz \
	--delete \
	"$src/"/app/doc "$dest"/app
cp "$src/"docker/supervisor.conf /etc/supervisor/conf.d/fablab.conf
# Unlike with Docker, supervisord won't inherit the WORKDIR, so force it.
sed -i "/^directory.*/d;/^command.*$/adirectory=/usr/src/app\nenvironment=RAILS_ENV=\"production\",RACK_ENV=\"production\"" /etc/supervisor/conf.d/fablab.conf
# env file cannot be read in the config file so we must pass it via systemd
test -e /lib/systemd/system/supervisor.service || fail "No supervisor.service file found."
sed -i "/^EnvironmentFile=.*\/config\/env/d;/^\[Service\].*$/aEnvironmentFile=$dest\/config\/env" /lib/systemd/system/supervisor.service
systemctl daemon-reload
# postgresql needs some config as well
# TODO: make this idempotent & cluster independant
# Must appear first.
sed -i '/^# ---.*$/ahost all all all trust' /etc/postgresql/13/main/pg_hba.conf
systemctl restart 'postgresql@*'
# TODO: limit elasticsearch RAM: ES_JAVA_OPTS=-Xms512m -Xmx512m
# Environment=ES_JAVA_OPTS="-Xms512m -Xmx512m" in .service ?
# TODO: install setup/log4j2.properties
systemctl daemon-reload
systemctl enable --now elasticsearch
# TODO: depend nginx service on supervisord
# TODO: /etc/hosts to map postgres & co to 127.0.0.1

export RAILS_ENV=production
export RACK_ENV=production


configure_env_file()
{
	if [ -e "$dest/config/env" ]; then
		echo "=== Detected existing env file, not touching. ==="
		return
	fi
	cp "$src/setup/env.example" "$dest/config/env"
	echo "Default env file installed. You need to edit it now."
	read -rp "Press Enter to edit $dest/config/env with ${EDITOR:-vi}." v </dev/tty
	"${EDITOR:-vi}" "$dest/config/env"
}

configure_env_file

ensure_generated_secret_key_base()
{
	if grep 'SECRET_KEY_BASE=.\+' "$dest/config/env"; then
		echo "=== SECRET_KEY_BASE already set. ==="
		return
	fi
	# we automatically generate the SECRET_KEY_BASE
	secret=$(cd "$dest" && bundle exec rake secret)
	sed -i.bak "s/SECRET_KEY_BASE=/SECRET_KEY_BASE=$secret/g" "$dest/config/env"
	echo "=== SECRET_KEY_BASE set to '$secret'. ==="
}

ensure_generated_secret_key_base

read_password()
{
  local password confirmation
  >&2 echo "Please input a password for this administrator's account"
  read -rsp " > " password </dev/tty
  if [ ${#password} -lt 8 ]; then
    >&2 printf "\nError: password is too short (minimal length: 8 characters)\n"
    password=$(read_password 'no-confirm')
  fi
  if [ "$1" != 'no-confirm' ]; then
    >&2 printf "\nConfirm the password\n"
    read -rsp " > " confirmation </dev/tty
    if [ "$password" != "$confirmation" ]; then
      >&2 printf "\nError: passwords mismatch\n"
      password=$(read_password)
    fi
  fi
  echo "$password"
}


setup_assets_and_databases()
{
  printf "\n\nWe will now setup the database.\n"
  read -rp "Continue? (Y/n) " confirm </dev/tty
  if [ "$confirm" = "n" ]; then return; fi

(
  set -a
  . "$dest"/config/env
  set +a
  cd "$dest" && bundle exec rake db:create # create the database
  cd "$dest" && bundle exec rake db:migrate # run all the migrations
)
  # prompt default admin email/password
  printf "\n\nWe will now create the default administrator of Fab-manager.\n"
  read_email
  PASSWORD=$(read_password)
  printf "\nOK. We will fill the database now...\n"
  (
    export ADMIN_EMAIL="$EMAIL"
    export ADMIN_PASSWORD="$PASSWORD"
    set -a
    . "$dest"/config/env
    set +a
    cd "$dest" && bundle exec rake db:seed # seed the database
  )

(
  set -a
  . "$dest"/config/env
  set +a
  cd "$dest"
  # now build the assets
  if ! bundle exec rake assets:precompile; then
    echo -e "\e[91m[ ❌ ] someting went wrong while compiling the assets, exiting...\e[39m" && exit 1
  fi
  # and prepare elasticsearch
  cd "$dest" && bundle exec rake fablab:es:build_stats
)
}
setup_assets_and_databases

systemctl restart supervisor
#TODO: .service file:
#CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/fablab.conf"]


exit 0
