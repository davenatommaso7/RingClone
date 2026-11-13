# RingClone M1: procedura di cancellazione

Stato: bozza del 13 novembre 2026, non revisionata e mai eseguita sui dispositivi. Descrive il codice del commit `a9ee2077`.

In M1 l'app non ha una funzione interna di esportazione o cancellazione (decisione D-08): basta questa procedura, perché l'app non conserva valori sanitari.

## Che cosa c'è da cancellare

- Sull'iPhone: il registro diagnostico e gli eventuali file conservati con un altro nome, nella cartella `Diagnostica` dell'app. Vedi `CONSERVAZIONE.md`.
- Sull'Apple Watch: nulla.
- In iOS: le scelte sui permessi di lettura di Salute concesse all'app.

## Procedura

1. Sull'iPhone tenere premuta l'icona "Ring M1", scegliere di rimuovere l'app e confermare l'eliminazione. iOS elimina l'app e tutti i suoi file, compreso il registro diagnostico.
2. Controllare sull'Apple Watch che l'app "Ring M1" non ci sia più. Se c'è ancora, eliminarla dal Watch.
3. Aprire le impostazioni di Salute sull'iPhone, alla voce che elenca le app con accesso ai dati, e verificare che "Ring M1" non compaia più o che tutti i suoi permessi siano disattivati.

## Che cosa non viene cancellato, e perché

- I dati in Salute: non sono dell'app e l'app non li ha mai modificati.
- Le copie di sicurezza: la cartella del registro è esclusa, quindi non dovrebbero contenerne una copia.
- Il repository e i rapporti di compilazione su GitHub: non contengono dati personali di Salute.

## Togliere solo i permessi, senza rimuovere l'app

Nelle impostazioni di Salute si possono disattivare i singoli tipi per "Ring M1". Alla lettura successiva l'app mostra per quei tipi lo stato "Nessun campione nell'intervallo" e non può sapere che la lettura è stata negata.

## Limiti

- I nomi delle voci di menu di iOS possono cambiare con la versione del sistema.
- Che l'esclusione dalle copie di sicurezza sia effettiva non è stato verificato sul dispositivo.
- Con un canale di installazione come TestFlight possono esistere dati presso Apple (per esempio i rapporti di arresto): dipendono dalle decisioni D-02 e D-16, non ancora prese.
