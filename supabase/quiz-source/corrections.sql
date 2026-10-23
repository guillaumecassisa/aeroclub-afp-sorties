-- 2. Questions d'origine : réponses fausses ou ambiguës corrigées --------------------
--    Chaque correction ne s'applique que si la question est encore dans sa version
--    d'origine (une question déjà retouchée depuis le site n'est pas modifiée).
update public.quiz_questions set
  correct = 'a',
  explanation = 'Le QNH est la pression mesurée sur l''aérodrome, ramenée au niveau moyen de la mer avec les caractéristiques de l''atmosphère standard. Calé sur le QNH, l''altimètre indique l''altitude de l''aérodrome une fois au sol.'
 where question = 'Quelle est la définition du QNH ?' and correct = 'b'
   and option_a = 'Pression au niveau de la mer calculée avec une atmosphère standard';

update public.quiz_questions set
  option_a = '-1,98°C / 1000 ft', option_b = '-0,65°C / 1000 ft', option_c = '-3,5°C / 1000 ft', option_d = '-1°C / 1000 ft',
  correct = 'a'
 where question = 'Le gradient de température standard de l''ISA est de :' and option_a = '-2°C / 1000 ft';

update public.quiz_questions set
  question = 'En France, au-dessus du FL195, l''espace aérien est en règle générale de classe :',
  option_a = 'A', option_b = 'C', option_c = 'E', option_d = 'G',
  correct = 'b',
  explanation = 'Depuis la mise en place de l''espace aérien supérieur harmonisé, l''espace situé au-dessus du FL195 est de classe C en France. Le vol VFR y est en principe interdit, sauf dérogation.'
 where question = 'Quelle est la limite inférieure de la classe A en France métropolitaine ?' and correct = 'a';

update public.quiz_questions set
  question = 'En classe G, au-dessous de 3000 ft AMSL (ou 1000 ft au-dessus du sol si c''est plus haut), quelle est la visibilité minimale VFR de base fixée par la réglementation SERA ?',
  option_a = '5 km', option_b = '8 km', option_c = '10 km', option_d = '800 m',
  correct = 'a',
  explanation = 'Le minimum de base est 5 km, hors des nuages et en vue de la surface. Il peut être abaissé à 1500 m pour un avion volant à 140 kt ou moins quand l''autorité le permet, ce qui est le cas en France.'
 where question = 'En VFR, quelle est la visibilité minimale en dessous de 3000 ft AMSL hors espace contrôlé ?' and correct = 'a'
   and option_a = '1,5 km';

update public.quiz_questions set
  explanation = 'En classe D, le contact radio bilatéral et la clairance du contrôle sont obligatoires pour tous les vols, VFR compris. Les VFR reçoivent l''information de trafic sur les autres vols.'
 where question like 'Un pilote VFR en classe D doit établir une communication radio bilatérale%' and correct = 'b'
   and explanation like '%la clairance ATC n''est pas requise%';

update public.quiz_questions set
  question = 'Au-dessus d''une agglomération, quelle est la hauteur minimale de survol en VFR (règle générale SERA) ?',
  option_a = '300 m (1000 ft) au-dessus de l''obstacle le plus élevé dans un rayon de 600 m',
  option_b = '150 m (500 ft) au-dessus du sol',
  option_c = '150 m au-dessus de l''obstacle le plus élevé dans un rayon de 150 m',
  option_d = '50 m au-dessus des toits',
  correct = 'a',
  explanation = 'Règle SERA : 300 m (1000 ft) au-dessus de l''obstacle le plus élevé situé dans un rayon de 600 m autour de l''aéronef. En France, des hauteurs plus importantes sont imposées au-dessus des grandes agglomérations (voir la carte et l''AIP).'
 where question = 'Quelle est la hauteur minimale VFR au-dessus des agglomérations ?' and correct = 'a'
   and option_a like '150 m%';

update public.quiz_questions set
  question = 'Deux avions convergent à peu près à la même altitude. Lequel doit céder le passage ?',
  option_a = 'Le plus rapide', option_b = 'Celui qui voit l''autre sur sa gauche',
  option_c = 'Celui qui voit l''autre sur sa droite', option_d = 'Le plus léger',
  correct = 'c',
  explanation = 'Règle de l''air : en route convergente, l''aéronef qui voit l''autre sur sa droite s''écarte. Face à face, chacun vire à droite.'
 where question like 'La règle de l''air VFR basique%' and correct = 'b';

update public.quiz_questions set
  option_a = 'Relèvement magnétique de l''avion vu depuis la station (QDR)'
 where question = 'Qu''est-ce que le QDM ?' and option_a = 'Relèvement magnétique de la station par rapport à l''avion';

update public.quiz_questions set
  option_a = 'L''écart entre l''altitude prévue et l''altitude réelle'
 where question = 'Qu''est-ce que la dérive en navigation ?' and option_a = 'Différence entre le cap et le route';

update public.quiz_questions set
  option_a = 'Poussée et traînée'
 where question = 'La finesse d''un avion est le rapport entre :' and option_a = 'Portance et traînée';

update public.quiz_questions set
  question = 'Quel phénomène le carburateur peut-il subir, même par température extérieure positive et air humide ?'
 where question = 'Qu''est-ce que le carburateur en hiver peut provoquer ?';

update public.quiz_questions set
  question = 'Quelle est l''altitude de l''aérodrome d''Aix-les-Milles (LFMA) ?',
  option_a = '124 ft', option_b = '368 ft', option_c = '95 ft', option_d = '980 ft',
  correct = 'b',
  explanation = 'D''après la carte VAC LFMA, l''altitude de l''aérodrome est 368 ft, soit une correction QNH-QFE d''environ 14 hPa.'
 where question = 'À quelle altitude se trouve l''aérodrome de LFMA ?' and correct = 'd';

update public.quiz_questions set
  question = 'Quelle est l''orientation de la piste revêtue de LFMA ?',
  correct = 'c',
  explanation = 'La piste d''Aix-les-Milles est la 14/32 (QFU 143° et 323°, carte VAC LFMA).'
 where question = 'Quelle est l''orientation de la piste principale de LFMA ?' and correct = 'a';

update public.quiz_questions set
  question = 'Quelle est la distance d''atterrissage utilisable (LDA) en piste 14 à LFMA ?',
  option_a = '1481 m', option_b = '1248 m', option_c = '1830 m', option_d = '1124 m',
  correct = 'b',
  explanation = 'D''après la carte VAC (AIP France, AD 2 LFMA, AMDT 11/26), la LDA est de 1248 m en piste 14 et de 1124 m en piste 32.'
 where question = 'Quelle est la LDA (Landing Distance Available) de la piste 13 à LFMA ?' and correct = 'c';

update public.quiz_questions set
  question = 'Quelle est la fréquence de la tour d''Aix-les-Milles (LFMA) ?',
  option_a = '118,105 MHz', option_b = '121,605 MHz', option_c = '118,755 MHz', option_d = '123,500 MHz',
  correct = 'c',
  explanation = 'AIX Tour : 118,755 (carte VAC LFMA, AMDT 11/26). Le sol est sur 121,605 et l''ATIS sur 136,230. Vérifiez toujours la VAC et les NOTAM en vigueur.'
 where question = 'Quelle est la fréquence de l''AFIS d''Aix-les-Milles (LFMA) ?' and correct = 'a';

update public.quiz_questions set
  question = 'Dans quel espace aérien se trouve l''aérodrome de LFMA ?',
  option_a = 'La CTR d''Aix, de classe D', option_b = 'La TMA de Nice', option_c = 'Un espace non contrôlé de classe G',
  option_d = 'Une CTR de classe A',
  correct = 'a',
  explanation = 'LFMA est au centre de la CTR AIX, de classe D, du sol à 2500 ft AMSL (AIP France). Contact radio et clairance y sont obligatoires.'
 where question = 'Quel type d''espace aérien entoure LFMA ?' and correct = 'a' and option_a like 'CTR de Marseille%';

update public.quiz_questions set
  option_a = 'Toujours à droite', option_b = 'Toujours face au nord',
  option_c = 'À gauche, sauf sens contraire publié (carte VAC)', option_d = 'Au choix du pilote',
  explanation = 'Par défaut, les virages du circuit se font à gauche. Le sens réel est celui publié pour chaque aérodrome (carte VAC), souvent choisi pour éviter les zones habitées ou le relief.'
 where question = 'Le circuit de piste standard se fait :' and correct = 'c';

update public.quiz_questions set
  question = 'Selon les bonnes pratiques enseignées en école, à quelle vitesse sol maximale roule-t-on habituellement sur les voies de circulation ?',
  option_a = 'Environ 10 kt (allure d''un homme qui marche vite)', option_b = '30 kt', option_c = '50 kt', option_d = 'Aucune limite',
  correct = 'a',
  explanation = 'Il n''y a pas de limite chiffrée générale, mais on roule à une vitesse permettant de s''arrêter immédiatement : environ 10 kt au maximum, moins sur l''aire de trafic.'
 where question = 'Quelle est la vitesse maximale en circulation (roulage) habituelle sur un aérodrome ?' and correct = 'a'
   and option_a = '30 kt';

update public.quiz_questions set
  question = 'La prise de pression totale (Pitot) et son orifice de purge sont bouchés, la prise statique est libre. En montée, l''anémomètre :',
  option_a = 'Indique une vitesse trop élevée', option_b = 'Indique une vitesse trop faible', option_c = 'Reste parfaitement juste',
  option_d = 'Tombe immédiatement à zéro',
  correct = 'a',
  explanation = 'La pression totale reste emprisonnée alors que la pression statique diminue en montée : l''écart augmente et l''anémomètre indique trop (il se comporte comme un altimètre). Si seule la prise Pitot est bouchée et la purge libre, l''indication tend vers zéro.'
 where question = 'Si la sonde Pitot est bouchée en montée, l''anémomètre :' and correct = 'c';

update public.quiz_questions set
  question = 'Quelle fréquence VHF est réservée aux communications air-air entre pilotes en France ?',
  option_a = '121,500 MHz', option_b = '123,450 MHz', option_c = '118,000 MHz', option_d = '123,500 MHz',
  correct = 'b',
  explanation = '123,450 MHz est la fréquence air-air. 123,500 MHz est la fréquence d''auto-information des aérodromes sans fréquence propre, 121,500 MHz la fréquence de détresse.'
 where question = 'Sur quelle fréquence doit être calée la radio VHF par défaut ?' and correct = 'b';

update public.quiz_questions set
  option_a = 'Toujours bimoteur'
 where question = 'Le Piper PA-28 Warrior est un avion :' and option_a = 'Bimotor à train tricycle rétractable';

update public.quiz_questions set
  question = 'Le moteur Lycoming O-320 qui équipe de nombreux avions école est un moteur :',
  option_a = '6 cylindres en ligne refroidi par liquide', option_b = 'Rotatif à pistons',
  option_c = '4 cylindres à plat (opposés) refroidi par air', option_d = 'Diesel 4 temps suralimenté',
  correct = 'c',
  explanation = 'Le « O » signifie « opposed » : 4 cylindres opposés à plat, refroidis par air, d''une cylindrée de 320 pouces cubes (environ 5,2 litres), pour 150 à 160 ch selon la version.'
 where question = 'La puissance du moteur Lycoming O-320 équipant de nombreux PA-28 est de :';

update public.quiz_questions set
  question = 'Que signifie le sigle ULM ?',
  option_a = 'Ultra-Léger Motorisé', option_b = 'Unité Légère de Manœuvre', option_c = 'Ultra-Long Moyen-courrier', option_d = 'Utilitaire Léger Monomoteur',
  correct = 'a',
  explanation = 'ULM signifie Ultra-Léger Motorisé. Ses limites de masse dépendent de la classe d''ULM et ont évolué : on se reporte à la réglementation en vigueur.'
 where question = 'Qu''est-ce qu''un aéronef ULM ?' and correct = 'b';

update public.quiz_questions set
  question = 'Quelle est la vitesse du son au niveau de la mer en atmosphère standard (15°C) ?',
  option_a = 'Environ 340 m/s', option_b = 'Environ 300 m/s', option_c = 'Environ 400 m/s', option_d = 'Environ 250 m/s',
  explanation = 'À 15°C, la vitesse du son vaut environ 340 m/s (661 kt, 1225 km/h). Elle diminue quand la température baisse.'
 where question = 'Quelle est la vitesse approximative du son à 0°C au niveau de la mer ?' and correct = 'a';

update public.quiz_questions set
  question = 'Qu''appelle-t-on l''« effet tunnel » en facteurs humains ?',
  explanation = 'L''effet tunnel est une focalisation de l''attention sur un seul élément (une panne, un instrument, la piste) au détriment de la surveillance globale : trajectoire, vitesse, trafic.'
 where question like 'Qu''est-ce que l''effet IMVP%';

update public.quiz_questions set
  question = 'Qu''est-ce que la déclinaison magnétique ?'
 where question = 'Qu''est-ce que la dérive magnétique (variation) ?';

update public.quiz_questions set
  option_c = 'La couleur du carburant, pour l''esthétique'
 where question = 'Que vérifie-t-on en drainant le carburant avant le vol ?' and option_c = 'La couleur du carburant pour la esthétique';

