#!/usr/bin/env python3
"""Régénère public/outils/pistes.json (terrains français : altitude, pistes, longueur, surface)
à partir des fichiers publics OurAirports (domaine public) :
  curl -O https://raw.githubusercontent.com/davidmegginson/ourairports-data/main/airports.csv
  curl -O https://raw.githubusercontent.com/davidmegginson/ourairports-data/main/runways.csv
  python3 scripts/pistes-ourairports.py <dossier des deux fichiers>
Les distances déclarées officielles (TORA / LDA) sont lues en direct sur la VAC du SIA quand elle
les publie ; ces longueurs physiques ne servent qu'à défaut."""
import csv, json, sys, re, os

d = sys.argv[1]
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ads = {r[0]: r[1] for r in json.load(open(os.path.join(root, 'lib/aerodromes.json'), encoding='utf-8'))}
elev = {}
for r in csv.DictReader(open(os.path.join(d, 'airports.csv'), encoding='utf-8')):
    if r['ident'] in ads and r['elevation_ft']:
        elev[r['ident']] = int(float(r['elevation_ft']))

def surface(s):
    s = (s or '').strip().lower()
    if s.startswith(('asp', 'con', 'bit', 'pem', 'mac', 'tar', 'paved', 'hard')):
        return 'dur'
    if s.startswith(('gr', 'turf', 'g', 'unpaved', 'sand', 'dirt')):
        return 'herbe'
    return ''

out = {}
for r in csv.DictReader(open(os.path.join(d, 'runways.csv'), encoding='utf-8')):
    ic = r['airport_ident']
    if ic not in ads or r['closed'] == '1' or not r['length_ft']:
        continue
    length = round(int(r['length_ft']) * 0.3048)
    for e in ('le', 'he'):
        ident = r[e + '_ident'].strip().upper()
        m = re.match(r'^(\d{1,2})([LRC]?)$', ident)
        if not m:
            continue
        thr = r[e + '_displaced_threshold_ft']
        out.setdefault(ic, {'n': ads[ic], 'e': elev.get(ic), 'r': []})['r'].append(
            {'id': m.group(1).zfill(2) + m.group(2), 'len': length, 'thr': round(int(thr) * 0.3048) if thr else 0,
             'surf': surface(r['surface'])})
for ic, n in ads.items():
    if re.match(r'^LF[A-Z]{2}$', ic) and ic not in out:
        out[ic] = {'n': n, 'e': elev.get(ic), 'r': []}
json.dump(dict(sorted(out.items())), open(os.path.join(root, 'public/outils/pistes.json'), 'w', encoding='utf-8'),
          ensure_ascii=False, separators=(',', ':'))
print(len(out), 'terrains,', sum(1 for v in out.values() if v['r']), 'avec pistes')
