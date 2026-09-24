# Habitudes

Habit tracker partagé: chacun voit les habitudes des autres, en direct, et ne peut modifier que les siennes.

- Appli: `index.html` (une page, sans build), servie par GitHub Pages.
- Données: Supabase (projet `habitudes`, org « Habitudes », plan gratuit).
- Sécurité: `schema.sql`. Les règles RLS font que tout le monde lit tout, et chacun n'écrit que ses propres lignes.
- `config.js` contient la clé *publishable*, faite pour être publique.

Pour publier un changement: `git push`. Tout le monde a la nouvelle version à la prochaine ouverture.
