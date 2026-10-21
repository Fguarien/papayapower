#!/bin/bash
# One-time setup: a self-signed « PapayaPower Local Signing » code-signing
# certificate in its own keychain, picked up by make-app.sh.
#
# Why: signed ad hoc, the app's designated requirement is its cdhash, which
# changes on every build — so the Keychain asks again for every stored token
# after each install, and firewalls such as Little Snitch
# see a new program and block it again. Signed with this certificate, the requirement is
# « identifier + certificate leaf », stable across builds: one « Always Allow »,
# once.
#
# Trade-off: the keychain has an EMPTY password, which is what lets a build
# over SSH unlock it. Any process running as you can therefore sign code with
# this certificate, and PapayaPower's Keychain items would trust that code. If you
# only ever build from a local Terminal, an Apple Development identity
# (PAPAYA_SIGN_ID=…) is the stricter choice.
#
# Undo:  security delete-keychain ~/Library/Keychains/papayapower-signing.keychain-db
set -euo pipefail

KC="${HOME}/Library/Keychains/papayapower-signing.keychain-db"
if [ -f "${KC}" ] && security find-identity -p codesigning "${KC}" 2>/dev/null | grep -q "PapayaPower Local Signing"; then
  echo "✓ already set up: ${KC}"
  exit 0
fi

D="$(mktemp -d)"; trap 'rm -rf "${D}"' EXIT
cd "${D}"
cat > c.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=PapayaPower Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -config c.cnf 2>/dev/null
# Transient password for the PKCS#12 hand-over only; it never leaves $D.
/usr/bin/openssl rand -hex 16 > p.txt
/usr/bin/openssl pkcs12 -export -inkey k.pem -in c.pem -out s.p12 -passout file:p.txt 2>/dev/null \
  || /usr/bin/openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out s.p12 -passout file:p.txt

[ -f "${KC}" ] || security create-keychain -p "" "${KC}"
security set-keychain-settings "${KC}"                 # no auto-lock
security unlock-keychain -p "" "${KC}"
security import s.p12 -k "${KC}" -f pkcs12 -P "$(cat p.txt)" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "${KC}" >/dev/null

# codesign only finds identities in keychains on the search list.
EXISTING=()
while IFS= read -r line; do
  k="$(echo "${line}" | sed -e 's/^ *"//' -e 's/"$//')"
  [ -n "${k}" ] && [ "${k}" != "${KC}" ] && EXISTING+=("${k}")
done < <(security list-keychains -d user)
security list-keychains -d user -s ${EXISTING[@]+"${EXISTING[@]}"} "${KC}"

security find-identity -p codesigning "${KC}"
echo "✓ ready — ./make-app.sh will now sign with « PapayaPower Local Signing »"
