# Release credentials

Releases publish as the `4dstem-release` IAM user, scoped to one bucket. Same
approach as `emd`, with the differences noted below.

`4dstem-release-policy.json` is the inline policy on that user. Read and write
within `4dstem-explorer`, and nothing else.

**Deliberately no `s3:DeleteObject`.** A release only ever adds files, and the
appcast keeps pointing at the older archives and deltas that installations on a
previous version upgrade through — so nothing here should be able to remove
them. This is the one place the policy differs from `ptycho-release`, which was
granted delete it does not need.

Unlike `emd`, there is no prefix condition: this bucket serves the appcast and
the archives from its root, and the feed URL baked into every shipped copy
(`https://4dstem-explorer.s3.amazonaws.com/4DSTEMExplorerAppcast.xml`) cannot be
moved under a prefix without stranding them.

## Public read

Already applied, and stricter than `emd`'s — it additionally requires HTTPS:

    {"Sid": "PublicReadHTTPSOnly", "Effect": "Allow", "Principal": "*",
     "Action": "s3:GetObject", "Resource": "arn:aws:s3:::4dstem-explorer/*",
     "Condition": {"Bool": {"aws:SecureTransport": "true"}}}

Because the bucket policy grants the read, an upload that forgets
`--acl public-read` is still publicly readable. That failure mode — publishing
an appcast that quietly 403s and takes updates away from every installation —
cannot happen here.

## Creating it

    aws iam create-user --user-name 4dstem-release
    aws iam put-user-policy --user-name 4dstem-release \
        --policy-name publish-releases \
        --policy-document file://Scripts/aws/4dstem-release-policy.json
    aws iam create-access-key --user-name 4dstem-release
    aws configure --profile 4dstem-release      # region us-east-1, where the bucket is

`Scripts/make_release.sh` passes `--profile 4dstem-release`.

## The static key

The same weakness `emd` documents: `~/.aws/credentials` holds a secret that does
not expire. Rotate with

    aws iam create-access-key --user-name 4dstem-release    # then update the profile
    aws iam delete-access-key --user-name 4dstem-release --access-key-id OLD_ID

and if it ever leaks, `delete-access-key` at once — nothing else revokes it. The
blast radius is bounded by the policy: publish to one bucket, no delete, so a
leaked key cannot remove the archives older installations upgrade through.

An assume-role setup avoids the static key but cannot work here, for the reason
recorded in `emd`: `sts:AssumeRole` refuses root, and root is what `aws login`
authenticates as.

## What is actually set up

IAM user `4dstem-release`, inline policy `publish-releases` (the file above),
one access key, stored as the `4dstem-release` profile in `~/.aws/credentials`.
`Scripts/make_release.sh` passes `--profile 4dstem-release`.

Verified after creating it — the scope holds:

| attempt | result |
| --- | --- |
| list `s3://4dstem-explorer/` | allowed |
| put an object | allowed (2.0.2 published with it) |
| delete an object | AccessDenied |
| list `s3://ptycho-explorer/` | AccessDenied |
| list `s3://emd-sparkle/` | AccessDenied |
| list every bucket | AccessDenied |

The delete probe targets a key that does not exist: S3 evaluates permission
before existence, so a denial is conclusive and no real archive is at risk.

A probe must also tell "denied" apart from "could not run". An earlier version
of this check reported delete as *allowed* when the real cause was a profile
that did not exist yet — a missing prerequisite reading as a permission grant,
which is the one mistake a verification table must not make.
