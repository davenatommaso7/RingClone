# RingClone M1: glossario dei valori importati

Stato: bozza del 13 novembre 2026, non revisionata. Il piano affida questo documento a un ricercatore medico: questa bozza è stata scritta senza quella competenza e va rivista prima di essere usata.

Per ogni tipo di dato dice tre cose: che cosa misura secondo la documentazione di Apple, che cosa mostra M1, che cosa non se ne può dedurre. Le pagine di Apple sono state lette il 13 novembre 2026 e possono cambiare. Dove la pagina non è stata riaperta, è scritto.

Regola generale: M1 mostra i valori così come li registra Salute. Non li interpreta, non li confronta con soglie e non ne ricava altri valori. Nessun valore mostrato è un'indicazione sullo stato di salute.

## Frequenza cardiaca

- Che cosa è: campioni della frequenza cardiaca, in battiti al minuto. Fonte: descrizione breve del tipo `heartRate` nella documentazione di HealthKit; la pagina dedicata non è stata riaperta.
- Che cosa mostra M1: numero di campioni del giorno, primo e ultimo, minimo e massimo, sorgenti, e quanti campioni sono non numerici o fuori da 30-210.
- Che cosa non se ne può dedurre: minimo e massimo non sono la frequenza a riposo né la frequenza massima della persona. Il numero di campioni dipende da quanto e come è stato indossato l'orologio. L'intervallo 30-210 è una scelta dell'app per contare i valori insoliti, non una soglia clinica.

## Frequenza cardiaca a riposo di Apple

- Che cosa è: una stima della frequenza cardiaca più bassa nei periodi di riposo, che il sistema ricava analizzando i campioni registrati da fermi durante il giorno. È diversa da un singolo campione registrato da fermi. Apple avverte che le stime diventano più accurate nel corso della giornata e che il sistema può cancellare i campioni precedenti e sostituirli. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/restingheartrate
- Che cosa mostra M1: ogni valore importato del giorno, con data e sorgente.
- Che cosa non se ne può dedurre: è una stima di Apple, non una misura diretta. Il valore letto la mattina può essere diverso da quello letto la sera dello stesso giorno, perché il sistema lo sostituisce.

## Passi

- Che cosa è: il numero di passi. Fonte: descrizione breve del tipo `stepCount`; la pagina dedicata non è stata riaperta.
- Che cosa mostra M1: il totale per ciascuna sorgente e, separato, il totale secondo la statistica di Salute.
- Che cosa non se ne può dedurre: i totali delle sorgenti non vanno sommati fra loro, perché iPhone e Apple Watch possono contare gli stessi passi. Il totale di Salute e la somma delle sorgenti possono quindi essere diversi senza che ci sia un errore.

## Sonno

- Che cosa è: campioni con una categoria ciascuno: a letto, sveglio, sonno core (leggero o intermedio), sonno profondo, sonno REM, sonno non specificato (addormentato, ma la fase non è nota). I campioni "a letto" si sovrappongono a quelli di dettaglio. Apple avverte che l'Apple Watch registra i campioni "sveglio" solo fra due campioni di sonno, quindi all'inizio e alla fine del periodo a letto possono mancare campioni di dettaglio. Fonte: https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
- Che cosa mostra M1: l'elenco dei campioni dalle 18 del giorno prima, ciascuno con categoria originale, sorgente, inizio e fine.
- Che cosa non se ne può dedurre: M1 non calcola durata del sonno, tempo per addormentarsi, risvegli o percentuali delle fasi. Le fasi sono una classificazione fatta da chi ha scritto i campioni, non una misura di laboratorio. Sorgenti diverse possono descrivere la stessa notte in modo diverso. "Sonno non specificato" non equivale a sonno leggero.

## Serie battito-battito

- Che cosa è: una serie che contiene i dati dei singoli battiti. Fonte: https://developer.apple.com/documentation/healthkit/hkdatatypeidentifierheartbeatseries (la pagina dà solo questa descrizione).
- Che cosa mostra M1: solo il numero di serie e l'intervallo coperto. I battiti non vengono letti.
- Che cosa non se ne può dedurre: nulla sulla variabilità cardiaca. Quante serie esistano e quanto durino sul dispositivo usato non è stato verificato.

## Variabilità RMSSD nativa

- Che cosa è: un tipo disponibile da iOS 27. La pagina di Apple riporta solo la dichiarazione, senza descrizione di finestra, frequenza o qualità. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd
- Che cosa mostra M1: solo il numero di campioni. I valori non vengono letti né mostrati.
- Che cosa non se ne può dedurre: nulla sul valore della variabilità. L'assenza di campioni non dice se il dispositivo non li produce o se la lettura non è consentita.

## Variabilità SDNN di Apple

- Che cosa è: la deviazione standard degli intervalli fra battiti normali, di solito in millisecondi, registrata automaticamente dall'Apple Watch. Apple precisa che esistono più modi di calcolare la variabilità e che HealthKit usa l'SDNN. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn
- Che cosa mostra M1: ogni campione dalle 18 del giorno prima, con data e sorgente, indicato come SDNN.
- Che cosa non se ne può dedurre: SDNN e RMSSD sono misure diverse e non si convertono l'una nell'altra. I campioni sono misure brevi prese in momenti scelti dal sistema: non sono confrontabili con valori ottenuti in altre condizioni o con altri strumenti.

## Frequenza respiratoria

- Che cosa è: campioni della frequenza respiratoria, in respiri al minuto. La pagina di Apple su questo tipo non è stata riaperta in questa bozza.
- Che cosa mostra M1: numero di campioni dalle 18 del giorno prima, minimo e massimo, sorgenti.
- Che cosa non se ne può dedurre: M1 non calcola un valore "della notte". Minimo e massimo sono due singoli campioni, non un valore tipico.

## Saturazione di ossigeno

- Che cosa è: campioni della saturazione di ossigeno. Fonte: descrizione breve del tipo `oxygenSaturation`; la pagina dedicata non è stata riaperta.
- Che cosa mostra M1: numero di campioni dalle 18 del giorno prima, minimo e massimo in percentuale, sorgenti. L'assenza di campioni è uno stato, non un errore.
- Che cosa non se ne può dedurre: non è una misura da strumento medico e un singolo valore non indica una condizione. L'assenza di campioni può dipendere dal dispositivo, dalle impostazioni o dai permessi, e l'app non può distinguere questi casi.

## Temperatura al polso nel sonno

- Che cosa è: l'orologio misura la temperatura al polso ogni cinque secondi durante il sonno e la riassume in un solo campione, corretto per l'ambiente, che rappresenta l'intera notte. Apple avverte che la temperatura varia da una notte all'altra e risente dell'ambiente, dell'esercizio, del cambio di fuso, del ciclo mestruale o di una malattia. L'orologio registra il valore assoluto, mentre l'app Salute mostra uno scostamento rispetto alla base personale, e solo dopo circa cinque notti. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature
- Che cosa mostra M1: l'elenco dei campioni dalle 18 del giorno prima, ciascuno con il proprio intervallo, la sorgente e il valore assoluto in gradi Celsius. Non li attribuisce a una notte.
- Che cosa non se ne può dedurre: non è la temperatura corporea. Il valore di M1 non è direttamente confrontabile con quello dell'app Salute, che mostra uno scostamento. Il campione non contiene l'ora della temperatura minima.

## Energia attiva

- Che cosa è: l'energia attiva consumata. Fonte: descrizione breve del tipo `activeEnergyBurned`; la pagina dedicata non è stata riaperta.
- Che cosa mostra M1: il totale per sorgente e, separato, il totale secondo la statistica di Salute, in chilocalorie.
- Che cosa non se ne può dedurre: è una stima dei dispositivi, non una misura. Un totale non disponibile è diverso da zero. I totali delle sorgenti non vanno sommati.

## Energia basale

- Che cosa è: l'energia che il corpo consuma a riposo per le funzioni di base, come respirare e far circolare il sangue. Apple avverte che HealthKit può condensare o unire i campioni. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/basalenergyburned
- Che cosa mostra M1: il totale per sorgente e, separato, il totale secondo la statistica di Salute, in chilocalorie.
- Che cosa non se ne può dedurre: è una stima. Il totale riguarda la parte del giorno già trascorsa, non l'intera giornata. Il numero di campioni non ha significato, perché il sistema li può unire.

## VO2 max stimato da Apple

- Che cosa è: il VO2 max è il consumo massimo di ossigeno durante l'esercizio; in clinica si misura con una prova da sforzo fino all'esaurimento. L'Apple Watch non lo misura: lo stima dalla risposta della frequenza cardiaca durante una camminata, una corsa o un'escursione all'aperto, su terreno quasi piano e con segnale adeguato. La stima è sotto-massimale, copre l'intervallo 14-60 ml/kg/min e richiede a sua volta una stima della frequenza cardiaca di picco. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/vo2max
- Che cosa mostra M1: ogni valore del giorno, con data e sorgente, indicato come stima importata.
- Che cosa non se ne può dedurre: non è il risultato di una prova da sforzo. Nei giorni senza attività all'aperto adatta è atteso che non ci siano campioni. Chi assume farmaci che riducono la frequenza di picco può avere stime meno accurate, secondo Apple.

## Tempo alla luce diurna

- Che cosa è: il tempo trascorso alla luce del giorno; i campioni sono cumulativi. Fonte: https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/timeindaylight (la pagina dà solo questa descrizione).
- Che cosa mostra M1: il totale per sorgente e, separato, il totale secondo la statistica di Salute, in minuti.
- Che cosa non se ne può dedurre: la pagina letta non dice come viene rilevata la luce né con quale accuratezza. Non è una misura dell'esposizione ai raggi ultravioletti.

## Allenamenti

- Che cosa è: gli allenamenti registrati in Salute. La pagina di Apple su questo tipo non è stata riaperta in questa bozza.
- Che cosa mostra M1: per ogni allenamento del giorno tipo, inizio e fine, durata in minuti e sorgente. Per i tipi che l'app non traduce compare "Tipo n." seguito dal numero usato da Salute.
- Che cosa non se ne può dedurre: M1 non legge distanza, energia o frequenza cardiaca dell'allenamento e non calcola intensità o carico. La durata è quella registrata, comprese le eventuali pause secondo le regole di chi ha scritto l'allenamento.

## Limiti di questa bozza

- Non è stata rivista da una persona con competenza medica.
- Usa solo la documentazione di Apple per sviluppatori; non usa letteratura scientifica.
- Per frequenza cardiaca, passi, frequenza respiratoria, saturazione di ossigeno, energia attiva e allenamenti la pagina dedicata di Apple non è stata riaperta.
- Le frasi su ciò che "non se ne può dedurre" sono in parte considerazioni di chi ha scritto la bozza, ricavate da come l'app legge i dati, e non affermazioni di Apple.
- Nulla è stato verificato sui dispositivi.
