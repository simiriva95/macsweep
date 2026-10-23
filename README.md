# MacSweep

App nativa macOS 15+ (SwiftUI + Swift Charts) per gestire lo storage e fare manutenzione. Nessuna dipendenza, nessun Xcode project.

⌘R in ogni sezione: ricalcola / riscansiona / cerca.

## Build e installazione

```bash
./build.sh install
```

Compila con `swiftc`, genera l'icona, esegue il self-test (`MacSweep --selftest`) e installa in `/Applications/MacSweep.app`. Senza `install` crea solo `build/MacSweep.app`.

**Accesso completo al disco**: Impostazioni di Sistema → Privacy e sicurezza → Accesso completo al disco → aggiungi MacSweep. Senza, Cestino, Mail e alcuni container risultano vuoti. `build.sh` firma col certificato "MacSweep Local Signing" del portachiavi, se presente: la firma resta stabile e il permesso sopravvive alle ricompilazioni (senza certificato firma ad-hoc e il permesso va ridato a ogni build).

Verifica permesso: `open -a MacSweep --args --diag && cat /tmp/macsweep-diag.txt` (OK/NO su Cestino, Mail, Safari).

## Comodità

- **Pulizia rapida** (Panoramica, barra dei menu, notch): cache, log, DerivedData, npm, Gradle, `brew cleanup`, simulatori non disponibili e Cestino in un clic, con anteprima e spunte; a fine pulizia, festa con lo spazio liberato.
- **Svuota Cestino** ovunque (anche i Cestini dei dischi esterni), con conferma: è definitivo.
- **Notch** (Mac con notch): passandoci sopra si apre un pannello con spazio libero, RAM, Svuota Cestino, Pulizia rapida, Apri. Mostra le scansioni in corso e "+X GB liberi" dopo una pulizia. Si spegne in Andamento → Avvisi.
- **Aggiornamenti → Strumenti di sviluppo**: npm globali, pnpm, bun, Rust (rustup), uv, Claude Code, Node LTS (nvm).

## Sezioni

**Spazio**
- **Panoramica**: anello del disco e chi occupa cosa (cache, log, Xcode, npm/pnpm/gradle, Docker, backup iPhone, Download, app). "Pulisci" sposta il contenuto nel Cestino.
- **Andamento**: grafico dello spazio libero nel tempo (una fotografia al giorno in `~/Library/Application Support/MacSweep/history.json`) e cosa è cresciuto in 7/30/90 giorni. Icona nella barra dei menu, avviso sotto soglia, apertura all'accensione.
- **Esplora**: cartelle ordinate per peso con barra di composizione, oppure **Mappa** a raggiera (3 anelli, clic su una fetta per entrare).
  Scanner proprio (`Sources/Scanner.swift`): `getattrlistbulk` + 12 thread, hard link contati una volta come `du -x`. Home da 550 GB in ~30-40 s (con `du` ~150 s). L'ultima scansione resta in `~/Library/Application Support/MacSweep/scan-cache.json` (cartelle ≥ 1 MB): all'avvio i dati compaiono subito e, se hanno più di un'ora, si aggiornano in background.
- **File grandi**: via Spotlight.
- **Download e duplicati**: installer (.dmg/.pkg…, con "App già installata"), file non aperti da N mesi, duplicati veri per contenuto (SHA-256), tenendo sempre almeno una copia.
- **Dischi esterni**: spazio, file nascosti di macOS (.DS_Store, ._*, Cestino del disco), espulsione.

**Sviluppo**
- **Progetti dev**: node_modules, venv, target, Pods, .next…
- **Versioni strumenti**: Node (nvm), Python (pyenv), Ruby (rbenv), Rust (rustup), Java, Go, Gradle, Android; quella in uso è protetta.
- **Homebrew**: pacchetti e app con peso, chi li usa, orfani; disinstallazione.
- **Repository Git**: peso di .git, `git gc`, eliminazione delle branch già unite (`git branch -d`, mai main/master/develop).
- **Docker**: immagini, container, volumi e build cache uno per uno (cancellazione definitiva, via CLI `docker`).
- **Simulatori**: runtime iOS/watchOS e singoli simulatori (`xcrun simctl`).
- **Modelli AI**: LM Studio, Hugging Face, Draw Things, Ollama.
- **Macchine virtuali**: UTM, Parallels, VMware, VirtualBox.

**Sistema**
- **Disinstalla**: app + residui in `~/Library` (preferenze, cache, container…), tutto nel Cestino.
- **Browser e privacy**: cache, cronologia e cookie di Chrome, Edge, Brave, Arc, Safari, Firefox (di Firefox niente cronologia: sta coi segnalibri).
- **Avvio automatico**: LaunchAgents ed elementi di login. Modificabili solo i tuoi agenti; quelli di sistema/aziendali in sola lettura.
- **Prestazioni**: memoria (con pressione e swap), CPU, app raggruppate con i loro processi, "Chiudi".
- **Aggiornamenti**: `brew outdated`, App Store (con `mas`), Aggiornamento Software di macOS.
- **Batteria**: salute, cicli, capacità reale, temperatura, alimentatore.
- **Manutenzione**: brew, simctl, npm/pnpm, docker, QuickLook, snapshot, svuota Cestino + **Pulizia programmata** (LaunchAgent `local.sriva.macsweep.autoclean` che lancia `MacSweep --autoclean`).
- **Registro**: tutto ciò che è finito nel Cestino, raggruppato per sessione, con "Rimetti tutto".

## Sicurezza

- File e cartelle vanno nel Cestino (`FileManager.trashItem`), ripristinabili dal Registro. Azioni definitive, sempre con conferma esplicita: "Svuota Cestino", eliminazioni Docker e simulatori (le fanno i rispettivi tool), DerivedData/Log nella pulizia programmata se spuntati.
- Mai toccati: `/System`, `/Library`, radici utente (`~`, `~/Library`, `~/Documents`…), cartelle dirette in `~/Library`. Fuori dalla home solo `/Applications/*.app`.

## File

- `Sources/Scanner.swift`: scanner veloce e cache su disco
- `Sources/Core.swift`: guard, cestino, registro, store
- `Sources/Features.swift`: avvio automatico, andamento, duplicati, Docker, simulatori, modelli AI, VM, pulizia programmata, ripristino
- `Sources/FeatureViews.swift`: viste delle sezioni sopra + barra dei menu
- `Sources/Extras.swift`: svuota Cestino, Pulizia rapida, festa, updater sviluppo, notch
- `Sources/More.swift` / `Sources/MoreViews.swift`: browser, prestazioni, aggiornamenti, versioni, Homebrew, Git, batteria, dischi esterni, mappa

Verifiche senza interfaccia: `MacSweep --selftest`, `MacSweep --render-map <cartella> <out.png>`, `MacSweep --render-ui <cartella>`, `MacSweep --diag`.
- `Sources/App.swift`: interfaccia
- `scripts/icon.swift`: disegna l'icona
- `build.sh`: build, firma ad-hoc, self-test, install
