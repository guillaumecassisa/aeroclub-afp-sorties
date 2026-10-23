-- Questions dans leur version d'origine (avant correction par la mise à jour 34)
insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
values ('Quelle est la définition du QNH ?', 'Pression au niveau de la mer calculée avec une atmosphère standard',
        'Pression au niveau de la mer calculée avec les conditions réelles', 'Pression au niveau de la piste', 'Pression à 1500 ft',
        'b', 'ancienne', 'meteo'),
       ('Quelle est la fréquence de l''AFIS d''Aix-les-Milles (LFMA) ?', '118,105 MHz', '121,500 MHz', '123,500 MHz', '119,700 MHz',
        'a', 'ancienne', 'lfma'),
       ('Si la sonde Pitot est bouchée en montée, l''anémomètre :', 'Indique une vitesse trop élevée', 'Indique une vitesse trop faible',
        'Reste figé', 'Tombe à zéro', 'c', 'ancienne', 'instruments');
-- Une question déjà retouchée par le chef pilote : ne doit pas être écrasée
insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
values ('Le circuit de piste standard se fait :', 'A', 'B', 'C', 'D', 'd', 'retouchée', 'lfma');
