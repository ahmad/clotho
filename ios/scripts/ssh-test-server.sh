#!/bin/sh
# Starts a throwaway sshd on 127.0.0.1:2222 for ClothoTests/SSHIntegrationTests. It runs as you, uses
# only files in /tmp/clotho-ios-sshtest, and changes nothing on the system. `stop` ends it.
set -e
D=/tmp/clotho-ios-sshtest
if [ "${1:-}" = stop ]; then kill "$(cat $D/sshd.pid)" 2>/dev/null || true; exit 0; fi
mkdir -p $D && cd $D
[ -f host_ed25519 ] || ssh-keygen -q -t ed25519 -N '' -f host_ed25519 -C clotho-ios-test-host
[ -f client ] || ssh-keygen -q -t ed25519 -N '' -f client -C clotho-ios-dev-test
cp client.pub authorized_keys && chmod 600 authorized_keys
printf 'Port 2222\nListenAddress 127.0.0.1\nHostKey %s/host_ed25519\nAuthorizedKeysFile %s/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nPidFile %s/sshd.pid\n' $D $D $D > sshd_config
[ -f sshd.pid ] && kill -0 "$(cat sshd.pid)" 2>/dev/null || /usr/sbin/sshd -f $D/sshd_config -E $D/sshd.log
whoami | tr -d '\n' > user
# The raw Ed25519 seed of the client key, which the test loads into the simulator's Keychain.
python3 - <<'PY'
import base64, struct
lines = open('/tmp/clotho-ios-sshtest/client').read().split('\n')
b = base64.b64decode(''.join(l for l in lines if l and not l.startswith('---')))
def rd(b, o):
    n = struct.unpack('>I', b[o:o + 4])[0]; return b[o + 4:o + 4 + n], o + 4 + n
o = len(b'openssh-key-v1\0')
_, o = rd(b, o); _, o = rd(b, o); _, o = rd(b, o); o += 4; _, o = rd(b, o); priv, o = rd(b, o)
p = 8; _, p = rd(priv, p); _, p = rd(priv, p); sk, p = rd(priv, p)
open('/tmp/clotho-ios-sshtest/seed.hex', 'w').write(sk[:32].hex())
PY
echo "sshd on 127.0.0.1:2222 ($D)"
