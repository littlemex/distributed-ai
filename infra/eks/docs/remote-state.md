# Remote state for `infra/eks`

## Why this exists

Local Terraform state has no history and no locking. A corrupt or truncated
write (an interrupted apply, a bad `state` command, concurrent runs) can leave
the working `terraform.tfstate` unusable with only the single local
`terraform.tfstate.backup` as a fallback. An S3 backend with versioning turns
that class of failure into routine recovery: every state write is a new object
version, so a known-good version can be promoted back to current when the latest
write is bad. A DynamoDB lock table prevents two applies from racing the same
state in the first place.

Terraform state here is also sensitive. It contains secrets such as the
CloudFront `X-Origin-Verify` value and transient ECR tokens, so the remote
backend enforces encryption at rest and TLS in transit.

## Local state is still the default

Nothing changes unless an operator deliberately opts in.

`infra/eks` does **not** commit an active `backend "s3" {}` block, because
Terraform `1.9` treats even an empty S3 backend block as a real remote backend
and fails a plain `terraform init` until `bucket` and `key` are provided.
To preserve the existing local-state workflow, the backend block is shipped as
`backend.tf.example`, not as active `.tf` config:

1. If you do nothing, `terraform init` keeps using local state exactly as it
   does today.
2. If you want S3, copy `backend.tf.example` to ignored `backend.tf`.
3. Create ignored `backend.hcl` from `backend.hcl.example`.
4. Run `terraform init -backend-config=backend.hcl -migrate-state`.

That design keeps local experimentation unchanged while making remote state an
explicit operator choice.

## Opt-in flow

1. Create the state bucket and lock table with [`bootstrap/`](../bootstrap/README.md). The bootstrap module itself uses local state by design.
2. In `infra/eks/`, copy `backend.tf.example` to `backend.tf`.
3. Fill in `backend.hcl` from `backend.hcl.example`, or generate it during the bootstrap step with `terraform output -raw backend_hcl > ../backend.hcl` from `infra/eks/bootstrap/`.
4. Run `terraform init -backend-config=backend.hcl -migrate-state`.
5. Run `terraform state list` to confirm the migrated state is readable, then run `terraform plan` and confirm it does not look like a first apply.

`backend.hcl` should stay environment-specific and untracked. The committed
example files contain placeholders only; no real bucket names, regions, table
names, or KMS ids belong in git.

## Recover a bad state from S3 versioning

1. Stop concurrent `terraform apply` runs and make sure nobody else is writing state.
2. List the available versions of the state object:

```bash
aws s3api list-object-versions \
  --bucket <state-bucket-name> \
  --prefix <state-object-key>
```

3. Promote the last known-good version back to current:

```bash
aws s3api copy-object \
  --bucket <state-bucket-name> \
  --copy-source '<state-bucket-name>/<state-object-key>?versionId=<good-version-id>' \
  --key <state-object-key>
```

Because the bucket is versioned, that recovery does not destroy history. The
bad current object remains as an older version, and the copied good version
becomes the new current object.

4. Run `terraform state list` or `terraform plan` again and confirm the state now matches reality.

If you want to inspect an older version before promoting it, download it first:

```bash
aws s3api get-object \
  --bucket <state-bucket-name> \
  --key <state-object-key> \
  --version-id <good-version-id> \
  /tmp/terraform.tfstate.recovery
```

## Staying on local state

Do nothing. Leave `backend.tf.example` un-copied, do not create `backend.hcl`,
and keep running `terraform init` as before. Local state remains the default
behavior until an operator explicitly opts into S3.
