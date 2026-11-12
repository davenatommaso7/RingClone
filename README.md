# RingClone: progetto iPhone e Apple Watch

RingClone è un prototipo indipendente e non ufficiale per funzioni di sonno, attività, recupero e fitness ispirate a un anello smart. Usa un motore Swift separato dalle app native iPhone e Apple Watch; non è un dispositivo medico e non promette risultati identici a quelli di Ultrahuman.

Questa versione v2.1 integra il confronto con GENNARO DONATO TOSCANO del 10 novembre 2026. La modifica algoritmica è limitata al PA-index di Nes; il resto del motore è invariato e i lavori necessari per completare le app sono raccolti nel prompt.

## Da dove iniziare

- **Prompt di sviluppo:** `docs/PROMPT_APP_IPHONE_APPLE_WATCH.md`. Contiene requisiti completi, formule, limiti delle sorgenti, problemi noti e criteri di accettazione per entrambe le app.
- **Confronto e decisioni:** `docs/CONFRONTO_E_DECISIONI.md`. Distingue correzione applicata, formule mantenute, fonti e attività future.
- **Analisi tecnica:** `docs/ANALISI.md`. Descrive il motore attuale e i limiti che non sono stati risolti in questa patch.
- **Xcode:** `docs/CONFIGURAZIONE_XCODE.md`. Checklist non collaudata per compilare e installare le app su un ambiente Apple reale.

## Correzione della v2.1

La precedente scala PA 0–45 era un mio errore, non un difetto da attribuire al progetto originale. Il prodotto delle codifiche pubblicate negli studi HUNT produce una scala 0–15; il testo integrale di Nes 2011 non è stato letto direttamente, quindi la ricostruzione è dichiarata come evidenza indiretta da articoli correlati ([HUNT 2012](https://pmc.ncbi.nlm.nih.gov/articles/PMC3445602/), [applicazione che cita Nes](https://pmc.ncbi.nlm.nih.gov/articles/PMC4121529/)).

- **Core:** questionario tipizzato, protocollo esplicito per attività meno che settimanale, proxy da workout riallineato e controlli su giorni/FCmax invalidi.
- **Test:** sei nuovi test; il caso di tre allenamenti moderati settimanali da quaranta minuti passa da PA 15 a PA 3,75.
- **Invariato:** coefficienti Nes, Uth, fusione VO₂ max, Cardio Age e tutti gli altri algoritmi. Nessuna modifica a interfacce o schema dei dati.
- **Ancora da integrare:** la pipeline usa tuttora il proxy da workout; questionario nel profilo, precedenza della risposta e migrazione dello storico sono richiesti dal prompt ma non implementati.

## Struttura

```text
Package.swift                 pacchetto RingCore, modalità Swift 6
Sources/RingCore/             logica pura, solo Foundation
Tests/RingCoreTests/          45 test del motore e dei testi di presentazione
Apps/iOS/                    HealthKit, assemblaggio, archivio, SwiftUI
Apps/watchOS/                movimento, trasferimenti e allenamenti
project.yml                  configurazione XcodeGen, non collaudata
docs/                        prompt, confronto, analisi e guida Xcode
docs/verifiche/               log Swift e patch PA-index
```

Le destinazioni minime dichiarate sono iOS 17, watchOS 10 e macOS 14 per il pacchetto. Le app sono configurate in modalità Swift 5, mentre RingCore usa Swift 6; questi sono parametri del progetto, non una dichiarazione sulle versioni correnti degli SDK.

## Provare il motore

Con una toolchain Swift 6, dalla cartella che contiene `Package.swift`, esegui il comando seguente. Non servono dati sanitari personali per i test inclusi.

```sh
swift test
```

Il risultato verificato su Linux con Swift 6.4.2 è `Executed 45 tests, with 0 failures`. Il log è incluso in `docs/verifiche/swift_test.log`; le prove sono deterministiche/sintetiche e non dimostrano accuratezza clinica.

## Famiglie funzionali nei sorgenti

| Area | Moduli | Stato e limite principale |
|---|---|---|
| PPG, battiti, HRV e respiro | `PPG`, `HRV`, `DSP` | Elaborazione di segnali forniti al Core; non acquisizione PPG grezza dal Watch né driver BLE. |
| FC, RHR, zone e carico | `HeartRate` | Tanaka/override/Karvonen e TRIMP; provenienza di FCmax da correggere prima dell'uso affidabile di Uth. |
| Temperatura | `Temperature` | Curva esterna oppure aggregato notturno; il minimo non è osservabile nel solo aggregato Apple. |
| Movimento | `Motion` | MAD, angolo, passi di riserva; rotazione registrata negli allenamenti ma non usata nei punteggi. |
| Sonno e fasi | `SleepDetection`, `SleepStaging` | Sessioni importate o rilevazione locale, HMM/Viterbi sperimentale; fasi native e riclassificate ancora da separare. |
| Metriche e punteggi del sonno | `SleepMetrics` | Durate, continuità, Sleep Index, regolarità e debito; problemi noti su TIB, frammenti e copertura SRI. |
| Attività ed energia | `Activity`, `Energy` | Passi, ore attive, workout, calorie e Movement Index; pesi e soglie locali. |
| Stress e recupero | `Stress`, `Recovery` | Stime fisiologiche relative, non diagnosi; qualità e stati di indisponibilità da rafforzare. |
| Ritmo circadiano | `Circadian` | SJL, allineamento e finestre; fallback da orari non equivale a fase misurata. |
| Fitness | `Fitness` | PA corretto, Nes/Uth e fusione; Cardio Age sperimentale. |
| Storico e presentazione | `History`, `DailyPipeline`, `Presentation` | Rielaborazione idempotente, baseline, testi e formati; calibrazione per metrica da completare. |

## Dati Apple: limiti importanti

- **HRV:** SDNN importata e RMSSD da intervalli non sono intercambiabili; HealthKit documenta SDNN e heartbeat series come percorsi differenti ([Apple SDNN](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilitysdnn), [Apple heartbeat series](https://developer.apple.com/documentation/healthkit/hkdatatypeidentifierheartbeatseries)). Il prototipo importa le serie, non ancora SDNN quantitativa.
- **RMSSD nativa:** il simbolo è documentato da iOS/watchOS 27.0, ma la pagina consultata non definisce finestra, frequenza e qualità ([Apple RMSSD](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd)). Non è stato aggiunto al codice: servono SDK compatibile e verifica sul percorso reale.
- **Temperatura:** il valore del sonno è aggregato sull'intera notte; non contiene l'ora del minimo ([Apple](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature)). Il fallback attuale da orari va etichettato correttamente.
- **Accelerazione:** il recorder documenta 50 Hz, massimo dodici ore per richiesta e conservazione fino a tre giorni ([Apple](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:))). Il prodotto non può promettere raccolta continua 24/7.
- **Alta frequenza:** il percorso descritto per i sensori batched richiede un workout attivo ([Apple WWDC 2023](https://developer.apple.com/videos/play/wwdc2023/10179/)). Non usare allenamenti fittizi per tenere l'app attiva durante il sonno.

## Verificato e non verificato

- **Verificato ora:** RingCore compila con Swift 6.4.2 Linux e supera 45 test su 45. I test aggiunti coprono codifica, range, policy, limiti e propagazione analitica della correzione PA.
- **Controlli precedenti:** i file app non grafici erano stati controllati contro moduli fittizi scritti a mano e i file SwiftUI solo per sintassi. Non erano e non sono una compilazione con SDK Apple.
- **Non verificato:** nessuna build Xcode, firma, prova su iPhone/Watch o schermata; `project.yml` non eseguito. Sensori, background, consumi e trasferimenti richiedono prove reali.
- **Non validato:** nessun confronto su persone con PSG, ECG o CPET. Pesi e soglie dei punteggi sono assunzioni locali, non formule proprietarie ricostruite.
- **Non pronto per produzione:** restano difetti su dati mancanti, provenienza, fasi del sonno, persistenza e ambito dei modelli. Il prompt li elenca senza confonderli con la sola modifica PA applicata.

## Storico, privacy e prossimi passi

Il codice non introduce server o account esterni e conserva i propri dati localmente, ma policy di backup, retention, errori di scrittura ed export richiedono ancora completamento. La demo esistente usa dati sintetici in memoria: non va trasformata in misure personali o salvata nei dati reali.

Se possiedi uno storico della v2, non mescolare senza versionamento risultati calcolati con PA 0–45 e PA 0–15. La migrazione e il ricalcolo cronologico sono specificati nel prompt, ma non inclusi nella patch focalizzata; per la prossima fase consegna insieme prompt e sorgenti aggiornati.
