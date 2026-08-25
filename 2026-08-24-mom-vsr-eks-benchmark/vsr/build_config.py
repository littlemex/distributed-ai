#!/usr/bin/env python3
"""Generate the Semantic Router and Envoy configs for the MoM benchmark.

Three inputs are joined so that no fact is stated twice:

    pool.yaml            which models take part, and what role each one plays
    models.json          the gateway's registry: alias -> Bedrock model id
    pricing.json         the gateway's rate table: pricing key -> per-token rate

The rate table is the gateway's own, so the router scores cost on exactly what
the request will be charged. Addresses and credentials are read from the
environment named in `pool.yaml`, never inlined here, and the generated files
are environment-specific: they are written to an output directory that is not
tracked.

    ./build_config.py --stratoclave-defaults <dir> --out-dir <dir>

Quality is the quantity the benchmark exists to measure, so it is never
invented. Without `--quality-from` the router is seeded with the operator's
price ordering and the emitted config records that it is a prior.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any

import yaml

MICRO_USD_PER_USD = 1_000_000


class ConfigError(RuntimeError):
    """A fact is missing or inconsistent; fail the build rather than guess."""


# --------------------------------------------------------------------------- #
# inputs
# --------------------------------------------------------------------------- #


def load_yaml(path: Path) -> dict[str, Any]:
    with path.open() as handle:
        return yaml.safe_load(handle)


def load_json(path: Path) -> dict[str, Any]:
    with path.open() as handle:
        return json.load(handle)


def index_registry(registry: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """Map every alias in the gateway registry to its entry."""
    by_alias: dict[str, dict[str, Any]] = {}
    for entry in registry["models"]:
        for alias in entry.get("aliases", []):
            if alias in by_alias:
                raise ConfigError(f"alias {alias!r} is duplicated in the registry")
            by_alias[alias] = entry
    return by_alias


def env(name: str, *, required: bool = True, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise ConfigError(
            f"environment variable {name} is required by pool.yaml but is unset"
        )
    return value or ""


# --------------------------------------------------------------------------- #
# pricing and quality
# --------------------------------------------------------------------------- #


def rate_for(rates: dict[str, Any], pricing_key: str) -> dict[str, float]:
    """Per-1M-token USD rates for a pricing key, from the gateway's table."""
    if pricing_key not in rates:
        raise ConfigError(
            f"pricing key {pricing_key!r} is not in the gateway rate table; "
            "the registry and the rate table disagree"
        )
    row = rates[pricing_key]
    return {
        "currency": "USD",
        "prompt_per_1m": row["input_per_mtok_microusd"] / MICRO_USD_PER_USD,
        "completion_per_1m": row["output_per_mtok_microusd"] / MICRO_USD_PER_USD,
        "cached_input_per_1m": row["cache_read_per_mtok_microusd"] / MICRO_USD_PER_USD,
    }


def price_prior_scores(
    members: list[dict[str, Any]], low: float, high: float
) -> dict[str, float]:
    """Rank members by completion rate and spread them over [low, high].

    Members priced identically score identically: the prior refuses to invent an
    ordering the rate table does not state. A calibration run replaces this.
    """
    rates = sorted({m["pricing"]["completion_per_1m"] for m in members})
    if len(rates) == 1:
        return {m["name"]: high for m in members}
    step = (high - low) / (len(rates) - 1)
    by_rate = {rate: low + index * step for index, rate in enumerate(rates)}
    return {m["name"]: by_rate[m["pricing"]["completion_per_1m"]] for m in members}


def measured_scores(path: Path, names: set[str]) -> dict[str, float]:
    """Per-member accuracy from a calibration summary, as the quality score."""
    summary = load_json(path)
    scores = {}
    for name, value in summary.get("accuracy_by_model", {}).items():
        if name not in names:
            raise ConfigError(
                f"calibration summary scores {name!r}, which is not in the pool"
            )
        scores[name] = float(value)
    missing = names - scores.keys()
    if missing:
        raise ConfigError(
            "calibration summary is incomplete; no accuracy for "
            + ", ".join(sorted(missing))
        )
    return scores


# --------------------------------------------------------------------------- #
# member resolution
# --------------------------------------------------------------------------- #


def resolve_members(
    pool: dict[str, Any],
    by_alias: dict[str, dict[str, Any]],
    rates: dict[str, Any],
    *,
    addresses: bool = True,
) -> list[dict[str, Any]]:
    """Join the pool with the gateway's registry and rate table.

    `addresses=False` resolves everything except where a member lives. The
    benchmark harness needs the roster and the rates — it must charge what the
    router charged — but it reaches every member through the router, so the
    upstream addresses are none of its business and demanding their environment
    variables would only invite a caller to invent them.
    """
    transports = pool["transports"]
    resolved: list[dict[str, Any]] = []
    unverified: list[str] = []

    for member in pool["members"]:
        alias = member["alias"]
        transport_name = member["transport"]
        transport = transports[transport_name]
        name = transport["name_prefix"] + alias

        if transport_name == "gateway":
            entry = by_alias.get(alias)
            if entry is None:
                raise ConfigError(
                    f"{alias!r} is not an alias in the gateway registry; the pool "
                    "asks for a model the gateway cannot serve"
                )
            pricing_key = entry["pricing_key"]
            upstream_model_id = alias
            endpoint = (
                f"{env(transport['host_env'])}:"
                f"{env(transport['port_env'], required=False, default='443')}"
                if addresses
                else None
            )
            backend_type = "openai"
            # api_key_env alone keeps this a plain endpoint: the router
            # injects the bearer token and Envoy dials address:port. Adding a
            # profile field (chat_path, provider, auth_header) would switch the
            # endpoint to profile mode and demand a base_url instead.
            extra_backend = {"api_key_env": transport["api_key_env"]}
            wire = entry["wire_protocol"]
            region = entry["bedrock_region"]
        else:
            pricing_key = member["pricing_key"]
            upstream_model_id = member["upstream_model_id"]
            endpoint = env(member["endpoint_env"]) if addresses else None
            backend_type = "vllm"
            extra_backend = {}
            wire = "openai"
            region = "in-cluster"

        facts = member["facts"]
        if facts.get("source") == "unverified":
            unverified.append(name)

        resolved.append(
            {
                "name": name,
                "alias": alias,
                "transport": transport_name,
                "upstream_model_id": upstream_model_id,
                "backend_type": backend_type,
                "endpoint": endpoint,
                "protocol": transport["protocol"],
                "extra_backend": extra_backend,
                "pricing_key": pricing_key,
                "pricing": rate_for(rates, pricing_key),
                "roles": member["roles"],
                "facts": facts,
                "wire_protocol": wire,
                "region": region,
            }
        )

    if unverified:
        print(
            "[WARNING] context window and capabilities are unverified for: "
            + ", ".join(unverified),
            file=sys.stderr,
        )
    return resolved


# --------------------------------------------------------------------------- #
# emitted config
# --------------------------------------------------------------------------- #


def provider_models(members: list[dict[str, Any]]) -> list[dict[str, Any]]:
    models = []
    for member in members:
        backend_ref = {
            "name": f"{member['alias']}-primary",
            "endpoint": member["endpoint"],
            "protocol": member["protocol"],
            "type": member["backend_type"],
            "weight": 1,
            **member["extra_backend"],
        }
        models.append(
            {
                "name": member["name"],
                "provider_model_id": member["upstream_model_id"],
                "api_format": "openai",
                "pricing": member["pricing"],
                "backend_refs": [backend_ref],
                # What actually goes on the wire to the backend.
                "external_model_ids": {
                    member["backend_type"]: member["upstream_model_id"]
                },
            }
        )
    return models


def model_cards(
    members: list[dict[str, Any]], quality: dict[str, float], quality_source: str
) -> list[dict[str, Any]]:
    cards = []
    for member in members:
        facts = member["facts"]
        tags = [f"transport:{member['transport']}", f"pricing-key:{member['pricing_key']}"]
        tags += [f"role:{role}" for role in member["roles"]]
        tags.append(f"quality-source:{quality_source}")
        card = {
            "name": member["name"],
            "context_window_size": facts["context_window"],
            "description": (
                f"{member['alias']} via {member['transport']} "
                f"({member['wire_protocol']} upstream, {member['region']})"
            ),
            "capabilities": facts["capabilities"],
            "quality_score": round(quality[member["name"]], 4),
            "modality": "ar",
            "tags": tags,
        }
        cards.append(card)
    return cards


def domain_signals(domains: list[str]) -> list[dict[str, Any]]:
    """Declare the classifier labels the decisions are allowed to match on.

    One label per MMLU-Pro category, so a scored request always lands in a
    decision. A request that fell through would be answered by the default
    model, which would quietly convert a routed arm into a pinned one and make
    the arm's result meaningless.
    """
    return [
        {
            "name": domain,
            "description": f"MMLU-Pro category {domain}.",
            "mmlu_categories": [domain],
        }
        for domain in domains
    ]


def multi_factor_decisions(
    members: list[dict[str, Any]], domains: list[str], weights: dict[str, float]
) -> list[dict[str, Any]]:
    """One decision per domain, each scoring the whole pool.

    The arm under test is the selector, not a hand-written per-category table:
    every member is a candidate everywhere and `multi_factor` balances quality,
    cost and observed latency. Splitting by domain is what lets a later arm
    narrow the candidate set per category without changing anything else.
    """
    algorithm = {
        "type": "multi_factor",
        "multi_factor": {
            "weights": weights,
            "latency_percentile": 95,
            "on_no_candidates": "cheapest",
        },
    }
    model_refs = [{"model": member["name"]} for member in members]
    return [
        {
            "name": f"mom_multi_factor_{domain.replace(' ', '_')}",
            "description": f"Weighted quality, latency and cost selection for {domain}.",
            "priority": 100,
            "rules": {
                "operator": "AND",
                "conditions": [{"type": "domain", "name": domain}],
            },
            "modelRefs": model_refs,
            "algorithm": algorithm,
        }
        for domain in domains
    ]


def router_config(
    members: list[dict[str, Any]],
    cards: list[dict[str, Any]],
    decisions: list[dict[str, Any]],
    domains: list[str],
    *,
    default_model: str,
    listener_port: int,
    entrypoint: str,
    recipe_name: str,
    quality_source: str,
    domain_classifier: str,
    management_api_bind: str,
) -> dict[str, Any]:
    signals = {"domains": domain_signals(domains)}
    return {
        "version": "v0.3",
        "listeners": [
            {
                "name": f"http-{listener_port}",
                "address": "0.0.0.0",
                "port": listener_port,
                "timeout": "1200s",
            }
        ],
        "providers": {
            "defaults": {"default_model": default_model},
            "models": provider_models(members),
        },
        "routing": {
            "strategy": "priority",
            "modelCards": cards,
            "signals": signals,
            "decisions": decisions,
        },
        "entrypoints": [{"model_names": [entrypoint], "recipe": recipe_name}],
        "recipes": [
            {
                "name": recipe_name,
                "description": (
                    "Benchmark arm: multi-factor selection over the whole pool. "
                    f"Quality scores come from: {quality_source}."
                ),
                "routing": {
                    "strategy": "priority",
                    "signals": signals,
                    "decisions": decisions,
                },
            }
        ],
        "global": {
            "router": {"config_source": "file", "strategy": "priority"},
            "services": {
                # The classification API answers "which decision would this
                # request take, and which model would be named" without calling a
                # model, which is how the classifier's own accuracy and the
                # selector's choices get measured for free. Its default bind
                # address is loopback, which makes the Service port that
                # advertises it unreachable from anywhere in the cluster — the
                # port would exist and nothing could connect to it.
                "management_api": {"bind_address": management_api_bind}
            },
            "model_catalog": {
                # The domain signal every decision matches on. The router
                # downloads this classifier on first start; its label set is the
                # 14 MMLU-Pro categories the pool declares as domains, so a
                # mismatch here would leave requests unrouted.
                "system": {"domain_classifier": domain_classifier}
            },
        },
    }


def envoy_config(
    members: list[dict[str, Any]],
    *,
    listen_port: int,
    extproc_host: str,
    extproc_port: int,
    name_prefixes: dict[str, str],
) -> dict[str, Any]:
    """Envoy owns the connection; the router only names the model.

    One cluster per distinct upstream address, and one route per transport
    prefix, so adding a member to `pool.yaml` never needs an Envoy edit.
    """
    clusters: dict[str, dict[str, Any]] = {}
    routes: list[dict[str, Any]] = []

    gateway_members = [m for m in members if m["transport"] == "gateway"]
    if gateway_members:
        host, _, port = gateway_members[0]["endpoint"].partition(":")
        for member in gateway_members:
            if member["endpoint"] != gateway_members[0]["endpoint"]:
                raise ConfigError(
                    "gateway members must share one endpoint; "
                    f"{member['name']} disagrees"
                )
        clusters["gateway_cluster"] = tls_cluster("gateway_cluster", host, int(port))
        routes.append(
            {
                "match": {
                    "prefix": "/",
                    "headers": [
                        {
                            "name": "x-selected-model",
                            "string_match": {"prefix": name_prefixes["gateway"]},
                        }
                    ],
                },
                "route": {
                    "cluster": "gateway_cluster",
                    "timeout": "1200s",
                    "host_rewrite_literal": host,
                },
            }
        )

    for member in (m for m in members if m["transport"] == "direct"):
        cluster_name = f"{member['alias'].replace('.', '-').replace('/', '-')}_cluster"
        host, _, port = member["endpoint"].partition(":")
        clusters[cluster_name] = plain_cluster(cluster_name, host, int(port or 80))
        routes.append(
            {
                "match": {
                    "prefix": "/",
                    "headers": [
                        {
                            "name": "x-selected-model",
                            "string_match": {"exact": member["name"]},
                        }
                    ],
                },
                "route": {"cluster": cluster_name, "timeout": "1200s"},
            }
        )

    if not routes:
        raise ConfigError("the pool has no members, so Envoy has nothing to route")

    # A request that reaches Envoy with no usable decision must fail loudly
    # rather than silently land on whichever cluster happens to be first.
    routes.append(
        {
            "match": {"prefix": "/"},
            "direct_response": {
                "status": 503,
                "body": {
                    "inline_string": (
                        '{"error":{"message":"no route for x-selected-model; '
                        'the router did not select a pool member",'
                        '"type":"router_no_decision"}}'
                    )
                },
            },
        }
    )

    return {
        "admin": {
            "address": {
                "socket_address": {"address": "127.0.0.1", "port_value": 19000}
            }
        },
        "static_resources": {
            "listeners": [
                listener(listen_port, routes, extproc_cluster_name="extproc_service")
            ],
            "clusters": [
                plain_cluster("extproc_service", extproc_host, extproc_port, http2=True),
                *clusters.values(),
            ],
        },
    }


def listener(
    port: int, routes: list[dict[str, Any]], *, extproc_cluster_name: str
) -> dict[str, Any]:
    return {
        "name": "listener_0",
        "address": {"socket_address": {"address": "0.0.0.0", "port_value": port}},
        "filter_chains": [
            {
                "filters": [
                    {
                        "name": "envoy.filters.network.http_connection_manager",
                        "typed_config": {
                            "@type": (
                                "type.googleapis.com/envoy.extensions.filters.network."
                                "http_connection_manager.v3.HttpConnectionManager"
                            ),
                            "stat_prefix": "ingress_http",
                            "access_log": [
                                {
                                    "name": "envoy.access_loggers.stdout",
                                    "typed_config": {
                                        "@type": (
                                            "type.googleapis.com/envoy.extensions."
                                            "access_loggers.stream.v3.StdoutAccessLog"
                                        ),
                                        "log_format": {
                                            "json_format": {
                                                "time": "%START_TIME%",
                                                "path": "%REQ(:PATH)%",
                                                "status": "%RESPONSE_CODE%",
                                                "flags": "%RESPONSE_FLAGS%",
                                                "duration_ms": "%DURATION%",
                                                "upstream_cluster": "%UPSTREAM_CLUSTER%",
                                                "selected_model": "%REQ(X-SELECTED-MODEL)%",
                                                "request_id": "%REQ(X-REQUEST-ID)%",
                                            }
                                        },
                                    },
                                }
                            ],
                            "route_config": {
                                "name": "local_route",
                                "virtual_hosts": [
                                    {
                                        "name": "local_service",
                                        "domains": ["*"],
                                        # A client must not be able to forge the
                                        # router's internal signals.
                                        "request_headers_to_remove": [
                                            "x-selected-model",
                                            "x-vsr-looper-request",
                                            "x-vsr-looper-secret",
                                            "x-vsr-looper-decision",
                                            "x-vsr-looper-iteration",
                                        ],
                                        "routes": routes,
                                    }
                                ],
                            },
                            "http_filters": [
                                {
                                    "name": "envoy.filters.http.ext_proc",
                                    "typed_config": {
                                        "@type": (
                                            "type.googleapis.com/envoy.extensions."
                                            "filters.http.ext_proc.v3.ExternalProcessor"
                                        ),
                                        "grpc_service": {
                                            "envoy_grpc": {
                                                "cluster_name": extproc_cluster_name
                                            }
                                        },
                                        "allow_mode_override": True,
                                        "processing_mode": {
                                            "request_header_mode": "SEND",
                                            "response_header_mode": "SEND",
                                            "request_body_mode": "BUFFERED",
                                            "response_body_mode": "BUFFERED",
                                            "request_trailer_mode": "SKIP",
                                            "response_trailer_mode": "SKIP",
                                        },
                                        # The benchmark must never silently
                                        # bypass the router: a dead ExtProc has
                                        # to fail the request, not turn into an
                                        # unrouted call.
                                        "failure_mode_allow": False,
                                        "message_timeout": "300s",
                                    },
                                },
                                {
                                    "name": "envoy.filters.http.router",
                                    "typed_config": {
                                        "@type": (
                                            "type.googleapis.com/envoy.extensions."
                                            "filters.http.router.v3.Router"
                                        ),
                                        "suppress_envoy_headers": False,
                                    },
                                },
                            ],
                            "stream_idle_timeout": "1200s",
                            "request_timeout": "1200s",
                            "common_http_protocol_options": {
                                "idle_timeout": "1200s"
                            },
                        },
                    }
                ]
            }
        ],
    }


def plain_cluster(
    name: str, host: str, port: int, *, http2: bool = False
) -> dict[str, Any]:
    http_config = (
        {"http2_protocol_options": {}} if http2 else {"http_protocol_options": {}}
    )
    return {
        "name": name,
        "connect_timeout": "10s",
        "type": "STRICT_DNS",
        "lb_policy": "ROUND_ROBIN",
        "typed_extension_protocol_options": {
            "envoy.extensions.upstreams.http.v3.HttpProtocolOptions": {
                "@type": (
                    "type.googleapis.com/envoy.extensions.upstreams.http.v3."
                    "HttpProtocolOptions"
                ),
                "explicit_http_config": http_config,
            }
        },
        "load_assignment": {
            "cluster_name": name,
            "endpoints": [
                {
                    "lb_endpoints": [
                        {
                            "endpoint": {
                                "address": {
                                    "socket_address": {
                                        "address": host,
                                        "port_value": port,
                                    }
                                }
                            }
                        }
                    ]
                }
            ],
        },
    }


def tls_cluster(name: str, host: str, port: int) -> dict[str, Any]:
    cluster = plain_cluster(name, host, port)
    cluster["type"] = "LOGICAL_DNS"
    cluster["dns_lookup_family"] = "V4_ONLY"
    cluster["load_assignment"]["endpoints"][0]["lb_endpoints"][0]["endpoint"][
        "hostname"
    ] = host
    cluster["transport_socket"] = {
        "name": "envoy.transport_sockets.tls",
        "typed_config": {
            "@type": (
                "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3."
                "UpstreamTlsContext"
            ),
            "sni": host,
        },
    }
    return cluster


# --------------------------------------------------------------------------- #
# entry point
# --------------------------------------------------------------------------- #


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--pool",
        type=Path,
        default=Path(__file__).with_name("pool.yaml"),
        help="pool specification (default: pool.yaml beside this script)",
    )
    parser.add_argument(
        "--stratoclave-defaults",
        type=Path,
        required=True,
        help="directory holding the gateway's models.json and pricing.json",
    )
    parser.add_argument("--out-dir", type=Path, required=True)
    parser.add_argument(
        "--quality-from",
        type=Path,
        help="calibration summary; replaces the price prior with measured accuracy",
    )
    parser.add_argument("--listener-port", type=int, default=8899)
    parser.add_argument("--envoy-port", type=int, default=8801)
    parser.add_argument("--extproc-host", default="127.0.0.1")
    parser.add_argument("--extproc-port", type=int, default=50051)
    parser.add_argument("--entrypoint", default="vllm-sr/mom-bench")
    parser.add_argument("--recipe-name", default="mom-bench-multifactor")
    parser.add_argument(
        "--domain-classifier",
        default="models/mmbert32k-intent-classifier-merged",
        help="router-local path of the intent classifier that emits domain labels",
    )
    parser.add_argument(
        "--management-api-bind",
        default="0.0.0.0",
        help=(
            "bind address for the classification API. The router's own default is "
            "loopback, which leaves the Service port advertising an endpoint nothing "
            "in the cluster can reach"
        ),
    )
    parser.add_argument(
        "--weights",
        default="quality=0.5,cost=0.3,latency=0.2",
        help="multi_factor weights as key=value pairs",
    )
    return parser.parse_args(argv)


def parse_weights(spec: str) -> dict[str, float]:
    weights = {}
    for pair in spec.split(","):
        key, _, value = pair.partition("=")
        weights[key.strip()] = float(value)
    total = sum(weights.values())
    if abs(total - 1.0) > 1e-6:
        raise ConfigError(f"multi_factor weights must sum to 1.0, got {total}")
    return weights


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    pool = load_yaml(args.pool)
    registry = load_json(args.stratoclave_defaults / "models.json")
    pricing = load_json(args.stratoclave_defaults / "pricing.json")

    members = resolve_members(pool, index_registry(registry), pricing["rates"])

    if args.quality_from:
        quality = measured_scores(args.quality_from, {m["name"] for m in members})
        quality_source = f"measured ({args.quality_from.name})"
    else:
        low, high = pool["quality"]["range"]
        quality = price_prior_scores(members, low, high)
        quality_source = "price prior (uncalibrated)"

    cards = model_cards(members, quality, quality_source)
    domains = pool["domains"]
    decisions = multi_factor_decisions(members, domains, parse_weights(args.weights))

    economy = [m for m in members if "economy" in m["roles"]]
    default_model = (economy or members)[0]["name"]

    router = router_config(
        members,
        cards,
        decisions,
        domains,
        default_model=default_model,
        listener_port=args.listener_port,
        entrypoint=args.entrypoint,
        recipe_name=args.recipe_name,
        quality_source=quality_source,
        domain_classifier=args.domain_classifier,
        management_api_bind=args.management_api_bind,
    )
    envoy = envoy_config(
        members,
        listen_port=args.envoy_port,
        extproc_host=args.extproc_host,
        extproc_port=args.extproc_port,
        name_prefixes={
            name: transport["name_prefix"]
            for name, transport in pool["transports"].items()
        },
    )

    args.out_dir.mkdir(parents=True, exist_ok=True)
    router_path = args.out_dir / "router-config.yaml"
    envoy_path = args.out_dir / "envoy.yaml"
    with router_path.open("w") as handle:
        yaml.safe_dump(router, handle, sort_keys=False, width=100)
    with envoy_path.open("w") as handle:
        yaml.safe_dump(envoy, handle, sort_keys=False, width=100)

    print(f"[OK] {len(members)} members -> {router_path}")
    print(f"[OK] envoy routes -> {envoy_path}")
    print(f"[INFO] quality source: {quality_source}")
    print(f"[INFO] default model: {default_model}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ConfigError as error:
        print(f"[FAIL] {error}", file=sys.stderr)
        sys.exit(2)
