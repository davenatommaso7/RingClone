# RingClone: confronto con Gennaro e decisioni implementative

Il confronto del 10 novembre 2026 ha integrato il codice di CIRUZZO LO SCUGNIZZ con il dossier di GENNARO DONATO TOSCANO. È stata applicata una sola correzione algoritmica, alla codifica dell'indice di attività PA usato da Nes; le altre formule sono rimaste invariate, mentre limiti e difetti preesistenti sono diventati requisiti espliciti del prompt iPhone e Apple Watch.

## Risultato e confini della consegna

- **Prompt principale:** `PROMPT_APP_IPHONE_APPLE_WATCH.md` raccoglie architettura, sensori, formule, provenienza, qualità, privacy, interfacce, problemi da risolvere e criteri di accettazione. È pronto per essere consegnato insieme al progetto aggiornato a chi realizzerà le app.
- **Codice aggiornato:** `Fitness.swift`, `PipelineTests.swift` e il nuovo `FitnessTests.swift`. Nessun altro modulo algoritmico, schermata, schema persistente o adattatore Apple è stato modificato in questo confronto.
- **Verifica:** 45 test del pacchetto RingCore superati, zero errori, su Linux con Swift 6.4.2. Sono i 39 test precedenti più 6 nuovi test PA; non sono test di un'app iPhone o Watch installata.
- **Limite operativo:** nessuna build con Xcode/SDK Apple, firma, prova su iPhone/Watch, misura della batteria o validazione clinica. Le app sono sorgenti da completare, non un prodotto già pronto per App Store.

## Come è stato svolto il confronto

Sono stati scambiati messaggi diretti con Gennaro e letti i suoi file di progetto `ricerche/smart-ring/confronto_RingClone_GDT.md` e `ricerche/smart-ring/studio_smart_ring_segnali_metriche.md`. La revisione ha incrociato ricerca, codice e test; quando il riepilogo e il codice differivano, il codice ha determinato lo stato “già presente”.

Le fonti decisive sono state aperte e controllate, non soltanto accettate dal dossier. In particolare, la codifica HUNT è stata confrontata su più articoli peer-reviewed e i limiti delle API sono stati controllati nella documentazione Apple; resta dichiarato dove la fonte originale o la semantica non sono state verificabili ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [HUNT 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/), [Apple SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn), [Apple temperatura notturna](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature)).

- **Pubblicato:** formula, definizione o dichiarazione effettivamente presente nella fonte indicata. Una dichiarazione di un produttore non è automaticamente una validazione indipendente.
- **Pubblicato indiretto:** informazione verificata in articoli correlati o in una fonte che riporta il modello, senza avere consultato il testo integrale originale. È il caso della ricostruzione PA per il modello Nes.
- **Euristico:** scelta di implementazione locale, come pesi dei punteggi, soglie, proxy da workout e smoothing.
- **Non verificato:** informazione insufficiente per implementare o dichiarare accuratezza. Non significa falsa, ma non utilizzabile come certezza.

## Correzione applicata: PA-index di Nes

### Errore precedente e prova utilizzata

Nella versione v2 avevo introdotto una scala PA 0–45 e descritto erroneamente la scala 0–15 come un difetto del progetto iniziale. Questa affermazione è ritirata: le codifiche e il prodotto documentati negli articoli HUNT portano a 0–15, e il codice è stato riallineato a tali codifiche ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [applicazione che cita Nes](https://pmc.ncbi.nlm.nih.gov/articles/PMC4121529/)).

Il testo integrale e il supplemento di Nes 2011 non sono stati consultati. L'abstract originale descrive 4.637 partecipanti iniziali e i modelli finali su 2.067 uomini e 2.193 donne, ma non espone la tabella completa dei codici PA: non viene quindi presentato come prova diretta di quella tabella ([Nes 2011, abstract](https://pubmed.ncbi.nlm.nih.gov/21502897/)).

### Codifica adottata

| Componente | Codici |
|---|---|
| Frequenza | Mai 0; meno di una volta/settimana 0; una volta 1; due-tre volte 2,5; quasi ogni giorno 5 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Intensità | Facile 1; fiato corto/sudore 2; quasi esaurimento 3 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Durata | Meno di 15 min 0,10; 15–29 min 0,38; 30–60 min 0,75; oltre 60 min 1,00 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Combinazione | \(PA=frequenza\cdot intensità\cdot durata\); massimo 15 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |

Un altro studio HUNT assegna 0,5 alla frequenza inferiore a una volta/settimana, invece di zero ([HUNT 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/)). Il codice rende esplicita questa divergenza con `PALessThanWeeklyPolicy.zero` e `.half`, usando `.zero` come default del protocollo adottato; non pretende che i due protocolli siano identici.

### Cosa cambia nei sorgenti

- **Questionario:** nuovo overload `paIndex(frequency:intensity:duration:lessThanWeeklyPolicy:)`, con categorie tipizzate. Calcola il prodotto senza ricavare automaticamente lo sforzo percepito dalla FC.
- **Proxy esistente:** `paIndex(workouts:days:hrMax:)` resta compatibile con i chiamanti. Riclassifica frequenza, durata mediana e frazione FC secondo i nuovi codici, ma è etichettato come proxy euristico, non come questionario HUNT osservato.
- **Robustezza:** giorni e FC massima devono essere finiti e positivi. La funzione mantiene il filtro preesistente per sessioni di almeno dieci minuti.
- **Integrazione attuale:** la pipeline continua a usare il proxy da workout. La schermata del questionario e la persistenza delle risposte non sono state aggiunte: sono richieste dal prompt per l'app completa.
- **Coefficienti:** equazioni Nes, SEE, Uth, fusione e Cardio Age non sono stati ritoccati. È stato corretto anche il solo commento descrittivo sul numero dei partecipanti iniziali di Nes, senza effetto sul risultato.

### Effetto analitico verificato

Per tre allenamenti settimanali da quaranta minuti a intensità moderata, il vecchio proxy produceva 15 e quello aggiornato produce 3,75. A parità di tutti gli altri ingressi, questo modifica soltanto il termine PA della stima Nes:

\[
\Delta VO_{2,u}=0,257(3,75-15)=-2,89125
\]
\[
\Delta VO_{2,d}=0,213(3,75-15)=-2,39625
\]

Le unità sono mL·kg⁻¹·min⁻¹; i coefficienti 0,257 e 0,213 sono quelli delle equazioni BMI riportate in letteratura ([Jalene e colleghi](https://pmc.ncbi.nlm.nih.gov/articles/PMC6759774/)). Il valore fuso finale può cambiare diversamente se sono presenti altre stime, e Cardio Age può cambiare indirettamente senza che la sua formula sia stata modificata.

## Confronto delle altre famiglie di algoritmi

| Area | Esito verificato | Decisione |
|---|---|---|
| HRV | Apple espone SDNN e serie di battiti; SDNN e RMSSD non sono lo stesso indicatore ([Apple SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn), [heartbeat series](https://developer.apple.com/documentation/healthkit/hkdatatypeidentifierheartbeatseries), [revisione HRV/PRV](https://pmc.ncbi.nlm.nih.gov/articles/PMC10742885/)). | Nessuna sostituzione di lnRMSSD con lnSDNN. Metrica, finestra e baseline devono restare separate. |
| Nuova API RMSSD | Simbolo Apple verificato con availability iOS/watchOS 27.0; la pagina consultata non precisa finestra, frequenza e qualità ([Apple RMSSD](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd)). | Nessun uso automatico aggiunto. Richiesti SDK compatibile, controlli runtime e verifica della semantica prima di integrare. |
| Temperatura e circadiano | Apple fornisce un aggregato notturno; Ultrahuman descrive finestre ancorate al minimo cutaneo ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature), [Ultrahuman](https://www.ultrahuman.com/science/explainers/circadian-alignment/)). | Nessuna nuova formula. Il fallback risveglio−2 h deve essere identificato come stima da orari, non minimo misurato. |
| Zone FC | Tanaka e le bande percentuali sono dichiarati da Ultrahuman ([zone FC](https://www.ultrahuman.com/science/explainers/heart-rate-zones/)). | Già presenti, insieme all'override e a Karvonen. Nessuna duplicazione o modifica. |
| Sleep Index | Cinque fattori pubblicati, inclusi posizione del nadir cardiaco e temperatura; nessuna formula completa con pesi nelle pagine consultate ([Sleep Index](https://www.ultrahuman.com/science/explainers/sleep-index/)). | Struttura e nadir già presenti. Pesi locali invariati, qualificati come euristici. |
| Movement | Passi, distribuzione dell'attività e frequenza dei workout sono pubblicati; pesi non disponibili ([Movement Index](https://www.ultrahuman.com/science/explainers/movement-index/)). | Formula locale invariata. Ciclismo e nuoto non vanno valutati soltanto tramite passi. |
| Recovery e Stress | Cinque contributori e modifica Stress Rhythm fino a ±10 sono descritti, ma non pesi e logistica locali ([Recovery](https://www.ultrahuman.com/science/explainers/recovery-score/)). | Nessun tuning. Nel prompt: qualità, copertura, baseline e movimento come prerequisiti. |
| Debito di sonno | Novanta giorni per il bisogno, quattordici per il debito, almeno cinque notti e categorie sono descritti da Oura, non da Ultrahuman ([Oura](https://support.ouraring.com/hc/en-us/articles/46233324892691-Sleep-Debt)). | Ricorsione locale 0,85 invariata; bisogno modificabile e sonnellini già presenti. Nessuna importazione automatica del modello Oura. |
| SRI e Social Jetlag | SRI è distinto dalla consistenza degli orari; la gestione del non-wear come mancante è esplicitata nell'implementazione GGIR; SJL usa il midpoint libero/lavorativo ([GGIR](https://wadpac.github.io/GGIR/articles/SleepRegularityIndex), [Social Jetlag](https://www.ultrahuman.com/science/explainers/social-jetlag/)). | Algebra invariata. Maschere di validità, griglia e ora legale rimangono attività di qualità esplicite. |
| VO₂ max Ultrahuman | La pagina di aggiornamento riporta un preprint e un confronto CPET, non coefficienti sufficienti a implementare il modello ([Ultrahuman VO₂ max](https://www.ultrahuman.com/blog/introducing-new-ultrahuman-vo2-max/)). | Nessuna sostituzione inventata di Nes. Le prestazioni dichiarate non sono trasferite al nostro codice. |
| Cardio Age | Conversione da VO₂ max rispetto a norme per sesso e smoothing descritti, parametri completi non pubblicati ([Cardio Age](https://www.ultrahuman.com/science/explainers/cardio-age/)). | Inversione della tabella locale e EMA 0,85/0,15 invariate, sperimentali e da verificare. |
| Calorie e MET | \(6FC/RHR-5\) è una caratteristica di un modello di ricerca, non una sostituzione dimostrata del calcolo energetico locale ([Scientific Reports](https://link.springer.com/article/10.1038/s41598-023-43024-x)). | Mifflin/Keytel e import HealthKit invariati. |
| Respiro da PPG | Il lavoro esaminato usa più modulazioni e un modello addestrato; non fornisce una semplice formula pronta per i dati Apple disponibili ([PLOS ONE](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0249843)). | Import notturno/RSA attuale invariato. Nessuna falsa promessa di fusione AM/BW/FM già realizzata. |
| Fasi del sonno | Il codice usa HMM/Viterbi anche sugli stadi importati; nessuna nuova formula completa è stata verificata per sostituirlo. | Nessuna modifica dell'HMM in questo intervento. Il prompt richiede separazione fra fasi originali e stima sperimentale. |

## Rettifiche documentali e decisioni non adottate

- **Baseline:** il codice usa sessanta giorni per le statistiche fisiologiche, con almeno sette valori validi per singola metrica. La precedente indicazione generica “ventotto giorni” era inesatta; gli orizzonti più brevi riguardano altri aggregati.
- **Bisogno di sonno:** nel profilo il default è otto ore, modificabile. Il suggerimento di usare sette ore come default non è stato adottato e non va confuso con la stima del bisogno personale.
- **TIB:** il periodo clinico a letto deve includere la latenza; onset-to-out-of-bed e ingresso-a-letto-to-alzata sono definizioni diverse. La gestione effettiva del codice è ancora da correggere quando il segnale `inBed` è disponibile.
- **Social Jetlag:** venti minuti non sono stati adottati come soglia clinica universale; il riferimento citato da Gennaro è una discussione, non una norma diagnostica ([rassegna sul Social Jetlag](https://pmc.ncbi.nlm.nih.gov/articles/PMC10204006/)).
- **VO₂ Apple:** è una stima importata, non una misura CPET. La priorità suggerita nel dossier è una scelta di prodotto; il codice attuale usa una fusione, non una preferenza assoluta.
- **Nessuna accuratezza trasferita:** concordanze di altri wearable, autoconferme dei sonnellini e stabilità longitudinale non validano RingClone. Le percentuali del vecchio test sintetico non diventano promesse per l'app.
- **Sincronizzazione:** Watch-iPhone è il flusso richiesto; eventuale cloud esterno deve restare facoltativo e autorizzato. Non è stata aggiunta alcuna trasmissione esterna di dati sanitari.

## Problemi preesistenti: registrati, non corretti in questa patch

Questi rilievi sono separati dalle novità nelle formule richieste dall'utente. Il prompt li include come lavoro necessario per una versione affidabile, senza affermare che siano già risolti.

| Rilievo | Punto del codice | Criterio di completamento richiesto |
|---|---|---|
| HRV ai bordi | `HRV.metrics` usa il `diff` precomputato del primo battito di una slice. | Escludere la coppia se il predecessore è fuori finestra; prova analitica con gap e tagli. |
| Fase non classificata | `HealthRepository` converte `asleepUnspecified` in leggero. | Conservare sonno senza fase nota e origine del campione. |
| Stadi esterni riclassificati | `DailyPipeline` passa le fasi importate all'HMM come osservazione. | Fasi native e stima sperimentale separate, senza attribuzione ingannevole. |
| Tempo a letto | `SleepDetection` scarta segmenti con `stage=nil`. | Usare correttamente `inBed` e dichiarare TIB/SOL non osservabili quando mancano. |
| Continuità e TST | `SleepMetrics` conta alcuni frammenti iniziali nei tratti ma non in TST. | Durate e denominatori coerenti con la stessa definizione di onset. |
| Sonnellini con buchi | Durata di sessioni unite può includere veglia. | Contare sonno effettivo, non soltanto intervallo start-end. |
| SRI | Griglia di sessanta secondi, veglia implicita e coppie di giorni locali. | Copertura valida, non-wear escluso e test delle giornate 23/25 ore. |
| FCmax “misurata” | A quarant'anni, picchi 172/173/174 possono produrre 180 da Tanaka ma `measured=true`. | Separare massimo predetto, osservato e confermato prima di usare Uth. |
| Incertezza della fusione | `Fitness.fuse` combina SEE assumendo indipendenza. | Non mostrare errore clinico o confidenza statistica non validati. |
| Valori di riserva | RHR=60, Stress Rhythm=100 e circadiano neutro su dati insufficienti. | Stati non disponibili/calibrazione, nessuna misura fittizia. |
| Minimo di temperatura | `DailyPipeline` usa risveglio−2 h; `Presentation` non ne esplicita sempre l'origine. | “Stima da orari”, oppure nessuna fase se mancano prerequisiti. |
| Movimento durante stress | Il filtro considera passi e workout, non tutto il movimento. | Qualità del segnale e inattività osservata. |
| Trasferimenti/persistenza | Errori di scrittura ignorati, avanzamento cursore e conferma solo di trasporto. | Conferma di persistenza, retry idempotenti e test di guasto. |
| Popolazione/profilo | Età ammesse dalla UI più ampie del dominio dichiarato dei modelli. | Validazione, esclusioni e messaggi espliciti. |
| Acquisizione/background | Richieste limitate e risvegli non garantiti. | Nessuna promessa 24/7; copertura, ultimo aggiornamento e prove su hardware. |

## Verifiche riproducibili

Il comando eseguito dalla cartella del pacchetto è `swift test`, con toolchain Swift 6.4.2 per Linux. La ripetizione finale della suite aggiornata ha eseguito 45 test in 50,460 secondi con zero failure; il log della verifica è incluso in `docs/verifiche/`.

| Gruppo | Test | Esito |
|---|---:|---|
| FitnessTests | 6 | Superati |
| PipelineTests | 13 | Superati |
| PresentationTests | 5 | Superati |
| SignalTests | 10 | Superati |
| SleepTests | 11 | Superati |
| Totale | 45 | Zero failure |

- **Nuova copertura:** tabella categoriale e intervallo 0–15, policy della frequenza rara, limiti di durata/frequenza/intensità del proxy, esempio 3,75, delta analitico Nes e giorni/FCmax invalidi.
- **Controllo del diff:** funzioni Nes, Uth, fusione, VO₂ max, inversione normativa e smoothing sono invariate. Il cambiamento descrittivo sul campione Nes è un commento, non una variazione della formula.
- **Nessun test allargato:** il test preesistente PA cambia l'atteso da 15 a 3,75; non sono state allentate tolleranze per far passare risultati incompatibili.
- **Non dimostrato:** qualità di misura su persone, disponibilità sensori su tutti i modelli Watch, correttezza dello strato app con SDK Apple e risultato estetico su dispositivi.

## Come usare il materiale

Per proseguire, consegna il prompt principale e l'archivio aggiornato allo stesso assistente di sviluppo, chiedendogli di iniziare dall'audit e dai criteri di accettazione. Il confronto e i documenti tecnici accompagnano il codice; non sostituiscono una build reale né l'esecuzione dei test sui dispositivi.

Se esiste già uno storico ottenuto con la v2, non mischiare automaticamente i risultati prima e dopo la correzione PA. Il prompt richiede versionamento e ricalcolo cronologico dei risultati derivati; questa migrazione non è stata implementata nell'intervento focalizzato alle formule.
