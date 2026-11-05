# EC2 Capacity Manager real-time supportability check, as one script and one HTML report

`scripts/supportability_report.py` calls `get-capacity-manager-supportability-scores` for every market and requested amount you choose and writes two files: a JSON data file with everything the page needs, and one self-contained HTML file with a High / Medium / Low table per instance type and Availability Zone. The HTML is built from the JSON file and from nothing else, so it can be rebuilt later with `--from-json` without calling AWS. The page switches between English and Japanese with a button, and its style follows the Cloudscape Design System.

It only restates what the AWS documentation says about the scores (see [What the documentation guarantees](#what-the-documentation-guarantees)). It does not launch, reserve or modify any capacity.

## Run

```bash
export AWS_PROFILE="${AWS_PROFILE:-default}"
export CM_REGION="ap-northeast-1"
cd investigations/2026-11-05-ec2-capacity-supportability-report
uv run scripts/supportability_report.py --region "$CM_REGION" --lang en --open
```

Set `AWS_PROFILE` to the profile that has the permissions below and `CM_REGION` to the Region where Capacity Manager is enabled (or where you want to enable it). The block is meant to be run from the root of this repository.

| Option | Meaning | Default |
|---|---|---|
| `--from-json` | Rebuild the HTML from a data file written by an earlier run. No AWS call, no credentials, no `--region`. Combine with `--lang`, `--out`, `--overwrite`, `--open`. A data file that does not match the schema, has a value of the wrong type, or cannot be read is refused with exit status `2`. The page is placed like a run's page: if the data file records an incomplete run (`status` other than `0`) the page is saved as `<name>.failed-<time>.html` and the exit status is still `0`, because rebuilding worked. `--out` may not be the data file itself | none |
| `--region` | Region where Capacity Manager is enabled; the API is called here. Required (unless `--from-json` is used), because Capacity Manager can be enabled in one Region per account and a wrong default would send `--enable` to the wrong Region | none |
| `--profile` | AWS profile name | ambient credentials |
| `--enable` | Enable Capacity Manager in `--region` if it is disabled. Without it the script never changes your account. Requires `--expect-account` | off |
| `--expect-account` | A 12-digit account ID. The script stops before any change unless the caller is in this account. Required with `--enable`, so the account is never changed by accident | none |
| `--max-calls` | Refuse to start when one run plans more than this many API calls. The quota of 100 per hour is shared by the whole account, so lower it when others use the account too | 95 |
| `--types` | Instance types to score (up to 50 per request; the script splits larger lists). Cannot be combined with `--requirements`. The default list is a mixed sample for demonstration, so its aggregate score says little about any real workload; pass your own list | a GPU, Trainium and general-purpose sample |
| `--requirements` | JSON for `InstanceRequirementsWithMetadata` (attribute-based selection); cannot be combined with `--types`. The API requires `VirtualizationTypes` in it | none |
| `--azs` | AZ IDs such as `apne1-az4`; Regions may be mixed (up to 10 per request; the script splits larger lists) | 10 AZs in 4 Regions |
| `--markets` | `on-demand`, `spot` | both |
| `--amounts` | Requested amounts, positive integers. Repeated values are run once and the list is sorted ascending. Every score is relative to the amount | `1 10 100` |
| `--unit` | `instances` or `vcpus` | `instances` |
| `--lang` | Language the report opens in. When given, it wins over the language the browser saved; when omitted, the saved choice is used, else English | saved choice, else English |
| `--out` | Output path. The report is written to a hidden temporary file (owner-only, mode 0600 on POSIX systems) next to this path and moved into place at the end. The path itself only ever receives the report of a run that ended with status `0`; any other run saves its report beside it as `<name>.failed-<date>-<time>-<microseconds>.html` and says so. A report that could not be placed at the path is saved as `<name>.unplaced-<date>-<time>-<microseconds>.html`. The hidden temporary file has a short name that does not depend on `--out`, and file systems without hard links are handled by creating the path exclusively and copying into it. An existing file or symbolic link at the path is refused unless `--overwrite` is given, and a directory is always refused. Both checks happen before anything is changed in the account. Parent directories are not checked; a missing directory is created with the default permissions of the system | `~/tmp/supportability/report-<date>-<time>-<microseconds>.html` |
| `--overwrite` | Replace the file at `--out` when the run ends with status `0`. A symbolic link at the path is replaced, not followed. A run that does not end with `0` never replaces it | off |
| `--open` | Open the report in the default browser when done | off |

Exit status: `0` when Capacity Manager was usable and every request returned scores; `1` when authentication fails or the caller is not in the `--expect-account` account; `2` for a command-line usage error (argparse); `6` when the plan would exceed the call cap (below); `3` when Capacity Manager is not enabled and `--enable` was not given, its status could not be read or confirmed, enabling failed, or any request returned an error or a response without usable scores; `4` when the output file cannot be created (nothing is changed in the account), or when the run was fine but the report could not be put at `--out` because the path appeared meanwhile or could not be written (the report is then saved beside it as `<name>.unplaced-<time>`); `5` for any other unexpected error (no report is left behind). For `3` the report is still written, with the errors listed per request. A Region counts as enabled only when `CapacityManagerStatus` is read back as `enabled`. A disabled Region was observed to answer `get-capacity-manager-attributes` with the error code `CapacityManager.Disabled` (2026-11-05; the error code is not in the documentation), and a normal response with status `disabled` is handled as well. A requested instance type x AZ pair that is missing from a successful response is shown as N/A and does not change the exit status.

The call cap: the script refuses to start when one run alone plans more than `--max-calls` (default 95) API calls. It does not know how many queries the account has already used this hour, so the documented quota of 100 queries per account per hour is still yours to track across runs. A run with the defaults makes 6 calls. In `--requirements` mode the instance types are resolved by the API, so the script cannot plan for the per-request limit of 100 type x AZ combinations. What happens beyond that limit is not documented and was not tested; if the API rejects the request the error is shown for that request. A failed attribute-based request has no known type list, so its rows are missing, a warning is shown above the table and every Best value is marked with a dagger. The count of calls does not include automatic SDK retries.

Requirements: Capacity Manager enabled in one Region of the account, and the AWS Support Unified Operations plan on the account. The caller needs permission for the EC2 Capacity Manager actions the script calls (get supportability scores, get attributes, and enable with `--enable`) and `sts:GetCallerIdentity`. The AWS Service Reference for EC2 (JSON, modified 2026-10-29) lists `EnableCapacityManager`, `GetCapacityManagerAttributes`, `DescribeAvailabilityZones` and `DescribeInstanceTypeOfferings` as IAM actions; it lists the operation `GetCapacityManagerSupportabilityScores` but gives it no IAM action. What permission that call needs is therefore not published as of 2026-11-05; the runs here used an administrator role.

## The data file

Every run writes `<out>.json` next to the page (`r.html` gives `r.json`; an `--out` that already ends in `.json` gives `<stem>.data.json`). The file follows the same placement rules as the page: owner-only mode, written to a temporary file first, and placed at the target path only when the run ended with status `0` (otherwise it is saved with the same `.failed-` or `.unplaced-` label as the page). Both targets are checked before anything is changed in the account.

The page is rendered from the parsed JSON text that is written to the file, never from the objects in memory, so anything the page shows is in the JSON by construction. (The page is not rendered from a re-read of the file on disk.) The data file is placed first, because it is the source of the page: if it cannot be placed at its path, the page is saved beside it as `.unplaced-` too, and if only the page cannot be placed, the data file stays and the page can be rebuilt with `--from-json`. The `status` inside the file is the status of the run; `4` (placement failed) is only in the exit status. The top-level keys of schema `ec2-capacity-supportability-report/1`:

| Key | Content |
|---|---|
| `schema`, `generated_by`, `generated_at_jst` | Format name and version, the tool, and the run time in JST |
| `status`, `reasons` | The exit status of the run and one plain-text reason per problem |
| `identity` | The caller's account ID and ARN |
| `request` | Region, markets, amounts, unit, the instance types asked for (`null` in attribute mode), the AZ IDs sent, and the number of API requests sent |
| `state` | Capacity Manager state: `enabled`, `status`, `error`, `needs_enable`, and the status fields read from the API |
| `log` | Notes about enabling, as English and Japanese pairs |
| `preflight` | AZ IDs and types sent, AZ IDs EC2 does not know, types offered nowhere, pairs EC2 says are not offered, and notes about checks that could not run |
| `results` | Per market and amount: `cells` (`[type, az, score]`), `groups` (one per planned request; repeats after a rejection stay inside the same group: types and AZs finally sent, aggregate score, error, values dropped after the API rejected them, and what was asked before any drop), `retries`, `sent` |

The file contains the scores, so it is EC2 Capacity Manager Data in the same way as the page: see [Sharing the output](#sharing-the-output).

## When something goes wrong

The script is built so that one bad input does not turn the whole report into errors. The right-hand column of the table is what the report and the exit status do; the observed API behaviour in the second table was seen on 2026-11-05 in one account. The last column of that table says what the documentation does say about it; see [Observed behaviour against the documentation](#observed-behaviour-against-the-documentation).

| # | Situation | What happens | Exit |
|---|---|---|---|
| 1 | Credentials missing (`NoCredentialsError`), profile not found (`ProfileNotFound`), or the endpoint cannot be reached (`EndpointConnectionError`); all three were run for real | Message on stderr, no report, nothing changed | 1 |
| 2 | The caller is not in the `--expect-account` account | Message on stderr, nothing changed | 1 |
| 3 | The plan needs more calls than `--max-calls` | Message on stderr before anything is sent | 6 |
| 4 | The output file cannot be created | Message on stderr, nothing changed in the account | 4 |
| 5 | `--region` is not the Region where Capacity Manager is enabled | The report explains it; `--enable` is never attempted | 3 |
| 6 | Capacity Manager is disabled and `--enable` is not given | The report tells you to re-run with `--enable` and `--expect-account`; no scores are requested | 3 |
| 7 | The state cannot be read, or enabling cannot be confirmed | The report shows the status as `unknown` with the error | 3 |
| 8 | An AZ ID that EC2 does not know, or an instance type that is offered in none of the requested AZs | Found before sending with two free EC2 calls (`DescribeAvailabilityZones`, `DescribeInstanceTypeOfferings`); the value is left out, listed under Checks before sending, and the rest is sent. If nothing is left, no Capacity Manager request is made | 3 |
| 9 | The preflight calls fail (for example no permission; the check needs `ec2:DescribeAvailabilityZones` and `ec2:DescribeInstanceTypeOfferings`) | The run goes on without the check and says so, with the error | not changed |
| 10 | The API rejects a value by name (an AZ ID or type the preflight could not judge). Only messages of the observed kind are recognised, those containing `Availability Zone ID 'X'` or `instance type 'X'` with a value that is in the request, as in "The Availability Zone ID 'X' isn't valid" and "The instance type 'X' isn't available ..." | The request is repeated without that value, at most 3 times per request and only while the `--max-calls` budget allows (the budget is what is left of the cap after the planned calls). An AZ ID that is rejected is remembered for the rest of the run; an instance type that is rejected is remembered only for requests with the same AZ set, because the message says the type is not available in "the specified Availability Zones" and not that it is invalid. A rejection is remembered even when no budget is left to repeat. Later requests do not pay for it again; its pairs show as Error and it is listed in the report | 3 |
| 11 | A request fails for another reason (permissions, throttling, an amount that is too large) | Only the pairs of that request show Error; other requests, amounts and markets still run; the error text is listed per request | 3 |
| 12 | A response has no scores, no valid aggregate, or malformed rows | Treated as an error for that request; malformed rows are left out and counted | 3 |
| 13 | Anything unexpected inside the run | Message on stderr, no report left behind, the path at `--out` untouched | 5 |
| 13a | Ctrl-C, SIGTERM or SIGHUP (a signal that the parent process set to ignore, such as SIGHUP under `nohup`, stays ignored) | Handled alike: message on stderr (requests already sent still count against the quota; an `--enable` that already ran stays in place), temporary file removed, the path untouched. SIGKILL cannot be handled and leaves at most the hidden temporary file, which does not block the next run | 130 |
| 14 | Every request fails | The report is still written (as a `.failed-` file) with a banner at the top, Error in every cell and the errors listed | 3 |
| 15 | Any run that reaches the report stage and does not end with `0` (earlier exits 1, 2, 4 and 6 print their own message instead) | The console ends with `RESULT: INCOMPLETE (exit status N)` and one line per reason on stderr; a complete run prints `RESULT: complete` | as above |
| 15a | `--from-json` with a missing file, invalid JSON, a different schema, or a value of the wrong type (unknown market, an amount below 1, a score other than High/Medium/Low, results that do not match the requested markets and amounts) | Message on stderr, no page written | 2 |
| 16 | Empty, blank or differently-cased `--types`/`--azs`, wrong JSON types in `--requirements`, an empty `--out` | Values are trimmed and lower-cased and then de-duplicated; empty values and wrong types are refused at the entry, before any call | 2 |

Observed API behaviour is listed with its documentation status in [Observed behaviour against the documentation](#observed-behaviour-against-the-documentation).

## What the documentation guarantees

Source: [Check supportability](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-supportability.html) and its sub-pages, read on 2026-11-05.

The report restates rows 1 to 9 and the plan and results part of row 10; the no-organization-setup part of row 10 is not shown in the report. Row 11 is in the footer.

| # | Statement | Where the documentation says it |
|---|---|---|
| 1 | A score is the ratio of the capacity a combination holds now to the amount requested. It is a point-in-time value and no score, High included, guarantees a launch | [What the scores mean](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-score-meaning.html) |
| 2 | High: several times the request. Medium: covers the request with little to spare, workable rather than safe. Low: less than requested, though some capacity is likely still available | same page |
| 3 | The same combination can score differently for different amounts | same page |
| 4 | Low per-combination scores with a High aggregate is intended | same page |
| 5 | For critical workloads use Capacity Reservations or Future-dated Capacity Reservations regardless of score | same page |
| 6 | After an `InsufficientCapacityError`, run the same type, AZ and amount: High means the combination needs to resize hosts, so launch what you can and retry the rest every few minutes; Medium or Low means limited capacity, so launch in another combination that scored High or add more instance types | [What to do based on your score](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-score-actions.html) |
| 7 | Spot scores are built on Spot placement score, which scores flexibility as a whole; the Spot aggregate gives equivalent guidance, and if you already use Spot placement score directly you read the aggregate as your Spot signal; how to read per-combination Spot values is not stated | [Relationship to Spot placement score](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-sps.html) |
| 8 | Call the API in the Region where Capacity Manager is enabled; one call can check AZs in any Region; run checks when you plan or review a workload, not on every launch | [How to check capacity](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-check-capacity.html) |
| 9 | 100 queries per account per hour; up to 100 instance type x AZ combinations per request. The separate limits of 10 AZs and 50 instance types per request are in the [AWS CLI reference](https://docs.aws.amazon.com/cli/latest/reference/ec2/get-capacity-manager-supportability-scores.html) | [Quotas](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-check-quotas.html) |
| 10 | Available only to AWS Support customers on the Unified Operations plan; account-level Capacity Manager is enough, no organization setup | top page of the section |
| 11 | Results cannot be shared with third parties; AWS Service Terms 5.9 allows use solely for internal capacity planning and workload management and forbids disclosure to third parties other than contractors or agents acting on your behalf | top page of the section and the [AWS Service Terms](https://aws.amazon.com/service-terms/) |

## What the documentation does not say

These are left out of the report on purpose.

| # | Question | Status |
|---|---|---|
| 1 | Would two accounts asking the same question at the same moment see the same score | Not stated. The report says only that the result is the calling account's answer |
| 2 | Do On-Demand scores follow the Spot placement score | Not stated. The documentation ties only the Spot scores to Spot placement score |
| 3 | How the High / Medium / Low thresholds are drawn beyond "several times" and "little to spare" | Not stated |
| 4 | The error returned for an account not on the Unified Operations plan | Not stated. The report prints the raw API error |
| 5 | Whether `VirtualizationTypes` is required with `--requirements` | The references mark it optional, but the API answered `MissingParameter: virtualizationTypes is required` when it was left out on 2026-11-05. Pass `"VirtualizationTypes":["hvm"]` in the JSON |
| 6 | The IAM action for `GetCapacityManagerSupportabilityScores` | Not published: the AWS Service Reference lists the operation without an IAM action |

## Observed behaviour against the documentation

Everything the tool relies on that was found by running it was looked up again in the AWS documentation on 2026-11-05 (the Capacity Manager pages of the EC2 User Guide, the EC2 API reference including [Common Error Types](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/CommonErrors.html) and [Error codes](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/errors-overview.html), the AWS CLI and boto3 references, and the AWS Service Reference). One account, 2026-11-05.

| # | Observed | What the documentation says | Status |
|---|---|---|---|
| 1 | `get-capacity-manager-attributes` in a Region that never enabled Capacity Manager fails with `CapacityManager.Disabled` | The API reference defines `capacityManagerStatus` as `enabled \| disabled`. The error code appears in no page | Error code not documented; the status values are documented, and the tool handles both |
| 2 | The same call in another Region, while Capacity Manager is enabled elsewhere, fails with `CapacityManager.IncorrectRegion` and the message names that Region | "You can only enable Capacity Manager in one AWS Region per account" ([EC2 Capacity Manager](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager.html)) | The rule is documented; the error code and its message are not |
| 3 | An unknown instance type or an invalid AZ ID fails the whole request with `InvalidParameterValue`, and the message names the value | `InvalidParameterValue` is a documented error. The EC2 error-code page says the returned message explains why the value is not valid | The error and the explanatory message are documented in general; that one bad value fails the whole request, and the wording of the message, are not |
| 4 | `--capacity-amount` above 100000 with `instances` fails | The CLI reference gives only `min: 1` for the amount | Upper limit not documented |
| 5 | Attribute-based selection fails with `MissingParameter` when `VirtualizationTypes` is left out | The CLI and boto3 references do not mark `VirtualizationTypes` as required; they do mark `VCpuCount` and `MemoryMiB` as required. `MissingParameter` is a documented error | Contradicts the reference: the field is optional there and required in practice |
| 6 | Requested pairs can be missing from a successful response | "A request with 10 types across 3 Availability Zones returns 30 combination scores" ([How to check capacity](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-check-capacity.html)) | Differs from the documented example; no explanation is given |
| 7 | Enabling reports `initial-ingestion-in-progress` first | The account-level page: 14 days of history are collected, it can take a few hours, and `initial-ingestion-in-progress` then `ingestion-complete` are shown. The API reference lists `initial-ingestion-in-progress`, `ingestion-complete` and `ingestion-failed` | Documented. Whether supportability checks work during ingestion is not |
| 8 | No credentials: `NoCredentialsError`; unknown profile: `ProfileNotFound`; bad Region: `EndpointConnectionError` | Not Capacity Manager behaviour; these are boto3 exceptions | Not applicable |
| 9 | Throttling is retried by the SDK | "The AWS SDKs automatically retry requests that receive this exception" (`ThrottlingException`, Common Error Types) | Documented. Whether retries count against the 100 queries per hour is not |
| 10 | The preflight uses `DescribeInstanceTypeOfferings` with `availability-zone-id` and `DescribeAvailabilityZones` with the `zone-id` filter and `AllAvailabilityZones` | Both are documented. The offerings call needs an AZ ID of the current Region, which is why the tool calls it in the AZ's own Region; `zone-id` also covers Local Zone IDs such as `usw2-lax1-az1` | Documented |
| 11 | A permission for `GetCapacityManagerSupportabilityScores` | The AWS Service Reference lists the operation without any IAM action | No IAM action is published as of 2026-11-05 |
| 12 | The operation has no API reference page | `GetCapacityManagerSupportabilityScores` is not in the EC2 API reference table of contents; it is documented in the User Guide, the AWS CLI reference and the boto3 reference | Reference page missing |
| 13 | The code name for a capacity failure | The EC2 error-code page lists `InsufficientInstanceCapacity`; the score-actions page says `InsufficientCapacityError` | Two names in the documentation |

## Notes on the design

- The aggregate score belongs to one request. When the combinations exceed one request (10 AZs, 50 instance types or 100 combinations), the script splits the run and the report lists one aggregate per request instead of claiming a single aggregate for the whole set.
- A combination that is absent from the response is shown as `N/A`, not as Low.
- AZs are given as AZ IDs because AZ names can map to different physical zones in different accounts.
- Enabling Capacity Manager is opt-in (`--enable`) because it changes the account and can be done in one Region per account.
- The style reproduces Cloudscape visual-refresh token values in plain CSS (tokens named in comments), so there is no npm dependency.

## Tests

```bash
cd investigations/2026-11-05-ec2-capacity-supportability-report
uv run --quiet --with boto3 python -I -m unittest discover -s tests -v
```

The tests use a fake client and need no AWS access, network or credentials. They check that every request respects the documented limits and drops no combination, that an error stays on its request and makes the exit status non-zero, that the report is still written, that `--enable` needs `--expect-account` and the matching account, that the call cap holds at the limit, the entry checks on `--amounts`, `--requirements`, `--region`, `--types` and `--max-calls`, the output file behaviour (exclusive creation, owner-only mode, symbolic links, `--overwrite` keeping the old report on failure and on status `3`, no half-written file), response validation, that every English text span has a Japanese span with Japanese characters (product names, AZ IDs and the breadcrumb are not translated), the static `--lang` attribute and the shape of the language script, that the Service Terms notice carries the restrictions, and that failed requests show as Error and partial rows are marked. The language switch itself (clicks, saved choice) is not exercised by an automated browser test. Most of these were also checked by changing the code under test and seeing a test fail.

## Sharing the output

The scores are EC2 Capacity Manager Data. Do not publish the HTML file, the JSON data file, screenshots of them or their numbers. This directory contains no measured scores for that reason.
