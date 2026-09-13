#!/usr/bin/env bash
# Installs imapsync (from upstream; it is no longer packaged in Debian) and its Perl deps,
# plus jq/curl/cron, on Debian 12/13 or Ubuntu. Run as root.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq jq curl cron logrotate ca-certificates perl make cpanminus \
  libauthen-ntlm-perl libcgi-pm-perl libcrypt-openssl-rsa-perl libdata-uniqid-perl \
  libencode-imaputf7-perl libfile-copy-recursive-perl libfile-tail-perl libio-socket-inet6-perl \
  libio-socket-ssl-perl libio-tee-perl libhtml-parser-perl libjson-webtoken-perl \
  libmail-imapclient-perl libparse-recdescent-perl libproc-processtable-perl libmodule-scandeps-perl \
  libreadonly-perl libregexp-common-perl libsys-meminfo-perl libterm-readkey-perl \
  libtest-mockobject-perl libtest-pod-perl libunicode-string-perl liburi-perl libwww-perl \
  libtest-nowarnings-perl libtest-deep-perl libtest-warn-perl libnet-ssleay-perl libdigest-hmac-perl
curl -fsSL -o /usr/local/bin/imapsync https://imapsync.lamiral.info/imapsync
chmod 755 /usr/local/bin/imapsync
if imapsync --modules_version | grep -q "Not installed"; then
  imapsync --modules_version | grep "Not installed"
  echo "some Perl modules are missing, see above" >&2; exit 1
fi
install -d -m 700 /etc/gmail2m365 /var/lib/gmail2m365
echo "imapsync $(imapsync --version) installed; now copy gmail2m365.sh to /usr/local/bin and create /etc/gmail2m365/*.conf"
