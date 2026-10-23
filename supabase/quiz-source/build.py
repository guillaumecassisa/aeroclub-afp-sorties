#!/usr/bin/env python3
"""Assemble migration-34 : en-tête SQL + corrections + banque de questions (fichiers q*.txt).
Format d'une ligne : categorie|question|bonne réponse|faux 1|faux 2|faux 3|explication
"""
import glob, hashlib, os, re, sys, unicodedata, collections

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, 'migration-34-quiz.sql')
CATS = {'general', 'meteo', 'reglementation', 'navigation', 'mecanique', 'moteur', 'instruments', 'radio',
        'documents', 'aerodynamique', 'performances', 'culture', 'flotte', 'securite', 'sol', 'pilotage', 'lfma'}
EXISTING = [l.strip() for l in open(os.path.join(HERE, 'existing.txt'), encoding='utf-8') if l.strip()]

def norm(s):
    s = re.sub(r'-(?=\d)', ' moins ', s)
    s = s.replace('/', ' sur ').replace('√', ' racine ').replace('%', ' pct ')
    s = unicodedata.normalize('NFKD', s.lower())
    s = ''.join(c for c in s if not unicodedata.combining(c))
    return re.sub(r'[^a-z0-9]+', ' ', s).strip()

def q(s):
    return "'" + s.replace("'", "''") + "'"

rows, errors, seen = [], [], {norm(e): 'existant' for e in EXISTING}
for f in sorted(glob.glob(os.path.join(HERE, 'q*.txt'))):
    for n, line in enumerate(open(f, encoding='utf-8'), 1):
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        p = [x.strip() for x in line.split('|')]
        where = f'{os.path.basename(f)}:{n}'
        if len(p) != 7:
            errors.append(f'{where}: {len(p)} champs'); continue
        cat, question, good, w1, w2, w3, expl = p
        if cat not in CATS: errors.append(f'{where}: catégorie {cat}')
        if not (5 <= len(question) <= 500): errors.append(f'{where}: question longueur')
        opts = [good, w1, w2, w3]
        if any(not (1 <= len(o) <= 300) for o in opts): errors.append(f'{where}: option longueur')
        if len({norm(o) for o in opts}) != 4: errors.append(f'{where}: options en double')
        if not (10 <= len(expl) <= 1500): errors.append(f'{where}: explication longueur')
        k = norm(question)
        if k in seen: errors.append(f'{where}: doublon de {seen[k]}')
        seen[k] = where
        rows.append((cat, question, good, [w1, w2, w3], expl))

# Bonne réponse répartie équitablement sur a/b/c/d, ordre stable
order = sorted(range(len(rows)), key=lambda i: hashlib.md5(rows[i][1].encode()).hexdigest())
pos = {}
for rank, i in enumerate(order):
    pos[i] = rank % 4
values, dist, cats = [], collections.Counter(), collections.Counter()
for i, (cat, question, good, wrong, expl) in enumerate(rows):
    k = pos[i]
    opts = wrong[:k] + [good] + wrong[k:]
    letter = 'abcd'[k]
    dist[letter] += 1; cats[cat] += 1
    values.append('    (' + ', '.join(q(x) for x in [question] + opts + [letter, expl, cat]) + ')')

if errors:
    print('\n'.join(errors)); sys.exit(1)

head = open(os.path.join(HERE, 'head.sql'), encoding='utf-8').read()
corr = open(os.path.join(HERE, 'corrections.sql'), encoding='utf-8').read()
with open(OUT, 'w', encoding='utf-8') as o:
    o.write(head + '\n' + corr + '\n')
    o.write('-- 3. Banque de questions (posée une seule fois) ----------------------------------\n')
    o.write("do $seed$ begin\n  if not public._seed_once('quiz-34') then return; end if;\n")
    o.write('  insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)\n')
    o.write('  select v.question, v.option_a, v.option_b, v.option_c, v.option_d, v.correct, v.explanation, v.category\n  from (values\n')
    o.write(',\n'.join(values))
    o.write('\n  ) as v(question, option_a, option_b, option_c, option_d, correct, explanation, category)\n')
    o.write('  where not exists (select 1 from public.quiz_questions x where lower(btrim(x.question)) = lower(btrim(v.question)));\nend $seed$;\n\n')
    o.write("notify pgrst, 'reload schema';\n\n-- Vérification\nselect\n"
            "  exists (select 1 from pg_proc where proname = 'quiz_today_set')\n"
            "  and exists (select 1 from pg_indexes where indexname = 'quiz_answers_user_day_question')\n"
            "  and (select count(*) from public.quiz_questions) >= 900 as \"MISE A JOUR 34 OK\",\n"
            "  (select count(*) from public.quiz_questions where active) as \"questions actives\";\n")
print(f'{len(rows)} nouvelles questions -> {OUT}')
print('bonnes réponses :', dict(sorted(dist.items())))
print('catégories :', dict(cats.most_common()))
