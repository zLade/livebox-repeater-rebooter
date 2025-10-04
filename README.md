# Orange Repeater Auto-Rebooter (Docker + Web UI)

Planifie un **redémarrage automatique hebdomadaire** des répéteurs **Orange / Livebox**.
Une petite **interface Web** permet de configurer l’IP, les identifiants puis de planifier le redémarrage (jour + heure). Le service **journalise** tout (ping avant → reboot → attente → ping après).

## Matériel testé

- **Modèle** : `ModèleWifi_6_Repeater`
- **Version Boot** : `20.04.16`
- **Version du logiciel** : `SR6R-fr-03.02.04.18`
- **Version du matériel** : `SERCREPREM_1_0_3`

> D’autres modèles Livebox/Repeater compatibles **API SAH** devraient fonctionner, à condition d’ajuster les commandes `curl` (RAW_CURL).

## Principe (API SAH)

1. Authentification via `sah.Device.Information.createContext` → récupération d’un **contextID**.
2. Reboot via `POST /ws` : service `NMC`, méthode `reboot`, en envoyant le **contextID** (entêtes `Authorization: X-Sah <contextID>` et `X-Context`).
3. Le script **ping** l’appareil avant/après et consigne les étapes dans un log texte.

## Points clés

- **UI Web** (port par défaut `3333`) pour renseigner : IP, username, password, **RAW_CURL** login & reboot, **jour/heure**, lecture des **logs**.
- Mettre le répéteur Wifi en IP Fixe via le DHCP de la livebox (ou votre dhcp)
- **Logs** persistants : `logs/rebooter.log` (affichés aussi dans l’UI).

## Déploiement rapide (Docker)

1. Cloner/copier le projet (ex. `/volume1/docker/rebooter`).
2. (Recommandé) Monter les dossiers en volumes : `server/`, `scripts/`, `logs/`.
3. Utiliser ce `docker-compose.yml` minimal :

   ```yaml
version: "3.9"
services:
  rebooter:
    build:
      context: /volume1/docker/rebooter
      dockerfile: Dockerfile
    container_name: repeater-rebooter
    ports:
      - "3333:3333"
    environment:
      - TZ=Europe/Paris
      - PORT=3333
    volumes:
      - /volume1/docker/rebooter/server/config.json:/app/server/config.json
      - /volume1/docker/rebooter/server/views:/app/server/views
      - /volume1/docker/rebooter/scripts:/app/scripts        
      - /volume1/docker/rebooter/logs:/app/logs
    restart: unless-stopped

   ```

4. Lancer :

   ```bash
   docker compose up -d --build
   ```

5. Ouvrir `http://<hôte>:3333`, saisir **IP / identifiants**

## Sécurité

- Les identifiants sont stockés en clair dans `server/config.json` (utiliser des permissions restrictives / réseau de confiance).

## Limitations

- Conçu pour les firmwares **SAH** (Livebox/Repeater). Les headers/URLs exacts peuvent varier selon les versions — ajuster les `curl` si besoin.
