#!/usr/bin/env python3
"""targets-snapshot.py: record what Prometheus is scraping, and compare two
records. Used either side of a change to prove the series identities held.

    python3 tools/targets-snapshot.py save before.json
    ... change ...
    python3 tools/targets-snapshot.py save after.json
    python3 tools/targets-snapshot.py diff before.json after.json

A target's identity is its final label set (job, instance and the rest), which
is what every series it produces carries. The scrape pool name is not part of
it and is ignored. diff exits 1 if anything was added, removed or changed.
"""
import json
import sys
import urllib.request

PROM = 'http://127.0.0.1:9090'


def save(path):
    d = json.load(urllib.request.urlopen(f'{PROM}/api/v1/targets?state=active'))
    out = []
    for t in d['data']['activeTargets']:
        out.append({'labels': t['labels'], 'health': t['health'], 'scrapeUrl': t['scrapeUrl'],
                    'interval': t.get('scrapeInterval'), 'timeout': t.get('scrapeTimeout'),
                    'pool': t['scrapePool']})
    out.sort(key=lambda x: (x['labels'].get('job', ''), x['labels'].get('instance', '')))
    with open(path, 'w') as f:
        json.dump(out, f, indent=1)
    bad = [t for t in out if t['health'] != 'up']
    print(f'{path}: {len(out)} targets, {len(bad)} not up')
    for t in bad:
        print(f"  not up: {t['labels'].get('job')} {t['labels'].get('instance')}")


def ident(t):
    return (t['labels'].get('job'), t['labels'].get('instance'))


def diff(a_path, b_path):
    a = {ident(t): t for t in json.load(open(a_path))}
    b = {ident(t): t for t in json.load(open(b_path))}
    n = 0
    for k in sorted(set(a) - set(b)):
        print(f'REMOVED  {k[0]} {k[1]}'); n += 1
    for k in sorted(set(b) - set(a)):
        print(f'ADDED    {k[0]} {k[1]} {b[k]["labels"]}'); n += 1
    for k in sorted(set(a) & set(b)):
        la, lb = a[k]['labels'], b[k]['labels']
        if la != lb:
            ch = {x: (la.get(x), lb.get(x)) for x in set(la) | set(lb) if la.get(x) != lb.get(x)}
            print(f'LABELS   {k[0]} {k[1]} {ch}'); n += 1
        for f in ('scrapeUrl', 'interval', 'timeout'):
            if a[k][f] != b[k][f]:
                print(f'{f.upper():8} {k[0]} {k[1]} {a[k][f]} -> {b[k][f]}'); n += 1
    print(f'{len(a)} before, {len(b)} after, {n} difference(s)')
    return 1 if n else 0


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'save':
        save(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == 'diff':
        sys.exit(diff(sys.argv[2], sys.argv[3]))
    else:
        print(__doc__)
        sys.exit(2)
