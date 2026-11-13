# RingClone M1: protocollo di prova sui dispositivi a elenco chiuso

Stato: bozza del 13 novembre 2026, non revisionata e mai eseguita. Riguarda il commit `a9ee2077` e i successivi che non cambiano le app di M1.

Serve a verificare i criteri CA-15 ... CA-20 del traguardo M1 su iPhone 15 Pro e Apple Watch Series 10. Richiede un canale di installazione, che non è ancora stato scelto (decisione D-02, secondo passo).

## Regola

Chi esegue le prove riferisce soltanto voci di questo elenco chiuso:

- `sì` oppure `no`
- `uguale`, `diverso` oppure `non confrontabile`
- uno dei tre stati: `presente`, `nessun campione`, `errore`
- un codice d'errore, cioè il dominio e il numero mostrati dall'app (per esempio `com.apple.healthkit 6`)
- il numero della prova e il nome del tipo di dato

Non si riferiscono mai valori, orari, nomi delle sorgenti, schermate, registrazioni dello schermo o file. Se una prova non si può descrivere con l'elenco, si riferisce `non confrontabile` e il numero della prova.

## Tipi di dato

Le sezioni della scheda "Dati importati" sono, nell'ordine: Frequenza cardiaca; Frequenza cardiaca a riposo di Apple; Passi; Sonno; Serie battito-battito; Variabilità RMSSD nativa; Variabilità SDNN di Apple; Frequenza respiratoria; Saturazione di ossigeno; Temperatura al polso nel sonno; Energia attiva; Energia basale; VO2 max stimato da Apple; Tempo alla luce diurna; Allenamenti.

## Prove

| N. | Che cosa fare | Che cosa riferire | Criterio |
|---|---|---|---|
| P01 | Installare l'app sull'iPhone e aprirla | L'app si apre: `sì` o `no` | CA-15 |
| P02 | Cercare l'app "Ring M1" sull'Apple Watch e aprirla | L'app è presente e si apre: `sì` o `no` | CA-15, CA-20 |
| P03 | Al primo avvio leggere la spiegazione e toccare "Continua" | Compare il foglio di iOS con un interruttore per ogni tipo: `sì` o `no` | CA-16 |
| P04 | Consentire tutti i tipi. Nella scheda "Dati importati" leggere la riga "Stato" di ogni sezione | Per ogni tipo: `presente`, `nessun campione` oppure `errore` con il codice | CA-16 |
| P05 | La sezione "Variabilità RMSSD nativa" compare nell'elenco | `sì` o `no` | CA-16 |
| P06 | Per Passi, Energia attiva, Energia basale e Tempo alla luce diurna confrontare la riga "Totale secondo la statistica di Salute" con il totale di oggi nell'app Salute | Per ogni tipo: `uguale`, `diverso` o `non confrontabile` | CA-17 |
| P07 | Per Frequenza cardiaca a riposo, Variabilità SDNN, VO2 max, Temperatura al polso e Allenamenti confrontare il numero di righe elencate con le voci dello stesso intervallo in Salute ("Mostra tutti i dati") | Per ogni tipo: `uguale`, `diverso` o `non confrontabile` | CA-17 |
| P08 | Per il Sonno confrontare numero e categoria dei campioni con le voci dello stesso intervallo in Salute | `uguale`, `diverso` o `non confrontabile` | CA-17 |
| P09 | Nelle impostazioni di iOS togliere il permesso a un solo tipo, riaprire l'app e toccare "Rileggi" | Lo stato di quel tipo è `nessun campione` e il testo non indica una causa: `sì` o `no` | CA-16 |
| P10 | Aprire la scheda "Diagnostica" e annotare per sé il numero di voci del registro. Bloccare l'iPhone per un minuto, sbloccarlo e tornare all'app | Il numero di voci è `uguale` o `diverso`; compare la sezione "Avvisi del registro": `sì` o `no`; se c'è un errore, il codice | CA-18 |
| P11 | Chiudere l'app dall'elenco delle app aperte e riaprirla. Aprire "Diagnostica" | Il numero di voci del registro è `uguale` o `diverso`; compare "Avvisi del registro": `sì` o `no` | CA-19 |
| P12 | Sull'Apple Watch leggere la sezione "Collegamento" | "Sessione" è attiva: `sì` o `no`; "App iPhone installata": `sì` o `no` | CA-20 |
| P13 | Sull'iPhone aprire la scheda "Collegamento" | "Apple Watch abbinato": `sì` o `no`; "App Watch installata": `sì` o `no` | CA-20 |

## Come riferire

Una riga per esito, per esempio: `P04 Passi: presente`, `P06 Energia attiva: uguale`, `P04 Saturazione di ossigeno: errore com.apple.healthkit 6`.

## Limiti di questa bozza

- Il numero di voci del registro (P10, P11) non è un valore sanitario, ma si riferisce comunque solo come `uguale` o `diverso`.
- Per Frequenza cardiaca, Frequenza respiratoria, Saturazione di ossigeno e Serie battito-battito il confronto del numero di campioni con Salute può essere troppo lungo da fare a mano: in quel caso si riferisce `non confrontabile`.
- I nomi delle voci di menu di iOS e dell'app Salute possono cambiare con la versione del sistema.
- Il comportamento a dispositivo bloccato (P10) in M1 si può osservare solo dopo lo sblocco, perché l'app non lavora in background.
