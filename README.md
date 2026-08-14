# sample-nodejs — GitOps repository

Declarative source of truth for **what is deployed, where**. ArgoCD reconciles the cluster
against this repository; nothing is applied by hand except the one bootstrap manifest below.

Application source, Helm chart and CI live in [1bugo2/sample-nodejs](https://github.com/1bugo2/sample-nodejs).

## Layout

```
bootstrap/root-app.yaml              app-of-apps — the only manifest applied manually
argocd/projects/                     AppProject: which sources and destinations are allowed
argocd/applications/                 one Application per environment
envs/<env>/values.yaml               Helm values for that environment
scripts/bootstrap-vm.sh              rebuilds the k3s lab from bare Ubuntu
```

## Why a separate repository

The task offered a choice between a dedicated GitOps repository and having ArgoCD read the
app repository directly. This is the separate-repository option, for four reasons:

1. **CI never holds a cluster credential.** The pipeline's entire deploy authority is
   "write a version number into one file in one repository", via a deploy key scoped to
   this repo alone. There is no kubeconfig in GitHub Actions, and the cluster
   (`192.168.56.101`, host-only network) is unreachable from the internet by design —
   ArgoCD only ever polls outbound.
2. **No CI recursion.** If the pipeline committed the version bump back into the repo it
   builds from, that commit would retrigger the pipeline. Avoiding that needs `[skip ci]`
   markers or path filters, both of which are easy to get subtly wrong.
3. **Deployment history is separate from code history.** `git log` here is the deploy
   log — who deployed what, when. `git revert` is the rollback, and it does not revert
   application source at the same time.
4. **Least privilege scales.** Adding a second environment or cluster changes access
   control here, not in the repository developers push to daily.

The cost is two repositories to keep in step, and a deploy is not atomic with its
merge — there is a gap between the app repo merging and ArgoCD syncing. Both are
acceptable; the credential separation is not something a single repo can give you.

## How a change reaches the cluster

```
PR to app repo  →  PR gate (secrets, SAST, deps, image build+smoke+scan, chart lint)
       │
    merge to main
       │
   release workflow:  SemVer from Conventional Commits  →  git tag
                      build → smoke test → Trivy gate → push to private GHCR
                      SBOM + cosign signature, chart pushed as an OCI artifact
       │
       └─ commits the new image digest to envs/dev/values.yaml here
                      │
             ArgoCD polls this repo, syncs, prunes, self-heals
```

The Trivy gate runs **before** the push, so an image with a HIGH or CRITICAL vulnerability
never reaches the registry at all — rather than being published and then flagged.

## Bootstrap

```bash
# 1. Build the cluster (k3s + Traefik + metrics-server + ArgoCD)
./scripts/bootstrap-vm.sh

# 2. Create the pull credential for the private registry
kubectl create namespace sample-nodejs
kubectl -n sample-nodejs create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<token-with-read:packages>

# 3. Hand ArgoCD the root application; everything else follows from this repo
kubectl apply -f bootstrap/root-app.yaml
```

## Rollback

```bash
git revert <commit that bumped the digest>
git push
```

ArgoCD syncs the previous digest. No `helm rollback`, no `kubectl`, and the rollback is
itself a reviewable commit.
