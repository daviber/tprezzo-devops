#!/usr/bin/env python3
"""Update front/API/worker in the existing Java installation, preserving rollback."""
import argparse
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time

import config

HERE = Path(__file__).resolve().parent
FILES = ('runtime.env', 'backend.env', 'frontend.env', 'stripe.env', 'images.manifest', 'frontend.sha256')
ACTIVE_DEFAULT = '/opt/tprezzo-java/releases/java-demo-20261011-01'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, **kwargs):
    result = subprocess.run(argv, capture_output=True, **kwargs)
    require(result.returncode == 0, 'Comando fallito: ' + Path(argv[0]).name + '; output riservato omesso.')
    return result.stdout


def clean_env():
    return {k: os.environ[k] for k in ('PATH', 'HOME') if k in os.environ}


def docker(*args):
    return run(['docker', '--host', 'unix:///var/run/docker.sock', *args], env=clean_env(), text=True)


def fingerprint(directory):
    digest = hashlib.sha256()
    for name in FILES:
        digest.update(name.encode() + b'\0' + (directory / name).read_bytes() + b'\0')
    return digest.hexdigest()


def validate(directory, built=True, images=False):
    config.load(directory)
    run(['python3', str(HERE / 'config.py'), 'check-built' if built else 'check', str(directory)])
    if images:
        for line in (directory / 'images.manifest').read_text().splitlines():
            image, expected = line.split()
            actual = docker('image', 'inspect', '--platform', 'linux/amd64', '--format', '{{.Id}}', image).strip()
            require(actual == expected, 'Digest immagine diverso dal manifest: ' + image)


def ssh_args():
    host = os.environ.get('DEPLOY_HOST', '188.245.184.80')
    user = os.environ.get('DEPLOY_USER', 'root')
    port = os.environ.get('DEPLOY_PORT', '22')
    require(re.fullmatch(r'[a-zA-Z0-9.-]+', host) and re.fullmatch(r'[a-zA-Z0-9._-]+', user)
            and port.isdigit(), 'Destinazione SSH non valida.')
    args = ['ssh', '-p', port, '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
            '-o', 'ConnectTimeout=15', '-o', 'ServerAliveInterval=30']
    identity = os.environ.get('SSH_IDENTITY_FILE')
    if identity:
        args += ['-i', identity]
    return args, user + '@' + host


def remote(command, **kwargs):
    args, host = ssh_args()
    return run([*args, host, command], **kwargs)


def path_check(active):
    require(re.fullmatch(r'/opt/tprezzo-java/releases/[a-z0-9][a-z0-9._-]{0,63}', str(active)),
            'Percorso installazione Java non valido.')


def prepare(release, active, directory):
    require(not directory.exists(), 'Configurazione già presente; scegliere un nuovo ID release.')
    # One locked snapshot: stdout contains only tar, never displayed or logged.
    script = f'''set -euo pipefail
cd {shlex.quote(str(active))}
exec 9>/opt/tprezzo-java/.manage.lock
flock -n 9
test -f .state/public
tar -cf - {' '.join(FILES)}
'''
    data = remote('bash -s', input=script.encode())
    require(len(data) < 1024 * 1024, 'Snapshot configurazione troppo grande.')
    directory.mkdir(parents=True, mode=0o700)
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:') as archive:
        members = archive.getmembers()
        require({m.name for m in members} == set(FILES) and len(members) == len(FILES)
                and all(m.isfile() for m in members), 'Snapshot remoto non valido.')
        for member in members:
            target = directory / member.name
            target.write_bytes(archive.extractfile(member).read())
            target.chmod(0o600)
    validate(directory)
    runtime = config.read_env(directory / 'runtime.env')
    require(runtime['ASYNC_ENABLED'] == 'true', 'Richiesta demo Java pubblicata con async attivo.')
    metadata = {'release': release, 'active': str(active), 'base_sha256': fingerprint(directory)}
    for service in ('api', 'worker', 'frontend'):
        runtime[service.upper() + '_IMAGE'] = f'tprezzo-java-{service}:{release}'
    config.write_env(directory / 'runtime.env', runtime)
    (directory / 'update.json').write_text(json.dumps(metadata) + '\n')
    (directory / 'update.json').chmod(0o600)
    validate(directory, built=False)
    print('Configurazione copiata dalla demo, chiave Next e provider preservati. Ora build-release.sh ' + release)


def publish(release, directory):
    validate(directory)
    metadata = json.loads((directory / 'update.json').read_text())
    active = Path(metadata['active'])
    path_check(active)
    require(metadata['release'] == release, 'ID aggiornamento diverso dalla configurazione.')
    archive = HERE.parents[1] / '.local' / f'images-{release}.tar.gz'
    require(archive.is_file(), 'Archivio mancante: eseguire prima build-release.sh.')
    package = '/opt/tprezzo-java/updates/' + release
    script = f'''set -euo pipefail
test ! -e {shlex.quote(package)}
test "$(df -Pm /opt | awk 'NR==2 {{print $4}}')" -ge 6144
umask 077
mkdir -p {shlex.quote(package)}
'''
    remote('bash -s', input=script.encode())
    args, host = ssh_args()
    sources = [str(directory / name) for name in (*FILES, 'update.json')]
    sources += [str(HERE / 'update_release.py'), str(HERE / 'config.py')]
    run(['rsync', '-az', '--no-owner', '--no-group', '-e', shlex.join(args), *sources, host + ':' + package + '/'])
    with archive.open('rb') as stream:
        remote('docker --host unix:///var/run/docker.sock load --platform linux/amd64', stdin=stream)
    print('Immagini caricate. Pubblicazione con fermo demo e drain worker.', flush=True)
    # Stream only safe progress metadata, never env or Stripe logs.
    command = shlex.join(['python3', package + '/update_release.py', '_apply', release])
    result = subprocess.run([*args, host, command])
    require(result.returncode == 0, 'Aggiornamento interrotto: stato conservato; consultare .state/update-phase e runbook.')


def apply(release, rollback=False):
    require(os.uname().sysname == 'Linux' and os.geteuid() == 0, 'Eseguire sul VPS Linux come root.')
    require(HERE == Path('/opt/tprezzo-java/updates') / release, 'Package aggiornamento non valido.')
    metadata = json.loads((HERE / 'update.json').read_text())
    require(metadata['release'] == release, 'ID package non coerente.')
    active = Path(metadata['active'])
    path_check(active)
    backup = active / '.state' / 'updates' / release
    with Path('/opt/tprezzo-java/.manage.lock').open('rb') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        require((active / '.state/public').is_file(), 'Demo Java non pubblicata; usare prima migrazione.')
        validate(active, built=not rollback, images=not rollback)
        target = backup / 'before' if rollback else HERE
        validate(target, images=True)
        old = config.read_env(active / 'runtime.env')
        new = config.read_env(target / 'runtime.env')
        ids = docker('ps', '-aq', '--filter', 'label=com.docker.compose.project=' + old['COMPOSE_PROJECT_NAME']).split()
        require(ids, 'Container del progetto Java assenti sul daemon locale.')
        owners = docker('inspect', '--format', '{{index .Config.Labels "com.docker.compose.project.working_dir"}}', *ids).splitlines()
        require(len(owners) == len(ids) and all(Path(owner).resolve() == active.resolve() for owner in owners),
                'Progetto Java posseduto da altra directory: nessun servizio modificato.')
        require(old['ASYNC_ENABLED'] == new['ASYNC_ENABLED'] == 'true', 'Async deve restare attivo.')
        for key in ('COMPOSE_PROJECT_NAME', 'INSTANCE_ID', 'APP_DOMAIN', 'CERTBOT_CONF_DIR', 'CERTBOT_WWW_DIR',
                    'NGINX_IMAGE', 'STRIPE_IMAGE', 'CERTBOT_IMAGE', 'STRIPE_RELAY_ENABLED'):
            require(old[key] == new[key], 'Aggiornamento front/back non può cambiare: ' + key)
        old_backend = config.read_env(active / 'backend.env')
        new_backend = config.read_env(target / 'backend.env')
        for key in ('TPREZZO_SUPABASE_URL', 'PRICE_CENTRIC_S3_BUCKET', 'PRICE_CENTRIC_S3_PREFIX', 'AWS_TEXTRACT_BUCKET'):
            require(old_backend.get(key) == new_backend.get(key), 'Namespace dati diverso: ' + key)
        if rollback:
            # Also recover a failed update before/during config replacement.
            # Refuse unrelated edits or a newer deployment.
            require(all((active / name).read_bytes() in ((HERE / name).read_bytes(), (target / name).read_bytes())
                        for name in FILES), 'Configurazione diversa dallo snapshot: verificare rollback manuale.')
        else:
            require(fingerprint(active) == metadata['base_sha256'],
                    'Configurazione demo cambiata: preparare una nuova release.')
        require(shutil.disk_usage(active).free >= 2 * 1024**3, 'Meno di 2 GiB liberi.')
        require(not docker('ps', '-q', '--filter', 'label=com.docker.compose.project=tprezzo-demo',
                           '--filter', 'label=com.docker.compose.service=worker').strip(), 'Worker Node ancora attivo.')
        domain = new['APP_DOMAIN']
        run(['openssl', 'x509', '-in', str(Path(new['CERTBOT_CONF_DIR']) / 'live' / domain / 'fullchain.pem'),
             '-noout', '-checkend', '604800'])
        base_command = ['docker', '--host', 'unix:///var/run/docker.sock', 'compose', '--project-directory', str(active),
                        '--env-file', str(active / 'runtime.env'), '-f', str(active / 'compose.yml'),
                        '-f', str(active / 'compose.public.yml'), '--profile', 'async', '--profile', 'stripe']

        def compose(*args):
            run([*base_command, *args], env=clean_env())

        compose('config', '--quiet')
        if not rollback:
            require(not backup.exists(), 'Snapshot aggiornamento già presente; non sovrascrivere.')
            (backup / 'before').mkdir(parents=True, mode=0o700)
            for name in FILES:
                shutil.copy2(active / name, backup / 'before' / name)
            previous = active / '.state/deployed-version'
            (backup / 'previous-version').write_text(previous.read_text() if previous.exists() else active.name + '\n')
        phase = active / '.state/update-phase'
        phase.write_text(('rollback ' if rollback else 'update ') + release + ': drain\n')
        print('Chiudo ingressi/produttori Java; worker drena la coda.', flush=True)
        compose('stop', 'nginx', 'stripe-cli', 'frontend', 'api')
        deadline = time.monotonic() + 900
        while True:
            count = run(['python3', str(active / 'config.py'), 'queue', str(active)], text=True).strip()
            require(count.isdigit(), 'Coda non verificabile; ingressi conservati chiusi.')
            if int(count) == 0:
                break
            require(time.monotonic() < deadline, 'Drain oltre 15 minuti; ingressi conservati chiusi.')
            print('Attendo drain: ' + count + ' job.', flush=True)
            time.sleep(5)
        compose('stop', '-t', '330', 'worker')
        phase.write_text(release + ': install\n')
        for name in FILES:
            temporary = active / ('.update-' + name)
            shutil.copyfile(target / name, temporary)
            temporary.chmod(0o600)
            os.replace(temporary, active / name)
        print('Avvio API, frontend e worker aggiornati.', flush=True)
        compose('up', '-d', '--no-build', '--pull', 'never', '--force-recreate', '--wait', '--wait-timeout', '180',
                'api', 'frontend', 'worker')
        if new['STRIPE_RELAY_ENABLED'] == 'true':
            compose('up', '-d', '--no-build', '--pull', 'never', '--force-recreate', 'stripe-cli')
        phase.write_text(release + ': publish\n')
        compose('up', '-d', '--no-build', '--pull', 'never', '--force-recreate', '--no-deps', '--wait',
                '--wait-timeout', '90', 'nginx')
        version = (backup / 'previous-version').read_text().strip() if rollback else release
        (active / '.state/deployed-version').write_text(version + '\n')
        phase.write_text('complete ' + version + '\n')
        print('Pubblicato https://' + domain + '; versione ' + version + '. Legacy Node e immagini precedenti conservati.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'publish', 'rollback', '_apply', '_rollback'))
    parser.add_argument('release')
    parser.add_argument('--data-compatible', action='store_true')
    args = parser.parse_args()
    require(re.fullmatch(r'[a-z0-9][a-z0-9._-]{0,63}', args.release), 'ID release non valido.')
    if args.action in ('_rollback', 'rollback'):
        require(args.data_compatible, 'Rollback richiede --data-compatible dopo verifica dati.')
    if args.action.startswith('_'):
        return apply(args.release, args.action == '_rollback')
    directory = HERE.parents[1] / '.local' / 'releases' / args.release
    if args.action == 'prepare':
        active = Path(os.environ.get('JAVA_ACTIVE_DIR', ACTIVE_DEFAULT))
        path_check(active)
        return prepare(args.release, active, directory)
    if args.action == 'publish':
        return publish(args.release, directory)
    package = '/opt/tprezzo-java/updates/' + args.release
    command = shlex.join(['python3', package + '/update_release.py', '_rollback', args.release, '--data-compatible'])
    ssh, host = ssh_args()
    result = subprocess.run([*ssh, host, command])
    require(result.returncode == 0, 'Rollback interrotto; stato conservato sul VPS.')


if __name__ == '__main__':
    os.umask(0o077)
    try:
        main()
    except (RuntimeError, config.ConfigError, OSError, ValueError, tarfile.TarError) as error:
        message = str(error) if isinstance(error, (RuntimeError, config.ConfigError)) else 'File/operazione non validi; dettagli riservati omessi.'
        print('[java-update] ' + message, file=sys.stderr)
        sys.exit(1)
