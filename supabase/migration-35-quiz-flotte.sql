-- =====================================================================
--  Mise à jour n°35 : questions « Flotte » consacrées aux avions du club
--  - La catégorie Flotte du quiz ne parle plus que des avions de l'AFPA :
--    PS28 Cruiser, Robin DR400/180, WT9 Dynamic, Diamond DA40, Bristell B23.
--    Les questions sur d'autres avions passent en Culture, Documents ou Général.
--  - 48 nouvelles questions tirées des manuels de vol (sections 2, 5 et 6,
--    telles que reprises dans le calculateur de performances et la masse et
--    centrage du site) : 50 questions Flotte au total.
--  Peut être exécutée plusieurs fois sans risque.
--  À exécuter dans Supabase > SQL Editor > New query > Run.
-- =====================================================================

-- 1. Questions générales sorties de la catégorie Flotte ---------------------------
update public.quiz_questions set category = 'culture'
 where category = 'flotte' and question in (
   'Le Piper PA-28 Warrior est un avion :',
   'Le moteur Lycoming O-320 qui équipe de nombreux avions école est un moteur :',
   'Le Cessna 172 Skyhawk est :',
   'Le Cessna 152 est :',
   'Quelle est la particularité du Cirrus SR22 en matière de sécurité ?',
   'Le Piper PA-28 et le Cessna 172 diffèrent principalement par :');
update public.quiz_questions set category = 'documents'
 where category = 'flotte' and question in (
   'Que signifie l''acronyme POH ?',
   'Dans le manuel de vol, la section 3 concerne généralement :');
update public.quiz_questions set category = 'general'
 where category = 'flotte' and question in (
   'Qu''est-ce qu''un avion à train classique ?',
   'Qu''est-ce qu''un avion à train tricycle ?',
   'Sur un avion à aile haute, où se trouvent en général les réservoirs ?',
   'Pourquoi un avion à aile basse a-t-il une pompe à carburant électrique de secours ?');



-- 2. Banque de questions (posée une seule fois) ----------------------------------
do $seed$ begin
  if not public._seed_once('quiz-flotte-35') then return; end if;
  insert into public.quiz_questions (question, option_a, option_b, option_c, option_d, correct, explanation, category)
  select v.question, v.option_a, v.option_b, v.option_c, v.option_d, v.correct, v.explanation, v.category
  from (values
    ('Quelle est la masse maximale au décollage du Robin DR400/180 F-HCLI ?', '900 kg', '1045 kg', '1200 kg', '1100 kg', 'd', 'Manuel de vol DR400/180 : 1100 kg au décollage et 1045 kg à l''atterrissage.', 'flotte'),
    ('Quelle est la masse maximale à l''atterrissage du Robin DR400/180 F-HCLI ?', '1100 kg', '1000 kg', '1045 kg', '900 kg', 'c', 'Le manuel limite l''atterrissage à 1045 kg : après un décollage à 1100 kg, il faut avoir consommé du carburant avant de se poser.', 'flotte'),
    ('Quel vent de travers démontré le manuel du DR400/180 indique-t-il ?', '12 kt', '22 kt', '15 kt', '30 kt', 'b', 'C''est le plus élevé de la flotte du club, au décollage comme à l''atterrissage.', 'flotte'),
    ('Dans quelle unité les vitesses sont-elles données dans le manuel du DR400/180 ?', 'En km/h', 'En nœuds', 'En mph', 'En m/s', 'a', 'Attention à la conversion : par exemple 130 km/h correspondent à environ 70 kt.', 'flotte'),
    ('Selon le manuel du DR400/180, à quelle vitesse l''avion décolle-t-il ?', 'Environ 60 km/h', 'Environ 100 km/h (54 kt)', 'Environ 160 km/h', 'Environ 200 km/h', 'b', 'Section 5 du manuel : décollage vers 100 km/h, passage des 15 m vers 130 km/h.', 'flotte'),
    ('Selon le manuel du DR400/180, quelle vitesse au passage des 15 m à l''atterrissage ?', '125 km/h (68 kt)', '95 km/h', '150 km/h', '110 km/h', 'a', 'La vitesse d''impact (toucher) indiquée est d''environ 95 km/h (51 kt).', 'flotte'),
    ('Quels crans de volets le manuel du DR400/180 utilise-t-il pour ses performances ?', 'Volets rentrés au décollage et à l''atterrissage', '2e cran au décollage, 1er cran à l''atterrissage', '1er cran au décollage, 2e cran à l''atterrissage', 'Volets sortis à fond dans les deux cas', 'c', 'Ce sont les configurations dans lesquelles les distances du manuel ont été établies.', 'flotte'),
    ('DR400/180 à 1100 kg, au niveau de la mer, en atmosphère standard, sans vent, piste en dur : distance de décollage jusqu''à 15 m ?', 'Environ 250 m', 'Environ 800 m', 'Environ 515 m', 'Environ 330 m', 'c', 'Le roulement vaut environ 250 m. Le guide ENAC conseille une marge d''environ 20 % sur ces valeurs.', 'flotte'),
    ('DR400/180 à 1045 kg, niveau de la mer, atmosphère standard, sans vent, piste en dur : distance d''atterrissage depuis 15 m ?', 'Environ 250 m', 'Environ 900 m', 'Environ 400 m', 'Environ 530 m', 'd', 'Section 5 du manuel ; le roulement seul vaut environ 250 m.', 'flotte'),
    ('Quelle majoration le manuel du DR400/180 prévoit-il pour une piste en herbe ?', '+50 %', '+15 %', 'Aucune', '+5 %', 'b', 'La correction herbe s''ajoute aux corrections d''altitude, de température et de vent.', 'flotte'),
    ('Quelle correction pour le vent arrière dans le manuel du DR400/180 ?', '+1 % par kt', 'Aucune', '+50 % dès 1 kt', '+10 % par tranche de 2 kt', 'd', 'Quelques nœuds de vent arrière suffisent donc à allonger nettement les distances.', 'flotte'),
    ('Quelle est la capacité du réservoir principal du DR400/180 F-HCLI (masse et centrage du site) ?', '50 litres', '110 litres', '200 litres', '80 litres', 'b', 'S''y ajoutent les réservoirs d''aile, 80 litres au total, avec un autre bras de levier.', 'flotte'),
    ('Quelle est la masse maximale au décollage du WT9 Dynamic F-HVXD ?', '750 kg', '472,5 kg', '600 kg', '1100 kg', 'c', 'Le manuel donne ses performances à cette masse unique de 600 kg.', 'flotte'),
    ('Quel vent de travers démontré retient-on pour le WT9 Dynamic ?', '22 kt', '12 kt', '15 kt', '25 kt', 'c', 'Valeur retenue par le club au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du WT9 Dynamic, quelle est la vitesse de décollage (Vlof) ?', '80 km/h (43 kt)', '120 km/h', '60 km/h', '100 kt', 'a', 'Le passage des 50 ft se fait à 100 km/h (54 kt).', 'flotte'),
    ('Selon le manuel du WT9 Dynamic, quelle est la vitesse de décrochage en configuration atterrissage (Vso) ?', '90 km/h', '45 km/h', '61 km/h (33 kt)', '120 km/h', 'c', 'Les vitesses du manuel du WT9 sont données en km/h.', 'flotte'),
    ('Que prévoit le manuel du WT9 Dynamic pour le vent de face dans le calcul des distances ?', 'Aucune réduction de distance', '-15 % par 5 kt', '-50 % dès 10 kt', '-1 % par kt', 'a', 'Le manuel ne donne qu''une pénalité de vent arrière : le vent de face n''est pas pris en compte (marge supplémentaire).', 'flotte'),
    ('WT9 Dynamic à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance de décollage jusqu''à 50 ft ?', 'Environ 263 m', 'Environ 515 m', 'Environ 136 m', 'Environ 600 m', 'a', 'Le roulement vaut environ 136 m ; sur herbe la distance passe à environ 285 m.', 'flotte'),
    ('Quelle est la capacité carburant du WT9 Dynamic F-HVXD (masse et centrage du site) ?', '80 litres', '128 litres', '190 litres', '50 litres', 'a', 'C''est la plus petite capacité de la flotte, à prendre en compte dans le devis carburant.', 'flotte'),
    ('Qui construit le PS-28 Cruiser du club ?', 'Robin', 'Czech Sport Aircraft', 'Diamond', 'Aerospool', 'b', 'Le PS-28 Cruiser est un biplace LSA construit en République tchèque.', 'flotte'),
    ('Quelle est la masse maximale au décollage du PS-28 Cruiser ?', '600 kg', '750 kg', '900 kg', '472,5 kg', 'a', 'Masse maximale au décollage et à l''atterrissage : 600 kg (manuel de vol, section 2).', 'flotte'),
    ('Quel vent de travers démontré le manuel du PS-28 Cruiser indique-t-il ?', '22 kt', '20 kt', '30 kt', '12 kt', 'd', 'C''est le plus faible de la flotte : prudence par vent de travers.', 'flotte'),
    ('Quel vent de face maximal démontré le manuel du PS-28 Cruiser indique-t-il ?', '24 kt', '12 kt', '40 kt', '10 kt', 'a', 'Le vent de travers démontré est, lui, de 12 kt.', 'flotte'),
    ('Selon le manuel du PS-28 Cruiser, à quelle vitesse fait-on la rotation ?', 'Entre 60 et 65 kt', 'Vers 80 kt', 'Vers 30 kt', 'Entre 40 et 44 kt', 'd', 'La montée se fait ensuite à Vy, 62 kt.', 'flotte'),
    ('Quelle est la vitesse de meilleur taux de montée (Vy) du PS-28 Cruiser ?', '44 kt', '80 kt', '100 kt', '62 kt', 'd', 'Valeur du manuel de vol, utilisée pour la montée normale.', 'flotte'),
    ('Quelle est la vitesse de décrochage en configuration atterrissage (Vso) du PS-28 Cruiser ?', '31 kt', '44 kt', '49 kt', '60 kt', 'a', 'C''est la plus faible de la flotte du club.', 'flotte'),
    ('PS-28 Cruiser à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance de décollage jusqu''à 15 m ?', 'Environ 141 m', 'Environ 387 m', 'Environ 515 m', 'Environ 700 m', 'b', 'Le roulement vaut environ 141 m ; sur herbe, le manuel donne environ 457 m.', 'flotte'),
    ('PS-28 Cruiser à 600 kg, niveau de la mer, atmosphère standard, piste en dur : distance d''atterrissage depuis 15 m ?', 'Environ 146 m', 'Environ 530 m', 'Environ 362 m', 'Environ 900 m', 'c', 'Le manuel ne donne qu''une valeur de référence : il faut majorer pour l''altitude, la chaleur et le vent.', 'flotte'),
    ('Quelle charge maximale dans le coffre à bagages arrière du PS-28 Cruiser ?', '60 kg', '18 kg', '5 kg', '40 kg', 'b', 'Le coffre arrière est limité à 18 kg ; la masse et centrage du site reprend cette limite.', 'flotte'),
    ('Entre quelles valeurs se situe le domaine de centrage du PS-28 Cruiser ?', 'Entre 420 et 525 mm du point de référence (28 à 35 % de la corde moyenne)', 'Entre 100 et 200 mm', 'Entre 1,7 et 1,8 m', 'Il n''y a pas de limite', 'a', 'Le site vérifie que le centre de gravité reste dans ce domaine au décollage comme sans carburant.', 'flotte'),
    ('Quel écran équipe le PS-28 F-HSAA d''après sa documentation ?', 'Un Garmin G1000', 'Aucun écran', 'Un Garmin G3X', 'Un Dynon (D1000)', 'd', 'Le manuel du Dynon D1000 est rangé dans les documents de l''avion sur le site.', 'flotte'),
    ('Quel instrument numérique équipe les PS-28 F-HNLR et F-HSAC d''après leur documentation ?', 'Un Garmin G1000', 'Un uAvionix AV-30', 'Un horizon à dépression', 'Aucun', 'b', 'Les manuels de l''AV-30 sont disponibles dans les documents de ces avions sur le site.', 'flotte'),
    ('Quelle suite avionique équipe le Bristell B23 F-HUFA ?', 'Un Dynon D1000', 'Un Garmin G3X', 'Des instruments classiques uniquement', 'Un Garmin G1000 NXi', 'b', 'Un guide rapide et le manuel d''utilisation du G3X sont dans les documents de l''avion.', 'flotte'),
    ('Que désigne le « 915 » du Bristell B23-915 du club ?', 'Sa masse maximale', 'Son numéro de série', 'Son moteur Rotax 915 iS', 'Sa vitesse maximale en km/h', 'c', 'Le B23-915 est motorisé par un Rotax 915 iS turbocompressé.', 'flotte'),
    ('Quelle est la masse maximale au décollage du Bristell B23 F-HUFA ?', '600 kg', '1100 kg', '750 kg', '900 kg', 'c', 'Les performances du manuel sont données à cette masse de 750 kg.', 'flotte'),
    ('Quel vent de travers démontré le manuel du Bristell B23 indique-t-il ?', '12 kt', '22 kt', '15 kt', '20 kt', 'c', 'Valeur valable au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle est la vitesse de décollage ?', '45 KIAS', '80 KIAS', '100 KIAS', '60 KIAS', 'd', 'Le passage des 50 ft se fait à 70 KIAS.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle vitesse d''approche finale ?', '70 KIAS', '44 KIAS', '58 KIAS', '80 KIAS', 'c', 'La vitesse de décrochage en configuration atterrissage (Vso) est de 44 KIAS.', 'flotte'),
    ('Selon le manuel du Bristell B23, quelle correction de vent de face au décollage ?', '-5 % par tranche de 5 kt', 'Aucune', '-15 % par tranche de 5 kt', '-50 % dès 10 kt', 'c', 'Par vent arrière, le manuel ajoute 20 % par tranche de 5 kt. À l''atterrissage : -5 % et +10 % par 5 kt.', 'flotte'),
    ('Quel facteur le manuel du Bristell B23 applique-t-il pour une piste en herbe au décollage ?', '×1,50', '×1,14', '×1,02', '×2', 'b', 'À l''atterrissage, le facteur herbe est de ×1,18. Ces corrections portent sur la distance jusqu''à 50 ft.', 'flotte'),
    ('Quelle est la capacité carburant du Bristell B23 F-HUFA (masse et centrage du site) ?', '80 litres', '190 litres', '50 litres', '120 litres', 'd', 'Le carburant est logé dans les ailes.', 'flotte'),
    ('Quel vent de travers démontré le manuel du Diamond DA40 indique-t-il ?', '12 kt', '15 kt', '30 kt', '20 kt', 'd', 'Valeur retenue par le club au décollage et à l''atterrissage.', 'flotte'),
    ('Selon le manuel du DA40, quelle vitesse d''approche à 1150 kg ?', '71 KIAS', '58 KIAS', '90 KIAS', '49 KIAS', 'a', 'La vitesse de montée initiale indiquée par le manuel est de 67 KIAS.', 'flotte'),
    ('DA40 à 1150 kg, niveau de la mer, atmosphère standard, sans vent, volets atterrissage : distance d''atterrissage depuis 15 m ?', 'Environ 352 m', 'Environ 638 m', 'Environ 300 m', 'Environ 1000 m', 'b', 'Le roulement vaut environ 352 m. C''est la plus longue distance d''atterrissage de la flotte.', 'flotte'),
    ('Selon le manuel du DA40, de combien majorer le roulement au décollage sur herbe courte et sèche ?', '50 %', '0 %', '25 %', '10 %', 'd', 'À l''atterrissage, la majoration du roulement sur herbe est de 5 %.', 'flotte'),
    ('Parmi les avions du club, lequel a le vent de travers démontré le plus faible ?', 'Le DR400/180', 'Le PS-28 Cruiser (12 kt)', 'Le DA40', 'Le Bristell B23', 'b', 'DR400 : 22 kt ; DA40 : 20 kt ; WT9 et B23 : 15 kt ; PS-28 : 12 kt.', 'flotte'),
    ('Parmi les avions du club, lesquels ont des manuels donnant les vitesses en km/h ?', 'Le DA40 et le B23', 'Le PS-28 et le DA40', 'Tous', 'Le DR400/180 et le WT9 Dynamic', 'd', 'Les manuels du DA40, du B23 et du PS-28 donnent les vitesses en nœuds : attention aux conversions en passant d''un avion à l''autre.', 'flotte'),
    ('Parmi les avions du club, lesquels sont des quadriplaces ?', 'Le DR400/180 et le DA40', 'Le PS-28 et le WT9', 'Le B23 et le DA40', 'Tous', 'a', 'Le PS-28 Cruiser, le WT9 Dynamic et le Bristell B23 sont des biplaces.', 'flotte')
  ) as v(question, option_a, option_b, option_c, option_d, correct, explanation, category)
  where not exists (select 1 from public.quiz_questions x where lower(btrim(x.question)) = lower(btrim(v.question)));
end $seed$;

notify pgrst, 'reload schema';

-- Vérification
select
  (select count(*) from public.quiz_questions where category = 'flotte') as "questions Flotte",
  exists (select 1 from public._seeds where name = 'quiz-flotte-35') as "MISE A JOUR 35 OK";
