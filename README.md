# vmin-kit

*[Türkçe](README-tr.md)*

Sets up a Virtualmin (GPL) hosting server with a single command.

**Supported systems:** Debian 12, Debian 13, Ubuntu 22.04 LTS, Ubuntu 24.04
LTS. On anything else the installer stops before it starts (`ALLOW_ANY_OS=1`
forces it). A clean install has been verified on all four.

The RHEL family (AlmaLinux, Rocky, RHEL) is **deliberately out of scope**:
Virtualmin supports it, but this tool is built on `apt`/`dpkg`. Claiming
support and leaving a half-finished install would be worse than not supporting
it at all.

When the run finishes the main domain is created, has a certificate and is
live; the panel, webmail and the Docker interface are reachable on their own
sub-domains.

Four Webmin plugins come with it: **Git Deploy**, **Composer** and
**Cloudflare DNS** work per domain inside the Virtualmin panel, and **Check
vmin-kit** tells you from the panel whether a Webmin or Virtualmin upgrade has
broken any of them.

---

## 1. Installation

### DNS first

The main domain and the hostname need **A records pointing at the server's
IP**:

```
example.com      A   <server-ip>
s.example.com    A   <server-ip>
```

On Cloudflare, keep the **proxy off (grey cloud)** during installation; you can
turn it on once the certificates are issued.

The installer checks this itself and, if something is wrong, tells you what to
fix without running anything.

### Run it

```bash
git clone <repo-url>
cd vmin-kit
sudo ./install.sh
```

There is one question: **the main domain**. After that a summary of the
settings to be used is shown for confirmation.

To run it from a script, pass the domain as an environment variable:

```bash
MAIN_DOMAIN=example.com sudo -E ./install.sh
```

**Running it again is harmless.** Every step is idempotent: what is installed is
skipped, what is missing is completed. That is also how an interrupted install
is resumed.

### The install log

The screen shows only the result of each step; the detailed output of the
commands goes to `vmin-kit-install-<timestamp>.log`. The file is written on
every run, no option needed. When a step fails the screen says so and the
reason is in the log.

The one exception is the Virtualmin installer: it takes minutes, so its output
streams to the screen as well.

To see everything on screen:

```bash
sudo ./install.sh --verbose
```

---

## 2. Settings — `config.env`

Everything except the main domain comes from this file. The file **lives in the
repository**: change it, commit it, and the next server that clones the
repository installs the same way.

| Setting | What it does | Default |
|---|---|---|
| `POSTGRES` | Installs PostgreSQL (Virtualmin picks it up itself and offers it among the database options) | 1 |
| `COMPOSER` | Installs Composer (required by the Composer plugin) | 1 |
| `DOCKER` | Docker Engine + Portainer + the `docker.<domain>` site | 1 |
| `PLUGIN_DEPLOY` | Installs the Git Deploy plugin | 1 |
| `PLUGIN_COMPOSER` | Installs the Composer plugin | 1 |
| `PLUGIN_CLOUDFLARE` | Installs the Cloudflare DNS plugin | 1 |
| `PLUGIN_CHECK` | Installs the Check VminKit plugin | 1 |
| `PANEL_PROXY` | Publishes the `webmin.<domain>` and `usermin.<domain>` sub-domains | 1 |
| `LOCK_PANEL_PORTS` | Binds ports 10000/20000 to `127.0.0.1` only | 1 |
| `ROUNDCUBE` | The `webmail.<domain>` sub-server + Roundcube | 1 |
| `ROLE_ALIASES` | Role addresses kept on new domains | `postmaster abuse` |
| `NO_ADMIN_REDIRECT` | Turns off Virtualmin's `admin.<domain>` → panel shortcut | 1 |
| `NO_WEBMAIL_REDIRECT` | Turns off the `webmail.<domain>` → Usermin shortcut | 1 |
| `HOST_PREFIX` | The hostname and panel name | `s` |
| `NS1_PREFIX` / `NS2_PREFIX` | The zone's nameserver pair | `ns1` / `ns2` |
| `DOCKER_PREFIX` `WEBMIN_PREFIX` `USERMIN_PREFIX` `WEBMAIL_PREFIX` | Sub-domain names of the interfaces | `docker` `webmin` `usermin` `webmail` |
| `PORTAINER_IMAGE` / `PORTAINER_PORT` | The Portainer container | `ce:lts` / `9000` |
| `PORTAINER_BIND_LOCAL` | Binds the Portainer port to `127.0.0.1` (reached through the reverse proxy) | `yes` |

Setting a plugin flag to 0 does **not remove an installed plugin**, it only
skips installing it. To remove one: `sudo ./update-plugins.sh --remove`.

At the end of the file are the escape hatches (`SKIP_DNS_CHECK`,
`ALLOW_ANY_OS`, `SERVER_IP`, `DNS_RESOLVER`) — normally unnecessary, and left
commented out.

---

## 3. What the installer does

| Step | What it does |
|------|--------------|
| `hostname` | Sets the hostname to `s.<domain>` |
| `virtualmin` | Installs Virtualmin with the official installer |
| `host-domain` | The hostname virtual server (the server's default site and the source of the service certificates); created even when no certificate can be issued |
| `postgres` / `composer` | The PostgreSQL and Composer packages *(optional)* |
| `dns-template` | DNS defaults for new domains |
| `panel-redirects` | Turns off the `admin.<domain>` and `webmail.<domain>` shortcuts |
| `domain-defaults` | SPF + DMARC on, role addresses limited |
| `dkim` | Enables DKIM; every domain created from then on signs outgoing mail |
| `plugins` | Packages and installs the plugins and registers them with Virtualmin |
| `main-domain` | Creates the main domain with an explicit feature list (spam/virus scanning and PostgreSQL excluded — the post-install wizard decides those) |
| `host-dns` | Adds the A record for the hostname |
| `ssl` | Let's Encrypt certificate + automatic renewal |
| `panel-sites` | Publishes the `webmin.` and `usermin.` sub-domains |
| `webmail` | The `webmail.` sub-domain + Roundcube *(optional)* |
| `docker` / `portainer` / `docker-site` | Docker Engine, the Portainer container and the `docker.` sub-domain *(optional)* |
| `lock-panel-ports` | Closes the panel ports once the proxy is verified to answer **and** the sub-domain is seen to have a valid certificate |
| `report` | Writes the summary to the screen and to the install log |

A failing step does not stop the installation: that step is skipped, the rest
run, and the state shows up in the report.

**Certificates and ports.** Every sub-domain (`webmin.`, `usermin.`,
`webmail.`, `docker.`) has its certificate checked in the step that creates it,
and is asked for once more if it is missing. If no certificate can be issued —
DNS has not propagated yet, or the Let's Encrypt quota is exhausted — **that
service's management port is not closed**: a browser will not trust a proxy
address on a self-signed certificate, so closing the port too would leave no
way in at all. Once the obstacle is gone, another `./install.sh` requests the
certificate and closes the port.

---

## 4. After the install

### Addresses

| Address | What |
|---|---|
| `https://webmin.<domain>` | The Virtualmin / Webmin panel |
| `https://usermin.<domain>` | Usermin (the user interface) |
| `https://webmail.<domain>` | Roundcube |
| `https://docker.<domain>` | Portainer |
| `https://s.<domain>:10000` | The panel's direct address — closed when `LOCK_PANEL_PORTS=1` |

No management port is left open to the outside: Webmin, Usermin and Portainer
listen on `127.0.0.1` and are published through Apache with their own
certificates.

### First things to do

1. **Read the summary:** it is printed when the install finishes — what was
   done, what was not, and what comes next. Failed steps, ports listening to
   the outside world and the vmin-kit version the server was built with are all
   there. The same summary sits at the end of the install log.
2. **The main domain's password** is generated randomly and **not stored**. If
   you need it for the panel or FTP, set a new one under *Edit Virtual Server →
   Password*.
3. **Portainer** asks for a setup token on first use, and the token is
   short-lived. It is in the install output; if you miss it, run
   `sudo ./configure-docker.sh`.
4. **In BIND mode** the registrar needs glue records for `ns1` / `ns2`.

### Mail

The domain owner's unix account is also a mailbox, and the role addresses
(postmaster, abuse) land there. Create your own addresses as separate mailboxes
(*Edit Users → Add a user to this server*). The username is the email address
itself; webmail is logged into with the full address.

Outgoing mail is signed with DKIM, and SPF and DMARC records are added to every
new domain. The installer enables these before the first domain. DMARC starts
at `p=none` — after a few weeks you can tighten it to `quarantine` from the
panel.

### DNS

The tool looks at the domain's NS records and detects the mode itself:

- **External DNS** (Cloudflare and the like) — you manage the A records there;
  the Cloudflare plugin can sync the local zone to it.
- **BIND** — the server is authoritative and the records are managed from the
  panel.

In both modes the local zone is always generated, and the nameserver pair is
`ns1.<domain>` / `ns2.<domain>`.

---

## 5. The plugins

The first three work **per domain**. To use one on a domain, its checkbox has
to be on under *Edit Virtual Server* (on by default for new domains). When it
is, they appear in the left menu under the domain.

Root manages every domain; a domain owner logs in with their own account and
sees only their own domain.

### Git Deploy

Deploys to the server from a remote git repository — the repository is not
hosted here.

1. **Git Deploy → Add a deployment.**
2. Enter the repository address and press **Check**; if it is reachable the
   branches are offered in a list, and if it is not, no record is created.
3. **Target directory:** a folder under the web directory. The form shows a
   fixed prefix (`/home/<user>/public_html/`) and you write only the
   sub-folder; leave it empty to deploy into that directory itself.
4. **Deployment mode:** *Manual* — a pull does not touch the site, you start
   the deployment yourself. *Automatic* — deploys straight after every pull.
5. Optionally write **post-deploy commands** (one command per line).

**Pulling and deploying are separate operations.** A pull fetches from the
remote into the local copy and the site does not change; you look at what
arrived on the **Commits** page and then press **Deploy**. The *State* column
in the list shows the live and the pulled commit separately, so a pending
deployment is visible there. **Log** is the output of the last operation.

The post-deploy commands run in the target directory, as the domain's own user,
like a shell script — it is one session, so a `cd` on one line still applies on
the next and multi-line `if` / `for` constructs work. That directory's PHP
version is available as `php`, so `php artisan migrate` and `composer install`
work as written, with no full paths. The deployment stops at the first failing
command and is marked failed; every command that runs is written to the log.

**The webhook.** The form shows a hook address for each deployment:
`https://webmin.<main-domain>/vmkit-deploy/nph-hook.cgi?uuid=...`. Put that address
in your git server's webhook settings — the provider does not matter (GitHub,
GitLab, Gitea) and you can call it by hand with `curl`. When called it follows
the deployment mode: automatic pulls and deploys, manual only pulls.

The UUID in the address is **a password**: it needs no login, and whoever knows
the address can trigger a deployment. It ends up in server logs, so do not
share it; if it leaks, "generate a new address" on the form invalidates the old
one immediately.

For private repositories, add the public key from the **Domain SSH key** page
to **your account** on GitHub (Settings → SSH keys). Do not add it as a deploy
key on a single repository: GitHub accepts a deploy key on one repository only,
so the second private repository would be stuck.

If the application serves from a sub-folder (Laravel and the like), use
Virtualmin's own setting: *Website Options → Website documents sub-directory =
`public_html/public`*. The deploy root stays `public_html`.

### Composer

Finds the folders containing a `composer.json` under the web directory by
itself and runs each one **with its own PHP version** (Virtualmin can hold a
PHP version per directory).

- **Operations:** install, update, dump-autoload.
- The **Packages** page lists the installed packages, their latest versions and
  which ones can be updated — it only reads, it changes nothing.

The commands run with `--no-dev --optimize-autoloader` by default, the form
Composer recommends for production: development packages are not installed and
the autoloader is optimised. If a project needs the development packages you
can turn that off in the module configuration — the setting is server-wide,
there is no exception for a single project.

Only the web directory is scanned, not the whole home directory; a sub-server's
directories show up in its own panel.

### Cloudflare DNS

The local BIND zone is the model, Cloudflare is the published copy.

1. Enter the domain's **API token** on the **Cloudflare DNS** page. The token is
   per domain — each domain carries the token of its own account.
2. The **Sync** switch turns tracking on and off for that domain while the token
   stays stored. With no token the domain is not processed at all.
3. The **Local zone vs Cloudflare** page **shows what would happen first** and
   writes nothing. Records out of scope get import / adopt / delete buttons.
   Clicking the state in the Proxy column switches the orange/grey cloud.

Only records tagged `vmkit` are touched: records you added by hand, tunnels and
Email Routing records are left alone.

The sync can be run by hand, but automatic is how it is meant to work: when the
plugin is installed it creates its own systemd units, is triggered the moment
the zone file changes, and checks every 15 minutes besides. An unchanged zone
makes no API call at all. The plugin's main page shows the state of the service
and restarts it if it has stopped.

### Check VminKit

*System Settings → Check VminKit.* The three plugins call into Virtualmin,
Webmin's UI library and a few Webmin modules, none of which promise a stable
interface; an upgrade can rename a function or stop calling a hook, and the
plugin only breaks when someone opens the page. This one finds out first.

It scans the plugins' own source for everything they call and looks each name
up in the running system, checks that Virtualmin still calls every hook they
implement, and verifies what each plugin needs to work: the webhook's Webmin
user and anonymous-access entry, the Cloudflare sync units, the `composer`
command. Where it can, a **Repair** button puts things right.

You do not have to remember to run it: after a Webmin or Virtualmin upgrade
(and once a day) the checks run again by themselves when the Virtualmin
dashboard is opened, and a failure shows up there as a warning. The page itself
only shows the last result.

---

## 6. Helper scripts

```bash
sudo ./install.sh                    # install (running it again is harmless)
sudo ./update-plugins.sh             # update the plugins (after a git pull)
sudo ./update-plugins.sh --remove    # remove the plugins
sudo ./configure-docker.sh           # reopen the Portainer setup screen with a new token
./build-plugins.sh [module]          # package the plugins as .wbm.gz (dist/)
```

**When DNS settles later:** there is no separate script, `sudo ./install.sh` is
enough. Every address without a certificate, the hostname included, is
requested again, and the management ports are closed once they are issued.

**What `update-plugins.sh` does:** copies the plugin files straight into
Webmin's module directory. There is no build step, refreshing the page is
enough. The development loop is `git pull && sudo ./update-plugins.sh`.

---

## 7. Troubleshooting

**I cannot reach the panel — the ports are locked and the proxy is not working
either.**
Log in over SSH, delete the `bind=` line from `/etc/webmin/miniserv.conf` and
run `systemctl restart webmin`. The panel opens on `:10000` again.

**No certificate was issued, it stayed self-signed.**
Make sure DNS points at the server (grey cloud on Cloudflare), then run
`sudo ./install.sh` again.

**The Portainer setup screen says "timed out".**
`sudo ./configure-docker.sh` — it restarts the container and gives you a new
token.

**The Cloudflare sync is not working.**
Look at the service state on the plugin's main page; if it has stopped, opening
the page restarts it. Also: `systemctl status vmkit-cloudflare-sync.path`.

**A step of the installation failed.**
Fix the cause and run `sudo ./install.sh` again; completed steps are skipped.

---

## 8. Layout

```
install.sh           # the single entry point
config.env           # settings (kept in the repository)
lib/common.sh        # helper functions
lib/steps.sh         # the installation steps
plugin/              # source of the Webmin plugins
build-plugins.sh     # plugin/ -> dist/<module>.wbm.gz
update-plugins.sh    # copy the plugins to the server (development)
configure-docker.sh  # the Portainer setup screen
```
