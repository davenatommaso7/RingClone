# RingClone M1: conservazione dichiarata

Stato: bozza del 13 novembre 2026, non revisionata. Descrive il codice del commit `a9ee2077`. È stata ricavata dalla lettura del codice: nulla di quanto segue è stato verificato sui dispositivi.

## Che cosa l'app non conserva

- Nessun valore letto da Salute. I valori restano in memoria finché la schermata è aperta e vengono riletti a ogni apertura e a ogni "Rileggi" (decisione D-18).
- Nessun profilo personale, nessuno storico, nessuna preferenza.
- Nulla sull'Apple Watch: l'app del Watch mostra solo lo stato del collegamento.
- Nulla fuori dal dispositivo: l'app non ha chiamate di rete e non usa iCloud. Fra iPhone e Apple Watch non viene trasferito alcun dato.
- L'app non scrive mai in Salute.

## Che cosa l'app conserva

Un solo file, sull'iPhone: il registro diagnostico.

| Aspetto | Valore |
|---|---|
| Posizione | Cartella `Diagnostica` nell'area "Application Support" dell'app, file `registro-diagnostico.json` |
| Contenuto di ogni voce | Data e ora, tipo di evento (lettura presente; nessun campione o accesso non determinabile; errore di lettura; file conservato con un altro nome), identificativo del tipo di dato, dominio e numero dell'errore |
| Che cosa non contiene | Valori, conteggi, sorgenti, intervalli dei campioni |
| Quando si scrive | Solo quando lo stato di un tipo cambia rispetto all'ultima voce di quel tipo |
| Versione di schema | 1 |
| Durata | 30 giorni (decisione D-06). Le voci più vecchie vengono tolte alla lettura successiva |
| Protezione | Completa: il file non è leggibile a dispositivo bloccato |
| Copie di sicurezza | La cartella è esclusa (decisione D-04) |

## File conservati con un altro nome

Se il file del registro risulta illeggibile o di una versione sconosciuta, l'app non lo sovrascrive: lo rinomina `registro-diagnostico.json.illeggibile-N` nella stessa cartella e lo segnala nella scheda "Diagnostica". Questi file non hanno una scadenza: restano finché l'app non viene rimossa. È un limite noto di M1.

## Che cosa conserva il sistema, non l'app

- Le scelte sui permessi di lettura sono conservate da iOS e si cambiano dalle impostazioni di Salute.
- I dati di Salute restano in Salute e non dipendono dall'app.

## Repository e compilazione

- Il repository è pubblico e non contiene dati sanitari né credenziali.
- I log e i rapporti di compilazione su GitHub sono conservati 7 giorni (decisione D-15) e contengono solo esiti tecnici.

## Che cosa non è verificato

- Che la protezione completa e l'esclusione dalle copie di sicurezza siano effettive sul dispositivo (criteri CA-18 e CA-19).
- Non esiste un controllo automatico che impedisca a una modifica futura di salvare valori sanitari: va verificato a ogni revisione del codice.
