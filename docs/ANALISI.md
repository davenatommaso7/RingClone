# Analisi, algoritmi e limiti

Questo documento descrive RingClone v2.1 dopo il confronto con GENNARO DONATO TOSCANO del 10 novembre 2026. La specifica completa per realizzare le app è in `PROMPT_APP_IPHONE_APPLE_WATCH.md`; le decisioni con le fonti e la separazione fra patch e lavori futuri sono in `CONFRONTO_E_DECISIONI.md`.

Il motore è indipendente e sperimentale, non una replica degli algoritmi proprietari di un produttore. Descrivere una formula presente nei sorgenti non significa che sia stata validata su persone o che l'app sia stata compilata per iPhone e Apple Watch.

## Evoluzione e correzioni della documentazione

Il progetto iniziale era un prototipo non compilato lato app, con un motore e pochi test. La v2 ha introdotto il pacchetto RingCore, storico idempotente, segmentazione più strutturata, trasferimenti e test; la v2.1 cambia soltanto il PA-index sul piano algoritmico.

- **Errore PA della v2:** avevo attribuito erroneamente al progetto originale un problema di scala e introdotto 0–45. La ricostruzione dagli articoli HUNT sostiene 0–15, con variante esplicita della frequenza rara; la precedente giustificazione è ritirata ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [HUNT 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/)).
- **Baseline:** non sono tutte su ventotto giorni. RHR, lnRMSSD, temperatura e respiro usano sessanta giorni; altri aggregati hanno finestre differenti.
- **Sonno:** il codice non va descritto come applicazione completa di definizioni cliniche. TIB/SOL, frammenti iniziali, sonnellini con buchi e fasi non classificate richiedono correzioni specifiche.
- **Prestazioni sintetiche:** le percentuali precedentemente misurate sul generatore non sono accuratezze su persone e non vengono usate come obiettivi del prodotto. Non giustificano ulteriore tuning per simulare le prestazioni di un wearable commerciale.

## Architettura effettiva

RingCore usa soltanto Foundation e accetta input indipendenti dalle API di piattaforma. `DailyPipeline.run(input, profile:, history:)` restituisce un report a partire da dati e storico espliciti, senza leggere l'orologio di sistema.

- **Rielaborazione:** sostituisce il report del giorno, mantiene ordine cronologico e non usa la notte corrente nella propria baseline. Il determinismo è coperto da test.
- **Tempo:** epoche di trenta secondi su griglia Unix; notte attribuita al risveglio, attività al giorno locale. Fusi e ora legale non sono ancora gestiti in modo completo.
- **Baseline fisiologiche:** mediana/MAD su sessanta giorni, minimo sette valori validi per ogni statistica. La calibrazione globale oggi conta le notti, non la readiness di ciascuna grandezza.
- **Altri orizzonti:** HRV sette giorni; orari quattordici; notti recenti/carico ventotto; workout fino a centottanta; Cardio Age precedente entro trenta; debito tredici giorni precedenti più quello elaborato.
- **Strato iPhone:** query HealthKit, assemblaggio, archivio JSON, ricezione movimento e SwiftUI. Il tipo e la provenienza dei campioni non sono ancora preservati con il dettaglio richiesto dal prompt.
- **Strato Watch:** registrazione inerziale consentita dalle API, avvio/fine workout, FC e zone, trasferimenti file. Pausa/ripresa, riepilogo punteggi e conferma di persistenza sono da integrare.

## Modelli presenti

Le formule in questa sezione sono una descrizione del codice corrente, non una raccomandazione clinica. Le modifiche future devono preservarne parametri e convenzioni, salvo correzioni supportate da test e fonti.

### Segnali, HRV e respiro

- **PPG:** passa-banda 0,5–4 Hz, due medie mobili per i picchi, rifinitura parabolica, qualità morfologica e penalità da movimento. Il modulo accetta array esterni; non è un driver BLE né un percorso di acquisizione ottica Apple.
- **NN:** validi fra 300 e 2.000 ms ed entro ±20% della mediana locale di undici battiti. È un filtro euristico, non una regola diagnostica.
- **RMSSD:** radice della media dei quadrati delle differenze fra NN contigui validi. Resta un difetto di bordo: il primo `diff` di una slice può provenire da un predecessore fuori finestra.
- **SDNN:** deviazione standard campionaria dei NN; pNN50, Poincaré e Baevsky sono calcolati separatamente. RMSSD di finestra è aggregato geometricamente nella notte, SDNN aritmeticamente: quest'ultima non è la SDNN globale di tutti i NN notturni.
- **Import Apple:** SDNN è una metrica distinta e non può sostituire automaticamente RMSSD nel Recovery ([Apple SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn), [revisione HRV/PRV](https://pmc.ncbi.nlm.nih.gov/articles/PMC10742885/)). Il prototipo non importa ancora SDNN quantitativa.
- **Respiro:** dato notturno importato se presente, altrimenti stima RSA da NN ricampionati a 4 Hz, detrending e picco 0,1–0,5 Hz. Non è una fusione PPG AM/BW/FM né una diagnosi respiratoria.
- **ECG:** rilevatore semplificato nel Core per segnali forniti dall'esterno. La sua presenza non dimostra una registrazione ECG implementata nell'app.

### Cuore, temperatura e movimento

- **RHR:** minimo della media su finestre di cinque minuti durante il sonno. Il codice ammette copertura parziale: l'etichetta non deve suggerire cinque minuti integralmente osservati se non lo sono.
- **FC massima:** override dell'utente, altrimenti massimo fra Tanaka e secondo picco osservato. Il flag `measured` può essere vero pur restituendo Tanaka: è un difetto preesistente, non corretto dalla patch PA.
- **Zone:** cinque bande 50–60–70–80–90–100% FCmax, oppure Karvonen; carico Edwards con minuti moltiplicati per indice di zona. Tanaka e le bande percentuali sono dichiarati anche dal produttore, non l'intera logica locale di massima osservata ([Ultrahuman](https://www.ultrahuman.com/science/explainers/heart-rate-zones/)).
- **Temperatura esterna:** mediana del sonno senza i primi venti minuti, minimo di curva lisciata su trenta minuti. L'aggregato Apple non contiene l'istante del minimo ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature)).
- **Movimento:** MAD in mg su blocchi di cinque secondi, variazioni dell'angolo e passi di riserva. La rotazione durante workout è raccolta ma non entra nei punteggi.

### Sonno

- **Rilevazione:** sessioni da una sorgente selezionata o immobilità/FC; notte principale distinta dai sonnellini. I segmenti possono essere uniti attraverso buchi fino a trenta minuti, che non dovrebbero diventare automaticamente sonno.
- **Fasi:** HMM a quattro stati, Viterbi, adattamento MAP in due passate, osservazione esterna con concordanza assunta 0,75 e priori temporali. Sono assunzioni del prototipo, non parametri di un modello clinicamente addestrato.
- **Tuning storico:** penalità del profondo −0,2 e assorbimento di un'epoca isolata di veglia sono stati scelti su dati sintetici. Restano invariati in questa patch; non qualificano un evento come micro-risveglio clinico.
- **Metriche:** TST, periodo a letto stimato, latenza, WASO, efficienza, risvegli, fasi, tratti, ristoratore e cicli stimati. Il codice ignora oggi i segmenti `inBed` senza fase e può avere incoerenze fra TST e somma dei tratti.
- **Fasi Apple:** `asleepUnspecified` viene convertito in leggero e gli stadi importati passano comunque all'HMM. Il prompt richiede fasi originali separate dalla stima locale.

Lo Sleep Index locale usa componenti normalizzate durata D, tranquillità Q, ristoratore R, timing T e vitali V:

\[
SleepIndex=100(0,30D+0,20Q+0,20R+0,15T+0,15V)
\]

La tranquillità usa 0,55 efficienza + 0,25 risvegli + 0,20 latenza; il ristoratore normalizza N3+REM; il timing usa orari e consistenza; i vitali includono RHR, posizione del nadir e temperatura. I cinque ingredienti sono descritti da Ultrahuman, ma i pesi e le normalizzazioni sono locali ([Sleep Index](https://www.ultrahuman.com/science/explainers/sleep-index/)).

- **SRI:** algebra \(-100+200A/T\), ma implementazione corrente su minuti, senza maschera completa di osservazione. Non-wear e differenze di 23/25 ore richiedono test e correzioni, distinti dalla formula; GGIR esplicita non-wear mancante ed epoche di trenta secondi ([GGIR](https://wadpac.github.io/GGIR/articles/SleepRegularityIndex)).
- **Debito:** \(\max(0,0,85D_{precedente}+bisogno-sonno)\), quattordici giorni, sonnellini inclusi e giornate mancanti saltate. Il bisogno predefinito è otto ore modificabili; il decadimento non è per giorno di calendario se si saltano osservazioni.
- **Oura:** regole su novanta giorni, cinque notti minime e categorie appartengono alla descrizione di Oura e non sono state importate come nuova formula Ultrahuman ([Oura](https://support.ouraring.com/hc/en-us/articles/46233324892691-Sleep-Debt)).

### Attività ed energia

- **Ora attiva:** almeno 250 passi oppure cinque minuti moderati, con almeno trenta minuti di veglia. La soglia FC è il massimo fra 60% FCmax e 40% della riserva aggiunta alla RHR.
- **Workout automatici:** almeno dieci minuti sopra soglia, buchi tollerati fino a due minuti, movimento per metà del periodo. La cadenza orienta l'etichetta, non identifica in modo universale ogni sport.
- **Calorie:** importazione HealthKit dove valida; riserva Mifflin-St Jeor, Keytel e costo locale dei passi. Non sono dati calorimetrici misurati e zero deve restare distinto da assenza.
- **Movement:** \(100(0,45s^{0,8}+0,35a+0,20w)\), con s = passi/max(obiettivo, 1.000), a = ore attive/9, w = workout in sette giorni/4, rapporti limitati a 0–1. Solo gli ingredienti generali sono dichiarati dal produttore ([Movement Index](https://www.ultrahuman.com/science/explainers/movement-index/)).

### Stress e recupero

Lo stress è una stima euristica di attivazione fisiologica, non ansia o stress percepito. Le finestre sono di cinque minuti; il filtro attuale esclude sonno, passi e workout, ma non tutto il movimento senza passi.

\[
z_{FC}=\frac{FC-1,30RHR}{0,13RHR},\quad
z_{SI}=\frac{\ln SI-\ln150}{0,8}
\]
\[
z_{HRV}=\frac{\ln RMSSD-(baseline-0,5)}{\max(dispersione,0,3)}
\]
\[
z=0,40z_{FC}+0,30z_{SI}-0,30\,clamp(z_{HRV},-3,3)
\]
\[
Stress=100\,logistica(1,2\,clamp(z,-4,4)-0,4)
\]

Quando mancano parti dell'input, il codice ha rami parziali da etichettare separatamente. Lo Stress Rhythm parte da cento e penalizza finestre oltre settanta con pesi temporali; senza finestre valide, cento non prova assenza di stress.

Recovery usa contributi standardizzati e limitati: sonno 0,30; RHR 0,25; HRV Form 0,30; temperatura 0,15, quindi \(100\,logistica(1,1+0,9\bar z)\) e contributo Stress Rhythm fino a ±10. La struttura e il limite ±10 sono descritti dal produttore, non i pesi e la funzione logistica del prototipo ([Recovery](https://www.ultrahuman.com/science/explainers/recovery-score/)).

### Ritmo circadiano

- **Social Jetlag:** differenza circolare dei midpoint libero/lavorativo; correzione per debito e MSFsc sono risultati separati. Servono classificazioni corrette delle notti, non soltanto il fine settimana.
- **Allineamento:** 0,40 fase + 0,35 SRI + 0,15 luce + 0,10 jetlag, con componente mancante oggi pari a 0,7. È una convenzione locale, non una fase fisiologica validata.
- **Finestre:** Minima di trenta minuti, Advance locale di quattro ore, Delay da otto a quattro ore prima, zona intermedia. Il produttore pubblica alcuni confini e concetti, non tutte le durate né il punteggio locale ([Circadian Alignment](https://www.ultrahuman.com/science/explainers/circadian-alignment/)).
- **Fallback:** risveglio abituale meno due ore se manca la curva termica. Deve essere mostrato come stima da orari; attualmente la provenienza non è sufficiente nell'output.

### Fitness e Cardio Age

Le equazioni BMI di Nes rimangono invariate e coincidono con quelle riportate nella pubblicazione consultata ([Jalene e colleghi](https://pmc.ncbi.nlm.nih.gov/articles/PMC6759774/)):

\[
VO_{2,u}=92,05-0,327a-0,933BMI-0,167RHR+0,257PA
\]
\[
VO_{2,d}=70,77-0,244a-0,749BMI-0,107RHR+0,213PA
\]

- **PA corretto:** prodotto delle categorie frequenza 0/1/2,5/5, intensità 1/2/3, durata 0,10/0,38/0,75/1,00. La frequenza rara ha policy 0 oppure 0,5; default 0, range complessivo 0–15 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [HUNT 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/)).
- **Pipeline:** continua a ricostruire PA dai workout. La nuova API del questionario è disponibile, ma non è ancora il percorso effettivo dell'app.
- **Uth:** \(15,3FCmax/RHR\), invariato. Il requisito di massimo confermato non è garantito dall'attuale flag `measured`.
- **Fusione:** media a varianza inversa di Nes, Uth quando abilitato, Apple recente e laboratorio facoltativo. SEE e dipendenza fra modelli non consentono di presentare l'errore fuso come confidenza clinica dimostrata.
- **Cardio Age:** inversione lineare della tabella presente, limite 18–90, smoothing 0,85 precedente + 0,15 nuovo. Tabella normativa, estrapolazione e ambito restano da verificare; non è età vascolare.

## Verifica e limiti residui

Su Linux con Swift 6.4.2, `swift test` esegue 45 test senza failure. Sono sei test Fitness, tredici Pipeline, cinque Presentation, dieci Signal e undici Sleep; log e patch sono inclusi in `verifiche/`.

- **Copertura nuova:** categorie PA, intervallo, policy, limiti del proxy, input invalidi ed effetto matematico sulla sola componente Nes.
- **Nessuna prova Apple:** app non compilate contro gli SDK, configurazione XcodeGen non eseguita, nessuno screenshot o test su dispositivi.
- **Nessuna validazione clinica:** dati sintetici e casi analitici non misurano accuratezza su persone. Non sono prove di equivalenza con Ultrahuman, Oura o Apple.
- **Qualità e mancanze:** fallback numerici, calibrazione per metrica, non-wear e interpolazione devono essere resi espliciti prima della produzione.
- **Persistenza:** scritture fallite, conferme applicative, cursori, retry, backup di sistema e migrazioni non sono completi.
- **Ambito:** profilo e formule non hanno ancora un controllo coerente della popolazione applicabile. Non estendere modelli a minori o condizioni cliniche senza evidenza specifica.
- **Storico PA:** serve versionamento e ricalcolo dei derivati se si riusa una v2 già popolata. Non è stato modificato lo schema persistente in questa patch.

Le funzioni rimanenti, i problemi riproducibili e i criteri di completamento sono elencati nel prompt. Il prossimo passo è una build reale con SDK Apple e correzioni guidate da test, non l'aggiunta di formule non pubblicate.
