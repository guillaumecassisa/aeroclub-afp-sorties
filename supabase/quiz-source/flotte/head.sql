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

