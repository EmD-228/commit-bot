# Commit Bot

Génère une activité GitHub _organique_ — sans tricher tous les jours.

<br>

<p align="center">
  <img width="90%" src="./the-dream.png" alt="Le rêve du graphe de contributions">
</p>

<br>

Une fois par jour (si mon laptop est ouvert à 22h),
<br>commit-bot ajoute la ligne du jour :

```
Commit: Wed Sep 25 22:00:00 EDT 2026
```

C'est un script Bash
<br>conçu pour tourner **sur ta machine**
<br>(pas sur un serveur)

<br><br>

> Mais pourquoi pas un serveur qui commit tous les jours ?

Parce que **personne ne commit vraiment tous les jours**.
<br>Un graphe trop parfait, ça se voit.

L'idée : le cron tourne à 22h **uniquement si ta machine est allumée**.
<br>Ça produit une distribution naturelle, avec des trous,
<br>comme la vie de n'importe quel dev.

<br><br>

## Mise en route

> Sur Windows, installe d'abord [WSL](https://docs.microsoft.com/en-us/windows/wsl/install-win10).

[Installe `git`](https://github.com/git-guides/install-git) si `git --version` ne fonctionne pas.

<br>

1. Ouvre ton terminal et place-toi où tu veux cloner le projet.

2. Clone ton fork :

```shell
git clone https://github.com/EmD-228/commit-bot.git
```

3. Teste le script (utile pour régler d'éventuels soucis de permissions) :

```shell
/bin/bash ./commit-bot/bot.sh
```

4. Ouvre ton crontab :

```shell
crontab -e
```

> Si l'écran devient presque vide sans menu visible, tu es dans **Vim**.
> <br>Appuie sur `i` pour passer en mode insertion.
> <br>Quand tu as fini, appuie sur `Esc` puis tape `:wq` pour sauvegarder et quitter
> <br>(ou `:q!` pour quitter sans sauvegarder).

5. Ajoute cette ligne pour [déclencher tous les jours à 22h](https://crontab.guru/#0_22_*_*_*) :

```shell
0 22 * * * /bin/bash /<chemin-absolu-vers-le-dossier>/commit-bot/bot.sh
```

> Vérifie ton installation avec :
>
> ```shell
> crontab -l
> ```
>
> La ligne ajoutée doit s'afficher.

<br><br>

## Crédits

Maintenu par **Kokou DENYO** ([@EmD-228](https://github.com/EmD-228)).

Basé sur le projet original de **Steven Kneiser** ([@theshteves](https://github.com/theshteves/commit-bot)) — licence MIT.
