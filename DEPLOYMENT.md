# Deployment to Amvera

## Two independent launch configurations

- Local development stays unchanged: `docker compose up --build` starts PostgreSQL,
  the Nest development server and Vite in separate containers with local mounts.
- Amvera uses [amvera.yaml](amvera.yaml) and [Dockerfile.amvera](Dockerfile.amvera).
  Docker builds both projects, copies the client output into the server's `public`
  directory and starts one server on port 5000. The server serves the UI and `/api`.
  PostgreSQL must be configured separately.
- The working repository keeps its submodules. Only the deployment snapshot sent
  to Amvera contains their actual files instead of Git links.

## One-time setup

1. In Amvera, disconnect the existing GitHub webhook/integration for this application.
   Do not run direct synchronization alongside this workflow: it would reintroduce
   submodule links into the deployment repository.
2. Copy the application's HTTPS Git repository URL from Amvera.
3. In the parent GitHub repository, open **Settings > Secrets and variables > Actions**.
   Add repository variable `AMVERA_GIT_URL`, for example
   `https://git.amvera.ru/YOUR_USER/YOUR_APPLICATION`. Do not put credentials in it.
4. Add repository secrets `AMVERA_USERNAME` and `AMVERA_PASSWORD` for Git access.
   Never commit these values. Amvera documents account username/password
   authentication for its HTTPS Git endpoint.
5. If any submodule is private, add secret `SUBMODULES_READ_TOKEN`: a token with
   read access to repository contents for the parent and all private submodules.
   Public repositories use the workflow's default GitHub token.
6. If Google sign-in is needed, add repository variable `VITE_GOOGLE_CLIENT_ID`.
   This is a **public** OAuth client ID, not a client secret. The exporter sets it
   as the Docker build argument's default only in the deployment copy.
   Amvera runtime variables are not available during its build.
7. In Amvera, configure:
   - `DATABASE_URL`: the real PostgreSQL connection string, stored as a secret;
   - `trackingApp_jwtPrivateKey`: a secret of at least 32 UTF-8 bytes;
   - `trackingApp_googleClientId`: the same Google client ID, if used;
   - `PORT=5000` if setting an explicit port; do not use a different value without
     also changing `run.containerPort`;
   - persistence mounted at `/data` for uploads (the Dockerfile sets
     `UPLOADS_DIR=/data/uploads`);
   - an application domain. For Google sign-in, register the public UI origin
     in the Google OAuth client settings too.
8. Commit and push these deployment files to the parent's `master` branch.
   Alternatively, run **Actions > Deploy to Amvera > Run workflow** on `master`.

No GitHub-to-Amvera webhook is required: the workflow pushes directly to Amvera,
which starts the build. Its first snapshot replaces the old tracked deployment
files, including a stale `amvera.yml`, without rewriting Git history.
Manage deployment configuration in this source repository rather than editing it
in the Amvera UI: the next snapshot will replace UI-created configuration changes.

## Publishing updates

1. Commit and push changes in each modified submodule.
2. Commit the updated submodule pointers in the parent repository and push `master`.
3. The workflow checks out those exact commits, exports committed files and pushes
   the snapshot to Amvera. Uncommitted local changes are never deployed.

A push to a submodule alone does **not** trigger deployment of the parent.
This keeps frontend/backend releases explicit and reproducible.

The exporter omits environment files, Git metadata, dependency/build directories,
logs, coverage and uploads. Review committed source for credentials anyway:
filename exclusions are not a secret scanner.

Delivery is serialized, preserves the existing Amvera `master` history and never
force-pushes. A remote update during delivery causes the normal Git push to fail;
inspect that update before rerunning. Authentication and export errors fail the job.
An identical snapshot creates no commit and does not trigger another build.

## Verification and troubleshooting

A green workflow means **source delivery**, not a successful build or healthy app.
Check in Amvera:

1. The repository contains real files inside both application directories.
2. The Docker build succeeds.
3. Startup migrations succeed and the server starts. The image runs
   `npm run db:deploy` before starting Nest; unreachable PostgreSQL prevents startup.
4. The public URL serves the UI; browser API requests use `/api` on that same origin.
5. Opening a nested client route directly works.
6. Uploads survive a restart.

Local Compose configuration and local environment files are not modified by the
workflow. To deploy a previous version, revert the parent source/submodule pointers
in a new commit and push it; do not overwrite the Amvera branch history.

Run the local delivery integration test in Bash:

```bash
bash scripts/test-deploy-amvera.sh
```

The test uses temporary local Git repositories, not Amvera credentials or network
access. It tests delivery and export behavior, not the application's Docker build.

## References

- [Amvera Git remote delivery](https://docs.amvera.ru/applications/git/secondary-origin.html)
- [Amvera build process](https://docs.amvera.ru/applications/build.html)
- [Amvera variables and secrets](https://docs.amvera.ru/applications/configuration/variables.html)
