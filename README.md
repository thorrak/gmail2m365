# gmail2m365

Pull new mail from one or more Gmail / Google Workspace inboxes into a Microsoft 365 (Exchange Online) mailbox, POP-style, on a cron schedule. A small Bash wrapper around [imapsync](https://imapsync.lamiral.info/).

Useful when you have moved your mail to Microsoft 365 but still receive mail at Gmail addresses, or during a Google Workspace → Microsoft 365 migration where you cannot (or do not want to) change MX records yet.

## What it does

Every run, for each configured mailbox:

1. Mints a short-lived OAuth2 access token for Microsoft 365 using an Entra ID app registration (client-credentials flow, so no interactive login and no stored user password).
2. Runs `imapsync` from the Gmail `INBOX` to the Microsoft 365 `INBOX`, preserving flags and internal dates and deduplicating by `Message-Id`.
3. Either deletes each copied message from Gmail immediately (default), or leaves it in the Gmail inbox for a configurable number of days.
4. Optionally pings a heartbeat URL (Uptime Kuma push monitor or similar) on success.

One script serves any number of destination mailboxes. Each mailbox has its own config file, lock, state, and log, so they run independently and can be scheduled concurrently.

## Requirements

- Linux with Bash 4+, `curl`, `jq`, `flock`, `cron`.
- [imapsync](https://imapsync.lamiral.info/) 2.x. It is no longer packaged in Debian, so `install-deps-debian.sh` installs the Perl dependencies from apt and downloads imapsync from upstream.
- A Microsoft 365 tenant where you can create an app registration and run Exchange Online PowerShell.
- Gmail accounts with IMAP enabled and 2-Step Verification on (needed to create app passwords).

## Install

```bash
# as root, on Debian 12/13 or Ubuntu
git clone https://github.com/thorrak/gmail2m365.git
cd gmail2m365
./install-deps-debian.sh
install -m 755 gmail2m365.sh /usr/local/bin/gmail2m365.sh
install -m 644 examples/logrotate.d-gmail2m365 /etc/logrotate.d/gmail2m365
```

## Microsoft 365 setup (once per tenant)

You need an app registration that is allowed to open mailboxes over IMAP without a user signing in.

1. **Entra ID → App registrations → New registration.** Single tenant. Note the **Directory (tenant) ID** and **Application (client) ID**.
2. **Certificates & secrets → New client secret.** Copy the value now; you cannot see it again. Note the expiry date and put a reminder in your calendar a month before it. When the secret expires every run fails with `token request failed`.
3. **API permissions → Add a permission → APIs my organization uses → Office 365 Exchange Online → Application permissions → `IMAP.AccessAsApp`.** Then **Grant admin consent**.
4. Register the app in Exchange Online and grant it access to each destination mailbox. In Exchange Online PowerShell:

   ```powershell
   Connect-ExchangeOnline
   # ObjectId is the *Enterprise application* object ID (Entra ID → Enterprise applications → your app),
   # not the app registration's object ID.
   New-ServicePrincipal -AppId <client-id> -ObjectId <enterprise-app-object-id> -DisplayName "gmail2m365"
   Add-MailboxPermission -Identity alice@example.com -User <enterprise-app-object-id> -AccessRights FullAccess
   ```

5. Make sure IMAP is enabled on each destination mailbox: `Get-CASMailbox alice@example.com | fl ImapEnabled`.

Then on the server:

```bash
umask 077
cp examples/m365.conf /etc/gmail2m365/m365.conf     # fill in TENANT_ID and CLIENT_ID
printf '%s\n' '<client secret value>' > /etc/gmail2m365/m365.secret
```

Verify the token works and carries the right role:

```bash
. /etc/gmail2m365/m365.conf
curl -sS -X POST "https://login.microsoftonline.com/$TENANT_ID/oauth2/v2.0/token" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$(</etc/gmail2m365/m365.secret)" \
  --data-urlencode "scope=https://outlook.office365.com/.default" \
  --data-urlencode "grant_type=client_credentials" \
| jq -r '.access_token | split(".")[1] | @base64d | fromjson | .roles'
# expect: ["IMAP.AccessAsApp"]
```

## Gmail setup (once per source account)

1. Turn on **2-Step Verification** for the Google account.
2. Create an **App password** (Google Account → Security → App passwords). Google shows it as four groups of four letters; the spaces are cosmetic.
3. In Gmail → Settings → **Forwarding and POP/IMAP**, make sure IMAP is enabled.
4. Decide what "delete" should mean. By default, deleting a message from `INBOX` over IMAP only removes the Inbox label; the message stays in *All Mail* forever. If you want it actually gone, three settings have to line up:
   - **Forwarding and POP/IMAP → Auto-Expunge: off.** The script sends explicit `EXPUNGE` commands. (With Auto-Expunge on, Gmail always archives and the next option is greyed out.)
   - **Forwarding and POP/IMAP → "When a message is marked as deleted and expunged from the last visible IMAP folder": Move the message to the Trash** (purged after 30 days) or **Immediately delete forever**.
   - **Labels → All Mail → Show in IMAP: unticked.** This is the one people miss. The setting above only fires when `INBOX` is the *last visible* folder, and All Mail is visible by default, so without this the message just gets archived. Hiding Spam from IMAP too is harmless.

```bash
umask 077
printf '%s\n' 'abcdefghijklmnop' > /etc/gmail2m365/gmail-alice.pw    # app password, no spaces
```

## Configure a mailbox

One file per destination mailbox, named `/etc/gmail2m365/<name>.conf`. See `examples/alice.conf`.

```bash
M365_USER="alice@example.com"
GMAIL_ACCOUNTS=( "alice@gmail.com:/etc/gmail2m365/gmail-alice.pw" )
RETAIN_DAYS=0
KUMA_PUSH_URL=""
```

| Variable | Meaning |
|----------|---------|
| `M365_USER` | Destination Microsoft 365 mailbox. |
| `GMAIL_ACCOUNTS` | Array of `address:/path/to/app-password-file`. Several Gmail inboxes can feed one destination. |
| `RETAIN_DAYS` | `0` (default): delete each message from Gmail right after copying. `N`: keep it in the Gmail inbox for N days, then expunge. See [Retention modes](#retention-modes). |
| `KUMA_PUSH_URL` | Optional. Fetched with a GET after every fully successful run. Leave empty to disable. |
| `EXTRA_ARGS` | Optional array of extra imapsync flags. `( --justlogin )` tests both logins; `( --dry )` reports without changing anything. |

### Test it

```bash
cp /etc/gmail2m365/alice.conf /tmp/t.conf
echo 'EXTRA_ARGS=( --justlogin )' >> /tmp/t.conf && gmail2m365.sh /tmp/t.conf   # both logins succeed?
sed -i 's/--justlogin/--dry/' /tmp/t.conf   && gmail2m365.sh /tmp/t.conf   # what would move?
rm /tmp/t.conf
gmail2m365.sh /etc/gmail2m365/alice.conf                                   # first real run
```

Test runs never advance the retention high-water mark, so they are safe against a live config.

### Schedule it

Add one line per mailbox to `/etc/cron.d/gmail2m365` (see `examples/cron.d-gmail2m365`):

```
* * * * * root /usr/local/bin/gmail2m365.sh /etc/gmail2m365/alice.conf >> /var/log/gmail2m365-alice.log 2>&1
```

Every minute is fine. A run takes roughly 10 seconds when there is nothing to do, and a per-mailbox `flock` makes an overlapping run exit immediately, so a slow run just delays the next one.

## Retention modes

**`RETAIN_DAYS=0` (POP-style).** imapsync copies each message and then deletes and expunges it from the Gmail inbox (`--delete1 --expunge1`). Whether that means "archive," "trash," or "gone" depends on the Gmail setting described above.

**`RETAIN_DAYS=N`.** Messages stay visible in the Gmail inbox for N days. The obvious problem with that is: if you then delete a message in Outlook, the next run sees it in Gmail, not in Microsoft 365, and copies it again. imapsync's `--usecache` does not solve this; it drops its cache entry as soon as the message disappears from the destination and re-copies it.

Instead the script records Gmail's `UIDVALIDITY` and the highest UID it has handled, per source account, in `/var/lib/gmail2m365/<name>/lastuid.<address>`, and passes `--search1 "NOT UID 1:<last>"` so each run only considers newer messages. Gmail UIDs only ever increase, so a message that was already handled can never look new again no matter what happens to it on the Microsoft side. The high-water mark is taken *before* the sync starts, so mail arriving mid-run is picked up next time.

Once every 24 hours per account, the script expunges inbox messages older than N days (`UID SEARCH BEFORE`, `UID STORE +FLAGS \Deleted`, `EXPUNGE`), again subject to the Gmail archive/trash setting.

If Gmail ever changes `UIDVALIDITY` (rare), the script logs it and rescans the last 7 days of the inbox. `Message-Id` deduplication keeps that from creating duplicates.

Switching modes is just editing `RETAIN_DAYS`. To force a rescan of the last 7 days in retain mode, delete the `lastuid.*` file.

## Files

| Path | Purpose |
|------|---------|
| `/usr/local/bin/gmail2m365.sh` | The script. |
| `/etc/gmail2m365/m365.conf` | Tenant and client ID (shared). |
| `/etc/gmail2m365/m365.secret` | Client secret, one line. |
| `/etc/gmail2m365/<name>.conf` | Per-mailbox config. |
| `/etc/gmail2m365/gmail-*.pw` | Gmail app passwords, one line each. |
| `/var/lib/gmail2m365/<name>/` | Lock, transient token file, retention state. |
| `/var/log/gmail2m365-<name>.log` | Per-mailbox log (stdout and stderr of every run). |

Keep `/etc/gmail2m365` and `/var/lib/gmail2m365` at mode 700 and the files inside at 600. Passwords are passed to `curl` and `imapsync` through files, never on the command line.

## Monitoring

Set `KUMA_PUSH_URL` to an [Uptime Kuma](https://github.com/louislam/uptime-kuma) *push* monitor URL. The script only pushes after a run with zero errors, so an expired secret, a revoked app password, a failing imapsync, or a dead host all show up as the monitor going down. Use one monitor per mailbox; a shared one would hide a single failing mailbox behind the others. A monitor interval of about 3× your cron interval gives one missed run of slack.

## Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| `token request failed: AADSTS7000215` | Wrong or expired client secret. |
| `token request failed: AADSTS700016` | Wrong `CLIENT_ID` or `TENANT_ID`. |
| Token mints but Host2 login fails | Service principal not registered in Exchange Online, mailbox permission missing, or IMAP disabled on the mailbox. |
| Host1 login fails | Wrong app password, 2-Step Verification off, or IMAP disabled in Gmail. |
| Runs take minutes | The destination inbox is huge. `MAXAGE_DAYS` in the script (default 7) limits how far back both sides are scanned. |
| `imapsync killed after 300s` | An IMAP session hung (seen occasionally on Gmail expunge). `RUN_TIMEOUT` caps each run; the next run resumes and `Message-Id` dedup prevents duplicates. |
| Mail "deleted" from Gmail shows up in All Mail | Gmail's expunge setting is on *Archive*, Auto-Expunge is on, or All Mail is still visible over IMAP. All three are covered in [Gmail setup](#gmail-setup-once-per-source-account). |
| `can not have both --usecache and --skipcrossduplicates` | You added `--usecache` to `EXTRA_ARGS`. Don't; see [Retention modes](#retention-modes). |

Run with `EXTRA_ARGS=( --justlogin )` to isolate authentication problems from sync problems. imapsync's full output is in the per-mailbox log.

## Known limitations

- Only `INBOX` is synced. Gmail labels other than Inbox are ignored.
- Gmail's `$Phishing` / `$NotPhishing` keyword flags are stripped because Exchange rejects them.
- The retention high-water mark is per Gmail account, not per destination. Feeding the same Gmail account into two destination mailboxes in retain mode is not supported.
- Built and tested on Debian 13 with imapsync 2.324. Other distributions need an equivalent of `install-deps-debian.sh`.

## License

MIT. See `LICENSE`.
