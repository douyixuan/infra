# Ubuntu 22.04 static-site deployment host

Reusable bootstrap for a deployment server that serves a zipped static HTML artifact via Nginx and deploys it from a local GitLab Runner (shell executor).

Layout:

```text
GitLab build job
  -> site.zip artifact
  -> deployment-server GitLab Runner
  -> deploy-static-site
  -> /srv/www/<site>/releases/<commit>
  -> /srv/www/<site>/current
  -> Nginx
```

The installer is idempotent enough to re-run for the same site and supports multiple sites by changing `SITE_NAME`, `SITE_HOST`, and/or `LISTEN_PORT`. Repository CI validates both shell scripts with `bash -n` and ShellCheck.

## 1. Create the GitLab runner

In GitLab: **Settings -> CI/CD -> Runners -> New project runner**.

For a production deployment runner:

- Tag: `deploy-215` (or any tag you choose)
- Disable **Run untagged jobs**
- Mark it **Protected**
- Copy the generated runner authentication token (`glrt-...`)

With the current GitLab runner-registration workflow, tags/protected/untagged are set when the runner is created in GitLab; the host registration command mainly needs the GitLab URL, auth token, and executor.

## 2. One-command online install

The script can prompt for the `glrt-...` token from `/dev/tty`, so it does not need to be placed in shell history:

```bash
curl -fsSL https://raw.githubusercontent.com/douyixuan/infra/main/snippets/static-site-deploy/install.sh \
  | sudo env \
      SITE_NAME=my-site \
      SITE_HOST=192.168.22.215 \
      GITLAB_URL=http://YOUR-GITLAB \
      RUNNER_TAG=deploy-215 \
      bash
```

It installs Nginx + GitLab Runner, configures the shell executor, creates `/srv/www/my-site`, installs the atomic deployment helper, registers the runner, and performs a local health check.

For a Vue/React-style SPA, add `SPA_MODE=1`.

## 3. Use a replaceable Ubuntu APT mirror

`APT_MIRROR` is used only for this install; the script does **not** rewrite `/etc/apt/sources.list`.

```bash
curl -fsSL https://raw.githubusercontent.com/douyixuan/infra/main/snippets/static-site-deploy/install.sh \
  | sudo env \
      SITE_NAME=my-site \
      SITE_HOST=192.168.22.215 \
      GITLAB_URL=http://YOUR-GITLAB \
      RUNNER_TAG=deploy-215 \
      APT_MIRROR=http://YOUR-MIRROR/ubuntu \
      bash
```

If security packages live on a different mirror, set `APT_SECURITY_MIRROR` too.

The GitLab Runner binary download is also replaceable with `RUNNER_BINARY_URL`. You can pin a version with `RUNNER_VERSION=vX.Y.Z`.

## 4. Fully offline install

On a machine with Docker + internet:

```bash
git clone https://github.com/douyixuan/infra.git
cd infra/snippets/static-site-deploy

./make-offline-bundle.sh \
  --arch amd64 \
  --output ./static-site-deploy-ubuntu22-amd64.tar.gz
```

For an ARM64 target, use `--arch arm64`.

Copy the tarball to the Ubuntu 22.04 deployment server, then:

```bash
tar xzf static-site-deploy-ubuntu22-amd64.tar.gz
cd static-site-deploy-offline

sudo GITLAB_URL=http://YOUR-GITLAB \
  ./install.sh \
    --offline-dir . \
    --site my-site \
    --host 192.168.22.215 \
    --runner-tag deploy-215
```

The offline bundle contains recursive Ubuntu package dependencies, the GitLab Runner binary, checksums, and the installer. Runner registration still talks only to your internal GitLab server.

## 5. Project CI

Start from [`gitlab-ci.yml.example`](./gitlab-ci.yml.example).

The required artifact contract is:

```text
site.zip
├── index.html
├── assets/
└── ...
```

The deploy job ultimately runs:

```bash
deploy-static-site my-site site.zip "$CI_COMMIT_SHA"
```

Deployment uses a new release directory plus an atomic `current` symlink switch. A failed HTTP health check switches `current` back to the previous release.

## 6. Server checks

```bash
systemctl status nginx gitlab-runner
gitlab-runner list

ls -l /srv/www/my-site/current
ls -1 /srv/www/my-site/releases

curl -H 'Host: 192.168.22.215' http://127.0.0.1/index.html
```

No `tmux`, `nohup`, `scp` deployment loop, or `python -m http.server` is required.
