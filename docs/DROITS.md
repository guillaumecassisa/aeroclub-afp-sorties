# Tableau des droits

Tout compte validé est **membre** ; chaque fonction attribuée dans ⚙️ Gestion → Membres et droits
ajoute des droits. Un membre peut cumuler plusieurs fonctions : il a alors la somme des droits.
Les règles sont appliquées **par la base de données** (RLS et fonctions sécurisées), pas seulement
par l'affichage : contourner le site ne permet pas de les enfreindre.

Toute personne ayant au moins une fonction est un **organisateur** : elle crée et publie des
événements sans validation et gère les documents des avions.

## Les fonctions

| Fonction | Attribuée par | Ce qu'elle ajoute |
|---|---|---|
| Membre | Validation du compte par un admin | Accès au site : événements, flotte, bar, shop, quiz, pédagogie (lecture) |
| Instructeur | Admin | Organisateur + valide ou refuse les propositions d'événements ; compte comme « instructeur à bord » |
| Trésorier | Admin | Organisateur + bar de tous les membres, règlements, prix, statistiques |
| Resp. maintenance | Admin | Organisateur + disponibilité des avions, données de masse et centrage |
| Chef pilote / Resp. conformité | Admin | Organisateur + publication dans l'Espace pédagogique, analyse des REX, questions du quiz |
| Admin / Secrétaire | Admin | Tous les droits ci-dessous sauf ceux réservés au trésorier ; le secrétaire a les droits admin |

Légende des colonnes : **Mb** membre · **Ins** instructeur · **Tré** trésorier · **Mnt** resp. maintenance ·
**CP** chef pilote / resp. conformité · **Adm** admin / secrétaire.

## Comptes et administration

Un compte créé reste « en attente » et ne voit rien du site tant qu'un admin ne l'a pas validé.

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Modifier son profil, son poids, ses lâchers | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Exporter ses données, demander la suppression de son compte | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Consulter l'annuaire des membres | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Valider un nouveau compte | — | — | — | — | — | ✓ |
| Attribuer ou retirer une fonction | — | — | — | — | — | ✓ (pas ses propres droits admin) |
| Effacer les données d'un membre (RGPD) | — | — | — | — | — | ✓ (pas son propre compte) |
| Informations du club, liens utiles | — | — | — | — | — | ✓ |
| Journal des modifications, sauvegarde | — | — | — | — | — | ✓ |

## Événements

Un membre sans fonction **propose** ; sa proposition n'est visible qu'après validation par un
instructeur ou un admin. Une fois publiée, il en devient l'**organisateur** et gère ses participants
(« le sien »). Les mêmes règles valent pour les projets sans date.

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Voir les événements publiés, s'inscrire, se désinscrire | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ajouter un +1 (si l'organisateur l'autorise) | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Proposer un événement (soumis à validation) | ✓ | — | — | — | — | — |
| Modifier ou retirer sa proposition non encore validée | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Créer et publier directement | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Valider ou refuser une proposition | — | ✓ | — | — | — | ✓ |
| Modifier un événement publié (dont fixer la date d'un projet) | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Annuler un événement publié | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Inscrire un autre membre | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Répartir les équipages, placer la liste d'attente dans un avion | le sien | ✓ | ✓ | ✓ | ✓ | ✓ |
| Autoriser ou non les +1, retirer un participant | le sien | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ajouter, changer ou retirer l'affiche d'un événement | le sien | ✓ | ✓ | ✓ | ✓ | ✓ |
| Voir le téléphone des inscrits | le sien | ✓ | — | — | — | ✓ |

Sortie avion : un membre non lâché sur le type d'avion n'y est placé que si un instructeur est à bord.

## Espace pédagogique et quiz

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Lire les documents et annonces pédagogiques | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Publier ou archiver un document, une annonce pédagogique | — | — | — | — | ✓ | ✓ |
| Déposer un REX (anonyme ou non), voir les siens et les REX publiés | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Voir tous les REX déposés, les analyser, les publier | — | — | — | — | ✓ | ✓ |
| Proposer une séance de formation | ✓ | — | — | — | — | — |
| Programmer une formation directement | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Répondre aux 3 questions du jour, voir ses résultats (Mon compte) et le top 5 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ajouter, modifier, désactiver, supprimer des questions du quiz | — | — | — | — | ✓ | ✓ |

## Flotte et préparation des vols

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Voir la flotte et les documents des avions | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Masse et centrage, performances, préparer son vol | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ajouter, modifier, supprimer un document d'avion | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Flotte (maintenance) : avions, disponibilité | — | — | — | ✓ | — | ✓ |
| Modifier les données de masse et centrage d'un avion | — | — | — | ✓ | — | ✓ |

## Bar, shop et statistiques

Le bar de tous les membres est réservé au trésorier : un admin qui doit y accéder se fait aussi
attribuer la fonction Trésorier. La gestion du shop est réservée aux admins.

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Noter ses consommations, voir son ardoise | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Annuler sa consommation | 30 min | 30 min | ✓ (mois non réglé) | 30 min | 30 min | 30 min |
| Noter une consommation pour un autre membre | — | — | ✓ | — | — | — |
| Gestion du bar : tableau de bord, ardoises, relances, carte et prix, export Excel | — | — | ✓ | — | — | — |
| Statistiques (chiffre d'affaires) | — | — | ✓ | — | — | ✓ |
| Commander au shop, voir ses commandes | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Annuler sa commande tant qu'elle est en attente | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Gestion du shop : commandes, stock, catalogue, export Excel | — | — | — | — | — | ✓ |
| Activer / désactiver « Bientôt disponible » sur le shop | — | — | — | — | — | ✓ |

## Annonces, bons plans et partage de vols

| Action | Mb | Ins | Tré | Mnt | CP | Adm |
|---|---|---|---|---|---|---|
| Lire les annonces du club | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Publier ou supprimer une annonce du club | — | ✓ | ✓ | ✓ | ✓ | ✓ |
| Ajouter un bon plan sur un terrain | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Archiver un bon plan | — | — | — | — | — | ✓ |
| Partage de vols : publier un vol, rejoindre, se retirer | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Clore ou annuler un vol partagé | le sien | le sien | le sien | le sien | le sien | ✓ |
| Partager des photos de vol, voir la galerie | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Supprimer une photo de vol | les siennes | les siennes | les siennes | les siennes | les siennes | ✓ |

> Où c'est appliqué : `lib/auth.ts` (affichage) et, dans la base, les fonctions `is_approved`,
> `is_staff`, `can_organize`, `can_teach`, `can_manage_fleet`, `can_manage_docs`, `is_treasurer`
> utilisées par les règles RLS et les fonctions `security definer`. Si une règle change, mettez ce
> tableau à jour dans le même commit.
