# ec2-supportability

`ec2-supportability` asks EC2 Capacity Manager how well each instance type and Availability Zone pair can support an amount you name right now, and prints the High / Medium / Low answer in a form that both people and programs can use: a table, JSON, tab-separated text, or `export` lines for a shell. It wraps the `get-capacity-manager-supportability-scores` API ([Check supportability](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-supportability.html)) so that one command checks every market and amount you list, checks the AZ IDs and instance types before spending a query on them, splits large lists to fit the per-request limits, and tells a missing score apart from a Low one. The same result can also be written as a bilingual (English / Japanese) HTML report.

The tool only reads. It does not launch, reserve or modify capacity, and it changes the account only when `--enable` is given (see [Options](#options)). What the scores mean, and what they do not promise, is listed in [What the documentation guarantees](#what-the-documentation-guarantees).

## Install

The package needs Python 3.10 or later and installs `boto3` and `jmespath`. To install it from this repository without cloning:

```bash
export REF="main"
python3 -m pip install "ec2-supportability @ https://github.com/littlemex/distributed-ai/archive/refs/heads/${REF}.zip#subdirectory=investigations/2026-11-05-ec2-capacity-supportability-report"
ec2-supportability --version
```

`REF` is the branch to install from. From a clone, `python3 -m pip install ./investigations/2026-11-05-ec2-capacity-supportability-report` does the same, and `python3 -m ec2_supportability` runs the command without the script on `PATH`.

## Requirements

Capacity Manager must be enabled in one Region of the account, and the account must be on the AWS Support Unified Operations plan. The caller needs `sts:GetCallerIdentity`, `ec2:GetCapacityManagerAttributes`, `ec2:DescribeAvailabilityZones` and `ec2:DescribeInstanceTypeOfferings` (the last two only for the check before sending), `ec2:EnableCapacityManager` for `--enable`, and whatever permission `GetCapacityManagerSupportabilityScores` needs. The AWS Service Reference for EC2 (JSON, modified 2026-10-29) lists that operation without an IAM action, so its permission is not published as of 2026-11-05; the runs here used an administrator role. Credentials come from the usual AWS chain (environment variables, a profile, or the role of the instance, task or Pod).

## Quick start

```bash
export CM_REGION="ap-northeast-1"
ec2-supportability --region "$CM_REGION" --markets on-demand --amounts 50 --azs use1-az1 --types c6g.xlarge c7g.xlarge m6g.xlarge
```

`CM_REGION` is the Region where Capacity Manager is enabled in your account; the API is always called there, and the AZs you check may be in any Region. The output below, and every sample in this README, uses the values of the example response in [How to check capacity](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-check-capacity.html), not a measurement:

```text
Check supportability  ap-northeast-1  2026-11-06 18:00 JST  result: complete

On-Demand, 50 instances   aggregate: High
  INSTANCE TYPE  use1-az1
  c6g.xlarge     High
  c7g.xlarge     High
  m6g.xlarge     Medium
```

Standard output carries only the result. Progress, warnings and the reasons a run was not complete go to standard error, so a pipe or `$(...)` never sees them, and the exit status tells a complete run (`0`) from an incomplete one (`3`) and from the other failures listed in [Exit status](#exit-status). Nothing is written to disk unless `--html` or `--save-json` asks for it.

## Output formats

`--output` chooses the format of standard output. Every format is made from the same data document, the one `--output json` prints.

| `--output` | For | Shape |
|---|---|---|
| `table` (default) | People | One block per market and amount: instance types as rows, AZ IDs as columns, the aggregate score in the block's heading. A legend explains each label other than High, Medium and Low that appears. On a terminal the three scores are coloured, unless `NO_COLOR` is set; the word is always there, so the colour is never the only signal |
| `json` | Programs, `jq`, storage | The whole data document (see [The data document](#the-data-document)), with every character outside ASCII escaped so it prints the same through any terminal or pipe encoding |
| `text` | `awk`, `cut`, `grep` | Tab-separated, no header, one record per line. The first field names the record and fixes the fields that follow (below) |
| `env` | `eval` in a shell | `export NAME=value` lines, each value quoted for the shell (below) |

`--output text` prints three kinds of records. A score that is not there is `n/a`, and the last field of a `SCORE` record says why.

| Record | Fields after the first |
|---|---|
| `RESULT` | `complete` or `incomplete`, the run's exit status, Region, unit |
| `AGGREGATE` | market, amount, request number, number of requests for this market and amount, aggregate score |
| `SCORE` | market, amount, instance type, AZ ID, score, state (`scored`, `unknown_az`, `not_sent`, `not_offered`, `failed` or `missing`; see [The data document](#the-data-document)) |

```text
RESULT	complete	0	ap-northeast-1	instances
AGGREGATE	on-demand	50	1	1	high
SCORE	on-demand	50	c6g.xlarge	use1-az1	high	scored
SCORE	on-demand	50	c7g.xlarge	use1-az1	high	scored
SCORE	on-demand	50	m6g.xlarge	use1-az1	medium	scored
```

`--output env` prints the result, the Region and the unit, and for each market and amount the aggregate score and the pairs that scored High, Medium and Low, as space-separated `type:az` words. Names are `<prefix><WHAT>_<MARKET>_<AMOUNT>` with the prefix from `--env-prefix` (default `CS_`). Every name for the markets and amounts of a run is printed, empty when there is nothing to put in it, so evaluating a second run with the same markets and amounts in the same shell replaces every value of the first. When a market and amount needed more than one request, each request has its own aggregate score and there is no single one: `CS_AGGREGATE_ON_DEMAND_50` is then empty, and `CS_AGGREGATE_ON_DEMAND_50_1`, `CS_AGGREGATE_ON_DEMAND_50_2` and so on hold the parts. A failed request gives an empty aggregate too. Names of other markets and amounts, and the numbered names, which only split runs print, are not touched, so evaluate each run in its own shell or subshell when the request can change between runs.

```text
export CS_RESULT=complete
export CS_REGION=ap-northeast-1
export CS_UNIT=instances
export CS_AGGREGATE_ON_DEMAND_50=high
export CS_HIGH_ON_DEMAND_50='c6g.xlarge:use1-az1 c7g.xlarge:use1-az1'
export CS_MEDIUM_ON_DEMAND_50=m6g.xlarge:use1-az1
export CS_LOW_ON_DEMAND_50=''
```

## Filtering with --query

`--query` takes a [JMESPath](https://jmespath.org/) expression, the language of the AWS CLI's `--query`, and runs it on the data document; the chosen `--output` then prints the expression's result. The syntax of the expression is checked before any AWS call, so a typo costs no query. An expression that is well formed but fails on the data, such as a function given a value of the wrong type, is reported with exit status `2` after the run; with `--save-json` the data is kept and `--from-json` can print it again.

```bash
ec2-supportability --region "$CM_REGION" --markets on-demand --amounts 50 --azs use1-az1 --types c6g.xlarge c7g.xlarge m6g.xlarge --output text --query "scores[?score=='high'].[instance_type,az_id]"
```

```text
c6g.xlarge	use1-az1
c7g.xlarge	use1-az1
```

`--output text` prints a list of lists or of objects as one tab-separated line per item, a list of plain values as one line, and a single value as one word, so `--query "aggregates[0].score"` prints only `high`. A backslash, tab or line break inside a value is written as `\\`, `\t`, `\n` or `\r`, so a value never splits a record. `--output table` gives a list of objects a header made of its keys. `--output env` needs the expression to return an object, such as `"{best_az: scores[?score=='high'].az_id | [0]}"`; each key becomes a variable name after the prefix, a list becomes one space-separated value, and an empty result becomes an empty value. Values are given to the shell as they are, without the escaping of `--output text`. Any other shape, a nested value, two keys that become the same name, or a name that changes how a shell or program runs (`PATH`, `IFS`, `HOME`, `BASH_ENV`, `LD_*`, `DYLD_*`, `PYTHON*` and the like, which a prefix plus a key can spell) stops the command with exit status `2` and a message on standard error.

In JMESPath a missing value is `null`, and `null != 'low'` is true. To get the pairs that are not Low, list the scores you want, `scores[?score=='high' || score=='medium']`, rather than writing `score!='low'`, which also returns the pairs that have no score.

## Using it in scripts, containers and batch jobs

A batch job that goes on only when the aggregate score is High:

```bash
set -euo pipefail
export EC2_SUPPORTABILITY_REGION="ap-northeast-1"
if ! out="$(ec2-supportability --markets on-demand --amounts 50 --azs use1-az1 use1-az2 --types c6g.xlarge c7g.xlarge m6g.xlarge --output env)"; then
  echo "the supportability check did not complete" >&2
  exit 1
fi
eval "$out"
if [ "$CS_AGGREGATE_ON_DEMAND_50" = high ]; then
  echo "proceed"
else
  echo "add instance types or wait"
fi
```

The command runs inside the `if` so that its exit status is checked; `export X="$(...)"` would hide a failure behind the success of `export`. A run that was split into several requests leaves `CS_AGGREGATE_ON_DEMAND_50` empty, so the job then takes the `else` branch instead of reading one request's aggregate as the whole.

A container image:

```dockerfile
FROM python:3.12-slim
ARG REF=main
RUN python3 -m pip install --no-cache-dir "ec2-supportability @ https://github.com/littlemex/distributed-ai/archive/refs/heads/${REF}.zip#subdirectory=investigations/2026-11-05-ec2-capacity-supportability-report"
USER nobody
ENTRYPOINT ["ec2-supportability"]
```

```bash
docker build -t ec2-supportability .
docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_SESSION_TOKEN -e EC2_SUPPORTABILITY_REGION="ap-northeast-1" ec2-supportability --markets on-demand --amounts 50 --azs use1-az1 --types c6g.xlarge c7g.xlarge m6g.xlarge --output json
```

On ECS, EKS or EC2 the task, Pod or instance role supplies the credentials and the `-e AWS_...` options are not needed.

Most options can also be set as environment variables named `EC2_SUPPORTABILITY_` followed by the option name in capitals with `-` replaced by `_`, such as `EC2_SUPPORTABILITY_REGION` or `EC2_SUPPORTABILITY_TYPES="c6g.xlarge c7g.xlarge"`. A list may be separated by spaces or commas; a value is trimmed, and an empty variable counts as unset. A variable is used only when its option is not on the command line, and `--types` and `--requirements` count as one option, so `--requirements` on the command line also silences `EC2_SUPPORTABILITY_TYPES`. A variable only ever gives the value of its own option: a list item that starts with `-` is refused, so no variable can add an option such as `--enable`. A value of the wrong form for its option (a word that is not one of its choices, or not a number) stops the command with status `2` and a message that names the variable; the checks that follow, such as the account ID's 12 digits or the JSON of `--requirements`, name the option. `--help` and `--version` ignore the variables. Some options have no variable on purpose. `--enable` and `--overwrite` change the account or replace a file, so they are asked for on the command line every time rather than inherited from an environment. `--query` and `--env-prefix` decide what a script that evaluates the output receives, so they are not inherited either. `--html`, `--save-json`, `--from-json` and `--open` name files and actions of one run. `AWS_REGION` and `AWS_DEFAULT_REGION` are not read for `--region`, because Capacity Manager can be enabled in only one Region per account and that Region should not come from whatever the shell happens to have.

The hourly quota is 100 queries per account, shared by everyone who uses the account, and the documentation recommends checking when a workload is planned or reviewed, not on every launch. A job that runs every few minutes would use the quota up; `--max-calls` caps what one run may plan.

## Options

| Option | Variable | Meaning | Default |
|---|---|---|---|
| `--region` | yes | Region where Capacity Manager is enabled; the API is called here. Required unless `--from-json` is used, because a wrong default would send `--enable` to the wrong Region | none |
| `--profile` | yes | AWS profile name | the usual credential chain |
| `--types` | yes | Instance types to score (up to 50 per request; larger lists are split). Lower-case letters, digits, `.` and `-` only, as in every instance type name. Cannot be combined with `--requirements`. The default list is a mixed GPU, Trainium and general-purpose sample whose aggregate says little about a real workload; pass your own list | a sample of 7 |
| `--requirements` | yes | JSON for `InstanceRequirementsWithMetadata` (attribute-based selection) instead of `--types`. The API requires `VirtualizationTypes` in it | none |
| `--azs` | yes | AZ IDs such as `apne1-az4`, from any Regions (up to 10 per request; larger lists are split) | 10 AZs in 4 Regions |
| `--markets` | yes | `on-demand`, `spot` | both |
| `--amounts` | yes | Requested amounts, positive integers; repeated values run once and the list is sorted. Every score is relative to the amount | `1 10 100` |
| `--unit` | yes | `instances` or `vcpus` | `instances` |
| `--enable` | no | Enable Capacity Manager in `--region` if it is disabled. Without it the account is never changed. Requires `--expect-account` | off |
| `--expect-account` | yes | A 12-digit account ID; the command stops before anything is sent unless the caller is in it | none |
| `--max-calls` | yes | Refuse to start when one run plans more than this many API calls | 95 |
| `--output` | yes | `table`, `json`, `text` or `env` | `table` |
| `--query` | no | JMESPath expression on the data document | none |
| `--env-prefix` | no | Prefix of the names `--output env` prints; letters, digits and `_`, not starting with a digit, and not empty | `CS_` |
| `--html FILE` | no | Also write the HTML report to `FILE` | not written |
| `--save-json FILE` | no | Also write the data document to `FILE` | not written |
| `--overwrite` | no | Replace an existing `--html` or `--save-json` file when the run ends with status `0` | off |
| `--lang` | yes | Language the HTML report opens in; when omitted, the language the browser saved, else English | saved choice |
| `--open` | no | Open the `--html` report in the browser after printing; requires `--html`. Anything the browser prints goes to standard error | off |
| `--from-json FILE` | no | Do not call AWS: print, and with `--html` or `--save-json` write, a data document saved earlier. No credentials and no `--region` are needed | none |
| `--version` | no | Print the version | |

Options must be spelled out in full; an abbreviation such as `--out` is refused rather than guessed.

## Exit status

| Code | Meaning | Standard output |
|---|---|---|
| `0` | Capacity Manager was usable, nothing asked for was left out, and every request returned scores | The result |
| `1` | Authentication failed, or the caller is not in the `--expect-account` account | Nothing |
| `2` | A usage error: a bad option or environment variable, an invalid `--query`, an `--env-prefix` that cannot start a name, a `--query` that fails on the data or whose result `--output env` cannot print, or a data file `--from-json` cannot use | Nothing |
| `3` | The run was not complete: Capacity Manager was not usable, a value was left out before sending, or a request failed or returned no usable scores | The result as far as it goes, with `result` set to `incomplete` |
| `4` | An `--html` or `--save-json` file could not be created (checked before anything is sent), written or placed | The result, when the run itself finished |
| `5` | An unexpected error | Nothing |
| `6` | The plan needs more calls than `--max-calls` | Nothing |
| `130` | Interrupted by Ctrl-C, SIGTERM or SIGHUP | Nothing |

When a run was not complete and printing failed as well, the status stays `3` (or `4`) rather than becoming `2`, so a script always learns the run was not complete. `--from-json` exits with the status of the run that produced the data (`0` or `3`), so replaying an incomplete run never looks complete; `2` and `4` keep their meanings. With `set -e`, status `3` stops a script; a script that wants to use a partial result can run the command inside `if` and read `CS_RESULT` or the `result` field. A requested pair that is missing from a successful response does not change the exit status; its state is `missing`. A reader that stops early, as `| head -1` does, does not change the exit status either.

## Files

`--html` and `--save-json` each write one file, and either can be given alone. Both paths are checked before anything is sent: an existing file or symbolic link is refused unless `--overwrite` is given, a directory is always refused, and the two must be different files, which is checked after resolving `..` and symbolic links; names that differ only in letter case count as the same file, because macOS and Windows volumes usually ignore case. Each file is written to a hidden temporary file (owner-only, mode 0600 on POSIX systems) next to its path and moved into place at the end. A path only ever receives the output of a run that ended with status `0`; any other run saves its file beside it as `<name>.failed-<date>-<time>-<microseconds><suffix>` and says so on standard error, so a failed run never replaces a good file. A file that could not be placed at its path is saved as `<name>.unplaced-<...>`. A side name never replaces a file that is already there; when two outputs shorten to the same side name, the second gets `-2` added. A file that cannot be written (a full disk) leaves nothing at either path, exits `4`, and the result is still printed. When both are given, the data file is placed first, and if it cannot be placed the page is saved as `.unplaced-` too, so the two stay together. File systems without hard links are handled by creating the path exclusively and copying into it. A missing parent directory is created.

`--from-json` reads a saved data document, recomputes the derived lists, and prints it in any format without calling AWS. With `--html` it rebuilds the page; a document from an incomplete run gives a page saved as `.failed-`, and the exit status is `3`, the status of that run. A file that does not match the schema, has a value of the wrong type, repeats a market or an amount, has an instance type or AZ ID that is not a name, has a status other than the integer `0` or `3`, or cannot be read is refused with status `2`, and the output path may not be the file being read.

## The data document

The document is what `--output json` prints and `--save-json` writes, and every other output is made from it alone: the command serialises it, parses that text back, and prints and renders only what was parsed, so a saved file reproduces exactly what the run showed. The `status` inside is the status of the run; `4` (a file could not be placed) appears only as the exit status. Schema `ec2-capacity-supportability-report/2` has these top-level keys:

| Key | Content |
|---|---|
| `schema`, `generated_by`, `generated_at_jst` | Format name and version, the tool, and the run time in JST |
| `result` | `complete` when `status` is `0`, else `incomplete` |
| `status`, `reasons` | The exit status of the run and one plain-text reason per problem |
| `identity` | The caller's account ID and ARN |
| `request` | Region, markets, amounts, unit, the instance types asked for (`types`, `null` in attribute mode), the attribute-based requirements (`requirements`, `null` with `--types`), the AZ IDs sent (`azs`), every AZ ID asked for including the ones EC2 did not know (`requested_azs`), and the number of API requests sent |
| `state` | Capacity Manager state: `enabled`, `status`, `error`, `needs_enable`, and the status fields read from the API |
| `log` | Notes about enabling, as English and Japanese pairs |
| `preflight` | AZ IDs and types sent, AZ IDs EC2 does not know, types offered nowhere, pairs EC2 says are not offered, and notes about checks that could not run |
| `results` | Per market and amount: `cells` (`[type, az, score]`), `groups` (one per planned request: the types and AZs finally sent, aggregate score, error, values dropped after the API rejected them, and what was asked before any drop), `retries`, `sent` |
| `scores` | One object per market, amount, instance type and AZ: `market`, `amount`, `instance_type`, `az_id`, `score` (`high`, `medium`, `low` or `null`) and `state` |
| `aggregates` | One object per request: `market`, `amount`, `request`, `requests`, `score` (`null` when the request failed), `error`, `instance_types`, `az_ids` |

`state` in `scores` says why a pair has the score it has; the first that applies is used. `scored`: the response had a score. `unknown_az`: EC2 does not know the AZ ID, so it was not sent. `not_sent`: no request was sent for that market and amount, for example because Capacity Manager was not usable. `not_offered`: the check before sending found that EC2 does not offer the type in that AZ. `failed`: the pair's request failed, or the API rejected one of its values and the pair was left out. `missing`: the request succeeded but the response had no row for the pair. With `--types` every requested pair has a row, unknown AZ IDs included. With `--requirements` the types are not known before the response, so only scored pairs have rows.

`result`, `scores` and `aggregates` are derived from the other keys, and reading a document always recomputes them, so an edited list cannot disagree with the facts it came from. The `status` read from a file is raised to `3` when its facts show a failed request, and its `reasons` are then rebuilt from the same facts, so an edited `0` cannot claim a complete run. Schema `/1`, the same document without the three derived keys, is still read.

## When something goes wrong

One bad input does not turn the whole result into errors. The observed API behaviour in this table was seen on 2026-11-05 in one account; [Observed behaviour against the documentation](#observed-behaviour-against-the-documentation) says what the documentation says about each.

| # | Situation | What happens | Exit |
|---|---|---|---|
| 1 | Credentials missing (`NoCredentialsError`), profile not found (`ProfileNotFound`), or the endpoint cannot be reached (`EndpointConnectionError`) | Message on standard error, nothing printed, nothing changed | 1 |
| 2 | The caller is not in the `--expect-account` account | Message on standard error, nothing changed | 1 |
| 3 | The plan needs more calls than `--max-calls` | Message on standard error before anything is sent | 6 |
| 4 | An invalid `--query`, a bad `--env-prefix`, a bad environment variable, an instance type or AZ ID with characters no name has, or another bad option | Refused before any AWS call | 2 |
| 5 | An `--html` or `--save-json` file cannot be created | Message on standard error, nothing changed in the account | 4 |
| 6 | `--region` is not the Region where Capacity Manager is enabled | The reason names the problem; `--enable` is never attempted; every pair of a known AZ is `not_sent` | 3 |
| 7 | Capacity Manager is disabled and `--enable` is not given | The reason says to run again with `--enable` and `--expect-account`; no scores are requested | 3 |
| 8 | The state cannot be read, or enabling cannot be confirmed | The status is shown as `unknown` with the error | 3 |
| 9 | An AZ ID that EC2 does not know, or an instance type offered in none of the requested AZs | Found before sending with two free EC2 calls (`DescribeAvailabilityZones`, `DescribeInstanceTypeOfferings`); the value is left out and listed, and the rest is sent. If nothing is left, no Capacity Manager request is made | 3 |
| 10 | The checks before sending fail (for example no permission) | The run goes on without them and says so, with the error | not changed |
| 11 | The API rejects a value by name (an AZ ID or type the check before sending could not judge). Only messages of the observed kind are recognised: those containing `Availability Zone ID 'X'` or `instance type 'X'` with a value that is in the request | The request is repeated without that value, at most 3 times per request and only while the `--max-calls` budget allows. A rejected AZ ID is remembered for the rest of the run; a rejected type only for requests with the same AZ set, because the message says it is not available in "the specified Availability Zones". The pairs of the value are `failed` | 3 |
| 12 | A request fails for another reason (permissions, throttling, an amount that is too large) | Only the pairs of that request are `failed`; other requests, amounts and markets still run; the error is listed per request | 3 |
| 13 | A response has no scores, no valid aggregate, or malformed rows | Treated as an error for that request; malformed rows are left out and counted | 3 |
| 14 | Every request fails | The result is still printed, with every pair `failed`, and a requested file is saved as `.failed-` | 3 |
| 15 | `--query` fails on the data, or `--output env` cannot print its result | Message on standard error, nothing printed; a `--save-json` file is still written, and the message names it so that `--from-json` can print it another way without a new query | 2, or 3 or 4 when the run was not complete |
| 16 | Anything unexpected inside the run | Message on standard error, nothing printed, no file left behind | 5 |
| 17 | Ctrl-C, SIGTERM or SIGHUP (a signal the parent process set to ignore, such as SIGHUP under `nohup`, stays ignored) | Message on standard error (requests already sent still count against the quota; an `--enable` that already ran stays in place). A signal that arrives while files are being placed waits until both are placed, so the two stay together; files placed before the signal stay, and temporary files are removed. SIGKILL cannot be handled and leaves at most a hidden temporary file, which does not block the next run | 130 |
| 18 | Empty, blank or differently-cased `--types` or `--azs`, wrong JSON types in `--requirements`, an empty `--html` or `--save-json` | Values are trimmed, lower-cased and de-duplicated; empty values and wrong types are refused before any call | 2 |

A run that reaches the end prints `RESULT: complete`, or `RESULT: INCOMPLETE (exit status N)` and one line per reason, on standard error, followed by the paths of the files it wrote. A Region counts as enabled only when `CapacityManagerStatus` is read back as `enabled`.

The call cap counts what one run plans, not what the account has already used this hour, so the quota is still yours to track across runs. A run with the defaults makes 6 calls; the count does not include automatic SDK retries. In `--requirements` mode the API resolves the instance types, so the tool cannot plan for the limit of 100 combinations per request; what happens beyond it is not documented and was not tested.

## What the documentation guarantees

Source: [Check supportability](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/capacity-manager-supportability.html) and its sub-pages, read on 2026-11-05.

The HTML report restates rows 1 to 9 and the plan and results part of row 10; the no-organization-setup part of row 10 is not shown in it. Row 11 is in its footer, and row 11 is also in `ec2-supportability --help`.

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

The tool does not claim any of these.

| # | Question | Status |
|---|---|---|
| 1 | Would two accounts asking the same question at the same moment see the same score | Not stated. The output says only that the result is the calling account's answer |
| 2 | Do On-Demand scores follow the Spot placement score | Not stated. The documentation ties only the Spot scores to Spot placement score |
| 3 | How the High / Medium / Low thresholds are drawn beyond "several times" and "little to spare" | Not stated |
| 4 | The error returned for an account not on the Unified Operations plan | Not stated. The tool prints the raw API error |
| 5 | Whether `VirtualizationTypes` is required with `--requirements` | The references mark it optional, but the API answered `MissingParameter: virtualizationTypes is required` when it was left out on 2026-11-05. Pass `"VirtualizationTypes":["hvm"]` in the JSON |
| 6 | The IAM action for `GetCapacityManagerSupportabilityScores` | Not published: the AWS Service Reference lists the operation without an IAM action |

## Observed behaviour against the documentation

Everything the tool relies on that was found by running it was looked up again in the AWS documentation on 2026-11-05 (the Capacity Manager pages of the EC2 User Guide, the EC2 API reference including [Common Error Types](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/CommonErrors.html) and [Error codes](https://docs.aws.amazon.com/AWSEC2/latest/APIReference/errors-overview.html), the AWS CLI and boto3 references, and the AWS Service Reference). One account, 2026-11-05.

| # | Observed | What the documentation says | Status |
|---|---|---|---|
| 1 | `get-capacity-manager-attributes` fails with `CapacityManager.Disabled` when no Region in the account has Capacity Manager enabled | The API reference defines `capacityManagerStatus` as `enabled \| disabled`. The error code appears in no page | Error code not documented; the status values are documented, and the tool handles both |
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

- The aggregate score belongs to one request. When the pairs exceed one request (10 AZs, 50 instance types or 100 combinations), the run is split and every output keeps one aggregate per request instead of claiming one for the whole set.
- A pair that is absent from the response is `missing` (`N/A` in the table), not Low.
- AZs are given as AZ IDs because AZ names can map to different physical zones in different accounts.
- Enabling Capacity Manager is opt-in (`--enable`) because it changes the account and can be done in one Region per account.
- The HTML report reproduces Cloudscape visual-refresh token values in plain CSS (tokens named in comments), so there is no npm dependency.

## Tests

```bash
cd investigations/2026-11-05-ec2-capacity-supportability-report
uv run --quiet --with-editable . python -I -m unittest discover -b -s tests
```

The tests use a fake client and need no AWS access, network or credentials. `tests/test_output.py` covers what is printed: that a plain run writes nothing to disk, that each `text` record has a fixed number of fields, the `state` of every kind of pair, that `env` output evaluated in bash gives the expected values and runs nothing that a value contains, that a split run never sets the single aggregate name, `--query` in every format, that an invalid query and a bad prefix are refused before any AWS call, the environment variables and their precedence, that `AWS_REGION` and `EC2_SUPPORTABILITY_ENABLE` are not used, that `--from-json` prints the same text as the live run and recomputes edited derived lists, and one test for each defect found in review (an environment variable adding an option, a query failing on the data, a full disk, two spellings of one path, side names colliding, an edited status, browser messages on standard output, a reader closing the pipe early, and others); each of those was checked to fail with its fix taken out. `tests/test_cli.py` covers the run: that every request respects the documented limits and drops no pair, that an error stays on its request and makes the exit status non-zero, that `--enable` needs `--expect-account` and the matching account, the call cap, the entry checks, the file placement rules (exclusive creation, owner-only mode, symbolic links, `--overwrite` keeping the old file on failure, no half-written file), response validation, and the HTML report's bilingual text and `--lang` attribute. The language switch in the browser is not exercised by an automated test.

## Sharing the output

The scores are EC2 Capacity Manager Data under the AWS Service Terms: use them for your own capacity planning and workload management, and do not disclose them to third parties other than contractors or agents acting on your behalf. That covers standard output as much as the files. CI logs, chat channels and shared dashboards widen who can read a job's output, so keep the output of this command out of them unless everyone who can read them may see the scores. This directory contains no measured scores for that reason.
