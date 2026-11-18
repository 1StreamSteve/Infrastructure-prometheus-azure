#!/usr/bin/env python3
"""check-rules.py: static checks on the Grafana alerting provisioning files.

Grafana loads a rule whose condition names a step that does not exist, and
only fails when it evaluates it. This catches that class of mistake before
sync.sh restarts Grafana:

  rules.yml          unique uids and titles; condition and every expression
                     reference point at a refId in the rule; data sources are
                     the Prometheus one or expressions; durations and states
                     are valid; severity is critical or warning; summary,
                     description and value annotations present (new-style
                     rules)
  contactpoints.yml  unique receiver uids; templates they call are defined
  policies.yml       every receiver a route names exists

    python3 tools/check-rules.py                         # /etc/grafana/provisioning/alerting
    python3 tools/check-rules.py grafana/provisioning/alerting

Exit codes: 0 good, 1 problems found, 2 cannot read the files.
"""
import os
import re
import sys

import yaml

DUR = re.compile(r'^(0|\d+(ms|s|m|h|d|w))+$')
NODATA = {'OK', 'NoData', 'Alerting', 'KeepLast'}
EXECERR = {'OK', 'Error', 'Alerting', 'KeepLast'}
EXPR_TYPES = {'reduce', 'threshold', 'math', 'resample', 'classic_conditions'}
DATASOURCES = {'prometheus-ds', '__expr__', '-100'}
UID = re.compile(r'^[A-Za-z0-9_-]{1,40}$')


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else '/etc/grafana/provisioning/alerting'
    errs = []

    def load(name):
        p = os.path.join(d, name)
        if not os.path.exists(p):
            return None
        try:
            return yaml.safe_load(open(p)) or {}
        except yaml.YAMLError as e:
            errs.append(f'{name}: not valid YAML: {str(e).splitlines()[0]}')
            return {}

    rules, cps, pol, tmpl = (load(n) for n in ('rules.yml', 'contactpoints.yml', 'policies.yml', 'templates.yml'))
    if rules is None:
        print(f'no rules.yml in {d}', file=sys.stderr)
        return 2

    uids, titles, n = set(), set(), 0
    for g in rules.get('groups') or []:
        gname = g.get('name', '?')
        if not DUR.match(str(g.get('interval', ''))):
            errs.append(f'group {gname}: interval "{g.get("interval")}" is not a duration')
        if not g.get('folder'):
            errs.append(f'group {gname}: no folder')
        for r in g.get('rules') or []:
            n += 1
            uid = r.get('uid', '')
            w = f'rule {uid or "?"} ({r.get("title", "?")})'
            if not UID.match(uid):
                errs.append(f'{w}: uid must be 1-40 letters, digits, - or _')
            if uid in uids:
                errs.append(f'{w}: duplicate uid')
            uids.add(uid)
            if r.get('title') in titles:
                errs.append(f'{w}: duplicate title')
            titles.add(r.get('title'))
            if not DUR.match(str(r.get('for', '0s'))):
                errs.append(f'{w}: for "{r.get("for")}" is not a duration')
            if r.get('noDataState') not in NODATA:
                errs.append(f'{w}: noDataState must be one of {sorted(NODATA)}')
            if r.get('execErrState') not in EXECERR:
                errs.append(f'{w}: execErrState must be one of {sorted(EXECERR)}')
            if (r.get('labels') or {}).get('severity') not in ('critical', 'warning'):
                errs.append(f'{w}: labels.severity must be critical or warning')
            data = r.get('data') or []
            refs = [x.get('refId') for x in data]
            if len(refs) != len(set(refs)):
                errs.append(f'{w}: duplicate refId')
            if r.get('condition') not in refs:
                errs.append(f'{w}: condition "{r.get("condition")}" is not one of its refIds {refs}')
            classic = False
            for x in data:
                ref, ds, m = x.get('refId'), str(x.get('datasourceUid')), x.get('model') or {}
                if ds not in DATASOURCES:
                    errs.append(f'{w}: {ref} uses unknown datasourceUid "{ds}"')
                elif ds == 'prometheus-ds':
                    if not str(m.get('expr', '')).strip():
                        errs.append(f'{w}: {ref} has no PromQL expr')
                else:
                    t = m.get('type')
                    if t not in EXPR_TYPES:
                        errs.append(f'{w}: {ref} expression type "{t}" unknown')
                    if t == 'classic_conditions':
                        classic = True
                    elif t in ('reduce', 'threshold', 'resample') and m.get('expression') not in refs:
                        errs.append(f'{w}: {ref} reads "{m.get("expression")}", not one of {refs}')
                    elif t == 'math':
                        for v in re.findall(r'\$\{?([A-Za-z0-9_]+)\}?', str(m.get('expression', ''))):
                            if v not in refs:
                                errs.append(f'{w}: {ref} math uses ${v}, not one of {refs}')
                    if t == 'threshold' and not m.get('conditions'):
                        errs.append(f'{w}: {ref} threshold has no conditions')
            if not classic:
                ann = r.get('annotations') or {}
                for a in ('summary', 'description', 'value'):
                    if not ann.get(a):
                        errs.append(f'{w}: no {a} annotation')

    receivers, rcv_uids = set(), set()
    used_templates = set()
    for c in (cps or {}).get('contactPoints') or []:
        receivers.add(c.get('name'))
        for r in c.get('receivers') or []:
            if r.get('uid') in rcv_uids:
                errs.append(f'contact point {c.get("name")}: duplicate receiver uid {r.get("uid")}')
            rcv_uids.add(r.get('uid'))
            for v in (r.get('settings') or {}).values():
                used_templates |= set(re.findall(r'template\s+"([^"]+)"', str(v)))
    defined = set()
    for t in (tmpl or {}).get('templates') or []:
        defined |= set(re.findall(r'define\s+"([^"]+)"', str(t.get('template', ''))))
    for t in sorted(used_templates - defined - {'default.message', 'default.title'}):
        errs.append(f'contact points call template "{t}", which templates.yml does not define')

    def walk(node, where):
        rc = node.get('receiver')
        if rc and rc not in receivers:
            errs.append(f'{where}: receiver "{rc}" is not a contact point in contactpoints.yml')
        for i, child in enumerate(node.get('routes') or [], 1):
            walk(child, f'{where} route {i}')
    for p in (pol or {}).get('policies') or []:
        walk(p, 'policies')

    for e in errs:
        print(f'ERROR  {e}')
    print(f'{n} rules, {len(rcv_uids)} receivers checked: ' + (f'{len(errs)} problem(s)' if errs else 'all good'))
    return 1 if errs else 0


if __name__ == '__main__':
    sys.exit(main())
