#!/usr/bin/env python3
"""Generate a deterministic graph fixture; no third-party dependencies or UI."""
import argparse
import json
import random
from pathlib import Path


def generate(settlements=100, valleys=10, seed=42, links="sparse"):
    if not 1 <= valleys <= settlements or settlements > 10000:
        raise ValueError("require 1 <= valleys <= settlements <= 10000")
    if links not in ("sparse", "isolated", "redundant"):
        raise ValueError("unknown link mode")
    rng = random.Random(seed)
    nodes, edges, groups = [], [], []
    pairs = set()

    def edge(a, b, kind):
        pair = tuple(sorted((a, b)))
        if a == b or pair in pairs:
            return
        pairs.add(pair)
        river = kind == "river"
        travel = rng.randint(2, 5) if river else rng.randint(4, 10)
        edges.append(dict(id=len(edges)+1, a=a, b=b, kind=kind,
                          capacity=rng.randint(100, 250) if river else rng.randint(20, 80),
                          days_ab=travel, days_ba=travel*1.75 if river else travel,
                          toll=0.0, risk=0.04 if river else 0.10))

    for valley in range(valleys):
        count = settlements // valleys + (valley < settlements % valleys)
        ids = list(range(len(nodes)+1, len(nodes)+count+1))
        groups.append(ids)
        trunk = max(1, (count+1)//2)
        for i, sid in enumerate(ids):
            # Seed roles use the existing five-settlement archetypes:
            # mixed farm, pasture, woodland, ironworks, port/farm/smithy.
            role = (1 if i % 2 == 0 else 5) if i < trunk else rng.choice([2, 3, 4])
            nodes.append(dict(id=sid, name=f"Valley {valley+1:02d} / {i+1:02d}",
                              valley=valley+1, archetype=role,
                              households=rng.randint(50, 150)))
            if 0 < i < trunk:
                edge(ids[i-1], sid, "river")
            elif i >= trunk:
                edge(ids[rng.randrange(trunk)], sid, "feeder")
                if i > trunk and rng.random() < 0.35:
                    edge(ids[i-1], sid, "track")
    # Add inter-valley links only after generating local economies/topology,
    # so changing connectivity preserves the same controlled starting world.
    if links != "isolated":
        for valley in range(1, valleys):
            edge(groups[valley-1][0], groups[valley][0], "pass")
    if links == "redundant":
        for valley in range(1, valleys):
            edge(groups[valley-1][-1], groups[valley][-1], "pass")
    result = dict(schema_version=1, seed=seed, link_mode=links,
                  valley_count=valleys, settlements=nodes, edges=edges)
    validate(result)
    return result


def validate(graph):
    nodes = {n["id"]: n for n in graph["settlements"]}
    assert len(nodes) == len(graph["settlements"])
    adjacency = {sid: set() for sid in nodes}
    pairs = set()
    for e in graph["edges"]:
        a, b = e["a"], e["b"]
        assert a in nodes and b in nodes and a != b
        pair = tuple(sorted((a, b)))
        assert pair not in pairs
        pairs.add(pair)
        assert e["capacity"] > 0 and e["days_ab"] > 0 and e["days_ba"] > 0
        adjacency[a].add(b)
        adjacency[b].add(a)
    remaining = set(nodes)
    components = 0
    while remaining:
        components += 1
        stack = [min(remaining)]
        while stack:
            node = stack.pop()
            if node in remaining:
                remaining.remove(node)
                stack.extend(adjacency[node] & remaining)
    expected = graph["valley_count"] if graph["link_mode"] == "isolated" else 1
    assert components == expected, (components, expected)
    return components


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settlements", type=int, default=100)
    parser.add_argument("--valleys", type=int, default=10)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--links", choices=["sparse", "isolated", "redundant"], default="sparse")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        graph = generate(args.settlements, args.valleys, args.seed, args.links)
    except ValueError as exc:
        parser.error(str(exc))
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(graph, indent=2)+"\n", encoding="utf-8")
    print(f"{len(graph['settlements'])} settlements, {len(graph['edges'])} edges, "
          f"{validate(graph)} components -> {args.out}")


if __name__ == "__main__":
    main()
