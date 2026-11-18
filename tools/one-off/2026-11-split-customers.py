#!/usr/bin/env python3
"""2026-11-split-customers.py: one-off move of the customer targets out of
prometheus.yml into one file per customer (change of Nov 2026).

Reads the June-style /etc/prometheus/prometheus.yml (every target a
static_config in its own job) and writes /etc/prometheus/targets/customers/
<customer>.yml, one file per customer, each target carrying its old job name
as a `job` label, so every series keeps its identity.

Before writing anything it proves the new layout is the same as the old:
the customer files it would write plus the repo's infrastructure.yml and
external.yml must hold exactly the old targets with exactly the old labels,
and every old job's interval, timeout, path and module must equal the new
scrape pool's. The one deliberate difference is the postgres_exporter `vm`
label, which takes the node_exporter's vm for the same VM (agreed 18 Nov 2026).
Any other difference stops it.

Dry run by default: prints what it would write. --write writes the files.
It never overwrites an existing customer file unless --force.

Run it BEFORE sync.sh replaces prometheus.yml (it needs the old one):
    sudo python3 tools/one-off/2026-11-split-customers.py              # dry run
    sudo python3 tools/one-off/2026-11-split-customers.py --write
"""
import argparse
import os
import subprocess
import sys

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))

# The new scrape pools (must match prometheus/prometheus.yml).
POOLS = {
    'node':              {'interval': None, 'timeout': None, 'path': None,     'module': None},
    'nginx':             {'interval': None, 'timeout': None, 'path': None,     'module': None},
    'postgres':          {'interval': None, 'timeout': None, 'path': None,     'module': None},
    'blackbox-customer': {'interval': '30s', 'timeout': '15s', 'path': '/probe', 'module': 'http_2xx_lenient'},
    'blackbox-external': {'interval': '60s', 'timeout': '15s', 'path': '/probe', 'module': 'http_2xx'},
}


def pool_for(job):
    if job.startswith('blackbox-ext-'):
        return 'blackbox-external'
    if job.startswith('blackbox-'):
        return 'blackbox-customer'
    for p in ('node', 'nginx', 'postgres'):
        if job.startswith(p + '-'):
            return p
    return None


def old_targets(cfg):
    """[(job, target, labels, settings)] from the June-style config."""
    out = []
    for sc in cfg.get('scrape_configs', []):
        job = sc['job_name']
        if 'file_sd_configs' in sc:
            sys.exit(f'job {job} already uses file_sd: this config has been migrated')
        settings = {
            'interval': sc.get('scrape_interval'),
            'timeout': sc.get('scrape_timeout'),
            'path': sc.get('metrics_path'),
            'module': (sc.get('params', {}).get('module') or [None])[0],
        }
        for st in sc.get('static_configs', []):
            for t in st.get('targets', []):
                out.append((job, t, dict(st.get('labels', {})), settings))
    return out


def load_list(path):
    with open(path) as f:
        return yaml.safe_load(f) or []


def key(job, target, labels):
    lab = dict(labels)
    lab['job'] = job
    return (target, tuple(sorted(lab.items())))


def render(customer, groups):
    lines = [
        f'# /etc/prometheus/targets/customers/{customer}.yml',
        f'# {customer}: written by tools/one-off/2026-11-split-customers.py from the',
        '# June prometheus.yml. Server-owned: edit here, then run check-targets.py.',
        '',
    ]
    for job, target, labels in groups:
        lines.append(f"- targets: ['{target}']")
        lines.append('  labels:')
        lines.append(f'    job: {job}')
        for k in ('customer', 'vm', 'role'):
            if k in labels:
                lines.append(f'    {k}: {labels[k]}')
        lines.append('')
    return '\n'.join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--config', default='/etc/prometheus/prometheus.yml')
    ap.add_argument('--out', default='/etc/prometheus/targets/customers')
    ap.add_argument('--git-targets', default=os.path.join(REPO, 'prometheus', 'targets'))
    ap.add_argument('--write', action='store_true')
    ap.add_argument('--force', action='store_true')
    a = ap.parse_args()

    with open(a.config) as f:
        old = old_targets(yaml.safe_load(f))
    print(f'old config: {len(old)} targets in {len({o[0] for o in old})} jobs')

    problems = []

    # 1. Every old job's scrape settings must equal its new pool's.
    for job, t, lab, st in old:
        pool = pool_for(job)
        if pool is None:
            problems.append(f'{job}: no scrape pool takes this job prefix')
            continue
        if st != POOLS[pool]:
            problems.append(f'{job}: settings {st} differ from pool {pool} {POOLS[pool]}')

    # 2. Split: infrastructure and external come from git, customers are written.
    customers = {}
    old_keys = set()
    for job, t, lab, st in old:
        old_keys.add(key(job, t, lab))
        if lab.get('customer') == 'infrastructure' or job.startswith('blackbox-ext-'):
            continue
        cust = lab.get('customer')
        if not cust:
            problems.append(f'{job}: no customer label')
            continue
        customers.setdefault(cust, []).append([job, t, dict(lab)])

    # 3. The agreed fix: postgres vm takes the node vm on the same host.
    changes = []
    for cust, groups in customers.items():
        node_vm = {t.rsplit(':', 1)[0]: lab['vm'] for job, t, lab in groups if job.startswith('node-')}
        for g in groups:
            job, t, lab = g
            if job.startswith('postgres-'):
                host = t.rsplit(':', 1)[0]
                if host not in node_vm:
                    problems.append(f'{job}: no node target on {host} to take the vm name from')
                elif lab.get('vm') != node_vm[host]:
                    changes.append((key(job, t, lab), f'{job} {t}: vm {lab.get("vm")} -> {node_vm[host]}'))
                    lab['vm'] = node_vm[host]

    # 4. New = git files + customer files. Must equal old, bar the vm changes.
    new_keys = set()
    for name in ('infrastructure.yml', 'external.yml'):
        for g in load_list(os.path.join(a.git_targets, name)):
            lab = dict(g['labels'])
            job = lab.pop('job')
            for t in g['targets']:
                new_keys.add(key(job, t, lab))
    for groups in customers.values():
        for job, t, lab in groups:
            new_keys.add(key(job, t, {k: v for k, v in lab.items()}))

    changed_old = {c[0] for c in changes}
    missing = old_keys - new_keys - changed_old
    added = new_keys - old_keys
    expected_added = len(changes)
    for k in sorted(missing):
        problems.append(f'old target not in the new layout: {k}')
    if len(added) != expected_added:
        for k in sorted(added):
            problems.append(f'new layout has a target the old did not: {k}')

    print(f'customers: {", ".join(f"{c} ({len(g)})" for c, g in sorted(customers.items()))}')
    print(f'deliberate changes ({len(changes)}):')
    for _, msg in changes:
        print(f'  {msg}')
    if problems:
        print('STOPPED, the new layout would not match the old:')
        for p in problems:
            print(f'  - {p}')
        return 1
    print('equivalence: OK (old targets == git files + customer files, bar the vm changes)')

    # 5. Write (or show).
    if a.write:
        os.makedirs(a.out, exist_ok=True)
    for cust, groups in sorted(customers.items()):
        path = os.path.join(a.out, f'{cust}.yml')
        text = render(cust, groups)
        if not a.write:
            print(f'\n--- would write {path}\n{text}')
            continue
        if os.path.exists(path) and not a.force:
            print(f'exists, left alone: {path} (use --force)')
            continue
        tmp = path + '.tmp'
        with open(tmp, 'w') as f:
            f.write(text)
        os.chmod(tmp, 0o644)
        try:
            import pwd
            pw = pwd.getpwnam('prometheus')
            os.chown(tmp, pw.pw_uid, pw.pw_gid)
        except (KeyError, PermissionError):
            pass
        os.rename(tmp, path)
        print(f'wrote {path}')

    if a.write:
        rc = subprocess.call([sys.executable, os.path.join(REPO, 'tools', 'check-targets.py'),
                              '--customer'] + [os.path.join(a.out, f'{c}.yml') for c in sorted(customers)])
        return rc
    print('\ndry run: nothing written (add --write)')
    return 0


if __name__ == '__main__':
    sys.exit(main())
