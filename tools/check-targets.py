#!/usr/bin/env python3
"""check-targets.py: validate the Prometheus target files.

Run it after adding or changing a customer file, before you walk away:
    python3 /opt/prometheus-azure-build/tools/check-targets.py

By default it checks /etc/prometheus/targets: infrastructure.yml, external.yml
and every customers/*.yml. Give file paths to check only those (customer files
are recognised by sitting in a folder called customers, or with --customer).
--root points it at another targets folder (the repo, a test copy).

A customer file that breaks a rule here is not a style problem. Prometheus
would drop its targets without a word (wrong job prefix), or the alerts would
name the wrong customer or VM. So every rule is an error, and the exit code
is 1 if any file has one.

Exit codes: 0 all good, 1 errors found, 2 nothing to check / bad arguments.
"""
import argparse
import glob
import os
import re
import sys

try:
    import yaml
except ImportError:
    print('python3-yaml is not installed (apt install python3-yaml)', file=sys.stderr)
    sys.exit(2)

NAME = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')
HOSTPORT = re.compile(r'^[A-Za-z0-9.-]+:[0-9]{1,5}$')
URL = re.compile(r'^https?://[^\s/:]+(:[0-9]{1,5})?(/\S*)?$')

CUSTOMER_LABELS = {'job', 'customer', 'vm', 'role'}
ROLES = {'odoo', 'postgres'}


class Report:
    def __init__(self):
        self.errors = 0

    def file(self, path, errs, info):
        if errs:
            self.errors += len(errs)
            print(f'ERROR  {path}')
            for e in errs:
                print(f'         - {e}')
        else:
            print(f'OK     {path}  ({info})')


def load_groups(path, errs):
    """The file as a list of {targets, labels} groups, or None."""
    try:
        with open(path) as f:
            text = f.read()
    except OSError as e:
        errs.append(f'cannot read: {e}')
        return None
    if re.search(r'^[^#\n]*<[^>\n]+>', text, re.M):
        errs.append('template placeholder <...> still in the file')
    try:
        data = yaml.safe_load(text)
    except yaml.YAMLError as e:
        errs.append(f'not valid YAML: {str(e).splitlines()[0]}')
        return None
    if data is None:
        errs.append('file is empty (delete it instead to stop monitoring)')
        return None
    if not isinstance(data, list):
        errs.append('must be a YAML list of target groups (each starting "- targets:")')
        return None
    groups = []
    for i, g in enumerate(data, 1):
        where = f'group {i}'
        if not isinstance(g, dict):
            errs.append(f'{where}: not a mapping with targets and labels')
            continue
        extra = set(g) - {'targets', 'labels'}
        if extra:
            errs.append(f'{where}: unexpected keys {sorted(extra)} (only targets and labels)')
        t, lab = g.get('targets'), g.get('labels')
        if not isinstance(t, list) or not t or not all(isinstance(x, str) for x in t):
            errs.append(f'{where}: targets must be a non-empty list of quoted strings')
            continue
        if not isinstance(lab, dict) or not all(isinstance(k, str) and isinstance(v, str) for k, v in lab.items()):
            errs.append(f'{where}: labels must map names to text values')
            continue
        if any(k.startswith('__') for k in lab):
            errs.append(f'{where}: labels starting with __ are not allowed here')
        if 'job' not in lab:
            errs.append(f'{where}: no job label (Prometheus would drop the target)')
            continue
        groups.append((where, t, lab))
    return groups


def check_customer(path, rep, seen):
    errs = []
    stem = os.path.basename(path)[:-len('.yml')]
    if not NAME.match(stem):
        errs.append(f'file name "{stem}" must be lower case letters, digits and single hyphens')
    if stem.startswith('ext') or stem == 'infrastructure':
        errs.append(f'customer name "{stem}" is reserved')
    groups = load_groups(path, errs) or []
    node_vm = {}
    pg = []
    n = 0
    for where, targets, lab in groups:
        job, cust = lab['job'], lab.get('customer')
        if cust != stem:
            errs.append(f'{where}: customer is "{cust}", must be "{stem}" (the file name)')
        unknown = set(lab) - CUSTOMER_LABELS
        if unknown:
            errs.append(f'{where}: labels {sorted(unknown)} not allowed in a customer file')
        if job.startswith(f'node-{stem}-') and len(job) > len(f'node-{stem}-'):
            kind = 'node'
        elif job.startswith(f'postgres-{stem}-') and len(job) > len(f'postgres-{stem}-'):
            kind = 'postgres'
        elif job == f'blackbox-{stem}' or job.startswith(f'blackbox-{stem}-'):
            kind = 'probe'
        else:
            errs.append(f'{where}: job "{job}" must be node-{stem}-<vm>, postgres-{stem}-<vm> '
                        f'or blackbox-{stem} (anything else is dropped by Prometheus)')
            continue
        if kind in ('node', 'postgres'):
            for lbl in ('vm', 'role'):
                if lbl not in lab:
                    errs.append(f'{where}: {kind} target needs a {lbl} label')
            if 'vm' in lab and not NAME.match(lab['vm']):
                errs.append(f'{where}: vm "{lab["vm"]}" must be the Azure VM name in lower case')
            if 'role' in lab and lab['role'] not in ROLES:
                errs.append(f'{where}: role "{lab["role"]}" must be one of {sorted(ROLES)}')
            for t in targets:
                if not HOSTPORT.match(t):
                    errs.append(f'{where}: target "{t}" must be <ip>:<port>')
        else:
            if set(lab) - {'job', 'customer'}:
                errs.append(f'{where}: a probe takes only job and customer labels')
            for t in targets:
                if not URL.match(t):
                    errs.append(f'{where}: probe target "{t}" must be a URL, e.g. http://10.9.0.4:8069')
        for t in targets:
            n += 1
            host = t.split('//')[-1].split('/')[0].rsplit(':', 1)[0]
            if kind == 'node' and 'vm' in lab:
                node_vm[host] = lab['vm']
            if kind == 'postgres' and 'vm' in lab:
                pg.append((where, host, lab['vm']))
            key = (kind, t)
            if key in seen:
                errs.append(f'{where}: {t} is already monitored by {seen[key]}')
            else:
                seen[key] = f'{os.path.basename(path)} ({job})'
            if job in seen and seen[job] != path:
                errs.append(f'{where}: job "{job}" is also used in {seen[job]}')
            seen[job] = path
    for where, host, vm in pg:
        if host in node_vm and node_vm[host] != vm:
            errs.append(f'{where}: postgres vm "{vm}" differs from the node vm "{node_vm[host]}" '
                        f'on the same VM ({host}); use the same name')
    rep.file(path, errs, f'{n} targets')


def check_fixed(path, rep, seen, kinds):
    """infrastructure.yml and external.yml: git-owned, lighter rules."""
    errs = []
    groups = load_groups(path, errs) or []
    n = 0
    for where, targets, lab in groups:
        job = lab['job']
        kind = next((k for p, k in kinds.items() if job.startswith(p)), None)
        if kind is None:
            errs.append(f'{where}: job "{job}" must start with one of {sorted(kinds)}')
            continue
        if kind == 'external':
            for lbl in ('category', 'site'):
                if lbl not in lab:
                    errs.append(f'{where}: external probe needs a {lbl} label')
            pattern = URL
        else:
            pattern = HOSTPORT
        for t in targets:
            n += 1
            if not pattern.match(t):
                errs.append(f'{where}: target "{t}" is not a valid {kind} target')
            key = (kind, t)
            if key in seen:
                errs.append(f'{where}: {t} is already monitored by {seen[key]}')
            seen[key] = f'{os.path.basename(path)} ({job})'
            seen[job] = path
    rep.file(path, errs, f'{n} targets')


FIXED = {
    'infrastructure.yml': {'node-': 'node', 'nginx-': 'nginx'},
    'external.yml': {'blackbox-ext-': 'external'},
}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('files', nargs='*', help='only these files')
    ap.add_argument('--root', default='/etc/prometheus/targets', help='targets folder (default %(default)s)')
    ap.add_argument('--customer', action='store_true', help='treat the given files as customer files')
    a = ap.parse_args()

    rep, seen = Report(), {}
    if a.files:
        todo = a.files
    else:
        todo = [os.path.join(a.root, f) for f in FIXED if os.path.exists(os.path.join(a.root, f))]
        cdir = os.path.join(a.root, 'customers')
        todo += sorted(glob.glob(os.path.join(cdir, '*.yml')))
        if os.path.isdir(cdir):
            for f in sorted(os.listdir(cdir)):
                if not f.endswith('.yml'):
                    print(f'note   {os.path.join(cdir, f)} is ignored by Prometheus (not .yml)')
    if not todo:
        print(f'nothing to check under {a.root}', file=sys.stderr)
        return 2

    for path in todo:
        base = os.path.basename(path)
        if a.customer or os.path.basename(os.path.dirname(os.path.abspath(path))) == 'customers':
            if not base.endswith('.yml'):
                rep.file(path, ['customer files must end in .yml, or Prometheus ignores them'], '')
                continue
            check_customer(path, rep, seen)
        elif base in FIXED:
            check_fixed(path, rep, seen, FIXED[base])
        else:
            rep.file(path, ['not a known targets file (use --customer for a customer file)'], '')

    print(f'{rep.errors} error(s)' if rep.errors else 'all good')
    return 1 if rep.errors else 0


if __name__ == '__main__':
    sys.exit(main())
