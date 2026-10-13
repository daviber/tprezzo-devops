#!/usr/bin/env python3
"""One-time compression of two closed host-log archives; keep all log contents."""
import argparse
import fcntl
import gzip
import hashlib
import os
from pathlib import Path
import pwd
import stat
import subprocess
import tempfile

ARCHIVES = (Path('/var/log/btmp.1'), Path('/var/log/auth.log.1'))


def digest(stream):
    return hashlib.file_digest(stream, 'sha256').digest()


def open_descriptors(path):
    found = 0
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            descriptors = list((proc / 'fd').iterdir())
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
        for descriptor in descriptors:
            try:
                if os.readlink(descriptor) == str(path):
                    found += 1
            except (FileNotFoundError, ProcessLookupError, PermissionError):
                continue
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if os.uname().sysname != 'Linux' or os.geteuid() != 0:
        raise SystemExit('Eseguire come root sul VPS Linux demo.')
    lock = Path('/opt/tprezzo-java/.manage.lock')
    if not lock.is_file():
        raise SystemExit('Marker installazione Java demo assente.')
    # Same flock used by deploy and by logrotate 3.21; never write the state file.
    with lock.open('rb') as deploy_lock, Path('/var/lib/logrotate/status').open('r+b') as rotation_lock:
        fcntl.flock(deploy_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(rotation_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        policy = Path('/etc/logrotate.d/btmp')
        content = policy.read_text()
        expected = '# no packages own btmp -- we\'ll rotate it here\n/var/log/btmp {\n    missingok\n    monthly\n    create 0660 root utmp\n    rotate 1\n}\n'
        updated = expected.replace('    monthly\n', '    monthly\n    compress\n')
        if content not in (expected, updated):
            raise SystemExit('Regola btmp diversa da quella verificata: nessuna modifica.')
        if args.apply and content != updated:
            backup_dir = Path('/var/lib/tprezzo-demo-maintenance')
            backup_dir.mkdir(mode=0o700, exist_ok=True)
            backup = backup_dir / 'btmp.logrotate.before'
            if not backup.exists():
                with backup.open('x') as output:
                    os.fchmod(output.fileno(), 0o600)
                    output.write(content)
            descriptor, temporary = tempfile.mkstemp(prefix='.btmp-', dir=policy.parent)
            try:
                with os.fdopen(descriptor, 'w') as output:
                    os.fchmod(output.fileno(), 0o644)
                    output.write(updated)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, policy)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
            print('btmp: compressione futura abilitata; frequenza/retention invariate.')
        recovered = 0
        for path in ARCHIVES:
            zipped = Path(str(path) + '.gz')
            if not path.exists():
                if zipped.is_file():
                    with gzip.open(zipped, 'rb') as compressed:
                        digest(compressed)
                    print(str(zipped) + ': archivio già compresso e integro.')
                else:
                    print(str(path) + ': assente, ignorato.')
                continue
            before = path.lstat()
            allowed_owners = {0} if path.name == 'btmp.1' else {0, pwd.getpwnam('syslog').pw_uid}
            if not stat.S_ISREG(before.st_mode) or before.st_uid not in allowed_owners or before.st_nlink != 1:
                raise SystemExit('Archivio non regolare/proprietario inatteso o hardlink: ' + str(path))
            if zipped.exists() or zipped.is_symlink() or open_descriptors(path):
                raise SystemExit('Archivio aperto o destinazione presente: ' + str(path))
            print(str(path) + ': bytes=' + str(before.st_size) + ', descriptor aperti=0.')
            if not args.apply:
                continue
            with path.open('rb') as original:
                original_digest = digest(original)
            subprocess.run(['/usr/bin/gzip', '--keep', '--', str(path)], check=True)
            with gzip.open(zipped, 'rb') as compressed:
                if digest(compressed) != original_digest:
                    raise SystemExit('Integrità gzip diversa: sorgente conservata.')
            after = path.lstat()
            if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns) or open_descriptors(path):
                raise SystemExit('Archivio cambiato/aperto: sorgente conservata.')
            # Only the redundant raw archive is removed after SHA256 verification.
            path.unlink()
            saved = before.st_size - zipped.stat().st_size
            recovered += saved
            print(str(zipped) + ': SHA256 contenuto verificato; recuperati bytes=' + str(saved))
        print('Spazio recuperato bytes=' + str(recovered) + '; nessun log attivo modificato.')


if __name__ == '__main__':
    os.umask(0o077)
    main()
