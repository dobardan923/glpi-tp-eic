
# GLPI TP EIC

Scripts de préparation des environnements GLPI 12 pour les cours :

- Diagnostiquer et résoudre un dysfonctionnement
- Utiliser un outil de gestion de parc informatique

## Environnement

- AlmaLinux
- GLPI 12
- API REST legacy
- Une machine virtuelle par étudiant

## Objectifs

- Préparer les données des travaux pratiques
- Faciliter le rattrapage des élèves absents
- Distribuer progressivement de nouveaux exercices
- Éviter la création de doublons
- Conserver les travaux déjà réalisés

## Organisation prévue

- `modules/` : utilisateurs, lieux, parc, tickets
- `scenarios/` : exercices pratiques de dépannage
- `lib/` : fonctions communes et communication API

## Sécurité

Aucun mot de passe administrateur ou token API ne doit être publié dans ce dépôt.
