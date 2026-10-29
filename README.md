# OrbitDisk

Le projet principal est **`OrbitDisk.xcodeproj`**. Ouvrez-le dans Xcode, sélectionnez le schéma `OrbitDisk`, puis utilisez **Run** ou **Test**.

Le manifeste Swift Package reste disponible pour les lancements rapides depuis le terminal :

```bash
swift run OrbitDisk
```

OrbitDisk force alors son activation au premier plan, comme lors d’un lancement depuis Xcode ou Finder.

OrbitDisk est un analyseur d’espace disque natif pour macOS, inspiré du principe de navigation visuelle de DaisyDisk mais doté de son propre nom, de sa propre interface et de ses propres assets.

## Fonctionnalités

- analyse récursive locale d’un volume ou d’un dossier ;
- carte circulaire interactive sur quatre niveaux ;
- navigation dans l’arborescence et classement par taille ;
- aperçu de la taille et du nombre d’éléments ;
- ouverture dans le Finder ;
- déplacement prudent vers la corbeille avec confirmation ;
- gestion des dossiers non lisibles et annulation d’un scan.

## Lancer

```bash
swift run OrbitDisk
```

## Tester

```bash
swift test
```

## Créer l’application macOS

```bash
chmod +x Scripts/package_app.sh
Scripts/package_app.sh
open dist/OrbitDisk.app
```

Le premier scan de certains dossiers peut nécessiter d’accorder à OrbitDisk l’accès correspondant dans macOS. Les liens symboliques ne sont pas suivis, ce qui évite les boucles et les doubles comptages.
