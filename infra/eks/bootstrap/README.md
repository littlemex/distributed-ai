# Bootstrap remote Terraform state for `infra/eks`

This standalone root module creates the S3 bucket and DynamoDB lock table that
the parent `infra/eks` working directory can use when you opt into remote
state.

It intentionally uses **local state** itself: the bucket and lock table cannot
store their own state before they exist.

## What it creates

- An S3 bucket with **versioning enabled**. Versioning is the recovery path for
  a truncated or otherwise bad state write: promote an older object version
  back to current.
- Default bucket encryption with **SSE-KMS**. Set `kms_key_id` for a
  customer-managed key, or leave it null to use the AWS-managed `aws/s3` key.
- An all-four-flags public access block plus a bucket policy that denies
  non-TLS access.
- A lifecycle rule that expires **noncurrent** object versions after
  `noncurrent_version_expiration_days` (default `90`) so history does not grow
  without bound.
- A DynamoDB lock table for Terraform `>= 1.9`. Terraform `>= 1.10` can use
  native S3 state locking (`use_lockfile = true`); the parent module targets
  `>= 1.9`, so this module creates a DynamoDB lock table by default.

## Bootstrap and migrate

### One command

From `infra/eks/`, run the wrapper, which applies this module, writes
`backend.hcl`, installs `backend.tf`, and prints the migrate command:

```
scripts/bootstrap-remote-state.sh -b <state-bucket-name> -r <aws-region> [-t <lock-table-name>] [-k <kms-key-arn-or-alias>] [-p <aws-profile>]
```

### By hand

1. `cd infra/eks/bootstrap`
2. `terraform init`
3. `terraform apply -var 'region=<aws-region>' -var 'state_bucket_name=<state-bucket-name>' -var 'lock_table_name=<lock-table-name>' -var 'state_key=<state-object-key>'`
4. If you want a customer-managed KMS key, add `-var 'kms_key_id=<kms-key-arn-or-alias>'` to the `apply` command above.
5. `terraform output -raw backend_hcl > ../backend.hcl`
6. `cd ..`
7. `cp backend.tf.example backend.tf`
8. `terraform init -backend-config=backend.hcl -migrate-state`
9. `terraform state list` should show your existing resources, and a follow-up `terraform plan` should not propose recreating existing resources.

`backend.hcl` and the copied `backend.tf` stay untracked; both are git-ignored.
If you want to keep using local state, do not create either file.
