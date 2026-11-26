# Riletture parziali della notte · RC7

`DailyPipeline.run` descrive i dati della lettura. `History.upsert` aggiorna l’archivio nel normale percorso `DayAssembler` → `Store`. Una rilettura priva di una notte verificabile può aggiornare le calorie osservate e i contributi di FC diurna senza cancellare la notte archiviata, le sue misure, i sonnellini o i tratti classificati. Il report registra separatamente gli istanti di lettura di quei settori. La scheda Sonno rende visibile la data della notte conservata e i punteggi che richiedono ingressi non ricomponibili risultano da verificare.

## Verifica della sostituzione

La sostituzione richiede lo stesso asse civile, un episodio principale concluso e una lettura coerente nel suo intervallo classificato. La conclusione usa l’uscita da letto osservata dopo la veglia finale o osservazioni successive già previste dal motore. Queste condizioni da sole non bastano per togliere sonno osservato. Se il nuovo episodio è più breve, ogni porzione rimossa deve avere veglia nativa sullo stesso intervallo e della stessa provenienza verificata. Un frammento con un risveglio documentato può lasciare ignota la coda della notte precedente. La veglia esplicita interna, con sonno documentato su entrambi i lati, può invece giustificare una revisione. `inBed`, una query riuscita, la FC e i buchi non dimostrano quella veglia; sovrapposizioni incompatibili lasciano la sostituzione senza prova sufficiente. Nessuna cancellazione viene inferita da una rilettura vuota.

La provenienza e la cronologia degli aggiornamenti usano gli identificatori e le letture locali descritti in RC6. L’istante indica quando l’app ha letto i dati. HealthKit non offre attraverso questo percorso una cronologia di scrittura o cancellazione per le revisioni del sonno. Un archivio senza asse mantiene leggibile la sua notte senza combinare letture attribuite a un nuovo asse. Una notte precedente senza fonte verificata non autorizza a sottrarla per presunta identità di un dispositivo. Una rilettura che copre la classificazione precedente può risolvere il caso.

## Settori conservati

- Energia. Una somma osservata più recente, compreso zero, ha precedenza. Una stima successiva conserva il valore osservato. Se la sola energia attiva viene aggiornata, il totale di una lettura precedente resta datato e non definitivo.
- FC. Il report salva la classe di zona per minuto osservato, senza conservare la FC grezza per questo merge. Una nuova lettura aggiorna il contributo diurno quando i limiti di zona coincidono. I minuti che toccano la notte o i sonnellini conservati restano attribuiti alla lettura di origine. Se manca una classificazione compatibile, il contributo resta non definitivo.
- Sonno. L’archivio conserva la prima e l’ultima lettura per le classificazioni notturne strutturalmente distinte, più l’eventuale prima notte indeterminata. Le letture ripetute senza notte, gli aggiornamenti diurni e i replay esatti non aggiungono varianti. Questa è una proiezione per settore, con i limiti di un archivio di report, e non una cronologia delle modifiche HealthKit. Le rettifiche serali RC6 restano legate a fonte, copertura e istanti originali.

La verifica su dispositivi resta necessaria per la disponibilità dei campioni e degli identificatori HealthKit. I casi di regressione usano dati sintetici e lo stesso merge dello Store.
