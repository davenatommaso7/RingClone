# RingClone: prompt di sviluppo iPhone e Apple Watch

Questo è un prompt operativo da consegnare a un assistente di programmazione insieme al progetto RingClone aggiornato e al documento `CONFRONTO_E_DECISIONI.md`. Integra il codice di CIRUZZO LO SCUGNIZZ, la ricerca di GENNARO DONATO TOSCANO e il confronto del 10 novembre 2026; distingue ciò che esiste nei sorgenti da ciò che deve ancora essere completato e verificato.

## Incarico

Agisci come un gruppo di lavoro senior per Swift, iOS, watchOS, elaborazione dei segnali e qualità del software sanitario non diagnostico. Completa il progetto nativo RingClone per iPhone e Apple Watch partendo dai sorgenti allegati, senza riscrivere inutilmente ciò che funziona e senza fermarti a una proposta o a un'interfaccia dimostrativa.

L'obiettivo è offrire tutte le famiglie funzionali richieste sotto, ispirate a un anello smart, usando realmente i dati accessibili all'Apple Watch. Il progetto è indipendente e non ufficiale: non deve dichiarare di replicare gli algoritmi proprietari, i punteggi, l'accuratezza o l'hardware di Ultrahuman.

Il prodotto è un'app di benessere, non un dispositivo medico. Interfaccia, documenti, commenti nuovi e spiegazioni devono essere in italiano; i nomi tecnici delle API possono restare quelli originali.

## Regole non negoziabili

- **Codice esistente:** leggi prima `Package.swift`, `Sources/RingCore`, `Tests/RingCoreTests`, `Apps/iOS`, `Apps/watchOS` e `project.yml`. Considera il codice la prova di cosa sia implementato; una descrizione nel README non dimostra che una funzione sia completa.
- **Novità scientifiche:** cambia una formula soltanto con una fonte consultata, coefficienti e unità espliciti, dominio di applicazione e input compatibili. Correggere bug deterministici o provenienza dei dati è un lavoro distinto: aggiungi un test che dimostri il problema, non mascherarlo ritoccando le soglie.
- **Proprietà intellettuale:** usa modelli pubblicati e assunzioni dichiarate. Nelle pagine consultate Ultrahuman descrive i contributori ma non pubblica formule complete e pesi di Sleep Index, Movement Index e Recovery; non inventarli come se fossero ufficiali ([Sleep Index](https://www.ultrahuman.com/science/explainers/sleep-index/), [Movement Index](https://www.ultrahuman.com/science/explainers/movement-index/), [Recovery](https://www.ultrahuman.com/science/explainers/recovery-score/)).
- **Dati mancanti:** mai trasformare assenza, mancato utilizzo, autorizzazione non accertabile o errore in una misura uguale a zero, in “tutto normale” o in una notte intera di veglia. Mostra “Non disponibile”, “Dati insufficienti”, “In calibrazione” o “Dato non aggiornato” con il motivo.
- **Niente falsi risultati:** non dichiarare build, screenshot, prove su hardware, autonomia o accuratezza non realmente ottenuti. Test sintetici, controlli di sintassi e controlli con framework fittizi non equivalgono a compilazione con SDK Apple né a validazione fisiologica.
- **Niente tuning cosmetico:** non modificare i pesi per far apparire una giornata “buona”, raggiungere una percentuale di accuratezza o far passare un test. Conserva le assunzioni attuali finché non esiste un confronto indipendente.
- **Niente funzioni cliniche implicite:** niente diagnosi di apnea, febbre, infezione, aritmia, età biologica o rischio cardiovascolare dai punteggi. Gli avvisi devono descrivere variazioni rispetto allo storico, non prescrivere trattamenti o allenamenti.

## Stato iniziale e architettura da conservare

Il punto di partenza è un prototipo con logica eseguibile, non un'app già pronta per App Store. RingCore è un pacchetto Foundation in modalità Swift 6; le app sono scritte in SwiftUI, configurate attualmente in modalità Swift 5 e non ancora compilate contro gli SDK Apple.

- **Target:** sono dichiarati iOS 17+, watchOS 10+ e macOS 14+ per il pacchetto. Usa l'ultima versione stabile di Xcode e degli SDK effettivamente disponibile nel tuo ambiente, verificane numeri e compatibilità; non ricavare la versione corrente da vecchi documenti del progetto.
- **Motore puro:** preserva `DailyPipeline.run(input, profile:, history:)`, determinismo, rielaborazione idempotente, storico cronologico e sostituzione del report dello stesso giorno. La notte corrente non deve entrare nella baseline contro cui viene valutata.
- **Separazione:** mantieni HealthKit, CoreMotion, WatchConnectivity e SwiftUI fuori da RingCore. Gli adattatori trasformano i dati di piattaforma in tipi indipendenti e testabili.
- **Moduli:** `Models`, `Stats`, `DSP`, `PPG`, `HRV`, `Temperature`, `HeartRate`, `Motion`, `SleepDetection`, `SleepStaging`, `SleepMetrics`, `Activity`, `Stress`, `Recovery`, `Circadian`, `Fitness`, `History`, `DailyPipeline`, `Transfer`, `Presentation`, `Synthetic`.
- **iPhone:** `HealthRepository` legge Salute; `DayAssembler` prepara gli input; `PhoneConnectivity` riceve il movimento; `Store` coordina elaborazione, profilo e storico; `RingApp` e `DashboardView` gestiscono ciclo di vita e UI.
- **Watch:** `MotionRecorder` prepara le epoche, `WatchLink` trasferisce i file, `WorkoutManager` gestisce gli allenamenti, `WatchApp` presenta l'interfaccia.
- **Presente e da integrare:** il prototipo ha letture HealthKit elencate in `HealthRepository`, workout Watch con avvio/fine, trasferimento del movimento e zone FC. Non importa ancora SDNN quantitativa, non ha pausa/ripresa dei workout né riepilogo dei punteggi sul Watch; `WatchSettings` trasferisce soltanto RHR/FCmax/zone. Import HRV quantitativa, controlli mancanti e riepilogo con payload versionato sono lavoro futuro, non funzioni già collaudate.
- **Tempo:** epoche di 30 secondi allineate a Unix; notte attribuita al giorno del risveglio; passi, energia e attività attribuiti al giorno locale. Rendi esplicite le finestre che attraversano mezzanotte, l'ora legale, i viaggi e le registrazioni di sonno diurne.
- **Baseline reali del codice:** `History.swift` usa fino a 60 giorni per RHR, lnRMSSD, temperatura e respiro, con almeno 7 valori validi per ciascuna statistica; 7 giorni per il trend HRV, 14 per gli orari, 28 per alcuni aggregati e il carico. Non sostituire questi valori con “28 giorni per tutto”: era una semplificazione inesatta nella documentazione precedente.

## Sensori, API e disponibilità reale

### Contratto delle sorgenti

Costruisci una matrice modello di dispositivo, versione OS, disponibilità API, consenso, presenza di dati e limiti. Una proprietà disponibile nell'SDK non garantisce che ogni Apple Watch produca il relativo campione.

| Dato | Percorso richiesto | Vincolo |
|---|---|---|
| FC | HealthKit; durante allenamenti anche live workout builder | Campionamento irregolare fuori allenamento; non promettere FC continua. |
| Intervalli battito-battito | `HKHeartbeatSeriesSample` e query associata | Usa timestamp e segnalazioni di interruzione; la serie è un dato elaborato, non PPG grezza ([Apple](https://developer.apple.com/documentation/healthkit/hkdatatypeidentifierheartbeatseries)). |
| HRV SDNN | `heartRateVariabilitySDNN` | Metrica distinta dall'RMSSD, con unità di tempo; Apple la definisce come deviazione standard degli intervalli NN ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn)). |
| HRV RMSSD nativa | `heartRateVariabilityRMSSD`, se verificabile con SDK e hardware | Il simbolo è documentato da iOS/watchOS 27.0, ma la pagina consultata non descrive finestra, frequenza o qualità ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd)). Non dedurre tali proprietà dal solo nome. |
| Temperatura del polso durante sonno | `appleSleepingWristTemperature` | Apple aggrega i campioni in un singolo valore per la notte; questo valore non identifica l'ora del minimo ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature)). |
| Accelerazione | `CMSensorRecorder`, se supportato | 50 Hz, richiesta massima di 12 ore, dati disponibili fino a 3 giorni; la riattivazione dell'app non è una garanzia di copertura continua ([Apple](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:))). |
| Rotazioni e device motion in alta frequenza | `CMBatchedSensorManager`, quando supportato | L'accesso descritto da Apple richiede un allenamento HealthKit attivo; non avviare finti allenamenti notturni per aggirare i limiti ([Apple, WWDC 2023](https://developer.apple.com/videos/play/wwdc2023/10179/)). |
| Sonno e fasi | `sleepAnalysis` | Conserva sorgente e categoria originale; separa sonno non classificato da leggero, profondo e REM. |
| Respirazione, SpO₂, passi, energia, workout, VO₂ max, luce diurna | Tipi HealthKit pertinenti, se disponibili | Tratta ogni canale come opzionale e documenta unità, intervallo di validità e condizioni di disponibilità. |

- **PPG grezza:** il percorso Apple attualmente scritto non acquisisce la forma d'onda ottica. `PPG.swift` elabora array forniti dall'esterno; non costituisce un driver BLE né un collegamento a un anello reale.
- **Estensioni hardware:** conserva l'interfaccia per importare PPG, temperatura continua e inerziale da sensori esterni. Non aggiungere dispositivi o protocolli BLE ipotetici; un'integrazione reale richiede modello, protocollo e autorizzazione specifici.
- **Nuova API RMSSD:** usa controlli di disponibilità a runtime e una strategia di compilazione compatibile con l'SDK effettivo. `#available` non rende compilabile un simbolo assente dall'SDK; finché la semantica non è verificata, mantieni separati RMSSD importato, RMSSD da serie e SDNN.
- **Unità:** bpm; intervalli NN/HRV in ms; respirazione in atti/min; temperatura in °C; accelerazione in g o mg espliciti; rotazione in rad/s all'ingresso e gradi/s se convertita; durata in s/min/ore senza mescolarle; energia in kcal; VO₂ max in mL·kg⁻¹·min⁻¹.

### Provenienza e qualità

Introduci un risultato per metrica con valore opzionale, unità, sorgente, tipo di derivazione, finestra, copertura, quantità di dati validi, versione algoritmo, aggiornamento e motivi di indisponibilità. Distingui almeno importato, calcolato da segnale, interpolato, stimato da modello, euristica e non disponibile.

- **Qualità:** usa indicatori verificabili di copertura, artefatti e continuità. Una categoria “qualità alta” non è una probabilità del 95% o un intervallo di confidenza clinico.
- **Contesto HRV:** registra metrica, origine e durata della finestra; valori ottenuti su durate differenti non sono automaticamente intercambiabili, e la variabilità ottica è PRV, non una misura ECG identica in ogni condizione ([revisione HRV/PRV](https://pmc.ncbi.nlm.nih.gov/articles/PMC10742885/)).
- **Calibrazione:** valuta la readiness per ogni baseline, non soltanto il numero totale di notti. Mostra le misure grezze valide anche in calibrazione, ma non mostrare come affidabile un punteggio personalizzato che dipende da baseline non pronte.
- **Riproducibilità:** registra versione di algoritmo e parametri; conserva i dati importati separati dalle derivazioni. Non mescolare nello storico risultati ottenuti con versioni incompatibili senza una migrazione documentata.

## Specifica degli algoritmi

Le formule seguenti descrivono il motore da preservare e i suoi confini, salvo la correzione PA-index già integrata. “Euristica” significa scelta locale non validata clinicamente, non formula ufficiale di Ultrahuman.

### PPG, battiti, cuore e respiro

- **PPG esterna:** conserva il passa-banda 0,5–4 Hz, rilevazione dei picchi a due medie mobili, rifinitura sub-campione, riconoscimento dell'inversione, qualità morfologica e penalizzazione degli artefatti di movimento. I parametri rimangono quelli del codice; non chiamare la semplice esclusione degli artefatti “filtro Kalman”.
- **FC:** per intervalli NN in millisecondi, \(FC=60\,000/\overline{NN}\). Se importata da HealthKit, conserva valore e contesto; distingui FC corrente, media notturna, RHR e massimo osservato.
- **RHR:** preserva la definizione locale di minimo delle medie su finestre di cinque minuti nel sonno, con copertura documentata. La RHR di un altro sistema può avere una definizione differente; non rimpiazzare silenziosamente l'una con l'altra.
- **NN validi:** nel codice, 300–2.000 ms ed entro il 20% della mediana locale. È una regola di filtraggio locale, non una soglia diagnostica; conserva l'adiacenza e non ricucire differenze attraverso battiti rimossi o gap.
- **RMSSD:** \(RMSSD=\sqrt{\sum_{(i-1,i)\in V}(NN_i-NN_{i-1})^2/|V|}\), dove \(V\) contiene soltanto coppie contigue valide dentro la finestra. Se tutte le coppie sono valide, \(|V|=N-1\).
- **SDNN:** \(SDNN=\sqrt{\sum_i(NN_i-\overline{NN})^2/(N-1)}\). Non derivare RMSSD da SDNN; non sostituire lnRMSSD con lnSDNN in Recovery o Stress senza un modello e una baseline separati.
- **Altre metriche HRV:** conserva pNN50, SD1/SD2 e Baevsky; dichiara convenzioni di unità, binning e limiti. Il codice aggrega geometricamente gli RMSSD di finestre e aritmeticamente le SDNN: non chiamare tale risultato “SDNN dell'intera notte”.
- **FC massima e zone:** conserva Tanaka \(208-0,7\cdot età\), cinque fasce 50–60–70–80–90–100% di FCmax, override esplicito e opzione Karvonen \(RHR+p(FCmax-RHR)\); Tanaka e le bande percentuali sono dichiarate da Ultrahuman, mentre override e Karvonen sono scelte del nostro prodotto ([Ultrahuman](https://www.ultrahuman.com/science/explainers/heart-rate-zones/)).
- **Zone nel tempo:** integra i campioni in base alla durata osservata con limite al mantenimento dell'ultimo campione. Non contare ore mancanti come permanenza in zona; conserva TRIMP di Edwards, somma dei minuti per indice di zona.
- **Respiro:** preferisci il dato notturno importato quando valido; come riserva usa l'RSA da NN, ricampionamento 4 Hz, detrending, banda 0,1–0,5 Hz, controllo di densità e qualità. Non presentare questo come fusione PPG AM/BW/FM: tale fusione richiede altri segnali e un modello dedicato ([studio sulla fusione respiratoria](https://journals.plos.org/plosone/article?id=10.1371/journal.pone.0249843)).
- **SpO₂:** mostra soltanto il dato disponibile dalla sorgente con limiti e provenienza. Non ricavare saturazione da una PPG monocanale non calibrata e non costruire una diagnosi di apnea dal respiro medio o dalle desaturazioni.

### Temperatura e movimento

- **Temperatura continua esterna:** conserva mediana del sonno escludendo i primi venti minuti e minimo della curva lisciata su trenta minuti. Il minimo cutaneo è un proxy periferico, non temperatura centrale o DLMO.
- **Temperatura Apple:** usa il valore notturno e la deviazione dalla baseline personale. Se non c'è la curva, il minimo non è misurato; l'eventuale fallback da orari deve avere tipo e testo differenti.
- **Inerziale:** mantieni accumulo in streaming, intensità MAD in mg su blocchi di cinque secondi, variazione dell'angolo del braccio e passi di riserva. L'angolo derivato dall'accelerazione non equivale a una misura del giroscopio.
- **Rotazioni:** preserva il campo di velocità angolare raccolto negli allenamenti. Il codice attuale lo registra ma nessun punteggio lo usa: non affermare il contrario né aggiungerlo ai punteggi senza un modello verificato.

### Sonno, fasi, continuità e Sleep Index

- **Segmentazione:** separa notte principale, sonnellini e veglia; non delimitare la notte con il minimo e massimo di tutti i campioni delle ventiquattro ore. Preserva l'associazione della notte al giorno del risveglio e gestisci notte ancora in corso.
- **Sorgenti:** preferisci una sorgente esplicita, senza sommare sovrapposizioni provenienti da app diverse. Conserva le fasi native Apple senza modificarle silenziosamente; usa l'HMM come riserva sperimentale o confronto separato.
- **Categorie:** `asleepUnspecified` significa sonno senza fase nota, non sonno leggero. `inBed` è un intervallo a letto, non una fase; dati mancanti e “fase ignota” devono restare distinti.
- **Modello locale:** HMM a quattro stati con Viterbi, osservazioni di movimento/FC/lnRMSSD/instabilità cardiaca, priori temporali e adattamento MAP. Concordanza esterna 0,75, due passate, bias del profondo −0,2 e riassorbimento di una singola epoca di veglia sono euristiche del prototipo; non ritoccarle usando risultati sintetici o accuratezze pubblicate di altri dispositivi.
- **Definizioni:** distingui ingresso a letto/luci spente, primo sonno, sonno persistente, ultimo risveglio e alzata. TIB include la latenza se il periodo a letto è osservato; TST conta soltanto epoche di sonno; WASO conta veglia dopo l'addormentamento; efficienza \(100\cdot TST/TIB\). Se TIB non è noto, dichiara l'approssimazione, non un'efficienza clinica esatta.
- **Metriche richieste:** durata totale e per fase, latenza, risvegli, WASO, efficienza, continuità, tratto più lungo, frammentazione, movimenti, cicli stimati, orari, regolarità e sonnellini. N3+REM è la quota di sonno ristoratore usata dal prodotto; non equivale a una misura diretta di “riparazione” dell'organismo ([Ultrahuman Sleep Index](https://www.ultrahuman.com/science/explainers/sleep-index/)).
- **Sleep Index locale:** \(100(0,30D+0,20Q+0,20R+0,15T+0,15V)\). D = durata rispetto al bisogno; Q = tranquillità; R = quota N3+REM; T = orario/consistenza; V = RHR, posizione del nadir e temperatura. Pesi e normalizzazioni sono locali; l'orario del minimo cardiaco è già presente, non una funzione da inventare.
- **Tranquillità locale:** conserva 0,55 efficienza + 0,25 risvegli + 0,20 latenza e le normalizzazioni in `SleepMetrics.swift`. Non confondere punteggio normalizzato 0–1 con percentuale 0–100.
- **SRI:** preserva l'algebra \(SRI=-100+200(A/T)\), con accordi A e confronti validi T, distinguendola dalla consistenza degli orari. Per la versione completa usa epoche di trenta secondi, osservazione valida e confronto temporale definito; GGIR esplicita trattamento del non-wear come mancante, scala −100…100 e giorni mezzogiorno-mezzogiorno ([GGIR](https://wadpac.github.io/GGIR/articles/SleepRegularityIndex)).
- **Debito locale:** \(D_t=\max(0,0,85D_{t-1}+bisogno-sonno_t)\), finestra quattordici giorni, sonnellini inclusi, giorni mancanti non trasformati in zero sonno. Il default nel codice è otto ore modificabili; 0,85 è un parametro locale e, quando si saltano giorni mancanti, non è un decadimento fisiologico per giorno di calendario.
- **Confronto con Oura:** bisogno su novanta giorni, minimo cinque notti e categorie del debito sono descrizioni di Oura, non una nuova formula Ultrahuman. Non sostituire il nostro modello con una somma di deficit o bisogno automatico solo sulla base di questa analogia ([Oura Sleep Debt](https://support.ouraring.com/hc/en-us/articles/46233324892691-Sleep-Debt)).

### Attività, allenamenti, calorie e Movement Index

- **Passi:** preferisci il conteggio disponibile da Salute con deduplicazione verificata; usa il rilevatore inerziale come riserva identificata. Non sommare automaticamente conteggi iPhone, Watch e locali sullo stesso intervallo.
- **Attività locale:** ora attiva con almeno 250 passi oppure cinque minuti oltre soglia moderata, in un'ora con almeno trenta minuti di veglia; minuti attivi da cadenza almeno cento passi/min o FC sopra soglia. Inattività soltanto dove è dimostrata la copertura, non dove manca l'orologio.
- **Allenamenti:** importa quelli salvati in Salute, consenti avvio/pausa/fine dal Watch secondo le API reali e mantieni il riconoscimento automatico separato. Evita duplicati e sovrapposizioni; distingui allenamento confermato e candidato automatico.
- **Riconoscimento locale:** almeno dieci minuti sopra soglia cardiaca, tolleranza di due minuti e movimento per almeno metà del periodo. Una FC alta da seduti non deve diventare un workout; la cadenza differenzia cammino, corsa e attività generica.
- **Energia:** usa energia attiva/basale importata quando valida, senza contare due volte i workout. Come riserva mantieni Mifflin-St Jeor, Keytel durante esercizio e costo locale dei passi; nessuna promessa di precisione calorimetrica.
- **Mifflin locale:** uomini \(10m+6,25h-5a+5\), donne \(10m+6,25h-5a-161\), con kg, cm, anni e risultato kcal/giorno. Registra l'applicabilità della formula alla popolazione, non stimare il dispendio di un minore con coefficienti per adulti.
- **Movement Index locale:** \(100[0,45s^{0,8}+0,35a+0,20w]\), con s = passi/max(obiettivo, 1.000), a = ore attive/9, w = workout negli ultimi sette giorni/4, ciascun rapporto limitato a 0–1 prima di applicare i pesi e la potenza. Ultrahuman conferma i tre ingredienti, non questi pesi o soglie ([Ultrahuman Movement Index](https://www.ultrahuman.com/science/explainers/movement-index/)).
- **MET alternativo:** non sostituire Keytel con \(MET=6FC/RHR-5\). Nel lavoro consultato è una caratteristica di un modello VO₂ max addestrato, non una validazione generale della nostra spesa energetica ([Scientific Reports](https://link.springer.com/article/10.1038/s41598-023-43024-x)).

### Stress e recupero

- **Stress locale:** finestre di cinque minuti in veglia, fuori dagli allenamenti e dal recupero immediato; usa FC rispetto alla RHR, Baevsky e RMSSD. Il codice normalizza \(z_{FC}=(FC-1,30RHR)/(0,13RHR)\), \(z_{SI}=(\ln SI-\ln150)/0,8\), e lnRMSSD rispetto alla baseline notturna meno 0,5.
- **Combinazione locale:** se tutti gli ingressi esistono, \(z=0,40z_{FC}+0,30z_{SI}-0,30\,\mathrm{clamp}(z_{HRV},-3,3)\), seguito da \(100\,\mathrm{logistica}[1,2\,\mathrm{clamp}(z,-4,4)-0,4]\). Il denominatore dello z-score HRV è max(dispersione, 0,3); conserva anche i rami parziali del codice ma contrassegnali, perché una stima solo-FC non ha la stessa qualità.
- **Contesto:** aggiungi controllo del movimento anche senza passi, buchi e recupero dall'esercizio. Non confondere attivazione fisiologica con ansia o stress percepito.
- **Stress Rhythm locale:** parte da cento, perde punti nelle finestre oltre settanta, con peso serale maggiore. È un indice euristico distinto dalla curva dello stress; l'assenza di finestre non dimostra una giornata senza stress.
- **Recovery locale:** contributi standardizzati e limitati, pesi sonno 0,30, RHR 0,25, HRV Form 0,30, temperatura 0,15; \(100\,\mathrm{logistica}(1,1+0,9\bar z)\) con contributo dello Stress Rhythm fino a ±10 punti. Solo la struttura dei cinque contributori e il limite ±10 sono descritti dal produttore, non i coefficienti locali ([Ultrahuman Recovery](https://www.ultrahuman.com/science/explainers/recovery-score/)).
- **Avvisi:** mostra variazioni relative e dati necessari a interpretarle. ACWR e deviazioni di temperatura/FC/HRV non devono essere trasformati in probabilità di infortunio o diagnosi.
- **Invito alla valutazione medica:** nelle informazioni educative, invita a rivolgersi a un professionista per russamento con pause respiratorie riferite, sonnolenza diurna marcata o FC a riposo persistentemente insolita. Non dichiarare che l'app rilevi tali sintomi o diagnostichi le loro cause; non fissare soglie cliniche nuove.

### Ritmo circadiano e Social Jetlag

- **Social Jetlag:** differenza circolare tra i punti medi del sonno nei giorni liberi e lavorativi, in valore assoluto per la metrica senza direzione. Conserva separatamente SJL, correzione per debito e cronotipo MSFsc; non scambiare queste grandezze ([Ultrahuman Social Jetlag](https://www.ultrahuman.com/science/explainers/social-jetlag/)).
- **Classificazione:** giorni lavorativi impostabili, eccezioni e turni gestibili; la notte è legata al giorno di risveglio. Non assumere che libero significhi sempre sabato o domenica.
- **Allineamento locale:** 0,40 fase + 0,35 SRI + 0,15 luce diurna + 0,10 jetlag; componenti mancanti attualmente assumono 0,7. Per il prodotto, rendi visibile l'insufficienza invece di presentare tale valore neutro come misura personale.
- **Finestre:** Minima ±15 minuti, Delay da otto a quattro ore prima del minimo, Advance dopo il minimo, Dead Zone intermedia; le durate complete e il punteggio non sono pubblicati dal produttore ([Ultrahuman Circadian Alignment](https://www.ultrahuman.com/science/explainers/circadian-alignment/)).
- **Fallback:** il codice usa risveglio meno due ore quando manca la curva. Mostra “stima da orari”, non “minimo di temperatura misurato”; senza orari affidabili non produrre una fase personale.
- **Consigli:** le finestre di luce, caffeina, pasti e allenamento sono suggerimenti di routine locali, non una PRC individuale né cronoterapia. Non introdurre soglie cliniche universali, incluso un presunto limite SJL di venti minuti.

### VO₂ max: correzione integrata del PA-index

Le equazioni BMI presenti sono confermate da una pubblicazione che le riporta; non vanno sostituite con le varianti basate sulla circonferenza vita ([Jalene e colleghi](https://pmc.ncbi.nlm.nih.gov/articles/PMC6759774/)). Conserva output in mL·kg⁻¹·min⁻¹:

\[
VO_{2,u}=92,05-0,327a-0,933BMI-0,167RHR+0,257PA
\]
\[
VO_{2,d}=70,77-0,244a-0,749BMI-0,107RHR+0,213PA
\]

La correzione emersa dal confronto riguarda l'input PA, non questi coefficienti. Il prodotto fra frequenza, intensità e durata è descritto negli studi HUNT e in un articolo che lo attribuisce a Nes; la vecchia codifica locale 0–45 è stata sostituita con una scala 0–15, mantenendo esplicito che il testo integrale di Nes 2011 non è stato consultato direttamente ([HUNT, codifiche](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [prodotto attribuito a Nes](https://pmc.ncbi.nlm.nih.gov/articles/PMC4121529/)).

| Componente | Codici da usare |
|---|---|
| Frequenza | Mai = 0; meno di una volta/settimana = 0 nel protocollo adottato; una volta = 1; due-tre = 2,5; quasi ogni giorno = 5 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Intensità percepita | Facile = 1; fiato corto e sudore = 2; quasi esaurimento = 3 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Durata | Meno di 15 min = 0,10; 15–29 min = 0,38; 30–60 min = 0,75; oltre 60 min = 1,00 ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |
| Combinazione | \(PA=f\cdot i\cdot d\), massimo \(5\cdot3\cdot1=15\), non somma ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/)). |

- **Variante esplicita:** un altro studio HUNT assegna 0,5 a “meno di una volta/settimana”; conserva la scelta del protocollo, non mescolare le codifiche e non nascondere la divergenza ([HUNT 2013](https://pmc.ncbi.nlm.nih.gov/articles/PMC3524509/)).
- **Questionario:** il calcolo categoriale è disponibile nel Core aggiornato ma non è collegato al profilo o alla pipeline. Integra il questionario esplicito con protocollo e data della risposta; nella futura app usa una risposta valida come prima fonte, mentre schermata e persistenza sono ancora da realizzare.
- **Proxy workout:** attualmente `DailyPipeline` usa questo percorso anche quando sarebbe preferibile il questionario; nella futura app deve diventare una riserva euristica identificata. La frequenza è ricostruita dagli allenamenti, l'intensità dalle frazioni della FC massima e la durata dalla mediana delle sessioni; questi passaggi non equivalgono al questionario originale e non ne ereditano la validazione.
- **Test analitico:** due-tre sessioni a settimana, sforzo moderato e quaranta minuti danno \(2,5\cdot2\cdot0,75=3,75\), non 15. A parità degli altri input, sostituire PA=15 con PA=3,75 cambia la sola stima Nes di −2,89125 negli uomini e −2,39625 nelle donne.
- **Uth:** conserva \(15,3FCmax/RHR\) come modello separato del prototipo; non attivarlo con una FC massima predetta etichettata erroneamente “misurata”. La conferma di un vero massimo/test è distinta dal superamento di una soglia percentuale di Tanaka.
- **Valori Apple/laboratorio:** conserva sorgente, data e freschezza. Priorità alla fonte più appropriata o fusione sono scelte progettuali, non regole ufficiali; un valore fuso non è un CPET misurato.
- **Incertezza:** la fusione a varianza inversa esistente assume implicitamente indipendenza, mentre Nes e Uth condividono la RHR. Non mostrare il SEE combinato come errore clinico dimostrato senza covarianze o validazione.
- **Modello Ultrahuman aggiornato:** la pagina consultata descrive una calibrazione contro CPET su 101 persone e un preprint, ma non espone formula e pesi sufficienti a implementarlo ([Ultrahuman VO₂ max](https://www.ultrahuman.com/blog/introducing-new-ultrahuman-vo2-max/)). Non sostituire Nes con un modello inventato né trasferire le prestazioni dichiarate al nostro codice.

### Cardio Age

Conserva l'inversione della tabella di mediane presente in `Fitness.swift`, il limite 18–90 e lo smoothing 0,85 precedente + 0,15 nuovo come scelte locali sperimentali. Verifica tabella normativa, popolazione, sesso usato dal modello e trattamento delle età estreme prima di trasformarla in una funzione destinata alla produzione.

- **Significato:** è un'età equivalente di fitness da VO₂ max stimato, non età dei vasi, PWV o “età vera del cuore”. Ultrahuman descrive conversione rispetto a norme per sesso e smoothing, ma non pubblica i parametri completi ([Ultrahuman Cardio Age](https://www.ultrahuman.com/science/explainers/cardio-age/)).
- **Incertezza:** mostra tendenza e limiti; non dichiarare che il clamp o un andamento stabile dimostrino accuratezza. La correzione PA può propagarsi a VO₂ max e Cardio Age, senza richiedere una modifica della formula di Cardio Age.
- **Migrazione:** uno storico calcolato con PA 0–45 non va mescolato senza spiegazione con quello nuovo. Versiona i risultati e ricalcola in ordine cronologico l'intero intervallo necessario, inclusi gli antecedenti dello smoothing; non cancellare dati di salute né invalidare silenziosamente l'archivio.

## Problemi noti da affrontare prima della produzione

Questi sono rilievi sul codice, non nuove formule fisiologiche. Nella consegna del confronto è stato corretto solo PA-index; i punti seguenti devono diventare test di regressione e attività esplicite nella realizzazione dell'app.

- **HRV ai bordi:** `HRV.metrics` può usare il `diff` del primo battito di una slice anche se il predecessore è esterno alla finestra. Testa l'esclusione delle coppie transfrontaliere e la copertura temporale effettiva, non solo il conteggio di battiti.
- **TIB e TST:** `SleepDetection` ignora i segmenti senza fase usati per “a letto”; `SleepMetrics` può includere in `sleepRuns` frammenti precedenti all'onset persistente che non rientrano in TST. Rendi coerenti definizioni, periodi e somma delle durate.
- **Sonnellini:** una sessione unita può includere buchi di veglia contati come sonno. Separa durata della sessione e durata effettivamente dormita prima di alimentare debito e SRI.
- **Fasi importate:** il codice attuale riclassifica anche le fasi esterne tramite HMM e converte `asleepUnspecified` in leggero. Per l'app completa, conserva fasi originali e stima sperimentale come risultati distinti.
- **SRI e calendario:** il codice usa minuti e presume veglia fuori dagli intervalli di sonno; coppie di giorni locali possono essere separate da 23/25 ore. Definisci osservazione valida, griglia e confronto temporale prima di correggere.
- **FCmax e Uth:** `HeartRate.hrMax` può restituire Tanaka ma impostare `measured=true` sulla base di un picco vicino al predetto. Separa valore predetto, massimo osservato e massimo confermato.
- **Fallback fuorvianti:** RHR=60, Stress Rhythm=100 senza finestre, allineamento neutro e Tmin=risveglio−2h non devono apparire come misure personali affidabili.
- **Stress e movimento:** il filtro attuale usa passi e workout; gestisci anche movimento senza passi, artefatti e stato del dispositivo.
- **Energia zero:** zero osservato e dato assente sono diversi. Verifica i rami che trattano energia HealthKit uguale a zero come mancante.
- **Persistenza Watch:** gestione degli errori oggi incompleta; non avanzare definitivamente il cursore o eliminare file prima della persistenza confermata. Prevedi reinvii idempotenti, integrità, versione del formato e conferma applicativa.
- **Profilo:** il modulo consente oggi età pediatriche pur usando modelli per adulti. Limita le stime al dominio supportato o rendile indisponibili; valida numeri facoltativi, valori non finiti, dati corporei e input di laboratorio.

## Esperienza iPhone e Watch

### iPhone

Realizza un'app nativa chiara e accessibile, con navigazione per giorno e trend, non una copia dei marchi o delle schermate Ultrahuman. Riusa le viste esistenti dove possibile e rendi visibili gli stati del dato.

- **Onboarding e profilo:** privacy, consenso contestuale, collegamento Watch, età e parametri corporei necessari, bisogno di sonno, obiettivo passi, giorni lavorativi, FCmax confermata opzionale, VO₂ di laboratorio datato e questionario PA.
- **Oggi:** sonno, recupero e movimento con scomposizione dei contributi, copertura e ultimo aggiornamento. Mostra chiaramente giorno ancora in corso e notifiche di dati tardivi.
- **Sonno:** ipnogramma con sorgente, durata, fasi, risvegli, TIB/TST/SOL/WASO, efficienza, continuità, ristoratore, orari, regolarità, sonnellini e debito.
- **Cuore:** FC, RHR, RMSSD e SDNN distinti, respirazione notturna, temperatura e relative baseline; SpO₂ soltanto se presente.
- **Attività:** passi, ore attive/inattive, sedentarietà osservata, workout, minuti in zona, TRIMP ed energia con origine.
- **Stress e ritmo:** timeline, copertura, Stress Rhythm, finestre circadiane e Social Jetlag con spiegazioni non diagnostiche.
- **Fitness:** VO₂ max con metodo e data, contributi se fusi, Cardio Age sperimentale e trend senza falsa precisione.
- **Controllo utente:** nascondere i punteggi se generano preoccupazione, correggere classificazione libero/lavorativo, scegliere sorgente, esportare o cancellare volontariamente i dati dell'app.
- **Accessibilità:** VoiceOver, Dynamic Type, contrasto, alternative testuali ai grafici, unità e decimali italiani; il colore non deve essere l'unico segnale.
- **Dimostrazione:** preserva la modalità dimostrativa esistente con banner persistente e verifica del ritorno ai dati reali. Nessuna scrittura dei dati sintetici in Salute o negli archivi reali e nessuna propagazione verso il Watch come misura personale.

### Apple Watch

L'app Watch deve funzionare come compagna operativa, non promettere acquisizione continua che il sistema non garantisce. Ogni dato sintetico o provvisorio deve essere riconoscibile.

- **Riepilogo:** ultimo aggiornamento e indicatori disponibili, con tempo trascorso dall'ultima sincronizzazione.
- **Allenamenti:** avvio, controlli, fine e salvataggio reali; FC e zona in tempo reale quando disponibili; gestione errori, autorizzazioni e riavvio.
- **Movimento:** raccolta consentita dalle API, epoche compatte, coda persistente e trasferimento economico; stato di backlog e copertura.
- **Batteria:** misura i consumi su dispositivo e descrivi il compromesso. Non usare allenamenti fittizi, timers permanenti o promesse di background “sempre attivo”.

## Privacy, archiviazione e sincronizzazione

Elabora sul dispositivo per impostazione predefinita e non introdurre account, server, pubblicità o invio dei dati a modelli esterni. La sincronizzazione Watch-iPhone richiesta dal prodotto va distinta da qualunque sincronizzazione cloud facoltativa.

- **Permessi:** richiedi solo i tipi necessari, con descrizioni comprensibili. Gestisci revoca, iPhone bloccato, sorgente non disponibile e query vuote senza dedurre automaticamente il rifiuto alla lettura.
- **Protezione locale:** file protetti, scritture atomiche, errori visibili, schema versionato, retention dichiarata e log senza dati sanitari identificabili. Definisci e documenta inclusione o esclusione dei file sanitari nei backup di sistema e prova il ripristino; “locale” non significa automaticamente “mai incluso in un backup”.
- **Trasferimenti:** file idempotenti con identità e integrità, conferma della ricezione persistita, ripresa dopo interruzioni e nessuna duplicazione dei workout o dei dati.
- **Background:** usa observer/background delivery e refresh secondo le regole della piattaforma; completa le callback, gestisci scadenza e cancellazione. Visualizza i buchi e ricalcola all'apertura senza promettere orari garantiti.
- **Export:** locale, volontario, versionato e accompagnato da un avviso sui dati sensibili; verifica import, round-trip e file corrotti. La cancellazione riguarda i dati posseduti dall'app, non tutti i dati di Salute.
- **Migrazioni:** separa profilo, dati originari e report derivati; documenta ricalcolo quando cambiano modello, parametri o sorgenti. Non cancellare silenziosamente lo storico in caso di errore di decodifica.

## Procedura di sviluppo e accettazione

Lavora in fasi verificabili, ma porta l'attività fino a codice, test e istruzioni utilizzabili. Se non hai Xcode o un dispositivo, completa le parti possibili e indica il blocco senza fingere che l'app sia stata compilata o installata.

- **Audit iniziale:** inventario dei file e delle funzionalità, esecuzione dei test esistenti, controlli sull'SDK reale, elenco dei difetti riproducibili. Mantieni un registro “già presente / corretto / da fare / non verificato”.
- **Progetto Xcode:** genera o correggi target iPhone e Watch, dipendenza locale RingCore, firme, bundle ID, Info.plist e capability. `project.yml` è un punto di partenza non collaudato; non considerarlo una prova di build.
- **Test deterministici:** unità, formule PA e Nes, filtri/gap HRV, bordi delle finestre, fasi ignote, TIB/TST, sonnellini frammentati, SRI e missingness, dati non indossati, duplicati, limiti di dominio e propagazione degli errori.
- **Tempo e stato:** mezzanotte, notte in corso, giornate di 23/25 ore, cambio fuso, dati tardivi/cancellati, rielaborazione, cambio profilo e migrazione della versione PA.
- **Integrazione:** permessi negati/parziali, telefono bloccato, Watch offline, trasferimenti ripetuti, fallimento di scrittura, riavvio, scadenza dei task e salvataggio workout.
- **UI:** snapshot o screenshot reali, VoiceOver e Dynamic Type, modalità scura, stati vuoti/obsoleti/calibrazione, nessun numero fittizio presentato come misura.
- **Hardware:** prova su iPhone e Watch fisici con versioni dichiarate; raccogli tempi, copertura e batteria realmente osservati. Un simulatore o uno stub non dimostra funzionamento dei sensori.
- **Validazione scientifica separata:** non chiamare clinici i test sintetici. Per affermazioni di accuratezza serve un protocollo indipendente con riferimenti adatti, per esempio PSG per sonno, ECG per battiti/HRV e CPET per fitness; non trasferire percentuali di altri prodotti.

## Consegna richiesta

Consegna il progetto completo aggiornato, non soltanto pseudocodice o schermate. Includi sorgenti, progetto Xcode o configurazione riproducibile, test, dati sintetici marcati, guida all'installazione, registro delle formule con fonti e ipotesi, migrazioni, log di verifica e limiti residui.

- **Resoconto:** elenca esattamente quali file e formule sono cambiati e perché; specifica quali formule sono rimaste invariate. Per ogni miglioramento distingui correttezza matematica, correttezza software e validazione su persone.
- **Evidenze:** allega screenshot o registrazioni soltanto delle interfacce realmente eseguite e riporta comandi, SDK e dispositivi utilizzati. Se una parte non è verificata, scrivi “non verificata” vicino alla relativa funzione.
- **Chiusura:** indica blocchi residui e azioni necessarie per poter installare e usare l'app. Non dire “pronta per App Store” finché firma, build, privacy, test su hardware e controlli di distribuzione non sono realmente completati.
