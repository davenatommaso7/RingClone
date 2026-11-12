# Creare il progetto Xcode e installare le app

Questa è una checklist di preparazione, non una procedura già collaudata su Mac. Nell'ambiente usato per la consegna è stato compilato solo RingCore su Linux; le app iPhone e Watch, la firma e `project.yml` non sono stati verificati con Xcode.

Non viene fissato un numero di “Xcode corrente” sulla base dei vecchi documenti. Usa una versione stabile realmente installata e verifica SDK, target, template e capability disponibili prima di procedere.

## Materiale e prerequisiti

- **Sorgenti:** cartella completa RingClone, con `Package.swift`, `Sources`, `Tests`, `Apps` e `project.yml`. Leggi prima `PROMPT_APP_IPHONE_APPLE_WATCH.md` e `CONFRONTO_E_DECISIONI.md`.
- **Ambiente:** Mac con Xcode e SDK per iPhone/Watch, iPhone e Apple Watch abbinati per le prove sensoriali. Un simulatore non dimostra accesso a dati reali né autonomia.
- **Firma:** configura un team e un profilo validi per i target scelti. Verifica nel tuo account Apple le capability disponibili; questa consegna non stabilisce quali siano utilizzabili con un account gratuito.
- **Minimi dichiarati:** iOS 17 e watchOS 10; RingCore dichiara anche macOS 14. Non sono affermazioni sulle ultime versioni pubblicate.
- **Linguaggio:** pacchetto RingCore in modalità Swift 6; target app attualmente configurati in Swift 5. Se li migri, documenta errori e modifiche invece di ignorare i controlli di concorrenza.

## Preparazione del progetto

L'archivio include `project.yml` come punto di partenza per XcodeGen. Non include un progetto Xcode generato e collaudato: l'output va creato, ispezionato e compilato sul Mac.

### Percorso XcodeGen

Con XcodeGen già installato e disponibile, esegui dalla cartella del progetto:

```sh
xcodegen
open RingClone.xcodeproj
```

Verifica i target generati, il collegamento dell'app Watch e la dipendenza locale RingCore. Inserisci il tuo team di firma e correggi eventuali differenze fra la configurazione e l'SDK reale; non interpretare la generazione riuscita come build riuscita.

### Percorso manuale

Se non usi XcodeGen, crea nell'Xcode installato un progetto iOS SwiftUI con app Watch compagna, usando i template effettivamente disponibili. Aggiungi poi il pacchetto locale e i sorgenti ai rispettivi target, evitando file `@main` duplicati.

- **iPhone:** aggiungi i file in `Apps/iOS`; collega il prodotto RingCore.
- **Watch:** aggiungi i file in `Apps/watchOS`; collega lo stesso pacchetto e verifica la relazione companion.
- **Identificativi:** il punto di partenza è `it.ringclone.app`, con Watch `it.ringclone.app.watchkitapp`. Se usi un prefisso diverso, aggiorna coerentemente companion identifier, identificatori dei task e impostazioni interessate.
- **Membership:** controlla che ogni file sia nel target giusto e che le risorse necessarie siano incluse. Non aggiungere direttamente i file del pacchetto anche ai target app.

## Permessi e configurazione da verificare

Le chiavi e le capability candidate sono già descritte in `project.yml`. Verifica che corrispondano alle sole funzioni effettivamente implementate, con testi italiani chiari e nessuna richiesta “per prudenza” priva di uso.

| Ambito | Verifica richiesta |
|---|---|
| iPhone, Salute | HealthKit, descrizioni di lettura/scrittura coerenti con le operazioni reali, consegna in background se usata. |
| iPhone, background | Identificatori registrati e permessi coerenti con i task effettivamente presenti; scadenza e cancellazione gestite. |
| Watch, allenamenti | HealthKit, autorizzazioni necessarie e modalità workout coerente con sessioni reali. |
| Watch, movimento | Descrizione dell'uso del movimento, disponibilità dell'API e comportamento quando non supportata. |
| Companion | Identificatori iPhone/Watch coerenti, trasferimento file e formato delle impostazioni compatibili. |
| Privacy | Protezione dei file, comportamento dei backup, nessun log sanitario superfluo e gestione della revoca. |

Per la futura integrazione RMSSD nativa, la sola guardia `#available` non basta se l'SDK usato non conosce il simbolo. La documentazione Apple lo elenca da iOS/watchOS 27.0, senza dettagliare la semantica del campionamento; questo percorso non è stato integrato nel prototipo ([Apple RMSSD](https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/heartratevariabilityrmssd)).

## Build e prove prima dell'installazione

- **Motore:** esegui `swift test` e confronta i 45 test attesi; i test su Linux sono già superati, ma non sostituiscono quelli nell'ambiente Apple.
- **Target:** compila separatamente iPhone e Watch contro gli SDK reali. Registra versioni, comandi e log, correggendo gli errori senza nascondere warning rilevanti.
- **Simulatori:** verifica navigazione e stati vuoti/dimostrativi con dati chiaramente sintetici. Raccogli screenshot solo dopo un'esecuzione reale.
- **Dispositivi:** verifica permessi, disponibilità dei canali, workout, salvataggio, trasferimenti, telefono bloccato, offline, riavvii e batteria.
- **Accettazione:** nessuna dichiarazione “pronta per App Store” senza firma, privacy, prove e requisiti di distribuzione effettivamente completati.

## Primo uso e aspettative corrette

Il prototipo chiede dati di profilo ed esegue un'elaborazione storica iniziale; non tutti i risultati hanno già un controllo adeguato dei prerequisiti. Finché i difetti elencati nel prompt non sono risolti, usalo come base di sviluppo e non per decisioni sanitarie.

- **Salute:** concedi soltanto gli accessi che scegli di usare. Serie di battiti, temperatura, respiro e altre misure possono essere assenti; non sono garantiti da una generica modalità Sonno.
- **Profilo:** valida età, parametri corporei, bisogno di sonno, giorni lavorativi e FCmax. Il questionario PA categoriale è disponibile nel Core ma non ancora nella schermata.
- **Watch:** l'app richiede registrazioni di movimento limitate; il recorder documenta dodici ore massime per richiesta e conservazione fino a tre giorni ([Apple](https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:))). Non promettere raccolta continua dal solo primo avvio.
- **Calibrazione:** conta i valori validi per ogni metrica, non soltanto le notti. Questo comportamento è un requisito ancora da completare nello strato app.
- **Demo:** ventuno giorni sintetici in memoria; mantieni un avviso persistente e non scriverli in Salute o nello storico reale.
- **Migrazione:** se importi dati derivati da v2, conserva gli originali e pianifica il ricalcolo cronologico con versione PA aggiornata. Non cancellare archivi per aggirare errori.

Questa checklist non modifica i file delle app né installa nulla sui tuoi dispositivi. Il materiale da consegnare allo sviluppatore è il progetto completo con il prompt, non questo documento da solo.
